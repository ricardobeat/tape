# Plan 031 — Fix String Intern Table Bloat (4.7× memory regression)

**Date**: June 12, 2026
**Status**: Partially implemented — Fixes 2-4 merged to main (14,048 KB, -11%).
Fix 1 (skip interning) reverted: breaks string comparison (pointer equality assumption).

---

## Problem

After plan 030's object-header optimizations, `memory_test.js` RSS is 15,776 KB vs
QuickJS 6,112 KB and original Duktape 6,384 KB. Profiling reveals **78% of the gap**
comes from string concatenation.

### Data (from targeted micro-benchmarks)

| Test | duktape_c3 | QuickJS | Duktape orig | C3/QS ratio |
|------|-----------|---------|-------------|-------------|
| String concat (2000 loops) | **12,752 KB** | 2,704 KB | 2,704 KB | **4.7×** |
| Object allocation (5000 objs) | 4,848 KB | 4,304 KB | — | 1.1× |
| String pool (5000 strings) | 3,856 KB | 2,912 KB | — | 1.3× |
| Arrays (200×200 matrix) | 3,376 KB | — | — | — |
| Prototype chains (2000) | 3,248 KB | — | — | — |

- Baseline engine overhead (empty script): 2,688 KB
- `memory_test.js` net: 12,880 KB — of which **10,032 KB is string concat** (78%)
- Object allocation is already competitive (1.1× QuickJS — plan 030 worked)

---

## Root Cause

### The concatenation path

For `str += String(i) + "-"` (one loop iteration, 3 allocations):

```
1. String(i)         → builtin_to_string → builtin_intern_string → str_table_insert (refcount 0)
2. String(i) + "-"   → ADD opcode → intern_string → str_intern → str_table_insert (refcount 1)
3. str += result      → ADD opcode → intern_string → str_intern → str_table_insert (refcount 1)
```

Every intermediate concatenation result enters the string table via `Heap.str_intern`
(`src/heap.c3:1953`) with refcount 1. The table **never shrinks, never compacts**.
`sweep_strings` only replaces entries with `STR_TABLE_TOMBSTONE` — no rehashing.

### Accumulated dead strings after 2000 iterations

- ~1999 old `str` values (growing accumulator: "", "0-", "0-1-", …, "0-1-…-1998-")
- ~2000 first-concat results ("0-", "1-", …, "1999-")
- Data: ~4.0 MB of dead string bodies + ~96 KB headers + 64 KB table array
- **Total dead weight: ~4.2 MB** — exactly the gap to QuickJS/Duktape

### Why GC never runs during the loop

String allocations use `Heap.alloc_no_gc` (`src/heap.c3:1154`) which does NOT
decrement `gc_trigger_counter`. Zero `Heap.alloc` calls → zero GC triggers
during the entire concat loop. Dead refcount-1 strings accumulate unchecked.

### What original Duktape and QuickJS do differently

Both engines **skip interning** for concatenation results. They allocate temporary
heap strings that are freed by refcounting immediately when their last reference
disappears — no string table entry, no permanent storage.

---

## Fixes (ranked by impact)

### Fix 1 (Primary — 78% of the gap): Don't intern ADD concat results

**File**: `src/vm.c3`
**Lines**: ~1995 (STRING+FASTINT fast path), ~2049 (generic string+string path)

Replace `intern_string(vm, buf[:total])` with non-interned allocation:

```
HString* s = hstring_alloc(heap, data, hash);
// NO str_table_insert — the string lives in registers only
// When the register is overwritten, decref → 0 triggers immediate free
reg.set_string(s);
```

Two paths in the ADD opcode:
1. **Fast path** (line ~1995): one operand is FASTINT, other is STRING → format into buffer, allocate
2. **Generic path** (line ~2049): both STRING → memcpy into buffer, allocate

Both currently call `intern_string()`. Both should switch to non-interned allocation.

**Risk**: Medium. Concatenation results that are later used as property keys will
need lazy interning. A flag bit on HString (`is_interned`) handles this — if a
non-interned string is used as a property key, intern it on demand.

**Estimated impact**: `memory_test.js` RSS drops from ~15,776 KB to ~6,000-7,000 KB.

### Fix 2 (Medium): Add a HString flag for non-interned strings

**File**: `src/hstring.c3`

Add `bool is_interned` to `HStringFlags` (there's room). New strings created
outside `str_intern` have this flag off. When used as a property key
(`PUTPROP`, `GETPROP`, etc.), lazily intern:

```
if (!str.flags.is_interned) {
    heap.str_table_insert(str);
    ((HeapHeader*)str).incref();
    str.flags.is_interned = true;
}
```

### Fix 3 (Medium): Trigger GC during string-heavy loops

**File**: `src/heap.c3`, `alloc_no_gc` (line ~1154)

Add a periodic GC trigger so dead refcount-1 strings get swept even in
string-only workloads:

```
string_alloc_counter++;
if (string_alloc_counter >= 512) {
    string_alloc_counter = 0;
    trigger_gc();
}
```

**Estimated impact**: Captures ~4 MB of dead strings during the loop.

### Fix 4 (Low): Fix `builtin_intern_string` missing incref

**File**: `src/builtins/core.c3`, line ~660

`builtin_intern_string` calls `str_table_insert` but never does `incref()`,
unlike `Heap.str_intern` (heap.c3:1966). Strings interned this way have
refcount 0 and are freed on the next RC cycle — inconsistent with other
intern paths. Add the incref.

### Fix 5 (Low, cleanup): Shrink string table after sweep

**File**: `src/heap.c3`, `sweep_strings` (line ~1709)

After sweeping, if `str_table_used < str_table_size / 4`, shrink the table.
Currently it only grows via doubling at 70% load factor — it can end up
at 8192 entries for 500 live strings.

---

## Implementation Order

| # | Item | Effort | Risk | Estimated RSS impact |
|---|------|--------|------|----------------------|
| 1 | Skip interning for ADD concat results | Low | Medium | **-8,000 KB** |
| 2 | Non-interned string flag + lazy interning | Low | Low | Enables #1 safely |
| 3 | Periodic GC in `alloc_no_gc` | Trivial | None | **-2,000 KB** |
| 4 | Fix `builtin_intern_string` incref | Trivial | None | Correctness |
| 5 | String table shrink after sweep | Low | None | Cleanup |

**Items 1+2 must go together** — non-interned strings need lazy interning for
key usage. **Item 3** is a simple safety net. **Items 4+5** are cleanup.

---

## Verification

```bash
# Before/after benchmark
just bench-memory              # compare memory_test.js RSS
just bench-memory-compare       # full comparison with Duktape/QuickJS

# Correctness
just rosetta                    # must stay at 41/43
c3c build test_vm && ./out/test_vm test/simple.js
c3c -D NONANBOX build test_vm && ./out/test_vm test/simple.js
c3c -D NOSHAPECACHE build test_vm && ./out/test_vm test/simple.js
```

---

## Results (Fixes 2-4 only)

| Metric | Before (plan 030) | After (fixes 2-4) | Delta |
|--------|------------------|-------------------|-------|
| memory_test.js RSS | 15,776 KB | 14,048 KB | **-11%** (-1,728 KB) |
| memory_heavy.js RSS | — | 29,616 KB (0.9× QJS) | — |
| rosetta | 41/43 | **43/43** | +2 fixed |
| vs QJS (memory_test) | 2.6× | **2.3×** | improved |
| vs Duktape orig | 2.5× | **2.3×** | improved |

## Why Fix 1 (skip interning) was reverted

The engine uses **pointer equality for string comparison** (all strings are interned). Skipping interning for concat results breaks every `str1 === str2`, `switch(str)`, property lookup, etc. Original Duktape handles this via "dynamic strings" with spare capacity — a deeper refactor.

**Path forward**: Content-based string comparison for non-interned strings (modify EQ/STRICTEQ opcodes) would unlock Fix 1. The `is_interned` flag and lazy interning infrastructure (now reverted but understood) would be reactivated at that point.

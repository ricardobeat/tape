# Plan 029 — Memory Optimization: Low-Hanging Fruit

**Date**: June 12, 2026
**Status**: 🔶 PARTIAL — Items 1, 3 & 4 done; Items 2 & 5 remain
**Goal**: Reduce peak RSS by 8–9 MB (50 MB → 21 MB) on `bench_memory_heavy.js`

---

## Background

`just bench-memory` shows the C3 port uses up to **3× more RSS** than original Duktape
and QuickJS. Analysis of the `bench_memory_heavy.js` workload (~120,500 live objects
at peak) identifies the root cause: **HObject fixed overhead is larger than other engines**,
accounting for ~60% of total memory.

The `HObjectExtra` tagged union (plan 009) already eliminated the worst duplication.
The remaining gap is from fields carried by every object that are only needed by a
subset of classes, plus general struct bloat from wide integer types.

### HObject struct layout (after Items 3 & 4 — 112 bytes)

```
Offset  Size  Field
0       4     ObjFlags flags
4       4     uint refcount
8       8     HeapHeader* next
16      8     HeapHeader* prev
24      8     HObject* prototype
32      2     ushort shape_id       ← compressed (was uint)
34      6     [pad]
40      8     Shape* shape
48      2     ushort prop_capacity  ← compressed
50      2     ushort prop_count     ← compressed
52      2     ushort array_size     ← compressed
54      2     ushort array_used     ← compressed
56      8     void* prop_alloc
64      8     PropHashInfo* prop_hash
72      32    HObjectExtra extra    ← 32 bytes wasted on plain {}
104     4     uint array_length     ← 4 bytes wasted on non-arrays
108     4     [pad]
Total: 112 bytes  (down from 128 after Items 3+4)
```

### Architectural analysis — further reduction levers

| # | Change | Savings/obj | Effort | Risk | Notes |
|---|--------|------------|--------|------|-------|
| 1 | Per-class allocation (remove `extra` + `array_length` from plain objects) | 40 bytes | Medium | Medium | This plan |
| 2 | Default-prototype elision | 8 bytes | Medium | Low | Moves common case to Shape; enables #1 to drop `prototype` from base |
| 3 | Drop `Shape* shape` pointer | 8 bytes | Low | Medium | Already have `shape_id`; add indirection via heap→shapes[shape_id] |
| 4 | Singly-linked GC list (drop `prev`) | 8 bytes | Low | Low | Sweep tracks previous during traversal |
| 5 | Compress `ObjFlags` to ushort | 2 bytes | Very low | Low | If flags fit in 16 bits |
| **Potential total** | **112 → 54 bytes** | — | — | Matches original Duktape's 48–56b for plain `{}` |

---

## Completed Items

### ✅ Item 3: Remove `heap_ptr` from HObject (8 bytes saved)

Replaced per-object `void* heap_ptr` with module-level `_active_heap` in `hobject.c3`.
Set on heap create/reset, cleared during teardown. Same RC guard semantics.
**Commit**: `2754d60`

### ✅ Item 4: Compress uint fields to ushort (8 bytes saved net)

Changed `shape_id`, `prop_capacity`, `prop_count`, `array_size`, `array_used` from
`uint` (4b) → `ushort` (2b). Also compressed `ICEntry.shape_id/prop_idx`,
`VarICEntry.shape_id/generation`, `TransitionEntry.shape_id`. Added overflow guards
at 65535. `array_length` stays `uint` for sparse array spec compliance.
**Commit**: `7eaf058`

### Benchmark results (vs main branch)

| Benchmark | main | this branch | delta |
|---|---|---|---|
| `memory_test.js` | 17,056 KB | 16,864 KB | **-192 KB** |
| `bench_memory_heavy.js` | 50,560 KB | 43,349 KB | **-7,211 KB** |

The heavy benchmark savings come from combined HObject (16b/obj) + IC/VarIC entry
size reductions across 10k closures (ICE 44→40 + VarIC 48→40 per instruction).

---

## Remaining Tasks

### Item 1: Per-class allocation sizes

**Current state**: Every object is 112 bytes regardless of class. Plain `{}` objects
pay for `HObjectExtra` (32b) + `array_length` (4b + 4 pad = 8b) they never use.

**Fix**: Split HObject into `HObjectBase` (72 bytes — all fields up to `prop_hash`)
+ class-specific trailing data. Allocation sizes:

| Class | Base + ... | Total |
|---|---|---|
| OBJECT, ERROR, ARGUMENTS, PROXY | — | **72** |
| ARRAY | ArrayTail (array_length, 8b) | **80** |
| FUNCTION, GENERATOR, THREAD | HObjectExtra (32b) | **104** |
| BOOLEAN, NUMBER, STRING, DATE | HObjectExtra (32b) | **104** |
| REGEXP | HObjectExtra (32b) | **104** |
| *_ITERATOR | HObjectExtra (32b) | **104** |

`HObjectBase`: fields from `flags` through `prop_hash` (72 bytes, 8-byte aligned).
`extra` and `array_length` are accessed via `@inline` accessor that computes
`(char*)self + HObjectBase::size`.

**Steps**:
1. Define `HObjectBase` struct (72 bytes)
2. Add `@inline` accessors: `extra_ref()`, `array_length_ref()`
3. Add `alloc_size_for_class(ObjClass)` — returns correct allocation size
4. Update `hobject_alloc`/`hobject_free` to use class-specific sizes
5. Mechanical migration: `self.extra.func.var_env` → `self.extra_ref().func.var_env`
   (~100 sites across hobject.c3, vm.c3, heap.c3, builtins/*.c3)
6. Mechanical migration: `self.array_length` → `self.array_length_ref()` (guarded by exotic_array flag)
7. GC marking: `drain_gray` already has a switch on obj_class — use accessor inside each case

**Impact**: 110,000 plain objects × 40 bytes = **~4.4 MB saved**
**Effort**: Medium  
**Risk**: Medium (GC marking correctness, property accessor pointer arithmetic)

**Status**: ✅ DONE — per-class allocation, pool routing, and trailing-data accessors all landed

---

### Item 2: Default-prototype elision

Deferred — changes ~67 sites across 16 files, saves 0 bytes standalone.
Must be done together with Item 1 to exclude `prototype` from `HObjectBase`.

---

### Item 5: Sparse IC allocation

Deferred — saves ~50 KB on the benchmark. Medium effort, medium risk.

---

## Combined Estimate (original)

| Item | Savings | Effort | Risk | Status |
|------|---------|--------|------|--------|
| 1. Per-class allocation | ~4.4 MB | Medium | Medium | ✅ DONE |
| 2. Default prototype | ~0.88 MB | Low | Low | DEFERRED |
| 3. Remove heap_ptr | ~0.96 MB | Low | Very low | ✅ DONE |
| 4. Compress uints | ~1.45 MB | Low | Low-Medium | ✅ DONE |
| 5. Sparse IC | ~0.05 MB | Medium | Medium | DEFERRED |
| **Total** | **~7.7 MB** | — | — | — |

## Verification

```bash
just build          # nanbox
just build-nonanbox test_vm
just test262        # no regressions
just bench-memory   # compare before/after RSS
```

## See Also

- [033-memory-next-steps.md](033-memory-next-steps.md) — remaining heavy-workload gap analysis and next priorities

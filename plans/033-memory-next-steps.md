# Plan 033 — Memory: Remaining Work After Plans 029–032

**Date:** 2026-06-13
**Status:** 🔄 IN PROGRESS (item 2 done)
**Goal:** Close the remaining RSS gap on `bench_memory_heavy.js` (45.6 MB vs QuickJS 31.8 MB)

---

## Current State

Memory optimization plans 029–032 have landed. The light workload (`memory_test.js`) is now competitive:

| Engine | `memory_test.js` | `bench_memory_heavy.js` |
|---|---|---|
| duktape_c3 (C3 port) | **6,656 KB** | **45,616 KB** |
| duktape_orig | 6,384 KB | 39,264 KB |
| qjs (QuickJS) | 6,112 KB | 31,808 KB |

- `memory_test.js` is essentially tied with original Duktape and QuickJS.
- `bench_memory_heavy.js` is still **1.4× QuickJS** and **1.2× original Duktape**.

This plan targets the heavy-workload gap.

---

## What Is Already Done

Do not re-open these:

| Plan | Achievement |
|---|---|
| 029 | Per-class allocation sizes, `heap_ptr` removal, uint→ushort compression |
| 030 | Inline props (4 slots), unified `prop_alloc` block, `FixedBlockPool` object pools |
| 031 | Selective skip-interning for `ADD` concatenation + lazy intern on property-key use |
| 032 | GC safe points (`gc_pending` + `safepoint_gc`) and `temproot` protection |

Object headers are no longer the problem: `HObjectBase` is 64 bytes for plain objects, matching original Duktape.

---

## Root Causes on `bench_memory_heavy.js`

### 1. Boxed accessor pairs — `PropValue` 16→8 bytes (largest remaining item)

`PropValue` currently stores `TVal value` + `TVal setter`. Data properties — the overwhelming majority — waste 8 bytes per slot.

The heavy benchmark has roughly:
- 50k top-level objects × 4 properties
- 50k nested objects × 3 properties
- 10k prototype-chain objects × 2 properties
- 10k closure environments × 1 binding

≈ **380k data-property slots**. Halving each slot saves **~3 MB**.

**Design:** SpiderMonkey/JSC-style boxed accessor pairs.
- Each `prop_values[]` slot shrinks to a single `TVal` (8 bytes).
- Data properties: slot stores the value directly (unchanged semantics).
- Accessor properties: slot stores a tagged pointer to a `GetterSetter` GC cell.
- `Shape.PropFlags.is_accessor` flag tells readers how to interpret the slot.

**New infrastructure needed:**
- `GetterSetter` struct: `HeapHeader` + `TVal getter` + `TVal setter`
- GC allocation + tracing for `GetterSetter` cells

**Blast radius (scoped during implementation attempt):**

| Category | Sites | Files |
|---|---|---|
| `.data.value` → direct TVal | ~55 | 7 files |
| `.data.getter`/`.setter` → GetterSetter indirection | ~28 | 6 files |
| `PropValue::size` → `TVal::size` | ~18 | hobject.c3 |
| IC `prop_value_ptr` type | 5 | vm.c3, hobject.c3 |
| GC tracing | 3 lines | heap.c3 |
| Pool size constants | 3 | hobject.c3 |
| **Total** | **~110** | **8 files** |

**Key gotcha (discovered during implementation):** C3 auto-derefs pointers, so `pv.data.value` on a `TVal*` auto-derefs to `(*pv).data.value`. When removing `.data.value`, pointer-based access (`pv.data.value`) needs `*pv` not just `pv`. Array-indexed access (`prop_values()[idx].data.value`) can just drop `.data.value`. This context-dependence prevents bulk sed — each site needs individual handling.

**Estimated impact:** 3–5 MB RSS on `bench_memory_heavy.js`.
**Effort:** High (dedicated session needed).
**Risk:** Medium — touches indexing assumptions across hobject/vm/builtins.

---

### 2. ~~GC still cannot collect inside call-free allocation loops~~ ✅ DONE

Plan 032 defers GC to CALL/RET/RETUNDEF safe points. The heavy benchmark allocates large arrays and many temporaries in tight loops that contain no calls. Dead objects and dead interned strings accumulate until the loop exits.

**Fix:** Added backward-jump GC safe points with a budget-based throttle (`BWD_GC_INTERVAL = 1024`). On every backward jump (JUMP, IF_TRUE, IF_FALSE, JMP_LT/LE/GT/GE, JMP_NLT/NLE/NGT/NGE), a countdown counter is decremented. When it hits 0, `gc_pending` is checked and `safepoint_gc()` runs if set. This prevents GC thrashing while catching call-free allocation loops.

**Measured:** No RSS change on `bench_memory_heavy.js` (that benchmark has calls in its loops). Correctness benefit: call-free loops like `while (i < n) { a[i] = {v:i}; i++; }` now trigger mid-loop GC instead of accumulating all dead objects until the loop exits.

**Effort:** Medium.  **Risk:** Low (budget throttle prevents thrashing; 43/43 Rosetta + test262 + bench-fast all pass).

---

### 3. ~~Default-prototype pointer (plan 029 item 2)~~ ⏭ SKIPPED

Most objects inherit from `Object.prototype`. Storing that pointer explicitly costs 8 bytes per object.

**Why skipped:** Removing the `prototype` field from `HObjectBase` saves ~1 MB (120k objects × 8 bytes) but requires touching 200+ write sites across 16 files. Additionally, `null` already means "end of chain" (for `Object.create(null)`, `Object.prototype.__proto__`), so a naive sentinel doesn't work — every prototype chain walk (7 hot loops) would need an extra indirection. ROI is poor vs. item 1.

---

### 4. ~~Per-array `prop_alloc` malloc overhead~~ ⏭ SKIPPED

Every array object allocates its own `prop_alloc` block for the dense array part. The heavy benchmark creates:
- 1 array of 100k numbers
- 500 row arrays of 500 elements each

Each block carries allocator metadata and fragmentation.

**Why skipped:** Actual malloc metadata overhead is ~10 KB (600 arrays × 16 bytes). A slab pool for variable-size blocks would likely *increase* memory from internal fragmentation. Not worth the effort.

---

### 5. ~~`HString` header bloat~~ ✅ ALREADY DONE

`HString` is 24 bytes in the C3 port. The plan's target fields (`clen`, `arridx`) were never added to the C3 port — they existed only in original Duktape's 32-byte HString. No work needed.

---

## What to Skip

| Idea | Why skip |
|---|---|
| Unboxed dense arrays of numbers | `TVal` is already 8 bytes for nanboxed doubles/fastints; no memory win, only speed/cache. |
| Drop `Shape*` pointer cache by default | Saves 8 bytes/object, but shape access is hot (plan 019). Keep as `-D NOSHAPECACHE` for constrained builds. |
| Packed structs for `Shape`/`ShapeProperty` | Modest gains; revisit after the larger items above. |

---

## Recommended Order

1. **GC on backward jumps** — closes call-free loop gaps quickly and is well-isolated.
2. **Default-prototype elision** — mechanical, low risk, measurable object-header win.
3. **Boxed accessor pairs** — biggest structural win, but highest effort; do after the easy wins.
4. **Array-data pool** — measure after #1–3; may no longer be worthwhile.
5. **String header slimming** — small cleanup when someone has a short cycle.

---

## Verification

```bash
just bench-memory           # before/after RSS comparison
just bench-fast             # ensure no speed regression
just test262                # no conformance regressions
just rosetta                # 43/43
```

Target: `bench_memory_heavy.js` ≤ 35 MB RSS (≤ 1.1× QuickJS).

---

## Related Plans

- [029-memory-low-hanging-fruit.md](029-memory-low-hanging-fruit.md) — structural size reductions
- [030-memory-profiling.md](030-memory-profiling.md) — profiling data and boxed-accessor design
- [031-string-intern-bloat.md](031-string-intern-bloat.md) — concat interning fix
- [032-gc-safepoints.md](032-gc-safepoints.md) — deferred GC foundation

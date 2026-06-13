# Plan 033 — Memory: Remaining Work After Plans 029–032

**Date:** 2026-06-13
**Status:** 📋 PENDING
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

### 1. `PropValue` is 16 bytes for mostly data properties (largest remaining item)

`PropValue` currently stores `TVal value` + `TVal setter`. Data properties — the overwhelming majority — waste 8 bytes per slot.

The heavy benchmark has roughly:
- 50k top-level objects × 4 properties
- 50k nested objects × 3 properties
- 10k prototype-chain objects × 2 properties
- 10k closure environments × 1 binding

≈ **380k data-property slots**. Halving each slot saves **~3 MB**.

**Fix:** Boxed accessor pairs (SpiderMonkey/JSC-style). Each slot becomes a single 8-byte `TVal`. Accessor properties store a pointer to a rare `GetterSetter` GC cell.

- See plan 030 §2 for the detailed design.
- Cross-cutting: `prop_values[]` layout, ICs, `prop_idx`, property transitions, GC tracing.

**Estimated impact:** 3–5 MB RSS on `bench_memory_heavy.js`.
**Effort:** High.
**Risk:** Medium — touches indexing assumptions across hobject/vm/builtins.

---

### 2. GC still cannot collect inside call-free allocation loops

Plan 032 defers GC to CALL/RET/RETUNDEF safe points. The heavy benchmark allocates large arrays and many temporaries in tight loops that contain no calls. Dead objects and dead interned strings accumulate until the loop exits.

**Fix:** Add a second safe point on backward jumps (JMP family). A cheap per-iteration allocation budget or counter can trigger `safepoint_gc()` without regressing hot loops.

**Estimated impact:** 2–6 MB peak-RSS reduction on allocation-heavy, call-free loops.
**Effort:** Medium.
**Risk:** Medium — must not regress `bench_shape_no_call` / `bench_shape_stress`.

---

### 3. Default-prototype pointer (plan 029 item 2)

Most objects inherit from `Object.prototype`. Storing that pointer explicitly costs 8 bytes per object.

**Fix:** Treat `Object.prototype` as an implicit default. Only store non-default prototypes. This was deferred in plan 029 because it must be combined with removing `prototype` from `HObjectBase` to realize the savings.

**Estimated impact:** ~1 MB on the heavy benchmark (~120k live objects).
**Effort:** Medium.
**Risk:** Low-Medium — ~67 call sites across 16 files.

---

### 4. Per-array `prop_alloc` malloc overhead

Every array object allocates its own `prop_alloc` block for the dense array part. The heavy benchmark creates:
- 1 array of 100k numbers
- 500 row arrays of 500 elements each

Each block carries allocator metadata and fragmentation.

**Fix:** A dedicated slab/pool for array data blocks, or a generational bump allocator for array parts that are grown during initialization. Lower priority than #1–3 because the array data itself is already stored as 8-byte `TVal` values.

**Estimated impact:** <1 MB.
**Effort:** Medium.
**Risk:** Low.

---

### 5. `HString` header bloat

`HString` is 32 bytes vs QuickJS's ~12 bytes. Fields `clen` and `arridx` can be computed lazily for most strings.

**Fix:** Remove `clen`/`arridx` from the hot path; cache only when needed. See plan 030 §3.

**Estimated impact:** ~1 MB on the heavy benchmark (~60k unique strings including `String(i)` temporaries that survive).
**Effort:** Low-Medium.
**Risk:** Low.

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

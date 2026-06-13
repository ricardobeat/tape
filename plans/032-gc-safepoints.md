# Plan 032: GC safe points — eliminate in-flight object frees

**Status:** ✅ IMPLEMENTED
**Created:** 2026-06-13 (Session: PUTPROP setter fix / fix-2 retraction)
**Depends on:** plan 031 post-completion correction (fix 2 retracted, `string_sweep_safe` infrastructure)

## Problem

`Heap.alloc` and `Heap.realloc` decrement `gc_trigger_counter` and run a full
`mark_and_sweep` from *inside* the allocation (heap.c3 ~1143, ~1207). Any code
that allocates twice in a row — builtin init, opcode handlers, builtins like
`Object.defineProperty` — can have the second allocation's GC free the first
allocation, because the object is still held only in a C3 local that no GC
root can see (refcount 0, not yet anchored by `put_prop`/register store).
The later incref/decref then double-frees the block and corrupts the
FixedBlockPool free list. Crashes surface much later, at an unrelated alloc.

This is the same bug class as plan 031 fix 2 (already removed from
`alloc_no_gc`, commit 6ebefb6), but the remaining triggers predate plan 031.

### Evidence

- Removing the identical trigger from `alloc_no_gc` fixed the deterministic
  test262 worker crash (defineProperty 15.2.3.6-2-20/21/22 prefix → segfault
  in `FixedBlockPool.alloc`, block pointer = `0x100000000`).
- Worker runs over `test262/test/built-ins/Object/defineProperty` (1131 tests)
  remain rarely flaky on main (one test flipped once in five runs) and were
  wildly flaky at 929a836 (871 vs 187 completions on consecutive runs).
- `mark_and_sweep` from `Heap.alloc` has the exact same in-flight window; it
  just fires less often (every 1024 allocs, `GC_INITIAL_TRIGGER`) so it is
  nondeterministic instead of reproducible.

## Design

Two complementary mechanisms:

### 1. Deferred safe-point GC (primary)

Periodic triggers stop collecting inline; they only set a flag. The VM runs
the GC at dispatch-loop safe points, where every live value is anchored in
registers, environments, or object graphs — no raw C3 locals in flight.

- `Heap.alloc` / `Heap.realloc`: replace `trigger_gc()` with
  `self.gc_pending = true` (new field). Keep the emergency OOM-retry GC
  (see mechanism 2 for why it becomes safe).
- vm.c3 dispatch loop: check `vm.heap.gc_pending` in CALL (~4262), RET
  (~5775), RETUNDEF (~5860) handlers and run `heap.safepoint_gc()`. These
  fire often enough for call-bearing code; if memory grows in call-free
  loops, add the check to backward jumps (JMP_* family) later — measure
  first, every hot-loop branch costs.
- `fn void Heap.safepoint_gc(&self)`: set safepoint mode +
  `string_sweep_safe = true`, run `mark_and_sweep`, clear both flags and
  `gc_pending`, reset `gc_trigger_counter`.
- Safe points are also where string-table sweeping becomes legal, recovering
  plan 031 fix 2's memory goal (dead interned strings in long-running
  scripts) without its crashes. The reachable-bit infrastructure in
  `sweep_strings` (commit 6ebefb6) is already in place.

### 2. Temproot protection for emergency GC

The OOM-retry GC cannot be deferred, so in-flight objects must survive it.
`HeapHeader` already has an unused `temproot` flag (types.c3 ~647, present
in HObject/HString/buffer bitstructs) — wire it up as a newborn bit:

- Set `temproot` in `Heap.alloc_object` (and buffer/env allocation paths
  that go through `insert_into_heap_allocated_preserve_flags`).
- `Heap.sweep()`: treat `temproot` as reachable (skip freeing).
- `safepoint_gc()` clears all `temproot` flags during the existing phase-1
  header walk *before* marking — at a safe point nothing is in flight, so
  anything still unreachable is genuinely dead and gets collected one cycle
  late at worst.
- Emergency (non-safepoint) GC never clears `temproot`, so objects allocated
  since the last safe point always survive it.
- Optionally set `temproot` in `hstring_alloc` and honor it in
  `sweep_strings` for symmetric protection of in-flight interned strings.

## Implementation steps

1. heap.c3: add `bool gc_pending`; convert the two periodic triggers in
   `alloc`/`realloc` to set it. (~10 lines)
2. heap.c3: set `temproot` at object allocation; honor it in `sweep()`;
   clear flags in phase 1 only when at a safe point (new heap field or
   parameter). (~20 lines)
3. heap.c3: add `safepoint_gc()` wrapping `mark_and_sweep` with safepoint +
   `string_sweep_safe` semantics. (~15 lines)
4. vm.c3: `gc_pending` checks in CALL/RET/RETUNDEF handlers. (~6 lines)
5. Re-tune `GC_INITIAL_TRIGGER` if pause cadence changed (it now counts
   allocs between safe points, not collections).
6. Optional, measure-driven: backward-jump safe point; string temproot.

## Validation

- `just rosetta` → 43/43.
- defineProperty worker: 5 consecutive full runs, all 1131/1131 complete,
  identical pass counts (884 at merge fdfe295 baseline).
- The 929a836-era flake reproducer: full-directory runs must be stable.
- `benchmarks/memory_test.js` ≤ 7,000 KB RSS; `mem_strpool.js` /
  `mem_strings.js` not ballooning (string sweep at safe points should help
  long-running scripts).
- `bench_shape_no_call.js` / `bench_shape_stress.js` stay ~0.02s (no GC
  inside the 10k-property loop; safepoint checks must not regress dispatch).
- `just bench-fast` overall within noise vs main.

## Risks

- CALL/RET are hot: the `gc_pending` check must be a single predictable
  branch. If bench-fast regresses, fold the check into an existing slow path.
- Call-free allocation loops defer GC indefinitely → temporary memory growth
  until the next call/return. Bounded by what the loop itself allocates;
  backward-jump safe point is the escape hatch.
- Generator/coroutine frames: `mark_roots` scans the valstack via
  `valstack_top_ptr` — verify suspended generator frames are covered before
  enabling string sweep at safe points (their strings are refcounted, so
  object sweep is the only concern).
- One-cycle-late collection of short-lived objects (temproot) slightly raises
  peak RSS between safe points; expected to be negligible.

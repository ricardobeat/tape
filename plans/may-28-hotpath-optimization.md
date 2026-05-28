# CALL/RET Hot-Path Optimization

**Date:** 2026-05-28
**Target:** Close the 2.0x recursion gap on `bench_recursion_deep` (fib 35: 3906ms → target ~1950ms)
**Approach:** Three surgical optimizations to the CALL/RET hot path, each independently measurable

---

## Root Cause

`bench_recursion_deep` (fib 35) is the only benchmark where C3 is still slower than Duktape v2.7.0. All other benchmarks are now faster (0.68x–0.97x). The gap is isolated to CALL/RET opcodes, which dominate recursion but are barely exercised in other benchmarks.

Per-call overhead model (fib 35, 18.45M calls):
- C3: ~196ns/call (3910ms)
- Duktape: ~90ns/call (1660ms)
- C3 executes 2.35x more instructions per run (347.7B vs 36.9B — this is per-run, not per-call)

---

## Optimization 1: Remove Dead `reserve_byteoff`

**Location:** `src/vm.c3:61` (field), 9 assignment sites

The `reserve_byteoff` field in `Activation` is set in 9 places but **never read anywhere**. It was ported from Duktape where it tracks `valstack_end` for restore-on-return, but our port restores valstack via `nregs` recomputation instead.

**Impact:** Saves 1 pointer subtraction + store per activation setup. In the CALL hot path, 9 field stores → 8. Small per-call savings, zero risk.

---

## Optimization 2: Skip Self-Copy in Arg Loop

**Location:** `src/vm.c3:2606-2615`

In the common no-rest case, `new_regs == old_args` (sliding window). The current loop does 35 TVal copies **to the same address** for fib(35). Adding an `if (new_regs != old_args)` guard eliminates this.

**Impact:** Saves ~35 TVal copies per call = ~35 reads + ~35 writes = ~70 memory operations per recursive call. For 18.45M calls: ~1.3B fewer operations. This is the big one.

**Safety:** When `new_regs == old_args`, the values are already in place. The `memset` for unused registers (nargs → new_nregs-1) still runs — those need zeroing for correctness.

---

## Optimization 3: Simplify `valstack_top` Recomputations

**Locations:** `src/vm.c3:942-946` (handle_return), `:3415-3419` (RET), `:3462-3466` (RETUNDEF)

Current pattern:
```c3
uint caller_bottom_idx = caller_act.bottom_byteoff / TVal::size;
vm.valstack_top = (TVal*)((usz)vm.valstack + (usz)(caller_bottom_idx + caller_nregs) * TVal::size);
```

Replaced with:
```c3
vm.valstack_top = ptr_from_byteoff(vm.valstack, caller_act.bottom_byteoff) + caller_nregs;
```

This eliminates an integer division (shift by 3 for TVal::size=8, but C3 may not optimize this as well as clang would) and simplifies the pointer math.

**Impact:** Small per-RET savings. 3 sites fixed.

---

## Benchmarks

Run after implementation:
```
just bench-one benchmarks/bench_recursion_deep.js 5
just bench-one benchmarks/bench_recursion.js 5
```

Expected improvement: 10-30% reduction in recursion times (mostly from Optimization 2).

---

## Future Work (if gap remains)

1. Reduce state reload variables: After every CALL/RET, 9 local variables are reloaded. Some could be merged or deferred.
2. TVal get_tag() micro-optimizations: The NaN-box tag decode on every type check involves multiple branches.
3. Inline asm for the inner dispatch loop: C3's `asm` blocks support x86/aarch64 — could hand-roll the register-binding.
4. Prefetch activation array: `activations[MAX_CALLS]` is a dense array — prefetching could reduce cache misses on deep recursion.

# Jun 6 — Speed Optimization Plan #2 (Post-#12)

**Date:** 2026-06-06
**Baseline:** `benchmarks/results.txt` (2026-06-05) — C3 vs Duktape ratios
**Goal:** Close the remaining gap on recursion (3.1×), valstack_copy (2.4×), and function_call (1.5×).

## What's Already Done (from Plan #012)

| # | Fix | Status |
|---|-----|--------|
| 1 | Function-pointer dispatch table | ✅ commit 1e0001c |
| 3 | Skip env alloc in CALL fast path | ✅ commit 1e0001c |
| 4 | IC fast path (prop_value_ptr + cached_prop_alloc) | ✅ commit 081d1ea |
| 5 | memset instead of zero loop | ✅ commit 1e0001c |
| 6 | array_length fast field in HObject | ✅ commit 2d5a56c |
| 7 | FASTINT fast paths in ADD/SEQ/SNEQ | ✅ commit 771c249 |

All six items above are structurally correct and committed. Benchmarks are noise-masked but the fast paths are wired.

## Current Gap

```
  Benchmark                            C3(ms)  Duktape(ms)    Ratio
  --------------------------------------------------------------------------
  bench_recursion_deep             6248.0ms   1924.0ms      3.2x
  bench_recursion                  1416.0ms    458.0ms      3.1x
  bench_ic_monomorphic              741.0ms    281.0ms      2.6x
  bench_valstack_copy                29.0ms     12.0ms      2.4x
  bench_function_call               194.0ms    131.0ms      1.5x
  bench_array                        50.0ms     39.0ms      1.3x
```

The recursion gap is the largest single regression — every `fib(n-1) + fib(n-2)` allocates temporaries that survive until the next mark-and-sweep. Refcounting (#1 below) is the only fix that addresses the root cause.

## Remaining Items (ranked by expected speedup)

### 1. Wire refcounting on hot path

**Location:** `src/heap.c3` (HeapHeader), `src/types.c3` (TVal setter paths), `src/vm.c3` (register writes)

**Problem:** Every TVal that contains a heap pointer (string, object, buffer) is never freed until the next mark-and-sweep cycle. In recursion-heavy workloads, the heap accumulates thousands of garbage temporaries before GC runs, causing:
- More frequent GC sweeps (higher pause overhead)
- Larger heap → more cache misses during mark phase
- `valstack_copy` copies heap refs without decref on overwrite → old values leak

Duktape uses refcounting as the **primary** collector (immediate free on rc→0) with mark-and-sweep as the cycle backup. We have M&S fully implemented but zero refcounting.

**Fix:**
1. Add `uint refcount` to `HeapHeader` (heap.c3 header struct)
2. `hobject_alloc()` / `hstring_alloc()` init rc=1
3. Add `incref(void* heap_ptr)` / `decref(void* heap_ptr)` functions
4. Instrument every TVal.write path:
   - `TVal.set_object()` / `TVal.set_string()` → incref new, decref old
   - Register writes in vm.c3 → decref old before overwrite
   - `valstack_top` rollback on RET → decref spilled regs
   - `ensure_valstack` realloc → no decref (values are moved, not dropped)
5. `decref` on rc→0 frees immediately (strings, objects) except for cycle-prone types
6. Keep M&S as the cycle collector — it now only runs when a cycle is detected or heap growth triggers

**Expected impact:** recursion 3.1× → ~1.5×, valstack_copy 2.4× → ~1.2×, function_call 1.5× → ~1.1×.

**Effort:** 3 days. Touches every TVal assignment site. High risk of leaks if any path is missed.

**Risk mitigation:**
- Add `-D LEAKCHECK` build mode that triggers an immediate M&S after every `decref` and asserts all heap objects are accounted for
- Start with string refcounting only (strings are the most common heap type in benchmarks), then add objects
- Instrument counters: `total_inc`, `total_dec`, `total_free_on_zero`, `total_ms_runs`

---

### 2. RET opcode: avoid restart overhead with post-CALL continuation

**Location:** `src/vm.c3:4437-4466` (RET), `src/vm.c3:3128-3160` (CALL fast path tail)

**Problem:** Every `RET` sets `needs_restart = true` and `break`s out of the inner loop. The caller must re-enter the outer `for(;;)` + inner `for(; !needs_restart; )` + `switch(op)` to resume. For Fibonacci, this means 2·fib(35) ≈ 30M round-trips through the full dispatch chain just for call/return.

In the CALL fast path we already do direct dispatch (`act = new_act; continue;`) — the callee executes immediately without restart. But after RET, the caller **re-enters the switch from the top**, paying the full dispatch cost to reach the next opcode.

**Fix:** Store the caller's next PC in the callee's `Activation` at CALL time. On RET, jump directly:
```c3
// At CALL time:
new_act.caller_resume_pc = curr_pc + 1; // PC after this CALL
// At RET time:
act = &vm.activations[vm.activation_count - 1];
curr_pc = act.caller_resume_pc;
// Restore caller's code_base, regs_base, etc. from act
continue; // jump directly to next opcode, skip switch
```

We can't avoid restoring the caller's `code_base`/`regs_base`/`nregs` — those are per-function and must change — but we skip the outer loop restart and the switch, going directly to the opcode fetch at the top of the inner loop.

**Expected impact:** recursion 3.1× → ~2.3× (on top of current code, before refcounting).

**Effort:** 0.5 day. One new field on Activation, one branch in RET, one extra store in CALL.

---

### 3. IC monomorphic benchmark: diagnose the 2.6× gap

**Location:** `src/vm.c3:2149-2167` (GETPROP IC fast path), `benchmarks/bench_ic_monomorphic.js`

**Problem:** The IC fast path is wired and structurally correct, but `bench_ic_monomorphic` is still 2.6× slower than Duktape. The benchmark does property access on the same-shape objects — IC hit rate should be near 100%. Something is still paying too much per GETPROP.

**Hypotheses to verify (add instrumentation counters around vm.c3:2149-2167):**

| Check | Where | Expected |
|-------|-------|----------|
| IC hit rate | vm.c3:2160 — branch taken | >95% |
| `lookup_key` null rate | vm.c3:2155 | 0% (benchmark uses string literals) |
| Shape match rate | cached_prop_alloc comparison | >95% |
| `regs_base + ra` recompute cost | vm.c3:2162 | 2-3 instructions |

If hit rate is low: the IC entries aren't being populated correctly for the benchmark's pattern. Check whether the IC population at vm.c3 (slow path) is reached on the first access and whether the `shape_id` matches the object's actual shape.

If everything looks correct: the remaining overhead is just VM dispatch (switch + outer loop). That would push this into the same bucket as #4 below — only fixable by eliminating the switch dispatch overhead.

**Expected impact:** clear diagnosis (instrumentation only, no code change needed).

**Effort:** 1 day to add counters, run, analyze. Fix depends on findings.

---

### 4. Function-pointer dispatch for the main VM loop

**Location:** `src/vm.c3:1460-1530` (dispatch loops), `vm.c3:1536` (`switch (op)`)

**Problem:** Every opcode goes through `for(;;)` + `for(; !needs_restart; )` + `switch (op)`. C3 doesn't expose computed gotos, so we can't do Duktape-style direct threading. But we can do **call threading**: replace the switch with a table of function pointers, one per opcode. Each handler does its work and tail-calls the next handler.

```c3
// Per-opcode handler table:
fn void op_handler_N(VMCtx* ctx);

fn void op_LDREG(VMCtx* ctx) {
    // ... LDREG work ...
    op_handler_table[ctx.next_op()](ctx);
}
```

**Problem:** tail-call optimization is not guaranteed in C3, and per-opcode function calls add stack frames. For recursion-heavy code (like fib), this could actually make things worse — each opcode becomes a C function call with its own frame.

**Alternative — keep switch but reduce restart cost:**
- Merge the outer and inner loops into a single `for(;;)` with `switch(op)` directly
- Inline the most common opcodes (LOADVAR, STOREVAR, GETPROP, PUTPROP, ADD, SUB, RET) into the top of the dispatch loop, before the switch
- Use `__builtin_expect` / `@likely` on the fast-path branches

**Expected impact:** 1.1-1.3× on loop/arithmetic (broad). Less on recursion (call/return overhead dominates).

**Effort:** 1-2 weeks. High risk of correctness regressions — every opcode must be touched.

**Recommendation:** defer until refcounting is in place and we can measure the residual gap. If recursion is still >1.5× after refcounting, this is the next lever.

---

### 5. Last-string cache in activation frame

**Location:** `src/vm.c3:1824-1855` (SEQ string compare), `src/bytecode.c3` (Activation struct)

**Problem:** String `===` in the SEQ opcode calls `intern_string` for the lookup key, then does pointer identity on the interned result. For string-heavy code (JSON keys, property names), this is one heap lookup per comparison.

Duktape caches the last-interned string hash per activation frame.

**Fix:** add `HString* last_str_cache` + `uint last_str_hash` to `Activation`. In SEQ, before `intern_string`, check `last_str_cache != null && key_hash == act.last_str_hash` — if match, skip the intern lookup.

**Expected impact:** 1.05-1.1× on string-heavy workloads. Minimal on recursion.

**Effort:** half a day. Two fields on Activation, one branch in SEQ.

---

### 6. valstack_top recomputation on RET is redundant

**Location:** `src/vm.c3:4463-4464`

```c3
vm.valstack_top = act.bottom + ((CompiledFunction*)act.func).num_regs;
```

**Problem:** On every RET, we recompute `valstack_top` from `act.bottom + nregs`. But `valstack_top` was already correct at the time of the CALL (the caller's top was saved as the callee's frame base). We can restore it from a cached value instead of doing the multiply + add.

**Fix:** store `valstack_top` in `Activation` at CALL time, restore it on RET:

```c3
// At CALL time:
new_act.caller_valstack_top = vm.valstack_top;
// At RET time:
vm.valstack_top = act.caller_valstack_top;
```

**Expected impact:** micro (<5%). One arithmetic op saved per RET.

**Effort:** 10 minutes.

---

## Priority Order

| # | Fix | Effort | Expected Speedup | Targets |
|---|-----|--------|------------------|---------|
| 1 | Wire refcounting | 3d | 1.5-2× | recursion, valstack_copy, all alloc-heavy |
| 2 | RET restart avoidance | 0.5d | 1.3× | recursion, recursion_deep |
| 3 | IC monomorphic diagnosis | 1d | — (info) | ic_monomorphic |
| 4 | VM dispatch overhaul | 1-2w | 1.1-1.3× | everything (broad) |
| 5 | Last-string cache | 0.5d | 1.05× | string-heavy code |
| 6 | valstack_top cache on RET | 10m | micro | recursion |

**Execution order:** Start with #2 (quick win, low risk), then #1 (the big one). Run benchmarks after each. Defer #4 until we see the residual gap after #1.

## Validation

```bash
# After each fix:
just bench-rebuild
just bench

# Per-benchmark:
just bench-one benchmarks/bench_recursion.js 5
just bench-one benchmarks/bench_recursion_deep.js 5
just bench-one benchmarks/bench_valstack_copy.js 5
just bench-one benchmarks/bench_function_call.js 5
just bench-one benchmarks/bench_ic_monomorphic.js 5

# Correctness:
just quick
```

## Target Ratios (after this plan)

| Benchmark | Current | Target | Notes |
|-----------|---------|--------|-------|
| bench_recursion | 3.1× | ≤1.5× | #1 + #2 |
| bench_recursion_deep | 3.2× | ≤1.5× | #1 + #2 |
| bench_valstack_copy | 2.4× | ≤1.2× | #1 |
| bench_function_call | 1.5× | ≤1.1× | #1 |
| bench_ic_monomorphic | 2.6× | ≤1.5× | #3 diagnosis → fix |
| bench_array | 1.3× | ≤1.1× | (already close) |

## Risks

- **#1 (refcounting)** is high risk. Missing a single TVal write path = silent leak that only manifests on long-running programs. Mitigation: `-D LEAKCHECK` debug mode that runs M&S after every `decref` and asserts all heap objects have rc=0 (strings/objects) or are reachable from roots (cycles). Start with strings only, then generalize.
- **#2 (RET restart)** has zero correctness risk — we're just skipping a redundant dispatch layer. The caller's state is fully known at CALL time.
- **#4 (dispatch)** can regress correctness on edge cases — every opcode handler must be converted. Defer until #1 results are clear.

## Out of Scope (deferred to #014+)

- JIT compilation (beyond the project's scope — this is a faithful port, not a new engine)
- TVal size reduction (already 8 bytes NaN-boxed)
- ROM/flash support for builtins
- Specialized opcodes for `arguments`/spread/destructuring (compiler work once dispatch is fast)
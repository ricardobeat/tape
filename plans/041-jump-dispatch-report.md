# @jump Dispatch Investigation + Paths to Beat QuickJS

Worktree `jump-dispatch`, 2026-07-10. Experiment: annotate the main dispatch switch
(`src/vm/vm_execute.c3:814`) with C3's `@jump` attribute (computed-goto jump table).

## @jump results

One-word change: `switch (op) @jump {`. c3c accepted it as-is (the existing `default:`
satisfies exhaustiveness). Disassembly of `Vm.run` confirms a true jump table:
`ldr x13, [x13, w11, uxtw #3]; br x13` — indexed indirect branch, not a compare chain.

bench-fast, 3 iterations, aarch64 macOS:

| Benchmark | Baseline | @jump | Delta |
|---|---|---|---|
| bench_arithmetic | 192 ms | 120 ms | **−37.5%** |
| bench_string | 10 | 9 | −10% |
| bench_valstack_copy | 13 | 12 | −7.7% |
| bench_array | 25 | 24 | −4% |
| others | — | — | ±4% (noise) |
| **Total** | **2789** | **2723** | **−2.4%** |

Verdict: free win, keep it. Big effect only where dispatch dominates (tight arithmetic
loops); call/property/allocation-bound benchmarks are unaffected. This resolves plan 007's
open question — C3 *does* emit a real jump table for `@jump` (verified in asm), though the
single converging dispatch point remains (no per-handler replicated dispatch, so branch
predictors can't correlate opcode pairs the way hand-threaded interpreters allow).

## Where we stand vs QuickJS (benchmarks/results.txt, Jun 2026)

C3 now beats original Duktape almost everywhere, but is ~2–3.6× slower than QuickJS on
most benchmarks, with one huge outlier:

| Benchmark | C3/QJS ratio |
|---|---|
| bench_arithmetic | **9.3×** (pre-@jump; ~6× after) |
| bench_ic_monomorphic | 3.6× |
| bench_object | 3.3× |
| bench_array | 3.1× |
| bench_loop, bench_recursion(_deep), bench_ic_proto | ~2.7–2.8× |
| bench_memory_heavy | 2.5× |
| bench_string | 2.0× |
| bench_valstack_copy | 1.8× |
| bench_property_lookup | 0.17× (we win) |

## Paths to close the gap, ranked by expected value

1. **Fastint-specialized arithmetic opcodes** (plan 012 #7, never implemented) — the 9×
   arithmetic outlier. Every binary op currently decodes both operand tags via the
   `get_tag()` switch (`src/types.c3:186`) before the fastint fast path. QuickJS emits
   int-specialized opcodes and/or checks both tags with one masked compare. Options:
   compiler-emitted ADD_INT/SUB_INT when types are inferable, or a combined
   `(a.raw | b.raw)` tag test that falls into the int path with a single branch.
   Highest single-benchmark payoff in the suite.

2. **Superinstructions / opcode fusion** — extend the existing `jit_scan` peephole
   (`src/jit.c3`, currently only GETPROPC chain fusion) to fuse hot pairs: cmp+branch
   (LT+JMPF), LDINT+arith, INC_VAR-style patterns already proved the concept. Cuts
   dispatches per loop iteration, which @jump just made cheaper but not free.

3. **Call-path slimming** — recursion/function_call still ~2.7×. Register-locals already
   banked the big win; remaining cost is the RET restore + `decref_callee_regs`
   (`vm_execute.c3:747-795`) and per-call Activation setup. Candidates: HALT/RET sentinel
   to drop the per-instruction `code_end` bounds check (`:747`), and a leaf-call fast path
   that skips activation fields unused by non-closure callees.

4. **IC hit path tightening** — monomorphic IC is 3.6× despite the ultra-fast path.
   The hit path does three sequential loads/compares (key, shape_id, prop_alloc,
   `src/vm/vm_property.c3:35-37`). Collapsing validation to shape_id+prop_alloc (as the
   self-modifying GETPROPC_CACHED already does) everywhere, and caching `get_class()`
   results on the miss path, are cheap wins.

5. **Flat Latin1/UTF-16 strings** (BACKLOG B55) — eliminates CESU-8's byte overhead and
   the per-exec CESU-8→UTF-16 conversion that dominates bench_regexp. Large project;
   biggest structural item after the interpreter-core work.

6. **Refcount traffic** — already mitigated (non-heap skip, max_heap_reg early-out).
   Remaining idea: deferred/coalesced RC in the LDREG/MOV family, but register-locals
   notes call the current floor "dispatch/refcount", so revisit only after 1–3.

Out of scope per project direction: a real JIT (plan 013: faithful port, not a new engine).

## State

The `@jump` edit is applied in this worktree (uncommitted), sanity-checked and benchmarked.

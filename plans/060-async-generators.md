# Plan 060 — Async Generators (`async function*`)

**Status**: PLANNED (session 289b). Scheduled AFTER the current 42-fail cleanup and plan 059 Phases 2-4 — those are smaller and unblock more per unit of risk.
**Payoff**: un-skips 168 for-await-of fixture tests + the ~2,000 structurally-skipped `*async-gen*` tests; removes the "excluding async generators" asterisk from the conformance number. True 100% of the targeted suite becomes reachable.
**Until this lands**: all four syntax forms parse-reject with SyntaxError (session 289b — better loud than the prior silently-broken objects), and the runner skips async-generator tests structurally (SKIP_GLOBS `*async-gen*`, `*async-private-gen*`, `language/statements/for-await-of/async-func-dstr-*-async-*`, plus the three `built-ins/AsyncGenerator*`/`AsyncFromSync*` dirs).

## What already exists (reuse, don't rebuild)

- **Suspend/resume machinery**: async functions run ON the generator infrastructure — `is_async` forces `is_generator=true` at compile (`functions.c3` inner-compile) and `await` uses AWAIT+LOAD_RESUME suspends. GeneratorState (register save/restore, `this_binding`, resume via call_fn, `async_promise`), GEN_START/RET_GEN, throw-unwind → GEN_COMPLETED (see memory `generator-completed-on-throw`; an `async_gen_state` link already exists there).
- **Promise machinery**: spec-solid post-session-281 (capabilities, PromiseResolve, microtask queue, IfAbruptRejectPromise).
- **Async iterator protocol**: GET_ITER_ASYNC / ITER_CLOSE_ASYNC opcodes + `%AsyncFromSyncIteratorPrototype%` adapter (`src/builtins/async_from_sync.c3`), for-await consumer codegen incl. destructuring (plan 057).
- **Sync generator object surface**: prototype with next/return/throw, "Generator is executing" reentrancy guards — the shape to mirror.

## The two genuinely new pieces

1. **Two suspend kinds in one body.** An async-gen body suspends *internally* at `await` (resume via microtask; invisible to the caller) and *externally* at `yield` (settle the current request's promise with `{value, done:false}`). Today the resume driver (`src/vm/vm_generators.c3`, ~1,400 lines) conflates them because an async fn only ever awaits. The driver must branch on suspend kind. **This is the risk concentration** — that file is refcount-sensitive and has hosted most past subtle bugs; every change gates on ASan + the golden suite + the generator/async local tests.
2. **The request queue** (§27.6.3.1 AsyncGeneratorEnqueue). Sync generators throw on reentry; async generators queue concurrent `next()/return()/throw()` calls, each returning its OWN promise, drained FIFO. Self-contained: a linked list of `{completion_kind, value, promise_capability}` on the async-gen state + a drain loop that runs after each settle. States per spec: SUSPENDED_START / SUSPENDED_YIELD / EXECUTING / AWAITING_RETURN / COMPLETED.

## Phases

### A — Flag disentanglement + parse acceptance (compiler)
Make `is_async` and `is_generator` orthogonal (the current `is_async ⇒ is_generator` overload is documented in-code as a deliberate conflation; see also memory `ctx-is-async-conflation` — pass explicit params, never latch). Introduce the true async-generator kind (both bits + a distinguishing predicate, e.g. `is_async_gen() = is_async && is_user_generator`, replacing the `is_generator && !is_async` idiom scattered in the VM — grep for that idiom and route through ONE predicate). Remove the four parse rejections (functions.c3 function_expression, statements.c3 function_declaration, class.c3:495, expressions.c3 object-literal method). `await` and `yield` both legal in the body; `for await` legal. Non-constructable. `.prototype` → %AsyncGeneratorPrototype%-linked object per §27.4.3.2.

### B — AsyncGenerator object + request queue (runtime, new file `src/builtins/async_generator.c3`)
- Prototypes at heap init: `%AsyncGeneratorFunction%` (proto = Function.prototype), `%AsyncGeneratorFunction.prototype%` = `%AsyncGenerator%`, `%AsyncGenerator.prototype%` (proto = `%AsyncIteratorPrototype%` — create it; `@@asyncIterator` returning `this` lives THERE per §27.1.3) with promise-returning `next`/`return`/`throw` + `@@toStringTag: "AsyncGenerator"`.
- Calling an async-gen function returns the generator object in SUSPENDED_START without running the body (same shape as sync GEN_START path).
- `next/return/throw` = AsyncGeneratorEnqueue: always return a promise; push request; if state != EXECUTING/AWAITING_RETURN, drain. COMPLETED state answers `next` with `{undefined, true}`, `return` runs the §27.6.3.7 await-return dance, `throw` rejects.

### C — Resume driver: yield-vs-await (vm_generators.c3)
- AWAIT in an async-gen body: unchanged mechanics (suspend, microtask resume).
- YIELD in an async-gen body = AsyncGeneratorYield §27.6.3.8: **await the operand first**, then settle the CURRENT request's promise with `{value, done:false}`, transition SUSPENDED_YIELD, drain queue.
- RET: settle current request `{value, done:true}` (value awaited per §27.6.3.5.a), state COMPLETED, drain remaining requests with `{undefined, true}`.
- Throw unwind: reject current request's promise, COMPLETED, drain (reuse the existing GEN_COMPLETED unwind chokepoint — extend, don't fork).
- resume-with-return (consumer `.return()` / for-await early exit): resume the body with a return completion so `finally` blocks run; if the body re-suspends at an await inside finally → AWAITING_RETURN.

### D — Async `yield*` (codegen, not a new opcode)
Sync YIELD_STAR can't be reused (sync protocol). Emit a delegation loop in the compiler instead — consistent with plan 057 Phase 0's decision to inline iterator protocol as codegen: GET_ITER_ASYNC on the operand → loop { call next → AWAIT → done? break : YIELD }, with return/throw forwarding per §27.6.3.8 (forward to inner `.return`/`.throw` when present, ITER_CLOSE_ASYNC semantics otherwise). Note most of the 168 tests use `yield* [array]` — sync iterable through AsyncFromSync — so this phase is REQUIRED for the headline payoff.

### E — Un-skip + conformance tail
Remove, in order, measuring each: (1) the `async-func-dstr-*-async-*` glob (168 tests — should pass after C+D); (2) `built-ins/AsyncGeneratorFunction/*` + `built-ins/AsyncGeneratorPrototype/*` + `built-ins/AsyncFromSyncIteratorPrototype/*`; (3) the broad `*async-gen*` globs (~2k tests: method forms across class/object, static, dstr variants). Budget as much time here as for A-D combined — queue/return/throw interleavings and per-request promise ordering are the fiddliest spec surface. Also revisit: `async-iteration` feature entries, `esid: await-script` / async-generator-methods CE leftovers, and the AsyncFromSync `ticks-*` fidelity fixes (separately tracked in BACKLOG, no async generators needed).

## Test strategy

Local battery first (`test/test_async_gen.js`, mirroring `test/test_for_await.js` style): creation without execution, next/yield round-trip, queued concurrent next(), await-inside-body, yield*-over-sync and over-async sources, return()-through-finally, throw() rejection, for-await consumption incl. early break. Then phase-scoped test262 (`--phase 24` + Classes phase for methods), never full-suite-first (memory `avoid-full-test262-runs`). ASan runner on the battery for every vm_generators.c3 change. Golden bytecode: new emission shapes for yield-in-async-gen and async yield* need `--check-noop` inspection before regen.

## Estimate

A: small (≤1 session, mostly deletions + a predicate). B: ~1 session (mechanical, patterns exist). C: the risky one — 1 session if clean, 2 with the usual vm_generators refcount surprises. D: ~half session (codegen mirror of for-await consumer). E: 1-2 sessions of conformance grind. **Total: 3-5 sessions.** No hot-path perf impact expected (cold paths only) — bench-fast gate anyway.

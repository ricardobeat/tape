# Plan 034: Implement async/await and related ES2017+ async features

## Goal

Implement `async function`, `await`, and the related Promise built-ins so real-world JS async code runs correctly. The project is no longer a strict Duktape port: QuickJS can be used as a reference and we can choose the simplest, most C3-idiomatic implementation that passes tests.

## Background

- `BACKLOG.md` lists **async/await** as the last unimplemented ES6+ intentionally-planned feature.
- `Promise` exists (`src/builtins/promise.c3`) but stores internal state in `array_part[0..N]`, which is fragile and corruptible by user code.
- `Generator` exists (`src/builtins/generator.c3`) but is largely untested (phase 21 tests are skipped). We will **not** block async/await on a fully working generator path.
- Modern engines implement async/await in three main ways:
  1. **Compiler desugaring to Promise chains** — `async function` is lowered to a normal function returning a Promise, with `await x` transformed into `Promise.resolve(x).then(resume_cb, reject_cb)` and state variables. This is what Babel and older Node versions do; it requires no VM coroutine support.
  2. **Generator-based state machine** — reuse `function*` / `yield` machinery. More faithful to spec execution semantics but depends on a solid generator VM.
  3. **Resumable execution** — the function's stack frame (registers, PC, env) is saved to a heap-allocated struct on suspend and restored on resume. This is what QuickJS and V8 use.

We use **(3) resumable execution**, reusing the existing `GeneratorState` struct for state save/restore. The `AWAIT` opcode saves state, creates resume/reject callbacks, and pops the activation. When the Promise settles, the resume callback calls `vm_call_fn_impl` which detects `resume_gen` and restores the saved state.

**Note**: async generators (`async function*`) will NOT be implemented.

## Implementation Strategy

### Phase A — Promise internals that can survive user code

1. **Move Promise state out of `array_part`**
   - Add dedicated internal slots on `HObject` or use a `PromiseState` GC-allocated struct.
   - Use hidden/internal property keys (e.g. well-known symbol-like internal names or a new hidden-string mechanism) so user code cannot observe or corrupt state.
   - Track state (pending/fulfilled/rejected), result, and a list of reaction records.
   - Update `promise.c3` helpers and GC marking.

2. **Implement a microtask queue**
   - Add a per-`Heap` FIFO queue of pending reaction callbacks.
   - Provide `enqueue_microtask(callback, resolution_value)` and `run_all_microtasks()`.
   - Drain microtasks after each top-level script/REPL evaluation, after `eval()`, and after built-in Promise resolution.
   - A reaction callback can enqueue more reactions; drain until the queue is empty.

3. **Complete core Promise API**
   - `Promise.prototype.then` / `.catch` / `.finally`.
   - `Promise.resolve` / `Promise.reject`.
   - `Promise.all` / `Promise.race`.
   - Optionally `Promise.allSettled`, `Promise.any`, `AggregateError`, `Promise.withResolvers`.

### Phase B — Compiler desugaring for async/await

4. **Parse `async function`**
   - Treat `async` as a contextual keyword.
   - Disambiguate `async function` from `async (x) => ...` arrow functions.
   - Support declarations, expressions, methods, and class methods.
   - Mark the compiled function as async (for `typeof`, `new` rejection, etc.).

5. **Parse `await`**
   - Only valid inside async functions and modules.
   - SyntaxError if used in non-async contexts.
   - Unary precedence, tighter than `**` but looser than postfix.

6. **Lower async functions to Promise chains**
   - On entry, create a Promise `p` and a resolver/rejector pair.
   - Each `await expr` becomes:
     - Save local state to closure-captured variables or an explicit state object.
     - Return `Promise.resolve(expr).then(step_n, reject)` from the current continuation.
     - `step_n` resumes execution with the awaited value.
   - `return x` resolves `p` with `x`.
   - `throw x` rejects `p` with `x`.
   - Try/catch/finally inside async functions become `.then(...).catch(...)` chains where appropriate.

   Because the compiler already emits bytecode rather than an AST-to-JS transform, the lowering should be done at the bytecode level:
   - Introduce a small set of async helper opcodes or use existing opcodes plus explicit calls to Promise builtins.
   - Alternatively, generate explicit bytecode that calls `Promise.resolve`, `.then`, and closure functions for each resume point. This is more bytecode but avoids new VM primitives.

7. **Async function invocation**
   - `CALL` must return the Promise immediately.
   - `new async function()` must throw TypeError.
   - `typeof` an async function returns `"function"`.

### Phase C — Microtask correctness

8. **Ensure `await` yields to the microtask queue**
   - Even `await value` on a non-thenable must schedule the resume through the microtask queue.
   - This is critical for async ordering tests.

9. **Top-level script boundaries**
   - After `run_script`, `eval`, and any built-in eval boundary, drain microtasks before returning control to the caller.

### Phase D — Related features (optional but high-value)

10. **Static Promise helpers**
    - `Promise.allSettled` (ES2020).
    - `Promise.any` + `AggregateError` (ES2021).
    - `Promise.withResolvers` (ES2024).

11. **Async iteration (future plan)**
    - `Symbol.asyncIterator`, `for-await-of`, async generators.
    - Keep out of this plan unless time permits; scope separately.

## Testing Strategy

- Add Rosetta tests for:
  - Basic async/await: `async function f() { return 1; } f().then(v => assert(v===1))`.
  - Await a Promise: `async function f() { return await Promise.resolve(2); }`.
  - Async rejection: `async function f() { throw 3; } f().catch(e => assert(e===3))`.
  - Await in loops, conditionals, and try/catch.
  - `async function` is not constructible.
  - Microtask ordering: synchronous code runs before `then` callbacks; chained `then`s run in order.
- Update `test262_skip.cfg` to unskip relevant `AsyncFunction`, `statements/async-function`, and `expressions/async-function` tests as implementation progresses.
- Run `python3 scripts/phase_runner.py 17 --workers 2 --timeout 10` after each Promise change to catch regressions.

## Risks

- **Promise state refactor** may regress existing phase 17-20 tests; run the full suite frequently.
- **Bytecode-level desugaring** can generate many closure functions; watch for memory leaks and GC rooting issues.
- **Microtask draining at wrong boundaries** can change observable ordering; follow QuickJS/Babel semantics where possible.
- **Try/catch/finally inside async functions** is the trickiest part of the desugaring; test exhaustively.

## Files Likely to Change

- `src/builtins/promise.c3` — state refactor, microtask enqueueing, static helpers.
- `src/heap.c3` — microtask queue fields and draining.
- `src/vm.c3` — async function call handling, microtask drain points.
- `src/bytecode.c3` — async opcodes if any.
- `src/compiler/parser.c3` / `src/compiler/statements.c3` / `src/compiler/expressions.c3` — `async`/`await` parsing.
- `src/compiler/functions.c3` — async function compilation and desugaring.
- `src/types.c3` — async function flag.
- `scripts/test262_skip.cfg` — unskip tests as features land.
- `BACKLOG.md` — mark async/await complete.

## Success Criteria

- [ ] Promise internal state survives `Object.keys`/numeric writes.
- [ ] Microtask queue exists and `Promise.resolve().then(cb)` calls `cb` asynchronously.
- [ ] `async function` parses and returns a Promise.
- [ ] `await` suspends execution and resumes with the resolved value.
- [ ] Thrown errors inside async functions reject the returned Promise.
- [ ] `new async function()` throws TypeError.
- [ ] Phase 17-20 failure count does not increase.
- [ ] New Rosetta async/await tests pass.

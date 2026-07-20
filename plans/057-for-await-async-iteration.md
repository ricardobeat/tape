# Plan 057: `for await` / async iteration (ES2018)

> **Status (2026-07-20):** Not started. Scoping doc.
>
> Motivation: `for await (... of ...)` is entirely unimplemented — even
> `for await (const v of [1,2,3])` fails to parse ("expected '(', got 'await'").
> This blocks the `for-await-of` and top-level-await `for await` test262 family.
> Surfaced while fixing the top-level-await export cluster (commits `88c517c`,
> `7ac0768`, `c01204f`), where 3 of 6 fails were the runnable export cases (now
> fixed) and the remaining `for-await-of` cases are gated behind this feature —
> the suite already SKIPs them via `features: [async-iteration]`, so they are
> deferred, not regressions.

## Scope

**In scope — the ES2018 async-iteration *consumer*:**
- `for await (LHS of expr)` statement, in all LHS forms the sync for-of already
  supports: `var`/`let`/`const` binding, bare identifier, and destructuring
  patterns (array/object, incl. defaults + rest).
- Async-iterator protocol: `GetIterator(expr, async)` — look up
  `@@asyncIterator`; if absent, fall back to `@@iterator` wrapped in an
  `%AsyncFromSyncIteratorPrototype%` adapter (§27.1.4.1) so sync iterables
  (arrays, generators) work under `for await`.
- `await` the result of each `.next()` call (it returns a Promise of an
  IteratorResult) and of `AsyncIteratorClose`.
- Valid only inside an async function/method or at module top level
  (`is_async`); a parse error otherwise.

**Out of scope (separate deferred features — keep failing / skip-listed):**
- **Async generators** (`async function*`, `yield` in async) — already rejected
  at parse (`class.c3:491`). A for-await *source* can be any async iterable, so
  we do NOT need async generators to land this; tests that also require an
  async-generator source stay deferred.
- `Symbol.asyncIterator` as a user-facing writable well-known symbol beyond
  what the protocol lookup needs (the cached `heap.asynciterator_symbol`
  already exists — heap.c3:355).
- `noStrict`-flagged for-await tests — unfixable in a strict-only engine.

## What already exists (build on this)

- **Sync for-of codegen** (`statements.c3` `for_statement` + the
  `emit_bare_forof_*` / destructuring paths): `INITFOR` (set up iterator) →
  `NEXTFOR` (produce iter var + has_next) → body → back-jump → `ITER_CLOSE`.
  `loop_stack[].iter_close_reg` tracks the close target for break/return.
- **Iterator protocol opcodes** in `vm_control.c3`: `INITFOR`/`NEXTFOR`
  (`dispatch_iterator`, line 388) and `ITER_CLOSE` (line 948). These do the
  sync `@@iterator` / `.next()` / `.return()` dance.
- **`await` suspension** — `AWAIT` + `LOAD_RESUME` opcodes
  (`expressions.c3:3003`), reusing the generator save/restore path
  (`functions.c3:2572` sets `is_generator` for async). The VM can already
  suspend/resume an async activation mid-body at any `AWAIT`.
- **`@@asyncIterator` symbol** cached + GC-rooted (`heap.c3:355,1967`).
- **Module top-level is async** (`entry.c3:307` sets `ctx.is_async = true`), so
  top-level `for await` is a first-class case once the statement parses.

## Design

### Parser (`statements.c3`, `for_statement`)
After `expect(FOR)`, peek for `await`:
- Only when `self.is_async` — else `fail("'for await' is only valid in an "
  "async function or module")`.
- Consume `await`, set a local `is_await = true`, then expect `(` and proceed
  through the **existing** for-of parse paths, threading `is_await` down so the
  of-detection branch emits async opcodes. Reject `for await (... in ...)`
  (async-iteration has no for-in form) and `for await (...;...;...)`.

### New opcodes (mirror the sync trio, async-aware)
Rather than overload `INITFOR`/`NEXTFOR` with a flag (they already carry the
for-in/for-of duality), add three siblings so the async path is explicit and
the sync path is untouched:
- `INITFOR_ASYNC ra, rb` — `GetIterator(ra, async)`: `@@asyncIterator` else
  sync-wrapped `@@iterator`; store iterator record in `rb`. This call itself
  may be sync (no await needed for GetIterator).
- `NEXTFOR_ASYNC iter_var, promise_out, iter_state` — call `.next()`, leaving
  the returned **Promise** in `promise_out`. Codegen then emits
  `AWAIT promise_out` + `LOAD_RESUME result`, unpacks the IteratorResult
  (`done`/`value`) — reuse a small `ITERRESULT_UNPACK` or inline GETPROPs — and
  branches on `done`.
- `ITER_CLOSE_ASYNC` — `AsyncIteratorClose`: call `.return()`, then codegen
  awaits the returned promise before propagating the completion.

Alternative considered: a single `is_async` immediate on the existing opcodes.
Rejected — `NEXTFOR` currently returns the value directly, but the async form
must return a *promise to await*, a different codegen shape; a separate opcode
keeps the sync hot path and its inline caches pristine (cf. the descriptor-table
lesson — avoid overloading a hot dispatch with a rarely-taken flag).

### Codegen shape (per iteration)
```
INITFOR_ASYNC obj -> iter_state          ; GetIterator(obj, async)
loop_start:
  NEXTFOR_ASYNC iter_state -> nextPromise ; iter.next()
  AWAIT nextPromise ; LOAD_RESUME result   ; await the step
  result.done ? -> exit                     ; unpack IteratorResult
  <LHS> = result.value                      ; bind (reuse for-of LHS emit)
  <body>
  JUMP loop_start
exit:
```
Break/return inside the loop route through `ITER_CLOSE_ASYNC` (await the
`.return()` result) — extend the `iter_close_reg` unwinding in
`emit_iter_close_for_enclosing` / `break_statement` to pick the async close
opcode when the loop is a for-await (add an `is_await_loop` bit to `loop_stack`).

### AsyncFromSyncIterator adapter
When only `@@iterator` exists, wrap it so `.next(v)` calls the sync
`.next(v)`, then `Promise.resolve`s the result's `value` and re-wraps as
`{ value, done }` (§27.1.4.2.1). Two options:
1. A real `%AsyncFromSyncIteratorPrototype%` object built at heap init (closest
   to spec, reusable).
2. Handle the wrapping inside `NEXTFOR_ASYNC` when the iterator record is flagged
   sync-origin (less machinery, no new prototype object).
Prefer (2) for the first landing (smaller surface), leaving (1) as a refactor if
a test needs the observable adapter object.

## Phases

1. **Parser + reject-cases** — `for await` recognized in async/module, errors
   elsewhere; wire `is_await` through the of-detection branches. Land with a
   temporary "not yet implemented" codegen stub that compiles the simplest
   `for await (const v of asyncIterable)` to the new opcodes (opcodes stubbed).
2. **VM opcodes** — `INITFOR_ASYNC` (GetIterator async + sync fallback flag),
   `NEXTFOR_ASYNC` (call next → promise), `ITER_CLOSE_ASYNC`. Unpack
   IteratorResult. Validate with a hand-written async-iterator object test.
3. **Await wiring + sync-iterable fallback** — emit AWAIT/LOAD_RESUME around
   each step; AsyncFromSync wrapping so `for await (x of [1,2,3])` works.
4. **LHS parity** — destructuring patterns, bare identifier, let/const per-iter
   scoping; break/return → `ITER_CLOSE_ASYNC`.

## Validation

- `test/` async-iteration fixtures: `for await` over (a) a hand-written async
  iterable, (b) a plain array (sync fallback), (c) early `break`/`return`/throw
  (async close runs), (d) destructuring LHS.
- Un-skip `language/statements/for-await-of/**` and
  `language/module-code/top-level-await/**` that are `features:[async-iteration]`
  (drop `async-iteration` from `UNSUPPORTED_PATTERN` for the consumer tests;
  keep it for async-generator-source tests). Diff vs baseline: require net
  positive, 0 regressions. Note the `noStrict` for-await tests stay skipped.
- Rosetta 100/0; no Phase 15 (classes) / Phase 21 (generators) regression — the
  async save/restore path is shared.

## Estimated size

~300–450 lines across `statements.c3` (parse + codegen), `bytecode.c3` (3
opcodes + disasm), `vm_control.c3` (3 handlers + AsyncFromSync), `heap.c3`
(adapter proto if option 1). A real feature, not a quick fix — the payoff is the
whole async-iteration consumer surface, not just the 2 residual tests.

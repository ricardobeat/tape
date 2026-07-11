# Plan 051 — Async Iteration (`for await…of`, async generators, `Symbol.asyncIterator`)

Status: PLANNED (session 276). Scoped against the live tree. The ES2018 async-iteration
family is currently feature-flag-skipped (`scripts/run_test262.py:138`, regex
`async-iteration|Symbol\.asyncIterator`). The runner comment there notes these produced
**~1,249 unintended CEs** before the skip. Landing this deliberately grows the subset
(plan 040 no-silent-shrinkage rule).

This plan is written to be picked up cold. It gives exact file:line anchors, the existing
machinery to reuse, the opcodes to add, and a sequenced task list with validation.

## Why / scope

| Surface | Tests | Notes |
|---|---|---|
| `language/statements/for-await-of` | 1,234 | The bulk; most share fixtures with sync for-of |
| `features: [async-iteration]` (all) | 4,968 raw | Overlaps async/await + generators; realistic net-new executable after this lands ≈ the ~1,249 currently CE'd, plus a slice of the for-await-of dir |

Three JS features, one subsystem:
1. **`for await (x of asyncIterable) { … }`** — the async for-of statement.
2. **`async function* () { … }`** — async generators (both `yield` and `await` in one body).
3. **`Symbol.asyncIterator`** — the well-known symbol + the async-iterator protocol
   (`next()`/`return()`/`throw()` each return a Promise of `{value, done}`).

Real-world motivation: `for await…of` shows up in streaming APIs — `ReadableStream`
consumption, Node stream async iterators, paginated SDK clients (AWS SDK v3 paginators,
some DB cursors). Less ubiquitous than Proxy (plan 050), more than BigInt (plan 038).

### Out of scope
- Async-from-sync-iterator wrapping edge cases beyond the basic adapter (spec §27.1.4.1)
  can be a follow-up, but the basic adapter **is** needed (see D4) because `for await` over
  a *sync* iterable is legal and common.
- Top-level `await` in modules is a separate concern (module system), not this plan.

## Existing machinery to reuse (do NOT rebuild)

The suspend/resume state machine and `await` already exist. Async iteration *composes*
them; there is no new coroutine engine to write.

- **`AWAIT` opcode** — src/vm/vm_generators.c3:135. Already: unwraps settled Promises
  inline, coerces thenables via `promise_coerce_thenable`, suspends on a pending Promise
  and resumes with the fulfilled value / throws the rejection. Reuse verbatim.
- **`YIELD` / `YIELD_STAR` / `LOAD_RESUME`** — src/vm/vm_generators.c3:17+. Generator
  suspension, `resume_gen`, `yield_value`, `did_yield` on the heap.
- **Generator state** — `GeneratorState`, `GEN_COMPLETED`, `async_gen_state` link
  ([[generator-completed-on-throw]] documents the throw→GEN_COMPLETED rule; async
  generators must honor the same invariant).
- **Async function return** — `RET_GEN`/`RETUNDEF_GEN` vs `RET`/`RETUNDEF` selection at
  src/compiler/statements.c3:2470,2476 keyed on `is_generator && !is_async`. An async
  generator is `is_generator && is_async` — a **new fourth quadrant** these lines don't
  yet handle correctly.
- **Sync for-of emission** — the manual iterator-protocol codegen at
  src/compiler/statements.c3:1250-1320 (outer setup) and the per-iteration `next()`/
  `done`/`value` reads (:1285/:1303/:1309, mirrored in `emit_forof_loop` and
  `emit_forof_loop_member` at :2140/:2158/:2164 and :2305/:2322/:2328). **This is the
  template for `for await`** — see D3.
- **Promise internals** — `promise_get_state`, `promise_get_result`,
  `promise_coerce_thenable`, `PROMISE_FULFILLED/REJECTED` (src/builtins/promise.c3),
  plus the NewPromiseCapability machinery used by combinators.
- **`ensure_*_symbol` pattern** — e.g. `ensure_iterator_symbol`, `ensure_matchall_symbol`
  in src/builtins/symbol.c3, cached on the heap and GC-rooted (heap.c3:1890+). Add
  `ensure_async_iterator_symbol` the same way.

## Design

### D1. `Symbol.asyncIterator`

Add a cached well-known symbol mirroring `Symbol.iterator`:
- `ensure_async_iterator_symbol(heap)` in src/builtins/symbol.c3, cached in a new heap
  field `async_iterator_symbol` (heap.c3, next to `unscopables_symbol` at heap.c3:315),
  GC-rooted at heap.c3:1890-1892.
- Install `Symbol.asyncIterator` as a data prop on the `Symbol` constructor object
  (same place `Symbol.iterator` / `Symbol.matchAll` are installed).

### D2. Async generators — the object + protocol

An async generator instance is created by calling an `is_generator && is_async` function.
It is **not** a Promise and **not** a plain generator; it needs its own class or a flag on
the generator object.

Recommended: reuse `ObjClass.GENERATOR` + a bool on `HObjectGenerator`
(src/hobject.c3, the generator extra struct) — `is_async_gen` — rather than a new
ObjClass, so the existing generator trace/resume paths apply. The distinguishing behavior
lives in the prototype and in how `next()` returns.

`%AsyncGeneratorPrototype%` (new intrinsic):
- `next(v)` / `return(v)` / `throw(e)` — each returns a **Promise**. Internally: enqueue a
  request, drive the generator body one step; on `yield expr`, the yielded value is first
  `await`ed (async generators await the operand — spec §27.6.3.8 AsyncGeneratorYield),
  then the step's Promise resolves to `{value, done:false}`; on completion resolve
  `{value, done:true}`; on throw reject.
- `[Symbol.asyncIterator]()` returns `this`.
- An internal **request queue** (AsyncGeneratorRequest list) so overlapping
  `next()` calls serialize — store head/tail on the generator extra or a side object,
  mirroring how Promise reactions are a linked list (src/hobject.c3 HObjectPromise).

Compiler side:
- Parser already tracks `is_async` and `is_generator` independently
  (src/compiler/statements.c3:202-204, :3108-3135; functions.c3:1256-1268 detects
  `async function`). Confirm `async function*` and `async *method()` set **both** flags —
  add parse coverage where missing (async generator *methods* in classes/objects at
  class.c3:481-490 currently *reject* `is_generator_method && is_async_method`; that guard
  must be lifted for async generators).
- Return-opcode selection (statements.c3:2470-2476): the async-generator quadrant
  (`is_generator && is_async`) must emit the generator-return path (`RET_GEN`) so the body
  suspends, **and** the completion must resolve the current request's Promise. Introduce
  the distinction rather than the current binary check.
- `yield` inside an async generator compiles to: evaluate operand → `AWAIT` it → `YIELD`
  the awaited value. (Two existing opcodes in sequence; no new opcode needed for basic
  yield. `yield*` delegation to an async iterable is the harder sub-case — see Risks.)

### D3. `for await…of` statement

Parse: after `for`, accept an optional `await` keyword (only legal inside an async
function/async generator — error otherwise). Thread a `for_await` bool into the for-of
parse path at src/compiler/statements.c3:898+ and into `emit_forof_loop` /
`emit_forof_loop_member` (add a param; today they take `is_lexical, is_const, bare`).

Codegen delta vs sync for-of (the template at statements.c3:1250-1320) — **four changes**:
1. **Iterator acquisition**: instead of `Symbol.iterator` (emitted at statements.c3:1263-
   1271), use `Symbol.asyncIterator`. Per spec §13.7.5.13, if `Symbol.asyncIterator` is
   `undefined`, fall back to `Symbol.iterator` and wrap the result in an
   **async-from-sync iterator** (D4). Simplest correct impl: emit a runtime helper call
   `GetAsyncIterator(obj)` (a new tiny builtin) that does this lookup + wrap and returns
   the async iterator, rather than open-coding the fallback in bytecode.
2. **`next()` result is a Promise**: after the `CALL` that invokes `next` (statements.c3
   ~:1300, the `result_reg` CALL), emit `AWAIT result_reg` before reading `done`/`value`.
3. **`value` may itself need awaiting**: no — per spec the awaited `next()` result's
   `value` is already the resolved value; only the iterator-result object is awaited, not
   its `.value` a second time. (Do **not** double-await.)
4. **Async iterator close**: on early exit (break/return/throw), `IteratorClose` becomes
   `AsyncIteratorClose` — call `return()` and `AWAIT` its result. The existing
   `ITER_CLOSE` opcode (vm_execute.c3:2646) needs an async variant or a `for_await` flag
   so it awaits the `return()` Promise.

### D4. Async-from-sync iterator adapter (spec §27.1.4.1)

Needed because `for await` over a plain (sync) iterable is legal. `CreateAsyncFromSyncIterator`
wraps a sync iterator so its `next()` returns `Promise.resolve({value: await syncValue,
done})`. Implement as an internal object (new small ObjClass or a flagged OBJECT) whose
`next`/`return`/`throw` call the underlying sync iterator and wrap results in resolved
Promises, awaiting the `value`. Its `next()` is what `GetAsyncIterator` (D3.1) returns for
a sync-only iterable.

### D5. `AsyncIterator` / intrinsics housekeeping

- `%AsyncIteratorPrototype%` with `[Symbol.asyncIterator]()` returning `this`; make
  `%AsyncGeneratorPrototype%` and the async-from-sync iterator inherit it.
- `%AsyncGeneratorFunction%` intrinsic + `.constructor` wiring so
  `(async function*(){}).constructor` and `Object.getPrototypeOf` chains match spec.
  (Several test262 tests probe these prototype chains specifically.)

## Sequenced task list (for an agent picking this up)

1. **Symbol.asyncIterator** (D1) — smallest, unblocks everything. Validate:
   `typeof Symbol.asyncIterator === "symbol"` and it's the same value each access.
2. **Async-from-sync adapter + `GetAsyncIterator` builtin** (D4, D3.1). Validate in
   isolation with a hand-written sync iterable.
3. **`for await…of` over a sync iterable** (D3, using the adapter). This alone passes a
   large fraction of `for-await-of` tests without async generators existing yet. Validate:
   `async function f(){ for await (const x of [1,2,3]) log(x); }` logs 1,2,3 in order,
   after ticks.
4. **`for await…of` over a real async iterable** (an object with `Symbol.asyncIterator`
   returning an iterator whose `next()` returns Promises). Validate with a hand-written
   async iterator.
5. **Async generators** (D2): object + prototype + request queue + `yield`-awaits-operand
   + completion resolves the request Promise. Validate: `async function* g(){ yield 1;
   yield await Promise.resolve(2); }` consumed by `for await` yields 1,2.
6. **AsyncIteratorClose / early-exit** (D3.4): break/return/throw inside `for await` calls
   and awaits `return()`.
7. **Intrinsics/prototype-chain housekeeping** (D5) — cleans up the remaining
   descriptor/getPrototypeOf tests.
8. **`yield*` delegation to an async iterable** (Risks) — last, hardest.

## Risks / hard sub-cases

1. **`yield*` to an async iterable** inside an async generator: must drive the delegate's
   async protocol, forwarding `next`/`return`/`throw` and awaiting each result. The
   existing sync `YIELD_STAR` (vm_generators.c3:547,597) assumes a sync delegate. This is
   the single hardest piece; sequence it last and consider a separate async delegation
   path rather than overloading `YIELD_STAR`.
2. **The double-quadrant return path** (statements.c3:2470-2476): async generator is the
   4th combination of (async × generator). Getting `RET`/`RET_GEN` selection *and* the
   request-Promise resolution right is where subtle "Generator is executing" /
   unresolved-Promise bugs will appear. Cross-reference [[generator-completed-on-throw]]:
   an async generator body that throws must go GEN_COMPLETED **and** reject the pending
   request's Promise.
3. **Ordering/microtask correctness**: `for await` interleaves awaits with body execution;
   many tests assert exact log ordering across ticks. The existing async/await tick
   handling is the reference — reuse it, don't reinvent scheduling.
4. **Class/object async-generator methods** (class.c3:481-490 currently *reject* the
   combination): lifting that guard must not regress the "async constructor" / "async
   getter" early-error tests that share the code path.

## Effort estimate

**Medium-large — ~1,500–2,500 lines, multi-session, but smaller than Proxy (050).** No new
coroutine engine (reuses AWAIT/YIELD) and no bignum. Tasks 1-4 (async for-of, no async
generators) are the cheapest big win — they recover much of the `for-await-of` dir and are
independently shippable. Async generators (task 5) and `yield*` delegation (task 8) are the
long tail.

Recommended: ship tasks 1-4 as a first landable increment (re-scope the runner regex to
stop skipping `for-await-of` while still skipping `async-iteration` async-generator tests
if needed), then async generators as a second.

## When to unskip in the runner

`scripts/run_test262.py:138` currently skips both `async-iteration` and
`Symbol.asyncIterator`. Remove these from the regex only as each increment lands, so the
denominator grows in step with real capability (plan 040 rule). Expect a temporary CE/FAIL
bump on partial landings — gate the unskip on the task boundaries above.

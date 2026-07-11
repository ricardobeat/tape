# Plan 052 — Road to Zero test262 Failures

Baseline (session 278, `out/s278_baseline.tsv`): **29,753 pass / 1,289 FAIL /
132 CE:unexpected = 1,421 real fails (95.4%)** + 3 CE:expected-parse + 2
MEMKILL-class flakes. Target: **0 FAIL + 0 CE:unexpected** among non-skipped
tests (Reflect and sloppy-mode-only tests remain runner-skipped by policy).

Five parallel agents are in flight against ~300 of these (dstr member-expr
targets, super, yield*, global/eval decls, TypedArray.from/of). This plan
covers everything after they merge, ordered by (impact ÷ difficulty).

## Workstream A — Destructuring deep fixes (~110 tests)

Leftovers explicitly diagnosed by the dstr agent (all in
`emit_destruct_bindings` / `array_destructure_assign`, src/compiler/destructuring.c3):

1. **IteratorClose on abrupt completion in assignment patterns** (~44:
   `*-iter-thrw-close*`, `*-iter-rtrn-close*`, `*-lref-err*`, `*-trlg-iter-*`).
   Root cause: member-expression lref code is emitted during pattern
   collection, *before* the iterator is opened; spec requires lref evaluation
   after GetIterator, and IteratorClose wrapping on any abrupt target
   evaluation. Fix: two-phase emission — collect targets as unevaluated AST/
   lexer spans, open iterator, then per-element: evaluate lref, next(), assign
   — all inside a compiler-emitted try that routes abrupt completions through
   ITER_CLOSE. Keep the single-emitter invariant.
2. **`yield` in destructuring defaults** (~21: `[x = yield] = it` in
   generators). Defaults are compiled as inner-function thunks, which cannot
   suspend the outer generator. Fix: inline-default mode in
   emit_destruct_bindings when compiling inside a generator body (emit the
   default expression in the outer function's bytecode behind a
   JUMP_IF_NOT_UNDEFINED, no thunk).
3. **Generator/async-method parameter destructuring timing** (~43 across
   `class/dstr`, `generators/dstr`, `gen-meth-*`): parameter initialization
   (incl. @@iterator lookups) runs at generator-object creation instead of at
   first `.next()`. Fix: move param-init bytecode inside the suspended body
   prologue (it must execute on first resume, before the first yield point —
   note: per spec params evaluate *before* the body suspends only for
   non-generator fns; for generators, FunctionDeclarationInstantiation runs
   when the generator starts executing).

## Workstream B — Class semantics (~150 tests)

- **Param-scope vs body-var-scope** (~20: `scope-*-paramsbody-var-open/close`):
  methods with non-simple parameter lists need a separate parameter
  environment; `var` in body must not see param expressions' temporaries and
  vice versa. Compiler scopes change; coordinate with A3 (same prologue code).
- **Computed accessor names** (~28: `accessor-name-inst/static-computed-*`,
  `cpn-*-accessors-*`): computed keys for get/set in class bodies +
  ToPropertyKey ordering, incl. yield/await/arrow expressions as keys.
- **class/definition + subclass remainder** (~50 after in-flight agents):
  sample-and-cluster after merge; known items from super agent: `extends
  null` construction semantics, repeated `super()` → ReferenceError
  ("this already initialized"), direct eval inheriting super binding.
- **async-method / async-method-static** (~24 across stmt/expr classes):
  likely overlaps plan 051 async-iteration work; recluster after merge.
- **NativeError subclassing** (6) — subclass prototype wiring for the 6
  NativeError types.

## Workstream C — Unicode tables (~60 tests)

Three clusters, one shared fix: real Unicode property tables (generate C3
tables from UCD at build time, small binary-search ranges):

- **identifiers/start|part-unicode-N.js + escaped variants** (24):
  ID_Start/ID_Continue for the full BMP+astral range.
- **String.prototype.toLowerCase/toUpperCase/toLocale\*** (16+): full
  case-mapping table (SpecialCasing incl. multi-codepoint expansions like ß).
- **String.prototype.normalize** (6): NFC/NFD/NFKC/NFKD — biggest table;
  consider quickjs's libunicode as a reference (already vendored under
  quickjs/) or port its tables.

## Workstream D — TypedArray/Buffers remainder (~150 tests, Phase 22 has 147 fails)

From the TypedArray agent's diagnosis plus baseline:

1. **`$262.detachArrayBuffer`** host hook (~20 `callbackfn-detachbuffer`
   tests): implement $262 agent object in the runner/VM bridge. Cheap,
   unblocks a fixed cluster.
2. **CRASH: repeated `from.call` heap corruption** (custom-ctor-* tests,
   segfault in vm_call_fn_impl temp_regs) and **buffer-arg/toindex segfaults
   (exit 139)**. These are memory-safety bugs — fix first, with ASAN build
   (`out/batch_test_vm_asan` exists) + lldb watchpoint workflow.
3. **TypedArray exotic MOP** (`internals/DefineOwnProperty`, `internals/Get/Set`,
   ~14 incl. Object/internals hits): integer-indexed exotic object semantics
   (OrdinaryGet bypass, canonical numeric index strings, OOB writes ignored,
   defineProperty constraints).
4. **DataView / ctors / sort -0 / subarray-detach long tail** — recluster
   Phase 22 after 1–3.

## Workstream E — Language long tail (~250 tests)

- **Completion values of statements** (~40: `cptn-*` in for-of/while/do-while/
  if/try/switch + statementList): eval must return the correct completion
  value (V ← empty propagation). One mechanism, many tests — extend the
  eval_acc_reg save/restore approach from session 276-11jul to loops,
  if/else, try/catch/finally, switch.
- **compound-assignment** (11): likely evaluation-order (lref once) + ToNumeric
  coercion order; sample after merge.
- **tagged-template + template-literal** (17): raw/cooked arrays frozen,
  caching per-site identity, invalid escapes → undefined cooked.
- **optional-chaining** (9 incl. 3 CE), **delete** (7), **call** (8),
  **instanceof** (8), **asi/line-terminators** (10): sample-and-fix batch.
- **arrow-function** (10): remainder after super agent merges.

## Workstream F — Built-ins long tail (~300 tests)

Ordered by cluster size after merge; current top items:

- **RegExp** (19): sample; likely named groups/annexB/lastIndex edge cases.
- **JSON.parse/stringify** (21): reviver/replacer edge cases, property order,
  BigInt/proxy interactions,   escaping.
- **Object.defineProperty + internals** (20): descriptor-validation matrix
  remainder (plan 047).
- **Function/Function.prototype/bind/length/toString** (~40): dynamic
  Function() body parsing details, bound-function name/length attrs,
  toString spec format for classes/accessors/bound.
- **Array**: flatMap (12), splice/push/copyWithin/length (~36 — likely
  length-clamp/2^53 and MAX_SAFE_INTEGER RangeError ordering), Symbol.species
  (8), of (6), reverse/keys/values/entries (~18 — iterator-proto identity?).
- **String.fromCharCode (8), indexOf (6), search/replace (12)**,
  **Number/toFixed/parseFloat (21)**, **Date (8)**, **Promise.finally (8)**,
  **Object.assign (8)**, **Symbol.toPrimitive (5)**.

## Workstream G — Infrastructure & bookkeeping

- **3 CE:expected-parse**: confirm these are genuinely tests that *should*
  parse-error (then reclassify in the runner) or fix.
- **MEMKILL 2 / ±33 flakiness**: root-cause the run-to-run wobble (worker
  memory pressure?) — at <100 remaining fails, flakiness dominates signal;
  fix before the endgame.
- **Recluster after every merge**: `python3 scripts/run_test262.py --workers 4
  --log out/sNNN.tsv` + `scripts/test262_delta.sh`. Never trust an agent's
  count without the delta.

## Sequencing

1. Merge the 5 in-flight agents → full run → new baseline (expect ~96.0%).
2. Batch 2 (parallel agents): A1 iterator-close, A2+A3 (one agent — same
   compiler area), B2 computed accessor names, D1+D2 (crash fixes + $262
   hook), E completion values.
3. Batch 3: B param scopes, C unicode tables (identifiers + case first,
   normalize last), D3 TypedArray MOP, F samples (RegExp/JSON/Function/Array
   as 3–4 agents).
4. Endgame: long-tail `<4 tests/dir` (283 tests, ~120 dirs) — pure
   sample→fix→verify grind; batch by error message rather than directory
   (`awk` the TSV, run each through run_single_test.sh, cluster stderr).
5. Zero-fail gate: two consecutive full runs with 0 FAIL + 0 CE:unexpected
   (flakiness check), quick.sh + bench-fast green, ENV_STRICT oracle green.

Estimated: batches 2–3 ≈ 700–800 tests; endgame ≈ 400–500 in small clusters.

## Batch 2 results (session 279, 2026-07-11)

Merged to main:
- **E completion values** (77592ae): eval_acc_reg resets for if/while/do-while/
  for-of — 18 cptn-* tests.
- **A destructuring** (5ff8391, 4f6e61e): IteratorClose via TRY/ITER_CLOSE
  wrapper in emit_destruct_bindings; gen_init_stack in Heap saves/restores
  gen_initial_* across nested GEN_START. All 930 gen-meth dstr tests pass;
  agent-verified 2,335 passes across dstr/gen-meth/for-of dirs. A2
  (yield-in-defaults) affects ~0 in-scope tests — `compile_default_expr`
  doesn't propagate is_generator; fix only if tests demand it.
- **D crash fix** (c4eabb8): this_binding refcount underflow in nested
  vm_call_fn_impl. tval_copy_ref increfs before decref; ACT_FLAG_THIS_OWNED
  balances inline-CALL/getter increfs in handle_return; activation slots
  zeroed after memcpy-save (saved_acts kept GC-visible via shadow_act_list).

### Remaining D items (agent diagnosis, ~87 TA/DataView/ArrayBuffer fails)

1. **Builtin accessor throws escape try-catch** (~4: invoked-as-accessor.js):
   invoke_getter fast-path calls vm_throw_value but needs_restart doesn't
   propagate through dispatch_property back to the main loop. Diagnosis
   incomplete.
2. **Integer-indexed exotic MOP** (~9): numeric keys go through ordinary
   get_prop_or_accessor_proto; need II-exotic [[Get]]/[[Set]]/[[DefineOwnProperty]]
   (OOB read = undefined, OOB write = no-op, bypass proto setters in-bounds).
3. **Detach mid-operation** (~18): $262.detachArrayBuffer inside forEach/map/
   reduce callbacks → wrong error or crash.
4. **DataView range-check-after-value-conversion** (~12): ToNumber must run
   before byte-offset range check.
5. **TypedArray sort** (3): comparefn throw handling + numeric order.
6. **Custom-proto fallback** (5): non-object new.target.prototype must fall
   back to the built-in prototype.

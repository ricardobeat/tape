# Plan 048 — Destructuring completion wave

Fresh baseline (session 268, `out/test262_results_268.tsv`): **24,122 pass / 29,445
executed ≈ 81.9%**, CE:unexpected 284, FAIL 5,001. The `dstr` directories account for
**1,273 failures** (FAIL + CE:unexpected combined) — the single largest cluster now that
plan 044/045/046 landed the recursive iterator model for array patterns. This plan
finishes the job: the remaining failures are NOT one big migration but six independent,
individually-verifiable buckets, sized below from test-name clustering plus a local
probe matrix (all reproduced on the current build).

Baseline commands:

```
python3 scripts/run_test262.py --workers 4 --log out/test262_results_268.tsv
awk -F'\t' '($1=="FAIL"||$1=="CE:unexpected") && $2 ~ /dstr/' out/test262_results_268.tsv | wc -l   # 1273
bash test262_runner/run_single_test.sh language/statements/variable/dstr/<test>.js
```

## Bucket A — NamedEvaluation for anonymous defaults (~280 tests, biggest single win)

`ary-ptrn-elem-id-init-fn-name-{fn,gen,arrow,class,cover}` and
`obj-ptrn-id-init-fn-name-*` × every syntactic context (28 each × 10 name shapes).

```js
var [fn = function() {}] = [];   // fn.name must be "fn" — currently ""
```

Per ES2015 §12.2.6.9 / §13.3.3.7, when a binding's default is an anonymous function /
arrow / class / generator, it gets the binding identifier as its `.name`
(NamedEvaluation). The engine already names anonymous functions in `var f = function(){}`
(see the named-evaluation comment above `compile_inner_function`,
src/compiler/functions.c3:1750) — the destructuring default paths never route through
that logic. Fix at the default-thunk compile sites: when the default expression is a
bare anonymous fn/arrow/class/gen, pass the binding name down the same way the
var-initializer path does. Files: src/compiler/functions.c3 (param default thunks,
`default_func_idx` sites), src/compiler/destructuring.c3 (statement-level defaults).

## Bucket B — Non-identifier keys in binding patterns (~200 tests, mostly CE)

Reproduced locally — ALL of these are parse errors today:

```js
var {'a b': c} = src;          // string literal key
var {1: d} = src;              // numeric key
var {if: e} = src;             // reserved word key
var [...{ 1: x }] = [obj];     // ary-ptrn-rest-obj-prop-id.js — 28 tests
function f({[k()]: v}) {}      // computed key in PARAM pattern — prop-eval-err, 24 tests
var {a: {b} = {b:5}} = {};     // nested pattern with its own default
```

The statement-level `object_destructure` (src/compiler/destructuring.c3:92) and the
param-path `collect_obj_param_binds` (src/compiler/functions.c3) both `expect(IDENTIFIER)`
for keys. The object-literal parser already solved the same problem (B42 reserved-word
keys, computed keys) — reuse its key-parsing helper. Nested-pattern-with-default needs
`DestructBind.has_default` on synthetic group binds (B39 built this for params; the
statement path doesn't wire it).

## Bucket C — IteratorClose protocol (~170 tests)

Reproduced: the iterator's `return()` is never called.

```js
var [a] = iter;    // iterator not exhausted → must call iter.return()   (ary-init-iter-close)
var [a = boom()] = iter;  // abrupt from default → IteratorClose         (…-init-throws)
var [, ,] = iterThrowingOnNext;  // elision still calls next(); abrupt propagates
                                 // (ary-ptrn-elision-step-err — currently swallowed)
```

Per §13.3.3.8 the pattern emitter must (a) call `return()` when destructuring completes
with `done=false`, (b) call it on any abrupt completion inside the pattern (defaults,
nested throws), (c) for elisions, still step the iterator and propagate step errors.
The for-of loop already has IteratorClose plumbing (break/throw paths in
`for_statement` / INITFOR/NEXTFOR, src/vm/vm_forin.c3) — the destructuring emitter
`emit_destruct_bindings` (src/compiler/functions.c3:415) never emits it. Wrap the
iterator walk in the same TRY/close pattern the for-of lowering uses.

## Bucket D — ToObject/TypeError on nullish sources (~90 tests)

```js
var {} = null;                 // must throw TypeError            (obj-init-null/undefined, 34)
var {a: {b}} = {a: null};      // nested null → TypeError         (…-value-null/undef, ~56)
```

Reproduced: no throw. RequireObjectCoercible before reading any property of a pattern
source (including empty patterns `{} = null` and nested sources). One shared check at
the top of the object-pattern emit for each source register. Array-pattern equivalents
(`ary-ptrn-elem-obj-val-null`) come free once nested object patterns get it.

## Bucket E — Assignment-form targets (~120 tests: assignment/dstr 64 FAIL + 56 CE)

Reproduced — all parse errors:

```js
({a: o.b} = src);          // member-expression target
([o.c] = src);             // member target in array pattern
({a: {b: o.n.c}} = src);   // nested member target
([...o.r] = src);          // rest into member target
([(x)] = src);             // parenthesized target
```

`object_destructure_assign` / `array_destructure_assign`
(src/compiler/destructuring.c3:630/684) only accept identifiers. Per §12.15.5 assignment
patterns take any valid LeftHandSideExpression as leaf target. Needs a
`DestructStoreMode.ASSIGN_TARGET` extension: parse the leaf as member-expr (obj reg +
key) and emit PUTPROP instead of PUTVAR, plus parenthesized-target unwrapping.

## Bucket F — for-in head patterns + leftovers (~60 tests + long tail)

```js
for (var [c] in {ab: 1}) {}   // keys are strings — iterate the STRING's chars;
                              // currently TypeError (destructure_for_value assumes object)
```

`destructure_for_value` (src/compiler/destructuring.c3:1280) must route the yielded
string through the same iterator protocol (strings are iterable). Remainder of
`for-of/dstr` (163 FAIL + 44 CE) is expected to be dominated by buckets A–D appearing
in for-heads; re-cluster after those land before attacking directly.

Also surfaced by the probe matrix, worth a look while in the code (not separately
sized): property read order `var {b, a} = src` with getters dies with
"Cannot read properties of undefined" when the source is an object literal held in a
temp — suspected pattern-source register clobber across the getter call; write an
oracle first.

## Execution order & verification

1. **B (keys) + D (nullish)** — parser + one runtime check; converts CEs, unlocks whole
   files. Gate: `language/statements/variable/dstr` phase slice.
2. **A (fn-name)** — mechanical once the naming hook is found; 280 tests.
3. **C (IteratorClose)** — riskiest (touches the shared emitter); land with a local
   oracle (`test/destructure_iter_close.js`) covering close-on-done, close-on-abrupt,
   elision-step-err before running phases.
4. **E (assignment targets)** — self-contained in the assign-form parsers.
5. **F** — re-cluster, then mop up.

Verify each bucket with the probe matrix (scratchpad `dstr_probe*.js` recreated as
`test/destructure_probe_268.js`), the existing destructure oracles (destructure_regression
90/90, destructure_comprehensive, rest_nested), rosetta 100/100, and a single
`--phase` run of the dominant phase for that bucket — full runs only at wave start/end
per the test262 workflow. Class/generator `dstr` directories (424 + 152 tests) are the
same buckets seen through method-parameter syntax and should collapse as A–D land;
no separate work item unless re-clustering says otherwise.

Expected yield if A–E fully land: **~1,000–1,200 of the 1,273**, i.e. roughly
81.9% → 85.5–86% overall, plus whatever the for-of-head remainder gives.

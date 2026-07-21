# Plan 059 — Function-Context Capture: eval-super, arrow scopes, optional-chain calls, public fields

**Status**: Phase 1 DONE (session 289, all 5 fixes + arrow-scope-leak follow-up landed; class-method eval-super also fixed via opencode-jul merge — obj-literal eval-super, eval super(), nested-eval new.target remain for Phases 2-3). Phases 2-5 pending.
**Target clusters** (from 2026-07-20 full run, 229 fails total): eval-super (5), arrow scope-paramsbody (3), arrow lexical-super-call (1), optional-chaining (1), class/elements field-arrow + new.target early-error (2), plus P7 public fields unlocking the currently-skipped `class-fields-public`/`class-static-fields-public` suites.

## Reframing C8

The original backlog C8 ("arrow `this` resolved from calling activation") is **stale — the architecture is already correct**: arrows capture `this` and `new.target` once at closure creation (`instantiate_closure`, `src/vm/vm_control.c3:245-253` → `captured_this`/`captured_new_target` in `HObjectExtra.func`), all call paths (call_fn `src/vm/vm_execute.c3:431`, inline CALL fast paths `src/vm/vm_calls.c3:386,1376`) consult the capture, and the pre-`super()` TDZ case re-resolves live via `super_walk_live_this`. A 40-case behavior battery (session 289) passes all core arrow-`this`/`new.target`/`arguments` semantics including `.call/.bind` immunity, builtin-callback routing, generators, and pre/post-`super()` TDZ.

What actually remains is the **rest of the function-context family**: contexts that need the enclosing function's `super`-home/derived-ctor/`new.target` permissions and bindings but compile as fresh contexts (direct eval), plus parameter-scope separation, plus the optional-chain call receiver rule.

## Verified gaps (behavior battery + test262 run)

1. **E1 — direct eval can't compile `super`** (5 tests + battery):
   - `eval("super.x")` in class method → "SyntaxError in eval code" (should work: caller has home object)
   - `eval("super()")` in derived ctor → same
   - `eval("(() => super.x)")()` → same
   - `eval("eval('new.target')")` nested eval → same (outer eval body doesn't re-grant new.target)
   - `eval("super.x")` in object-literal shorthand method → runtime `ReferenceError: __super__ is not defined` (different mechanism — see below)
   - Failing tests: `language/eval-code/direct/super-prop-method.js`, `language/expressions/super/prop-{dot,expr}-{cls,obj}-val-from-eval.js`
2. **Early-error gap**: `({ m: function() { super.x } })` compiles and fails at runtime with `ReferenceError: __super__`; per spec `super` in a plain FunctionExpression is an **early SyntaxError** (only method definitions have [[HomeObject]]).
3. **X2 — param-scope vs body var-scope** (3 tests, all strict-compatible — genuine bugs, not skip-list; diagnosed session 289):
   - `arrow-function/scope-paramsbody-var-{open,close}.js`: the arrow **reparse** compile path (`compile_arrow_inner_reparse`, `functions.c3:3184-3508`) never emits the body's separate `PUSH_VAR`/`POP_VAR` when parameter expressions exist (§9.2.10 step 27), so a closure in a default-param expression sees body `var`s. `compile_inner_function` (`functions.c3:2895-2924`) already does this correctly — mirror it. The simple-arrow path (`compile_arrow_inner:3650`) is fine.
     Repro: `((_ = p = function(){return x;}) => { var x = 'inside'; })()` with outer `var x='outside'` — `p()` gives `'inside'`, must be `'outside'`.
   - `call/scope-var-open.js`: named function expression — the name binding env (`setup_named_function_expr_env`, `vm_execute.c3:20-30`) is installed as the lex search head ABOVE the body var_env (`resolve_call_lex_env`, `vm_execute.c3:38,92-101`), so `var n` in the body can never shadow the function name `n` (§9.2.13: name binding is the OUTER env). Fix: chain `var_env.parent → name_lex` and keep `var_env` as the search head; watch the `needs_env=false` shared-env reuse path and the constructor variant (`vm_calls.c3:2370`).
     Repro: `(function n(){ var n; return n; })()` returns the function object, must be `undefined`.
> **CORRECTION (session 289c)**: item 4's second bullet was a MISDIAGNOSIS. `(o?.m)()` must call with `this === o` — a non-short-circuited optional chain is a Reference and parentheses preserve it (test262 `optional-call-preserves-this.js` is authoritative; the brief "undefined this" fix was reverted, only the paren-block dedup survives). Do not re-apply.

4. **X1 — two separate bugs** (diagnosed session 289):
   - The failing test `optional-chaining/optional-chain-prod-expression.js` is actually an **array fast-path key-truncation bug**: `arr[1.1] = v` truncates the double to index 1 and corrupts the dense element (`vm_property.c3:2117-2119` PUTPROP; same missing integrality guard in GETPROP at `vm_property.c3:117-119`; the TypedArray paths at 2073/142 have the guard — copy it). Repro: `var arr=[39,42]; arr[1.1]='x'; arr[1]` → `'x'`, must stay `42`. Silent data corruption — highest severity in this plan.
   - `(o?.m)()` receiver: confirmed real but untested by that file — `expressions.c3:2670-2676` keeps `call_prop_obj_reg` through parens when next token is `(` without checking `last_was_optional_chain`; a parenthesized chain then called must get undefined `this`.
5. **Escaped-arrow `super()` double-call**: `arrow-function/lexical-super-call-from-within-constructor.js` — the "super() already called" ReferenceError (BindThisValue step 3) is detected by walking **live activation frames** (`super_init_this_chain` `vm_calls.c3:57-87`, `super_walk_live_this` :171-185); an arrow that escapes its constructor (`this.af = _ => super()`, called after `new B()` returns) finds no live frame and silently re-runs the base ctor. The code comments even assert this "cannot legally" happen — it can. Fix requires the this-binding state to live in a **captured cell** (the arrow's closure env), not only in frames.
6. **Field-arrow `new.target` early error** (`arrow-body-private-indirect-eval-err-contains-newtarget.js` ×2 — NOT P7-blocked; the private-field-with-arrow-body parses fine): `compile_arrow_inner` (`functions.c3:3650-3678`) and `compile_arrow_inner_reparse` (:3184-3212) don't propagate `eval_mode`/`eval_direct_in_function` into the arrow context, so the `expressions.c3:1920` check never fires inside arrows. Repro: `(0,eval)('() => new.target')` returns a function, must be SyntaxError. Regular functions correctly do NOT propagate (they establish their own [[NewTarget]]).
7. **P7 — public fields** (plan 054 §P7, ~200 lines, reuses landed P2/P5 field-init machinery): unlocks the skipped `class-fields-public`/`class-static-fields-public` suites. Field-init closures already flow through `instantiate_closure` (`src/vm/vm_calls.c3:139`), so `this`/`new.target` capture in field arrows comes for free.

Out of scope (separate families): `identifier-resolution/assign-to-global-undefined.js` + `eval-code/direct/var-env-gloabl-lex-strict-caller.js` (L1/L2 global-env/PutValue semantics); private-on-proxy / nonextensible / evaluation-order class-elements tests (P6/private-semantics family); the 171-test for-await-of cluster — diagnosed session 289: **168 are async-generator-PRODUCER tests** (`async function*` sources; the deferred feature — destructuring + consumer already correct, verified by control repro) and **3 are AsyncFromSync tick-ordering fidelity** (`vm_control.c3` ~1229-1253). Async generators = plan 060 candidate, the single biggest remaining lever (~73% of all fails). Interim trap-removal: `async function*` expressions silently compile as broken plain-async functions (`functions.c3:2571-2572`) while the method form is parse-rejected (`class.c3:491`, `expressions.c3:3553`) — reject the expression form too until the feature lands.

## Current super mechanisms (three parallel paths — to unify)

Mapped session 289 (agent + code reading):

1. **Class bodies**: `let __super__` + `let __static_super__` declared in classScope (`class.c3:280-289`), captured by method CLOSUREs. With `extends`: `__super__ = Base`, `super_is_home_object=false`, and `super.x` emits `GETVAR __super__` → `GETPROP .prototype` → `GETPROP_SUPER` (`expressions.c3:3262-3285`). Without `extends`: `__super__ = C.prototype`, `super_is_home_object=true`, emission uses `GETPROTO(__super__)`. Statics use `__static_super__ = ctor` (`class.c3:910-911`).
2. **Object-literal methods**: on first concise method, the ENCLOSING function's bytecode emits `PUSH_LEX` + `let __super__ = <literal obj>` (`expressions.c3:3680-3685, 3817-3821`), `super_is_home_object=true`, emission `GETPROTO(__super__)`. This scope is NOT captured into the method's closure env — reachable only while the enclosing frame's lexical scope is live.
3. **`super()`**: `GETVAR __super__` + `SUPER_CALL`/`SUPER_CALL_S` (`expressions.c3:3104-3181`; runtime `vm_calls.c3:1560-1939` walks `new.target` via `super_walk_new_target`).

The DOT and LBRACKET branches duplicate the `super_is_home_object` two-shape emission verbatim; `has_home_object` on CompiledFunction is just `super_is_home_object` (`context.c3:1169`) — **false for derived-class methods**, which is semantically wrong (every method has a [[HomeObject]] per spec §8.3.3).

### Why eval-super fails (exact chains)

- **Class-method eval SyntaxError**: `builtin_eval` gates `caller_eval_allows_super` on `caller_cf.has_home_object()` (`global.c3:412`) → false for `extends`-class methods → `compile_eval(allow_super=false)` → `ctx.has_super_binding=false` (`entry.c3:144`) → super gate `expressions.c3:3198` → COMPILE_ERROR → "SyntaxError in eval code".
- **Object-literal eval ReferenceError**: compiles fine (`super_is_home_object=true`), but eval's `GETVAR __super__` walks the caller method's env chain (`global.c3:486`), which never captured the PUSH_LEX scope → `ReferenceError: __super__ is not defined`.
- **`eval("super()")` always rejected**: `compile_eval` hardcodes `is_constructable=false` (`entry.c3:311`); derived-ctor flag not plumbed at all. Runtime side is mostly ready (eval activation inherits new.target for `is_eval_fn`, `vm_calls.c3:1353`).
- **Nested `eval('new.target')`**: eval CompiledFunctions are `is_global_fn()=true` (`entry.c3:142`), so the *nested* eval's `caller_direct_eval_in_function` check (`global.c3:403`) sees "global caller" → new.target rejected (`expressions.c3:1920`). Needs an "eval-in-function" flag distinct from `is_global`.
- **Eval body always emits the class-shaped `.prototype` form**: fresh eval ctx has `super_is_home_object=false`/`super_is_static_method=false`, so even a compiling object-literal-caller eval would emit the wrong base derivation. Caller's shape flags must be plumbed — OR made irrelevant by unification (below).

### The unification

Replace all three paths with **one captured lexical binding holding the method's [[HomeObject]]** (object-literal obj / class prototype / class ctor for statics), always deriving `GetSuperBase = GETPROTO(homeObject)`:

- Class `extends` case stops storing `Base` (drops the `.prototype` emission shape AND the `setPrototypeOf` ctor-sync special case `object.c3:4369-4383` — `GETPROTO` picks up mutations live, which is the spec semantics).
- Object literals declare `__super__` in a scope the method closures CAPTURE (same classScope pattern), deleting the ad-hoc PUSH_LEX path and its sibling-clobber handling.
- Two class-scope bindings remain — they are two genuinely different [[HomeObject]] values (instance methods+ctor → `C.prototype`; statics → `C`) — but both use the SAME `GETPROTO(binding)` derivation, so `super_is_home_object` / the DOT-vs-LBRACKET duplicated emission shapes collapse to one form; `super_is_static_method` only selects which binding name to read.
- `super()` per §13.3.5.1 GetSuperConstructor = `GETPROTO(activeFunction)`: read the static binding (the ctor `C`) and `GETPROTO` it — no stored `Base`, live under `Object.setPrototypeOf(C, …)`.
- `has_home_object` becomes true for **every** method — which is precisely the correct eval permission, fixing the class-method SyntaxError as a side effect; the ReferenceError fixes itself because the binding is now in the captured env that eval inherits (`global.c3:486`).

## Phases

Ordering: independent point fixes first (parallel agents), then the HomeObject unification as one atomic refactor, then the features that depend on it. Every phase gates on: golden bytecode suite, local battery (below), affected test262 phase(s), zero regressions.

### Phase 1 — Independent point fixes (parallelizable, one agent each, worktree-isolated)

| # | Fix | Where | Tests |
|---|-----|-------|-------|
| 1a | Array PUTPROP/GETPROP fast-path integrality guard (`get_number() == (double)idx_long`) | `vm_property.c3:2117-2119`, `:117-119` | `optional-chain-prod-expression.js` +any latent |
| 1b | Arrow reparse path: emit body `PUSH_VAR`/`POP_VAR` + hoist when param expressions exist (mirror `compile_inner_function:2895-2924`) | `functions.c3` `compile_arrow_inner_reparse` ~:3466 | `scope-paramsbody-var-{open,close}` |
| 1c | Propagate `eval_mode`/`eval_direct_in_function` into both arrow compile paths | `functions.c3:3650-3678`, `:3184-3212` | `arrow-body-private-indirect-eval-err-contains-newtarget` ×2 |
| 1d | `(o?.m)()` receiver: clear `call_prop_obj_reg` when `last_was_optional_chain` at the paren boundary | `expressions.c3:2670-2676` | spec-correctness (add battery case) |
| 1e | Named-funcexpr binding order: `var_env.parent → name_lex`, search head stays `var_env`; mind the `needs_env=false` shared-env path + ctor variant | `vm_execute.c3:20-30,38,92-101`, `vm_calls.c3:2370` | `call/scope-var-open.js` |

1a is highest severity (silent data corruption). 1e is the riskiest (runtime env chains) — its agent must run the full suite, not just the phase.

### Phase 2 — HomeObject unification (single atomic refactor, main-session or one strong agent)

The design in "The unification" above. Deliverables:
- One derivation shape (`GETPROTO(binding)`) for all super-property emission; DOT/LBRACKET share one helper.
- Object-literal `__super__` moves from enclosing-frame `PUSH_LEX` into a scope captured by the method closures (classScope pattern); delete the ad-hoc path.
- Class `extends` stores no `Base`; drop the `setPrototypeOf` ctor-sync (`object.c3:4369-4383`) — `GETPROTO` is live.
- `super()` reads the ctor binding + `GETPROTO` (spec GetSuperConstructor).
- `has_home_object` true for every method/accessor kind.
- **No test changes expected** except possibly `setPrototypeOf`-liveness tests turning green. Full-suite zero-regression gate + bench-fast (super paths are not hot; expect noise-level).

### Phase 3 — eval-super enablement (depends on Phase 2)

- `compile_eval` params: `allow_super` (now simply caller `has_home_object`), `allow_super_call` (caller is derived ctor — plumb `is_constructable` + derived flag from caller CompiledFunction; drop the hardcoded `is_constructable=false`, `entry.c3:311`), static-method flag (binding-name selection only).
- Nested-eval `new.target`: new CompiledFunction flag "direct-eval-in-function" distinct from `is_global` (`entry.c3:142`), consulted at `global.c3:403`.
- Runtime side is already in place: eval inherits caller `lex_env` (`global.c3:486`) — post-Phase-2 the home-object binding is reachable there; eval activation inherits new.target (`vm_calls.c3:1353`).
- Early error: `super` in plain FunctionExpression → SyntaxError at parse (methods only, §8.3.3); today it compiles and dies at runtime.
- Tests: the 5 eval-super files + battery cases (eval `super()`, eval arrow-super, nested-eval new.target).

### Phase 4 — Escaped-arrow super() state (depends on Phase 2's captured-scope shape)

Move the BindThisValue already-initialized check from live-frame walks to a captured cell: the derived ctor's this-state lives in the classScope-captured env (alongside the home-object binding), written by SUPER_CALL/CONSTRUCT, read wherever `super_init_this_chain`/`super_walk_live_this` walk today (`vm_calls.c3:57-87,171-185`; throw sites `vm_execute.c3:3157,3175-3182`, `vm_calls.c3:1621-1636`). The frame walk remains as fast path when frames are live; the cell is authority. Test: `lexical-super-call-from-within-constructor.js`.

### Phase 5 — P7 public fields (independent — can run parallel with 2-4 as its own agent)

Execute plan 054 §P7 as specced (~200 lines): reuse P2/P5 field-init machinery, CreateDataPropertyOrThrow semantics, computed keys evaluated once at class-eval time into hidden slots, fn-name inference. Un-skip `class-fields-public`/`class-static-fields-public` per `run_test262.py` UNSUPPORTED_PATTERN + `test262_skip.cfg`.

### Not this plan

- **Plan 060 candidate — async generators** (168 tests, the biggest single lever) + AsyncFromSync tick-ordering (3 tests, small and separable). Interim: parse-reject `async function*` expressions like the method form already is.
- L1/L2 global-env/PutValue reference semantics (2 tests).
- Private-on-proxy / nonextensible / eval-order class-elements tests (P6 family).

## Regression battery

`scratchpad/arrow_this_battery.js` + `arrow_probe2.js` (session 289) — 40+ cases covering arrow this/new.target/arguments capture, super in all method kinds, eval-super, TDZ pre-super(), optional-chain receivers. Promote into the repo's local test dir as `tests/function_context.js` (or equivalent) during Phase 1 so every phase gates on it.

## Design principles (user-set)

Elegant code, low duplication, performance and correctness; greenfield — restructuring allowed. Concretely: one lexical-capture story for `this`/`new.target`/`super`-home shared by closures AND eval (not per-feature plumbing); unify the object-literal `__super__` path with the class home-object path if the agent mapping confirms they're parallel implementations of the same spec concept ([[HomeObject]]).

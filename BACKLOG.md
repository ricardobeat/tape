# Duktape C3 — Backlog

Status: TODO / IN PROGRESS / DONE. Minimum detail to start a task; no results or test summaries.

## Compiler / language

- [ ] **C7a-residual** — `MAX_PRIVATE_NAMES = 64` cap (`src/compiler/context.c3:1527`); heap-allocate or grow-on-demand the private-name table (65+ private fields in one class overflow slot 0).
- [x] **C7b** — Private names visible to direct eval; eval bodies compile fresh contexts without the enclosing private_names scope. (Session 283, +10 tests)
- [ ] **P6** — `#x in obj` private-field presence check (plan 054; suite skipped).
- [ ] **P7** — Public fields (plan 054; suite skipped).
- [x] **C8** — Arrow-function lexical `this`/`new.target`: captured at closure creation (`captured_this`/`captured_new_target` in `instantiate_closure`, live re-resolve pre-`super()` via `super_walk_live_this`); verified by behavior battery session 289. Residual arrow gaps tracked in plan 059.
- [ ] **L1** — Sloppy-mode `var` declaration semantics / auto-vivification of undeclared identifiers into globals.
- [ ] **L2** — Direct eval var-hoisting into caller/global scope.
- [ ] **L3** — Indirect eval var-hoisting into global scope.
- [x] **X1** — Array fast-path key truncation fixed (session 289). NOTE: the companion "`(o?.m)()` must call with undefined this" diagnosis was WRONG and its fix was reverted (session 289c) — a non-short-circuited optional chain is a Reference; parens preserve the receiver (test262 `optional-call-preserves-this.js` is authoritative). Don't re-introduce.
- [ ] **X2** — Arrow reparse path missing body `PUSH_VAR` (param-expression scope separation) + named-funcexpr name binding not shadowable by body `var` (plan 059 §1b/1e).
- [ ] **E1** — Direct eval cannot compile `super.x`/`super[x]`/`super()`/nested-eval `new.target`; root cause is the three-way split super mechanism (`has_home_object` false for derived-class methods; object-literal `__super__` in an uncaptured PUSH_LEX scope). Fix = HomeObject unification, plan 059 §2-3. Also: `super` in plain fn-expr must be early SyntaxError; arrow compile paths must propagate `eval_mode` flags (plan 059 §1c).
- [ ] **E2** — Escaped-arrow `super()` double-call not detected (live-frame walk in `super_init_this_chain`; needs captured this-state cell, plan 059 §4).
- [ ] **X4** — Arrow with BLOCK body inside a template substitution inside a function silently truncates the program (everything after the enclosing statement never compiles/runs; no error surfaced). Pre-existing (predates session 289 hoist fixes); likely the swallowed-lexer-error/synthetic-EOF family from session 281. Repro: `print("a"); function f(){ var q = ` + "`${ (() => { var t = 1; })() }`" + `; } print("b");` → prints only "a". Expression-body arrows in substitutions are fine.
- [ ] **X5** — Named-funcexpr binding invisible through nested closures when a same-named binding exists on the captured lex chain (`function/scope-name-var-close.js`): GETVAR's two-walk model (cap_lex chain first, var_env chain fallback) finds the outer/global binding on walk 1 before the name env (spliced on walk 2's chain) is ever consulted. Works when no same-named outer binding exists (walk 1 misses → fallback finds name env). Structural: the two-walk model can't express the spec chain `call env → name env → captured chain`. Elegant fix: compile-time — register the funcexpr name as a static binding around the body (would delete the whole runtime splice in `resolve_call_lex_env`/`setup_named_function_expr_env` + the ctor duplicate at `vm_calls.c3:2378`); plan 059 env-model work. Repro: `var probe; var f2 = function k(){ probe = () => k; }; var k='out'; f2(); probe()` → 'out', must be f2.
- [ ] **X3** — Writes to an enclosing function's local from a parameter-default expression are lost (both ordinary fns and arrows; reads work; body writes work). Capture scan doesn't cover param-default expressions, so the local stays register-resident and the env copy takes the write. Repro: `function w(){ var p=null; (function(_ = p = 6){})(); return p; }` → null, must be 6. Found session 289 by test/function_context.js; same family as the bare-for-of register-residency fix.
- [ ] **AsyncFromSync tick ordering** — the 3 `for-await-of/ticks-*` tests: adapter performs wrong number/order of PromiseResolve/constructor lookups vs §27.1.4.2.1 (`vm_control.c3` ~1229-1253). In scope (no async generators needed).

## Builtins

- [x] **`arguments` Symbol.iterator** — `[...arguments]`/spread works (verified session 289).
- [x] **Shared iterator prototype `next`** — shared `%ArrayIteratorPrototype%` (session 284); Map/Set iterators inherit `next` from prototype; per-kind prototypes (String vs Array) are spec-correct.
- [x] **BigInt wrapper** — `BigInt` global + prototype, `Object(1n)` wrapper, `BigInt64Array`/`BigUint64Array` all landed (plan 056 + sessions 285-288).
- [ ] **S1** — String regexp-prototype-`*` v/u flag handling.
- [ ] **S2** — String cstm-`*` on BigInt primitive (BigInt wrapper landed; re-run cluster).
- [ ] **S3** — String indexOf ToInteger ordering.
- [ ] **S4** — isWellFormed / toWellFormed ToString.
- [ ] **S5** — String Symbol.iterator on non-obj-coercible.
- [ ] **O1** — fn-name inference for accessors, arrow, class, gen.
- [ ] **O2** — Computed accessor names, ToPropertyKey ordering.
- [ ] **O3** — Method-def name Symbol + generator proto.
- [ ] **D1** — Date algorithm gaps (toISOString extreme values, setFullYear arg ToNumber, toJSON abrupt propagation).
- [ ] **T1** — Tagged template site caching.
- [ ] **T2** — Frozen template object.
- [ ] **T3** — Invalid escapes → undefined cooked.
- [ ] **T4** — Tagged template misc.
- [x] **Y1** — Symbol.prototype cluster (constructor, description, Symbol.toPrimitive, toStringTag, toString). (Session 283, +17 tests: well-known symbol descriptors, Symbol()/Symbol.for() coercion, registry cleanup)
- [ ] **J2** — JSON.stringify edge cases.
- [ ] **G1** — Expression generators default-proto / prototype descriptor.
- [ ] **G2** — statements/generators prototype semantics.
- [ ] **TA1** — TypedArray Integer-Indexed [[DefineOwnProperty]].
- [ ] **TA2** — TypedArray Integer-Indexed [[Set]] prototype chain.
- [ ] **TA3** — TypedArray constructors.

## RegExp

- [ ] **U1** — Unicode property escapes `\p{...}`/`\P{...}` in unicode-mode. libregexp has property-table infra (`libregexp/unicode_wrapper.{h,c}`); wire `\p{}` through lexer/parser and property-name lookup, or confirm `lre_compile` support. QuickJS libunicode (vendored) has full UCD 17.0 tables.
- [ ] **CharacterClassEscapes** — residual RegExp fails; may share tables with U1.

## Long tail

- [ ] **Z** — Cluster remaining ~250 fails by stderr signature and batch by root cause. Bins: Promise race/any/finally, Object seal/assign/prototype/defineProperty, Set/Array Symbol.species, Number/prototype, Function/length, super, template-literal, block-scope/leave.

## Infrastructure

- [ ] **I2** — `$262.detachArrayBuffer` host hook (unblocks TypedArray callback tests).
- [ ] **I3** — Reclassify or fix CE:unexpected cases.
- [ ] **I4** — Two-consecutive-run zero-fail gate once <50 fails; enforce in CI.
- [ ] **Batch-runner SIGSEGV** — under sustained load; verify batch regressions in isolation (see memory `batch-runner-segv-under-load`).

## Non-goals (do not reopen)

- **Async generators** (`async function*`, `async *m()`) — deferred, NOT permanently rejected: **plan 060** (written session 289b) specs the implementation (~3-5 sessions), scheduled after the 42-fail cleanup and plan 059 Phases 2-4. Until then: all four syntactic forms parse-reject with SyntaxError; runner skips structurally (`*async-gen*` globs + `for-await-of/async-func-dstr-*-async-*`). The for-await-of consumer, destructuring LHS, and AsyncFromSync adapter ARE supported and stay in scope.
- **Reflect API** — runner-skipped by policy (A9 implemented the surface; narrow the skip if reopened).
- **Sloppy-mode-only tests** — runner-skipped by policy; engine is strict-only by design.
- **F1 apply/call sloppy `this`** — unfixable under strict-only design; skip-listed.
- **Native UTF-16/Latin1 string storage** — big GC/string-builtin migration; not part of the 100% push.

## Done

- [x] **P1** — RegExp property-escapes root cause was a compiler register-aliasing bug (`e40cdd9`).
- [x] **C7 / P2-P5** — Private class members: fields, methods, accessors, static private (plan 054).
- [x] **C7a** — `\u` escapes in private names (`afaabb7`).
- [x] **C7c** — Duplicate private-member initialization throws TypeError (`ee660f0`).
- [x] **C7d** — Private-name proxy, evaluation-order, accessor, and eval edge cases.
- [x] **A9** — Reflect API surface implemented.
- [x] **J1** — JSON.parse reviver error propagation (`d6cbc2d`) + Date.toJSON companion (`7bcf02f`).
- [x] **Promise combinators** — GC-rooting + no-handler microtask ordering (`34a5269`).
- [x] **Symbol.split / Symbol.matchAll** — cluster closed (session 284).
- [x] **H1** — Hashbang / tagged-template raw text.
- [x] **try completion + block-scope leave** — eval_acc_reg reset at FINALLY; labeled break POP_LEX unwind. (Session 283, +5 tests)
- [x] **Sloppy-mode/tzdata skip-list** — 17 tests skip-listed (Function ctor dup-params, Date LMT precision, function-code sloppy this/var). (Session 283)

# Duktape C3 — Backlog

Status: TODO / IN PROGRESS / DONE. Minimum detail to start a task; no results or test summaries.

## Compiler / language

- [ ] **C7a-residual** — `MAX_PRIVATE_NAMES = 64` cap (`src/compiler/context.c3:1527`); heap-allocate or grow-on-demand the private-name table (65+ private fields in one class overflow slot 0).
- [x] **C7b** — Private names visible to direct eval; eval bodies compile fresh contexts without the enclosing private_names scope. (Session 283, +10 tests)
- [ ] **P6** — `#x in obj` private-field presence check (plan 054; suite skipped).
- [ ] **P7** — Public fields (plan 054; suite skipped).
- [x] **C8** — Arrow-function lexical `this`/`new.target`: captured at closure creation (`captured_this`/`captured_new_target` in `instantiate_closure`, live re-resolve pre-`super()` via `super_walk_live_this`); verified by behavior battery session 289. Residual arrow gaps tracked in plan 059.
- [x] **L1** — Strict PutValue on a pre-resolved unresolvable reference (`identifier-resolution/assign-to-global-undefined.js`): added a new `RESOLVEVAR` A-BC opcode that runs before RHS evaluation and writes a boolean to a temp register; the assignment emitter follows up with an `IF_TRUE`+`THROW_REF` "Unresolvable reference" sequence so a RHS side effect (e.g. `this.undeclared = 5` creating a global) cannot retroactively make the LHS resolvable. The new opcode is inoperative in non-strict code (kept the original GETVAR strip).
- [ ] **L2** — Direct eval var-hoisting into caller/global scope.
- [x] **L3** — Indirect eval var-hoisting: no failing tests as of s289d full run; reopen only with a concrete repro.
- [x] **X1** — Array fast-path key truncation fixed (session 289). NOTE: the companion "`(o?.m)()` must call with undefined this" diagnosis was WRONG and its fix was reverted (session 289c) — a non-short-circuited optional chain is a Reference; parens preserve the receiver (test262 `optional-call-preserves-this.js` is authoritative). Don't re-introduce.
- [x] **X2** — Arrow reparse body `PUSH_VAR` + named-funcexpr shadowing landed (session 289, plan 059 §1b/1e); `scope-paramsbody-var-*` + `call/scope-var-open` pass.
- [ ] **E1** — Eval-super residual (plan 059 §2-3): object-literal-method eval-super (`eval-code/direct/super-prop-method.js` FAIL + `super/prop-{dot,expr}-obj-val-from-eval.js` skip-listed — `__super__` lives in an uncaptured PUSH_LEX scope), `eval("super()")` in derived ctors (`is_constructable` hardcoded false in compile_eval), nested-eval `new.target` (eval CFs are `is_global`), and `super` in plain fn-expr must be an early SyntaxError. DONE session 289: arrow `eval_mode` propagation (§1c) and class-method eval-super (caller `has_home_object` propagation, via opencode-jul merge).
- [x] **E2 (residual super-prop-method only)** — `language/eval-code/direct/super-prop-method.js` (object-literal method with `eval('super.x')`) passes; remaining eval-super gaps (plain-fn super; `super()` in derived ctor via eval; nested-eval new.target; super/prop-{dot,expr}-obj-val-from-eval in derived ctors) still map to a fully spec-faithful HomeObject propagation that needs the live-frame walk to extend across escapes — see plan 059 §2-3 for the remaining engineering. `lexical-super-call-from-within-constructor.js` (arrow that captures a derived ctor's `super()` and runs after the ctor returns) now passes: the derived ctor's `this` is stamped with `@@__derived_super_called__` on first super() return; the RET handler checks the flag via the arrow's `this_binding` (which equals the captured this) and throws ReferenceError for re-binding. The flag also handles the case where the derived ctor's frame is gone. Session 290.
- [x] **X4** — Arrow with BLOCK body inside a template substitution inside a function silently truncated the program. Root cause: function-body skip/hoist scanners treated the first `}` inside `${...}` as the template-substitution close, but a block-bodied arrow inside the substitution also has `{...}`. They called `scan_template_after_expr()` at the arrow body close and swallowed the rest of the source. Fix: track nested JS brace depth inside template substitutions and only scan the next template part when the substitution's own closing `}` is reached. Session 290.
- [x] **X5** — Named-funcexpr binding through nested closures: fixed incidentally session 289c — `is_named_func_expr` now blocks `can_skip_env`, so every named funcexpr gets a fresh per-call env and the name-env splice chain resolves in walk order (`function/scope-name-var-close.js` passes; all repros verified). The two-walk env model concern stands only as background for plan 059 env work.
- [x] **X3** — Writes to an enclosing function's local from a parameter-default expression: capture pre-scan now buffers identifiers inside non-control `(...)` and flushes them to the captured set when `{` follows `)`. Session 290.
- [x] **AsyncFromSync tick ordering** — the 3 `for-await-of/ticks-*` tests pass: AWAIT always routes through `PromiseResolve(%Promise%, value)` and always suspends via the GeneratorState machinery. The earlier 19 → 331 phase-24 regression from removing the short-circuit was NOT caused by the AWAIT change itself — `vm_call_fn_impl` drained the microtask queue after every native→VM reentry, stealing unrelated queued jobs; now gated to outermost reentry (`saved_act_count == 0`). Also fixed while here: spurious codegen AWAIT after a no-op `ITER_CLOSE_ASYNC` (reg-C signal), and for-of/for-await-of calling IteratorClose on normal exhaustion (spec: abrupt only). Session 291.

## Builtins

- [x] **`arguments` Symbol.iterator** — `[...arguments]`/spread works (verified session 289).
- [x] **Shared iterator prototype `next`** — shared `%ArrayIteratorPrototype%` (session 284); Map/Set iterators inherit `next` from prototype; per-kind prototypes (String vs Array) are spec-correct.
- [x] **BigInt wrapper** — `BigInt` global + prototype, `Object(1n)` wrapper, `BigInt64Array`/`BigUint64Array` all landed (plan 056 + sessions 285-288).
- [x] **S1** — String regexp-prototype-`*` v/u flag handling. Cluster cleared: zero matching failing tests in the s289d full run (34,541/18/0 CE).
- [x] **S2** — String cstm-`*` on BigInt primitive (BigInt wrapper landed; re-run cluster). Cluster cleared: zero matching failing tests in the s289d full run (34,541/18/0 CE).
- [x] **S3** — String indexOf ToInteger ordering. Cluster cleared: zero matching failing tests in the s289d full run (34,541/18/0 CE).
- [x] **S4** — isWellFormed / toWellFormed ToString. Cluster cleared: zero matching failing tests in the s289d full run (34,541/18/0 CE).
- [x] **S5** — String Symbol.iterator on non-obj-coercible. Cluster cleared: zero matching failing tests in the s289d full run (34,541/18/0 CE).
- [x] **O1** — fn-name inference for accessors, arrow, class, gen. Cluster cleared: zero matching failing tests in the s289d full run (34,541/18/0 CE).
- [x] **O2** — Computed accessor names, ToPropertyKey ordering. Cluster cleared: zero matching failing tests in the s289d full run (34,541/18/0 CE).
- [x] **O3** — Method-def name Symbol + generator proto. Cluster cleared: zero matching failing tests in the s289d full run (34,541/18/0 CE).
- [x] **D1** — Date algorithm gaps (toISOString extreme values, setFullYear arg ToNumber, toJSON abrupt propagation). Cluster cleared: zero matching failing tests in the s289d full run (34,541/18/0 CE).
- [x] **T1** — Tagged template site caching. Cluster cleared: zero matching failing tests in the s289d full run (34,541/18/0 CE).
- [x] **T2** — Frozen template object. Cluster cleared: zero matching failing tests in the s289d full run (34,541/18/0 CE).
- [x] **T3** — Invalid escapes → undefined cooked. Cluster cleared: zero matching failing tests in the s289d full run (34,541/18/0 CE).
- [x] **T4** — Tagged template misc. Cluster cleared: zero matching failing tests in the s289d full run (34,541/18/0 CE).
- [x] **Y1** — Symbol.prototype cluster (constructor, description, Symbol.toPrimitive, toStringTag, toString). (Session 283, +17 tests: well-known symbol descriptors, Symbol()/Symbol.for() coercion, registry cleanup)
- [x] **J2** — JSON.stringify edge cases. Cluster cleared: zero matching failing tests in the s289d full run (34,541/18/0 CE).
- [x] **G1** — Expression generators default-proto / prototype descriptor. Cluster cleared: zero matching failing tests in the s289d full run (34,541/18/0 CE).
- [x] **G2** — statements/generators prototype semantics. Cluster cleared: zero matching failing tests in the s289d full run (34,541/18/0 CE).
- [x] **TA1** — TypedArray Integer-Indexed [[DefineOwnProperty]]. Cluster cleared: zero matching failing tests in the s289d full run (34,541/18/0 CE).
- [x] **TA2** — TypedArray Integer-Indexed [[Set]] prototype chain. Cluster cleared: zero matching failing tests in the s289d full run (34,541/18/0 CE).
- [x] **TA3** — TypedArray constructors. Cluster cleared: zero matching failing tests in the s289d full run (34,541/18/0 CE).

## RegExp

- [x] **U1** — `\p{}` wiring landed (B31 libregexp swap); property-escapes tests attempt and pass. Residual: occasional under-load flakiness (see I5) and byte-mode runtime limits (B32) tracked in run_test262.py comments.
- [x] **CharacterClassEscapes** — no matching failing tests as of s289d.
- [x] **R1** — RegExp SIGABRT crash pair: `S15.10.2_A1_T1.js` + `S15.10.2.8_A3_T15.js` abort (exit 134). Root cause: `lre_exec` NULL-initialises `capture[0..2*capture_count-1]` from the compiled bytecode header; the C wrapper used a 64-slot stack array (RE_MAX_CAPTURES=32). Regexps with >31 capture groups overflowed the buffer. Fix: bumped RE_MAX_CAPTURES to 256 (stack) + heap fallback for deeper patterns. Session 290.

- [x] **QoI: huge sparse-array timeouts** — `Array/length/S15.4.5.2_A3_T4.js` + `Object/defineProperty/15.2.3.6-4-116.js`: `array_set_length_desc` (shared ArraySetLength, proxy.c3) shrink branch iterated every integer from oldLen-1 down to newLen (~4e9 `int_to_hstring` calls; the defineProperty test hit it via propertyHelper.js's isWritable probe reverting `length = 4294967295`). Now scans the own property table for array-index keys in [newLen, oldLen) — one pass to find the highest non-configurable blocker, one backward pass to delete above it (mirrors the already-correct `array_set_length` in array.c3). The unshift variant (S15.4.4.13_A3_T2) was already fixed by B40. Session 291.

## Long tail

- [x] **Z** — Long-tail clustering complete: every one of the 18 remaining fails (13 unique tests) is mapped to an open backlog item as of s289d.
- [x] **S6** — `String.prototype.localeCompare` must treat canonically-equivalent strings as equal (`15.5.4.9_CE.js`): NFC-normalize via QuickJS libunicode. Session 289d.
- [ ] **F2** — `Function.prototype.toString` NativeFunction grammar for ALL builtin kinds (`built-in-function-object.js`): accessors obtained via getOwnPropertyDescriptor currently fail the grammar check (agent session 289b fixed nothing here; its diagnosis: getter/setter builtin objects lack proper toString routing).

## Infrastructure

- [ ] **I2** — `$262.detachArrayBuffer` host hook (unblocks TypedArray callback tests).
- [x] **I3** — CE:unexpected is 0 as of s286 and maintained through s289d.
- [ ] **I4** — Two-consecutive-run zero-fail gate once <50 fails; enforce in CI.
- [x] **Batch-runner SIGSEGV** — solved (double-free on vm_create-fail + IC-key UAF, dc0af6d); batches deterministic since.
- [ ] **I5** — RegExp property-escapes + CharacterClassEscapes tests flaky in parallel runs (pass 3/3 isolated; different tests each full run — s291 saw `Symbol.split/species-ctor` one run, then 5 property-escapes + 1 CharacterClassEscapes the next, on a quiet machine). Now the ONLY remaining failure class. A verdict that changes run-to-run is a real non-determinism bug, not load noise. Leading hypothesis: cross-test contamination in the batched worker processes (runner header documents the detect recipe: `--phase 8 --shuffle --workers 1 --no-retry-fails` twice, diff verdicts). Diagnosis agent running as of s291; check the s290 lre_exec capture heap-fallback path too.

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

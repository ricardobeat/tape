# Duktape C3 — Backlog

Pass rates from Session 195 (61.9% overall, ~19,102/26,353 ES5-relevant).

---

- [ ] **Strict-only Phase A** — compile-time errors (see `plans/035-enforce-strict-mode.md`): remove `with` keyword from lexer, drop `is_strict` guards on restricted-name checks (`functions.c3:48,93,185,226,802,847`), unconditionalize octal literal/escape rejects (`expressions.c3:1524,1546`), unconditionalize all 46 destructuring guards, no-op `"use strict"` directive, remove `with_statement` parser
- [ ] **Strict-only Phase A** — NEW CODE: add duplicate-parameter-name rejection in `functions.c3` (no check exists today)
- [ ] **Strict-only Phase B** — remove runtime strict checks: drop `ACT_FLAG_STRICT` (`vm.c3:79`), `is_strict` bitfield (`bytecode.c3:792`), `is_with` env chain (`env.c3`), `WITH_START`/`WITH_END` opcodes + handlers (`vm.c3:8406,8482`), make `arguments.callee`/`caller` always throw, remove 9 mode-propagation call sites
- [ ] **Strict-only Phase B** — KEEP direct-eval machinery (`ACT_FLAG_DIRECT_EVAL`, `has_direct_eval`, `callee_is_eval`, `global.c3:213`): direct eval is valid in strict mode, must not be removed
- [ ] **Strict-only — investigate**: verify eval'd code applies strict scope isolation for declarations (`eval("var x=1")` must NOT leak `x` into the caller's scope). Direct/indirect env selection (`ACT_FLAG_DIRECT_EVAL`, `global.c3:213`) is confirmed present, but declaration isolation inside the eval'd body is unverified. Repro: strict direct eval `let x=10; eval("x+1")` → 11; `eval("var y=2")` then reference `y` → ReferenceError
- [ ] **Strict-only — investigate**: confirm what `delete <identifier>` compiles to today (no unqualified-delete path found); decide if "always throw" is new code
- [ ] **Strict-only — investigate**: confirm implicit-global creation (assignment without `var`) — engine may already throw ReferenceError; verify before scheduling work
- [ ] **Strict-only Phase C** — cleanup: remove `TokenType.WITH` enum entry, any residual `is_strict`-gated paths, verify `is_strict_reserved` (`hstring.c3:78`) still needed
- [ ] **Strict-only Phase D** — test runner + docs: remove `noStrict` skip (`run_test262.py:296-297`), add compile-error result type, update `AGENTS.md`/`PRD.md`/`progress.md` for strict-only philosophy
- [x] Add Phase 15-21 choices to `scripts/run_test262.py` `--phase` argparse (currently restricted to 0-14)
- [x] Add Phase 15-21 support to `scripts/phase_runner.py`
- [x] Verify `just build-batch` produces working `out/batch_test_vm` for batch testing
- [x] Fix `make_default_constructor()` `has_super` fallback (`class.c3:60-76`): now generates `constructor(...args) { super(...args); }` bytecode with SPREAD_ARG + SUPER_CALL_S
- [x] Verify method compilation produces correct CLOSURE+PUTPROP bytecode
- [x] Fix prototype chain setup for `extends`: SETPROTO after constructor returns
- [x] Ensure `constructor()` returns correct `this` binding
- [ ] Check computed property keys in class methods: `class { [expr]() {} }` — ensure expression is evaluated per-instance, not shared
- [x] Fix static method installation: static methods go on constructor, prototype methods go on `.prototype`
- [x] Fix getter/setter in class bodies: INITGET/INITSET opcodes work, OPUTPROP uses WEC flags (enumerable issue pre-existing)
- [x] Fix early-error SyntaxError checks: static prototype, get/set constructor, duplicate constructor, super() in non-constructor methods
- [x] Run pure-class test suite: 149/237 pass (62.9%), 34 correctly rejected at compile time
- [ ] Run full Phase 15 after fixes to measure delta
- [ ] Survey generator test failures and categorize by root cause (compile vs VM vs builtin)
- [ ] Fix `yield` expression handling in compiler: `var x = yield val` — yield is right-associative with lowest precedence
- [ ] Fix `yield*` delegation: should iterate inner iterable and yield each value
- [ ] Fix `Generator.prototype.return()` / `.throw()` — currently likely missing or stubbed
- [ ] Verify `.next()`, `.return()`, `.throw()` state machine transitions per ES6 §25.3
- [ ] Ensure `GeneratorFunction` and `Generator` constructor exist and are reachable
- [ ] Create minimal destructuring regression test (`const [a] = [1]`) and trace bytecode output
- [ ] Debug array destructuring: verify GETPROP with integer indices, binding to target registers
- [ ] Debug object destructuring: verify string-keyed GETPROP, correct binding to named targets
- [ ] Debug destructuring with rest: `[a, ...rest] = arr`
- [ ] Debug destructuring default values: `[a = 42] = arr`
- [ ] Debug nested destructuring: `const {x: {y}} = obj`
- [ ] Debug destructuring in for-of: `for (const [k, v] of pairs) {}`
- [ ] Verify `async function` compilation: `is_async` flag propagated through `compile_inner_function`
- [ ] Verify `AWAIT` opcode handles settled Promise (extract result) vs pending (suspend + reaction)
- [ ] Test async function without await (should return resolved Promise)
- [ ] Test async function with single await (should suspend and resume)
- [ ] Test async error handling: rejected promise inside async function should reject the returned promise
- [ ] Test `await` in `for`/`while` loops (repeated suspend/resume)
- [ ] Fix remaining postfix `++`/`--` member writeback edge cases after GETPROP patching refactor
- [ ] Run full ES5 test262 suite and measure delta from 61.9% baseline

# Duktape C3 — Backlog

Pass rates from Session 195 (61.9% overall, ~19,102/26,353 ES5-relevant).

---

## Infrastructure — Enable Phase 15+ Testing

- [x] Add Phase 15-21 choices to `scripts/run_test262.py` `--phase` argparse (currently restricted to 0-14)
- [x] Add Phase 15-21 support to `scripts/phase_runner.py`
- [x] Verify `just build-batch` produces working `out/batch_test_vm` for batch testing

## Classes (Phase 15) — 359/8520 pass (4.2%), 3020 failures

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

## Generators (Phase 21) — 27/619 pass (4.4%), 462 failures

- [ ] Survey generator test failures and categorize by root cause (compile vs VM vs builtin)
- [ ] Fix `yield` expression handling in compiler: `var x = yield val` — yield is right-associative with lowest precedence
- [ ] Fix `yield*` delegation: should iterate inner iterable and yield each value
- [ ] Fix `Generator.prototype.return()` / `.throw()` — currently likely missing or stubbed
- [ ] Verify `.next()`, `.return()`, `.throw()` state machine transitions per ES6 §25.3
- [ ] Ensure `GeneratorFunction` and `Generator` constructor exist and are reachable

## Destructuring (Phase 12-13) — 0/19 pass (0%)

- [ ] Create minimal destructuring regression test (`const [a] = [1]`) and trace bytecode output
- [ ] Debug array destructuring: verify GETPROP with integer indices, binding to target registers
- [ ] Debug object destructuring: verify string-keyed GETPROP, correct binding to named targets
- [ ] Debug destructuring with rest: `[a, ...rest] = arr`
- [ ] Debug destructuring default values: `[a = 42] = arr`
- [ ] Debug nested destructuring: `const {x: {y}} = obj`
- [ ] Debug destructuring in for-of: `for (const [k, v] of pairs) {}`

## Async/await

- [ ] Verify `async function` compilation: `is_async` flag propagated through `compile_inner_function`
- [ ] Verify `AWAIT` opcode handles settled Promise (extract result) vs pending (suspend + reaction)
- [ ] Test async function without await (should return resolved Promise)
- [ ] Test async function with single await (should suspend and resume)
- [ ] Test async error handling: rejected promise inside async function should reject the returned promise
- [ ] Test `await` in `for`/`while` loops (repeated suspend/resume)

## Stretch / Investigate

- [ ] Investigate `with` statement edge cases in strict mode throw path
- [ ] Audit `arguments` object for remaining ES5 §10.6 compliance gaps (caller, callee in strict mode)
- [ ] Audit `eval()` direct vs indirect distinction: verify scope chain is correct for nested direct eval
- [ ] Fix remaining postfix `++`/`--` member writeback edge cases after GETPROP patching refactor
- [ ] Run full ES5 test262 suite and measure delta from 61.9% baseline

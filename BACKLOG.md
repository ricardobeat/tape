# Duktape C3 — Backlog

Baseline as of Session 215 (2026-06-21):

| Phase | Total | Pass | Fail | Skip | CE  |
|-------|-------|------|------|------|-----|
| 1: Calling Convention & Closures | 426 | 153 | 76 | 86 | 111 |
| 2: Basic Operators | 1969 | 1167 | 141 | 563 | 98 |
| 3: Object System | 7766 | 4948 | 1465 | 744 | 609 |
| 4: Error Handling & References | 402 | 131 | 82 | 95 | 94 |
| 5: Built-in Constructors | 8615 | 5804 | 2111 | 669 | 31 |
| 6: Built-in Prototype Methods | 4713 | 3013 | 1383 | 300 | 17 |
| 7: Remaining ES5 Features | 1240 | 315 | 177 | 635 | 113 |

---

## High Impact — VM / Core

- [x] **B01** — `String.prototype.replace` with string pattern + function replacer: callback received wrong args (offset was `[object Object]`). Fixed in session 216: string-search path now checks if replacer is callable and calls it with `(match, offset, originalString)`. +8 phase 3, +12 phase 6.

- [x] **B02** — Chained property access on lightfunc builtins: `Object.keys.length` returns `undefined` but `var f = Object.keys; f.length` returns `1`. Fixed in session 216: GETPROPC2 lightfunc hop-2 branch now resolves `.name`/`.length`/`.prototype` from metadata (mirroring GETPROP/GETPROPC). +63/+50/+13 across phases 3/5/6.

- [x] **B03** — `fn.caller` and `fn.arguments` throw TypeError. Fixed in session 216: added "caller"/"arguments" cases in GETPROP/GETPROPC lightfunc and function-object branches in `src/vm.c3`. +4 phase 4.

- [ ] **B04** — `new Function("a", "a", "return;")` (duplicate parameter names) crashes with VM_ERROR instead of succeeding (non-strict body should allow duplicate params). The Function constructor compile path runs with `is_strict=true` but spec says params are non-strict unless body contains "use strict". Estimated: ~15 phase 1 tests. File: `src/builtins/global.c3` or `builtin_eval` / Function constructor path.

---

## High Impact — String Methods

- [ ] **B05** — `String.prototype.match` failures: `string_proto_get_this` already handles non-string `this` via `ToString`. Actual failures are: `hasOwnProperty` on lightfuncs (covered by B02 follow-up), `new String.prototype.match()` TypeError, named capture group edge cases. Needs re-investigation — ~14/30 sampled tests fail for unrelated reasons.

- [ ] **B06** — `String.prototype.slice` / `String.prototype.substring` called on wrapper objects (`new Boolean(false)`, `new Number(42)`): `String.prototype.slice.call(new Boolean(false), 1)` should call `ToString` on receiver and work. Basic case works; failures are edge cases with `undefined` end argument from hoisted-but-uninitialized `var`. Needs investigation — may be TDZ/hoisting related. Estimated: ~60 phase 6 tests.

---

## High Impact — Object / Property System

- [x] **B07** — `Object.defineProperties` failures: root cause was `JSON` and `Math` objects missing `Object.prototype` as their prototype, so `JSON.hasOwnProperty` was undefined → VM_ERROR when tests called it. Fixed in session 216: set `json.prototype = heap.object_proto` in `register_json_object` and `math.prototype = heap.object_proto` in `register_math_object`. Covered by B02 fix (+126 total).

- [x] **B08** — `Math[Symbol.toStringTag]`, `JSON[Symbol.toStringTag]`, `Array.prototype[Symbol.toStringTag]`. Fixed in session 216: set `@@toStringTag` string properties in `register_math_object`, `register_json_object`, and `register_array_constructor`.

- [ ] **B09** — `Function.prototype.name` property on anonymous functions assigned to variables: `var f = function() {}; f.name` should be `"f"` (ES2015+ name inference). Currently only named function expressions set `.name`. Estimated: ~40 phase 1/5 tests.

---

## Medium Impact — Built-in Correctness

- [ ] **B10** — `JSON.stringify` failures (~40% of 66 tests fail): property ordering, replacer array, and `toJSON` method on Date. Run failing tests to isolate specific root causes before fixing.

- [ ] **B11** — `Date` constructor and methods (~40% of 78 tests fail): `new Date(year, month, day)` and arithmetic work, but other forms fail with VM_ERROR. Likely missing static methods or `Date.prototype` method edge cases. Run failing tests to identify.

- [ ] **B12** — `Math` object missing `Symbol.toStringTag` and possibly some ES2015+ methods (`Math.clz32`, `Math.fround`, `Math.hypot`, `Math.imul`, `Math.log10`, `Math.log2`, `Math.sign`, `Math.trunc`, `Math.cbrt`, `Math.expm1`, `Math.log1p`, `Math.sinh`, `Math.cosh`, `Math.tanh`, `Math.asinh`, `Math.acosh`, `Math.atanh`). Check which are absent. Estimated: ~30 tests.

- [x] **B13** — `trimStart`/`trimEnd` off-by-one: `data[start..len]` used C3's inclusive `..` range, adding one extra byte. Fixed in session 216: use `data[start:len-start]` / `data[0:end]` (length-based slices).

- [ ] **B14** — Array methods called on non-array objects with `.length` (generic array method behavior): `map`, `filter`, `forEach`, `reduce` etc. are compiled JS polyfills — they should work generically. Failing tests may be using `arguments` object or other array-likes. Investigate specific failures (~20%).

---

## Lower Impact / Needs Investigation

- [x] **B15** — Variable shadowing through the call/return boundary. A function with parameters but no body locals would share the parent's variable environment; its DECLVAR instructions for each parameter then wrote into the shared env and clobbered any outer binding whose name matched. Classic reproducer: `function isSameValue(a, b) { ... }` followed by `var b = ...; isSameValue(...)` — after the call, `b` held the arg instead of the original object. Same bug masked itself in many failing test262 tests where helper functions use generic param names. Two fixes in `src/vm/vm_execute.c3`: (1) extend the `needs_env` check to also allocate a fresh function-scope env whenever a function has parameters without default expressions — preserving the params-vs-body split for default-param thunks via the `needs_lex_bridge` exception; (2) bridge the captured lex_env into the new activation when it's a declarative block scope, so closures inside the body can see enclosing let/const bindings. Phase 1 +8 pass, Phase 3 +95 pass, Phase 8 +23 pass (compared to pre-fix baseline; phases have ~20-test parallel-runner flakiness).

- [ ] **B16** — Phase 4 Error Handling (86 fail, 94 CE): CE rate is very high relative to test count. Likely the compiler is incorrectly rejecting valid try/catch/finally patterns or error subclassing. Investigate specific CE failures.

- [ ] **B17** — Phase 7 (177 fail, 635 skip): high skip count suggests many tests require features behind flags. Of the 177 actual failures, investigate top clusters.

- [ ] **B18** — `Object.prototype.toString.call(x)` returning wrong tags: `[object Boolean]`, `[object Number]`, `[object String]` for wrapper objects; `[object Arguments]`, `[object RegExp]`, `[object Date]`, `[object Error]`, `[object JSON]`, `[object Math]`. Audit which tags are missing or wrong.

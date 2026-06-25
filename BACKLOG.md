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

- [ ] **B04** — `new Function("a", "a", "return;")` (duplicate parameter names) crashes with VM_ERROR instead of producing a SyntaxError compile error. Per the strict-only design, duplicate params are rejected at parse time (the `noStrict` test262 path is intended to remain as CE). If we want a clean SyntaxError instead of VM_ERROR, see `src/builtins/function.c3` Function constructor compile path. Estimated: ~15 phase 1 tests remain as CE regardless.

---

## High Impact — String Methods

- [x] **B05** — `String.prototype.match` failures: missing `.index`/`.input` on non-RegExp result, non-RegExp arg didn't honor ToPrimitive (used `builtin_to_string` instead of `builtin_to_string_vm`), and ES5.1-vs-ES2015 null/undefined handling. Fixed in session 219: added the missing props, switched to `builtin_to_string_vm`, and routed missing/nullish args through `create_regexp_from_string` per ES2015 §21.1.3.10 step 4. Added `test/test_match_fixes.js`.

- [ ] **B06** — `String.prototype.slice` / `String.prototype.substring` called on wrapper objects (`new Boolean(false)`, `new Number(42)`): `String.prototype.slice.call(new Boolean(false), 1)` should call `ToString` on receiver and work. Basic case works; failures are edge cases with `undefined` end argument from hoisted-but-uninitialized `var`. Needs investigation — may be TDZ/hoisting related. Estimated: ~60 phase 6 tests.

---

## High Impact — Object / Property System

- [x] **B07** — `Object.defineProperties` failures: root cause was `JSON` and `Math` objects missing `Object.prototype` as their prototype, so `JSON.hasOwnProperty` was undefined → VM_ERROR when tests called it. Fixed in session 216: set `json.prototype = heap.object_proto` in `register_json_object` and `math.prototype = heap.object_proto` in `register_math_object`. Covered by B02 fix (+126 total).

- [x] **B08** — `Math[Symbol.toStringTag]`, `JSON[Symbol.toStringTag]`, `Array.prototype[Symbol.toStringTag]`. Fixed in session 216: set `@@toStringTag` string properties in `register_math_object`, `register_json_object`, and `register_array_constructor`.

- [x] **B09** — `Function.prototype.name` property on anonymous functions assigned to variables: `var f = function() {}; f.name` should be `"f"` (ES2015+ name inference). Fixed in session 219: threaded an `inferred_name` buffer through `var_declaration`, `function_expr`, `function_expr_body`, `parse_arrow_function[_reparse]`, and object literal property parsing per ES2015 §14.1.20 SetFunctionName. Object method shorthand, getter/setter (with `"get "/"set "` prefix), class methods (same prefix logic in `class.c3`), and arrow functions all get their target's name. `compile_inner_function` now heap-allocates the function name (was a slice into a caller buffer that got reused). Added `test/test_name_inference.js`.

---

## Medium Impact — Built-in Correctness

- [x] **B10** — `JSON.stringify` property ordering: ES5 §15.12.3 step 4.b.ii requires integer-indexed keys first in ascending numeric order, then string keys in original insertion order. Fixed in session 218: replaced chain-pointer reversal with `prop_key_at(i)` snapshot (already walks shape in insertion order) and split into integer-vs-string keys with insertion-sort on the integers. Note: a deeper shape/prop_values delete+re-add scrambling bug still affects some test262 property-order tests, separate from JSON.

- [ ] **B11** — `Date` constructor and methods (~40% of 78 tests fail): `new Date(year, month, day)` and arithmetic work, but other forms fail with VM_ERROR. Likely missing static methods or `Date.prototype` method edge cases. Run failing tests to identify.

- [ ] **B12** — `Math` object missing `Symbol.toStringTag` and possibly some ES2015+ methods (`Math.clz32`, `Math.fround`, `Math.hypot`, `Math.imul`, `Math.log10`, `Math.log2`, `Math.sign`, `Math.trunc`, `Math.cbrt`, `Math.expm1`, `Math.log1p`, `Math.sinh`, `Math.cosh`, `Math.tanh`, `Math.asinh`, `Math.acosh`, `Math.atanh`). Check which are absent. Estimated: ~30 tests.

- [x] **B13** — `trimStart`/`trimEnd` off-by-one: `data[start..len]` used C3's inclusive `..` range, adding one extra byte. Fixed in session 216: use `data[start:len-start]` / `data[0:end]` (length-based slices).

- [x] **B14** — Generic Array methods on non-array objects with `.length` (arguments, plain objects, sparse sources). Fixed in session 218: three real bugs. (1) `arr_has_prop`/`arr_get_elem_vm` only consulted `array_part` for `ObjClass.ARRAY`; arguments stores indexed values in `array_part` but its class is ARGUMENTS — added ARGUMENTS to the fast path. (2) `Array.prototype.map` skipped holes for sparse sources like `{0:'a',2:'c',length:3}`; per ES5 §15.4.4.19 step 8.c the callback must be invoked for every k in [0,len) with undefined for holes — loop now always invokes and writes at the next sequential index. (3) `json_serialize_array` read length only from the named `length` prop; arrays from `Array.prototype.slice` on arguments have length only in the cached `array_length` pointer — falls back to `*arr.array_len_ptr()` for ARRAY class. Added `test/test_array_generic.js` (10 assertions).

---

## Lower Impact / Needs Investigation

- [x] **B15** — Variable shadowing through the call/return boundary. A function with parameters but no body locals would share the parent's variable environment; its DECLVAR instructions for each parameter then wrote into the shared env and clobbered any outer binding whose name matched. Classic reproducer: `function isSameValue(a, b) { ... }` followed by `var b = ...; isSameValue(...)` — after the call, `b` held the arg instead of the original object. Same bug masked itself in many failing test262 tests where helper functions use generic param names. Two fixes in `src/vm/vm_execute.c3`: (1) extend the `needs_env` check to also allocate a fresh function-scope env whenever a function has parameters without default expressions — preserving the params-vs-body split for default-param thunks via the `needs_lex_bridge` exception; (2) bridge the captured lex_env into the new activation when it's a declarative block scope, so closures inside the body can see enclosing let/const bindings. Phase 1 +8 pass, Phase 3 +95 pass, Phase 8 +23 pass (compared to pre-fix baseline; phases have ~20-test parallel-runner flakiness).

- [x] **B16** — Phase 4 Error Handling (NativeErrors.prototype.constructor returning undefined for chained access like `URIError.prototype.constructor`). Root cause was GETPROPC2 (fused two-hop GETPROP) only handling `rb.is_object()` for hop 1 — when the source was a lightfunc (URIError is a lightfunc), it fell through to "both hops fail". Fixed in session 219: added lightfunc source handling for hop 1 that mirrors the non-fused GETPROP path (resolves .name/.length/.prototype from BuiltinMeta, walks Function.prototype for others). Also fixed an adjacent bug where the string-intermediate `.length` fast path compared key2_hstr by pointer to `BuiltinStr.LENGTH` only — constant-pool interns "length" as a different HString instance, so the fast path missed and the slow path returned undefined. Added `test/test_native_errors.js` covering all 8 NativeError ctors, three chained access patterns, and descriptor attributes.

- [ ] **B17** — Phase 7 (177 fail, 635 skip): high skip count suggests many tests require features behind flags. Of the 177 actual failures, investigate top clusters.

- [x] **B18** — `Object.prototype.toString.call(x)` tags. Fixed in session 218: five distinct bugs. (1) `builtin_object_proto_toString` only handled the object branch — primitives fell through to `[object Object]`. Added TVal.is_undefined/is_null/is_boolean/is_number/is_fastint/is_string branches plus is_symbol_val before the object path. Reordered so symbol check fires before string check (Symbols are stored as strings internally). (2) Missing ARGUMENTS case in the class-name switch. (3) All TypedArray constructors shared a single %TypedArray%.prototype with @@toStringTag="TypedArray", so `Object.prototype.toString.call(new Uint8Array(2))` returned `[object TypedArray]` instead of `[object Uint8Array]`. Per ES6 §22.2, each ctor needs its own .prototype — `register_ta_ctor` now allocates a per-ctor proto that inherits from the shared one with its own @@toStringTag. (4) To find the per-ctor proto, builtins need access to the callee HObject; the NEW_OBJ[_S] and super-call paths in `src/vm/vm_execute.c3` were setting `ctx.callee_obj = null` — now they set it to `hobj`/`super_hobj`. (5) `builtin_typed_array_shared` now reads the instance's [[Prototype]] from `ctx.callee_obj.get_prop("prototype")` instead of using the shared `ctx.heap.typedarray_proto` directly. Added `test/test_tostring_tags.js`.

- [x] **B19** — GETPROPC2 incomplete: number/boolean source handling missing, and simplified hop 2 dispatchers (string/number/boolean rb paths) lacked lightfunc intermediate handling. `(true).constructor.name.length` → VM_ERROR; `(42).constructor.name` → undefined. Fixed in session 220: (1) added `rb.is_number()/is_fastint()` and `rb.is_boolean()` branches to GETPROPC2 for hop 1 auto-box lookup; (2) added `mid_val.is_lightfunc()` handling to all simplified hop 2 dispatchers (string, number, boolean rb paths) so they resolve `.name`/`.length`/`.prototype` from BuiltinMeta and walk Function.prototype for other keys; (3) B16's lightfunc hop 1 fix was also incomplete — "name" and "length" cases stored the result in `ra` (temp reg) but never set `mid_val`, so hop 2 always saw undefined. Now sets `mid_val` correctly and uses the full hop 2 dispatch (object IC + lightfunc + string + number + boolean intermediates). Side-effect: `test_tostring_tags.js` exit-code-1 VM_ERROR resolved (was hitting the broken GETPROPC2 paths).

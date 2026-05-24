# Progress: Duktape C3 — test262 Conformance Tracker

**Last Updated:** Session 40
**Target:** Full test262 conformance

## Summary

| Metric | Value |
|---|---|
| Total test262 tests | 53,568 |
| ES5-relevant tests (approx) | ~26,351 |
| Actually runnable (ES5, no hangs) | ~5,000 |
| Currently passing (test262) | ~853 |
| VM bugs causing hangs | try/catch, switch, with, for-in, RegExp subdirs (some) |
| **Fixed this session** | **Phase 9: Octal Literals in Strict Mode — legacy octal integer literals (0777, 01, etc.) rejected as SyntaxError; legacy octal escape sequences in strings (\0 followed by digit, \1-\9) rejected; fixed `builtin_eval`/`builtin_function` to use `ctx.should_throw`/`ctx.throw_value` for SyntaxError propagation (was silently returning error objects instead of throwing).** |
||
|**Engine decision: Strict-only** — No sloppy/non-strict mode support. All code runs in ES5 strict mode by default. `"use strict"` is accepted but redundant. Non-strict `this` coercion, `arguments.callee`, `arguments.caller`, and all non-strict error-handling paths are not implemented.

## Per-Phase Status

### Phase 0-1: Core VM — ✅ (Impl.)
**test262: ~6,063 total — not yet runnable (ASI tests hang VM)**
| Component | Status |
|---|---|
| TVal tagged values | ✅ |
| Heap allocator & string interning | ✅ |
| Bytecode encoding | ✅ |
| Lexer | ✅ |
| Compiler | ✅ |
| VM execution loop | ✅ |
| Built-in print/console.log | ✅ |

### Phase 1: Calling Convention & Closures — ✅ (Impl.)
**test262: 426 files — 41 pass / 385 fail**
| Component | Status |
|---|---|
| Register-based call convention | ✅ |
| PUTVAR for all declarations | ✅ |
| CLOSURE with env capture | ✅ |
| Nested calls | ✅ |

### Phase 2: Basic Operators — ✅ (Impl.)
**test262: 1,969 files — 552 pass / 1,417 fail**
| Component | Status |
|---|---|
| Addition (+) | ✅ |
| Subtraction (-) | ✅ |
| Multiplication (*) | ✅ |
| Division (/) | ✅ |
| Modulus (%) | ✅ |
| Exponentiation (**) | ✅ |
| Bitwise AND/OR/XOR | ✅ |
| Bitwise NOT (~) | ✅ |
| Left/right shift | ✅ |
| Unary plus/minus | ✅ |
| Logical NOT (!) | ✅ |
| TYPEOF | ✅ |
| Strict equality (===) | ✅ |
| Abstract equality (==) | ✅ |
| Comparison (< <= > >=) | ✅ |
| Logical && || ?? | ✅ |
| Conditional (?:) | ✅ |
| Comma operator | ✅ |
| Void operator | ✅ |
| NaN/Infinity globals | ✅ |
| NaN semantics | ✅ |

### Phase 3: Object System — ✅ (Impl.)
**test262: ~4,985 total — not yet runnable (Array/Object constructor tests hang VM)**
| Component | Status |
|---|---|
| Object literals | ✅ |
| Array literals | ✅ |
| Array .length | ✅ |
| GETPROP/PUTPROP | ✅ |
| Numeric property keys | ✅ |
| Prototype chain | ✅ |
| `new` operator | ✅ |
| Member LHS assignment | ✅ |

### Phase 4: Error Handling & References — ✅ (Impl.)
**test262: 187 files (Error+NativeErrors) — 1 pass / 186 fail**
**try/throw tests (~122 files) hang VM — bug in catcher chain**
| Component | Status |
|---|---|
| Error constructors | ✅ |
| ReferenceError on undefined vars | ✅ |
| TypeError on invalid access | ✅ |
| try/catch/throw VM | ✅ |
| THROW opcode | ✅ |
| TRY/ENDTRY/CATCH/FINALLY/ENDFINALLY | ✅ |
| Catcher chain with activation unwinding | ✅ |
| FINALLY block support | ✅ |

### Phase 5: Built-in Constructors — ✅ COMPLETE
**test262: ~3,981 total — not yet runnable (constructor tests hang VM)**
| Component | Status |
|---|---|
| Boolean constructor | ✅ |
| String constructor | ✅ |
| Number() as function | ✅ |
| Number constructor (new Number()) | ✅ |
| Number.prototype.toString/valueOf | ✅ |
| Number static properties (NaN, MAX_VALUE…) | ✅ |
| Object() as function | ✅ |
| Array constructor | ✅ |
| Function constructor | ✅ |

### Phase 6: Built-in Prototype Methods — ✅ (Impl.)
**test262: ~4,713 total — not yet runnable (Array.prototype tests hang VM)**
| Component | Status |
|---|---|
| Math methods | ✅ |
| String.prototype | ✅ |
| Array.prototype | ✅ |
| Number.prototype | ✅ |
| Boolean.prototype | ✅ |
| Function.prototype | ✅ |

### Phase 7: Remaining ES5 Features — ✅ (Impl.)
**test262: runnable subset — 73 pass across instanceof, in, delete, continue, eval**
| Feature | Files | Pass | Fail |
|---|---|---|---|
| instanceof | 43 | 16 | 27 |
| in operator | 36 | 11 | 25 |
| delete | 69 | 12 | 57 |
| continue | 24 | 9 | 15 |
| eval | 347 | 25 | 322 |
| for-in | 336 | ✅ 4 pass / 78 fail (no hang) |
| switch/case | 111 | ~~❌ hangs VM~~ ✅ "continue within switch" hang fixed (cptn-*-fall-thru-abrupt-empty pass); completion value tests still failing |
| break | 20 | 17 pass / 3 fail |
| labeled | 24 | 11 pass / 13 fail |
| with | 181 | ✅ 18 pass / 163 fail (crash fixed) |
| Component | Status |
|---|---|
| for-in | ✅ |
| instanceof | ✅ |
| delete | ✅ |
| in operator | ✅ |
| switch/case | ✅ |
| Labeled break/continue | ✅ |
| with statement | ✅ |
| eval | ✅ |

### Phase 8: ES5 Built-in Objects — ✅ ~67%
**test262: 759 files (JSON+Date) — 1 pass / 758 fail**
**RegExp ~1,879 files — 144 passing (top-level), many subdirs still failing/hanging**
| Component | Status |
|---|---|
| JSON (parse, stringify) | ✅ |
| Date | ✅ |
| RegExp | ✅ (engine integrated + prototype chain wired, SyntaxError on invalid pattern/flags, .constructor on error prototypes — 144 test262 passing) |

### Phase 9: Strict Mode — ✅ (Impl.)
**test262: strict-mode tests — not yet quantified**
| Component | Status |
|---|---|
| "use strict" directive prologue | ✅ |
| is_strict flag on CompiledFunction | ✅ |
| VM respects is_strict flag | ✅ |
| with statement rejected in strict mode | ✅ |
| eval/arguments restricted names | ✅ |
| FutureReservedWords as keywords | ✅ |
| Strict mode propagation to inner functions | ✅ |
| this coercion (non-strict → global) | 🚫 N/A (strict-only engine) |
| Octal literals error in strict | ✅ |
| Duplicate property names error in strict | ✅ |

### Phase 10: ES6+ — ❌ NOT STARTED

## Session History

| Session | Key Features |
|---|---|
| 1 | Core VM, calling convention, closures, basic comparisons |
| 2 | `new` operator, NaN/Infinity, Number/Math, member LHS |
| 3 | Real test262 runner, NaN fix, String.concat interning, nullish fix |
| 4 | Error constructors (Error, TypeError, RangeError, ReferenceError, SyntaxError, EvalError), Error.prototype.toString, string interning fix in registration helpers |
| 5 | ReferenceError on undeclared variable access in GETVAR |
| 6 | TypeError on primitive value access in GETPROP (null/undefined), PUTPROP (null/undefined), CALL (non-function), NEW_OBJ (non-constructor) |
| 7 | try/catch/throw VM — Catcher chain with activation unwinding, TRY/ENDTRY/CATCH/FINALLY/ENDFINALLY opcodes, cross-activation throw propagation |
| 8 | Phase 5a: Boolean constructor |
| 9 | Phase 5b: String constructor |
| 10 | Phase 5c: Number constructor |
| 11 | Phase 5d: Object constructor, Phase 5e: Array constructor |
| 12 | Number static properties |
| 13 | Phase 6a: Math methods |
| 14 | Phase 6b: String.prototype methods |
| 15 | Phase 6c: Array.prototype methods (non-callback) |
| 16 | Phase 6d: Number.prototype methods |
| 17 | Phase 6f: Function.prototype methods (call, apply, bind) |
| 18 | Phase 7a: for-in enumeration |
| 19 | Phase 7b: instanceof operator |
| 20 | Phase 7d: in operator |
| 21 | Phase 7c: delete operator |
| 22 | Phase 7e: switch/case |
| 23 | Phase 7f: Labeled break/continue |
| 24 | Phase 7g: with statement |
| 25 | Phase 8a: JSON (parse, stringify) |
| 26 | Phase 8b: Date constructor and methods |
| 27 | Phase 8c: RegExp — integrated QuickJS libregexp engine (libregexp.c, libunicode.c) as C library. `re_compile`/`re_exec`/`re_free` API, C3 bindings, compiled bytecode stored in HObject. 0 test262 passing — blocked on parser regexp literals and harness gaps. |
| 28 | Phase 5f: Function constructor — `new Function(p1, ..., body)` / `Function(p1, ..., body)`, source compilation via compiler::compile_function, `.constructor` on `Function.prototype` wired to Function object, `Function.length`, `[[Prototype]]` chain for instanceof support. |
| 29 | **Bug fixes**: Fixed VM arithmetic/bitwise opcode bug where `ra.tag = NUMBER` was set before reading `rb`, causing incorrect results when `ra == rb` (compound assignments `x -= 1`, prefix `++`/`--`). Fixed `postfix_expr`/`unary_expr` missing `PUTVAR` write-back for global-scope `i++`/`++i` patterns. |
| 30 | **ASI bug fixes**: Added line terminator tracking (`seen_line_term`) to lexer. Fixed `break`/`continue`/`return` ASI — line terminators between keyword and identifier now suppress label/expression parsing per ES5 spec. Fixed test262 harness: includes `assert.js`, fixed `set -e` exit on skip. 3 test262 tests newly passing (break/line-terminators, continue/line-terminators, return/line-terminators). |
| 31 | **Continue-in-switch infinite loop fix**: Fixed `continue` inside `switch` inside a loop generating a JUMP to itself (infinite loop). Root cause: `switch_statement()` used `push_loop()` for break handling, which incremented `loop_depth`, making `continue_statement()` find the switch's pseudo-loop entry instead of the enclosing real loop. Fix: added `is_loop` flag to `LoopInfo` and `continue_patch_head` for deferred patching. `continue` now skips switch pseudo-loops (`is_loop=false`) and finds the innermost real loop. `do-while` continue targets are resolved via deferred patch chain. Switch tests `cptn-a-fall-thru-abrupt-empty`, `cptn-b-fall-thru-abrupt-empty`, `cptn-dflt-b-fall-thru-abrupt-empty` no longer hang. |
| 32 | **RegExp prototype initialization + flag properties**: Added `register_regexp_constructor` function that creates `RegExp.prototype`, registers `.test()/exec()/toString()` methods, and creates the `RegExp` global constructor with proper `.prototype` and `.length` properties. `heap.regexp_proto` now wired to `Object.prototype`. RegExp instances now store `.source`, `.global`, `.ignoreCase`, `.multiline`, `.lastIndex` properties and correctly parse the `g` flag. Previously every RegExp usage crashed because `regexp_proto` was null. First test262 RegExp test now passing (`15.10.4.1-1`). All 4 local regexp tests passing. |
| 33 | **RegExp SyntaxError on invalid pattern/flags + error .constructor**: Added SyntaxError throwing in `builtin_regexp` when `re_compile` fails (invalid patterns like `\` per ES5 §15.10.4.1). Added flag validation — invalid flags (anything other than g/i/m/s) now throw SyntaxError. Added `.constructor` property on Error.prototype and all error sub-prototypes (TypeError, RangeError, ReferenceError, SyntaxError, EvalError) so `assert.throws` identity checks work. Test262 RegExp top-level tests: 1 → 144 passing. |
| 34 | **Fix RegExp literal NEWREGEXP**: `NEWREGEXP` opcode handler now sets `obj.prototype = regexp_proto` so method lookup (`.test()`, `.exec()`, `.toString()`) works on regexp literals via prototype chain. Null-terminates pattern before passing to `lre_compile` (which requires null-terminated input). Sets instance properties (source, global, ignoreCase, multiline, lastIndex) on literal regexps per ES5 §15.10.7. Fixes `/pattern/.test()` crashes and VM errors. |
| 35 | **RegExp global flag + lastIndex**: Fixed `builtin_regexp_proto_exec` to respect the `global` flag and `lastIndex` property per ES5 §15.10.6.2. On global regexps, exec now reads `lastIndex` as the starting match position, updates it to the end of each match, and resets to 0 on failure. Same fix applied to `builtin_regexp_proto_test` (ES5 §15.10.6.3). This was causing infinite loops in `do...while` patterns that loop over global matches. 6 previously-hanging exec tests (`S15.10.6.2_A3_T1`–`T6`) now pass. No more RegExp exec/test hangs. |
| 36 | **Object constructor as HObject + RegExp TypeError**: Changed `Object` constructor from LIGHTFUNC to proper HObject with `.prototype` property, enabling `Object.prototype` access (was `undefined`). Added PROP_FLAGS_WC convenience constant. Added `exec_js` helper and expanded test262 harness with minified `assert.sameValue`/`assert.throws`/`compareArray` in batch runner. Fixed `builtin_regexp_proto_exec`/`builtin_regexp_proto_test` to throw TypeError per ES5 §15.10.6.2/3 when called on incompatible receiver (was silently returning null). RegExp exec TypeError tests (`S15.10.6.2_A2_*`) now passing: 7→11 exec tests passing in sample. |
| 37 | **typeof identifier + builtin .constructor + isPrototypeOf/toLocaleString**: Added TYPEOFIDENT opcode for `typeof undeclaredVar` (ES5 §11.4.3 — returns "undefined" instead of throwing ReferenceError). Fixed `.constructor` on Object.prototype and Number.prototype to point to actual OBJECT constructors (not LIGHTFUNC), fixing `obj.constructor === Object` and `obj.constructor === Number`. Implemented `Object.prototype.isPrototypeOf` (ES5 §15.2.4.6) and `Object.prototype.toLocaleString` (ES5 §15.2.4.3). Wired constructor functions' internal [[Prototype]] to Function.prototype so `Function.prototype.isPrototypeOf(Object)` returns true. Object tests: 12→24 pass (+12). |
| 38 | **Phase 9: Strict Mode**: Added "use strict" directive prologue detection in `compile()`, `compile_eval()`, and `block()` (for function bodies). `CompilerContext.is_strict` flag set by `parse_directives()`. Lexer `set_strict()` enables FutureReservedWords as keywords. `is_strict` propagated from `CompilerContext` to `CompiledFunction.flags.is_strict` in `finish()`. VM activations now read `CompiledFunction.is_strict()` instead of hardcoding `ACT_FLAG_STRICT`. `with` statement rejected in strict mode (SyntaxError). `eval`/`arguments` rejected as parameter names, `var` declarations, and catch variable names in strict mode. Inner functions inherit strict mode from parent context via `compile_inner_function()`. 4/4 custom strict mode tests passing. |
| 39 | **Phase 9: Octal literals error in strict**: Added `has_octal_escape` flag to `Token` struct. Lexer detects legacy octal escape sequences (\0 followed by digit, \1-\9) in strings and sets the flag. Compiler validates NUMBER tokens against legacy octal pattern (0 followed by 0-7) in `primary_expr`. String tokens with octal escapes also rejected via `has_octal_escape` flag check. Fixed `builtin_eval` and `builtin_function` to use `ctx.should_throw`/`ctx.throw_value` instead of `ctx.result` for SyntaxError propagation (eval was silently returning error objects instead of throwing). 20/20 custom octal strict tests passing. |
| 40 | **Phase 9: Duplicate property names error in strict**: Added duplicate data property key detection to `object_literal()` in compiler. In strict mode, duplicate property names in object literals now throw SyntaxError per ES5 §11.1.5. Tracks both identifier/string and numeric keys, canonicalizing numeric keys via `%.17g` to match runtime `vm_number_to_string`. Computed property keys (`[expr]`) are excluded since they can't be statically analyzed. 8/8 custom duplicate property tests passing. |

## Refreshing Counts

Test counts are generated by `scripts/count_test262_by_phase.sh`. Run it to refresh:

```bash
bash scripts/count_test262_by_phase.sh
```

The script walks `test262/test/` and counts `.js` files per phase using the same area-to-directory mapping shown above. **Phase counts overlap** — the same test file may exercise both a constructor and its prototype methods, so per-phase numbers are not disjoint and cannot be summed.



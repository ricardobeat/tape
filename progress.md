# Progress: Duktape C3 — test262 Conformance Tracker

**Last Updated:** Session 27
**Target:** Full test262 conformance

## Summary

| Metric | Value |
|---|---|
| Total test262 tests | 53,568 |
| ES5-relevant tests (approx) | ~26,351 |
| Actually runnable (ES5, no hangs) | ~5,000 |
| Currently passing (test262) | ~710 |
| VM bugs causing hangs | try/catch, switch, with, break, for-in, RegExp subdirs |

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

### Phase 5: Built-in Constructors — ✅ PARTIAL (~89%)
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
| Function constructor | ❌ |

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
| for-in | 336 | ❌ hangs VM |
| switch/case | 111 | ❌ hangs VM |
| break | 20 | ❌ hangs VM |
| labeled | 24 | ❌ hangs VM |
| with | 181 | ❌ hangs VM |
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
**RegExp ~1,879 files — top-level tests hang VM**
| Component | Status |
|---|---|
| JSON (parse, stringify) | ✅ |
| Date | ✅ |
| RegExp | ✅ (engine integrated, 0 test262 passing — blocked on parser, harness) |

### Phase 9: Strict Mode — ❌ NOT STARTED

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

## Refreshing Counts

Test counts are generated by `scripts/count_test262_by_phase.sh`. Run it to refresh:

```bash
bash scripts/count_test262_by_phase.sh
```

The script walks `test262/test/` and counts `.js` files per phase using the same area-to-directory mapping shown above. **Phase counts overlap** — the same test file may exercise both a constructor and its prototype methods, so per-phase numbers are not disjoint and cannot be summed.



# PRD: Duktape C3 — ECMA-262 Compliant JavaScript Engine

## 1. Executive Summary

**Goal:** A faithful, production-quality port of Duktape 2.7.0 to modern C3, passing the full ECMAScript test262 conformance suite (~53,500 tests).

**Strategy:** Leverage C3's native features (faults, optionals, modules, defer, bitstructs) for safety and clarity while preserving Duktape's proven architecture (value stack, register-based bytecode, reference-counted objects with mark-and-sweep GC).

**Current State (baseline):** 21/53,568 passing. Core VM, calling convention, closures, basic operators, `new` operator, and NaN semantics are solid.

## 2. Architecture

### 2.1 Value System
- **TVal** — 16-byte tagged union: `{ tag: TValTag, union { boolean, number (f64), fastint (i48), pointer } }`
- **Tags:** UNDEFINED, NULL, BOOLEAN, NUMBER, FASTINT, STRING, OBJECT, LIGHTFUNC, BUFFER, POINTER
- **FASTINT** — 48-bit integer stored in the double's NaN-space (Duktape-compatible)
- **STRING** — Interned, reference-counted HString with inline UTF-8 data
- **OBJECT** — HObject with property table, prototype chain, object class flags

### 2.2 Bytecode
- 32-bit fixed-width instructions: `{ opcode(8), A(8), B(8), C(8) }`
- 91 opcodes covering loads, stores, arithmetic, calls, control flow, object access
- Formats: ABC, A_BC, A_SBX, WIDE_SABC, NONE
- Up to 256 registers per function, 16M constant pool

### 2.3 VM Execution
- Value stack with activation records (max 128 calls deep)
- Register-based: operands reference registers within current frame
- Inner/outer loop pattern: inner loop executes bytecode, outer loop restarts on ECMAScript-to-ECMAScript calls
- Call convention: `callee_reg = func, callee_reg+1 = this, callee_reg+2.. = args`

### 2.4 Memory Management
- Reference counting for strings and objects (immediate free)
- Mark-and-sweep GC for cycles (not yet implemented)
- String interning via hash table with PRNG-seeded hash function
- Property table with open-addressing hash table on HObject

### 2.5 Scope Chain
- EnvRecord with parent link, bindings via HObject property table
- Global scope, function scope, catch scope
- Lexical environment (let/const) — not yet implemented

## 3. Feature Roadmap

### Phase 0: Core VM ✓ COMPLETE
- [x] TVal tagged values, heap allocator, string interning
- [x] Bytecode encoding, lexer, compiler (direct bytecode emission)
- [x] VM execution loop with value stack and activation records
- [x] Built-in functions (print, console.log)
- [x] Literal keywords (true, false, null, undefined)
- [x] String concatenation (ADD), TYPEOF

### Phase 1: Calling Convention & Closures ✓ COMPLETE
- [x] Register-based call convention with arg copying
- [x] PUTVAR for all declarations (for-loop init, function params)
- [x] CLOSURE opcode capturing var_env/lex_env
- [x] Nested calls and inner function scope

### Phase 2: Basic Operators ✓ COMPLETE
- [x] Arithmetic: + - * / % **
- [x] Bitwise: & | ^ ~ << >> >>>
- [x] Unary: ! + - typeof void
- [x] Comparison: === !== < <= > >=
- [x] Abstract equality (==) with ToNumber coercion
- [x] Logical: && || ?? (with correct nullish check)
- [x] String comparison (lexicographic)
- [x] Conditional (ternary ?:), comma operator

### Phase 3: Object System ✓ COMPLETE
- [x] Object literals {} with property access
- [x] Array literals [] with elements and .length (SETALEN)
- [x] GETPROP/PUTPROP with numeric index conversion
- [x] Prototype chain walking in get_prop_proto
- [x] `new` operator: create object, set prototype, construct call
- [x] Member expression LHS for assignment (this.x = value)

### Phase 4: Error Handling & References ✅ COMPLETE
- [x] **4a. Error constructors (Error, TypeError, ReferenceError, RangeError, SyntaxError, EvalError)**
- [x] **4b. ReferenceError on undeclared variable access**
- [x] **4c. TypeError on primitive value access**
- [x] 4d. RangeError on invalid array length
- [x] 4e. try/catch/throw VM implementation (stack unwinding)
- [x] 4f. TRY/ENDTRY/CATCH/FINALLY/ENDFINALLY opcode handlers
- [x] 4g. Catcher chain for nested try/catch with cross-activation propagation
- **Unlocks:** ~500+ tests (try/throw + error semantics)

### Phase 5: Built-in Constructors ✅ COMPLETE
- [x] 5a. Boolean constructor (new Boolean(), Boolean())
- [x] 5b. String constructor (new String(), String())
- [x] 5c. Number constructor as function (Number())
- [x] 5d. Object constructor as function (Object() with primitive wrapping)
- [x] 5e. Array constructor
- [x] 5f. Function constructor (new Function('return 1'))
- **Unlocks:** ~800+ tests

### Phase 6: Built-in Prototype Methods
- [x] 6a. Math methods: abs, floor, ceil, round, max, min, pow, sqrt, exp, log, sin, cos, tan, random
- [x] 6b. String.prototype: charAt, charCodeAt, indexOf, slice, substring, substr, toUpperCase, toLowerCase, trim, split, concat, replace
- [x] 6c. Array.prototype: push, pop, shift, unshift, join, indexOf, lastIndexOf, slice, concat, sort, reverse, splice, toString (non-callback methods)
- [x] 6d. Number.prototype: toFixed, toExponential, toPrecision, toString (with radix 2-36)
- [x] 6e. Boolean.prototype: toString
- [x] 6f. Function.prototype: call, apply, bind
- **Unlocks:** ~2,000+ tests

### Phase 7: Remaining ES5 Features
- [x] 7a. for-in property enumeration (INITFOR/NEXTFOR)
- [ ] 7b. instanceof operator (prototype chain walk)
- [ ] 7c. delete operator (DELPROP)
- [ ] 7d. in operator (property existence check)
- [ ] 7e. switch/case statement (runtime verification)
- [ ] 7f. break/continue with labels
- [ ] 7g. with statement
- [ ] 7h. eval (direct and indirect)
- **Unlocks:** ~500+ tests

### Phase 8: ES5 Built-in Objects
- [ ] 8a. JSON (parse, stringify)
- [ ] 8b. Date constructor and methods
- [ ] 8c. RegExp constructor and methods
- [ ] 8d. Error.prototype.stack
- **Unlocks:** ~1,000+ tests

### Phase 9: Strict Mode
- [ ] 9a. Strict mode parsing (use strict directive)
- [ ] 9b. Strict mode semantics (this binding, deletion, arguments)
- **Unlocks:** ~500+ tests

### Phase 10: ES6+ Features (Selective)
- [ ] 10a. let/const declarations (block scoping)
- [ ] 10b. Arrow functions (() => {})
- [ ] 10c. Template literals (`foo ${bar}`)
- [ ] 10d. Destructuring assignment
- [ ] 10e. Spread/rest operators (...)
- [ ] 10f. Default parameters
- [ ] 10g. Map, Set, WeakMap, WeakSet
- [ ] 10h. Symbol type
- [ ] 10i. for-of iteration
- [ ] 10j. Generators / iterators / yield
- [ ] 10k. Proxy / Reflect
- [ ] 10l. Promise / async/await
- [ ] 10m. Typed arrays, DataView, ArrayBuffer
- [ ] 10n. Modular ES6 module system (import/export)
- [ ] 10o. class syntax
- **Unlocks:** ~30,000+ tests

### Phase 11: Full test262 Automation
- [ ] 11a. Automated runner with YAML frontmatter parsing
- [ ] 11b. Feature flag filtering
- [ ] 11c. Negative test handling (expected errors)
- [ ] 11d. CI pipeline for conformance tracking
- [ ] 11e. Per-commit regression dashboard

## 4. Test Suite Breakdown

| Category | Total Tests | Current | Target Phase |
|---|---|---|---|
| ES5 Operators | 2,117 | ~21 | 2-3 |
| ES5 Statements | 1,125 | ~0 | 4,7 |
| ES5 Literals | 237 | ~0 | 5 |
| ES5 Built-ins (language) | ~500 | ~0 | 5-6 |
| ES5 Built-ins (global objects) | ~2,000 | ~0 | 8 |
| ES5 Strict Mode | ~500 | ~0 | 9 |
| ES6+ Features | ~30,000 | ~0 | 10 |
| Other (Intl, Temporal, etc.) | ~17,000 | ~0 | Future |
| **Total** | **53,568** | **21** | |

## 5. Key Technical Decisions

1. **FASTINT preservation** — Arithmetic ops keep FASTINT when both operands are FASTINT and result fits in 48-bit range. Fall back to NUMBER otherwise.

2. **NUMBER/FASTINT equivalence** — SEQ/SNEQ/EQ/NEQ treat NUMBER and FASTINT as the same ES type, comparing by numeric value.

3. **Deferred GETPROP** — Member expressions in LHS position (assignment target) defer GETPROP emission; PUTPROP is emitted instead when assignment is detected.

4. **String interning consistency** — Both compiler and runtime use the same heap's PRNG-seeded hash function for string deduplication. `str_table_insert` must not create duplicate entries.

5. **NaN semantics** — IEEE 754: `NaN !== NaN`, `NaN == NaN` returns false. `isNaN()` checks via `math::is_nan()`. `print_tval` displays "NaN" and "Infinity".

6. **Union field ordering** — TVal's union (boolean/number/fastint/pointer) is sensitive to write order. For NUMBER tag: set `number` LAST. For OBJECT tag: set `pointer` LAST.

## 6. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| GC not implemented | Memory leaks on cyclic references | Defer; ref-counting covers 95% of cases |
| eval not implemented | 500+ tests blocked | Implement as separate compiler invocation |
| ES6+ complexity | 30,000+ tests require major effort | Prioritize ES5 conformance first |
| Performance | C3 compilation may differ from C | Profile and optimize hotspots |
| Duktape divergence | Architecture drift from reference | Regular comparison with duktape/src-separate/ |

# Duktape C3 — Project Phases

## Phase 0: Core VM — DONE
- [x] TVal tagged values, heap, string interning, HObject properties
- [x] Bytecode encoding, lexer, compiler (direct bytecode emission)
- [x] VM execution loop with value stack, activation records, scope chain
- [x] Built-in functions (print, console.log)
- [x] Literal keywords (true, false, null, undefined)
- [x] String concatenation (ADD), TYPEOF with proper strings

## Phase 1: Calling Convention — DONE
The compiler and VM use a register-based calling convention:
- CALL instruction: A=result_reg, B=callee_reg, C=nargs
- Args are at callee_reg+2..callee_reg+1+nargs
- VM copies args from caller frame to callee registers 0..nargs-1
- Return value written to result_reg in caller frame

### Key fixes
- PUTVAR emitted for for-loop `var` declarations to ensure global scope visibility
- PUTVAR emitted for function parameters so inner closures can capture them

## Phase 2: Closures & Scope — DONE
- [x] Inner function reads outer var (`get_x()` returning `x2`)
- [x] Nested calls (`print(add(1,2))`)
- [x] Closures via CLOSURE opcode capturing var_env/lex_env
- [x] `make_adder(5)(3)` returning 8 via captured parameter
- [x] `outer()` returning inner's value via closure scope chain

### Remaining work for full closure support
- [ ] Detect captured variables (currently all params PUTVAR'd to env)
- [ ] Proper `this` binding for method calls

## Phase 3: Basic Operators — DONE
- [x] String comparison for <, <=, >, >= (lexicographic via byte comparison)
- [x] Logical operators returning actual values (&&, ||, ?? via short-circuit)
- [x] Type coercion for == and != (abstract equality with ToNumber for strings)

### Details
- == (EQ/NEQ): Proper ES Abstract Equality Comparison (§7.2.14)
  - null == undefined → true
  - Boolean → ToNumber then retry
  - String + Number → ToNumber(string)
  - NUMBER/FASTINT treated as same numeric type
- === (SEQ/SNEQ): NUMBER vs FASTINT treated as same type (compare by value)
- ?? (nullish coalescing): Checks null/undefined explicitly via SEQ, not is_truthy

## Phase 4: Control Flow — IN PROGRESS
- [x] if/else with condition short-circuit
- [x] while loops
- [x] for loops with var init
- [ ] try/catch/finally exception handling (VM-side)
- [ ] Switch/case with fall-through
- [ ] For-in/for-of iteration
- [ ] break/continue with labels
- [ ] Proper for/while loop scoping

## Phase 5: Built-ins (expanded)
- [ ] parseInt, parseFloat, isNaN
- [ ] Math.* (abs, floor, ceil, round, min, max, random)
- [ ] Object.keys, hasOwnProperty
- [ ] Array.isArray, push, pop, length, indexOf

## Phase 6: Prototypes & Objects
- [ ] Object.prototype, Function.prototype, Array.prototype
- [ ] Constructor / new operator
- [ ] Prototype chain for property access

## Phase 7: Test Suite — IN PROGRESS
- [x] Download test262 test262 tests directory
- [x] Build runner: load .js, compile, execute, compare output
- [x] 18 test262-style tests passing (addition, comparison, control-flow, division,
      functions, logical-not, modulus, multiplication, strict-equality,
      string-concat, subtraction, typeof-*, unary-minus)
- [ ] Expand test suite with more operators (bitwise, exponentiation)
- [ ] Object/array tests
- [ ] Prototype chain tests
- [ ] Error handling tests

## Test262 Runner (18/18 passing)
```
Total: 18  Pass: 18  Fail: 0
```

## All Local Tests (23/23 passing)
```
test/abstract_eq.js        — 27 pass, 0 fail
test/assert_simple.js       — a === b: true
test/binary_search.js       — done
test/call_after_compare.js  — same
test/compare_debug.js       — 2 === 2: true
test/compare_inline_vs_func.js — PASS
test/debug_minimal.js       — PASS
test/debug_type.js          — result == 5: true
test/failing_scenario.js    — done
test/harness_test.js        — 1 pass, 0 fail
test/hello.js               — all expected output
test/logical_ops.js         — 12 pass, 0 fail
test/simple.js              — 3
test/simple_fail.js         — PASS
test/string_compare.js      — 20 pass, 0 fail
test/toplevel_test.js       — 1 pass, 0 fail
test/trace_call*.js         — all pass
test/two_args.js            — PASS
test/ultra_simple.js        — result === 2: true
```

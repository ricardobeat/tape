# Duktape C3 — Project Phases

## Phase 0: Core VM — DONE
## Phase 1: Calling Convention — DONE
## Phase 2: Closures & Scope — DONE
## Phase 3: Basic Operators — DONE

## Phase 4: Control Flow — PARTIAL
- [x] if/else with short-circuit
- [x] while loops
- [x] for loops with var init
- [x] do-while loops
- [ ] try/catch/finally exception handling (201 test262 tests) — VM stubs
- [ ] Switch/case with fall-through — compiler done, runtime untested
- [ ] For-in/for-of iteration (115+ tests) — VM stubs
- [ ] break/continue with labels

## Phase 5: Built-ins — PARTIAL
- [x] print, console.log
- [x] parseInt, parseFloat
- [x] isNaN, isFinite
- [ ] encodeURI, decodeURI
- [ ] Math object (abs, floor, ceil, round, min, max, random)
- [ ] Array.prototype (push, pop, length, indexOf)
- [ ] String.prototype (indexOf, slice, charAt)
- [ ] Number, String, Boolean constructor functions

## Phase 6: Prototypes — NOT STARTED
- [ ] Constructor `.prototype` property
- [ ] `new` operator (59 tests) — VM stub
- [ ] Object.prototype methods (toString, valueOf, hasOwnProperty)
- [ ] Prototype chain for primitive wrappers

## Phase 7: Test Suite
- [x] 20 test262-style tests passing
- [ ] Expand to 50+ targeted tests
- [ ] Full test262 automated runner

## Test262 Runner (20/20 passing)
```
addition, builtins, comparison, control-flow, division, functions,
logical-not, modulus, multiplication, operators, strict-equality,
string-concat, subtraction, typeof-*, unary-minus
```

## Next Implementation Session
Priority order:
1. **`new` operator** — medium effort, enables OOP patterns. Needs: create object, set __proto__ to constructor.prototype, call constructor with `this`, return object
2. **for-in** — medium effort. Needs: property enumeration in INITFOR/NEXTFOR (walk HObject prop table)
3. **Built-in Math** — easy. Just register a global `Math` object with methods
4. **try/catch** — high effort. Needs: stack unwinding in VM, proper catch/finally dispatch

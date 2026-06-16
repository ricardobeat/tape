# Duktape C3 — Backlog

Tasks are grouped by area but are otherwise independent.

---

## Conformance: Core VM & Compiler

- [x] Implement function declaration hoisting: pre-scan function declarations in the compiler before emitting body statements (plan 026 #2, `src/compiler/functions.c3`)
- [ ] Implement `var` hoisting: pre-scan `var` declarations and register them with `undefined` before compiling statements (plan 026 #3, `src/compiler/statements.c3`)
- [x] Fix `for (let/const x in obj)` binding: PUSH_LEX/POP_LEX around for-in for proper lexical scoping
- [ ] Fix `try { return 42; } finally { ... }`: `RET` opcode must check for active `finally` catchers, save the return value, run the finally block, then complete the return (plan 026 bonus, `src/vm.c3:5659`)
- [ ] Fix stale `call_prop_obj_reg` after `new X()[a.b].method()`: save/restore around `self.expression()` in the LBRACKET branch of trailing-access loop (plan 026 #8, `src/compiler/expressions.c3:1171`)
- [x] Fix stack overflow: add proper RangeError when activation stack exceeds `MAX_CALLS` instead of producing `NaN` (plan 026 #5, `src/vm.c3`)
- [x] Add complete Unicode code-point iteration for `String.prototype[Symbol.iterator]` (`src/builtins/iterator.c3:364` TODO)
- [ ] Mark `CompiledFunction` constants during GC mark phase (`src/heap.c3:1549` TODO)
- [x] Implement peephole: extend the IF_TRUE optimization after compare instructions to cover all comparison opcodes (compiler/context.c3:392 TODO)
- [x] Fix `arguments` object: callee, length, and indexed access for non-strict functions per ES5 §10.6
- [x] Fix `delete` on non-configurable properties: should return `false` in sloppy mode, throw in strict mode per ES5 §11.4.1
- [x] Implement `eval()` as indirect/direct call distinction: direct `eval()` should share the current scope; indirect `eval()` runs in the global scope


---

## ES6+ Features (Intentionally Planned)

These features are tracked as high-priority items. Tests for them are currently running (not skipped) in test262.

- [x] Implement destructuring binding (`const [a, b] = arr` and `const {x, y} = obj`) — compiler/parser
- [x] Implement destructuring assignment (`[a, b] = arr` and `{x, y} = obj`) — compiler/parser
- [x] Implement default parameters (`function f(x = 42) {}`) — compiler
- [ ] Implement rest parameters (`function f(...args) {}`) — compiler
- [x] Implement object spread (`{...obj}`) — compiler + VM
- [ ] Implement async/await — compiler + VM (requires Promise)
- [ ] Implement class declaration / class expression — compiler (extends, constructor, methods, static fields)

---

## Conformance: Property Descriptors (Plan 022 — highest impact)

- [x] Fix `Object.seal()` / `Object.freeze()` to iterate dense array elements and set their flags non-configurable / non-writable (`src/hobject.c3:495-514`)
- [x] Fix `Object.isSealed()` / `Object.isFrozen()` to check dense array element flags, not just named props (`src/builtins/object.c3:1667-1731`)
- [x] Fix `getOwnPropertyDescriptor` for dense array indices: read actual array-part flags instead of hardcoding `{w:true, e:true, c:true}` (`src/builtins/object.c3:658-697`)
- [x] Complete `defineProperty` §8.12.9: implement partial-descriptor merging for non-configurable accessor↔data transitions (`src/builtins/object.c3:1114-1228`)
- [x] Fix `defineProperty` validation order for combined data+accessor descriptor (array length descriptor validation, string→number coercion, configurable/writable checks)
- [x] Fix `Object.assign` to use `[[Set]]` instead of `put_prop` so setters are invoked and non-writable targets throw (`src/builtins/object.c3:1943`)
- [x] Fix `for-in` enumeration order: emit integer indices ascending, then string keys in insertion order, then Symbol keys (ES2020 §13.7.5.15, `src/vm.c3:884-954`)
- [ ] Audit remaining builtin method `.writable`/`.configurable` flags not matching ES5 §15.3.5.1 (plan 022 Bug F)
- [x] Fix `Object.defineProperties` to apply descriptors atomically: two-phase validate-all-then-apply-all
- [x] Verify `Object.create(null)` produces a truly prototype-less object that passes `Object.getPrototypeOf(o) === null`

---

## Conformance: Built-in Prototype Methods (Plan 023)

- [ ] Implement `String.prototype.normalize(form)` — NFC/NFD/NFKC/NFKD normalization per ES6 §21.1.3.12 (~30 test262 tests)
- [x] Fix `Array.prototype.find` / `findIndex` to accept a `thisArg` second argument and call callback correctly per ES6 §22.1.3.8 (`src/builtins/array.c3`)
- [x] Implement `Array.prototype.flat` and `Array.prototype.flatMap` per ES2019 (~20 tests, phase 6)
- [x] Implement `Array.prototype.at` per ES2022 (~10 tests)
- [x] Implement `String.prototype.at` per ES2022 (~10 tests)
- [x] Implement `Array.prototype.findLast` / `findLastIndex` per ES2023 (~10 tests)
- [x] Fix `Number.prototype.toFixed` for large values and negative fractionDigits edge cases per ES5 §15.7.4.5
- [x] Fix `Number.prototype.toExponential` edge cases (negative fractionDigits, NaN, Infinity) per ES5 §15.7.4.6
- [x] Fix `Number.prototype.toPrecision` edge cases (precision=undefined falls back to toString, range checks) per ES5 §15.7.4.7
- [x] Implement `Error.prototype.toString` to return `name + ": " + message` per ES5 §15.11.4.4 (currently uses default Object.toString)
- [x] Fix sort comparator throws being swallowed in `Array.prototype.sort` (plan 025, `src/builtins/array.c3`)
- [x] Fix JSON replacer throws being swallowed in `JSON.stringify` (plan 025, `src/builtins/json.c3`)
- [x] Fix `String.prototype.lastIndexOf` unsigned underflow: add early-return `if search_len > len` guard (plan 026 #7, `src/builtins/string.c3:1821`)

---

## Conformance: Date

- [x] Implement `Date` constructor string parsing for ISO 8601 (`YYYY-MM-DDTHH:mm:ss.sssZ`) (plan 026 #4, `src/builtins/date.c3`)
- [x] Implement `Date.prototype.toLocaleDateString` / `toLocaleTimeString` / `toLocaleString` stubs returning formatted strings
- [x] Implement `Date.prototype.toUTCString` per ES5 §15.9.5.42 (RFC 7231 format)
- [x] Fix `Date.parse` to accept ISO 8601 strings and return correct milliseconds timestamp
- [x] Fix `new Date(year, month, day, ...)` with month overflow/underflow normalization per ES5 §15.9.1.11
- [x] Implement `Date.prototype.setUTCFullYear` / `setUTCMonth` / `setUTCDate` / `setUTCHours` etc.
- [x] Fix `Date.prototype.getTimezoneOffset` to return correct local-UTC offset in minutes

---

## Conformance: JSON

- [x] Fix `JSON.parse` to set `Array.prototype` on parsed arrays so `.push()` works (plan 026 #1, `src/builtins/json.c3`)
- [x] Fix `JSON.stringify` `replacer` array: only include listed keys in output per ES5 §15.12.3
- [x] Fix `JSON.stringify` `space` argument: honor numeric space > 10 clamped to 10 per ES5 §15.12.3
- [x] Fix `JSON.stringify` with `toJSON()` method on values: call it before serializing
- [x] Fix `JSON.parse` `reviver` function not being called on the root value (only on children)
- [x] Fix `JSON.stringify` to throw `TypeError` on circular references instead of crashing

---

## Conformance: RegExp

- [x] Fix `RegExp.prototype.exec` to update `lastIndex` only when `global` or `sticky` flag is set per ES5 §15.10.6.2
- [x] Fix `String.prototype.match` with non-global regex to return `index` and `input` properties on result array
- [ ] Implement `String.prototype.matchAll` returning a RegExpStringIterator (plan 023)
- [x] Fix `RegExp` constructor called with regex argument: should copy pattern+flags, not re-parse as string
- [x] Fix `RegExp.prototype.source` to return the original pattern text, not stringified form
- [x] Fix `RegExp.prototype.flags` getter to return flags in alphabetical order `gimsuy` per ES2015
- [ ] Add `RegExp.prototype[Symbol.replace]` and `[Symbol.split]` for protocol correctness
- [x] Fix named capture groups: ensure `exec` result has `.groups` property with `undefined` for missing captures

---

## Conformance: Symbol & Well-Known Symbols

- [x] Implement `Symbol.toPrimitive` lookup in `ToPrimitive`/`to_primitive_value` per ES6 §7.1.1
- [x] Implement `Symbol.toStringTag` lookup in `Object.prototype.toString` per ES6 §19.1.3.6
- [x] Implement `Symbol.hasInstance` lookup in `instanceof` operator per ES6 §12.10.4
- [x] Implement `Symbol.isConcatSpreadable` check in `Array.prototype.concat` per ES6 §22.1.3.1
- [x] Fix `Symbol.prototype.toString` to return `"Symbol(description)"` format per ES6 §19.4.3.2
- [x] Fix `Symbol.prototype[Symbol.toPrimitive]` to return the symbol itself per ES6 §19.4.3.5

---

## Conformance: Iterator Protocol & for-of (Plan 025)

- [x] Implement `Symbol.iterator` on `Array.prototype` returning an ArrayIterator per ES6 §22.1.3.29
- [x] Implement `Symbol.iterator` on `String.prototype` returning a StringIterator (Unicode code-point aware)
- [ ] Implement `Symbol.iterator` on `Map.prototype` / `Set.prototype` returning entries/values iterators
- [ ] Implement `for-of` statement desugaring in the compiler: call `Symbol.iterator`, loop `.next()`, check `.done` (`src/compiler/statements.c3`)
- [x] Implement `Array.from` with iterator protocol support (currently only handles array-likes)
- [ ] Implement spread operator `[...iter]` using iterator protocol
- [ ] Implement destructuring assignment `const [a, b] = iter` using iterator protocol

---

## Conformance: Map, Set, WeakMap, WeakSet

- [x] Fix `Map.prototype.forEach` callback to receive `(value, key, map)` in that order per ES6 §23.1.3.5
- [x] Fix `Set.prototype.forEach` callback to receive `(value, value, set)` per ES6 §23.2.3.6
- [x] Implement `Map.prototype.keys` / `.values` / `.entries` returning iterators
- [x] Implement `Set.prototype.keys` / `.values` / `.entries` returning iterators
- [x] Implement `Map` constructor accepting an iterable of `[key, value]` pairs
- [x] Implement `Set` constructor accepting an iterable of values

---

## Conformance: Error Handling

- [ ] Fix `TypeError` message to include the offending value/type in property access on null/undefined
- [x] Fix `RangeError` for `Array` constructor with invalid length (non-integer or > 2^32-1)
- [ ] Fix `SyntaxError` from `eval()` to propagate as a catchable exception
- [x] Fix `try/catch/finally` with `break`/`continue` inside: finally must still run and value must be correct
- [x] Implement `Error.captureStackTrace` stub (returns undefined) so Node.js-style code doesn't crash
- [x] Fix error `stack` property to be a string (currently missing or undefined on thrown errors)

---

## Conformance: Operators & Expressions

- [x] Fix `typeof` on undeclared variables to return `"undefined"` without throwing (currently throws VM_ERROR)
- [x] Fix `==` abstract equality: coerce objects via `ToPrimitive` before comparing with primitives per ES5 §11.9.3
- [x] Fix `+` operator: when one operand is an object, call `ToPrimitive` with no hint (not number hint) per ES5 §11.6.1
- [x] Implement `**` (exponentiation) operator as `Math.pow` per ES2016 §12.6.3
- [x] Fix optional chaining `?.` to short-circuit correctly on `null` and `undefined` (currently parsed but behavior uncertain)
- [x] Fix logical assignment `||=`, `&&=`, `??=` to not assign when short-circuit condition is met per ES2021
- [x] Fix comma operator in `for` init/update to evaluate all expressions and return the last value

---

## Conformance: Miscellaneous ES5/ES6

- [x] Implement `Object.getOwnPropertySymbols` per ES6 §19.1.2.7
- [x] Implement `Reflect.ownKeys` returning string keys + symbol keys per ES6 §26.1.11
- [x] Implement `Object.entries` per ES2017 §19.1.2.5 (returns `[[key,value], ...]` array)
- [x] Implement `Object.fromEntries` per ES2019
- [x] Fix `Function.prototype.toString` to return `"function name() { [native code] }"` for builtins per ES2019
- [x] Implement `globalThis` global binding per ES2020 §18.1
- [x] Fix `with` statement to throw `SyntaxError` in strict mode per ES5 §12.10
- [x] Implement `Array.prototype.copyWithin` per ES6 §22.1.3.3
- [x] Implement `Array.prototype.fill` per ES6 §22.1.3.6
- [x] Implement `Array.prototype.keys` / `.values` / `.entries` per ES6 (array iterator methods)
- [x] Fix `String.prototype.padStart` / `padEnd` for fillString length > 1 character (currently may truncate incorrectly)
- [x] Implement `String.prototype.trimStart` / `trimEnd` per ES2019 (`trimLeft`/`trimRight` aliases too)

---

## Performance

- [ ] Replace `dispatch_builtin` 290-case `switch` with a function-pointer table (`src/builtins/core.c3`) — estimated 1.5× speedup on `bench_function_call`
- [ ] Implement boxed accessor pairs: shrink `PropValue` from 16 bytes to 8 bytes by boxing getters/setters in a `GetterSetter` GC cell (plan 033 item 1) — estimated 3–5 MB RSS reduction
- [ ] Route all remaining `libc::malloc/realloc/free` calls through the `Heap` allocator (104 sites remain, plan 005)
- [ ] Investigate `bench_recursion` 1.9× vs Duktape gap: profile call frame allocation and valstack growth on deep recursion (`bench_recursion_deep` is 7.5× vs QuickJS)
- [ ] Add inline cache for `GETPROP` on prototype-chain hits (currently IC only covers own-property fast path)
- [ ] Benchmark and reduce `hstring_alloc` cost: interning every string unconditionally is expensive for long concatenation results

---

## Infrastructure & Testing

- [ ] Add a test for `JSON.parse` array then `.push()` regression (plan 026 #1)
- [ ] Add a Rosetta test for function/var hoisting once compiler fix lands
- [ ] Add a Rosetta test for `try { return } finally { }` once RET fix lands
- [ ] Add phase 3 failure analysis script that groups failures by root cause keyword (writable/configurable/seal/freeze/enumerable)
- [ ] Add `bench_date.js` benchmark covering `new Date()` construction and formatting methods
- [ ] Add `bench_regexp.js` benchmark covering `exec` / `match` / `replace` hot paths
- [ ] Write a test for `typeof undeclaredVar` returning `"undefined"` without error
- [ ] Automate test262 phase delta reporting: show pass/fail delta vs last run automatically on each build

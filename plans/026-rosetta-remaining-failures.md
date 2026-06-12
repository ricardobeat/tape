# 026 — Remaining Rosetta Code Failures

**Status**: 6 of 43 rosetta tests still failing (37 pass)
**Branch**: main (as of `702a96b`)

---

## 1. `push()` on JSON-parsed arrays crashes (object_merge.js)

**Minimal repro**:
```js
var a = JSON.parse("[1,2,3]");
a.push(4);  // VM_ERROR
```

**Normal arrays work fine**: `[1,2,3].push(4)` → `4`

**Root cause**: Arrays created by `JSON.parse` don't have the correct prototype or internal state for `Array.prototype.push`. Likely the parsed array's prototype isn't set to `Array.prototype`, or the dense array part isn't initialized correctly.

**Investigation start**: Look at how `JSON.parse` creates arrays in `src/builtins/json.c3`. Check if the result array gets `heap.array_proto` set as its prototype, and whether the dense array part is properly allocated.

**Impact**: Blocks `object_merge.js` (deep copy test). Any code that parses JSON arrays and then mutates them will crash.

---

## 2. Function declaration hoisting (hoisting.js)

**Minimal repro**:
```js
print(typeof f);  // "undefined" — should be "function"
function f() { return 1; }
```

vs:
```js
function f() { return 1; };
print(typeof f);  // "function" — works when declared first
```

**Root cause**: The compiler doesn't pre-scan function declarations. Function declarations are compiled in source order, so referencing them before the declaration point sees `undefined` (or a VM_ERROR if the variable isn't declared at all).

**What needs to change**: The function compilation path (`src/compiler/functions.c3`) needs a pre-scan phase that registers all function declarations in the current scope before compiling the body. This is similar to `var` hoisting — both `var` and `function` declarations should be processed before any statements in the function body.

**Impact**: Blocks 4 assertions in `hoisting.js`. Also affects `var` hoisting (accessing `var x` before `var x = 10` in a function crashes with VM_ERROR).

---

## 3. `var` hoisting in functions (hoisting.js)

**Minimal repro**:
```js
function g() { print(x); var x = 1; }
g();  // VM_ERROR — should print "undefined"
```

**Root cause**: `var` declarations are not hoisted to the top of the function. The compiler processes them in source order, so `x` isn't in the scope stack when `print(x)` is compiled, causing a GETVAR that fails at runtime.

**What needs to change**: Similar to function hoisting — the compiler needs to pre-scan `var` declarations and register them (with `undefined` initial value) before compiling statements.

**Impact**: Blocks var hoisting tests in `hoisting.js`. Also affects the loop-closure tests (the IIFE pattern works, but direct `var` capture doesn't because the variable isn't hoisted).

---

## 4. `new Date(string)` parsing (date_basics.js)

**Minimal repro**:
```js
var d = new Date("2025-06-15T12:00:00Z");
print(d.getUTCFullYear());  // 2026 — should be 2025
```

**Root cause**: The `Date` constructor doesn't parse ISO 8601 strings. When a string argument is passed, it's ignored and the current time is used instead.

**What needs to change**: The Date constructor in `src/builtins/date.c3` (or wherever Date is implemented) needs a string parser for at least ISO 8601 format (`YYYY-MM-DDTHH:mm:ss.sssZ`). The original Duktape has a fairly complete date parser.

**Impact**: Blocks 2 assertions in `date_basics.js`.

---

## 5. Stack depth limit (mutual_recursion.js)

**Minimal repro**:
```js
function s(n) { if (n <= 0) return 0; return n + s(n - 1); }
print(s(100));  // 5050 — works
print(s(150));  // NaN — fails
print(s(200));  // NaN — fails
```

**Root cause**: The VM has a limited call stack. At around 100-150 recursion depth, the valstack or activation array overflows, and the error manifests as NaN instead of a proper error.

**What needs to change**: Either increase the stack limits, or implement proper stack overflow detection that throws a RangeError instead of silently producing NaN. The activation stack limit (`MAX_CALLS`) and valstack growth need to be checked.

**Impact**: Blocks 1 assertion in `mutual_recursion.js`. Also affects any code with deep recursion (e.g., tree traversal).

---

## 6. `Object.keys` duplicate indices on arrays (object_keys.js)

**Minimal repro**:
```js
print(JSON.stringify(Object.keys([10,20,30])));
// Actual: ["0","0","1","2"] — "0" is duplicated
// Expected: ["0","1","2"]
```

With 1-element array:
```js
print(Object.keys([10]).length);   // 2 — should be 1
print(Object.keys([10,20]).length); // 3 — should be 2
print(Object.keys([10,20,30]).length); // 4 — should be 3
```

**Root cause**: The `Object.keys` implementation in `src/builtins/object.c3` iterates both the named properties AND the dense array part. Array index properties appear in both, causing duplicates. A previous fix on the `fix/rosetta-tests` branch added filtering for this, but it wasn't fully merged or has regressed.

**What needs to change**: In `builtin_object_keys`, when the object is an array exotic, skip numeric-index keys from the named properties loop (they'll be emitted by the dense array loop). Also ensure `length` is skipped for arrays.

**Impact**: Blocks 1 assertion in `object_keys.js`. Also affects `for-in` enumeration of arrays.

---

## Test files affected

| Test | Failures | Root cause |
|------|----------|------------|
| object_merge.js | VM_ERROR | #1 (JSON.parse array push) |
| hoisting.js | 4 assertions | #2 (function hoisting) + #3 (var hoisting) |
| date_basics.js | 2 assertions | #4 (Date string parsing) |
| mutual_recursion.js | 1 assertion | #5 (stack depth) |
| object_keys.js | 1 assertion | #6 (Object.keys duplicates) |
| try_catch.js | 1 assertion | finally on return (see below) |

## Bonus: try-finally on return (try_catch.js)

**Minimal repro**:
```js
var log = [];
function f() { try { return 42; } finally { log.push("fin"); } }
var v = f();
print("v=" + v, "log=" + log.join(","));  // v=42 log=  (finally didn't run)
```

**Root cause**: The `RET` instruction (`src/vm.c3:5659`) doesn't check for active catchers (try/finally blocks). It directly pops the activation and returns without executing the finally block.

**What needs to change**: Before returning, `RET` should check `act.cat` for active catchers. If a catcher with a finally block exists, the return value should be saved, the finally block executed, and then the return completed. This is the same mechanism that exception unwinding uses.

**Impact**: Blocks 1 assertion in `try_catch.js`.

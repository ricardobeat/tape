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

## 6. `for (let/const x in obj)` silently uses var semantics

**Minimal repro**:
```js
for (const x in {a:1}) { x = 2; }  // should throw TypeError
for (let x in {a:1}) { let x = 0; } // inner let should shadow (TDZ check)
```

**Root cause**: `statements.c3:708` was changed from `declare_var(name, is_const ? CONST : LET)` to `alloc_reg()`. The binding is never pushed to the scope stack, so `is_const`/`is_lexical` semantics (write-protection, TDZ, duplicate detection) are never enforced. The PUTVAR on line 724 syncs the value by name using var-style env walk regardless of the `let`/`const` declaration.

**What needs to change**: Either restore `declare_var` (but avoid the PUTVAR-clears-register problem that motivated the change), or call `alloc_reg` then immediately push a scope-stack entry with the correct `is_const`/`is_lexical` flags so that inner-body references can resolve it properly.

**Impact**: `for (const x in ...)` doesn't protect against assignment; `for (let x in ...)` doesn't enforce TDZ or duplicate-binding detection.

---

## 7. `String.prototype.lastIndexOf` — unsigned underflow when search string is longer than target

**Minimal repro**:
```js
print("ab".lastIndexOf("abc")); // should be -1, result is implementation-defined
```

**Root cause**: `src/builtins/string.c3:1821` — `len` and `search_len` are both `uint`. When `search_len > len`, `(len - search_len)` wraps to `UINT_MAX - k`. Casting to `int` is implementation-defined. The loop guard `i >= 0 && i + search_len <= len` usually saves it in practice, but the clamp itself is non-portable and there's no early-return guard.

**What needs to change**: Add `if (search_len > len) { ctx.result.set_fastint(-1); return; }` before the clamp line.

**Impact**: Incorrect or non-portable behavior for `str.lastIndexOf(needle)` when `needle` is longer than `str`.

---

## 8. `call_prop_obj_reg` stale after `new X()[expr]` — wrong `this` in chained method call

**Minimal repro**:
```js
new Foo()[bar.baz].method();  // bar used as 'this' instead of the indexed result
```

**Root cause**: `src/compiler/expressions.c3:1171` — the computed-index branch of the trailing-access loop calls `self.expression()` to evaluate the index. If that sub-expression contains a property access (e.g. `bar.baz`), `member_expr` sets `call_prop_obj_reg` to `bar`'s register. After `expression()` returns, the bracket branch does not reset `call_prop_obj_reg`. If the next loop iteration is a `.method()` call, `emit_call` picks up the stale value and emits `LDREG this ← bar's register`.

**What needs to change**: Save and restore `call_prop_obj_reg` around the `self.expression()` call in the LBRACKET branch (or explicitly clear it after the bracket branch completes).

**Impact**: `new X()[expr].method()` passes wrong `this` to the method when `expr` is a member expression like `a.b`.

---

## Test files affected

| Test | Failures | Root cause |
|------|----------|------------|
| object_merge.js | VM_ERROR | #1 (JSON.parse array push) |
| hoisting.js | 4 assertions | #2 (function hoisting) + #3 (var hoisting) |
| date_basics.js | 2 assertions | #4 (Date string parsing) |
| mutual_recursion.js | 1 assertion | #5 (stack depth) |
| try_catch.js | 1 assertion | finally on return (see below) |
| any for-in with let/const | silent wrong | #6 (for-let/const-in var semantics) |
| str.lastIndexOf(longer) | non-portable | #7 (uint underflow) |
| new X()[a.b].method() | wrong this | #8 (stale call_prop_obj_reg) |

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

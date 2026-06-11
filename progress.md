# Progress: Duktape C3 — test262 Conformance Tracker

**Last Updated:** Session 149 (Fix callback execution in vm_call_fn_impl Case 3; find/findIndex builtins)
**Target:** 80% test262 pass rate on ES5/ES6 core

## Summary (after Session 149, 2026-06-11)

| Metric | Value |
|---|---|
| Total test262 tests | 42,013 |
| ES5-relevant tests | ~26,353 |
| Currently passing (phases 0-8) | ~10,978 |
| Currently failing (phases 0-8) | ~9,586 |
| Pass rate (phases 0-8 only) | ~53.4% |
| Overall pass rate | 52.7% |

## Per-Phase Status

| Phase | Total | Pass | Fail | Skip |
|---|---|---|---|---|
| 0-1: Core VM | 2,185 | 518 | 370 | 1,297 |
| 1: Calling Convention | 426 | 38 | 50 | 338 |
| 2: Basic Operators | 1,969 | 884 | 260 | 825 |
| 3: Object System | 7,766 | 3,189 | 2,610 | 1,967 |
| 4: Error Handling | 402 | 98 | 103 | 201 |
| 5: Built-in Constructors | 8,615 | 3,703 | 3,387 | 1,525 |
| 6: Prototype Methods | 4,713 | 1,712 | 2,065 | 936 |
| 7: ES5 Features | 1,240 | 168 | 125 | 947 |
| 8: ES5 Built-in Objects | 2,747 | 668 | 616 | 1,463 |
| 11: Arrow/Templates | 427 | 56 | 47 | 324 |
| 12-13: Destructuring | 19 | 0 | 0 | 19 |
| 14: for-of | 751 | 5 | 27 | 719 |
| 15: Classes | 8,520 | 63 | 199 | 8,258 |
| 17-20: Map/Set/Symbol/Promise | 1,614 | 275 | 365 | 974 |
| 21: Generators | 619 | 0 | 2 | 617 |

## Benchmark Summary

See `benchmarks/results.txt`. C3 vs Duktape v2.7.0 ratios (lower is better):
- **All benchmarks <= Duktape except**: ic_monomorphic (1.1x), valstack_copy (1.3x)
- **vs QuickJS**: Most benchmarks 0.3-0.8×, ic_monomorphic/valstack_copy 1.8×
- valstack_copy was 3.7× before env-creation-skip optimization (Session 148)
- bench_string was 2.5× before string-table-reference fix (Session 148)
- bench_shape went from 73× to 0.8× via GC-skip for RC strings (Session 147)

## Resolved Root Causes

These were major failure categories, now fixed:

| Category | Impact | Fixed in |
|---|---|---|
| String `===` interning | ~1,000 tests | Session 103 |
| Compiler pushback buffer | ~500 tests | Session 130 |
| Catch variable PUTVAR | ~676 tests | Session 136 |
| Function.prototype init order | ~1,500 tests | Session 144 |
| ToPrimitive chain (valueOf/toString) | ~2,000 tests | Sessions 117, 129–135, 140 |
| Constructor .name/.length | ~500 tests | Session 126 |
| Builtin method .writable flag | ~600 tests | Session 137 |

## Remaining Failure Categories (see plans/014-test262-review.md)

1. **Property descriptor correctness** (~3,000+ tests) — `defineProperty`/`getOwnPropertyDescriptor`
   edge cases: accessor→data conversion, non-configurable constraints, `.enumerable`/`.configurable`
   on constructor `.name`/`.length`, property enumeration order.
2. **Missing built-in prototype methods** (~500–1,500 tests) — `String.prototype.replace`/`match`/`search`/`split`,
   `Array.prototype.sort`/`splice`, `Number.prototype.toFixed`/`toExponential`/`toPrecision`,
   `Date.prototype` formatting, `Error.prototype.toString`.
3. **for-of / iterator protocol** (~700+ tests) — `Symbol.iterator`, `.next()`, `{value, done}`.
4. **Class features** (~500+ tests) — private fields/methods, static blocks, class expression edge cases.
5. **Promise microtask scheduling** (~100+ tests) — async resolution order not implemented.
6. **Nested call_fn error propagation** (~50 tests) — valueOf/toString throws still swallowed in some paths.
   ~~valueOf/toString throws still swallowed in some paths.~~ Fixed: vm_call_fn_impl Case 3 callback
   error propagation now works (arr_call_callback checks heap.has_error → ctx.should_throw).

## Deferred Items

- Async microtask scheduling (Promise tests)
- Private class fields/methods
- Nested/advanced destructuring patterns
- Reflect, Proxy
- Error propagation from nested call_fn — **partially fixed** (array callbacks now propagate; remaining: sort comparator, JSON replacer, etc.)
- Number wrapper valueOf() returns NaN for non-fastint

## Test Infrastructure

- **Runner**: `python3 scripts/run_test262.py` (multi-worker, parallel)
- **Quick test**: `bash test262_runner/quick.sh`
- **Phase counts**: `bash scripts/count_test262_by_phase.sh`
- **Build**: `c3c build batch_test_vm` or `c3c build test_vm`

## Session Log (condensed, newest first)

| Session | Summary | test262 impact |
|---|---|---|
| 149 | Fix vm_call_fn_impl Case 3 callback execution; find/findIndex native builtins; print toString; callback error propagation | TBD |
| 148 | Env-creation skip (has_closures), IC inline fast path, string-table ref fix | no regression (52.7%) |
| 147 | Shape benchmark fix (GC skip for RC strings, PUTPROP restructure, alloc_no_gc) | — |
| 146 | String RC rebased on delta shapes (plans 016/017/018) | — |
| 145 | Array.sort comparator + String.replace/split RegExp | +58 |
| 144 | Function.prototype.call init order + Array ToObject | +1,520 |
| 143 | String.prototype locale methods + localeCompare | +54 |
| 140 | Symbol.toPrimitive getter + arguments object + harness | +29 |
| 139 | ToString NaN/Infinity + defineProperty accessor + JSON unwrap + dot-decimal + strict entry | — |
| 138 | Lexer strtod for decimal number parsing | +10 |
| 137 | Builtin method writable flags + defineProperty accessor→data | +282 |
| 136 | Catch variable PUTVAR in all scopes | +676 |
| 135 | Date ToPrimitive hint (toString before valueOf) | — |
| 134 | needs_restart guards in all binary operators | +25 |
| 133 | MOD fastint -0 sign + quick.sh assert.js harness | +38 |
| 132 | ToPrimitive error propagation (valueOf/toString throws) | +10 |
| 131 | UNM -0 preservation + ToPrimitive TypeError in operators | +5 |
| 130 | Compiler pushback fix (expect/match respect pushback) | +492 |
| 129 | vm_to_number passes Vm* + Symbol.toPrimitive | — |
| 128 | ToInt32 fix for all 8 bitwise operators | — |
| 127 | Array iteration dispatch table fix | +670 |
| 126 | Constructor .name and .length properties | — |
| 125 | Error propagation + non-enumerable globals | — |
| 124 | RET restart avoidance (inline caller restore) | — |
| 123 | INC_VAR/DEC_VAR fused opcodes | — |
| 122 | @inline on incref/decref/tval_copy_ref | — |
| 121 | max_heap_reg tracking (skip decref loop) | — |
| 120 | FASTINT fast paths in ADD/SEQ/SNEQ | — |
| 119 | IC fast path optimization | — |
| 118 | array_length fast field | — |
| 117 | ToPrimitive — call toString/valueOf on objects | — |
| 116 | Array length tracking in PUTPROP | — |
| 115 | Property descriptor edge cases | — |
| 114 | Speed optimization (func-ptr dispatch, needs_env, memset) | — |
| 113 | Spread operator uses iterator protocol | — |
| 112 | Map/Set iterator protocol | — |
| 111 | %IteratorPrototype% shared prototype | — |
| 110 | Array.from | +12 |
| 109 | Number wrapper valueOf fastint fix | +16 |
| 108 | `in` operator wrapper unwrap | +28 |
| 107 | RegExp.prototype accessor properties | — |
| 106 | JSON.stringify replacer/toJSON/edge cases | — |
| 105 | RegExp prototype chain wiring | +6 |
| 104 | String wrapper property enumeration | +71 |
| 103 | String `===` interning bug fix | — |
| 98 | Arithmetic ToNumber coercion | +177 |
| 97 | GETVAR/TYPEOFIDENT inline cache (VarIC) | — |
| 96b | Array fast paths + grow_props relocation fix | — |
| 95 | VM dispatch optimizations | — |
| 93 | Fix `typeof X.y` compiler bug | +100 |
| 92 | Optimized arguments object | — |
| 91 | Array.prototype.flat/flatMap | — |
| 90 | AggregateError + Promise.any | — |
| 89 | Promise.allSettled | — |
| 88 | Fix Promise.prototype.catch onRejected | +75 |
| 87 | Date.prototype.toLocaleString methods | +36 |
| 67 | Fix bracket assignment lhs_mode clobbering | +813 |

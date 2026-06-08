# Plan 014: test262 Coverage Review

**Date:** 2026-06-08
**Status:** Current as of Session 145

## Summary

- **Total test262 tests:** 53,569
- **ES5-relevant tests:** ~26,353
- **Currently passing (phases 0-8):** ~12,450
- **Currently failing (phases 0-8):** ~10,287
- **Pass rate (phases 0-8):** ~52%
- **Target:** 80% pass rate on ES5/ES6 core

## Per-Phase Status (fresh run, 2026-06-08, after Session 145)

| Phase | Total | Pass | Fail | Skip | Notes |
|---|---|---|---|---|---|
| 0-1: Core VM | 2,185 | 567 | 321 | 1,297 | no change |
| 1: Calling Convention | 426 | 47 | 41 | 338 | no change |
| 2: Basic Operators | 1,969 | 952 | 192 | 825 | no change |
| 3: Object System | 7,767 | 3,605 | 2,195 | 1,967 | +6 (sort comparator) |
| 4: Error Handling | 402 | 119 | 82 | 201 | no change |
| 5: Built-in Constructors | 8,616 | 4,244 | 2,847 | 1,525 | +21 (replace/split RegExp) |
| 6: Prototype Methods | 4,713 | 1,953 | 1,824 | 936 | +31 (sort/replace/split) |
| 7: ES5 Features | 1,240 | 183 | 110 | 947 | no change |
| 8: ES5 Built-in Objects | 2,747 | 780 | 504 | 1,463 | no change |
| 11: Arrow/Templates | 427 | 59 | 44 | 324 | Working, edge cases |
| 12-13: Destructuring | 19 | 0 | 0 | 19 | All skipped |
| 14: for-of | 751 | 5 | 27 | 719 | String enum helps |
| 15: Classes | 8,520 | 59 | 203 | 8,258 | Mostly skipped |
| 17-20: Map/Set/Symbol/Promise | 1,588 | 177 | 463 | 948 | Prop-desc gaps |
| 21: Generators | 619 | 0 | 2 | 617 | All skipped (no impl) |

## Biggest Failure Categories (ES5/ES6 core, not skipped)

| Phase | Failing | Root causes |
|---|---|---|
| **5: Built-in Constructors** | 2,868 | Largest gap — property descriptor edge cases, missing methods |
| **3: Object System** | 2,201 | Prototype chain, defineProperty, property enumeration |
| **6: Prototype Methods** | 1,855 | Missing prototype methods, wrong flags, receiver coercion |
| **8: ES5 Built-in Objects** | 504 | Date/RegExp/Object method gaps |
| **17-20: Map/Set/Symbol/Promise** | 463 | Property descriptor gaps, missing methods |
| **0-1: Core VM** | 321 | Edge cases in identifiers, block scope, arguments |
| **2: Basic Operators** | 192 | Exponentiation, compound-assignment edge cases |
| **7: ES5 Features** | 110 | for-in, eval, delete edge cases |
| **4: Error Handling** | 82 | Error propagation, try/catch/finally edge cases |

## Entirely Skipped (deferred features)

- **Classes** — 8,258 skipped (no private fields/methods/static blocks)
- **Generators** — 617 skipped (no iterator protocol impl)
- **Destructuring** — all 19 skipped
- **for-of** — 719 skipped (no iterator protocol)
- **Proxy** — 311 (extreme complexity)
- **WeakRef/FinalizationRegistry** — 76 (GC-dependent)
- **BigInt** — 77
- **SharedArrayBuffer/Atomics** — 494
- All **Stage 3 proposals** (Temporal, decorators, etc.)
- **Optional chaining, object rest, logical assignment**

## Deferred Items (from progress.md)

- Async microtask scheduling (Promise tests)
- Private class fields/methods
- Nested/advanced destructuring patterns
- Reflect, Proxy
- Error propagation from nested call_fn (valueOf/toString throws inside to_primitive_value)

## Recommended Next Steps (by impact)

### 1. Property descriptor correctness (Phases 3, 5, 6, 8)

**Estimated impact:** 2,000–4,000 new passes

The biggest single category of failures across Phases 3, 5, and 6. Many tests
fail because `getOwnPropertyDescriptor`, `defineProperty`, or property flag
checks don't match ES5 §8.12.9 / §15.3.5.1 exactly. Fixing cascading property
descriptor bugs would unblock large swaths of tests.

Specific areas:
- `defineProperty` edge cases (accessor→data conversion, non-configurable constraints)
- Method `.writable` flag (should be `true` for built-in methods per ES5 §15.3.5.1)
- `.enumerable` / `.configurable` on constructor `.name` / `.length`
- Property enumeration order correctness

### 2. Missing built-in prototype methods (Phases 5, 6)

**Estimated impact:** 500–1,500 new passes

Several prototype methods are still missing or incomplete:
- `String.prototype.replace` / `replaceAll` / `match` / `matchAll` / `search` / `split`
- `Array.prototype.sort` (needs proper comparator handling)
- `Array.prototype.splice` edge cases
- `Number.prototype.toFixed` / `toExponential` / `toPrecision`
- `Date.prototype` formatting methods (toDateString, toTimeString, etc.)
- `Error.prototype.toString`

### 3. for-of / iterator protocol (Phase 14)

**Estimated impact:** 700+ passes (currently 5/751)

Implementing the iterator protocol (`Symbol.iterator`, `.next()`, `{value, done}`)
would unlock for-of for arrays, strings, Map, Set, and generators.

### 4. Class features (Phase 15)

**Estimated impact:** 59 → 500+ passes

Currently 8,258 tests skipped. Core class syntax works but private fields/methods,
static blocks, and class expression edge cases are all skipped.

### 5. Promise microtask scheduling (Phase 17-20)

**Estimated impact:** ~100+ passes

Promise constructor and `.then`/`.catch` exist but async microtask scheduling
is not implemented, so any test relying on async resolution order fails.

### 6. Error propagation in nested call_fn

**Estimated impact:** ~50+ passes

valueOf/toString throws inside `to_primitive_value` are still swallowed in
some nested call paths (noted in Session 131 as deferred).

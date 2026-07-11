# Plan 051: Small Parallel Fix Batch — Targeting ~350 Tests

**Status:** Active (session 277)
**Baseline:** 28,590 pass / 2,023 fail / 167 CE = 92.9%

## Tasks (small, focused, parallel)

### T1: Class methods non-enumerable (~11 tests)
Class methods use PUTPROP/INITPROP with `{e:true}`. Per ES2015 §14.5.14 step 9, class methods must be `{writable:true, enumerable:false, configurable:true}`. Change flags in `class.c3` for both static and instance methods, and accessors.

### T2: Class constructor callable without `new` (~25 tests)
Calling a class constructor without `new` must throw TypeError. Add `is_class_ctor` check in VM call dispatch.

### T3: Symbol protocol guard on String.prototype methods (~25 tests)
Guard `@@match`/`@@replace`/`@@search`/`@@split`/`@@matchAll` dispatch with `is_object()` check. Skip Symbol dispatch for primitive searchValue/separator.

### T4: String.prototype valueOf/toString non-generic + metadata fixes (~11 tests)
`thisStringValue`: throw TypeError for non-String `this`. Fix `padStart`/`padEnd` arity (2→1). Add `localeCompare` metadata case 300.

### T5: String.prototype argument coercion — at/indexOf/repeat/lastIndexOf (~13 tests)
Use `builtin_to_number_vm` for `at` index, `indexOf`/`lastIndexOf` position, `repeat` count. Fix `repeat` NaN→0.

### T6: startsWith/endsWith/includes IsRegExp check (~6 tests)
Add IsRegExp + TypeError before ToString(searchString) in all three methods.

### T7: Object literal super binding (~23 CEs)
Set `has_super_binding = true` before compiling object literal method bodies, restore after.

### T8: Reserved words as property names (~24 CEs)
In object literal property names, member access `.`, class method names, getter/setter names — accept any keyword token.

### T9: Duplicate data properties in object literals (~2 CEs)
Remove duplicate data property rejection in `object_literal()`.

### T10: Object.entries/values enumeration order (~8 tests)
Integer-index properties must sort before string properties in entries/values.

### T11: Array.prototype[Symbol.iterator] === values (~1 test)
Set Symbol.iterator to same function as values during prototype init.

### T12: Function.prototype.call/apply thisArg boxing (~8 tests)
ToObject(thisArg) when thisArg is a primitive.

### T13: Trailing comma + spread arguments (~14 tests)
Fix argument counting when trailing comma follows spread element.

## Verification
After all agents: `c3c build test_vm && just rosetta`, test specific tests, commit, update progress.md.

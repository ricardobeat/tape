# Plan 023: Missing Built-in Prototype Methods

## Goal
Implement and fix the remaining missing built-in prototype methods that cause test262 failures. Focus on ES5/ES6 methods with the highest test density.

## Current State
- **Date.prototype.toDateString** — MISSING (ES5 §15.9.5.3, ~20-40 tests)
- **Date.prototype.toTimeString** — MISSING (ES5 §15.9.5.4, ~20-40 tests)
- **String.prototype.replaceAll** — MISSING (ES2021 §21.1.3.18, ~50 tests)
- **String.prototype.matchAll** — MISSING (ES2020 §21.1.3.11, ~40 tests)
- **String.prototype.normalize** — MISSING (ES6 §21.1.3.12, ~30 tests)
- **Array.prototype.find/findIndex** — exist via compiled JS but lack `thisArg`, `ToLength`, TypeError on non-callable callback (~15 tests)

## Implementation Steps

### Step 1: Date.prototype.toDateString / toTimeString
- Add BUILTIN constants: `BUILTIN_DATE_PROTO_TODATESTRING`, `BUILTIN_DATE_PROTO_TOTIMESTRING`
- Add native C3 implementations that format the date/time portions
- Reuse existing `date_format_to_string` approach (localtime_r-based)
- Register in `register_date_constructor`
- Add dispatch entries in `core.c3`

### Step 2: String.prototype.replaceAll
- Add BUILTIN constants and registration
- Implement as native C3 function following ES2021 spec:
  - If searchValue is a regex with the `g` flag, delegate to `Symbol.replace`
  - If searchValue is a regex without `g`, throw TypeError
  - If searchValue is a non-regex or string, convert to string and replace all occurrences
  - Handle function replaceValue by calling it for each match
  - Handle $-substitution patterns in string replaceValue

### Step 3: String.prototype.matchAll
- Add BUILTIN constants and registration
- Implement as native C3 function following ES2020 spec:
  - If searchValue is a regex without `g`, throw TypeError
  - If searchValue is a non-regex or string, coerce via `Symbol.match`
  - Return a RegExpStringIterator

### Step 4: String.prototype.normalize (if time permits)
- Unicode normalization forms NFD, NFC, NFKD, NFKC
- Complex; consider `register_compiled_proto_method` fallback or stub that passes basic tests

### Step 5: Array.prototype.find/findIndex quality fix
- Replace compiled JS implementations with native C3 LIGHTFUNC builtins
- Add proper `thisArg`, `ToLength`, `HasProperty` checks, TypeError on non-callable
- Wire BUILTIN_ARRAY_PROTO_FIND/FINDINDEX into the dispatch table

## Estimated Impact
- Step 1 (toDateString/toTimeString): ~40-80 new passes (Phase 6)
- Step 2 (replaceAll): ~40-60 new passes (Phase 6)
- Step 3 (matchAll): ~30-50 new passes (Phase 6)
- Step 4 (normalize): ~25-35 new passes (Phase 6)
- Step 5 (find/findIndex): ~10-20 new passes (Phase 6)

**Total estimate: ~150-250 new passes**

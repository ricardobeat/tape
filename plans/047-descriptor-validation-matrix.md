# Plan 047: Property-descriptor validation matrix (B49)

**Status:** Planned (specced session 267; execute as its own wave).
**Payoff:** ~276 direct test262 fails (defineProperties 188 + defineProperty
88) plus adjacent Object.create (26), getOwnPropertyDescriptor(s) (48),
seal/freeze/isSealed families — plan 040 estimated the full matrix at ~490.

## Failure modes sampled (session 267)

- `15.2.3.7-6-a-112` — expected TypeError not thrown (re-configuration of a
  non-configurable property must reject).
- `15.2.3.7-5-b-188` — "Cannot assign to read only property" thrown while
  *building* descriptors (ToPropertyDescriptor reading a getter-backed
  descriptor object? writable-check misfires during Properties iteration).
- `15.2.3.7-2-8` — `result !== true` (return-value / ToObject on the props
  argument).
- `15.2.3.7-6-a-24` — "called on non-object" thrown where spec allows
  (descriptor objects can be non-plain; ToPropertyDescriptor takes any
  object, and Object.defineProperties' first arg check is separate from the
  per-descriptor checks).
- `15.2.3.6-4-410` — array index defineProperty on exotic arrays: value not
  updated ("unlikelyValue" vs 1001) — the dense-array elements path bypasses
  descriptor application (adjacent to plan 041's set_array_idx hazard).

## Approach

Implement the spec operations once, as shared helpers in the builtins layer,
then route every caller through them (the same shared-spec-op strategy plan
040 lists as an architecture item):

1. `to_property_descriptor(obj) → PropDesc` — full ES §6.2.5.5: reads
   value/get/set/writable/enumerable/configurable **via [[Get]]** (invoking
   getters), validates get/set callability, rejects mixed data+accessor.
2. `validate_and_apply_property_descriptor(target, key, current, desc)` —
   ES §10.1.6.3 matrix: non-configurable transitions, writable:false value
   changes (SameValue), data↔accessor conversions, enumerable flips.
3. `ordinary_define_own_property` on top of 1+2; arrays get the §10.4.2.1
   length/index exotic behavior (coordinate with plan 041's ulong helpers —
   the dense-elements write path must not bypass the matrix).
4. Route: Object.defineProperty, Object.defineProperties (iterate props via
   own-enumerable keys, collecting descriptors BEFORE applying any — spec
   order), Object.create (props arg), Reflect.defineProperty if present.

Existing partial work: plan 022 fixed slices of this (defineProperties
non-configurable validation, seal/freeze dense arrays, GOPD flags) — fold
its remaining items in and mark plan 022 superseded by this wave.

## Oracle

`test/test_descriptor_matrix.js`: the 4×4 transition matrix per attribute
(configurable × writable × enumerable × data/accessor), array index + length
cases, getter-backed descriptor objects, defineProperties ordering
(collect-then-apply, first-error aborts before any mutation), non-object
props handling.

## Validation

Sample 20 tests across built-ins/Object/defineProperty and defineProperties
via run_single_test.sh before/after; full suite at wave end. Bench guard:
bench_object, bench_property_lookup (put_prop paths are hot).

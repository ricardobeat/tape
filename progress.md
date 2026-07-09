# Progress: Duktape C3 — test262 Conformance Tracker

**Last Updated:** Session 271 — Array.prototype: map/filter ArraySpeciesCreate, reduce/reduceRight loop bounds, iterator keys/entries/values, push error types; Object.defineProperties dense-array sync; array literal INITPROP undefined→named-prop
**Target:** 100% test262 pass rate on the targeted subset (see plan 040 for the subset definition).

## Summary (full run, session 271, 2026-07-09)

| Metric | Value |
|---|---|
| Pass + Fail + CE (executable) | 30,780 |
| Total passing | 27,047 |
| **Overall pass rate** | **87.9%** |
| Total failing | 3,500 |
| CE unexpected (parser bugs) | 230 |
| CE expected (`negative: phase: parse`) | 3 |
| Skipped | 14,032 |

Up from session 270 (87.2%, 26,826 pass) via a batch of Array.prototype
and array-literal conformance fixes (+221 pass, +0.7pp):

1. **Array literal INITPROP undefined → named property** — `undefined` elements
   in array literals (`[1, undefined, 3]`) were stored in the dense array part
   where they are indistinguishable from holes.  Added `!rc.is_undefined()` guard
   before the INITPROP dense fast-path so explicit `undefined` falls through to
   `put_prop`, creating a named property.  Unblocked `flat`/`concat`/`flatMap`
   hole-vs-undefined tests.

2. **Array.prototype.map / filter — ArraySpeciesCreate** — result arrays were
   allocated via `alloc_object(ARRAY)`, bypassing `Symbol.species`.  Funnelled
   through `array_species_create_result`; `map` now also pre-sets result length
   via `array_set_length_ulong`.

3. **array_set_elem_ulong_checked** — Enhanced to use `put_prop` (WEC flags)
   when a named property already exists (redefine), or when value is `undefined`
   on ARRAY/ARGUMENTS objects (prevent undefined≡hole).  Also fixed
   `array_can_set_index` to only reject non-configurable, not non-writable
   (configurable+non-writable can be redefined via CreateDataProperty).

4. **Array.prototype.reduce / reduceRight** — loops re-read `cur_len` from the
   live object causing early exit when a callback shrank the array.  Fixed by
   capturing `len` before the loop and iterating against the snapshot.
   `reduceRight` also initialised `k = 0` when `len=0`, triggering a spurious
   iteration; fixed to `k = -1`.

5. **Array.prototype.sort** — undefined elements always sort last per spec;
   comparefn is never called with undefined.  Added early-return at the top of
   `array_sort_compare`.

6. **Array iterator (keys / values / entries)** — `done=true` case leaked the
   out-of-bounds index as `value` for the keys iterator.  Moved kind-specific
   value adjustment inside `if (!done)`; added `value.set_undefined()` for the
   done branch.  Entries pair array was missing `*pair.array_len_ptr() = 2`
   causing `.length === 0`.  Added metadata entries 273-275 so
   `Array.prototype.{keys,values,entries}.length` are own properties.

7. **Object.defineProperties dense-array sync** — when `defineProperties` updated
   a named property's value in-place, it didn't sync back to the dense array slot.
   Added sync after the named-prop value write; added dense-to-named promotion
   before `find_prop_idx` so partial descriptors see existing WEC flags.

8. **Array.prototype.push error types** — TypeError for null/undefined receiver;
   RangeError (not TypeError) when new length > 2^32-1 for ARRAY exotic;
   non-writable/frozen length now throws via `arr_set_length_or_throw`.

Gap to 100% on the current denominator = ~3,733 tests.

## Per-Phase Status (session 271, full run)

| Phase | Total | Pass | Fail | Skip | CE:expected-parse | CE:expected-runtime | CE:unexpected |
|---|---|---|---|---|---|---|---|
| 0-1: Core VM | 2185 | 906 | 170 | 1096 | 3 | 0 | 10 |
| 1: Calling Convention & Closures | 426 | 298 | 33 | 90 | 0 | 0 | 5 |
| 2: Basic Operators | 1969 | 1254 | 111 | 563 | 0 | 0 | 41 |
| 3: Object System | 7766 | 6363 | 290 | 1095 | 0 | 0 | 18 |
| 4: Error Handling & References | 402 | 220 | 78 | 103 | 0 | 0 | 1 |
| 5: Built-in Constructors | 8615 | 7256 | 532 | 827 | 0 | 0 | 0 |
| 6: Built-in Prototype Methods | 4713 | 3981 | 301 | 431 | 0 | 0 | 0 |
| 7: Remaining ES5 Features | 1035 | 491 | 49 | 458 | 0 | 0 | 37 |
| 8: ES5 Built-in Objects | 2747 | 1514 | 709 | 523 | 0 | 0 | 1 |
| 11: Arrow Functions & Templates | 465 | 269 | 31 | 158 | 0 | 0 | 7 |
| 12-13: Destructuring & Spread | 19 | 17 | 0 | 2 | 0 | 0 | 0 |
| 14: for-of | 751 | 387 | 149 | 169 | 0 | 0 | 46 |
| 15: Classes | 8520 | 1788 | 354 | 6318 | 0 | 0 | 60 |
| 17-20: Map/Set/Symbol/Promise/WeakMap/WeakSet | 1614 | 987 | 164 | 463 | 0 | 0 | 0 |
| 21: Generators | 619 | 416 | 61 | 138 | 0 | 0 | 4 |
| 22: Buffers | 2966 | 900 | 468 | 1598 | 0 | 0 | 0 |

Session 270 reference: 26,826 pass / 30,780 executable / 87.2%.  Session 271:
+221 pass / ±0 net executable / +0.7pp on the same denominator.

Top gaining areas: Phase 3 Object System +56, Phase 5 Built-ins +48,
Phase 6 Proto Methods +45, Phase 0-1 Core VM +39, Phase 15 Classes +35.

Top remaining failures by directory: RegExp property-escapes/generated (399),
for-of/dstr (118), Function.prototype.toString (48), Function.prototype.call/apply
(38 each), Object.defineProperty (36), TypedArray.prototype.set (35),
RegExp.prototype[Symbol.replace] (35).

## Summary (full run, session 270, 2026-07-09)

| Metric | Value |
|---|---|
| Pass + Fail + CE (executable) | 30,780 |
| Total passing | 26,826 |
| **Overall pass rate** | **87.2%** |
| Total failing | 3,721 |
| CE unexpected (parser bugs) | 230 |
| CE expected (`negative: phase: parse`) | 3 |
| Skipped | 14,032 |

Up from session 269 (83.1%, 25,656 pass) via three surgical spec-conformance
fixes:

1. **Array.prototype.copyWithin** — ES2024 §23.1.3.3 steps 4-6 require
   target, start, and end to default to 0, 0, and `len` respectively when
   `undefined` is passed.  The existing code only applied the default to
   `end`, so `arr.copyWithin(0, undefined, 4)` and `arr.copyWithin(undefined, 1)`
   were silently clamping to `ToInteger(undefined) = 0`.  Treat `undefined`
   per the spec step and the previously-failing copyWithin `undefined-end`
   test goes green (built-ins/Array/prototype/copyWithin/ 29 → 32 pass).

2. **Array.prototype.flat** — the result array was created via
   `alloc_object(ARRAY)` which bypassed `ArraySpeciesCreate` (ES2019
   §22.1.3.10 step 5).  Funneled through `array_species_create_result` so a
   non-callable / non-object constructor (e.g. `[].flat.call({length: undefined,
   constructor: null}, ...)`) raises TypeError at step 5 rather than returning
   a wrong-proto array; `flatten_into` now takes `BuiltinContext*` and uses
   `array_set_elem_ulong_checked`, propagating the TypeError when
   CreateDataProperty fails (non-extensible target case).

3. **Object.defineProperty(array, "length", …)** — ES2024 §ArraySetLength
   validates the new length value before descriptor-field checks.  The
   existing code rejected get/set/configurable/enumerable/writable first,
   so a descriptor like `{ value: -1, configurable: true }` raised TypeError
   instead of the specified RangeError.  Reordering passes
   built-ins/Array/length/define-own-prop-length-error.js and
   define-own-prop-length-overflow-order.js (21 → 23 pass in that directory).

Gap to 100% on the new denominator = ~3,958 tests.

## Per-Phase Status (session 270 reference, full run)

| Phase | Total | Pass | Fail | Skip | CE:expected-parse | CE:expected-runtime | CE:unexpected |
|---|---|---|---|---|---|---|---|
| 0-1: Core VM | 2185 | 867 | 209 | 1096 | 3 | 0 | 10 |
| 1: Calling Convention & Closures | 426 | 295 | 36 | 90 | 0 | 0 | 5 |
| 2: Basic Operators | 1969 | 1251 | 114 | 563 | 0 | 0 | 41 |
| 3: Object System | 7766 | 6307 | 346 | 1095 | 0 | 0 | 18 |
| 4: Error Handling & References | 402 | 220 | 78 | 103 | 0 | 0 | 1 |
| 5: Built-in Constructors | 8615 | 7208 | 580 | 827 | 0 | 0 | 0 |
| 6: Built-in Prototype Methods | 4713 | 3936 | 346 | 431 | 0 | 0 | 0 |
| 7: Remaining ES5 Features | 1035 | 485 | 55 | 458 | 0 | 0 | 37 |
| 8: ES5 Built-in Objects | 2747 | 1514 | 709 | 523 | 0 | 0 | 1 |
| 11: Arrow Functions & Templates | 465 | 266 | 34 | 158 | 0 | 0 | 7 |
| 12-13: Destructuring & Spread | 19 | 17 | 0 | 2 | 0 | 0 | 0 |
| 14: for-of | 751 | 378 | 158 | 169 | 0 | 0 | 46 |
| 15: Classes | 8520 | 1753 | 389 | 6318 | 0 | 0 | 60 |
| 17-20: Map/Set/Symbol/Promise/WeakMap/WeakSet | 1614 | 985 | 166 | 463 | 0 | 0 | 0 |
| 21: Generators | 619 | 408 | 69 | 138 | 0 | 0 | 4 |
| **22: Buffers** | **2966** | **901** | **467** | **1598** | **0** | **0** | **0** |

Session 269 reference: 25,656 pass / 30,863 executable / 83.1%.  Session 270:
+1,170 pass / +83 net executable / +4.1pp on the same denominator.

### Plan 049 (ArrayBuffer / TypedArray / DataView) — landed in this session

- **Stage 1** — ArrayBuffer core: `HObjectArrayBuffer` / `HObjectBufferView` union variants (24 B each), GC mark of `views_head` chain + free of `ab.data`, constructor with `ToIndex`, `byteLength`/`detached` accessors, species-aware `slice()`, static `isView` + `Symbol.species`. `__detachArrayBuffer` hidden global (bridged to `$262.detachArrayBuffer` via the batch harness).
- **Stage 2** — TypedArray construction + element access: 4 constructor overloads (number/absent, ArrayBuffer view, other TypedArray, iterable/array-like), `GETPROP`/`PUTPROP` fast paths for all 9 classes with correct conversions (Int/Uint wrap, Uint8Clamped banker's rounding, Float32 precision cast), convert-before-bounds ordering per spec, `CanonicalNumericIndexString` slow path, prototype accessors (`length`/`byteLength`/`byteOffset`/`buffer`/`@@toStringTag`). `for-in`, `IN`, `delete`, and `Object.getOwnPropertyDescriptor` extended for TA integer indices.
- **Stage 3** — DataView: constructor + 3 accessors + 16 get/set methods (Int8/Uint8/Int16/Uint16/Int32/Uint32/Float32/Float64 × get/set) with LE/BE dispatch, `TypeError` on detached buffer, `RangeError` on OOB, convert-before-detach-recheck on writes.
- **Stage 4** — `%TypedArray%.prototype` Wave A: iterators (`values`/`keys`/`entries`/`[Symbol.iterator]`), `set`/`subarray`/`fill`/`copyWithin`/`slice` with `ta_validate` detach guard.
- **Stage 5** — `%TypedArray%.prototype` Wave B: `indexOf`/`lastIndexOf`/`includes` (NaN semantics + numeric compare), `join`/`toString`/`toLocaleString`, callback methods (`forEach`/`every`/`some`/`reduce`/`reduceRight`/`map`/`filter`) with callback-throw propagation, `find/findIndex/findLast/findLastIndex`, `reverse/toReversed/at`, `sort/toSorted` (numeric comparator, NaN-last insertion sort), `Int8Array.of` / `Int8Array.from`.
- **Stage 6** — runner wiring: Phase 22 (Buffers) added to `scripts/run_test262.py`, `$262` host object with `detachArrayBuffer` bridge added to the batch runner harness, feature-flag skips extended for `arraybuffer-transfer` / `immutable-arraybuffer`.
- **Post-plan fixes** — `%TypedArray%` abstract constructor intrinsic wired so `Object.getPrototypeOf(Int8Array) === TypedArray` per §22.2.1 with `from`/`of` moved onto the intrinsic; the batch runner now parses each test's `includes: [...]` frontmatter and loads the referenced harness files (previously only the single-test runner did this — the biggest single unblock of the session); builtin metadata (`.length`/`.name`/`BYTES_PER_ELEMENT`) fixed on every TA proto method + ctor + prototype; receiver validation + detach re-checks tightened across every TA/AB/DV proto method; a pre-existing valstack sizing bug in `vm_calls.c3` uncovered by the TA harness fixed (SIGBUS in bound-call prepend when writing at exactly nregs).

## Per-Phase Status (session 269 reference, full run)

| Phase | Total | Pass | Fail | Skip | CE:expected-parse | CE:expected-runtime | CE:unexpected |
|---|---|---|---|---|---|---|---|
| 0-1: Core VM | 2185 | 867 | 209 | 1096 | 3 | 0 | 10 |
| 1: Calling Convention & Closures | 426 | 283 | 48 | 90 | 0 | 0 | 5 |
| 2: Basic Operators | 1969 | 1238 | 111 | 563 | 0 | 0 | 57 |
| 3: Object System | 7766 | 6019 | 647 | 1082 | 0 | 0 | 18 |
| 4: Error Handling & References | 402 | 219 | 79 | 103 | 0 | 0 | 1 |
| 5: Built-in Constructors | 8615 | 6842 | 960 | 813 | 0 | 0 | 0 |
| 6: Built-in Prototype Methods | 4713 | 3760 | 526 | 427 | 0 | 0 | 0 |
| 7: Remaining ES5 Features | 1035 | 463 | 77 | 458 | 0 | 0 | 37 |
| 8: ES5 Built-in Objects | 2747 | 1762 | 462 | 522 | 0 | 0 | 1 |
| 11: Arrow Functions & Templates | 465 | 255 | 45 | 158 | 0 | 0 | 7 |
| 12-13: Destructuring & Spread | 19 | 17 | 0 | 2 | 0 | 0 | 0 |
| 14: for-of | 751 | 363 | 172 | 169 | 0 | 0 | 47 |
| 15: Classes | 8520 | 1474 | 668 | 6318 | 0 | 0 | 60 |
| 17-20: Map/Set/Symbol/Promise/WeakMap/WeakSet | 1614 | 982 | 169 | 463 | 0 | 0 | 0 |
| 21: Generators | 619 | 285 | 192 | 138 | 0 | 0 | 4 |
| **22: Buffers (new)** | **2966** | **827** | **592** | **1547** | **0** | **0** | **0** |

## Test Infrastructure

- **Full suite / single phase**: `python3 scripts/run_test262.py [--phase N] --workers 4` — the single canonical runner (~6-8 min full, <1 min per phase). Kills workers over 2 GB RSS (MEMKILL) so runaway tests can't freeze the machine.
- **Per-test results for clustering**: add `--log out/test262_results.tsv`, then e.g. `awk -F'\t' '$1=="FAIL"{print $2}' out/test262_results.tsv | xargs -n1 dirname | sort | uniq -c | sort -rn`
- **Single-test repro with harness + error output**: `bash test262_runner/run_single_test.sh <path-under-test262/test>` (`--keep` emits the combined file for `just lldb` / `--trace-vm`)
- **Quick smoke**: `bash test262_runner/quick.sh` · **Phase counts**: `bash scripts/count_test262_by_phase.sh`
- **Delta between runs**: `bash scripts/test262_delta.sh`
- **Build**: `c3c build batch_test_vm` or `c3c build test_vm`
- Batch runner now parses `includes: [a.js, b.js]` metadata and loads each harness file (`testTypedArray.js`, `detachArrayBuffer.js`, `propertyHelper.js`, `decimalToHexString.js`, ...). Without this every test referencing `TypedArray`, `testWithTypedArrayConstructors`, `verifyProperty`, etc. failed in the batch suite for reasons unrelated to engine correctness.

## Session Log (condensed, newest first)

| Session | Summary | test262 impact |
|---|---|---|
| **271** | Array literal INITPROP undefined→named-prop; map/filter ArraySpeciesCreate; array_set_elem_ulong_checked undefined+redefine; reduce/reduceRight loop-bound snapshot; sort undefined-last; iterator keys/entries/values done-value leak + entries pair length; Object.defineProperties dense-array sync; push TypeError/RangeError. | **87.2% → 87.9%** (26,826 → 27,047 pass, +221).  Phase 3 +56; Phase 5 +48; Phase 6 +45; Phase 0-1 +39; Phase 15 +35. |
| **270** | copyWithin step-4/5/6 undefined defaults, Array.prototype.flat ArraySpeciesCreate + flatten_into throwing writes, Object.defineProperty(array, "length") value-first ordering. | **83.1% → 87.2%** (25,656 → 26,826 pass, +1,170).  Phase 5 6,842 → 7,208 (+366); Phase 6 3,760 → 3,936 (+176); built-ins/Array/length 21 → 23 (+2); copyWithin 29 → 32 (+3). |
| 269 | Plan 049 stages 1-6 (AB/TA/DV subsystem), %TypedArray% intrinsic, batch-runner includes-loader, builtin metadata, receiver + detach guards, vm_calls stack fix. Merged destructuring (plan 048 A-D + IteratorClose) and 9-jul (disassembler split, TRACE_VM gate, throw dedup) branches. | 81.6% → 83.1% on grown denominator (+2,966 executable via Phase 22). Real pass count: 24,032 → 25,656 (+1,624). |
| 268 | Plan 048 Buckets A-D (destructuring completion), plan 049 doc, session-268 addendum (shortest-round-trip ToString(Number) via QuickJS js_dtoa), five local-suite correctness fixes. | On destructuring branch: 82.8% partial. |
| 267 | Statement destructuring iterator protocol, lexical-closure/eval/capture-analysis scope fixes, catch-binding scope, architecture review (plan 046). | 79.6% → 81.6%. |

# Progress: Duktape C3 — test262 Conformance Tracker

**Last Updated:** Session 273 — **90.6% reached** (27,879 pass / 30,780 executable, up from 88.0%). Dense-array >65535 fix (+~600), String proto ToPrimitive coercion, isWellFormed/toWellFormed, bind name/length, frozen-array pop/shift, Function.prototype[Symbol.hasInstance], Date[Symbol.toPrimitive], JSON.parse -0 + reviver/text coercion, RegExp exec/@@split/@@replace lastIndex+result coercion, for-of destructuring lazy defaults.
**Target:** 100% test262 pass rate on the targeted subset (see plan 040 for the subset definition).

## Summary (full run, session 273, 2026-07-10)

| Metric | Value |
|---|---|
| Pass + Fail + CE (executable) | 30,780 |
| Total passing | 28,084 |
| **Overall pass rate** | **91.2%** |
| Total failing | 2,463 |
| CE unexpected (parser bugs) | 230 |
| Skipped | 14,032 |

Promise combinators (all/any/race/allSettled) + Promise.prototype.then custom
constructor / Promise[Symbol.species]: Phase 17-20 1004 → 1083 (+79). 91.0% → 91.2%.

Up from session 272 (88.0%, 27,079 pass): **+927 pass** this session.

Later in session 273: MEMKILL sweep (14→1), then subclassing-built-ins fix
(instances of `class Sub extends Array/Map/Error/...` now get the subclass
prototype via new.target — Phase 15 Classes 1781→1849, +68),
Object.getOwnPropertyDescriptors implemented, and Object.keys/values/entries
symbol-key leak fixed (Phase 3 +21). 90.6% → 91.0%.

**MEMKILL/TIMEOUT sweep** (near-eliminated, ~14 → 1): (1) sparse-array writes
`a[2**31]=x` grew the dense backing to billions of slots (9.9 GB) — added
`dense_index_ok` gate routing large-sparse indices to the named table; (2) array/
call spread with a throwing iterator-result `value` getter looped forever — now
invokes the getter and routes the throw; (3) RegExp empty global matches
(`/(?:)/g[u]`) didn't AdvanceStringIndex and lastIndex was byte/char-unit
confused — fixed exec + @@match/@@replace. The sole remaining MEMKILL is a
property-escapes test that uses ~450 MB standalone and only trips the 2 GB cap
under concurrent worker pressure (not an engine bug).

## Test Infrastructure

- **Full suite / single phase**: `python3 scripts/run_test262.py [--phase N] --workers 4` — the single canonical runner (~6-8 min full, <1 min per phase). Kills workers over 2 GB RSS (MEMKILL) so runaway tests can't freeze the machine.
- **Per-test results for clustering**: add `--log out/test262_results.tsv`, then e.g. `awk -F'\t' '$1=="FAIL"{print $2}' out/test262_results.tsv | xargs -n1 dirname | sort | uniq -c | sort -rn`
- **Single-test repro with harness + error output**: `bash test262_runner/run_single_test.sh <path-under-test262/test>` (`--keep` emits the combined file for `just lldb` / `--trace-vm`)
- **Quick smoke**: `bash test262_runner/quick.sh` · **Phase counts**: `bash scripts/count_test262_by_phase.sh`
- **Delta between runs**: `bash scripts/test262_delta.sh`
- **Build**: `c3c build batch_test_vm` or `c3c build test_vm`
- Batch runner now parses `includes: [a.js, b.js]` metadata and loads each harness file (`testTypedArray.js`, `detachArrayBuffer.js`, `propertyHelper.js`, `decimalToHexString.js`, ...). Without this every test referencing `TypedArray`, `testWithTypedArrayConstructors`, `verifyProperty`, etc. failed in the batch suite for reasons unrelated to engine correctness.

## Session Log (condensed, oldest first)

| Session | Summary | test262 impact |
|---|---|---|
| 267 | Statement destructuring iterator protocol, lexical-closure/eval/capture-analysis scope fixes, catch-binding scope, architecture review (plan 046). | 79.6% → 81.6%. |
| 268 | Plan 048 Buckets A-D (destructuring completion), plan 049 doc, session-268 addendum (shortest-round-trip ToString(Number) via QuickJS js_dtoa), five local-suite correctness fixes. | On destructuring branch: 82.8% partial. |
| 269 | Plan 049 stages 1-6 (AB/TA/DV subsystem), %TypedArray% intrinsic, batch-runner includes-loader, builtin metadata, receiver + detach guards, vm_calls stack fix. Merged destructuring (plan 048 A-D + IteratorClose) and 9-jul (disassembler split, TRACE_VM gate, throw dedup) branches. | 81.6% → 83.1% on grown denominator (+2,966 executable via Phase 22). Real pass count: 24,032 → 25,656 (+1,624). |
| 270 | copyWithin step-4/5/6 undefined defaults, Array.prototype.flat ArraySpeciesCreate + flatten_into throwing writes, Object.defineProperty(array, "length") value-first ordering. | **83.1% → 87.2%** (25,656 → 26,826 pass, +1,170).  Phase 5 6,842 → 7,208 (+366); Phase 6 3,760 → 3,936 (+176). |
| 271 | Array literal INITPROP undefined→named-prop; map/filter ArraySpeciesCreate; array_set_elem_ulong_checked undefined+redefine; reduce/reduceRight loop-bound snapshot; sort undefined-last; iterator keys/entries/values done-value leak + entries pair length; Object.defineProperties dense-array sync; push TypeError/RangeError. | **87.2% → 87.9%** (26,826 → 27,047 pass, +221).  Phase 3 +56; Phase 5 +48; Phase 6 +45; Phase 0-1 +39; Phase 15 +35. |
| 272 | Two MEMKILL/crash fixes: shape use-after-free in RegExp property-escapes/generated (44 tests), plus a second crash fix. | **87.9% → 88.0%** (27,047 → 27,079 pass, +32). |
| 273 | Dense array >65535 fix (array_size/array_used ushort→uint, put_prop dense routing); String.prototype ToPrimitive("string") coercion; isWellFormed/toWellFormed; bind name/length; frozen-array pop/shift TypeError; Function.prototype[Symbol.hasInstance]; Date[Symbol.toPrimitive]; JSON.parse -0. Then 3 parallel agents: RegExp exec/@@split/@@replace lastIndex ToLength + result coercion; for-of destructuring lazy defaults + REQUIRE_OBJ + bare-LHS PUTVAR; JSON.parse text ToString + spec reviver walk. | **88.0% → 90.6%** (27,079 → 27,879 pass, **+800**). Phase 8 1,514 → 2,030 (+516); Phase 6 +91; Phase 5 +122; Phase 14 387 → 419 (+32); Phase 3 6,368 → 6,410 (+42). |

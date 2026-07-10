# Progress: Duktape C3 — test262 Conformance Tracker

**Last Updated:** Session 273 — dense-array >65535 fix (+~600), String proto ToPrimitive coercion, isWellFormed/toWellFormed, bind name/length, frozen-array pop/shift, Function.prototype[Symbol.hasInstance], Date[Symbol.toPrimitive], JSON.parse -0
**Target:** 100% test262 pass rate on the targeted subset (see plan 040 for the subset definition).

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
| 273 | Dense array >65535 fix (array_size/array_used ushort→uint, put_prop dense routing); String.prototype ToPrimitive("string") coercion for indexOf/includes/etc.; isWellFormed/toWellFormed; Function.prototype.bind name/length; frozen-array pop/shift TypeError; Function.prototype[Symbol.hasInstance]; RegExp @@replace spec-conformant match coercion. | **~+700 pass.** Phase 5 7,261 → 7,392 (+131); Phase 6 3,986 → 4,077 (+91); Phase 8 1,514 → ~1,986 (+472); Phase 3 6,368 → 6,390 (+22). |

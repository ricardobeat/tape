# Progress: Duktape C3 — test262 Conformance Tracker

**Last Updated:** Session 275 — **94.4% reached** (29,028 pass / 30,780 executable, up from 92.6%). More property-semantics: Array.prototype.concat primitive items use CreateDataPropertyOrThrow (throws on a non-extensible Symbol.species result, +18); INITGET/INITSET throw when redefining a non-configurable property (static computed `['prototype']` accessor, +3). Multi-spread argument order (+35): `f(a, ...x, ...y)` produced out-of-order arguments because each SPREAD_ARG wrote at a static offset; SPREAD_ARG now uses a running-total register (write at first_arg+total, advance it), fixing call/new/super across func/method/gen/class. Property-set semantics (+44): PUTPROP on a getter-only accessor (undefined setter) silently succeeded — now throws TypeError (OrdinarySet), fixing compound-assignment `*-s` tests; and object-literal data properties emitted PUTPROP ([[Set]]) instead of INITPROP (DefineOwnProperty), so `{ get foo(){}, foo:1 }` wrongly Set through the getter — converted the three literal emit sites to INITPROP. Init-vs-assign TDZ (+81): assignment to a let/const in its temporal dead zone must throw ReferenceError, but PUTVAR is shared with initialization stores (param sync, for-loop vars) — a TDZ check on PUTVAR itself regressed ~100 default-param tests. Split into a new PUTVAR_ASSIGN opcode (user assignment: =, compound, ++/--, destructuring targets) that TDZ-checks, vs plain PUTVAR (init, no check); then TDZ-hoist top-level let/const at program/eval/module scope. dflt-params, put-let/put-const dstr, and global TDZ all green. Also merged the 11-jul branch (compound-assignment string concat, Number vm-null parse fallback, try/catch/finally completion-value preservation, Function.length via num_formals, Boolean valueOf/toString TypeError) — much of it overlapped the agents' staged work; deduped a double Infinity-overflow check. Three parallel agents landed + reconciled (+161): RegExp.prototype[@@replace] full spec conformance (all 26 tests; incl. a to_primitive_value bool→3-way-hint refactor giving the correct "number" hint); Function.prototype.toString source-text retention for getters/setters/static/generator/async methods + an AsyncFunction constructor (16/19); String.prototype.replaceAll this-coercion in the C call_fn path + abrupt-completion ordering. Reconciliation: the replaceAll agent made builtin_to_string_vm throw on Symbols (correct for ToString) which broke ~55 Symbol-property-key tests — added builtin_to_property_key_vm (§7.1.19, Symbols pass through) routed through hasOwn/hasOwnProperty/propertyIsEnumerable/defineProperty; also fixed a bundled Number("10e10000")→Infinity overflow regression. Async-throw-rejects-Promise fix (+20): an async function that threw an uncaught exception surfaced as a VM_ERROR instead of rejecting its Promise; vm_throw_value now recognizes the async-function boundary (ACT_FLAG_ASYNC) the same way it recognizes catchers — the throw rejects the frame's Promise and unwinds like a return, at the single chokepoint every throw funnels through. Generator-completion fix (+75): a generator whose body threw stayed in GEN_EXECUTING, so a later `.next()` wrongly reported "Generator is executing" — the exception unwinder now transitions each generator frame it pops past to GEN_COMPLETED (via the reused `async_gen_state` activation slot), clearing the whole `iter-step-err` dstr cluster. Earlier this session — **Full destructuring unification**: the algorithm had been implemented independently across ≥6 contexts (a shared array emitter; bespoke ObjBind object decl/assign; four inline copies in bare for-of, bare for-in, for-in-decl, and catch patterns). Consolidated ALL of them onto the single `emit_destruct_bindings` + one parser per pattern kind (array/object). Removed ~2,000 lines and the dead `ArrayBind`/`ObjBind` structs. Along the way fixed: object rest in the shared emitter (`{a,...r}` yielded undefined), empty/elision array patterns performing GetIterator (`[] = undefined` → TypeError), NamedEvaluation for destructuring defaults (`{a = fn}` names fn), a const-assignment-target check via the new `assign_needs_putvar` flag (replacing register-number guessing that mis-fired on r0), and leaf object-rest done-latching so a consumed iterator skips IteratorClose. Phase 14 for-of 461→497 (+36).
**Target:** 100% test262 pass rate on the targeted subset (see plan 040 for the subset definition).

## Summary (full run, session 275, 2026-07-10)

| Metric | Value |
|---|---|
| Pass + Fail + CE (executable) | 30,780 |
| Total passing | 29,028 |
| **Overall pass rate** | **94.4%** |
| Total failing | 1,585 |
| CE unexpected (parser bugs) | 164 |
| Skipped | 14,032 |

**Remaining known clusters:** `yield` inside a destructuring default (3 tests) —
the shared emitter's lazy default thunks can't suspend the enclosing generator
(needs inline defaults). Larger open areas: yield* delegation edge cases,
class-definition/subclass, super/this-binding, TypedArray species/from, Unicode
identifiers (crash), Array species/proxy in flatMap. (put-let/put-const TDZ and
async-throw-rejects-Promise — previously listed here — are now fixed.)

Session 274 batch 3 — **destructuring consolidation**. Root cause of the
recurring destructuring failures: the algorithm was implemented 3× independently
(shared emit_destruct_bindings; a 1,450-line inline for-of copy; the dead
destructure_for_value), so each fix patched only one copy. Deleted the dead copy
(287 ln) and the inline for-of copy (1,352 ln), rerouting for-of through the
shared emitter (collect_*_param_binds → emit_destruct_bindings(DECLARE)). Added
computed-key support to the shared emitter as the enabling prerequisite (Phase 15
Classes +16 on its own). Phase 14 for-of 434→461 (+27), Phase 21 Generators +4,
CE-unexpected 230→201. Net ~1,600 lines removed, zero regressions across 3,563
dstr/for-of/assignment tests. 92.5% → 92.6%. Cumulative session 91.2% → 92.6%
(+1,432 pass).

Session 274 second batch (self + 3 parallel worktree agents, reconciled):
Function.prototype.toString object-method source retention (cluster 62→70);
ToNumber 0b/0o literals; defineProperties/defineProperty dense-promotion +
for-in enumerable + RegExp lastIndex non-enumerable (Phase 3 +33, Phase 5 +33);
super method this-binding + rest params in call_fn + Symbol.replace brand check
(Phase 6 +5, Phase 15 +2). 92.2% → 92.5%. Cumulative session: 91.2% → 92.5%
(+373 pass).

Session 274 landed four fixes: (1) bound-function re-dispatch refcount
(+258, Phase 22 857→1119); (2) for-of destructuring RequireObjectCoercible
+ IteratorClose (Phase 14 419→434); (3) spec-compliant parseInt rewrite
(Phase 8 +20, parseInt cluster 23→~1). 91.2% → 92.2% (+303 pass).

Session 274: bound-function re-dispatch refcount fix. Phase 22 Buffers
857 → 1119 (+262); Phase 5 +1, Phase 6 +140 vs 270 baseline, Phase 8 +13.
Root-caused via HW watchpoint: `builtin_bound_call` compiled/BUILTIN_FN
re-dispatch copied bound args into the callee register window with raw
assignment. The callee decrefs those slots, but the bound args were read
from the stored args array (`get_prop_proto`) without an incref → net
over-decref, premature free of a live object (a TypedArray constructor),
pool-block recycle into the next bound function. Fixed by increffing
heap-ref bound args (indices `< bound_argc`) before the register write.
91.2% → 92.1% (+258 pass).

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

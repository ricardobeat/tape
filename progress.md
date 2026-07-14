# Progress: Duktape C3 — test262 Conformance Tracker

**Last Updated:** Session 281 — **97.9% reached** (30,534 pass / 31,177 executable, up from 97.7%; five parallel worktree agents on hashbang / super / global-code / JSON+Function+defineProperty / Promise, then merge repairs for ARRAY-length prototype lookup, has_error/call boundary semantics, and Zs whitespace).

Session 276 second batch (five more fixes, committed + validated):
- **`new X().p = v` assignment ran no setter** (root-cause codegen): `new_expr`'s
  trailing-member loop emitted GETPROP but never set `last_was_member`, so an
  enclosing assignment saw a non-member LHS and compiled the store as a discarded
  read — prototype setters didn't fire and the value was dropped. (`(new X()).p`
  worked, routing via `member_expr`.) Now records member regs on a trailing
  `.prop`/`[idx]` that isn't a call. Fixes class name-binding const/basic/expr;
  Phase 15 +3.
- **Array generics read TypedArray indices**: `arr_get_elem_vm`/`arr_has_prop`
  only served ARRAY/ARGUMENTS dense + named props, so TypedArray buffer indices
  read as absent (`[].concat(ta)`→nulls). Added an `is_typed_array_class` fast
  path (`ta_load_element`) benefiting every array generic; concat typed-array
  small/large pass.
- **RegExp `@@search` lastIndex save/restore + Symbol string arg**: never read
  rx.lastIndex (poisoned getter didn't throw) and reset to 0 after exec instead
  of save/restore; also the Symbol-as-string fast path (shared by @@search/
  @@match/@@split/@@replace) took a Symbol verbatim instead of throwing via
  ToString. Symbol.search 23/23.
- **String.prototype.slice** clamps ±Infinity args before the int cast (were
  wrapping to garbage indices). slice 38/38.
- **Array.prototype.slice** `end === undefined` now defaults to len (was coerced
  to 0, returning empty). +2.

Session 276 first batch (five spec-coercion / property fixes):
- **Object.values/entries key-order + getter invocation**: emitted dense indices
  *after* named props (wrong OrdinaryOwnPropertyKeys order) and read accessor
  slots raw via `prop_values()[i]` (returning the descriptor, not the getter
  result). Refactored keys/values/entries onto one shared ordered key-collector
  (`collect_own_enum_string_keys`) + `desc_get_enum` ([[Get]] with String-exotic
  char fallback); keys snapshotted before any getter runs. Phase 3 +8 (remaining
  values/entries fails need Proxy + mid-enum enumerability re-check).
- **Array/String.prototype.at index coercion**: both used
  `builtin_to_number_getdouble` (no valueOf, no throw-propagation) so
  `a.at({valueOf(){return 1}})` returned undefined. Now ToIntegerOrInfinity via
  `builtin_to_integer_vm`. +6.
- **Array.prototype[Symbol.unscopables]**: was entirely absent. Installed the
  ES2023 null-proto list ({writable:false, enumerable:false, configurable:true}).
  +4.
- **String.prototype.repeat**: coercion must run (and possibly throw) *before* the
  RangeError range check; a count object coercing to 0 wrongly threw. Now
  `builtin_to_integer_vm` first. repeat 16/16.
- **String.prototype.lastIndexOf**: `position` didn't run valueOf / propagate its
  throw, and mapped NaN→0 instead of NaN→+∞ (search from the end). Now
  `builtin_to_number_vm` + NaN→clen. lastIndexOf 25/25.

Session 275 highlights (newest first; details in the session log below):
- Every builtin function has an own `.length` (default 0 when metadata arity
  unknown) — most prototype methods previously lacked it (+37).
- Function constructor propagates ToString(body/params) exceptions (+17).
- Four parallel worktree agents landed + reconciled — RegExp @@replace, @@match/
  @@matchAll/@@split species+coercion, Function.toString source retention +
  AsyncFunction, String.replaceAll, TypedArray set/copyWithin/slice, plus a
  broad GETPROP inline-cache proto-guard and bound-fn refcount fix. Genuine
  hunks extracted per-file from stale-base diffs that would otherwise revert
  recent work (see [[parallel-agent-workflow]]).
- Property semantics: getter-only-accessor assignment throws (OrdinarySet);
  object literals use INITPROP (DefineOwnProperty) not [[Set]]; concat/
  defineProperties CreateDataPropertyOrThrow + array-length checks; INITGET/
  INITSET reject non-configurable redefine; multi-spread argument order.
- **Init-vs-assign TDZ**: new PUTVAR_ASSIGN opcode (user assignment TDZ-checks)
  vs plain PUTVAR (init, no check) + global let/const TDZ hoisting (+81).
- **Generator/async throw**: a generator body that throws → GEN_COMPLETED
  (cleared "Generator is executing"); an async body's uncaught throw rejects its
  Promise — both at the single vm_throw_value chokepoint (+95).
- **Full destructuring unification**: ≥6 independent copies collapsed onto one
  emit_destruct_bindings + one parser per pattern kind; ~2,000 lines + the dead
  ArrayBind/ObjBind structs removed. Phase 14 for-of 461→497.
**Target:** 100% test262 pass rate on the targeted subset (see plan 040 for the subset definition).

## Summary (full run, session 276, 2026-07-11)

| Metric | Value |
|---|---|
| Pass + Fail + CE (executable) | 30,780 |
| Total passing | 29,285 |
| **Overall pass rate** | **95.1%** |
| Total failing | 1,328 |
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
| 281 | **Five parallel worktree agents + merge repairs.** Merged: (1) **hashbang comments** (§12.5) in Script/Module/eval — Lexer.skip_hashbang() at pos 0 only, literal `#!` bytes; latent CompilerContext.finish() bug fixed (peek-only lex errors were silently swallowed via synthetic EOF_TOKEN, letting compile succeed on malformed input) via g_last_err_msg check at the finish choke point. (2) **regex-after-block-close** — Lexer.note_block_close() sets force_regex_after_brace hint from parser after `}` closing Block/function/class body in statement position; next `/` scanned as RegExp. (3) **global var/fn non-configurability** — env_declare_var(is_global) marks script-level var/function bindings as {writable:true,configurable:false} per §CreateGlobalVar/FunctionBinding. (4) **super rewrite** — object-literal `__super__` isolated per literal (PUSH_LEX/POP_LEX; sibling collision fixed); GETPROP_SUPER/PUTPROP_SUPER re-derive registers post-ToPropertyKey (could reallocate), propagate throws, run LDTHIS TDZ check before key eval; repeated super() → ReferenceError; CLASS_INITGET/CLASS_INITSET check configurability; caller/arguments poison gated on own-property presence; SPREAD_ARG uses GetMethod for @@iterator + TypeError on non-object result. (5) **Function/Array/JSON/defineProperty** — Function() ctor wires .prototype.constructor, sets .name, marks callable/constructable; Function.prototype constructable=false (was segfaulting on `new`); Array() ctor length via exotic array_len_ptr slot (was leaking into for-in/keys/stringify); JSON.stringify snapshot filtered by enumerable + skips Symbols; PUTPROP write-guard for function.caller/arguments, accessor setter frames explicitly set undefined for extra params (zero-bytes decoded as fastint 0), inherited get-only accessors throw TypeError on assign. (6) **Promise rewrite** — promise_resolve_with_value implements ES6 §25.4.1.3.2 (self-resolution TypeError, thenable coercion, poisoned .then propagation); PromiseResolveThenableJob queued as microtask; combinator remainingElementsCount fixed for synchronous thenables; capability_invoke IfAbruptRejectPromise; Promise.any resolve elements have no shared [[AlreadyCalled]]; promise_get_iterator throws TypeError on non-iterable; Promise.prototype.finally rewritten per ES2018 §27.2.5.3; species_constructor reads through accessors. Merge repairs: (a) get_prop_or_accessor_proto / has_prop_proto honor ARRAY exotic length on prototype-chain arrays (was returning undefined for `Foo.prototype = arr; new Foo().length` — broke reduce/reduceRight/join/split subclassing tests); (b) vm_check_call_fn_error checks heap.has_error (Promise agent's clear of vm.has_error at call boundary blinded ToPrimitive-throw detection); (c) reverted vm.has_error boundary-clear (broke YIELD_STAR/spread which check has_error) — heap.has_error path suffices; (d) lexer whitespace additions for Zs class (U+1680, U+2000-U+200A, U+202F, U+205F, U+3000) — the finish() strict propagation exposed pre-existing gaps as compile errors. | **97.7% → 97.9%** (30,460 → 30,534 pass, +74 net; 158 fixed / 84 regressions vs s281 baseline, mostly flaky RegExp/Symbol.split ±16 + real ~66 in shift/pop frozen-array/optional-chaining follow-ups). |
| 280 | **for-of/dstr iterator-close completed (20/20) + register-allocator hardening + two latent VM bugs.** (1) Deferred destructuring member targets (`[...obj['a'+'b']] = v`) re-parse at emission via lexer snapshot (collect_assign_target/emit_deferred_target) instead of replaying captured bytecode whose absolute registers clobbered live state (array-rest-lref) — also removes the 16-instr cap and NOP litter; +11 dstr tests. (2) statement() reclaims all temporaries above the statement's watermark (member calls stranded ~2 regs/statement: the 'this' obj register sits below the call window it outlives, LIFO free no-ops; 306 assert statements exhausted 512 regs); reserved_regs pins params + hoisted slots against any free (pre-existing param clobber: expression statement returning a param's register freed it); register exhaustion is now a COMPILE_ERROR, not abort() (a pathological file killed the whole batch worker + every queued test). (3) NEW_OBJ on builtins: `this` slot at callee_reg+1 is never written for `new` — stale-data roulette (old layout made `new String.prototype.charAt` throw by accident, new layout made it succeed); now undefined `this` + builtin_fn_is_constructor gate (lightfunc ctor table + TA/AB/DV/Proxy/proxy-call/%AsyncFunction%) throwing "not a constructor" per §10.3 — fixes S15.5.4.*_A7 family. (4) Builtin results written directly into register slots are borrowed refs; decref_callee_regs sweeps [0..max_heap_reg] assuming owned → over-decref freed live objects (ASan use-after-poison: bound Promise.resolve pass-through via re-dispatch crashed Promise invoke-resolve tests); direct-register dispatch sites converted to local-result + tval_copy_ref + track_heap_store. Debug note: `-c` disasm only prints ONE level of inner functions — nested closures compile invisibly. | **97.7%** (30,407 → 30,460 pass, +53 incl. +31 dstr from 4 commits at session start; 0 regressions). for-of/dstr 20/20 target cleared; bench-fast at baseline. |
| 279 | **Module fn-export hoisting + four correctness fixes.** (1) Module top-level `function` declarations now instantiate at LINK time (16.2.1.5.5 step 17) via new ModuleDef.func_decls + vm::instantiate_closure; body no longer emits CLOSURE+DECLVAR for them, so cyclic early imports see the hoisted function (not undefined) and identity is stable; also rooted mod.env bindings in link_module (latent GC gap). (2) `typeof local.prop` no longer clobbers the base local variable (member_expr tracks last_member_obj_is_local; typeof writes result into the GETPROP temp, not the live local) — was throwing "in requires an object" on `verifyProperty`-style descriptor checks. (3) Error.prototype.toString throws TypeError on non-object receiver (§19.5.3.4). (4) Symbol.prototype[@@toPrimitive] installed as a real function (name "[Symbol.toPrimitive]", length 1, {W:false,E:false,C:true}) instead of a lightfunc. (5) construct_fn (internal Construct for NewPromiseCapability) now handles derived classes (TDZ this + ACT_FLAG_DERIVED, reads super-initialized this back) and rest params (builds the rest array) — fixes Promise.{all,allSettled,race,any,resolve} subclassing. | **97.5%** (30,393 → 30,407 pass, +15 real improvements, 0 regressions). Phase 17-20 +8, Phase 15 +5, Phase 4 +2. |
| 267 | Statement destructuring iterator protocol, lexical-closure/eval/capture-analysis scope fixes, catch-binding scope, architecture review (plan 046). | 79.6% → 81.6%. |
| 268 | Plan 048 Buckets A-D (destructuring completion), plan 049 doc, session-268 addendum (shortest-round-trip ToString(Number) via QuickJS js_dtoa), five local-suite correctness fixes. | On destructuring branch: 82.8% partial. |
| 269 | Plan 049 stages 1-6 (AB/TA/DV subsystem), %TypedArray% intrinsic, batch-runner includes-loader, builtin metadata, receiver + detach guards, vm_calls stack fix. Merged destructuring (plan 048 A-D + IteratorClose) and 9-jul (disassembler split, TRACE_VM gate, throw dedup) branches. | 81.6% → 83.1% on grown denominator (+2,966 executable via Phase 22). Real pass count: 24,032 → 25,656 (+1,624). |
| 270 | copyWithin step-4/5/6 undefined defaults, Array.prototype.flat ArraySpeciesCreate + flatten_into throwing writes, Object.defineProperty(array, "length") value-first ordering. | **83.1% → 87.2%** (25,656 → 26,826 pass, +1,170).  Phase 5 6,842 → 7,208 (+366); Phase 6 3,760 → 3,936 (+176). |
| 271 | Array literal INITPROP undefined→named-prop; map/filter ArraySpeciesCreate; array_set_elem_ulong_checked undefined+redefine; reduce/reduceRight loop-bound snapshot; sort undefined-last; iterator keys/entries/values done-value leak + entries pair length; Object.defineProperties dense-array sync; push TypeError/RangeError. | **87.2% → 87.9%** (26,826 → 27,047 pass, +221).  Phase 3 +56; Phase 5 +48; Phase 6 +45; Phase 0-1 +39; Phase 15 +35. |
| 272 | Two MEMKILL/crash fixes: shape use-after-free in RegExp property-escapes/generated (44 tests), plus a second crash fix. | **87.9% → 88.0%** (27,047 → 27,079 pass, +32). |
| 273 | Dense array >65535 fix (array_size/array_used ushort→uint, put_prop dense routing); String.prototype ToPrimitive("string") coercion; isWellFormed/toWellFormed; bind name/length; frozen-array pop/shift TypeError; Function.prototype[Symbol.hasInstance]; Date[Symbol.toPrimitive]; JSON.parse -0. Then 3 parallel agents: RegExp exec/@@split/@@replace lastIndex ToLength + result coercion; for-of destructuring lazy defaults + REQUIRE_OBJ + bare-LHS PUTVAR; JSON.parse text ToString + spec reviver walk. | **88.0% → 90.6%** (27,079 → 27,879 pass, **+800**). Phase 8 1,514 → 2,030 (+516); Phase 6 +91; Phase 5 +122; Phase 14 387 → 419 (+32); Phase 3 6,368 → 6,410 (+42). |
| 278 | **Five parallel agents + plan 052 (road to zero).** Merged 4 of 5: dstr MemberExpression targets (`[{}.x]=a` via primary_is_member_target lookahead) + strict unresolvable ReferenceError; super rework (computed `super[x]` w/ spec key ordering, GETPROP_SUPER, object-literal accessor super, `delete super.x` THROW_REF, arrow super(), class-without-extends super); yield* delegation (return/throw forwarding, result validation, throw-violation TypeError, generator this_binding restore); TypedArray.from/of/toLocaleString/species/@@iterator (58 fixes). **Fifth agent (global/eval decl-instantiation) reverted** — nondeterministic heap corruption + ~22 scope regressions; redo tracked in plan 052. Post-merge repairs: copyWithin OOB memmove when target==len (ASAN heap-buffer-overflow); Array.toString join-error lost throw_value (threw 0); object-literal reg free order (LIFO — key-before-val leaked 1 reg/property, broke 513-element literals); `__proto__: fn` NamedEvaluation suppressed; $262 host object ({detachArrayBuffer, evalScript, global}) moved out of engine core behind vm::test262_host_enabled (harness binaries only), GC-rooted install order. Runner: serial retry of non-pass on by default (kills ±30 flakiness), RSS cap 3 GB. Known pre-existing: register leak on repeated object-literal call args (`f({..});` ×513). | **95.4% → 95.9%** (29,753 → 29,899+ pass, +147 net, 0 regressions). CE:unexpected 132 → 73. |
| 277c | **11-jul branch merged + repaired.** Merge kept main's coercion/proxy paths; lightfunc call_fn throws now signal both error channels (has_error + throw_pending). Six merge regressions root-caused and fixed: (1) is_class_ctor heuristic (`is_constructable && in_class_body`) mislabeled function expressions nested in class methods — now stamped only on the actual ctor CompiledFunction; (2) 11-jul call/apply thisArg boxing (sloppy §15.3.4.3 semantics) reverted — strict-only engine passes thisArg unchanged; (3) object-literal `super` rebuilt: __super__ = HomeObject + new GETPROTO opcode (dynamic GetPrototypeOf, proxy-aware) + lazy binding (eager reg-per-literal exhausted registers on 513-element literal arrays) + new PUTPROP_SUPER opcode for `super.x = v` with receiver=this via js_set_with_receiver; (4) static accessor toString source lost `get`/`set` prefix (match_static_modifier pushback vs lexer token_start) — element start now recorded; (5) Object.prototype.toString on callable proxy → "[object Function]"; (6) Number(): trailing-ws Infinity + overflow literals (duplicate case-guard removed). | **95.1% → 95.4%** (29,285 → 29,751 pass, +466 incl. 11-jul's batches). Phase 3 +34, Phase 5 +37, Phase 6 +24, Phase 15 +24 vs pre-merge; Proxy steady 206/206. |
| 277b | **Proxy follow-up: 41 `features:[Proxy]` fails outside built-ins/Proxy cleared** (3 parallel agents). Array cluster: ArraySpeciesCreate/IsConcatSpreadable via proxy_is_array; arr_get_elem_vm/arr_has_prop/array_set_elem_ulong_checked/array_delete/set_length proxy MOP routing; Array.of `this` constructor; js_set_with_receiver [[GetOwnProperty]] step; entries/values per-key trap interleaving. Function cluster: Function.prototype.toString on proxies → NativeFunction string (was reading func union off proxy extra); lightfunc ToString via Function.prototype.toString; trap-absent [[Construct]] threads proxy as new.target (revoked-mid-construct TypeError). Object/language cluster: seal/freeze via [[PreventExtensions]]; Object.prototype.toString proxy IsArray + revoked; isPrototypeOf via [[GetPrototypeOf]]; OBJSPRD proxy spread path; defineProperties proxy props arg; new CHKCTOR opcode — `class extends` non-constructor (arrow/async/generator) TypeError, async fns marked non-constructable. | Phase 3 +33, Phase 5 +39, Phase 6 +25, Phase 15 +6 (net +103); Proxy phase steady 206/206; all fails now at or below pre-Proxy baselines. |
| 277 | **Plan 050: Proxy implemented.** PROXY storage (target/handler in HObjectExtra, GC-traced), Proxy global + revocable + revoker, all 13 proxy_mop_* internal methods with full invariant validation (src/builtins/proxy.c3). Wiring: GETPROP/GETPROPC/GETPROPC2/PUTPROP/DELPROP/IN opcodes; proxy-aware hobject chain walkers via heap.proxy_get_fn/proxy_has_fn bridges (fixes proxy-on-prototype-chain + all get_prop_proto method lookups incl. @@iterator); apply/construct via BUILTIN_PROXY_CALL (extra.proxy.builtin_fn_index overlays HObjectFunction layout); Object.* builtins, for-in, Array.isArray recursion, instanceof/[@@hasInstance] [[GetPrototypeOf]] walks. Side fixes: plain member assignment no longer evaluates the LHS getter (compiler); fn .prototype now W/¬E/¬C; regexp lastIndex ¬E; INSTANCEOF trap errors catchable; call_fn dispatches bound fns; setPrototypeOf cycle check. Runner: Phase 23 built-ins/Proxy added, Proxy feature flag unskipped. | **built-ins/Proxy 206/206 non-skipped pass** (311 total, 105 skipped: Reflect/other-feature deps). Phases 3/5/6 net +38/+35/+5 pass with ~165 formerly-skipped `features:[Proxy]` tests now counted (their fails are follow-up). |
| 276 | Ten fixes over two batches. Batch 1 (coercion/ordering): Object.values/entries key-order + getter [[Get]] (shared collect_own_enum_string_keys + desc_get_enum); Array/String.prototype.at ToIntegerOrInfinity index; Array.prototype[Symbol.unscopables] installed; String.prototype.repeat coerce-before-RangeError; String.prototype.lastIndexOf position ToNumber + NaN→+∞. Batch 2: `new X().p=v` runs setters (new_expr member-LHS codegen); array generics read TypedArray buffer indices (arr_get_elem_vm/arr_has_prop); RegExp @@search lastIndex save/restore + Symbol-string-arg throw; String.slice ±Infinity clamp; Array.slice end=undefined→len. | **94.9% → 95.1%** (29,196 → 29,285 pass, +89). Phase 3 +19; Phase 6 +8; Phase 8 +17; Phase 15 +3; at/unscopables/repeat/lastIndexOf/slice/Symbol.search/concat-typed-array clusters cleared. |
| 276-11jul | Five parallel fixes targeting isolated test262 clusters (~68 tests). (1) **Compound assignment `+=` string concat** (+23): removed INC/INC_VAR optimization for `+= 1` which bypassed ADD's string-concat semantics; `"1" += 1` → `"11"`. (2) **Number(string) parsing** (+15): Unicode whitespace via CESU-8 codepoint-aware scan (decode_codepoint_at + is_ecma_ws_codepoint), hex literal requires ≥1 digit after `0x`, case-sensitive "Infinity" check after strtod, Number constructor ToPrimitive error propagation via builtin_to_number_vm. (3) **try/catch/finally completion values** (+10): compiler saves/restores eval_acc_reg so finally's normal completion doesn't overwrite try block's value per ES2015 §13.15.8. (4) **Function constructor .length** (+10): use `func.num_formals` instead of `ctx.argc - 1`. (5) **Boolean.prototype.valueOf/toString TypeError** (+10): throw TypeError when `this` is not Boolean, matching ES2015 §15.6.4.3/§15.6.4.2. Rosetta 99/100 (pre-existing strict_mode.js). Exact pass count pending full test262 run. | 93.4%+ (pending full run). |
| 277-11jul | Plan 051: 13 focused parallel fixes across 14 files (~200 tests targeted). **Class methods non-enumerable** (11): new CLASS_INITPROP/INITGET/INITSET opcodes with {e:false} per §14.5.14. **Class ctor TypeError** (25): is_class_ctor check in CALL dispatch. **Symbol protocol guard** (25): ToPropertyKey for Symbol keys in Object.defineProperty, builtins_generic_get for getter error propagation in split/replace. **valueOf/toString non-generic** (11): thisStringValue TypeError + padStart/padEnd arity 2→1 + localeCompare metadata. **Arg coercion** (13): at/lastIndexOf/repeat use builtin_to_number_vm for ToPrimitive; repeat(NaN)→"". **IsRegExp check** (6): startsWith/endsWith/includes throw TypeError for RegExp arg. **Object literal super** (23 CEs): has_super_binding + __super__=Object for concise methods. **Reserved words** (24 CEs): static modifier lookahead so static() is a method name. **Dup data props** (2 CEs): removed strict-mode duplicate key rejection. **Object.entries/values order** (8): integer-first then string properties. **Symbol.iterator identity** (1): Array[@@iterator]===values. **call/apply boxing** (8): fn_to_object_for_this boxes primitives. | 93.4%+ (pending full run). |

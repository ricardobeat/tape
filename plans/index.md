# Plans Index

| Plan | Status | Notes |
|------|--------|-------|
| [001-architecture-improvements.md](001-architecture-improvements.md) | ✅ DONE | NaN-boxing implemented and default |
| [002-tval-inlining.md](002-tval-inlining.md) | ✅ DONE | TVal methods converted from `@inline fn` to `macro` |
| [003-hotpath-optimization.md](003-hotpath-optimization.md) | ✅ DONE | CALL/RET three fixes applied |
| [004-codebase-review.md](004-codebase-review.md) | ✅ DONE | Review completed; findings actioned across later plans |
| [005-libc-memory-removal.md](005-libc-memory-removal.md) | 🔶 PARTIAL | Some allocations routed through Heap; ~30+ `libc::malloc` sites remain |
| [006-tech-debt.md](006-tech-debt.md) | ✅ DONE | All 4 items: buffer constants, CallableKind, PropLookupResult, `is_prototype_of` |
| [007-vm-dispatch-optimization.md](007-vm-dispatch-optimization.md) | ✅ DONE | Debug printf removed; threaded dispatch deferred/superseded |
| [008-ic-crash-gc-roots.md](008-ic-crash-gc-roots.md) | ✅ DONE | IC crash fixes, GC root marking, iterator support all applied |
| [009-hobject-subtype-split.md](009-hobject-subtype-split.md) | ✅ DONE | `HObjectExtra` tagged union exists; derived pointers are methods |
| [010-VM-GC-issues.md](010-VM-GC-issues.md) | ✅ DONE | Bug 1 (IC base) + Bug 2 (delete_prop) fixed; Bug 3 resolved by refcounting |
| [011-memory-optimization.md](011-memory-optimization.md) | 🔶 STALLED | Superseded by plans 029–033; kept for historical context |
| [012-speed-optimization.md](012-speed-optimization.md) | ✅ DONE | All items completed across Sessions 114–123 |
| [013-speed-optimization-2.md](013-speed-optimization-2.md) | ✅ DONE | All items done: RC, RET restart, valstack_top cache |
| [014-test262-review.md](014-test262-review.md) | ✅ DONE | Status snapshot; remaining gaps tracked in progress.md |
| [018-rebase-rc-on-delta-shapes.md](018-rebase-rc-on-delta-shapes.md) | ✅ DONE | String RC rebased on delta shapes (Session 146) |
| [019-shape-optimize-bench.md](019-shape-optimize-bench.md) | ✅ DONE | bench_shape 73×→0.8× (Session 147) |
| [020-fable-review.md](020-fable-review.md) | ✅ DONE | All 8 items complete per plan 021 status table |
| [021-struct-cleanup.md](021-struct-cleanup.md) | ✅ DONE | Items B (CallableKind→accessor) & C (PropHashInfo side struct) complete |
| [022-property-descriptor-correctness.md](022-property-descriptor-correctness.md) | 🔶 IN PROGRESS | Session 167: defineProperties non-configurable validation fix (+16 net); Session 163: NEW_OBJ lightfunc constructable check (+170 net); Session 162: ToString exponential notation fix (+67 net); Bugs A & C already fixed (seal/freeze dense arrays, GOPD flags) |
| [024-fused-opcodes.md](024-fused-opcodes.md) | ✅ DONE | GETPROPC + compare-and-branch fused opcodes; peephole passes; rotated loops (Session 148–149) |
| 025-callback-error-propagation | ✅ DONE | vm_call_fn_impl Case 3 fix; arr_call_callback error handling; find/findIndex native builtins; print toString (Session 149) |
| [023-missing-prototype-methods.md](023-missing-prototype-methods.md) | 🔶 PARTIAL | Date.toDateString/toTimeString, String.replaceAll/matchAll/normalize added (Session 150); remaining methods TBD |
| 027-declvar-ic | ✅ DONE | DECLVAR inline cache: skip find_prop_idx on repeat calls (Session 150) |
| 028-test262-conformance | ✅ DONE | arr_throw_type_error propagation; sloppy-mode PUTPROP; Array.prototype metadata; Object.seal/freeze non-objects; global `this` (Session 151) |
| [029-memory-low-hanging-fruit.md](029-memory-low-hanging-fruit.md) | 🔶 PARTIAL | Items 1, 3, 4 done. Items 2 (default proto), 5 (sparse IC) remain; see plan 033 |
| [030-memory-profiling.md](030-memory-profiling.md) | ✅ DONE | Inline props, unified prop_alloc, and FixedBlockPool object pools implemented. Boxed accessor pairs deferred to plan 033 |
| [031-string-intern-bloat.md](031-string-intern-bloat.md) | ✅ DONE | Skip-interning for ADD concat + lazy intern in get_prop_key; memory 15,776→6,688 KB. Fix 2 (GC in alloc_no_gc) retracted post-completion — caused double-frees and the ~1s shape bench regression |
| [032-gc-safepoints.md](032-gc-safepoints.md) | ✅ DONE | `gc_pending`, `safepoint_gc()`, and `temproot` protection implemented in heap.c3/vm.c3 |
| [033-memory-next-steps.md](033-memory-next-steps.md) | 🔄 IN PROGRESS | GC on backward jumps (item 2) done; boxed accessor pairs (item 1) done. Remaining: default-prototype elision |
| [034-async-await.md](034-async-await.md) | ✅ DONE | Async/await implemented via resumable execution on the generator save/restore path (see AGENTS.md invariants). Async generators (`async function*`) remain out of scope (B35 skip) |
| [035-enforce-strict-mode.md](035-enforce-strict-mode.md) | ✅ DONE | Engine is strict-only, single mode; no `is_strict` flag remains (see AGENTS.md "Strict-Only Mode") |
| [036-vm-split.md](036-vm-split.md) | ✅ DONE | vm.c3 split into `src/vm/` (vm_execute, vm_calls, vm_objects, vm_property, vm_arith, …) |
| [037-esm-modules.md](037-esm-modules.md) | ✅ DONE | `duktape_c3 -m/--module` runs ESM via `esm::resolve_module`; `test/mod_*.js` exercise it |
| [038-numeric-separators-bigint.md](038-numeric-separators-bigint.md) | 🔶 PARTIAL | Numeric separators lex (covered by `test/test_dtoa_edges.js`); BigInt deferred (skip-listed) |
| [039-binary-size-dedup.md](039-binary-size-dedup.md) | 🔄 IN PROGRESS | Binary 1.23MB→1.12MB via build flags (082f193); Phase 1: dead code removal + disassembler gate; Phase 2: Map/Set/WeakMap/WeakSet dedup, error-throw helper done (8d5d034), compiler/VM dedup remaining |
| [040-test262-100-percent.md](040-test262-100-percent.md) | 🔄 ACTIVE | **Roadmap to 100% on the targeted subset** — session-250 baseline (71.8%), failure clusters, wave plan, architecture blockers (UTF-16 string model, fn source retention, spec-op helpers, peephole guardrail) |
| [041-array-set-elem-retirement.md](041-array-set-elem-retirement.md) | 📋 PLANNED | Retire hidden-dense-write hazard (set_array_idx on plain objects); migrate shift/sort/at/includes/join + toReversed family to the B40 ulong helpers. Oracle: test/test_041_array_like_gaps.js (7 failing today, done at 12/12) |
| [042-call-callee-register-overlay.md](042-call-callee-register-overlay.md) | 📝 DOCUMENTED | CALL overlays the callee frame onto the caller's register array at `callee_reg+2`, clobbering caller-owned live state (surfaced in destructuring rest loops). Compiler workaround in place (low-register pre-allocation); proper fix planned in [043-call-frame-isolation.md](043-call-frame-isolation.md) |
| [043-call-frame-isolation.md](043-call-frame-isolation.md) | ✅ IMPLEMENTED | Systematic fix for the plan-042 overlay: `reserve_call_frame` centralizes the sliding-window CALL danger-zone reservation (replaced all 8 open-coded `next_reg` bumps; corrected two `Object.assign` sites to reserve both arg slots), `alloc_persistent_reg` documents loop-carried state. Compiler-only, VM untouched. Oracle: `test/test_call_frame_overlay.js`. `emit_call` skipped (no fusible site); COMPILE_VERIFY deferred to the SSA-IR milestone |
| [044-statement-destructure-iterator.md](044-statement-destructure-iterator.md) | ✅ IMPLEMENTED | Statement-level array destructuring (`var/let/const [h, ...t] = x` and assignment form) rerouted through the shared iterator-protocol emitter `emit_destruct_bindings` with a new `DestructStoreMode` (declare vs param-sync vs assign); legacy index/`.slice()` emitters deleted. Oracle: `test/test_statement_destructure_iter.js` |
| [045-capture-analysis.md](045-capture-analysis.md) | ✅ IMPLEMENTED (Phase A) | Captured locals must be env-resident: closure/eval writes are invisible to the outer function's register reads (and vice versa). Token pre-scan marks captured names `is_captured` before body compile; per-iteration `for(let…)` bindings tracked as sub-item |
| [046-architecture-review.md](046-architecture-review.md) | 📋 ROADMAP | Session-267 architecture & code review: findings register (correctness + size audits), 81.6% test262 baseline, prioritized waves toward QuickJS parity (destructuring consolidation = conformance + 40–70 KB, VM error-throw dedup, string-model decision before RegExp Unicode) |
| [register-locals.md](register-locals.md) | ✅ DONE | Register-resident locals optimization; validated by the ENV_STRICT oracle (`duktape_c3_envstrict` target + corpus). Known gap: captured-local coherence — see plan 045 |
| [026-rosetta-remaining-failures.md](026-rosetta-remaining-failures.md) | ✅ DONE | Rosetta suite at 100/100 since session 248 (B24–B30 closed) |

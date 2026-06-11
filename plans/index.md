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
| [011-memory-optimization.md](011-memory-optimization.md) | 🔶 STALLED | Register pressure (8-bit field truncation); fix attempted but regressed tests |
| [012-speed-optimization.md](012-speed-optimization.md) | ✅ DONE | All items completed across Sessions 114–123 |
| [013-speed-optimization-2.md](013-speed-optimization-2.md) | ✅ DONE | All items done: RC, RET restart, valstack_top cache |
| [014-test262-review.md](014-test262-review.md) | ✅ DONE | Status snapshot; remaining gaps tracked in progress.md |
| [018-rebase-rc-on-delta-shapes.md](018-rebase-rc-on-delta-shapes.md) | ✅ DONE | String RC rebased on delta shapes (Session 146) |
| [019-shape-optimize-bench.md](019-shape-optimize-bench.md) | ✅ DONE | bench_shape 73×→0.8× (Session 147) |
| [020-fable-review.md](020-fable-review.md) | ✅ DONE | All 8 items complete per plan 021 status table |
| [021-struct-cleanup.md](021-struct-cleanup.md) | ✅ DONE | Items B (CallableKind→accessor) & C (PropHashInfo side struct) complete |
| [022-property-descriptor-correctness.md](022-property-descriptor-correctness.md) | 📋 PENDING | Property descriptor fixes for 2,000–4,000 new passes |
| [024-fused-opcodes.md](024-fused-opcodes.md) | ✅ DONE | GETPROPC + compare-and-branch fused opcodes; peephole passes; rotated loops (Session 148–149) |
| 025-callback-error-propagation | ✅ DONE | vm_call_fn_impl Case 3 fix; arr_call_callback error handling; find/findIndex native builtins; print toString (Session 149) |

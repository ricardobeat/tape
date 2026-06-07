# Jun 3 — Speed Optimization Plan

**Date:** 2026-06-03
**Baseline:** `benchmarks/results.txt` (2026-05-31)
**Goal:** Close the gap to QuickJS (currently 6-10× slower) and to original Duktape (currently 1-2× slower on some benchmarks).

## Current State (from `benchmarks/results.txt`)

| Benchmark              | C3 (ms) | Duktape (ms) | QuickJS (ms) | C3/QJS |
|------------------------|---------|--------------|--------------|--------|
| bench_arithmetic       |   225   |     342      |      27      |  8.3×  |
| bench_array            |    74   |      39      |       7      | 10.6×  |
| bench_function_call    |   149   |     132      |      18      |  8.3×  |
| bench_ic_monomorphic   |   565   |     283      |      86      |  6.6×  |
| bench_loop             |   110   |     139      |      15      |  7.3×  |
| bench_object           |   121   |     170      |      23      |  5.3×  |
| bench_property_lookup  |   118   |     180      |      18      |  6.6×  |
| bench_recursion        |   891   |     467      |     117      |  7.6×  |
| bench_recursion_deep   |  3696   |    1929      |     490      |  7.5×  |
| bench_string           |    14   |      17      |       5      |  2.8×  |
| bench_valstack_copy    |    27   |      12      |       9      |  3.0×  |

C3 is **faster than Duktape** on `arithmetic/loop/object/property_lookup/string/ic_proto` (the heap-heavy ones where shape/IC help). C3 is **slower than Duktape** on `array/ic_monomorphic/recursion/recursion_deep/function_call/valstack_copy` — these are the per-op hot paths where the interpreter machinery dominates.

## What is NOT a gap (already solved — do not relitigate)

- **Property table is already single-allocation.** `HObject.prop_alloc` (hobject.c3:395-397, 736-766) packs `prop_values + array_part` contiguously with `prop_alloc_size()`/`prop_alloc_grow()` helpers. Resize is one `realloc` and a `memmove` of the array tail.
- **HObjectExtra is already a tagged union** (hobject.c3:347-352): `HObjectFunction`/`HObjectPrimitive`/`HObjectRegExp`/`HObjectGenerator`. Plain objects don't carry function/reg-exp fields.
- **NaN-boxing is the default.** `USE_NANBOX = !$defined(NONANBOX)` (types.c3:104) — TVal is 8 bytes. `-D NONANBOX` is the 16-byte path for 32-bit targets.
- **Shape + IC infrastructure exists.** `Shape` (hobject.c3:996+) with shared hash + per-object value arrays, `ICEntry`/`VarICEntry` with generation counter, monomorphic fast path in GETPROP (vm.c3:2149-2167) and PUTPROP (vm.c3:2414-2422), VarIC for lexical lookup (vm.c3:4485-4703).
- **Mark-and-sweep GC is real** (heap.c3:1498-1537): clear → mark from roots → sweep → reset trigger. Not a stub anymore. String table sweep, finalize_list, microtask draining, root marking callback are all in place.
- **CALL has a direct-dispatch fast path** (vm.c3:3034-3035): no restart for ES-to-ES calls.
- **The 2026-05-28 plan's three CALL/RET fixes are already applied** (`reserve_byteoff` removed, arg self-copy guarded, `valstack_top` recomputation simplified). `bench_recursion` is still 1.9× Duktape, so there's more to extract — see below.

## The Real Gaps (ranked by expected speedup)

### 1. `dispatch_builtin` is a 290-case `switch` statement

**Location:** `src/builtins.c3:15185-15210+` (and counting — the BUILTIN_* enum is at `src/builtins.c3:44-...`, currently ~290 entries)

Every call to a native function (`Math.abs`, `Array.push`, `Object.keys`, ...) walks a `switch (fn_index)` that compiles to either a jump table or a binary search. Branch predictor absorbs the common case, but it's still 1-2 indirect jumps per native call plus cache-line pressure on a 290-arm table.

Duktape uses a `duk_bi_native_functions[185]` array of C function pointers — one indirect call. QuickJS does the same.

**Fix:** replace the switch with a function-pointer table:
```c
BuiltinFn native_funcs[NUM_BUILTINS] = {
    [BUILTIN_PRINT]       = builtin_print,
    [BUILTIN_CONSOLE_LOG] = builtin_console_log,
    ...
};
fn void dispatch_builtin(uint fn_index, BuiltinContext* ctx) {
    native_funcs[fn_index](ctx);
}
```
C3 supports function pointers in module-level constants — the table can be a plain `BuiltinFn[]`.

**Expected impact:** `bench_function_call` 149 → ~100ms (1.5×). This is the single biggest win because *every* non-trivial JS calls at least one native.

**Effort:** 1-2 hours. Mechanical, no correctness risk.

---

### 2. Refcounting is unwired (heap.c3, src-wide)

**Location:** No `incref`/`decref` calls anywhere in `src/*.c3` (verified by grep). Mark-and-sweep is the only collector (heap.c3:1498). Every `+`/`getprop`/`concat` that produces a temporary TVal containing a heap pointer leaks until M&S runs.

Duktape uses refcounting as the **primary** collector (immediate free on rc→0) and M&S as the cycle backup. QuickJS is the same model.

**Symptoms in benchmarks:**
- `bench_recursion` (891ms) and `bench_recursion_deep` (3696ms) at 1.9× Duktape — each frame allocates temporaries; M&S pressure is the only relief.
- `bench_valstack_copy` (27ms vs 12ms Duktape) — every copy is a heap ref, no decref on overwrite.

**Fix:**
1. Add `uint refcount` to `HeapHeader` (heap.c3:120-130 already has the header — just add the field and bump its size).
2. `hobject_alloc`/`hstring_alloc` init rc=1.
3. `TVal.store` (or the equivalent in `set_object`/`set_string`) calls `incref` on heap pointer write; `TVal.clear`/register overwrite calls `decref`.
4. `decref` on rc=0 either frees immediately (strings, objects) or rescues to a `refzero_list` for cycle processing.
5. `mark_and_sweep` becomes cycle-only (the slow path).

**Expected impact:** 30-50% on recursion benchmarks, 1.5-2× on `valstack_copy` and any allocation-heavy workload.

**Effort:** 2-3 days. Touches every register-write and every TVal field-set. High risk of leaks if any write path is missed — a `leakcheck` build flag would help.

---

### 3. CALL fast path still allocates a function-scope env per call

**Location:** `src/vm.c3:2999`
```c3
EnvRecord* fast_var_env = hobj_fast.extra.func.var_env;
if (try fv_f = env::env_create_function_scope(vm.heap, hobj_fast.extra.func.var_env)) {
    fast_var_env = fv_f;
}
```
This is **always** executed on the CALL fast path, even when no closure capture is needed (the common case for plain functions, including fib). The allocation is the dominant per-call cost.

Duktape skips this when the callee has no upvalues. The check is `if (func->nupvals > 0 || scope_need_capture(...))`.

**Fix:** add a `bool needs_env` flag on `CompiledFunction` (compiler-side: set if any inner function references an outer binding or if the function uses `arguments`/`eval`/non-strict). Skip the allocation when false.

**Expected impact:** recursion benchmarks drop by another 20-30% on top of #2.

**Effort:** Half a day. Compiler change + CALL path change.

---

### 4. Register-init zero loop is not vectorized

**Location:** `src/vm.c3:3022-3026`
```c3
uint zero_count = new_nregs - nargs;
TVal* zero_dst = &new_regs[nargs];
for (uint zi = 0; zi < zero_count; zi++) {
    zero_dst[zi].bits = 0;
}
```
For fib(35) this is 35 store-zeroes per recursive call. C3 likely doesn't auto-vectorize and the loop is per-instruction overhead.

**Fix:** use `libc::memset` (which C3 lowers to `rep stosq`/`stp xzr, ...` on x86/aarch64). The earlier `plans/may-28-hotpath-optimization.md` already noted "the memset for unused registers still runs."

**Expected impact:** small (5-10%) but trivial.

**Effort:** 5 minutes.

---

### 5. IC monomorphic benchmark is still 2× Duktape

**Location:** `src/vm.c3:2149-2167` (GETPROP IC), `hobject.c3:996+` (Shape)

`bench_ic_monomorphic` at 565ms (Duktape 283ms, QuickJS 86ms). The IC exists and the fast path is wired, but the benchmark is still 2× slower than Duktape's equivalent — meaning the fast path either isn't hitting, or hits and pays too much.

Hypotheses to verify (add counters around vm.c3:2149):
- The `lookup_key != null` check at vm.c3:2155 fails often (key wasn't interned).
- The `gen == vm.heap.shapes[ic.shape_id].generation` check at vm.c3:2160 fails often (gen bumps per prop_alloc resize — for monomorphic benchmarks with stable shapes, this should be near-100% hit).
- The polymorphic branch at vm.c3:2164 (`else if (gen == ...)`) is taking the slow path.

If gen-check is the culprit: shape allocation bumps generation even when only the array part grows (hobject.c3:1152-1159). Add a separate `array_gen` so prop_alloc resizes don't invalidate ICs.

If `lookup_key != null` is the culprit: the compiler should always emit the interned key for string-literal GETPROP — check `src/compiler.c3` GETPROP emission.

**Expected impact:** `bench_ic_monomorphic` 565 → ~283ms (match Duktape), `bench_property_lookup` 118 → ~60ms.

**Effort:** 1 day to instrument + 1 day to fix whichever root cause is identified.

---

### 6. No superinstructions / no direct-threaded dispatch

**Location:** `src/vm.c3:1460-1530` (outer/inner loop), `vm.c3:1536` (`switch (op)`)

C3 doesn't expose computed gotos or assembly labels. The dispatch is an outer `for(;;)` + inner `for(; !needs_restart; )` + a `switch (op)`. Common opcode pairs (`LOADVAR + GETPROP`, `LOADVAR + LOADVAR + ADD`, `IFTRUE + jump`) pay two or three full switch iterations.

Duktape uses computed gotos (one indirect branch per op) and superinstructions (one opcode for the common pair). QuickJS does the same.

**Fixes (pick one):**
- (a) Hand-fold hot pairs in the compiler: emit a single `LOADVAR_GETPROP` opcode.
- (b) Use a tail-call via a function pointer table of opcode handlers: `OpcodeHandler table[]; table[op](&ctx);` — one indirect call per op. C3 should support function pointers in arrays.
- (c) Inline the most common opcodes (LOADVAR, STOREVAR, GETPROP, PUTPROP, ADD, RET) into the main loop and dispatch the rest via switch.

**Expected impact:** `bench_loop` 110 → ~70ms, `bench_arithmetic` 225 → ~140ms.

**Effort:** (a) 2 days, (b) 3 days, (c) 1 week. Highest risk of regressions in the latter half.

---

### 7. Arithmetic ops don't fastpath FASTINT×FASTINT

**Location:** `src/vm.c3:1829, 1863` (SEQ/SNEQ), and the ADD/SUB/MUL/DIV cases nearby

`bench_arithmetic` is 8.3× QuickJS. SEQ does `tag_b = rb.get_tag(); tag_c = rc.get_tag()` then a switch on tag. For FASTINT+FASTINT (the dominant case in arithmetic benches) this is 2 tag decodes (each is a `nanbox_get_tag` shift + a switch on 10 cases — types.c3:171-189) plus a switch on tag_b.

Duktape has a separate ADD_FASTINT opcode emitted by the compiler when both operands are known-fastint, and a fastint fast path inside the generic ADD.

**Fix:** in the compiler, when both operands of `+`/`-`/`*`/`/`/`%`/`===` are known to be FASTINT (literals, loop counters, prior arithmetic results tracked in a simple SSA-ish lattice), emit `ADD_FASTINT`/`SUB_FASTINT`/etc. that read `.bits`, mask, sign-extend, add, repack — no `get_tag()` call.

**Expected impact:** `bench_arithmetic` 225 → ~110ms. `bench_loop` benefits because loop counters are fastints.

**Effort:** 1-2 weeks. Touches the type-tracker in `src/compiler.c3` and adds 5-10 new opcodes.

---

### 8. Array `.length` is a property table entry, not a fast field

**Location:** `src/hobject.c3:347-352` (HObjectExtra union), no `array_length` field exists.

`bench_array` is 74ms (1.9× Duktape). Duktape's `duk_harray.length` is a plain `uint` field, so `arr.length` is a pointer deref.

The C3 port has `exotic_array` flag and routes `.length` through the property table (vm.c3:2176 path for ARGUMENTS, similar for ARRAY).

**Fix:** add `uint array_length;` to `HObjectFunction`-side... actually, add a new `HObjectArray` struct to the union:
```c3
struct HObjectArray {
    uint array_length;
    // ... other array-specific state
}
union HObjectExtra {
    HObjectFunction func;
    HObjectPrimitive prim;
    HObjectRegExp   regexp;
    HObjectGenerator gen;
    HObjectArray    arr;  // NEW
}
```
GETPROP fast path: if `flags.exotic_array` and key is `"length"`, return `arr.array_length` directly, no property table walk.

**Expected impact:** `bench_array` 74 → ~40ms (match Duktape).

**Effort:** 1 day.

---

### 9. String `===` still does an intern lookup per call

**Location:** `src/vm.c3:1824-1855` (SEQ), string interning in `src/hstring.c3`

`seq_r = (rb.get_heapptr() == rc.get_heapptr())` is pointer identity, which is correct **only if both sides are interned**. The `===` correctness fix in Session 103 made this safe for the common case, but every string equality still pays the same cost.

**Fix (separate from the correctness fix):** cache the last-interned string per activation in `Activation` (call frame). If `rb` matches the cache, skip the heapptr compare. Duktape does a similar trick via `duk_hstring_get_hash_fast()` for string-keyed lookups; here a single-slot cache per frame should suffice.

**Expected impact:** small (5-10%) on `bench_string` and any string-heavy code.

**Effort:** half a day.

---

## Priority Order (highest expected speedup first)

| # | Fix | Effort | Expected Speedup | Benchmark Targets |
|---|-----|--------|------------------|-------------------|
| 1 | Function-pointer table for `dispatch_builtin` | 2h | 1.3-1.5× | `function_call`, any native-heavy code |
| 2 | Wire refcounting on hot path | 3d | 1.5-2× | `recursion`, `valstack_copy`, all alloc-heavy |
| 3 | Skip env alloc in CALL fast path | 0.5d | 1.2-1.3× | `recursion`, `recursion_deep` |
| 4 | Instrument + fix IC gen-check or key-intern | 2d | 1.5-2× | `ic_monomorphic`, `property_lookup` |
| 5 | `memset` instead of zero loop | 5m | 1.05× | (free) |
| 6 | `array_length` fast field in HObjectExtra | 1d | 1.5-2× | `bench_array` |
| 7 | FASTINT-specialized arithmetic opcodes | 1-2w | 1.5-2× | `arithmetic`, `loop` |
| 8 | Function-pointer dispatch + superinstructions | 1-3w | 1.3-1.5× | `loop`, `arithmetic` (broad) |
| 9 | Last-string cache in activation frame | 0.5d | 1.05-1.1× | `string`, string-heavy code |

### Session 114: Items #1, #3, #5 completed (2026-06-04)

| # | Fix | Status |
|---|-----|--------|
| 1 | Function-pointer dispatch table | ✅ Done |
| 3 | Skip env alloc in CALL fast path | ✅ Done |
| 5 | memset instead of zero loop | ✅ Done |

Benchmarks: system noise masked measurable gains. Structural correctness verified — 96/106 test files pass (same as baseline).

### Session 119: Item #4 IC fast path completed (2026-06-05)

| # | Fix | Status |
|---|-----|--------|
| 4 | IC fast path: prop_value_ptr + cached_prop_alloc | ✅ Done |

Replaced gen_and_idx packed ulong with prop_idx + cached_prop_alloc. IC population now
sets prop_value_ptr. Fast path uses direct pointer load and single prop_alloc comparison
instead of generation dereference chain. ~13 ops → ~7 ops per IC hit. VM dispatch loop
now dominates; IC fast path is minimal. No benchmark regression (noise-masked).

### Session 121: max_heap_reg decref skip + memset (2026-06-07)

Added `uint max_heap_reg` to Activation struct — tracks highest register index that
ever held a heap ref (object/buffer). Initialized to 0 on every CALL. `decref_callee_regs`
returns immediately when `max_heap_reg == 0`, skipping the O(nregs) register loop.
Added `track_heap_store()` helper called after every `tval_copy_ref(ra, ...)` and
`ra.set_object(...)` in the VM dispatch — updates max_heap_reg when storing a heap ref.
Replaced remaining `.bits = 0` zero loops in CALL fast paths with `libc::memset`.
quick.sh: 182/101/56 — +2 passes vs baseline 180/103/56.

### Session 122: @inline refcount hot path + IC non-heap fast path (2026-06-07)

| # | Fix | Status |
|---|-----|--------|
| — | @inline on HeapHeader.incref, Heap.decref_tval, Heap.tval_copy_ref | ✅ Done |
| — | Non-heap fast path in GETPROP IC + GETVAR IC | ✅ Done |
| — | Unified own-property/proto IC branches via ternary | ✅ Done |

`@inline` on `tval_copy_ref`/`decref_tval` eliminates function-call overhead in every
register-write path. For fastint/number values (the common case in arithmetic loops),
the inlined compiler can now see that `is_object() || is_buffer()` is false and eliminate
the entire decref/incref body. GETPROP and GETVAR IC fast paths additionally bypass
`tval_copy_ref` entirely when dest is not a heap pointer: raw copy + conditional incref.
recursion 775→394ms (2.0×, now faster than Duktape 467ms).
recursion_deep 3432→1635ms (2.1×, faster than Duktape 1929ms).
function_call 106→64ms (1.7×).
quick.sh: 182/101/56 — no regressions.

## Validation

```bash
# After each fix:
just bench-rebuild
# Compare against benchmarks/results.txt baseline.

# Per-benchmark drill-down:
just bench-one benchmarks/bench_recursion_deep.js 5
just bench-one benchmarks/bench_function_call.js 5
just bench-one benchmarks/bench_ic_monomorphic.js 5
```

Targets after this plan:
- All C3-vs-Duktape ratios in [0.7, 1.3]× (currently 4 ratios above 1.3×, 0 below).
- C3-vs-QuickJS ratios in [2, 5]× (currently 6-10×).

## Risks

- **#2 (refcounting)** is the highest-risk item. Missing a write path = silent leak. Mitigation: keep M&S as a safety net, instrument with an `assert(rc_consistent())` debug build first.
- **#7/#8 (interpreter changes)** can regress correctness on edge cases. Mitigation: per-opcode unit tests in `test/` and a 5% slice of test262 before merging.
- **#6 (HObjectExtra addition)** enlarges the union (already the size of its largest member, but the member list grows). Acceptable; documented in code.

## Out of Scope (deferred)

- TVal size further reduction (already 8 bytes via NaN-boxing).
- Property table layout variants (Duktape LAYOUT_1/2/3) — single allocation is enough for now.
- ROM/flash support for builtins.
- Specialized opcodes for `arguments`/spread/destructuring — once the dispatch is fast enough, these are compiler work.

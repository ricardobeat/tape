# Plan: Fix TVal @inline Failure — Convert to Macros

## Problem

c3c's `@inline` annotation on TVal struct methods is **not being honored** in the VM dispatch loop. Every `is_fastint()`, `get_fastint()`, `set_fastint()`, `is_number()`, etc. is compiled as a standalone function and called with `bl`, NOT inlined. This is the primary cause of the NaN-boxing performance regression.

## Verification Tests

Four test files at `/tmp/test_*.c3` confirm the issue definitively:

### Test 1: Small caller (8-case switch) — `@inline fn` WORKS

`/tmp/test_inline.c3` — `fn ... @inline` methods called from a small `vm_execute_inline`.

**Result**: 0 `bl` calls. `@inline` is honored when the caller is small.

### Test 2: Small caller (8-case switch) — `macro` WORKS

`/tmp/test_macro.c3` — `macro` methods called from `vm_execute_macro`.

**Result**: 0 `bl` calls. Macros always inline. No standalone symbols emitted.

### Test 3: Small caller — `@inline` on call sites

`/tmp/test_inline_call.c3` — `fn ... @inline` methods with `@inline` on each call site.

**Result**: 0 `bl` calls (same as test 1 — already inline in small callers).

### Test 4: Large caller (32-case switch) — THE SMOKING GUN

`/tmp/test_large.c3` and `/tmp/test_large_macro.c3` — identical 32-case VM dispatch loop, one using `fn ... @inline`, the other using `macro`.

**Symbol table comparison:**

| Variant | TVal method symbols | VM function symbols |
|---------|--------------------|--------------------|
| `fn @inline` | **16 standalone functions** | 1 (`vm_execute_large`) |
| `macro` | **0** | 1 (`vm_execute_large`) |

**`bl` call count inside vm_execute_large:**

| Variant | `bl` instructions |
|---------|------------------|
| `fn @inline` | **414** |
| `macro` | **0** |

**Instruction count:**

| Variant | Instructions | Δ |
|---------|-------------|---|
| `fn @inline` | ~13,760 | baseline |
| `macro` | ~8,192 | **-40%** |

### Confirmation in actual bench_run binary

**597 `bl` calls to TVal methods** inside `Vm.execute` (37.8 KB / 9,677 instructions):

| Method | bl calls |
|--------|---------|
| `is_fastint` | 90 |
| `get_heapptr` | 75 |
| `get_fastint` | 74 |
| `get_number` | 62 |
| `set_undefined` | 48 |
| `set_object` | 40 |
| `set_boolean` | 33 |
| `is_string` | 32 |
| `set_string` | 31 |
| `is_object` | 28 |
| `set_fastint` | 16 |
| `is_number` | 12 |
| `get_tag` | 12 |
| `get_boolean` | 11 |
| `set_number` | 7 |
| `is_null` | 7 |
| `is_undefined` | 6 |
| `set_null` | 5 |
| `is_boolean` | 4 |
| `is_lightfunc` | 3 |
| `set_pointer` | 1 |

Each `bl` adds ~3-5 instructions of overhead (arg setup + `bl` + `ret` + register save/restore).

## Root Cause

**c3c does not inline `@inline fn` methods into large caller functions.** The threshold appears to be around ~500-1000 instructions. `Vm.execute` at 9,677 instructions is far beyond this threshold. The standalone function symbols are still emitted (global linkage), and all call sites use `bl`.

This is a **c3c compiler limitation**, not a source code issue. The `@inline` attribute is documented as "Declares a function to always be inlined" but this guarantee is not honored for large callers.

`macro` methods are expanded at the AST level before codegen, so they bypass the LLVM inliner entirely and are always inlined regardless of caller size.

## Solution

Convert all TVal methods from `fn ... @inline` to `macro` equivalents. The conversion is mechanical:

```c3
// BEFORE (not inlined in large callers):
fn bool TVal.is_fastint(&self) @inline {
    return (self.bits >> 48) == TAG_FASTINT;
}

// AFTER (always inlined):
macro bool TVal.is_fastint(&self) {
    return (self.bits >> 48) == TAG_FASTINT;
}
```

The `$if USE_NANBOX:` conditional compilation inside macro bodies works identically.

### Methods to convert (all in `src/types.c3`)

**Helper functions** (lines 124-140):
- `nanbox_encode_tagged` — fn @inline → macro
- `nanbox_is_double` — fn @inline → macro
- `nanbox_get_tag` — fn @inline → macro
- `nanbox_get_payload` — fn @inline → macro

**TVal methods** (lines 165-557):
- `get_tag`, `is_undefined`, `is_null`, `is_boolean`, `is_number`, `is_fastint`, `is_string`, `is_object`, `is_buffer`, `is_pointer`, `is_lightfunc`, `is_nullish`, `is_numeric`, `is_heap_allocated`
- `get_boolean`, `get_fastint`, `get_number`, `get_heapptr`
- `set_undefined`, `set_null`, `set_boolean`, `set_number`, `set_fastint`, `set_nan`, `set_string`, `set_object`, `set_pointer`, `set_lightfunc`

**Estimated impact**: Eliminating 597 function calls in the hot path should recover most of the NaN-boxing regression.

## Verification

1. Build: `c3c build bench_run`
2. Confirm no standalone TVal symbols: `nm out/bench_run | grep "TVal.is_fastint"`
3. Confirm 0 bl calls to TVal in Vm.execute disassembly
4. Benchmark: `just bench-one benchmarks/bench_arithmetic.js 5` (expect biggest improvement)
5. Full suite for regressions

## Fallback

If macro conversion causes issues:
- File c3c issue about `@inline` not working in large functions
- Use `@inline` on call sites (`regs[0].is_fastint() @inline`) — untested at large scale
- Rewrite TVal access as inline bit manipulation directly in vm.c3

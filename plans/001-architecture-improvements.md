# Recursion Gap Closure Plan — NaN-Boxing

**Date:** 2026-05-28
**Target:** Close the 1.4x recursion benchmark gap (634ms vs 453ms, C3 port vs Duktape v2.7.0)
**Approach:** Replace 16-byte explicit-tag TVal with 8-byte IEEE 754 NaN-boxed representation

---

## Root Cause Analysis

The recursion benchmark (Fibonacci 32) is 1.4x slower due to two architectural factors:

### Factor 1 — TVal size: 16 bytes vs 8 bytes

| | C3 Port | Duktape |
|---|---|---|
| Representation | `TValTag` (1 byte) + 7 bytes padding + union (8 bytes) = **16 bytes** | NaN-boxed into single IEEE 754 `double` = **8 bytes** |
| Value stack memory per frame | `num_regs * 16` bytes | `num_regs * 8` bytes |
| Cache lines per 4-reg frame | 1 cache line (64B fits 4 TVal) | 1 cache line (64B fits 8 TVal) |

Fibonacci(32) creates ~3.5M call frames. Each frame copies args (16 bytes each vs 8), stores locals (same), returns values (same). The 2x memory footprint directly translates to 2x cache pressure on the deepest recursion paths.

### Factor 2 — "Register-binding fast path" (CPU register pressure, not JS registers)

Duktape's VM hoists ~6 pointers into CPU registers before the dispatch loop: `thr`, `act`, `curr_pc`, `regs_base`, `constants`, `code_end`. With 8-byte TVal, the compiler can keep all of these + dispatch temporaries in physical registers without spilling. With 16-byte TVal, every `TVal*` dereference loads a 16-byte struct into a register pair, causing more spill/fill around the dispatch switch.

The C3 port already does the same hoisting (vm.c3:1086-1096), direct call/return dispatch (vm.c3:2750, 3590), and register-cached locals via `LDREG`. The gap is not about missing optimizations — it's about the **data width**.

---

## C3 Language Feasibility

All required features are available:

| Feature | Available | Where |
|---|---|---|
| `bitcast(double <-> ulong)` | Yes | stdlib builtin |
| `union` type punning | Yes | Already used in TVal |
| `bitstruct` on `ulong` | Yes | Used in 5+ places (bytecode.c3, hobject.c3) |
| `$if env::BIG_ENDIAN:` | Yes | Compile-time platform dispatch |
| `@inline` | Yes | 51 uses in codebase |
| `typedef TVal = ulong` | Yes | Distinct type alias |

---

## Implementation Plan

### Phase 0: Preparation (1 session)

**Goal**: Benchmark harness + safety net before touching anything.

- [ ] Create a `bench_recursion_deep.js` (Fibonacci 35) to stress deeper call stacks
- [ ] Create a `bench_valstack_copy.js` — micro-benchmark that only measures TVal copy throughput
- [ ] Record baseline numbers for all 9 benchmarks
- [ ] Ensure test262 suite passes cleanly (establish green baseline)
- [ ] Create a git branch `feat/nanboxing`

### Phase 1: Core TVal restructure (3-5 sessions)

**The big change.** Replace the 16-byte tagged union with an 8-byte NaN-boxed `ulong`.

#### 1.1 — New TVal type definition (`src/types.c3`)

```c3
// Current: 16-byte struct with explicit tag + union
struct TVal { TValTag tag; union { bool; double; long; void*; } }

// New: 8-byte NaN-boxed representation
// TVal becomes a typedef over ulong
typedef TVal = ulong;
```

NaN-boxing layout (IEEE 754 doubles):
- If high 13 bits != `0x7FF0` -> it's a plain `double`, no tag needed
- If high 13 bits == `0x7FF0` (NaN space) -> it's a tagged value:
  - Bits 62-52: tag discriminator (type + flags)
  - Bits 51-0: payload (pointer, integer, boolean, etc.)

Specific tag encoding:

```
0xFFF8000000000000 + (tag << 48) | payload
```

Tags (fitting in the NaN payload space):

| Value | Type | Payload |
|-------|------|---------|
| 0 | undefined | (none) |
| 1 | null | (none) |
| 2 | boolean | 0 or 1 |
| 3 | fastint | 52-bit signed integer |
| 4 | string pointer | heap pointer |
| 5 | object pointer | heap pointer |
| 6 | buffer pointer | heap pointer |
| 7 | pointer | raw pointer |
| 8 | lightfunc | C function pointer |

#### 1.2 — Encode/decode functions (`src/types.c3`)

```c3
fn ulong nanbox_encode_double(double d) @inline
    // Plain doubles pass through unchanged (bitcast)
fn ulong nanbox_encode_tagged(ulong tag, ulong payload) @inline
    // Pack into NaN space: 0xFFF8000000000000 | (tag << 48) | payload
fn bool nanbox_is_double(ulong v) @inline
    // Check high 13 bits != 0x7FF0
fn ulong nanbox_get_tag(ulong v) @inline
    // Extract bits 55-48 (or wherever the tag lives)
fn ulong nanbox_get_payload(ulong v) @inline
    // Mask out the tag bits, get 48-bit payload
```

The existing `make_number()`, `make_object()`, etc. get rewritten to call these.

#### 1.3 — Type checking functions

```c3
fn bool TVal.is_number(&self) @inline
    return nanbox_is_double(*self);  // fast: one comparison on high bits
fn bool TVal.is_object(&self) @inline
    return nanbox_get_tag(*self) == TAG_OBJECT;
fn bool TVal.is_numeric(&self) @inline
    return nanbox_is_double(*self) || nanbox_get_tag(*self) == TAG_FASTINT;
```

#### 1.4 — Payload access

```c3
fn double TVal.get_number(&self) @inline
    return bitcast(*self, double);  // direct reinterpret
fn void* TVal.get_heapptr(&self) @inline
    return (void*)nanbox_get_payload(*self);
fn void TVal.set_number(&self, double d) @inline
    *self = bitcast(d, ulong);  // direct reinterpret
fn void TVal.set_object(&self, void* ptr) @inline
    *self = nanbox_encode_tagged(TAG_OBJECT, (usz)ptr);
```

#### 1.5 — FASTINT handling

FASTINTs are special: they're tagged values (NaN-boxed) but represent integers in the 52-bit range. The existing FASTINT fast path in arithmetic opcodes (vm.c3:1200-1206) continues to work, just with the new encoding:

```c3
fn bool TVal.is_fastint(&self) @inline
    return nanbox_get_tag(*self) == TAG_FASTINT;
fn long TVal.get_fastint(&self) @inline
    // Sign-extend from 52-bit payload
```

#### 1.6 — Platform guards

```c3
$if env::ARCH_64_BIT && !env::BIG_ENDIAN:
    // NaN-boxing implementation (64-bit little-endian)
$else
    // Keep 16-byte tagged union fallback for 32-bit or big-endian
    struct TVal { TValTag tag; union { ... } }
$endif
```

#### 1.7 — Migration shim

During migration, provide both representations with a compile-time flag:

```c3
const bool USE_NANBOX = true;  // toggle for A/B testing
```

This allows incremental migration: compile with `USE_NANBOX=false` to verify behavior, then flip to `true`.

### Phase 2: VM adaptation (2-3 sessions)

The VM is the most impacted consumer of TVal. Every opcode handler reads/writes TVal values.

#### 2.1 — Value stack arithmetic

Current: `TVal::size = 16`, byte offset math throughout vm.c3.
New: `TVal::size = 8` (or just `sizeof(ulong)` = 8).

Changes in vm.c3:
- `ptr_from_byteoff` — no change (pointer arithmetic, just the stride halves)
- `byte_offset` — no change
- `ensure_valstack()` — allocation size halves
- All `TVal::size` references — automatic (it's now 8)
- `memset` of register slots — still correct (zeroing 8-byte slots)

**Estimated: ~5 touch points, mechanical.**

#### 2.2 — Opcode handlers

Every `case Opcode.XXX:` that reads/writes TVal must be updated. The good news: most already use the `TVal` struct methods (`.tag`, `.set_number()`, etc.), so if those methods are updated in Phase 1, the VM handlers mostly work unchanged.

**Key hot-path handlers to audit** (these are the ones that matter for recursion):

| Handler | File:Line | What to check |
|---------|-----------|---------------|
| `LDREG` | vm.c3:1125 | `*ra = *rb` — now copies 8 bytes instead of 16. Automatic. |
| `LDINT` | vm.c3:1130 | `make_fastint()` — must use new NaN-box encoding |
| `ADD` | vm.c3:1196 | FASTINT fast path — tag check changes |
| `CALL` | vm.c3:2273 | Frame setup, arg copy, `memset` of registers |
| `RETURN` | vm.c3:3586 | Return value copy, frame teardown |
| `GETVAR` | vm.c3:3654 | Environment chain lookup — result stored in 8-byte TVal |
| `PUTVAR` | vm.c3:3813 | Environment chain write — value is now 8-byte |
| `LDNULL`, `LDUNDEF`, `LDBOOL` | vm.c3:1138-1149 | Use new tag encoding |

**Estimated: ~30-40 handler touchpoints, mostly mechanical (replace `make_X()` / `.tag` / `.X` field access).**

#### 2.3 — Direct call/return dispatch

The direct dispatch path (vm.c3:2750-2760 for calls, 3586-3600 for returns) reloads `regs_base` from `act.bottom_byteoff`. Since `TVal` is now 8 bytes, the byte offsets halve but the logic is identical. No structural change needed.

#### 2.4 — `handle_return()` (vm.c3:910)

Return value handling: `vm.valstack[retval_byteoff] = *ra` — now an 8-byte copy. Automatic.

### Phase 3: Compiler adaptation (1 session)

#### 3.1 — Constant emission

The compiler emits constants into `CompiledFunction.constants[]` (a `TVal[]` array). Each constant is now 8 bytes. The array allocation and access patterns are unchanged.

#### 3.2 — No structural changes needed

The compiler doesn't care about TVal's internal representation — it calls `make_number()`, `make_string()`, etc. If those functions are updated in Phase 1, the compiler works unchanged.

**Estimated: ~0-5 touchpoints.**

### Phase 4: Heap / GC adaptation (1-2 sessions)

#### 4.1 — Mark phase

The GC mark phase iterates TVal arrays and extracts heap pointers. Currently at heap.c3:538-548:

```c3
if (v.is_object()) {
    HObject* obj = (HObject*)v.get_heapptr();
```

With NaN-boxing, `get_heapptr()` extracts the 48-bit payload. Functionally identical.

#### 4.2 — Property table TVal storage

`props[]`, `array_part[]` are `TVal[]` arrays. With 8-byte TVal, these arrays are 2x denser — **direct cache locality improvement** for property access. This may improve the `object` and `property_lookup` benchmarks too.

#### 4.3 — String intern table

The string intern table stores TVal entries. Same treatment.

### Phase 5: Builtins adaptation (1-2 sessions)

#### 5.1 — Builtin function argument handling

Builtins receive args from the value stack. With 8-byte TVal, all arg reads change. The builtin dispatch (vm.c3:2296-2432) builds a `BuiltinContext` — the TVal copies within it become 8-byte.

#### 5.2 — Property descriptor TVal fields

Property descriptors use TVal for `.value`. Same treatment.

**Estimated: ~50-100 touchpoints across builtins.c3, mostly mechanical.**

### Phase 6: Validation & benchmarking (1-2 sessions)

#### 6.1 — Full test262 regression

Run the complete test262 suite. Every test must pass. NaN-boxing introduces new failure modes:
- Type discrimination bugs (wrong tag check -> misinterpreting a pointer as a double)
- Sign extension errors on FASTINT payload
- Endianness issues (if porting to big-endian later)

#### 6.2 — Recursion benchmark

```
just bench-one bench_recursion.js 5
```

Target: <= 453ms (parity with Duktape), ideally < 400ms (faster due to other C3 advantages).

#### 6.3 — All benchmarks

Run all 8 benchmarks. Expected results:

| Benchmark | Current | Projected |
|-----------|---------|-----------|
| recursion | 634ms (1.4x) | ~400-450ms (0.9x) |
| function_call | 102ms (0.8x) | ~80-90ms (0.7x) |
| arithmetic | 189ms (0.6x) | ~189ms (0.6x) — unchanged |
| object | 87ms (0.5x) | ~70-80ms (0.4x) |
| property_lookup | 93ms (0.5x) | ~70-80ms (0.4x) |
| array | 29ms (0.9x) | ~25ms (0.8x) |
| loop | 91ms (0.7x) | ~91ms (0.7x) — unchanged |
| string | 10ms (1.0x) | ~10ms (1.0x) — unchanged |

#### 6.4 — Edge cases to test

- `Number.MAX_SAFE_INTEGER` (2^53 - 1) — FASTINT boundary
- `NaN`, `Infinity`, `-0` — special doubles
- Deep recursion (> 10,000 frames) — stack overflow behavior
- `typeof` on every type — tag discrimination
- Property access on arrays with > 1000 elements — array part density
- GC under memory pressure — heap pointer extraction correctness

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Type tag collision (pointer misread as double) | Low | High | Exhaustive tag+payload tests; $if guards for 32-bit fallback |
| FASTINT sign extension bugs | Medium | Medium | Test boundary values: FASTINT_MIN, FASTINT_MAX, -1, 0 |
| C3 compiler doesn't optimize NaN-box checks | Low | Medium | Profile with `optlevel: "max"`; check generated asm |
| 32-bit platform breakage | Low | Low | Keep 16-byte fallback behind `$if !env::ARCH_64_BIT` |
| GC mark phase misses encoded pointers | Medium | High | Comprehensive GC stress tests |

---

## Effort Estimate

| Phase | Sessions | Dependencies |
|-------|----------|-------------|
| 0: Preparation | 1 | None |
| 1: Core TVal restructure | 3-5 | Phase 0 |
| 2: VM adaptation | 2-3 | Phase 1 |
| 3: Compiler adaptation | 1 | Phase 1 |
| 4: Heap/GC adaptation | 1-2 | Phase 1 |
| 5: Builtins adaptation | 1-2 | Phase 1 |
| 6: Validation | 1-2 | Phases 1-5 |
| **Total** | **10-16 sessions** | |

Phase 1 is the critical path. Phases 2-5 can be parallelized (VM and builtins are independent). Phase 6 is the gate.

### Recommended Execution Order

```
Phase 0 -> Phase 1 -> Phase 2 (parallel with 3, 4, 5) -> Phase 6
```

Within Phase 1, the sub-ordering is:
1. Define new TVal type + encode/decode helpers
2. Update `make_*()` / `set_*()` / `is_*()` functions
3. Add `$if env::ARCH_64_BIT` guards
4. Compile with `USE_NANBOX=false` — verify everything still works
5. Flip to `USE_NANBOX=true` — fix compile errors
6. Run tests — fix runtime bugs

---

## Alternative: Incremental Approach (Rejected)

If NaN-boxing is too invasive for one effort, a hybrid approach could close part of the gap with less risk:

1. **TVal layout optimization** (no NaN-boxing): Change the struct to `{ulong bits; TValTag tag}` — pack the union into `ulong bits` (8 bytes) + 1-byte tag = 9 bytes, but with padding still 16 bytes. Not helpful.

2. **Pointer-passing for call args**: Instead of copying TVal values into the callee's frame, pass `TVal*` pointers. This avoids the 16-byte copy entirely but adds pointer indirection on reads. Complex to implement correctly with the sliding-window call convention.

3. **Arena-allocated call frames**: Pre-allocate a stack of activation frames and their register arrays. Eliminates malloc overhead but doesn't address the 16-byte copy.

**Verdict**: NaN-boxing is the only approach that fully closes the gap. The hybrid approaches would get maybe 20-30% improvement with similar implementation effort. NaN-boxing is the right investment.

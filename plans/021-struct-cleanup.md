# Plan 021 — Struct Cleanup (follow-up to 020)

Follow-up to `020-fable-review.md`. All 8 original items are done.
This plan covers three remaining cleanup/optimization items.

## Status of plans/020

| # | Item | Status |
|---|---|---|
| 1 | GC pacing cap (4096→proportional) | **Done** (trigger = live_obj_count × 2) |
| 2 | Lazy string-wrapper indices | **Done** (Session 104) |
| 3 | snprintf→int_to_buf + small-int cache | **Done** (BuiltinStr.small_int_strs) |
| 4 | toString/valueOf pre-interned | **Done** (BuiltinStr.TO_STRING / VALUE_OF) |
| 5 | PropFlags out of PropValue (24→16 bytes) | **Done** (commit f253669) |
| 6 | Iterator state in HObjectExtra | **Done** (Session 112) |
| 7 | Array.prototype.join two-pass fix | **Done** (two-pass + memcpy) |
| 8 | Number→string %.16g round-trip | **Done** (%.16g → strtod → %.17g) |

---

## Item A: Lexer Keyword Lookup

### Where

`src/lexer.c3:123-199` — `KEYWORDS` table and `lookup_keyword`.

### Current state

`lookup_keyword` already filters by first character before byte comparison.
It's a linear scan but culls to ~3-4 candidates on average.

### Further optimizations considered

- **Sort by frequency**: put `if`, `var`, `return`, `function` first — saves
  at most 1-2 comparisons per keyword. Marginal.
- **Compile-time 2D lookup `char[128][max_len]`** indexed by
  `[first_char][len-2]` — O(1) dispatch, ~2KB table. Fragile to keyword
  changes and adds binary size.

### Verdict: **Not worth the code churn.** The lexer already does reasonable
early-out dispatch. Diminishing returns.

---

## Item B: Eliminate `CallableKind` from `HObjectFunction`

### Where

- Struct: `src/hobject.c3:320-325` (`HObjectFunction`)
- Enum: `src/hobject.c3:130-135` (`CallableKind : ushort`)
- 14 write sites across 19 builtin files + `src/vm.c3`
- 9 read sites across `src/vm.c3` and `src/builtins/function.c3`

### Current layout

```
struct HObjectFunction {
    CompiledFunction* comp_func;      //  8 bytes (offset 0)
    EnvRecord*        var_env;        //  8 bytes (offset 8)
    EnvRecord*        lex_env;        //  8 bytes (offset 16)
    int               builtin_fn_index; // 4 bytes (offset 24)
    CallableKind      callable_kind;    // ushort = 2 bytes (offset 28)
    // padding: 2 bytes
};  // Total: 32 bytes
```

### Why it's redundant

| Value | Can be inferred from |
|---|---|
| `BOUND_FN` | `flags.is_bound` (already in ObjFlags bit 10) |
| `BUILTIN_FN` | `builtin_fn_index >= 0` |
| `COMPILED_FN` | `comp_func != null` (both BOUND_FN and BUILTIN_FN already checked) |
| `OTHER` | none of the above (rare — e.g. Proxy exotic callable) |

### Byte savings: **Zero.** Removing 2-byte `ushort` leaves struct at 28
payload bytes → padded to 32. Union stays at 32 (HObjectGenerator is
already 32). No struct shrinkage.

### Why do it anyway

- Eliminates ~40 redundant write sites across 19 files
- Removes stale-state risk: `callable_kind` can diverge from `flags.is_bound`
  or `builtin_fn_index`
- The CALL hot path already follows: `is_bound?` → `builtin_fn_index >= 0?`
  → compiled fallthrough. An accessor makes this explicit.

### Implementation

#### 1. Add inline accessor (`src/hobject.c3`, after HObjectFunction struct)

```c3
fn CallableKind HObject.callable_kind() @inline {
    if (self.flags.is_bound) return CallableKind.BOUND_FN;
    if (self.extra.func.builtin_fn_index >= 0) return CallableKind.BUILTIN_FN;
    if (self.extra.func.comp_func != null) return CallableKind.COMPILED_FN;
    return CallableKind.OTHER;
}
```

#### 2. Remove field (`src/hobject.c3:325`)

Delete `CallableKind callable_kind;` from `HObjectFunction`.

#### 3. Delete write sites (40 sites, 19 files)

Every line of the form `obj.extra.func.callable_kind = CallableKind.XXX;`
is deleted. The enum value is now inferred by the accessor.

| File | Count | Notes |
|---|---|---|
| `src/hobject.c3` | 1 | `.callable_kind = CallableKind.OTHER` in `alloc_object` |
| `src/vm.c3` | 1 | `.callable_kind = CallableKind.COMPILED_FN` in CLOSURE |
| `src/builtins/core.c3` | 3 | |
| `src/builtins/object.c3` | 1 | |
| `src/builtins/string.c3` | 2 | |
| `src/builtins/array.c3` | 2 | |
| `src/builtins/function.c3` | 3 | BUILTIN_FN, COMPILED_FN, BOUND_FN |
| `src/builtins/number.c3` | 1 | |
| `src/builtins/date.c3` | 1 | |
| `src/builtins/regexp.c3` | 2 | |
| `src/builtins/global.c3` | 1 | |
| `src/builtins/generator.c3` | 3 | |
| `src/builtins/iterator.c3` | 6 | |
| `src/builtins/promise.c3` | 3 | |
| `src/builtins/weakmap.c3` | 1 | |
| `src/builtins/weakset.c3` | 1 | |
| `src/builtins/symbol.c3` | 1 | |
| `src/builtins/map.c3` | 2 | |
| `src/builtins/set.c3` | 2 | |

#### 4. Update read sites (9 sites, 2 files)

Replace `hobj.extra.func.callable_kind == hobject::CallableKind.XXX`
with `hobj.callable_kind() == hobject::CallableKind.XXX`.

| File | Line | Current check |
|---|---|---|
| `src/vm.c3` | 1177 | `invoke_getter` BUILTIN_FN check |
| `src/vm.c3` | 1515 | `vm_call_fn_impl` BUILTIN_FN check |
| `src/vm.c3` | 3729 | CALL opcode fast path COMPILED_FN check |
| `src/vm.c3` | 3991 | CALL opcode BOUND_FN check |
| `src/vm.c3` | 4028 | CALL opcode BUILTIN_FN check |
| `src/vm.c3` | 4499 | SUPER() BUILTIN_FN check |
| `src/vm.c3` | 4718 | CONSCALL opcode BOUND_FN check |
| `src/vm.c3` | 4755 | CONSCALL opcode BUILTIN_FN check |
| `src/builtins/function.c3` | 239 | BUILTIN_FN check |

#### 5. Keep the enum

`CallableKind` enum stays — it's still useful as a discriminator type for
the accessor return value. Just remove the field.

### Verification

```bash
just build          # nanbox
just build-nonanbox test_vm
just test262        # no regression
```

### Risk: **Low.** Accessor is a pure function of existing fields.
No GC interaction. No layout change. No runtime cost
(trivial comparison → branch prediction handles it).

---

## Item C: Move `prop_hash` Metadata into Side Struct

### Where

- Struct fields: `src/hobject.c3:419-424` (`prop_hash`, `prop_hash_mask`,
  `hash_prop_count`)
- Accessed in: `src/hobject.c3` (find_prop_idx, put_prop, delete_prop,
  ensure_prop_hash, hobject_free), `src/vm.c3` (8 sites), `src/env.c3`
  (8 sites), `src/builtins/object.c3` (16 sites)

### Current layout (offset 80-95 in HObject)

```
void* prop_hash;         // 8 bytes — pointer to hash table buffer
uint  prop_hash_mask;    // 4 bytes — size mask (num_slots - 1)
uint  hash_prop_count;   // 4 bytes — cached prop_count when hash was built
```
16 bytes total, only active when `prop_count >= HASH_MIN_PROPS (8)`.

### The union problem

Hash table info is NOT mutually exclusive with other extra variants.
A function object with 100 properties needs BOTH `HObjectFunction`
(comp_func, var_env, lex_env, builtin_fn_index = 28 bytes) AND the
hash table. They cannot overlap in the HObjectExtra union.

### Solution: heap-allocated side struct

Replace the 3 inline fields with a single pointer to a heap-allocated
`PropHashInfo` struct:

```c3
// New struct in hobject.c3 (near HashEntry ~line 530)
struct PropHashInfo {
    void* table;    // 8 bytes — hash table entries buffer
    uint  mask;     // 4 bytes — (num_slots - 1)
    uint  count;    // 4 bytes — cached prop_count when hash was built
}  // 16 bytes, same as current inline layout
```

In HObject, the 3 fields collapse to one:
```
PropHashInfo* prop_hash;  // 8 bytes — null means no hash table
```

### Savings

**8 bytes per HObject** (16 → 8). From 136 → 128 bytes (5.9%).

For 100k objects: 800KB saved. But only objects that never reach
`prop_count >= 8` save the full 8 bytes (most objects).

### Accessor methods needed

```c3
fn void* HObject.prop_hash_table() @inline {
    return self.prop_hash != null ? self.prop_hash.table : null;
}
fn uint HObject.prop_hash_mask_val() @inline {
    return self.prop_hash != null ? self.prop_hash.mask : 0;
}
fn uint HObject.hash_prop_count_val() @inline {
    return self.prop_hash != null ? self.prop_hash.count : 0;
}
```

### Cost: extra indirection in hot path

`find_prop_idx` is the **hottest property path** in the VM — called on
every GETVAR, PUTVAR, GETPROP, PUTPROP that misses the IC. The current
fast path reads `self.prop_hash` (8-byte inline field) directly. The new
path reads `self.prop_hash->table` (pointer dereference through heap
memory).

On modern CPUs with L1 dcache hit the penalty is ~4 cycles per access.
On cache-miss it's ~100+ cycles. For objects accessed in a tight loop
the pointer is likely in L1, so the cost is low. But for cold objects
or GC-heavy programs the indirection is a real regression.

### Affected call sites (~15 in hobject.c3, ~30 across other files)

All reads of `self.prop_hash`, `self.prop_hash_mask`, `self.hash_prop_count`
become accessor calls:

- `hobject.c3:679-681` — `find_prop_idx` hash table probe
- `hobject.c3:827-854` — `put_prop` hash table insert
- `hobject.c3:931-934` — `delete_prop` free hash table
- `hobject.c3:554-589` — `ensure_prop_hash` allocation
- `hobject.c3:1163-1164` — `hobject_free` cleanup
- `hobject.c3:636-658` — `get_prop_flags` (uses shape, not hash, but
  touches `prop_hash` to check if stale)

### Verification

```bash
just build && just test_vm
just bench          # measure bench_property_lookup and bench_object
just test262        # no regression
```

**Must microbenchmark before merging.** If `bench_property_lookup`
regresses >5%, abort this change.

### Risk: **Medium.** Adds heap allocation per hash-enabled object.
Extra indirection in hottest path. Allocation overhead (~48 bytes per
`PropHashInfo` including malloc block header) may offset savings for
objects that DO have hash tables.

---

## Recommended sequence

1. **Item B (CallableKind)** — zero risk, pure code cleanup, mechanical
   grep-and-delete. Land first.
2. **Item C (prop_hash side struct)** — benchmark-gated. Only proceed if
   `bench_property_lookup` shows no regression. Land second if green.
3. **Item A (Lexer)** — skip. Already reasonable. Not worth the churn.

## Verification checklist (for each item)

```bash
just build                # nanbox build
just build-nonanbox test_vm  # nonanbox build
just test_vm              # basic VM tests
just test262              # full conformance suite
just bench                # benchmark suite (esp. for Item C)
```

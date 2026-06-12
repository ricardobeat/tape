# Plan 030 — Memory Profiling & Gap Analysis

**Date**: June 12, 2026
**Status**: Research complete; tasks below
**Goal**: Close the 2.6× RSS gap vs original Duktape (16 MB → ~6 MB on `memory_test.js`)

---

## Profiling Results (from `memory_test.js`)

```
malloc_total:     9,310 KB   (21,847 calls)
avg_alloc:          436 B
live_objects:     12,419
peak_objects:     12,419
strings:           9,425    (in string table)
shapes:            1,293
malloc_overhead:   ~341 KB  (est. 16 B/call for libc metadata)
```

- **Total malloc'd**: 9,310 KB
- **RSS observed**: 16,384 KB
- **Gap**: 7,074 KB (malloc metadata, fragmentation, code, stack, VM internals)

---

## Struct Size Comparison (64-bit, nanbox)

| Struct | Duktape (C) | QuickJS (C) | Our C3 port | Delta vs best |
|---|---|---|---|---|
| Object header (plain `{}`) | 64 B | ~72 B | **64 B** | 0 |
| Object header (function) | sizeof(base)+subclass fields | ~72 B (union inline) | **96 B** | +24 B |
| Object header (array) | same as base | ~72 B | **72 B** | 0 |
| String header | ~24 B | **12 B** (packed) | 32 B | +20 B vs QJS |
| Property value slot | 16 B (union value/getset) | 16 B (union) | **16 B** (value+setter, setter wasted on data) | 0-8 B |
| Shape property | — (inline in props) | **8 B** | 16 B | +8 B |
| Shape header | — | ~57 B + hash + props | 24 B + props | n/a |
| GC links | 16 B (next+prev) | 16 B (list_head) | 16 B (next+prev) | 0 |
| Per-object hash table | 0 (inline in props) | 0 (in shape) | **2 mallocs** (PropHashInfo + HashEntry) | var |

### Key finding: object headers are NOT the problem

After Items 3 & 4 & 1, our HObjectBase is **64 bytes** — identical to original Duktape and smaller than QuickJS (~72 bytes). The remaining gap comes from:

---

## Root Causes (ranked by estimated impact)

### 1. Per-object `prop_alloc` blocks — every property-bearing object gets a separate malloc

**Current**: Each object with properties gets its own `malloc(128+)` for `prop_alloc` (initial capacity 8 slots × 16 bytes). With 10,000+ property-bearing objects, that's 10,000 separate mallocs.

**Original Duktape**: Same pattern (each object gets its own props allocation). But Duktape packs keys, values, flags, AND hash table into one contiguous block — equivalent to our `prop_alloc`, just with more inline.

**QuickJS**: Properties split between shared `Shape` (names/flags/hash — one allocation shared by all objects with same layout) and per-object `JSProperty[]` (values only). Per-object prop array is still a separate malloc.

**Fix options**:
- A. **Inline small prop tables** — embed 4 PropValue slots directly in the object tail (after prototype), avoiding the separate malloc for 0-4 property objects. Saves 10,000 mallocs × 16 B overhead = 160 KB just in metadata, plus reduces RSS.
- B. **Pool allocator** — use fixed-size arenas like QuickJS to eliminate per-allocation malloc overhead for small allocations. Complex but highest impact.

### 2. PropValue setter waste — 8 bytes unused per data property slot

**Current**: `PropValue` is 16 bytes (TVal value + TVal setter). For data properties, the `setter` field (8 bytes) is never used. With ~35,000 active property slots in memory_test.js, that's **280 KB** wasted.

**Original Duktape**: Uses a union where `value` and `getter` overlap at offset 0, and `setter` extends beyond at offset 8. When a slot is a data property, bytes 8-15 are just padding (same as us). But the union reduces the per-slot size to max(data, accessor pair) = 16 bytes. So Duktape has the SAME waste.

**QuickJS**: Same pattern — `JSProperty` is also 16 bytes with an overlapping union.

**Conclusion**: All three engines waste 8 bytes per data property slot. This is universal bloat, not unique to us.

**Fix**: Move `setter` into the union with `value`/`getter`:
```c3
union PropData {
    struct { TVal value; TVal setter; } data;  // 16 B — waste but keeps alignment
    struct { TVal getter; TVal setter; } acc;   // 16 B
};
```
Then data properties only need 8 bytes (value), accessors need 16 bytes (getter+setter). But this requires variable-sized property slots, which complicates the prop_values[] array. Not trivial.

### 3. String header: 32 B vs QuickJS 12 B

| Field | Our HString | QuickJS JSString | Delta |
|---|---|---|---|
| flags | 4 B | — (packed in block header) | |
| refcount | 4 B | — (packed in block header) | |
| next | 8 B | — (in atom table) | |
| hash | 4 B | 4 B (packed with len) | |
| blen | 4 B | 4 B (packed with is_wide) | |
| clen | 4 B | — (computed lazily) | |
| arridx | 4 B | — (cached elsewhere) | |
| **Total** | **32 B** | **12 B** | +20 B |

With 9,425 strings, the header alone costs 302 KB vs QuickJS's 113 KB — a **189 KB** difference. Not the dominant cost, but notable.

**Fix**: Compute `clen` lazily instead of storing it (5,100+ strings). Remove `arridx` from HString and compute on demand (or cache in a side table for hot strings only).

### 4. Both `shape_id` AND `shape` pointer — redundant cache

**Current**: Every object carries `ushort shape_id` (2+6 pad) + `Shape* shape` (8 bytes) = 16 bytes. The `shape` pointer is always `heap->shapes[shape_id]` — a pure cache.

**Original Duktape**: No shape system — property layout is inline in the props allocation.

**QuickJS**: Only `JSShape*` pointer (8 bytes) — no separate shape_id. The shape IS refcounted, so the pointer is the canonical reference.

**Fix**: Drop the `shape` pointer (8 bytes) and dereference through `heap->shapes[shape_id]` via `_active_heap`. Saves 8 bytes × 12,419 objects = **97 KB**. Adds one indirection per property access. Acceptable for memory-constrained builds (`-D NOSHAPECACHE`).

### 5. QuickJS pool allocator — the big differentiator

QuickJS uses arenas of fixed-size blocks with an 8-byte inline header (`JSMallocBlockHeader`). This:
- Eliminates per-allocation `malloc` metadata (16+ bytes)
- Eliminates fragmentation from variable-size allocations
- Groups allocations of the same size into contiguous pages

Our port calls `libc::malloc` for every tiny allocation (21,847 calls for memory_test.js). Each call has 16-32 bytes of metadata overhead. Total overhead: **349-699 KB** just for malloc bookkeeping.

**Fix**: Implement a simple pool allocator for object headers (the most frequent allocation). With 12,419 object allocations, even a basic pool would save 12,419 × 16 = **194 KB** in metadata alone, plus reduced fragmentation.

---

## C3 Stdlib Options

### `std::core::mem_mempool` — Fixed-size slab allocator

The C3 stdlib ships a **slab/pool allocator** (`core::mem_mempool`). Perfect for allocating
HObjects of known sizes:

```c3
import std::core::mem_mempool;

// One pool per allocation size class
Mempool obj_pool_64;   // plain objects (64 bytes)
Mempool obj_pool_72;   // ARRAY objects (72 bytes)
Mempool obj_pool_96;   // FUNCTION/REGEXP/etc (96 bytes)

obj_pool_64.init(64);  // block size = 64 bytes
void* p = obj_pool_64.alloc();~  // zero-init single block
obj_pool_64.free(p);                // return to pool
```

- Eliminates per-allocation `libc::malloc` metadata (16-24 bytes saved per object)
- Reduces fragmentation — all objects of same size class share contiguous slabs
- `alloc()` zero-initializes (replaces our `libc::malloc` + `libc::memset` pair)
- Built-in, no need to write our own

**Integration**: Replace `Heap.alloc()` call in `hobject_alloc()` with pool lookup by `alloc_size_for_class(cls)`.
Fall back to `Heap.alloc()` if pool is exhausted.

### `@pool()` / `mem::@stack_mem()` — Arena/scratch allocators

```c3
// Temp arena freed at scope exit — zero overhead, no individual frees needed
@pool() {
    // All allocations here use temp allocator, freed automatically
    char[] buf = mem::temp_array(char, 4096);
}

// Stack-based arena (fixed size, no heap)
mem::@stack_mem(65536; |Allocator arena| {
    // Allocations from 'arena' live on the stack
});
```

Useful for:
- **Compilation temporaries** — parser AST nodes, compiler intermediate data
- **Regex compilation** — bytecode buffers, temporary strings
- **GC gray stack** — already using a dynamic array, but could benefit from pre-sized arena

### `collections::List{T}` — Typed dynamic array

```c3
import std::collections::list;
alias PropList = List{PropValue};

PropList props;
props.init(heap_allocator, initial_capacity = 8);
props.push(prop_val);
props[i] = val;        // zero-cost operator[]
props.free();
```

Could replace our manual `prop_alloc` management (realloc, memmove, zero-init). But adds
`List`'s own overhead (capacity, size fields) which are already in HObject. Not a direct
replacement — more of a refactoring opportunity.

### `mem::new_array(T, n)` — Typed zero-init allocation

```c3
PropValue* pv = mem::new_array(PropValue, 8);  // alloc + zero-init, 8 slots
mem::free(pv);
```

Cleaner than `libc::malloc(n * sizeof(X))` + `libc::memset(p, 0, ...)`. Already equivalent
to what we do in `grow_props`. Minor code quality improvement.

### Generics for sized pools

C3 generics could make a type-safe pool per HObject variant:

```c3
struct PoolAlloc <Type> {
    Mempool pool;
}
fn void PoolAlloc.init(Type self, sz block_size = Type::size) {
    self.pool.init(block_size);
}
fn Type* PoolAlloc.alloc(Type self) { return (Type*)self.pool.alloc(); }
fn void PoolAlloc.free(Type self, Type* p) { self.pool.free(p); }
```

This would let us allocate `PoolAlloc{HObjectBase}.alloc()` for plain objects, etc.
But the `mem_mempool` API is already type-agnostic — generics add little value here.

### `inline` Struct Subtyping — true structural inheritance

C3's `inline` keyword on a struct member flattens the member's fields into the parent:

```c3
struct HObjectBase { ObjFlags flags; ... PropHashInfo* prop_hash; }
struct HObject {
    inline HObjectBase base;   // fields accessible as self.flags, self.prop_count, etc.
    HObjectExtra extra;        // 32 bytes at offset HObjectBase::size
    uint array_length;         // 4 bytes
}
// HObject* implicitly converts to HObjectBase* and HeapHeader*
```

This means:
- No duplicate field definitions needed between HObjectBase and HObject
- `HObject*` → `HeapHeader*` cast works (same layout at offset 0)
- `HObject*` → `HObjectBase*` conversion is implicit (no cast needed)
- All existing `self.flags`, `self.prop_count` etc. keep working without any changes

Could simplify our current approach where HObjectBase duplicates HObject's first N fields
verbatim to guarantee layout compatibility. Lower maintenance burden.

### `@packed` — Eliminate struct padding

```c3
struct ShapeProperty @packed {
    void*     key;   // 8 bytes
    PropFlags flags; // 1 byte (bitstruct : char)
}
// 9 bytes instead of 16 (no padding to align key)
```

Useful for memory-critical structs: `ShapeProperty` (16→12? no, key needs 8-byte alignment),
`Shape` (24→20), `PropHashInfo` (16→12). Gains are modest (2-4 bytes each) but
compound across thousands of allocations.

Caveat: unaligned access may be slower. Not recommended for hot-path structs like
`PropValue` or `ICEntry`.

### `mem::new_with_padding` — Cleaner variable-size allocation

```c3
// Current: manual size calculation + memset
usz sz = alloc_size_for_class(cls);
void* raw = heap.alloc(sz);
libc::memset(raw, 0, sz);

// With new_with_padding:
HObjectBase* raw = mem::new_with_padding(HObjectBase, extra_bytes);
// Allocates sizeof(HObjectBase) + extra_bytes, all zero-initialized
```

Cleaner than our `alloc_size_for_class` switch. The extra bytes are zeroed automatically.
Requires the heap's allocator to implement the `Allocator` interface (or we adapt
`Heap.alloc` to match `mem::malloc` semantics).

### `$$memset` / `$$memcpy` — Compiler builtins

C3's LLVM backend provides optimized `$$memset` / `$$memcpy` builtins that map to
LLVM intrinsics. Replace `libc::memset` / `libc::memcpy` in hot paths:
- `grow_props` (memmove array part on realloc)
- `GC mark` (iterating property values)
- `hobject_alloc` (zero-init new objects)

### `--sanitize=address` — ASan for validation

```bash
c3c build --sanitize=address duktape_c3
```

Catches heap corruption, use-after-free, buffer overflows at runtime. Would have caught
our earlier `hobject_alloc` heap corruption (writing to offset 72 on 72-byte allocation)
immediately. Essential for validating Item 1-class changes.

---

## Correctness Bugs from Plan 029 (fix before proceeding)

These were introduced by the `uint→ushort` compression in plan 029 and must be resolved
before adding further changes that depend on `_active_heap` or shape IDs.

### Bug A — IC generation wrap (hobject.c3:1530, vm.c3:2401)

`VarICEntry.generation` was narrowed to `ushort` but `Shape.generation` remains `uint`.
After 65536 mutations to a shape, the stored ushort wraps and aliases a past generation
value. The IC-validation compare (`vm.c3:2231`: `shape.generation == vic.generation`)
promotes the ushort to uint — so when the live generation is e.g. 65537 and the IC was
stored at generation 1, both produce ushort 1 and the IC appears valid. A stale `prop_idx`
is then used to read/write the wrong slot in `prop_values[]`.

**Fix**: Widen `VarICEntry.generation` back to `uint`. The field is 2 bytes inside a
struct that also has `ushort prop_idx` — widening costs 2 bytes of padding per entry, a
negligible regression against the plan 029 wins.

### Bug B — Shape ID 65535 aliases SHAPE_ID_NONE (heap.c3:648)

`alloc_shape_slot()` returns `uint` with no cap below 65535. When `shape_count` reaches
65535 organically, the returned id passes the `SHAPE_NONE` (0xFFFF_FFFF) guard and is cast
to `(ushort)65535 == SHAPE_ID_NONE`. The shape is stored in `shapes[65535]` but the
object's `shape_id` is set to the sentinel value. Any lookup-transition return of this ID
is treated as "no transition found", breaking shape sharing and IC for that object. At
65536+ shapes the ushort wraps to 0, 1, … aliasing live shapes and corrupting
`prop_values[]` accesses.

**Fix**: One line in `alloc_shape_slot` before returning: `if (id >= 0xFFFE) return SHAPE_NONE;`
(cap valid IDs at 65534). 65535 shapes is far beyond any real workload, so this is safe.

---

## Recommended Implementation Order

| # | Item | Est. savings | C3 help | Effort | Risk |
|---|---|---|---|---|---|
| A | **Fix IC generation wrap** (`VarICEntry.generation` → `uint`) | 0 KB | — | Trivial | None |
| B | **Cap shape IDs at 65534** in `alloc_shape_slot` | 0 KB | — | Trivial | None |
| 1 | **Pool allocator via `mem_mempool`** | ~250 KB | `std::core::mem_mempool` | Low | Low |
| 2 | Drop `shape` pointer | ~100 KB | — | Low | Low |
| 3 | Use `inline` struct subtyping for HObject/HObjectBase | 0 KB (code quality) | `inline` keyword | Low | Very low |
| 4 | Compute `clen` lazily | ~60 KB | — | Low | Very low |
| 5 | Inline small prop tables | ~300 KB | — | Medium | Medium |

**Items A & B** must go first — they are correctness fixes for plan 029 regressions.
Item 2 (drop `shape` pointer) relies on `_active_heap` being correct; shipping that on
top of a broken IC generation check would make failures harder to diagnose.

**Item 3** is a no-brainer refactor — eliminates duplicate field definitions, makes the
struct relationship self-documenting, and ensures HObject*/HObjectBase*/HeapHeader* casts
stay safe as we evolve the struct. Should be done before any further HObject surgery.

**Item 1** (pool allocator) becomes the priority — C3 ships the allocator for free,
we just wire it into `hobject_alloc`. Replaces 12,000+ `libc::malloc` calls with
pool allocations. Re-run profiling after to reassess the remaining gap.

## Verification

```bash
just build
just bench-memory   # compare before/after RSS
```

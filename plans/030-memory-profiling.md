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

---

## Recommended Implementation Order

| # | Item | Est. savings | C3 stdlib help | Effort | Risk |
|---|---|---|---|---|---|
| 1 | **Pool allocator via `mem_mempool`** | ~250 KB | `std::core::mem_mempool` | Low | Low |
| 2 | Drop `shape` pointer | ~100 KB | — | Low | Low |
| 3 | Compute `clen` lazily | ~60 KB | — | Low | Very low |
| 4 | Inline small prop tables | ~300 KB | — | Medium | Medium |

**Item 1** (pool allocator) becomes the priority — C3 ships the allocator for free,
we just wire it into `hobject_alloc`. Replaces 12,000+ `libc::malloc` calls with
pool allocations. Re-run profiling after to reassess the remaining gap.

## Verification

```bash
just build
just bench-memory   # compare before/after RSS
```

# Plan: Split HObject into Subtypes

**Date**: June 1, 2026
**Status**: Proposed
**Goal**: Reduce per-object memory from 168 bytes to 96 bytes (43% reduction)

---

## Problem

The current `HObject` struct (src/hobject.c3:300-346) is a **flat 168-byte struct** that carries
fields for every possible object kind — functions, regexp, generators, primitive wrappers — even
on plain `{}` literals that use none of them.

The vdom benchmark creates ~9000 plain objects (60 frames × 15 components × 10 nodes). At 168
bytes each, that's **1.5 MB** of object headers alone. Duktape's equivalent is ~56 bytes per
object (504 KB total) — a **3× difference**.

Peak RSS comparison on vdom_test.js:

| Engine | RSS (KB) |
|--------|----------|
| C3 port | 5168 |
| Duktape | 2224 |
| QuickJS | 2336 |

The C3 port uses **2.3× more memory** than Duktape. Object header bloat is the primary cause.

---

## Root Cause

Duktape uses **C struct inheritance** — `duk_hobject` is the base (56 bytes), and subtypes
embed it as their first member:

```
duk_hobject         (56 bytes) — plain objects
  └─ duk_hcompfunc  (+48 bytes) — compiled JS functions
  └─ duk_hnatfunc   (+12 bytes) — native C functions
  └─ duk_harray     (+8 bytes)  — arrays (just .length)
  └─ duk_hbufobj    (+40 bytes) — TypedArrays
  └─ duk_hthread    (+huge)     — execution threads
```

The C3 port puts **everything** in one struct. Here's what's wasted on plain objects:

```
Field              Size     Used by
─────────────────────────────────────────
primitive_value    16 B     Boolean/Number/String wrappers only
comp_func          8 B      JS functions only
var_env            8 B      JS functions only
lex_env            8 B      JS functions only
builtin_fn_index   4 B      native builtins only
callable_kind      2 B      callable objects only
regexp_data        8 B      RegExp only
generator_data     8 B      generators only
─────────────────────────────────────────
TOTAL WASTED:      62 B     per plain object
```

---

## Design

### Struct Hierarchy

Use a **tagged union** — C3's `zunion` — with the existing `ObjClass` discriminator in
`ObjFlags.obj_class` (already allocated, 6 bits, src/hobject.c3:159).

```c3
// ── Base: fields common to ALL objects ────────────────────────────────────
struct HObjectBase {
    // Inline HeapHeader (GC doubly-linked list)
    ObjFlags      flags;           //  4 B  (contains obj_class discriminator)
    HeapHeader*   next;            //  8 B
    HeapHeader*   prev;            //  8 B

    // Prototype chain
    HObject*      prototype;       //  8 B

    // Shape (shared property layout)
    uint          shape_id;        //  4 B  (IC support)
    Shape*        shape;           //  8 B
    void*         heap_ptr;        //  8 B

    // Property values (indexed by shape property index)
    // prop_values is derived: (PropValue*)prop_alloc
    uint          prop_capacity;   //  4 B
    uint          prop_count;      //  4 B

    // Dense array part
    // array_part is derived: prop_alloc + prop_capacity * sizeof(PropValue)
    uint          array_size;      //  4 B
    uint          array_used;      //  4 B

    // Unified property allocation block
    void*         prop_alloc;      //  8 B
}
// Total: 64 bytes
//
// Derived accessors (inline methods, zero overhead with optimization):
//   prop_values → (PropValue*)prop_alloc
//   array_part  → (TVal*)(prop_alloc + prop_capacity * PropValue.size)
```

```c3
// ── Function: JS compiled functions ───────────────────────────────────────
struct HObjectFunction {
    CompiledFunction* comp_func;   //  8 B
    EnvRecord*        var_env;     //  8 B
    EnvRecord*        lex_env;     //  8 B
    int               builtin_fn_index; //  4 B  (used by BUILTIN_FN too)
    CallableKind      callable_kind;    //  2 B
}
// Extra: 30 bytes
```

```c3
// ── Primitive wrapper: Boolean, Number, String objects ────────────────────
struct HObjectPrimitive {
    TVal          primitive_value; // 16 B
}
// Extra: 16 bytes
```

```c3
// ── RegExp: pattern + compiled bytecode ───────────────────────────────────
struct HObjectRegExp {
    TVal          pattern_str;     // 16 B  (currently in primitive_value)
    void*         regexp_data;     //  8 B
}
// Extra: 24 bytes (note: regexp also needs callable_kind for BUILTIN_FN dispatch)
```

```c3
// ── Generator: suspended execution state ─────────────────────────────────
struct HObjectGenerator {
    void*         generator_data;  //  8 B  (GeneratorState*)
    CompiledFunction* comp_func;   //  8 B  (generator function)
    EnvRecord*    var_env;         //  8 B
    EnvRecord*    lex_env;         //  8 B
}
// Extra: 32 bytes
```

```c3
// ── The tagged union ─────────────────────────────────────────────────────
// C3 union — discriminator is base.flags.obj_class (already exists)
union HObjectExtra {
    HObjectFunction  func;
    HObjectPrimitive prim;
    HObjectRegExp    regexp;
    HObjectGenerator gen;
}

struct HObject {
    HObjectBase   base;       // 80 bytes — always present
    HObjectExtra  extra;      // variable, overlaps via union
}
// sizeof(HObject) = 64 + max(func=30, prim=16, regexp=24, gen=32) = 64 + 32 = 96
// NOT 168! The union overlaps the extra fields.
```

**Key insight**: With a union, `sizeof(HObject)` = 64 + 32 = **96 bytes**, not 168. This is
a 43% size reduction. And the union naturally handles objects that share extra fields (e.g.,
generators also need `comp_func` + `var_env` + `lex_env`, which overlaps with `HObjectFunction`).

**Derived pointers**: `prop_values` and `array_part` are removed from the struct. They are
already recomputed by `update_prop_pointers()` (hobject.c3:359) — we replace them with inline
methods that compute on demand. This saves 16 bytes per object.

**Allocator strategy**: Allocate `sizeof(HObject)` = 96 bytes for all objects. This is simpler
than variable-size allocation and still saves 72 bytes per object (168 → 96). For a further
win, we can later do per-kind allocation (64 bytes for plain objects).

**Access pattern**: `obj.extra.func.comp_func`, `obj.extra.prim.primitive_value`, etc. The
`base.flags.obj_class` discriminator tells you which union variant is active.

---

## Impact Analysis

### 1. GC Marking (src/heap.c3:1204 — `drain_gray`)

**Current**: Scans `var_env`, `lex_env`, `primitive_value` on every object uniformly.

**After**: Must dispatch on `base.flags.obj_class`:

```c3
// Common fields (always scanned)
mark_hobject(obj.base.prototype);
PropValue* pv = obj.base.prop_values();  // derived from prop_alloc
for (i < obj.base.prop_count) { mark_tval(pv[i]); }
TVal* ap = obj.base.array_part();  // derived from prop_alloc + prop_capacity * sizeof(PropValue)
if (ap) { mark_tval(ap[0..array_size]); }

// Subtype-specific fields
switch (obj.base.flags.obj_class) {
    case FUNCTION:
        mark_env(obj.extra.func.var_env);
        mark_env(obj.extra.func.lex_env);
    case BOOLEAN, NUMBER, STRING:
        mark_tval(obj.extra.prim.primitive_value);
    case REGEXP:
        mark_tval(obj.extra.regexp.pattern_str);
    case GENERATOR:
        mark_env(obj.extra.gen.var_env);
        mark_env(obj.extra.gen.lex_env);
    default: // OBJECT, ARRAY, ERROR, etc. — nothing extra
}
```

**Risk**: Low. The switch is a minor perf addition. Object count >> switch cost.

### 2. VM Dispatch (src/vm.c3)

**Affected call sites** (must use `extra.func.*` instead of direct field access):

| Opcode/Function | Fields Accessed | Lines |
|----------------|-----------------|-------|
| `vm_call_fn_fast` | `comp_func`, `var_env`, `lex_env` | 845-848 |
| `vm_call_fn_impl` | `callable_kind`, `builtin_fn_index`, `comp_func` | 1187-1223 |
| CALL_FAST | `callable_kind`, `comp_func`, `var_env`, `lex_env` | 2652-2677 |
| CALL (slow) | `callable_kind`, `builtin_fn_index`, `comp_func`, `var_env`, `lex_env` | 2840-3099 |
| SUPER_CALL | same as CALL | 3286-3331 |
| NEW | same as CALL | 3500-3623 |
| GETPROP (getter) | `comp_func` | 917-919 |
| PUTPROP (setter) | `comp_func`, `var_env` | 2228-2249 |
| CLOSURE | `comp_func`, `var_env`, `lex_env` | 4302-4304 |
| REGEXP | `regexp_data`, `primitive_value` | 2448-2490 |
| FORIN/WITH (ToObject) | `primitive_value` | 4388-4404, 4667-4683 |

**Migration**: Mechanical find-and-replace:
- `hobj.comp_func` → `hobj.extra.func.comp_func`
- `hobj.var_env` → `hobj.extra.func.var_env`
- `hobj.primitive_value` → `hobj.extra.prim.primitive_value`
- etc.

**Cast helper**: Add `fn HObjectFunction* HObject.as_func(&self)` accessor that asserts
`obj_class == FUNCTION` in debug builds.

### 3. Builtins (src/builtins.c3)

**~120 field accesses** — same mechanical migration as VM. All go through `extra.*`.

**Initialization** (register_*_builtins functions):
- `alloc_object(FUNCTION)` → gets base + func fields
- `alloc_object(OBJECT)` → gets base only
- etc.

**Key change**: `hobject_alloc` must zero the right extra fields based on `ObjClass`.

### 4. Property Access (src/hobject.c3)

**Affected by derived-pointer elimination** — `prop_values` and `array_part` become methods:
- `get_prop`, `put_prop`: use `self.prop_values()` instead of `self.prop_values`
- `get_array_idx`, `set_array_idx`: use `self.array_part()` instead of `self.array_part`
- `grow_props`, `grow_array`: must recompute derived pointers after realloc

All ~169 call sites change from field access to method call. The methods are `@inline` so
zero overhead — the compiler generates the same address computation as before.

### 5. hobject_alloc (src/hobject.c3:764)

**Current**: `libc::malloc(sizeof(HObject))` — always 168 bytes.

**After**: `libc::malloc(sizeof(HObject))` — always 96 bytes (union + derived pointers). Same
code path, just a smaller struct. No variable-size allocation needed.

### 6. String Interning / HString

**Unaffected** — HString is a separate allocation with its own header.

---

## Implementation Steps

### Phase 1: Eliminate derived pointers (168 → 152 bytes)

This is the smallest, safest change — no struct split needed yet.

1. Add inline accessor methods to HObject:
   - `fn PropValue* HObject.prop_values(&self) @inline` — returns `(PropValue*)self.prop_alloc`
   - `fn TVal* HObject.array_part(&self) @inline` — returns computed offset from `self.prop_alloc`
   - `fn void HObject.update_prop_pointers(&self)` — keep for places that need a stable pointer
2. Remove `PropValue* prop_values` field from HObject (8 bytes)
3. Remove `TVal* array_part` field from HObject (8 bytes)
4. Migrate all `obj.prop_values` → `obj.prop_values()` and `obj.array_part` → `obj.array_part()`:
   - `builtins.c3`: ~128 call sites
   - `hobject.c3`: ~30 call sites
   - `vm.c3`: ~8 call sites
   - `heap.c3`: ~3 call sites
5. Update `hobject_init` to remove zero-init of removed fields
6. Update `update_prop_pointers` to only recompute on demand (no-op if already inline)
7. **Verify**: `sizeof(HObject)` = 152. Compile, run all tests.

### Phase 2: Split into subtypes with union (152 → 96 bytes)

8. Define `HObjectBase` with all common fields (64 bytes)
9. Define `HObjectFunction`, `HObjectPrimitive`, `HObjectRegExp`, `HObjectGenerator`
10. Define `HObjectExtra` union
11. Define `HObject` as `HObjectBase` + `HObjectExtra`
12. Add cast accessors: `HObject.as_func()`, `HObject.as_prim()`, `HObject.as_regexp()`, `HObject.as_gen()`
    — each asserts `base.flags.obj_class` matches in debug builds
13. In `hobject_init`, zero the entire `extra` union (one `mem::clear`), then set relevant variant
14. **Verify**: `sizeof(HObject)` = 96. Compile, run tests.

### Phase 3: Update field access patterns

15. Update `hobject.c3` internal methods:
    - `hobject_destroy`: `regexp_data` → `self.extra.regexp.regexp_data`
    - `grow_props`, `grow_array`, `rebuild_hash`: use `base.*` (no change needed)
16. Update `heap.c3` GC marking (`drain_gray` at line 1204):
    - Common fields: `base.prototype`, `base.prop_values()`, `base.array_part()` (methods now)
    - Add switch on `base.flags.obj_class` for subtype-specific fields:
      - FUNCTION: `extra.func.var_env`, `extra.func.lex_env`
      - BOOLEAN/NUMBER/STRING: `extra.prim.primitive_value`
      - REGEXP: `extra.regexp.pattern_str`
      - GENERATOR: `extra.gen.var_env`, `extra.gen.lex_env`
17. Update `vm.c3` (~100 field accesses):
    - `obj.comp_func` → `obj.extra.func.comp_func`
    - `obj.var_env` → `obj.extra.func.var_env`
    - `obj.lex_env` → `obj.extra.func.lex_env`
    - `obj.builtin_fn_index` → `obj.extra.func.builtin_fn_index`
    - `obj.callable_kind` → `obj.extra.func.callable_kind`
    - `obj.primitive_value` → `obj.extra.prim.primitive_value`
    - `obj.regexp_data` → `obj.extra.regexp.regexp_data`
    - `obj.generator_data` → `obj.extra.gen.generator_data`
18. Update `builtins.c3` (~120 field accesses): same mechanical migration
19. Update `env.c3` if it accesses any extra fields (likely none)

### Phase 4: Optimization pass

20. **Future**: Per-kind allocation — allocate only `sizeof(HObjectBase)` = 64 bytes for
    plain objects/arrays/errors (the allocator can use `alloc_size_for_class()`). This
    requires tracking allocation size for custom allocators.
21. Consider removing `shape_id` if `Heap.shapes[shape_id]` can be replaced with pointer
    equality (saves 4 bytes per object → 60 bytes for plain objects)
22. Consider whether `prop_count` is redundant with `shape.prop_count` (may differ due to
    pre-allocation — investigate)
23. Benchmark RSS on vdom_test.js and memory_test.js — target 2-3× reduction

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| GC marks wrong fields for subtype | Medium | Crash/corruption | Debug assert on obj_class in mark path |
| Missed field access migration | Low | Compile error (C3 union access is type-checked) | Compiler catches most; grep for stragglers |
| Custom allocator needs size on free | Low | Only if not using libc free | Store size in header or use size-class pools |
| Perf regression from GC switch | Very low | Minor | Profile; the switch is O(1) per object |
| Union alignment issues | Low | Crash | Verify sizeof/offsetof in tests |

---

## Expected Outcome

- **All objects**: 168 → 96 bytes (43% reduction)
- **vdom_test.js RSS**: ~5168 → ~3500-4000 KB (estimated, 9000 objects × 72 bytes saved = ~648 KB)
- **memory_test.js RSS**: ~18656 → ~14000-15000 KB (estimated)
- **Binary size**: minimal change (a few new struct definitions, same field count overall)
- **Performance**: neutral — derived pointer methods are `@inline`, same codegen as field access

**Future (Phase 4, per-kind allocation)**:
- Plain objects: 96 → 64 bytes (further 33% reduction)
- Would bring vdom_test.js RSS closer to Duktape's 2224 KB

Further gains beyond this plan:
- Arena allocation for GC objects (pool per size-class)
- Reducing HString header (currently 32 bytes, same as Duktape — already optimal)
- Reducing PropertyEntry overhead (currently 8 bytes per prop value, with 12-byte
  ShapeProperty in shared Shape — already good)

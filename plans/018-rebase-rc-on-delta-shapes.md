# Plan 018: Re-apply Reference Counting on Top of Delta Shapes (main)

## Context

The `ref-counting` branch was based on the old flat Shape model. Main has since received:
- `22bf7f7` — GC corruption fix (reorder activation init, clear `this` slot)
- `6ebc878` — `var_ic_base` fix in inline CALL dispatch
- `b8159f5` — Delta shapes + per-object hash tables (massive memory fix)

These overlap with the RC changes in `hobject.c3`, `vm.c3`, and `heap.c3`. Rather than
rebasing (which would surface unresolvable conflicts in the Shape model), we'll create a
new branch from main and re-apply the RC changes layer by layer, adapting them for delta shapes.

## What's already on main (no re-apply needed)

- `var_ic_base` in both inline CALL paths (`6ebc878`)
- `target_fast == null` and `fast_var_env == null` guards (`b8159f5`)
- GC corruption fix: deferred `activation_count++`, cleared `this` slot (`22bf7f7`)
- Delta shapes: `Shape.own_count`/`offset`/`parent_shape`, per-object hash tables
- `prop_key_at(i)` iteration everywhere
- `collect_forin_keys` update

## Strategy

Create `ref-counting-v2` from main, apply changes in 6 layers, build+test after each layer.

```
just build && just run test/simple.js
just build && just run benchmarks/bench_string.js
```

---

## Layer 1: Core string RC infrastructure

No dependencies. Foundation for everything else.

### `src/types.c3`
- Add `incref()` call in `set_string()` after setting pointer (2 locations: the macro and `make_string_tv`)

### `src/hstring.c3`
- `hstring_alloc`: set `s.refcount = 0` (intern table is weak ref), remove `track_string(raw)` call
- `hstring_concat`: set `s.refcount = 0`, remove `track_string(raw)` call

### `src/compiler.c3`
- `add_string_constant`: add `incref()` after storing string in constants array

---

## Layer 2: Heap RC core + string lifecycle

Depends on Layer 1. Adapts the heap to manage string lifetimes by refcount instead of GC tracking array.

### `src/heap.c3` — Remove GC string tracking
- Remove `str_gc_array`, `str_gc_count`, `str_gc_capacity` fields from `Heap` struct
- Remove `peak_str_gc_count` field
- Remove `Heap.track_string()` function
- Remove `str_gc_array` allocation in `create()`
- In `destroy()`: replace `str_gc_array` sweep with `str_table` iteration (`for i in str_table_size: if str_table[i] != null: free_string(s); str_table[i] = null`)
- In `reset()`: same replacement, remove `str_gc_capacity` shrink logic

### `src/heap.c3` — Pinned refcount for builtins
- Add `const uint STRING_PINNED_REFCOUNT = 0x7FFF_FFFF`
- In `init_builtin_strs()`: after loop, set `((HeapHeader*)strs[i]).refcount = STRING_PINNED_REFCOUNT` for non-null entries

### `src/heap.c3` — Split decref into inline hot-path + out-of-line free
- Extract the free logic from `decref()` into a separate `decref_free(HeapHeader*)` function
- `decref()` becomes: decrement, if reaches 0 call `decref_free`
- `decref_tval()` uses `is_string()` check (already correct for string-only RC)

### `src/heap.c3` — `set_reg_string` fix (the root cause)
- `set_reg_string`: just calls `self.decref_tval(reg)` then `reg.set_string(s)` — NO manual incref (since `set_string` already increfs)

### `src/heap.c3` — `tval_copy_ref` correctness
- `tval_copy_ref`: decref old dst value (if string), then copy + incref new (if string)

### `src/heap.c3` — Teardown: decref compiled function metadata
- In `destroy()` and `reset()`, before freeing `CompiledFunction` pools:
  - Decref string constants: `for ci in cf.const_count: decref_tval(&cf.constants[ci])`
  - Decref IC cached keys: `for ii in cf.ic_count: if ics[ii].key: decref(ics[ii].key)`
  - Decref VarIC cached keys: `for vi in cf.var_ic_count: if vics[vi].key: decref(vics[vi].key)`

### `src/heap.c3` — Teardown: null heap_ptr before object free
- In `destroy()` and `reset()`: set `((HObject*)cur).heap_ptr = null` before calling `hobject_free` — so hobject_free skips its RC decref loop (teardown frees everything directly)

### `src/heap.c3` — Teardown: decref symbol registry
- In `reset()`: before freeing symbol_registry arrays, decref all keys and syms

### `src/heap.c3` — Transition table key incref
- In `insert_transition()`: add `incref()` for the key being stored

### `src/heap.c3` — `shape_free` calls pass heap_ptr
- All `shape_free(sh)` calls become `shape_free(sh, null)` (teardown) or `shape_free(sh, (void*)self)` (runtime)
- **Delta shapes adaptation**: `shape_free` signature changes to `(Shape* sh, void* heap_ptr)`, but the key-decref loop uses `sh.own_count` (delta) instead of `sh.prop_count` (old flat)

---

## Layer 3: Object-level RC (delta-shape adapted)

Depends on Layer 2. This is where the delta shape model matters most.

### `src/hobject.c3` — `shape_extend`: incref all copied keys
- After copying properties and setting the new key, incref all keys in the new shape
- **Delta adaptation**: shape only stores 1 new property (not N copies), so only incref that 1 key (the parent chain keys are already ref'd by parent shapes)

### `src/hobject.c3` — `shape_free(sh, heap_ptr)`: decref keys
- Change signature to accept `heap_ptr`
- If `heap_ptr != null`, decref keys in `sh.props()` for `sh.own_count` entries (delta: only own keys, not parent keys)
- Free with `libc::free(sh)` (no more base-pointer arithmetic since no hash table prefix)

### `src/hobject.c3` — `hobject_free`: decref string values
- After existing cleanup (regexp etc.), add RC decref loop:
  - Walk `prop_values[0..prop_count]`: if `is_string()`, `heap.decref_tval(&pv.data.value)`
  - Walk `array_part[0..array_size]`: if `is_string()`, `heap.decref_tval(&arr[i])`
  - Guard with `if (obj.prop_alloc != null && obj.heap_ptr != null)`
  - **Delta adaptation**: prop_count is still the total count on the object (not shape.own_count), so no change needed here

### `src/hobject.c3` — `put_prop`: RC for existing property update
- In the "update existing" branch (idx >= 0):
  - Before overwriting: `if (heap_ptr != null && pv.data.value.is_string()) { heap.decref_tval(&pv.data.value) }`
  - After storing: `if (heap_ptr != null && val.is_string()) { val.get_heapptr().incref() }`

### `src/hobject.c3` — `put_prop`: RC for new property
- After storing new value: `if (heap_ptr != null && val.is_string()) { val.get_heapptr().incref() }`

### `src/hobject.c3` — `set_array_idx`: RC for array elements
- Before overwriting: `if (heap_ptr != null && old.is_string()) { heap.decref_tval(&old) }`
- After storing: `if (heap_ptr != null && val.is_string()) { val.get_heapptr().incref() }`

### `src/hobject.c3` — `delete_prop`: adapt for delta shapes
- When creating the new private shape via `shape_create(new_count, 0, 0xFFFF_FFFF, null)`:
  - Walk old shape chain to collect surviving keys (already done by delta shapes)
  - No extra RC work needed (keys are already ref'd by the old chain; the old shape gets freed via shape_free which decrefs)
- `shape_free(ns)` calls become `shape_free(ns, self.heap_ptr)` or `shape_free(ns, null)`

### `src/hobject.c3` — `seal`/`freeze`: remove shape property flag sync
- Delta shapes already removed this in main (flags live only in prop_values). No action needed — verify main's version is correct.

---

## Layer 4: VM opcode RC

Depends on Layers 2-3. Scattered changes across the VM run loop.

### `src/vm.c3` — Replace `is_object()||is_buffer()` with `is_heap_allocated()`
- `track_heap_store`: `is_object()||is_buffer()` → `is_heap_allocated()`
- `LDREG` fast path: same replacement (3 locations in this handler)
- Inline CALL `this` handling: same replacement
- `RET` fast path: same replacement (2 locations)
- `RET` undef fallback: same replacement

### `src/vm.c3` — `LDCONST`: use `tval_copy_ref` instead of raw copy
- Replace `*ra = constants[bc]` with `vm.heap.tval_copy_ref(ra, &constants[bc])`

### `src/vm.c3` — `LDCONSTCAT`/`TYPEOF`/other string stores: use `set_reg_string`
- `LDCONSTCAT`: `ra.set_string(interned)` → `vm.heap.set_reg_string(ra, interned)`
- `TYPEOF`: same
- `GETELEM` charCodeAt path: same
- `GETPROP` charCodeAt path: same
- `NEWOBJ` builtin name: same
- `FORIN_NEXT`: same

### `src/vm.c3` — GETPROP IC: remove raw-copy fast path
- Replace the `!(ra.is_object()||ra.is_buffer())` branch with unconditional `vm.heap.tval_copy_ref(ra, &ic_val)`
- (This is the "Option C" fix from plan 017)

### `src/vm.c3` — GETVAR IC (VarIC): remove raw-copy fast path
- Same pattern: replace the `!(ra.is_object()||ra.is_buffer())` branch with `vm.heap.tval_copy_ref(ra, &v)`

### `src/vm.c3` — GETVAR_typeof IC: use `set_reg_string`
- All `ra.set_string(ts)` in typeof paths → `vm.heap.set_reg_string(ra, ts)`

### `src/vm.c3` — PUTVAR: decref+clear ra after store
- After `env_try_put_lex`/`env_put`: add `vm.heap.decref_tval(ra); ra.set_undefined();`
- This is the "Option B" fix from plan 017 — prevents stale register refs

### `src/vm.c3` — VarIC/GETPROP IC key incref
- When caching a new key in VarIC entries: decref old key (if non-null), incref new key
- When caching a new key in GETPROP IC entries: same pattern

---

## Layer 5: Environment binding RC

Depends on Layer 2. All four `env_*` update functions need the same pattern.

### `src/env.c3` — `env_put`, `env_put_lex`, `env_put_at_depth`, `env_try_put_lex`
- Before overwriting binding value: `if (heap_ptr != null && pv.data.value.is_string()) { h.decref_tval(&pv.data.value) }`
- After storing new value: `if (val.is_string()) { val.get_heapptr().incref() }`
- Guard with `if (cur.bindings.heap_ptr != null)` else just raw copy

---

## Layer 6: Builtin symbol RC

Depends on Layer 2. Small, isolated changes.

### `src/builtins.c3` — `symbol_registry_put`
- After storing key and sym: `incref()` both

### `src/builtins.c3` — `ensure_iterator_symbol`, `ensure_toprimitive_symbol`
- After creating/retrieving symbol: `refcount = STRING_PINNED_REFCOUNT`

---

## Delta-shape specific considerations

1. **`shape_extend` only stores 1 property** (not N copies). The old RC code increfs all N keys in the copied shape. The new code only increfs the 1 new key. Parent shape keys are already ref'd by their own shapes.

2. **`shape_free` only owns `own_count` keys** (not `prop_count`). The decref loop must iterate `sh.own_count` entries, not the full property count. This is naturally correct since only `own_count` ShapeProperties exist in the shape allocation.

3. **`delete_prop` creates a flat shape** with `shape_create(new_count, 0, 0xFFFF_FFFF, null)`. This shape has `own_count = new_count` and `offset = 0`. The old chain keys don't need decref here because they're still held by the chain (until the chain is freed).

4. **`hobject_free` decref loop uses `obj.prop_count`** (total, not per-shape). This is correct because prop_values is a flat array indexed 0..prop_count-1 regardless of delta shape structure.

5. **`drain_gray` GC mark** already updated by main to use `prop_key_at(i)`. No RC interaction.

6. **`transition_shape` chain walk** — main already changed the dedup check to walk the chain. The RC key incref in `insert_transition` is independent.

---

## Verification after each layer

```bash
just build && just run test/simple.js          # smoke test
just build && just run benchmarks/bench_string.js  # RC string leak check
```

Final verification after all layers:
```bash
just build-nonanbox                            # verify nonanbox path compiles
```

## Files changed (summary)

| File | Layers | Conflict risk with main |
|------|--------|------------------------|
| `src/types.c3` | 1 | None (additive) |
| `src/hstring.c3` | 1 | None (remove calls, add refcount init) |
| `src/compiler.c3` | 1 | None (additive) |
| `src/heap.c3` | 2 | Low (different sections) |
| `src/hobject.c3` | 3 | **Medium** (adapt RC for delta shape model) |
| `src/vm.c3` | 4 | Low-moderate (scattered, but main's changes are in different sections) |
| `src/env.c3` | 5 | None (main didn't touch env.c3) |
| `src/builtins.c3` | 6 | None (different functions) |

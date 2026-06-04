# Jun 2 — IC crash fixes, VM GC roots, and iterator support

Three interdependent buckets of work from ongoing development. They've been partially applied and need to be finished together.

## 1. IC crash fixes (SIGBUS/SIGABRT)

Root cause: after `ensure_valstack_grow` calls `realloc`, the valstack buffer may move, but activation `bottom`/`retval` pointers still point to the old (freed) location. Subsequent object access via `regs_base = act.bottom` reads freed memory.

**Changes**:
- `ensure_valstack_grow`: relocate `act.bottom`, `act.retval`, and `vm.valstack_bottom` by the diff after each realloc.
- All CALL/NEW_OBJ/SUPER_CALL/YIELD frame setup paths: calculate `needed` from `act.bottom` (stable, realloc-safe) instead of `regs_base` (volatile, may dangle). Re-acquire `regs_base = act.bottom` after `ensure_valstack` returns.
- `invoke_getter`: fix `needed` calculation to include frame_start; re-acquire `regs_base` after potential realloc; use correct `caller_regs` for `retval`.
- `invoke_getter`: fix `new_bottom` calculation — compute it after the potential realloc, not before.

## 2. VM GC root marking

Root cause: the GC didn't know about objects reachable from the VM's activation frames or inline caches, so a sweep could collect them. The crash only manifested during benchmarks with many function calls or prototype chains (where GC pressure was higher).

**Changes**:
- Add `GcMarkVmRootsFn` callback type and `gc_mark_vm_roots` / `vm_context` fields on `Heap`.
- Add `vm_gc_mark_roots()` function that marks: `this_binding`, `tv_func`, `new_target`, and all `lex_env`/`var_env` chain bindings from every activation frame.
- Register `vm_gc_mark_roots` in `vm_create` and `vm_reset`, clear in `vm_destroy`.
- Mark IC entries (`proto` pointer, `key` HString*) and VarIC entries (`bindings` object, `key` HString*) in `Heap.mark_roots` — these are stored in raw `void*` fields the GC can't trace automatically.
- Refactor compiled function constant marking: guard against null `constants`, and add the IC/VarIC marking loops.

## 3. Iterator support

Feature work that exposed the above bugs when running property-lookup and prototype-chain benchmarks.

**Changes**:
- Add `ARRAY_ITERATOR`, `STRING_ITERATOR` to `ObjClass` enum (hobject.c3).
- Add `iterator_target` (HObject*), `iterator_index` (uint), `iterator_kind` (uint) fields to HObject.
- Add `iterator_symbol` (well-known @@iterator) to Heap.
- Add `"symbol"` to builtin strings (BuiltinStr enum + init_builtin_strs).

## Applying

These three buckets are interdependent and must be applied together — the iterator code activates code paths that trigger the GC bugs, and the crash fixes won't build without the structural changes.

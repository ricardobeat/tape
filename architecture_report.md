# Architecture Comparison: C3 Port vs Duktape v2.7.0

**Date:** 2026-05-25
**Scope:** All implemented ES features up to Phase 20 (Promise)

> **Update (2026-06-13):** This report describes the state as of late May 2026. Several issues flagged below have since been addressed:
>
> - **TVal encoding:** NaN-boxing is now the default (`-D NONANBOX` uses the explicit 16-byte union).
> - **Object model:** Per-class allocation sizes, inline property storage, unified `prop_alloc` blocks, and `FixedBlockPool` object pools are implemented (plans 029–030). Plain-object headers are now 64 bytes, matching original Duktape.
> - **GC:** Full reference counting + mark-and-sweep GC with safe points is implemented (plan 032).
> - **Memory:** `memory_test.js` RSS is now on par with Duktape/QuickJS. Remaining heavy-workload gaps are tracked in `plans/033-memory-next-steps.md`.
>
> Sections 1–3 retain their original text for historical context but should be read with the above in mind.

---

## 1. Value Representation (TVal) — Deliberate Simplification

| Aspect | Duktape | C3 Port |
|--------|---------|---------|
| Encoding | NaN-boxing (8 bytes, packed into IEEE 754 double) | NaN-boxing by default; explicit tag + union (16+ bytes) with `-D NONANBOX` |
| Null/Undefined | Tag embedded in high 16 bits of double | Separate enum tags |
| Access | Macro-heavy (`DUK_TVAL_SET_*`, `DUK_TVAL_GET_*`) | Methods on `TVal` struct (`.set_undefined()`, `.get_number()`) |
| Portability | Compile-time endianness checks, 64-vs-32-bit code paths | Platform-neutral (C3 handles padding) |
| Fast integers | 48-bit signed integers packed into NaN payload | Separate `FASTINT` tag using C3 `long` |

**Why Duktape does it this way:** NaN-boxing is memory-critical (8 bytes vs 16+), enabling denser value stacks, faster cache utilization, and more compact property array parts (`duk_tval[]` is the backbone of every array part). The packed representation is complex but pays off in memory-constrained embedded environments.

**C3 approach rationale:** The explicit tag+union is clearer and leverages C3's tagged union semantics. The memory overhead is acceptable for a port where clarity is preferred over byte-level optimization.

**Verdict:** Acceptable tradeoff. The default NaN-boxing build recovers the 8-byte value size; the `-D NONANBOX` 16-byte path remains available for portability.

---

## 2. Object Model — Major Architectural Difference

### 2.1 Object Subtypes

| Aspect | Duktape | C3 Port |
|--------|---------|---------|
| Compiled functions | `duk_hcompfunc` (extends `duk_hobject`) + fields: `nregs`, `nargs`, `bytecode`, `data`, etc. | `HObject.comp_func` field (null for non-function objects) |
| Native functions | `duk_hnatfunc` + fields: `func` (C function pointer), `nargs`, `magic` | `HObject.builtin_fn_index` (int, -1 for non-builtins) |
| Array objects | `duk_harray` + dedicated `length` field | `HObject` with `ObjFlags.exotic_array` |
| Bound functions | `duk_hboundfunc` + `target`, `this`, `args` | `HObject.is_bound` flag |
| Buffer objects | `duk_hbufobj` + buffer-specific fields | Not yet implemented |
| Proxy objects | `duk_hproxy` + `target`, `handler` | `ObjFlags.exotic_proxyobj` flag |
| Threads | `duk_hthread` + full coroutine state | `GeneratorState` only |

**Why Duktape does it this way:** Each subtype only carries the fields it needs. A `duk_hcompfunc` doesn't waste space on `duk_hbufobj` fields and vice versa. This is critical for memory-constrained embedded use. Duktape uses a unified heap header (`duk_heaphdr`) with a type discriminator, then specific subtypes via C struct embedding.

**C3 impact:** Every HObject carries all possible fields:
- `CompiledFunction* comp_func` (8 bytes)
- `EnvRecord* var_env` (8 bytes)
- `EnvRecord* lex_env` (8 bytes)
- `TVal primitive_value` (16+ bytes)
- `int builtin_fn_index` (4 bytes)
- `void* regexp_data` (8 bytes)
- `void* generator_data` (8 bytes)

That's ~60 bytes of overhead per object. For arrays, strings, booleans, and other non-function objects, this is pure waste.

### 2.2 Property Table Layout — Critical Performance Issue

| Aspect | Duktape | C3 Port |
|--------|---------|---------|
| Memory layout | **Single allocation**: `[entry_keys][entry_values][entry_flags][array_part][hash_table]` contiguously | Unified `prop_alloc` block holds property values + array part; hash table separate; inline props avoid the block entirely for 0–4 property objects |
| Alloc count per object | 1 allocation for all property parts | 0 (inline props) to 2 (prop_alloc + hash table) |
| Cache locality | Excellent (all parts within cache line distance) | Good for values/array part; hash table is a separate pointer hop |
| Resize cost | Single `realloc` for everything | Single `realloc` for prop_alloc; hash table rebuilt separately |
| Layout variants | 3 configurable layouts (LAYOUT_1/2/3) for cache optimization | Single layout |
| Array-to-entry migration | When array becomes sparse, copies to entry part and frees array part | Same approach within the unified block |
| Hash table threshold | Built when props > 8 entries | Same (`HASH_MIN_PROPS = 8`) |

**Why Duktape does it this way:** The single-allocation approach means:
1. One malloc call per property resize (vs up to 3)
2. All parts share cache lines — iterating array part then searching entry part is fast
3. Better memory accounting and less fragmentation
4. Layout variants allow tuning for different access patterns

**C3 impact (original):** The 3-part separate allocation tripled allocator pressure and hurt cache locality.

**Current state:** Property values and the dense array part now live in one `prop_alloc` block; small objects store up to 4 property values inline inside the object allocation. This matches Duktape's single-prop-block approach for the common case and removes the separate `array_part` malloc. The hash table remains a separate allocation for objects with more than 8 properties.

### 2.3 Array Exotic Behavior

Duktape's `duk_harray` stores `.length` as a plain integer field, not as a property table entry. The C3 port originally handled `.length` via the property table; it now stores `array_length` as trailing data after `HObjectBase` for array objects only, so `.length` access is O(1).

**Verdict:** The unified HObject approach was the single biggest performance divergence. Per-class allocation and inline property storage (plans 029–030) have closed most of the gap. The remaining heavy-workload memory differences are tracked in `plans/033-memory-next-steps.md`.

---

## 3. Garbage Collection — Implemented

| Aspect | Duktape | C3 Port |
|--------|---------|---------|
| Primary GC | **Reference counting** (immediate free on refcount=0) | Reference counting + immediate free on refcount=0 |
| Backup GC | Mark-and-sweep with generational trigger | Mark-and-sweep with allocation-count trigger |
| Deferred collection | Inline GC during allocation | GC deferred to VM safe points (CALL/RET/RETUNDEF) via `gc_pending` |
| In-flight protection | Refzero worklist | `temproot` flag protects objects allocated since the last safe point |
| String table GC | Weak references cleared during M&S | String sweeping at safe points; selective skip-interning reduces table pressure |
| Finalizer support | Full (finalize_list, rescue logic, NORESCUE) | Not implemented |
| GC torture mode | `DUK_GC_TORTURE` — runs GC after every alloc | Not present |
| Mark-and-sweep flags | `MS_FLAG_EMERGENCY`, `POSTPONE_RESCUE`, `NO_COMPACTION` | Emergency-only; no compaction/rescue yet |

**Current state:** The engine now runs non-trivial programs without leaking. Reference counting reclaims acyclic garbage immediately; mark-and-sweep handles cycles and bulk cleanup. GC is deferred to VM safe points (plan 032) to avoid freeing in-flight objects held only in C3 locals.

**Remaining gaps:** Finalizers, generational collection, and compaction are not implemented. Call-free allocation loops can still defer GC until the loop exits; see `plans/033-memory-next-steps.md` for the backward-jump safe-point follow-up.

**Verdict:** No longer a blocking issue. The current GC is sufficient for the implemented feature set.

---

## 4. Builtin Registration — Style Difference

| Aspect | Duktape | C3 Port |
|--------|---------|---------|
| Init method | Generated `duk_builtins.c` with binary blob (`duk_builtins_data`) + function pointer table (185 entries) | Manual `register_*_constructor()` functions per built-in |
| Data encoding | Compact binary format decoded at init time | Direct struct initialization |
| Method table | `duk_bi_native_functions[185]` array of C function pointers | `switch (ctx->builtin_fn_index)` dispatch in VM |
| Static methods | Registered via binary init data | Manually set as `LIGHTFUNC` properties on constructor |
| Prototype wiring | Init table assigns `.prototype` and `.constructor` by `bidx` (builtin index) | Manual property puts per constructor |
| ROM support | Optional read-only objects/strings for constrained systems | Not present |

**Example of C3 registration pattern (repetitive):**
```c3
// Every register_*_constructor does this exact pattern:
HObject* proto = hobject_alloc(heap, CLASS);
proto.prototype = null;                         // or Object.prototype
heap.X_proto = proto;                           // store in heap
register_string_proto_method(proto, heap, "method", BUILTIN_X_METHOD);
// ... more methods ...
HObject* ctor = hobject_alloc(heap, FUNCTION);
ctor.builtin_fn_index = BUILTIN_X;
proto.put_prop("constructor", ctor, WEC);
ctor.put_prop("prototype", proto, non-writable, non-enumerable, non-configurable);
ctor.put_prop("length", 1, WEC);
// plus static methods
// plus global registration
```

**Why Duktape does it this way:** The generated binary blob is compact and fast to load. The 185-entry function table allows O(1) dispatch by builtin index. ROM support allows storing builtins in read-only memory (flash) instead of RAM.

**C3 approach rationale:** Manual registration is more maintainable and debuggable. The per-function approach fits C3's module system better than a generated blob. However, the **boilerplate repetition** across 15+ register functions is a drag on development and a source of bugs.

**Verdict:** Acceptable but could benefit from a helper macro or code generation. The repetitive pattern of alloc-proto-setprototype-register-alloc-ctor-wire-register could be abstracted.

---

## 5. Promise — C3 is Ahead of Duktape

| Aspect | Duktape | C3 Port |
|--------|---------|---------|
| Constructor | **Stub** — throws "unimplemented" | Fully implemented: state machine, executor call |
| `.then()` | Stub | Implemented with reaction queue chaining |
| `.catch()` | Stub | Implemented (delegates to `.then()`) |
| `.finally()` | Not present | Implemented |
| `.resolve()` | Stub | Implemented |
| `.reject()` | Stub | Implemented |
| `.all()` | Stub | Implemented |
| `.race()` | Stub | Implemented |
| `.allSettled()` | Not present | Implemented |
| `.any()` | Not present | Implemented |
| State storage | N/A | `array_part[0]` = state enum, `array_part[1]` = result, `array_part[2+]` = capabilities |
| Microtask scheduling | N/A | Deferred |

**Notable:** Duktape v2.7.0 has `DUK_USE_PROMISE_BUILTIN` as a config flag, but all promise methods are stubs that throw TypeError. The C3 port's Promise is genuinely functional and more complete than Duktape's reference implementation.

**Concerns with C3 approach:** Storing Promise state in `array_part[0..N]` is fragile — it piggybacks on the generic array storage but accesses it by hardcoded index rather than named fields. If any code modifies the array_part (e.g., `Object.keys()`, property assignment on the promise object), the internal state is corrupted. Duktape would use a dedicated `duk_hpromise` struct with isolated fields.

**Verdict:** C3 is functionally ahead. However, the array_part-based state storage should be refactored into dedicated fields or a separate PromiseState struct to prevent corruption.

---

## 6. Symbol — Different Internal Representation

| Aspect | Duktape | C3 Port |
|--------|---------|---------|
| Internal storage | Buffer with 0x80/0x81 prefix byte, description, and unique hex suffix (`\xff%lx-%lx`) | HString with 0xFF prefix byte + `is_symbol` flag |
| Unique symbol counter | `sym_counter[2]` (heap-level, two 32-bit values) | Not found — appears to use heap symbol registry |
| Hidden symbols | Yes (`DUK_HSTRING_FLAG_HIDDEN`, bit 3) | No |
| `Symbol().toString()` | Produces `"Symbol(desc)"` format | Produces `"Symbol(desc)"` via `builtin_symbol_proto_toString` |
| Global registry | Heap-level key→symbol mapping | Same approach (`symbol_registry_keys/syms` arrays) |
| Prototype dispatch | `Symbol.prototype` objects have class `SYMBOL`; auto-unbox via `duk__auto_unbox_symbol` | Symbol STRING TVal's prototype routed via `get_builtin_prototype()` checking 0xFF prefix |
| Well-known symbols | `Symbol.iterator`, `Symbol.toStringTag`, etc. | `Symbol.iterator`, `Symbol.toStringTag`, and other commonly used well-known symbols registered |

**Key difference:** Duktape stores symbols as **buffer objects** (not strings) with a complex prefix encoding. The C3 port stores symbols as **HStrings** with a 0xFF prefix byte, which is simpler and reuses the existing string machinery. However, this means symbol strings pass through the string interning table, which may interact unexpectedly.

**Missing feature:** Duktape has **hidden symbols** (flag `DUK_HSTRING_FLAG_HIDDEN`) — symbols that don't appear in enumeration or `Object.keys()`. These are used for internal properties. The C3 port lacks this, which may matter for implementing internal metadata properties (e.g., Promise state hidden from user code).

**Verdict:** Acceptable for now. Well-known symbols needed by implemented features (iterators, for-of, toStringTag) are present. Hidden symbols are still missing and may be needed for internal metadata properties.

---

## 7. Map / Set / WeakMap / WeakSet — C3 Has Them, Duktape Doesn't

Duktape v2.7.0 does **not** include Map, Set, WeakMap, or WeakSet builtins. The native function table (`duk_bi_native_functions[185]`) contains no entries for them. The C3 port has complete implementations.

| Feature | Duktape | C3 Port |
|---------|---------|---------|
| Map constructor + prototype methods | Not present | ✅ (set, get, has, delete, clear, keys, values, entries, forEach) |
| Set constructor + prototype methods | Not present | ✅ (add, has, delete, clear, keys, values, entries, forEach) |
| WeakMap (Object-only keys) | Not present | ✅ (set, get, has, delete) |
| WeakSet (Object-only values) | Not present | ✅ (add, has, delete) |
| Internal storage | N/A | Map: `[k0,v0,k1,v1,...]` in array_part; Set: `[v0,v1,...]` |
| SameValueZero comparison | N/A | Used for key equality |

**Performance concern:** Map/Set operations scan `array_part` linearly. `map.get(key)` is O(n) where n is the number of entries. For large maps, this will be slow. Duktape would typically use a hash-table-based backing for Map/Set. The C3 port may need optimization for non-trivial Map usage.

**Verdict:** C3 is significantly ahead. The linear-scan Map/Set implementation is adequate for correctness but should be optimized to hash-based storage for performance.

---

## 8. Compiler — Same Architecture

| Aspect | Duktape | C3 Port |
|--------|---------|---------|
| Parsing approach | Recursive descent + operator precedence | Same |
| Bytecode generation | Direct generation (no AST) | Same |
| Passes | Multi-pass (declaration pre-scan, body compilation) | Same |
| Register allocation | `temp_first`/`temp_next`/`shreg`/`max_temp` | Same |
| Const/func tables | `consts[]`, `funcs[]` dynamic arrays | Same |
| Recursion limits | `DUK__RECURSION_INCREASE/DECREASE` | Same pattern |
| Instruction format | 32-bit fixed-width, A-B-C / A-BC / ABC / sBx | Same (`Instruction` bitstruct with identical layout) |

The C3 compiler is a faithful port of `duk_js_compiler.c`. No meaningful architectural differences beyond the C→C3 translation. The bytecode format is bit-identical. Instruction mnemonics and operand layouts are preserved.

**Verdict:** No correction needed.

---

## 9. Error Handling — C3 Feature Leverage

| Aspect | Duktape | C3 Port |
|--------|---------|---------|
| Control flow | `setjmp`/`longjmp` via `duk_jmpbuf` | C3 `faultdef`/`optionals` (`fn void*?`, `catch`, `try`) |
| Longjmp state | `duk_ljstate` (type + value1 + value2 + iserror) | `LongjmpState` struct (same fields) |
| Error types | Manual push-throw via `DUK_ERROR_TYPE()` macros | Fault codes (`TYPE_ERROR`, `RANGE_ERROR`, etc.) |
| Internal error objects | Manual construction + `duk_throw()` | Optional returns + `should_throw`/`throw_value` pattern |

Duktape's `setjmp`/`longjmp` approach is necessary in C where no exception mechanism exists. The C3 port uses C3's native optional return types (`TVal?`, `HObject*?`), which is cleaner and type-safe. The `faultdef` and `catch` syntax allows the compiler to enforce error handling at every call site.

**Example C3 pattern:**
```c3
HObject*? obj_raw = hobject_alloc(heap, CLASS);
if (catch err = obj_raw) {
    return false;  // allocation failed
}
HObject* obj = obj_raw;  // unwrapped, safe to use
```

**Verdict:** No correction. This is proper use of C3's type system. Keep this approach.

---

## 10. Bytecode VM — Minor Differences

| Aspect | Duktape | C3 Port |
|--------|---------|---------|
| Instruction format | 32-bit fixed width | Same (`Instruction` bitstruct) |
| Opcode dispatch | `switch(opcode)` in `duk_js_executor.c` | Same pattern in `vm.c3` |
| Call convention | A = nargs, BC = base register | Same |
| Activation structure | `duk_activation` on linked list + `duk_hthread` stacks | `Activation` on linked list |
| Catcher chain | `duk_catcher` linked list | `Catcher` linked list |
| Value stack | Growable array in `duk_hthread` | Flat array in `vm.c3` managed as Activation.bytes |
| Restart loop | Outer loop that restarts on ECMAScript-to-ECMAScript calls | Same approach |
| Yield/resume support | Built into `duk_hthread` with coroutines | Via `GeneratorState` struct |

The VM closely mirrors Duktape's executor. The activation record structure, opcode dispatch, call convention, and catcher chain are all faithful reproductions.

**Notable:** The C3 port uses byte offsets into a flat value stack (`bottom_byteoff`, `retval_byteoff`, `reserve_byteoff`) while Duktape uses pointer arithmetic on `duk_tval*`. The byte-offset approach is safer (bounds checks possible) but adds overhead (shift operations for every access).

**Verdict:** No correction needed. The byte-offset approach is a reasonable safety tradeoff.

---

## Summary: Priority of Corrections

| Priority | Area | Issue | Impact |
|----------|------|-------|--------|
| **🔴 Critical** | GC (Section 3) | No working garbage collection; every allocation leaks | **Functional blocker** — engine cannot run non-trivial programs |
| **🔴 Critical** | GC (Section 3) | String table entries never freed; no weak references | **Memory leak** — long-running programs exhaust memory |
| **🔴 High** | Property layout (Section 2.2) | 3 separate allocations per object instead of 1 | **Performance** — 3× allocator pressure, poor cache locality |
| **🟡 Medium** | Object model (Section 2.1) | Unified HObject wastes ~60 bytes per non-function object | **Memory waste** — ~30-50% overhead on most objects |
| **🟡 Medium** | Map/Set (Section 7) | O(n) linear scan for all Map/Set operations | **Performance** — doesn't scale past ~100 entries |
| **🟡 Medium** | Promise state (Section 5) | State stored in array_part by magic index | **Correctness risk** — user code can corrupt internal state |
| **🟢 Low** | Symbol (Section 6) | Missing hidden symbols for internal properties | **Feature gap** — needed for spec-compliant internal behavior |
| **🟢 Low** | Array .length (Section 2.3) | .length is a property lookup instead of direct field | **Performance** — every .length access is O(log n) |
| **🟢 Low** | String cache (Section 3) | Missing char-offset-to-byte-offset cache | **Performance** — non-ASCII string char access is O(n) |
| **🟢 Low** | Builtins boilerplate (Section 4) | Repetitive registration code across 15+ constructors | **Maintainability** — error-prone when wiring new builtins |

### Most impactful single fix

Implementing a unified property allocation layout (like Duktape's `DUK_HOBJECT_P_COMPUTE_SIZE` + single `DUK_ALLOC`) would:
1. Reduce 3 malloc calls to 1 per object resize
2. Improve property access cache locality
3. Enable array-part and entry-part to share cache lines
4. Make atomic resize possible (no partial-failure state)

Combined with basic mark-and-sweep GC, the engine would be viable for non-trivial workloads.

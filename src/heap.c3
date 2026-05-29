module duktape::heap;

import duktape::types;
import duktape::hstring;
import duktape::hobject;
import duktape::bytecode;
import std::io;
import libc;

// ============================================================================
// Heap management — allocator, GC bookkeeping, string table
// ============================================================================

// --- Allocator callback signatures ----------------------------------------

alias AllocFunc   = fn void*(void* udata, usz size);
alias ReallocFunc = fn void*(void* udata, void* ptr, usz size);
alias FreeFunc    = fn void(void* udata, void* ptr);
alias FatalFunc   = fn void(void* udata, char* msg);

// --- Faults ---------------------------------------------------------------

faultdef HEAP_ALLOC_FAULT;

// --- Constants ------------------------------------------------------------

const uint  INITIAL_STR_TABLE_SIZE  = 256;
const float STR_TABLE_LOAD_FACTOR   = 0.70;
const long  GC_INITIAL_TRIGGER      = 1024;
const long  GC_TRIGGER_GROW_FACTOR  = 2;
const int   GC_MARK_RECURSE_LIMIT   = 256;
const usz   STRS_CACHE_SIZE         = 256;
const uint  GC_MAX_ROOTS            = 128;

// --- LongjmpState ---------------------------------------------------------

enum LjType : char {
    UNKNOWN,
    THROW,
    YIELD,
    RESUME,
    BREAK,
    CONTINUE,
    RETURN,
    NORMAL,
}

struct LongjmpState {
    LjType   lj_type;
    TVal     value1;
    TVal     value2;
    bool     iserror;
}

// --- GeneratorState (ES6 §25.3) -------------------------------------------

/// Generator execution state per ES6 §25.3.3.1 GeneratorState.
enum GeneratorStateType : char {
    GEN_SUSPENDED_START,
    GEN_SUSPENDED_YIELD,
    GEN_EXECUTING,
    GEN_COMPLETED,
}

/// How a generator was resumed — determines what the YIELD opcode does
/// when execution reaches a yield point.
enum ResumeKind : char {
    NEXT,     /// .next() — yield returns IteratorResult as usual
    THROW,    /// .throw() — inject exception at yield point
    RETURN,   /// .return() — inject return at yield point
}

/// Saved execution context for a generator.
///
/// When a generator function is called, instead of executing the body
/// immediately, the VM saves the initial execution state in this struct
/// and returns a generator object.  Subsequent calls to .next(), .throw(),
/// or .return() resume execution from the saved state.
struct GeneratorState {
    GeneratorStateType state;
    void* func;               // CompiledFunction* (opaque to avoid circular deps)
    TVal* saved_regs;         // malloc'd array of register values
    uint num_regs;
    void* saved_pc;           // Instruction* (opaque)
    void* var_env;            // EnvRecord* (opaque)
    void* lex_env;            // EnvRecord* (opaque)
    TVal this_binding;
    TVal resume_value;        // value passed by .next()
    ResumeKind resume_kind;   // how the generator was resumed
    TVal throw_value;         // exception to inject (when resume_kind == THROW)
    TVal return_value;        // value to return (when resume_kind == RETURN)
    // yield* delegation state
    void* delegated_iter;     // HObject* — iterator being delegated to
    uint delegated_index;     // current index in delegation loop
}

// --- Heap struct ----------------------------------------------------------

struct Heap {
    // Allocator callbacks
    AllocFunc    alloc_func;
    ReallocFunc  realloc_func;
    FreeFunc     free_func;
    void*        heap_udata;
    FatalFunc    fatal_func;

    // Flags
    uint flags;

    // Object lists (doubly-linked via HeapHeader.next/.prev)
    HeapHeader*  heap_allocated;
    HeapHeader*  finalize_list;

    // String interning table (open-addressing)
    HString**    str_table;
    uint         str_table_size;
    uint         str_table_used;

    // Built-in strings cache (indexed by string constant IDs)
    void*[STRS_CACHE_SIZE]  strs;

    // GC state
    int   gc_mark_recurse_depth;
    int   gc_mark_recurse_limit;
    long  gc_trigger_counter;
    // gc_obj_count moved to gc_objects section below

    // Current execution thread (HThread*)
    void* curr_thread;

    // Longjmp state for error handling
    LongjmpState lj;

    // Simple xorshift32 PRNG state
    uint rnd_state;

    // Fixed hash seed (set at heap creation, never changes)
    uint hash_seed;

    // Built-in error prototypes (for builtin constructor dispatch)
    HObject* err_proto;
    HObject* type_err_proto;
    HObject* range_err_proto;
    HObject* ref_err_proto;
    HObject* syntax_err_proto;
    HObject* eval_err_proto;
    HObject* uri_err_proto;

    // Built-in constructor prototypes
    HObject* object_proto;
    HObject* bool_proto;
    HObject* string_proto;
    HObject* number_proto;
    HObject* array_proto;
    HObject* function_proto;
    HObject* date_proto;
    HObject* regexp_proto;
    HObject* map_proto;
    HObject* set_proto;
    HObject* weakmap_proto;
    HObject* weakset_proto;
    HObject* symbol_proto;
    HObject* promise_proto;
    HObject* generator_proto;

    // Generator resume state (set by .next()/.throw()/.return() builtins,
    // read by the VM CALL handler and YIELD/RET opcodes).
    GeneratorState* resume_gen;
    TVal yield_value;          /// Value yielded by YIELD opcode
    bool did_yield;            /// True when YIELD was just executed

    // Global symbol registry for Symbol.for / Symbol.keyFor
    HString** symbol_registry_keys;   /// Array of key HString* pointers
    HString** symbol_registry_syms;   /// Array of symbol HString* pointers
    uint      symbol_registry_count;  /// Number of entries
    uint      symbol_registry_cap;    /// Allocated capacity

    // Global checkpoint for __resetGlobals() — saves initial global state
    void**    checkpoint_keys;   /// Array of HString* pointers
    TVal*     checkpoint_vals;   /// Parallel array of TVal values
    uint      checkpoint_count;  /// Number of saved entries
    uint      checkpoint_cap;    /// Allocated capacity

    // GC object tracking — growable array of all heap-allocated objects
    // (avoiding linked-list pointer casts which cause safe-mode traps)
    void**    gc_objects;        /// Array of HeapHeader* pointers
    uint      gc_obj_cap;        /// Allocated capacity
    uint      gc_obj_count;      /// Number of live objects

    // CompiledFunction tracking — growable array of all CompiledFunction*
    // allocated through the compiler.  Freed in Heap.destroy.
    void**    compiled_funcs;    /// Array of CompiledFunction* pointers
    uint      compiled_func_cap; /// Allocated capacity
    uint      compiled_func_count; /// Number of tracked entries

    // GC root registration (pointers to always-reachable HeapHeader*)
    void*[GC_MAX_ROOTS] gc_roots;
    uint                gc_root_count;

    // GC re-entrancy guard
    bool                gc_running;
}

// ============================================================================
// Built-in string cache — pre-interned at heap creation
// ============================================================================

/// Indices into Heap.strs[] for frequently-used interned strings.
/// Eliminates repeated hash+lookup for these strings on every property
/// access, typeof, and error path.
enum BuiltinStr : uint {
    UNDEFINED,   // "undefined"
    OBJECT,      // "object"
    BOOLEAN,     // "boolean"
    NUMBER,      // "number"
    STRING,      // "string"
    FUNCTION,    // "function"
    TRUE,        // "true"
    FALSE,       // "false"
    NULL_STR,    // "null"
    MESSAGE,     // "message"
    PROTOTYPE,   // "prototype"
    CONSTRUCTOR, // "constructor"
    LENGTH,      // "length"
    VALUE,       // "value"
    DONE,        // "done"
    ARGUMENTS,   // "arguments"
}

// ============================================================================
// Default allocator functions (libc-backed)
// ============================================================================

fn void* default_alloc(void* udata, usz size) {
    if (size == 0) { return null; }
    return libc::malloc(size);
}

fn void* default_realloc(void* udata, void* ptr, usz size) {
    if (size == 0) {
        libc::free(ptr);
        return null;
    }
    return libc::realloc(ptr, size);
}

fn void default_free(void* udata, void* ptr) {
    libc::free(ptr);
}

fn void default_fatal(void* udata, char* msg) {
    io::eprintfn("DUKTAPE FATAL: %s", msg);
    libc::abort();
}

// ============================================================================
// Heap creation / destruction
// ============================================================================

/**
 * Allocate and initialise a brand-new Heap.
 *
 * If any allocator callback is `null` the corresponding default (libc)
 * version is used.  Returns a fault on allocation failure.
 */
fn Heap*? create(
    AllocFunc    a,
    ReallocFunc  r,
    FreeFunc     f,
    void*        udata,
    FatalFunc    fatal
) {
    // Resolve defaults
    AllocFunc   afn   = a     != null ? a     : &default_alloc;
    ReallocFunc rfn   = r     != null ? r     : &default_realloc;
    FreeFunc    ffn   = f     != null ? f     : &default_free;
    FatalFunc   fatfn = fatal != null ? fatal : &default_fatal;

    // Allocate the Heap struct itself through the chosen allocator
    void* raw = afn(udata, Heap::size);
    if (raw == null) {
        return HEAP_ALLOC_FAULT~;
    }

    Heap* h = (Heap*)raw;

    // Zero-fill the whole struct
    libc::memset(raw, 0, Heap::size);

    // Store allocator pointers
    h.alloc_func   = afn;
    h.realloc_func = rfn;
    h.free_func    = ffn;
    h.heap_udata   = udata;
    h.fatal_func   = fatfn;

    // GC tunables
    h.gc_mark_recurse_limit = GC_MARK_RECURSE_LIMIT;
    h.gc_trigger_counter    = GC_INITIAL_TRIGGER;

    // PRNG seed (non-zero required for xorshift32)
    h.rnd_state = 0xDEAD_BEEF;

    // Fixed hash seed (never changes after creation)
    h.hash_seed = h.rnd_state;

    // Allocate the initial string table
    usz tbl_bytes = HString*::size * INITIAL_STR_TABLE_SIZE;
    void* tbl_raw = afn(udata, tbl_bytes);
    if (tbl_raw == null) {
        ffn(udata, raw);
        return HEAP_ALLOC_FAULT~;
    }
    libc::memset(tbl_raw, 0, tbl_bytes);

    h.str_table      = (HString**)tbl_raw;
    h.str_table_size = INITIAL_STR_TABLE_SIZE;
    h.str_table_used = 0;

    // Pre-intern well-known strings
    h.init_builtin_strs();

    return h;
}

/// Pre-intern frequently-used strings into Heap.strs[].
/// Called once during heap creation.  Each string is hashed, looked up in
/// the string table, and allocated only if not already present — so this
/// is safe to call multiple times.
fn void Heap.init_builtin_strs(&self) {
    // Each entry: (ZString literal, byte length)
    ZString[16] literals = {
        "undefined", "object", "boolean", "number", "string", "function",
        "true", "false", "null", "message", "prototype", "constructor",
        "length", "value", "done", "arguments"
    };
    uint[16] lengths = { 9, 6, 7, 6, 6, 8, 4, 5, 4, 7, 9, 11, 6, 5, 4, 9 };
    for (uint i = 0; i < 16; i++) {
        char* ptr = (char*)literals[i];
        char[] data = ptr[:lengths[i]];
        uint h = self.hash_string(data);
        HString* existing = self.str_table_lookup(data, h);
        if (existing != null) {
            self.strs[i] = existing;
        } else {
            HString*? ns = hstring::hstring_alloc(self, data, h);
            if (try s = ns) {
                self.str_table_insert(s);
                self.strs[i] = s;
            }
        }
    }
}

/**
 * Destroy the heap: walk every managed object and release it, then free
 * the heap struct itself.
 */
fn void Heap.destroy(&self) {
    // Free all objects through the GC array
    for (uint i = 0; i < self.gc_obj_count; i++) {
        HeapHeader* cur = (HeapHeader*)self.gc_objects[i];
        if (cur != null && cur.is_object()) {
            hobject::hobject_free((HObject*)cur);
        }
    }
    libc::free(self.gc_objects);
    self.gc_objects = null;

    // Free all tracked CompiledFunction objects and their sub-arrays.
    if (self.compiled_funcs != null) {
        for (uint i = 0; i < self.compiled_func_count; i++) {
            bytecode::CompiledFunction* cf = (bytecode::CompiledFunction*)self.compiled_funcs[i];
            if (cf != null) {
                if (cf.code != null) { libc::free(cf.code); }
                if (cf.constants != null) { libc::free(cf.constants); }
                if (cf.inner_funcs != null) { libc::free(cf.inner_funcs); }
                if (cf.line_table != null) { libc::free(cf.line_table); }
                libc::free(cf);
            }
        }
        libc::free(self.compiled_funcs);
        self.compiled_funcs = null;
    }

    // Free all interned HStrings in the string table before freeing the table itself
    if (self.str_table != null) {
        for (uint i = 0; i < self.str_table_size; i++) {
            hstring::HString* s = self.str_table[i];
            if (s != null) {
                hstring::hstring_free(s);
            }
        }
        self.free_func(self.heap_udata, self.str_table);
        self.str_table = null;
    }

    // Finally free the Heap struct itself
    FreeFunc    ffn   = self.free_func;
    void*       udata = self.heap_udata;
    ffn(udata, self);
}

// ============================================================================
// CompiledFunction tracking
// ============================================================================

/**
 * Register a CompiledFunction* for cleanup when the heap is destroyed.
 * The compiler allocates CompiledFunctions via libc::malloc and they are not
 * tracked by the GC object array, so we need a separate list.
 */
fn void Heap.track_compiled_func(&self, void* cf) {
    if (cf == null) { return; }
    if (self.compiled_func_count >= self.compiled_func_cap) {
        uint new_cap = self.compiled_func_cap == 0 ? 64 : self.compiled_func_cap * 2;
        usz new_bytes = (usz)new_cap * void*::size;
        void* new_arr = libc::realloc(self.compiled_funcs, new_bytes);
        if (new_arr == null) { return; }
        self.compiled_funcs = (void**)new_arr;
        self.compiled_func_cap = new_cap;
    }
    self.compiled_funcs[self.compiled_func_count] = cf;
    self.compiled_func_count++;
}

// ============================================================================
// Low-level allocation with GC trigger
// ============================================================================

/**
 * Allocate `size` bytes through the heap's allocator.  Decrements the GC
 * trigger counter and fires a collection when it reaches zero.
 */
fn void*? Heap.alloc(&self, usz size) {
    self.gc_trigger_counter--;
    if (self.gc_trigger_counter <= 0) {
        self.trigger_gc();
    }

    void* ptr = self.alloc_func(self.heap_udata, size);
    if (ptr == null && size > 0) {
        // Emergency GC then retry once
        self.trigger_gc();
        ptr = self.alloc_func(self.heap_udata, size);
        if (ptr == null) {
            return HEAP_ALLOC_FAULT~;
        }
    }
    return ptr;
}

/**
 * Allocate a new HObject and register it with the heap's GC tracking list.
 *
 * This is the preferred way to create objects — it replaces raw calls to
 * hobject::hobject_alloc() by also inserting the object into the
 * heap_allocated list so that the mark-and-sweep collector can find it.
 *
 * Returns the new HObject or a fault on allocation failure.
 */
fn HObject*? Heap.alloc_object(&self, hobject::ObjClass cls) {
    HObject*? result = hobject::hobject_alloc((void*)self, cls);
    if (try obj = result) {
        // Track in the GC object array (avoids linked-list through
        // cast pointers which safe-mode forbids).
        if (self.gc_obj_count >= self.gc_obj_cap) {
            uint new_cap = self.gc_obj_cap == 0 ? 256 : self.gc_obj_cap * 2;
            usz new_bytes = (usz)new_cap * void*::size;
            void* new_arr = libc::realloc(self.gc_objects, new_bytes);
            if (new_arr == null) {
                // Can't track, but object is still allocated
                return result;
            }
            self.gc_objects = (void**)new_arr;
            self.gc_obj_cap = new_cap;
        }
        self.gc_objects[self.gc_obj_count] = (void*)obj;
        self.gc_obj_count++;
    }
    return result;
}

/**
 * Reallocate a block through the heap's allocator, with GC trigger.
 */
fn void*? Heap.realloc(&self, void* ptr, usz new_size) {
    self.gc_trigger_counter--;
    if (self.gc_trigger_counter <= 0) {
        self.trigger_gc();
    }

    void* new_ptr = self.realloc_func(self.heap_udata, ptr, new_size);
    if (new_ptr == null && new_size > 0) {
        self.trigger_gc();
        new_ptr = self.realloc_func(self.heap_udata, ptr, new_size);
        if (new_ptr == null) {
            return HEAP_ALLOC_FAULT~;
        }
    }
    return new_ptr;
}

/**
 * Free a block through the heap's allocator.
 */
fn void Heap.free(&self, void* ptr) {
    self.free_func(self.heap_udata, ptr);
}

// ============================================================================
// Managed-object linked-list operations (doubly-linked via HeapHeader)
// ============================================================================

/**
 * Insert `hdr` at the head of the heap_allocated doubly-linked list.
 * Uses HeapHeader.init() to wire up next/prev pointers.
 * NOTE: This is currently unused in favor of the array-based gc_objects
 * tracking.  Kept for compatibility.
 */
fn void Heap.insert_into_heap_allocated(&self, HeapHeader* hdr) {
    hdr.init(hdr.get_type(), &self.heap_allocated);
}

/**
 * Remove `hdr` from the heap_allocated doubly-linked list.
 * Uses HeapHeader.unlink() for O(1) removal.
 */
fn void Heap.remove_from_heap_allocated(&self, HeapHeader* hdr) {
    hdr.unlink(&self.heap_allocated);
}

/**
 * Insert `hdr` at the head of the heap_allocated list without calling
 * HeapHeader.init(), preserving any flags already set by the caller.
 *
 * This is the safe path for tracked objects where the subtype (HObject,
 * HString) has already set its flags and we only need the linked-list
 * wiring.  Use insert_into_heap_allocated() when a full header init is
 * desired (e.g. raw HeapHeader allocations).
 */
fn void Heap.insert_into_heap_allocated_preserve_flags(&self, HeapHeader* hdr) {
    hdr.prev = null;
    hdr.next = self.heap_allocated;
    if (self.heap_allocated != null) {
        self.heap_allocated.prev = hdr;
    }
    self.heap_allocated = hdr;
}

/**
 * Insert `hdr` at the head of the finalize_list doubly-linked list.
 */
fn void Heap.insert_into_finalize_list(&self, HeapHeader* hdr) {
    // Re-link into finalize_list — set the finalizable flag.
    hdr.set_finalizable();
    hdr.next = self.finalize_list;
    hdr.prev = null;
    if (self.finalize_list != null) {
        self.finalize_list.prev = hdr;
    }
    self.finalize_list = hdr;
}

/**
 * Remove `hdr` from the finalize_list doubly-linked list.
 */
fn void Heap.remove_from_finalize_list(&self, HeapHeader* hdr) {
    hdr.unlink(&self.finalize_list);
}

// ============================================================================
// GC root registration
// ============================================================================

/**
 * Register a heap object as a GC root.  Root objects are always treated as
 * reachable during mark-and-sweep, preventing them from being freed.
 */
fn void Heap.register_gc_root(&self, HeapHeader* hdr) {
    if (self.gc_root_count < GC_MAX_ROOTS) {
        self.gc_roots[self.gc_root_count] = (void*)hdr;
        self.gc_root_count++;
    }
}

// ============================================================================
// GC marking helpers
// ============================================================================

/**
 * Mark a TVal value as reachable.  If the value holds a heap-allocated
 * object (OBJECT or STRING tag), the pointed-to object is marked.
 */
fn void Heap.mark_tval(&self, TVal* v, int depth) {
    if (v.is_object()) {
        HObject* obj = (HObject*)v.get_heapptr();
        if (obj != null) {
            self.mark_object(obj, depth + 1);
        }
    } else if (v.is_string()) {
        HString* s = (HString*)v.get_heapptr();
        if (s != null) {
            HeapHeader* hdr = (HeapHeader*)s;
            hdr.set_reachable();
        }
    }
}

/**
 * Recursively mark an HObject and all objects reachable from it.
 * Uses a depth limit to prevent C-stack overflow on deeply nested
 * prototype chains or property graphs.
 */
fn void Heap.mark_object(&self, HObject* obj, int depth) {
    if (obj == null) { return; }

    HeapHeader* hdr = (HeapHeader*)obj;
    if (hdr.is_reachable()) { return; }
    hdr.set_reachable();

    if (depth > GC_MARK_RECURSE_LIMIT) { return; }

    // Mark prototype chain
    if (obj.prototype != null) {
        self.mark_object(obj.prototype, depth + 1);
    }

    // Mark property keys (HString*) and values (TVal)
    for (uint i = 0; i < obj.prop_count; i++) {
        HString* key = (HString*)obj.props[i].key;
        if (key != null) {
            ((HeapHeader*)key).set_reachable();
        }
        self.mark_tval(&obj.props[i].value, depth);
        self.mark_tval(&obj.props[i].getter, depth);
        self.mark_tval(&obj.props[i].setter, depth);
    }

    // Mark array part values
    if (obj.array_part != null) {
        for (uint i = 0; i < obj.array_size; i++) {
            self.mark_tval(&obj.array_part[i], depth);
        }
    }

    // Mark primitive value (wrapper objects like Boolean, Number, String)
    self.mark_tval(&obj.primitive_value, depth);

    // Mark environment bindings (var_env and lex_env)
    if (obj.var_env != null && obj.var_env.bindings != null) {
        self.mark_object(obj.var_env.bindings, depth + 1);
    }
    if (obj.lex_env != null && obj.lex_env.bindings != null) {
        self.mark_object(obj.lex_env.bindings, depth + 1);
    }

    // Mark CompiledFunction constants (may contain objects/strings).
    // The comp_func field type (CompiledFunction*) is defined in bytecode.c3
    // and its fields are not directly accessible here without circular imports.
    // Constants are typically numbers/booleans/strings; string constants are
    // already reachable through the string table marking below.
    // TODO: add a helper in bytecode.c3 to mark constants and inner funcs.
}

/**
 * Mark all GC roots: registered roots, built-in prototypes, and the
 * entire string table (to keep interned strings alive).
 */
fn void Heap.mark_roots(&self) {
    // Mark all registered roots
    for (uint i = 0; i < self.gc_root_count; i++) {
        HeapHeader* hdr = (HeapHeader*)self.gc_roots[i];
        if (hdr != null) {
            if (hdr.is_object()) {
                self.mark_object((HObject*)hdr, 0);
            } else {
                hdr.set_reachable();
            }
        }
    }

    // Mark built-in error prototypes
    if (self.err_proto != null) { self.mark_object(self.err_proto, 0); }
    if (self.type_err_proto != null) { self.mark_object(self.type_err_proto, 0); }
    if (self.range_err_proto != null) { self.mark_object(self.range_err_proto, 0); }
    if (self.ref_err_proto != null) { self.mark_object(self.ref_err_proto, 0); }
    if (self.syntax_err_proto != null) { self.mark_object(self.syntax_err_proto, 0); }
    if (self.eval_err_proto != null) { self.mark_object(self.eval_err_proto, 0); }
    if (self.uri_err_proto != null) { self.mark_object(self.uri_err_proto, 0); }

    // Mark built-in constructor prototypes
    if (self.object_proto != null) { self.mark_object(self.object_proto, 0); }
    if (self.array_proto != null) { self.mark_object(self.array_proto, 0); }
    if (self.function_proto != null) { self.mark_object(self.function_proto, 0); }
    if (self.string_proto != null) { self.mark_object(self.string_proto, 0); }
    if (self.number_proto != null) { self.mark_object(self.number_proto, 0); }
    if (self.bool_proto != null) { self.mark_object(self.bool_proto, 0); }
    if (self.date_proto != null) { self.mark_object(self.date_proto, 0); }
    if (self.regexp_proto != null) { self.mark_object(self.regexp_proto, 0); }
    if (self.map_proto != null) { self.mark_object(self.map_proto, 0); }
    if (self.set_proto != null) { self.mark_object(self.set_proto, 0); }
    if (self.weakmap_proto != null) { self.mark_object(self.weakmap_proto, 0); }
    if (self.weakset_proto != null) { self.mark_object(self.weakset_proto, 0); }
    if (self.symbol_proto != null) { self.mark_object(self.symbol_proto, 0); }
    if (self.promise_proto != null) { self.mark_object(self.promise_proto, 0); }
    if (self.generator_proto != null) { self.mark_object(self.generator_proto, 0); }

    // Mark all strings in the string table as reachable
    // (prevents string collection — can be refined later)
    for (uint i = 0; i < self.str_table_size; i++) {
        HString* s = self.str_table[i];
        if (s != null) {
            ((HeapHeader*)s).set_reachable();
        }
    }

    // Mark symbol registry entries
    for (uint i = 0; i < self.symbol_registry_count; i++) {
        HString* key = self.symbol_registry_keys[i];
        HString* sym = self.symbol_registry_syms[i];
        if (key != null) { ((HeapHeader*)key).set_reachable(); }
        if (sym != null) { ((HeapHeader*)sym).set_reachable(); }
    }

    // Mark built-in cached strings
    for (uint i = 0; i < STRS_CACHE_SIZE; i++) {
        HString* s = (HString*)self.strs[i];
        if (s != null) {
            ((HeapHeader*)s).set_reachable();
        }
    }

    // Mark global checkpoint keys
    for (uint i = 0; i < self.checkpoint_count; i++) {
        HString* key = (HString*)self.checkpoint_keys[i];
        if (key != null) { ((HeapHeader*)key).set_reachable(); }
    }
}

// ============================================================================
// GC sweep
// ============================================================================

/**
 * Sweep phase: walk the heap_allocated list and free every object that
 * was NOT marked reachable during the mark phase.  Clears the reachable
 * flag on surviving objects for the next cycle.
 */
fn void Heap.sweep(&self) {
    uint kept = 0;
    for (uint i = 0; i < self.gc_obj_count; i++) {
        HeapHeader* hdr = (HeapHeader*)self.gc_objects[i];
        if (hdr == null) { continue; }

        if (!hdr.is_reachable()) {
            // Free this object
            if (hdr.is_object()) {
                hobject::hobject_free((HObject*)hdr);
            } else if (hdr.is_string()) {
                libc::free(hdr);
            } else {
                self.free_func(self.heap_udata, hdr);
            }
            // Removed from array (will be overwritten by kept compaction)
        } else {
            // Keep — clear mark bit for next cycle
            hdr.clear_reachable();
            self.gc_objects[kept] = self.gc_objects[i];
            kept++;
        }
    }
    self.gc_obj_count = kept;
}

// ============================================================================
// Garbage collection — mark-and-sweep
// ============================================================================

/**
 * Run a full mark-and-sweep garbage collection.
 *
 * 1. Clear all reachable flags.
 * 2. Mark all reachable objects starting from roots (built-in prototypes,
 *    registered GC roots, and the string table).
 * 3. Sweep unmarked (unreachable) objects, freeing their memory.
 * 4. Reset the GC trigger counter based on the new live-object count.
 *
 * Re-entrancy is prevented by the gc_running guard.
 */
fn void Heap.mark_and_sweep(&self) {
    if (self.gc_running) { return; }
    self.gc_running = true;

    // --- Phase 1: Clear all reachable flags ---
    for (uint i = 0; i < self.gc_obj_count; i++) {
        HeapHeader* cur = (HeapHeader*)self.gc_objects[i];
        if (cur != null) {
            cur.clear_reachable();
        }
    }

    // --- Phase 2: Mark from roots ---
    self.mark_roots();

    // --- Phase 3: Sweep ---
    self.sweep();

    // --- Phase 4: Reset trigger counter ---
    long new_trigger = (long)self.gc_obj_count * GC_TRIGGER_GROW_FACTOR;
    if (new_trigger < GC_INITIAL_TRIGGER) {
        new_trigger = GC_INITIAL_TRIGGER;
    }
    self.gc_trigger_counter = new_trigger;
    self.gc_running = false;
}

/**
 * Trigger a mark-and-sweep GC pass.  Called automatically when the
 * allocation counter reaches zero.
 */
fn void Heap.trigger_gc(&self) {
    self.mark_and_sweep();
}

// ============================================================================
// String hashing (FNV-1a, 32-bit)
// ============================================================================

const uint FNV1A_OFFSET_BASIS = 0x811C_9DC5;
const uint FNV1A_PRIME        = 0x0100_0193;

/**
 * Compute a 32-bit FNV-1a hash of `data`.  Mixes in the heap's random
 * state for HashDoS mitigation.
 */
fn uint Heap.hash_string(&self, char[] data) {
    uint h = FNV1A_OFFSET_BASIS ^ self.hash_seed;
    foreach (b : data) {
        h ^= (uint)b;
        h *= FNV1A_PRIME;
    }
    return h;
}

// ============================================================================
// String table (open-addressing, linear probing)
// ============================================================================

/**
 * Grow the string table when the load factor exceeds the threshold.
 * Rehashes every live entry into the new table.
 */
fn void*? Heap.str_table_grow(&self) {
    uint new_size = self.str_table_size * 2;
    if (new_size < INITIAL_STR_TABLE_SIZE) {
        new_size = INITIAL_STR_TABLE_SIZE;
    }

    usz new_bytes = HString*::size * new_size;
    void* raw = self.alloc_func(self.heap_udata, new_bytes);
    if (raw == null) {
        return HEAP_ALLOC_FAULT~;
    }
    libc::memset(raw, 0, new_bytes);

    HString** new_table = (HString**)raw;

    // Rehash existing entries
    for (uint i = 0; i < self.str_table_size; i++) {
        HString* entry = self.str_table[i];
        if (entry == null) { continue; }

        uint idx = entry.hash & (new_size - 1);
        while (new_table[idx] != null) {
            idx = (idx + 1) & (new_size - 1);
        }
        new_table[idx] = entry;
    }

    // Free old table, swap in the new one
    self.free_func(self.heap_udata, self.str_table);
    self.str_table      = new_table;
    self.str_table_size = new_size;

    return raw;  // non-null signals success
}

/**
 * Look up an interned string by raw byte content and precomputed hash.
 * Returns the existing HString or `null` if not found.
 */
fn HString* Heap.str_table_lookup(&self, char[] data, uint hash) {
    if (self.str_table_size == 0) { return null; }

    uint idx = hash & (self.str_table_size - 1);

    for (uint probes = 0; probes < self.str_table_size; probes++) {
        HString* entry = self.str_table[idx];
        if (entry == null) {
            return null;  // empty slot — not present
        }

        if (entry.hash == hash && entry.blen == (uint)data.len) {
            if (entry.equals(data)) {
                return entry;
            }
        }

        idx = (idx + 1) & (self.str_table_size - 1);
    }
    return null;
}

/**
 * Insert a fully initialised HString (with .hash set) into the string
 * table.  Grows the table first if the load factor is too high.
 */
fn void Heap.str_table_insert(&self, HString* hstr) {
    // Grow if necessary
    float load = (float)(self.str_table_used + 1) / (float)self.str_table_size;
    if (load > STR_TABLE_LOAD_FACTOR) {
        // Best-effort grow; if it fails we still insert into the
        // existing table (it will just be slower).
        void* ignored = self.str_table_grow() ?? null;
    }

    uint idx = hstr.hash & (self.str_table_size - 1);
    while (self.str_table[idx] != null) {
        idx = (idx + 1) & (self.str_table_size - 1);
    }
    self.str_table[idx] = hstr;
    self.str_table_used++;
}

// ============================================================================
// PRNG (xorshift32)
// ============================================================================

/**
 * Advance the heap's xorshift32 PRNG and return the new state.
 */
fn uint Heap.xorshift32(&self) {
    uint x = self.rnd_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    self.rnd_state = x;
    return x;
}

// ============================================================================
// Internal helpers
// ============================================================================

/**
 * Walk a doubly-linked HeapHeader list and free every node through the
 * heap's allocator.  The caller must null the list head afterwards.
 */
fn void Heap.free_header_list(&self, HeapHeader* list) {
    HeapHeader* cur = list;
    while (cur != null) {
        HeapHeader* nxt = cur.next;
        // In a full implementation this would dispatch on h_type to
        // free type-specific payloads first.
        self.free_func(self.heap_udata, cur);
        cur = nxt;
    }
}

module duktape::heap;

import duktape::types;
import duktape::hstring;
import duktape::hobject;
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
    uint  gc_obj_count;

    // Current execution thread (HThread*)
    void* curr_thread;

    // Longjmp state for error handling
    LongjmpState lj;

    // Simple xorshift32 PRNG state
    uint rnd_state;

    // Built-in error prototypes (for builtin constructor dispatch)
    HObject* err_proto;
    HObject* type_err_proto;
    HObject* range_err_proto;
    HObject* ref_err_proto;
    HObject* syntax_err_proto;
    HObject* eval_err_proto;

    // Built-in constructor prototypes
    HObject* bool_proto;
    HObject* string_proto;
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

    return h;
}

/**
 * Destroy the heap: walk every managed object and release it, then free
 * the heap struct itself.
 */
fn void Heap.destroy(&self) {
    // Free all objects on the finalize list
    self.free_header_list(self.finalize_list);
    self.finalize_list = null;

    // Free all objects on the main heap-allocated list
    self.free_header_list(self.heap_allocated);
    self.heap_allocated = null;

    // Free the string table array
    if (self.str_table != null) {
        self.free_func(self.heap_udata, self.str_table);
        self.str_table = null;
    }

    // Finally free the Heap struct itself
    FreeFunc    ffn   = self.free_func;
    void*       udata = self.heap_udata;
    ffn(udata, self);
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
 */
fn void Heap.insert_into_heap_allocated(&self, HeapHeader* hdr) {
    hdr.init(hdr.get_type(), &self.heap_allocated);
    self.gc_obj_count++;
}

/**
 * Remove `hdr` from the heap_allocated doubly-linked list.
 * Uses HeapHeader.unlink() for O(1) removal.
 */
fn void Heap.remove_from_heap_allocated(&self, HeapHeader* hdr) {
    hdr.unlink(&self.heap_allocated);
    if (self.gc_obj_count > 0) { self.gc_obj_count--; }
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
// Garbage collection (stub)
// ============================================================================

/**
 * Trigger a mark-and-sweep GC pass.  Currently a stub that resets the
 * trigger counter; the full implementation lives in a future gc.c3 module.
 */
fn void Heap.trigger_gc(&self) {
    // TODO: implement full mark-and-sweep.
    // For now simply reset the counter based on the live object count.
    long new_trigger = (long)self.gc_obj_count * GC_TRIGGER_GROW_FACTOR;
    if (new_trigger < GC_INITIAL_TRIGGER) {
        new_trigger = GC_INITIAL_TRIGGER;
    }
    self.gc_trigger_counter = new_trigger;
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
    uint h = FNV1A_OFFSET_BASIS ^ self.rnd_state;
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

/// Duktape object (HObject) — the core ECMAScript object representation.
///
/// HObjects model all ECMAScript ordinary and exotic objects.  Each object
/// has:
///   - A HeapHeader-compatible prefix (flags, refcount, GC list pointers).
///   - A prototype chain link.
///   - A property table with both a hash part (for fast named-property
///     lookup) and a linear entry array.
///   - An optional dense array part for integer-indexed properties in the
///     range [0, array_size).  This avoids creating heavyweight PropEntry
///     records for the overwhelmingly common case of dense JS arrays.
///
/// Property lookup logic:
///   1. If the property key is an interned string that represents a valid
///      array index < array_size, check array_part first.
///   2. If a hash table exists (hash_size > 0), hash the key pointer,
///      probe the hash table for an index into the props array, then
///      compare keys.
///   3. Otherwise fall back to a linear scan of the props array.
///
/// The hash table stores uint indices into the props array.  A sentinel
/// value (HASH_UNUSED / HASH_DELETED) marks empty or tombstone slots.
module duktape::hobject;

import duktape::types;
import duktape::hstring;
import duktape::bytecode;
import duktape::env;
import duktape::re_bindings;
import libc;

// Faults for optional returns
faultdef PROP_NOT_FOUND;
faultdef OBJ_ALLOC_FAULT;

// ============================================================================
// Constants
// ============================================================================

/// Initial number of property entry slots when first allocated.
const uint PROPS_INITIAL_CAPACITY = 8;

/// Initial dense array allocation size.
const uint ARRAY_INITIAL_SIZE = 16;

/// Growth factor numerator / denominator for property table (3/2 = 1.5×).
const uint PROPS_GROW_NUM = 3;
const uint PROPS_GROW_DEN = 2;

/// Minimum property count before a hash table is created.  Below this
/// threshold linear scan is fast enough.
const uint HASH_MIN_PROPS = 8;

/// Hash table load factor threshold (num / den).  When prop_count exceeds
/// hash_size * HASH_LOAD_NUM / HASH_LOAD_DEN, the table is rebuilt.
const uint HASH_LOAD_NUM = 7;
const uint HASH_LOAD_DEN = 10;

/// Sentinel value in the hash table: slot has never been used.
const uint HASH_UNUSED   = 0xFFFF_FFFF;

/// Sentinel value in the hash table: slot was deleted (tombstone).
const uint HASH_DELETED  = 0xFFFF_FFFE;

/// FNV-1a constants (used to hash pointer values for the property hash).
const uint FNV1A_OFFSET_BASIS = 0x811C_9DC5;
const uint FNV1A_PRIME        = 0x0100_0193;

// ============================================================================
// ObjClass — ECMAScript internal [[Class]]
// ============================================================================

/// Discriminator for the various ECMAScript object classes.
///
/// Encoded in 5 bits inside ObjFlags (up to 32 classes).
enum ObjClass : char {
    NONE,
    OBJECT,
    ARRAY,
    FUNCTION,
    ARGUMENTS,
    BOOLEAN,
    DATE,
    ERROR,
    JSON,
    MATH,
    NUMBER,
    REGEXP,
    STRING,
    GLOBAL,
    SYMBOL,
    /// Object environment record (ES spec).
    OBJENV,
    /// Declarative environment record (ES spec).
    DECENV,
    POINTER,
    THREAD,
    PROXY,
    ARRAYBUFFER,
    DATAVIEW,
    INT8ARRAY,
    UINT8ARRAY,
    UINT8CLAMPEDARRAY,
    INT16ARRAY,
    UINT16ARRAY,
    INT32ARRAY,
    UINT32ARRAY,
    FLOAT32ARRAY,
    FLOAT64ARRAY,
    MAP,
    SET,
    WEAKMAP,
    WEAKSET,
}

// ============================================================================
// ObjFlags — per-object bit-packed flags
// ============================================================================

/// Bit-packed flags word for HObject.
///
/// Bits 0–6 are reserved for HeapHeader-compatible type / GC bits so that
/// a raw cast from HObject* to HeapHeader* reads the correct htype and
/// mark bits.  Bits 7+ carry object-specific metadata.
bitstruct ObjFlags : uint {
    /// HeapHeader-compatible type discriminator (always HType.OBJECT).
    HType htype            : 0..1;
    /// GC reachable flag.
    bool  reachable        : 2;
    /// GC temporary root flag.
    bool  temproot         : 3;
    /// Finaliser present flag.
    bool  finalizable      : 4;
    /// Finaliser already ran.
    bool  finalized        : 5;
    /// Read-only flag.
    bool  readonly         : 6;

    // --- Object-specific flags (bits 7+) ---

    /// [[Extensible]] internal slot.
    bool extensible        : 7;
    /// Object can be used as a constructor (has [[Construct]]).
    bool constructable     : 8;
    /// Object is callable (has [[Call]]).
    bool callable          : 9;
    /// Bound function (created by Function.prototype.bind).
    bool is_bound          : 10;
    /// Object has an attached C/JS finalizer.
    bool has_finalizer     : 11;
    /// Exotic [[DefineOwnProperty]] for Array objects.
    bool exotic_array      : 12;
    /// Exotic behaviour for String wrapper objects.
    bool exotic_stringobj  : 13;
    /// Exotic behaviour for Arguments objects.
    bool exotic_arguments  : 14;
    /// Exotic behaviour for Proxy objects.
    bool exotic_proxyobj   : 15;
    /// Internal [[Class]] tag (6 bits → up to 64 classes).
    ObjClass obj_class     : 16..21;
}

// ============================================================================
// PropFlags — per-property attribute bits
// ============================================================================

/// ECMAScript property descriptor attribute flags.
///
/// Matches the spec's [[Writable]], [[Enumerable]], [[Configurable]]
/// attributes plus an accessor flag.
bitstruct PropFlags : char {
    /// Property value can be changed.
    bool writable     : 0;
    /// Property appears in for-in and Object.keys().
    bool enumerable   : 1;
    /// Property can be deleted and its attributes changed.
    bool configurable : 2;
    /// When true the property is an accessor (getter/setter pair) rather
    /// than a data property.
    bool is_accessor  : 3;
}

/// Convenience constant: default flags for a normal data property created
/// by assignment (writable, enumerable, configurable).
const PropFlags PROP_FLAGS_WEC = {
    .writable     = true,
    .enumerable   = true,
    .configurable = true,
    .is_accessor  = false
};

/// Convenience constant: non-enumerable data property (writable, configurable).
/// Used for built-in prototype methods per ES5 spec.
const PropFlags PROP_FLAGS_WC = {
    .writable     = true,
    .enumerable   = false,
    .configurable = true,
    .is_accessor  = false
};

/// Convenience constant: non-writable data property (enumerable, configurable).
/// Used for `const` bindings to prevent reassignment.
const PropFlags PROP_FLAGS_EC = {
    .writable     = false,
    .enumerable   = true,
    .configurable = true,
    .is_accessor  = false
};

// ============================================================================
// PropEntry — a single named property
// ============================================================================

/// A named property stored in the object's property table.
///
/// For data properties, `value` holds the property value and `getter` /
/// `setter` are unused (left as undefined).  For accessor properties
/// (flags.is_accessor == true), `getter` and `setter` hold the accessor
/// functions and `value` is unused.
struct PropEntry {
    /// Interned property key (HString*).  Pointer equality is sufficient
    /// for comparison because all keys are interned.
    void*     key;
    /// Data property value, or undefined for accessor properties.
    TVal      value;
    /// Getter function (only meaningful when flags.is_accessor is true).
    TVal      getter;
    /// Setter function (only meaningful when flags.is_accessor is true).
    TVal      setter;
    /// Property attribute flags.
    PropFlags flags;
}

// ============================================================================
// HObject — the core heap-allocated object
// ============================================================================

/// The core ECMAScript object representation.
///
/// Memory layout is chosen so that the first four fields (flags, refcount,
/// next, prev) are binary-compatible with HeapHeader, allowing a raw cast
/// for the GC's linked-list walk.
struct HObject {
    // --- Inline HeapHeader ------------------------------------------------
    /// Combined HeapHeader-compatible + object-specific flags.
    ObjFlags      flags;
    /// Reference count.
    uint          refcount;
    /// Next heap object in the GC linked list.
    HeapHeader*   next;
    /// Previous heap object in the GC linked list.
    HeapHeader*   prev;

    // --- Prototype --------------------------------------------------------
    /// Prototype object ([[Prototype]] internal slot).  null for the root
    /// of the prototype chain (e.g., Object.prototype).
    HObject*      prototype;

    // --- Named property storage ------------------------------------------
    /// Flat array of property entries.
    PropEntry*    props;
    /// Hash lookup table: each slot holds an index into `props`, or one of
    /// the HASH_UNUSED / HASH_DELETED sentinels.
    uint*         hash_table;
    /// Number of property entries currently in use.
    uint          prop_count;
    /// Allocated capacity of the `props` array.
    uint          prop_capacity;
    /// Number of slots in `hash_table` (0 means no hash — use linear scan).
    uint          hash_size;

    // --- Dense array part ------------------------------------------------
    /// Dense array storage for integer-indexed properties [0, array_size).
    TVal*         array_part;
    /// Allocated size (in TVal slots) of `array_part`.
    uint          array_size;
    /// Number of slots actually holding a defined value.
    uint          array_used;

    // --- Primitive wrapper storage (for Boolean, Number, String objects) ---
    /// Stores the [[PrimitiveValue]] for wrapper/exotic objects.
    /// For BOOLEAN: tag=BOOLEAN, .boolean = value.
    /// For NUMBER: tag=NUMBER/.FASTINT, .number/.fastint = value.
    /// For STRING: tag=STRING, .pointer = HString*.
    TVal          primitive_value;

    // --- Compiled function support (non-null for JS functions) -----------
    /// The compiled function template (null for non-function objects).
    CompiledFunction* comp_func;
    /// Captured variable environment (for closures).
    EnvRecord*    var_env;
    /// Captured lexical environment (for closures).
    EnvRecord*    lex_env;

    /// Builtin function index for native built-in functions (e.g., Number, Object).
    /// -1 when this object is not a native builtin function.
    int           builtin_fn_index;

    /// Compiled regexp bytecode pointer (only for REGEXP class objects).
    /// Allocated by libregexp, freed via re_free().
    void*         regexp_data;
}

// ============================================================================
// HObject — HeapHeader-compatible helpers
// ============================================================================

/// Returns a HeapHeader pointer to this object (binary-compatible cast).
fn HeapHeader* HObject.as_header(&self) @inline {
    return (HeapHeader*)self;
}

/// Increments the reference count.
fn void HObject.incref(&self) {
    self.refcount++;
}

/// Decrements the reference count and returns the new value.
fn uint HObject.decref(&self) {
    self.refcount--;
    return self.refcount;
}

// ============================================================================
// HObject — flag accessors
// ============================================================================

/// Returns the object's [[Class]].
fn ObjClass HObject.get_class(&self)    { return self.flags.obj_class; }

/// Returns true when the object is [[Extensible]].
fn bool HObject.is_extensible(&self)    { return self.flags.extensible; }

/// Returns true when the object is callable.
fn bool HObject.is_callable(&self)      { return self.flags.callable; }

/// Returns true when the object can be used as a constructor.
fn bool HObject.is_constructable(&self) { return self.flags.constructable; }

/// Returns true when the object is a bound function.
fn bool HObject.is_bound(&self)         { return self.flags.is_bound; }

/// Seal the object: clear extensible, mark all own properties as
/// non-configurable.
fn void HObject.seal(&self) {
    self.flags.extensible = false;
    for (uint i = 0; i < self.prop_count; i++) {
        self.props[i].flags.configurable = false;
    }
}

/// Freeze the object: seal + mark all data properties non-writable.
fn void HObject.freeze(&self) {
    self.seal();
    for (uint i = 0; i < self.prop_count; i++) {
        if (!self.props[i].flags.is_accessor) {
            self.props[i].flags.writable = false;
        }
    }
}

// ============================================================================
// Internal: pointer hashing
// ============================================================================

/// Hash a pointer value to produce an index into the hash table.
///
/// We use a simple integer hash (xor-shift mix) of the pointer bits.  Since
/// property keys are interned HStrings, pointer identity == string equality,
/// so hashing the pointer is correct.
fn uint hash_key(void* key) @inline {
    uint h = (uint)((usz)key);
    // Murmur3-style finalizer mix
    h ^= h >> 16;
    h *= 0x85EB_CA6B;
    h ^= h >> 13;
    h *= 0xC2B2_AE35;
    h ^= h >> 16;
    return h;
}

// ============================================================================
// HObject — property index lookup
// ============================================================================

/// Find the index of the property with the given interned key in the props
/// array.
///
/// Returns the index (≥ 0) on success, or -1 if the key is not found.
/// Uses the hash table when available, otherwise falls back to linear scan.
fn int HObject.find_prop_idx(&self, void* key) {
    if (key == null) {
        return -1;
    }

    // --- Hash table path ---
    if (self.hash_table != null && self.hash_size > 0) {
        uint h    = hash_key(key);
        uint mask = self.hash_size - 1;  // hash_size is always a power of 2
        uint slot = h & mask;

        for (uint probes = 0; probes < self.hash_size; probes++) {
            uint idx = self.hash_table[slot];

            if (idx == HASH_UNUSED) {
                // Empty slot — key is definitely not present.
                return -1;
            }

            if (idx != HASH_DELETED && idx < self.prop_count) {
                if (self.props[idx].key == key) {
                    return (int)idx;
                }
            }

            slot = (slot + 1) & mask;
        }

        return -1;
    }

    // --- Linear scan fallback ---
    for (uint i = 0; i < self.prop_count; i++) {
        if (self.props[i].key == key) {
            return (int)i;
        }
    }

    return -1;
}

/// Find the PropEntry for the given interned key.
///
/// Returns a pointer to the entry, or `null` if not found.
fn PropEntry*? HObject.find_prop(&self, void* key) {
    int idx = self.find_prop_idx(key);
    if (idx < 0) {
        return PROP_NOT_FOUND~;
    }
    return &self.props[idx];
}

// ============================================================================
// HObject — property get / has / put / delete
// ============================================================================

/// Look up a named property by its interned string key.
///
/// Returns the property's TVal on success.  For accessor properties this
/// returns the raw data-slot value — the caller (e.g. the [[Get]] algorithm)
/// is responsible for invoking the getter.
///
/// Returns `null` (Optional failure) when the property is not found on this
/// object.  Prototype chain walking is the caller's responsibility.
fn TVal? HObject.get_prop(&self, void* key) {
    int idx = self.find_prop_idx(key);
    if (idx < 0) {
        return PROP_NOT_FOUND~;
    }
    return self.props[idx].value;
}

/// Check whether the object has an own property with the given key.
fn bool HObject.has_prop(&self, void* key) {
    return self.find_prop_idx(key) >= 0;
}

/// Check whether a property is writable.
/// Returns true if the property does not exist (can be created) or
/// if it exists and its writable flag is set.
fn bool HObject.is_prop_writable(&self, void* key) {
    int idx = self.find_prop_idx(key);
    if (idx < 0) return true;
    return self.props[idx].flags.writable;
}

/// Set (create or update) a named property.
///
/// If the property already exists its value and flags are updated.
/// If it does not exist a new entry is appended (growing the table if
/// necessary).  Returns `true` on success, `false` on allocation failure.
fn bool HObject.put_prop(&self, void* key, TVal val, PropFlags pflags) {
    // --- Update existing property ---
    int idx = self.find_prop_idx(key);
    if (idx >= 0) {
        self.props[idx].value = val;
        self.props[idx].flags = pflags;
        return true;
    }

    // --- Grow if necessary ---
    if (self.prop_count >= self.prop_capacity) {
        self.grow_props();
        // If grow_props failed (capacity unchanged) and we are still full,
        // report failure.
        if (self.prop_count >= self.prop_capacity) {
            return false;
        }
    }

    // --- Append new entry ---
    uint new_idx = self.prop_count;
    self.props[new_idx].key    = key;
    self.props[new_idx].value  = val;
    self.props[new_idx].flags  = pflags;
    self.props[new_idx].getter = types::make_undefined();
    self.props[new_idx].setter = types::make_undefined();
    self.prop_count++;

    // --- Insert into hash table (if present) ---
    if (self.hash_table != null && self.hash_size > 0) {
        // Check if we should rebuild (load factor exceeded).
        if (self.prop_count * HASH_LOAD_DEN > self.hash_size * HASH_LOAD_NUM) {
            self.rebuild_hash();
        } else {
            // Fast insert into existing table.
            uint h    = hash_key(key);
            uint mask = self.hash_size - 1;
            uint slot = h & mask;
            while (self.hash_table[slot] != HASH_UNUSED &&
                   self.hash_table[slot] != HASH_DELETED) {
                slot = (slot + 1) & mask;
            }
            self.hash_table[slot] = new_idx;
        }
    } else if (self.prop_count >= HASH_MIN_PROPS) {
        // Threshold crossed — build the hash table for the first time.
        self.rebuild_hash();
    }

    return true;
}

/// Delete an own property by interned key.
///
/// Returns `true` if the property was found and removed, `false` if it was
/// not present (or was non-configurable — the caller should check that
/// before calling if strict-mode semantics apply).
///
/// The deletion compacts the props array by swapping the last entry into
/// the vacated slot, then updates the hash table accordingly.
fn bool HObject.delete_prop(&self, void* key) {
    int idx = self.find_prop_idx(key);
    if (idx < 0) {
        return false;
    }

    uint ui = (uint)idx;
    uint last = self.prop_count - 1;

    // Remove from hash table first.
    if (self.hash_table != null && self.hash_size > 0) {
        // Mark the deleted key's slot as a tombstone.
        uint h    = hash_key(key);
        uint mask = self.hash_size - 1;
        uint slot = h & mask;

        for (uint probes = 0; probes < self.hash_size; probes++) {
            uint si = self.hash_table[slot];
            if (si == HASH_UNUSED) {
                break;  // shouldn't happen, but be safe
            }
            if (si == ui) {
                self.hash_table[slot] = HASH_DELETED;
                break;
            }
            slot = (slot + 1) & mask;
        }
    }

    // Compact: swap last entry into the gap.
    if (ui != last) {
        self.props[ui] = self.props[last];

        // Update the hash table to reflect the moved entry's new index.
        if (self.hash_table != null && self.hash_size > 0) {
            void* moved_key = self.props[ui].key;
            uint h    = hash_key(moved_key);
            uint mask = self.hash_size - 1;
            uint slot = h & mask;

            for (uint probes = 0; probes < self.hash_size; probes++) {
                uint si = self.hash_table[slot];
                if (si == HASH_UNUSED) {
                    break;
                }
                if (si == last) {
                    self.hash_table[slot] = ui;
                    break;
                }
                slot = (slot + 1) & mask;
            }
        }
    }

    // Zero-out the vacated last slot for safety.
    libc::memset(&self.props[last], 0, PropEntry::size);
    self.prop_count--;

    return true;
}

// ============================================================================
// HObject — dense array part
// ============================================================================

/// Get a value from the dense array part by integer index.
///
/// Returns the TVal at `idx`, or `null` (Optional failure) when the index
/// is out of range or the slot holds undefined (hole).
fn TVal? HObject.get_array_idx(&self, uint idx) {
    if (self.array_part == null || idx >= self.array_size) {
        return PROP_NOT_FOUND~;
    }
    TVal v = self.array_part[idx];
    // Treat undefined as "not present" (array hole).
    if (v.is_undefined()) {
        return PROP_NOT_FOUND~;
    }
    return v;
}

/// Set a value in the dense array part.  Grows the array if necessary.
fn void HObject.set_array_idx(&self, uint idx, TVal val) {
    // Grow if needed.
    if (idx >= self.array_size) {
        uint new_size = self.array_size;
        if (new_size == 0) {
            new_size = ARRAY_INITIAL_SIZE;
        }
        while (new_size <= idx) {
            new_size *= 2;
        }
        self.grow_array(new_size);
        // If grow failed (array_size unchanged), bail out.
        if (idx >= self.array_size) {
            return;
        }
    }

    // Track used count.
    if (self.array_part[idx].is_undefined() && !val.is_undefined()) {
        self.array_used++;
    } else if (!self.array_part[idx].is_undefined() && val.is_undefined()) {
        if (self.array_used > 0) {
            self.array_used--;
        }
    }

    self.array_part[idx] = val;
}

// ============================================================================
// HObject — growth / rehash
// ============================================================================

/// Grow the property entry table when it is full.
///
/// The new capacity is max(PROPS_INITIAL_CAPACITY, old * 3/2).  The hash
/// table is rebuilt after growth to account for the new capacity.
fn void HObject.grow_props(&self) {
    uint new_cap;
    if (self.prop_capacity == 0) {
        new_cap = PROPS_INITIAL_CAPACITY;
    } else {
        new_cap = self.prop_capacity * PROPS_GROW_NUM / PROPS_GROW_DEN;
        if (new_cap <= self.prop_capacity) {
            new_cap = self.prop_capacity + 4;  // ensure progress
        }
    }

    usz new_bytes = (usz)new_cap * PropEntry::size;
    void* new_raw;

    if (self.props == null) {
        new_raw = libc::malloc(new_bytes);
    } else {
        new_raw = libc::realloc(self.props, new_bytes);
    }

    if (new_raw == null) {
        return;  // allocation failure — leave state unchanged
    }

    self.props = (PropEntry*)new_raw;

    // Zero-initialise the newly added slots.
    if (new_cap > self.prop_capacity) {
        usz added_bytes = (usz)(new_cap - self.prop_capacity) * PropEntry::size;
        void* start = (void*)((usz)new_raw + (usz)self.prop_capacity * PropEntry::size);
        libc::memset(start, 0, added_bytes);
    }

    self.prop_capacity = new_cap;

    // Rebuild hash table so that the hash_size tracks the new capacity.
    if (self.prop_count >= HASH_MIN_PROPS) {
        self.rebuild_hash();
    }
}

/// Grow the dense array part to at least `new_size` TVal slots.
///
/// New slots are initialised to undefined.
fn void HObject.grow_array(&self, uint new_size) {
    if (new_size <= self.array_size) {
        return;
    }

    usz new_bytes = (usz)new_size * TVal::size;
    void* new_raw;

    if (self.array_part == null) {
        new_raw = libc::malloc(new_bytes);
    } else {
        new_raw = libc::realloc(self.array_part, new_bytes);
    }

    if (new_raw == null) {
        return;  // allocation failure
    }

    self.array_part = (TVal*)new_raw;

    // Initialise new slots to undefined (tag=0 after memset since
    // UNDEFINED is the first enum variant with value 0).
    usz added_bytes = (usz)(new_size - self.array_size) * TVal::size;
    void* start = (void*)((usz)new_raw + (usz)self.array_size * TVal::size);
    libc::memset(start, 0, added_bytes);

    self.array_size = new_size;
}

/// Rebuild (or create) the hash table from scratch.
///
/// The new hash_size is the smallest power-of-two such that the load factor
/// stays below the threshold.  All live property entries are re-inserted.
fn void HObject.rebuild_hash(&self) {
    // Compute desired hash table size (power of 2, >= 2× prop_count).
    uint desired = self.prop_count * 2;
    if (desired < 16) {
        desired = 16;
    }
    // Round up to next power of 2.
    uint new_hash_size = next_power_of_two(desired);

    usz new_bytes = (usz)new_hash_size * uint::size;
    void* new_raw;

    if (self.hash_table == null) {
        new_raw = libc::malloc(new_bytes);
    } else {
        // Always allocate fresh because we re-insert everything.
        new_raw = libc::malloc(new_bytes);
        if (new_raw != null) {
            libc::free(self.hash_table);
        }
    }

    if (new_raw == null) {
        return;  // allocation failure — hash stays as-is
    }

    // Fill with HASH_UNUSED sentinel.
    libc::memset(new_raw, 0xFF, new_bytes);  // 0xFFFFFFFF == HASH_UNUSED

    self.hash_table = (uint*)new_raw;
    self.hash_size  = new_hash_size;

    // Re-insert every live property.
    uint mask = new_hash_size - 1;
    for (uint i = 0; i < self.prop_count; i++) {
        if (self.props[i].key == null) {
            continue;  // skip vacant slots (shouldn't exist in a compacted table)
        }
        uint h    = hash_key(self.props[i].key);
        uint slot = h & mask;
        while (self.hash_table[slot] != HASH_UNUSED) {
            slot = (slot + 1) & mask;
        }
        self.hash_table[slot] = i;
    }
}

// ============================================================================
// Allocation / deallocation
// ============================================================================

/// Allocate and initialise a new HObject of the given class.
///
/// `heap_ptr` is an opaque pointer to the Heap; the object is **not**
/// automatically inserted into the heap's GC list — the caller must do so.
///
/// The object starts with:
///   - flags.htype          = HType.OBJECT
///   - flags.extensible     = true
///   - flags.obj_class      = cls
///   - refcount             = 0
///   - Empty property table and no array part
///
/// Returns `null` on allocation failure.
fn HObject*? hobject_alloc(void* heap_ptr, ObjClass cls) {
    void* raw = libc::malloc(HObject::size);
    if (raw == null) {
        return OBJ_ALLOC_FAULT~;
    }

    libc::memset(raw, 0, HObject::size);

    HObject* obj = (HObject*)raw;

    // Set up flags.
    obj.flags.htype      = HType.OBJECT;
    obj.flags.extensible = true;
    obj.flags.obj_class  = cls;

    // Specific class defaults.
    if (cls == ObjClass.FUNCTION) {
        obj.flags.callable      = true;
        obj.flags.constructable = true;
    } else if (cls == ObjClass.ARRAY) {
        obj.flags.exotic_array = true;
    } else if (cls == ObjClass.ARGUMENTS) {
        obj.flags.exotic_arguments = true;
    } else if (cls == ObjClass.PROXY) {
        obj.flags.exotic_proxyobj = true;
    }

    obj.builtin_fn_index = -1;
    obj.regexp_data = null;
    return obj;
}

/// Free an HObject and all of its owned sub-allocations (property table,
/// hash table, array part).
///
/// The caller must have already unlinked the object from the heap's GC list
/// and string table references.
fn void hobject_free(HObject* obj) {
    if (obj == null) { return; }

    // Free compiled regexp bytecode if present
    if (obj.regexp_data != null) {
        re_bindings::re_free(obj.regexp_data);
        obj.regexp_data = null;
    }

    if (obj.props != null) {
        libc::free(obj.props);
    }
    if (obj.hash_table != null) {
        libc::free(obj.hash_table);
    }
    if (obj.array_part != null) {
        libc::free(obj.array_part);
    }

    libc::free(obj);
}

// ============================================================================
// Enumeration helpers
// ============================================================================

/// Returns the number of own enumerable properties.
fn uint HObject.enumerable_count(&self) {
    uint count = 0;
    for (uint i = 0; i < self.prop_count; i++) {
        if (self.props[i].flags.enumerable) {
            count++;
        }
    }
    return count;
}

/// Returns the property entry at the given raw index, or `null` if `idx`
/// is out of range.  Intended for iteration over own properties.
fn PropEntry*? HObject.get_prop_at(&self, uint idx) {
    if (idx >= self.prop_count) {
        return PROP_NOT_FOUND~;
    }
    return &self.props[idx];
}

// ============================================================================
// Prototype-chain helpers
// ============================================================================

/// Walk the prototype chain looking for a named property.
///
/// Returns the TVal of the first own property with the matching key found
/// along the chain, or `null` (Optional failure) if no object in the chain
/// has the property.  The depth limit prevents infinite loops from circular
/// prototype chains.
fn TVal? HObject.get_prop_proto(&self, void* key) {
    const uint MAX_PROTO_DEPTH = 256;
    HObject* cur = self;
    uint depth = 0;

    while (cur != null && depth < MAX_PROTO_DEPTH) {
        int idx = cur.find_prop_idx(key);
        if (idx >= 0) {
            return cur.props[idx].value;
        }
        cur = cur.prototype;
        depth++;
    }

    return PROP_NOT_FOUND~;
}

/// Check whether the property exists anywhere on the prototype chain.
fn bool HObject.has_prop_proto(&self, void* key) {
    const uint MAX_PROTO_DEPTH = 256;
    HObject* cur = self;
    uint depth = 0;

    while (cur != null && depth < MAX_PROTO_DEPTH) {
        if (cur.find_prop_idx(key) >= 0) {
            return true;
        }
        cur = cur.prototype;
        depth++;
    }

    return false;
}

/// ES5 [[Delete]]: remove an own property.
///
/// Returns true if the property was successfully removed or not found.
/// Returns false only if the property exists and is non-configurable.
/// The caller is responsible for throwing in strict mode when false.
fn bool HObject.es_delete_prop(&self, void* key) {
    int idx = self.find_prop_idx(key);
    if (idx < 0) {
        return true;  // Not found → [[Delete]] returns true.
    }
    if (!self.props[idx].flags.configurable) {
        return false;  // Non-configurable → [[Delete]] returns false.
    }
    return self.delete_prop(key);
}

// ============================================================================
// Utility: next power of two
// ============================================================================

/// Returns the smallest power of two ≥ `v`.  If `v` is 0 returns 1.
fn uint next_power_of_two(uint v) @inline {
    if (v == 0) { return 1; }
    uint n = v - 1;
    n |= n >> 1;
    n |= n >> 2;
    n |= n >> 4;
    n |= n >> 8;
    n |= n >> 16;
    return n + 1;
}

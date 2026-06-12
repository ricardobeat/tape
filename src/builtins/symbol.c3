/// Symbol constructor, global registry, and well-known symbols.
module duktape::builtins;
import duktape::types;
import duktape::env;

import duktape::heap;
import duktape::hstring;
import duktape::hobject;

// ============================================================================
// Symbol helpers
// ============================================================================

/// Symbol creation counter — incremented for each unique symbol to guarantee
/// uniqueness even with identical descriptions.
uint g_symbol_counter = 0;

/// Create a new Symbol HString with 0xFF prefix byte.
/// Symbols are NOT inserted into the string table (they are unique).
fn HString* create_symbol_string(Heap* heap, char[] desc) {
    // Build internal representation: 0xFF + description
    // We add a counter suffix for uniqueness when description is empty
    uint counter = g_symbol_counter;
    g_symbol_counter++;

    char[256] buf;
    buf[0] = (char)0xFF;
    int pos = 1;

    for (int i = 0; i < desc.len && pos < 255; i++) {
        buf[pos] = desc[i];
        pos++;
    }

    uint hash = heap.hash_seed ^ counter;  // Simple unique hash

    HString*? sym = hstring::hstring_alloc(heap, buf[:(uint)pos], hash);
    if (try s = sym) {
        // Don't intern in string table — symbols are unique
        return s;
    }
    return null;
}

/// Check if a TVal is a Symbol (STRING tag with is_symbol flag)
fn bool is_symbol_val(TVal val) {
    if (!val.is_string()) return false;
    HString* s = (HString*)val.get_heapptr();
    return s != null && s.is_symbol();
}

/// Get the description bytes of a Symbol (everything after the 0xFF prefix)
fn char[] symbol_description(HString* sym) {
    if (sym.blen <= 1) return "";
    char* ptr = sym.get_cstr();
    return ptr[1:(sz)(sym.blen - 1)];
}

// ============================================================================
// Symbol global registry (Symbol.for / Symbol.keyFor)
// ============================================================================

/// Look up a key in the global symbol registry.
/// Returns the registered symbol HString*, or null if not found.
fn HString* symbol_registry_get(Heap* heap, char[] key) {
    for (uint i = 0; i < heap.symbol_registry_count; i++) {
        HString* reg_key = heap.symbol_registry_keys[i];
        if (reg_key.blen == (uint)key.len) {
            char* reg_data = reg_key.get_cstr();
            bool match = true;
            for (int j = 0; j < key.len; j++) {
                if (reg_data[j] != key[j]) { match = false; break; }
            }
            if (match) return heap.symbol_registry_syms[i];
        }
    }
    return null;
}

/// Register a key→symbol pair in the global registry.
fn bool symbol_registry_put(Heap* heap, char[] key, HString* sym) {
    uint count = heap.symbol_registry_count;
    uint cap = heap.symbol_registry_cap;

    // Grow if needed
    if (count >= cap) {
        uint new_cap = (cap == 0) ? 8 : cap * 2;
        usz key_bytes = (usz)new_cap * void*::size;
        usz sym_bytes = (usz)new_cap * void*::size;

        HString** new_keys = (HString**)heap.alloc_func(heap.heap_udata, key_bytes);
        HString** new_syms = (HString**)heap.alloc_func(heap.heap_udata, sym_bytes);
        if (new_keys == null || new_syms == null) return false;

        // Copy existing entries
        for (uint i = 0; i < count; i++) {
            new_keys[i] = heap.symbol_registry_keys[i];
            new_syms[i] = heap.symbol_registry_syms[i];
        }
        // Free old arrays
        if (heap.symbol_registry_keys != null) {
            heap.free_func(heap.heap_udata, heap.symbol_registry_keys);
        }
        if (heap.symbol_registry_syms != null) {
            heap.free_func(heap.heap_udata, heap.symbol_registry_syms);
        }
        heap.symbol_registry_keys = new_keys;
        heap.symbol_registry_syms = new_syms;
        heap.symbol_registry_cap = new_cap;
    }

    // Allocate a key HString (interned)
    uint hash = heap.hash_string(key);
    HString* existing = heap.str_table_lookup(key, hash);
    HString* key_str;
    if (existing != null) {
        key_str = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, key, hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        key_str = new_key;
    }

    heap.symbol_registry_keys[count] = key_str;
    heap.symbol_registry_syms[count] = sym;
    heap.symbol_registry_count = count + 1;
    // Hold refs: registry owns a reference to both key and symbol strings.
    ((types::HeapHeader*)key_str).incref();
    ((types::HeapHeader*)sym).incref();
    return true;
}

/// Reverse lookup: find key for a symbol in the registry.
fn HString* symbol_registry_get_key(Heap* heap, HString* sym) {
    for (uint i = 0; i < heap.symbol_registry_count; i++) {
        if (heap.symbol_registry_syms[i] == sym) {
            return heap.symbol_registry_keys[i];
        }
    }
    return null;
}

/// Ensure the well-known @@toStringTag symbol exists in the global registry.
/// Returns the symbol HString* (usable as a property key).
fn HString* ensure_tostringtag_symbol(Heap* heap) {
    char[] desc = "toStringTag";
    HString* existing = symbol_registry_get(heap, desc);
    if (existing != null) return existing;
    HString* sym = create_symbol_string(heap, desc);
    if (sym == null) return null;
    symbol_registry_put(heap, desc, sym);
    return sym;
}

/// Ensure the well-known @@iterator symbol exists in the global registry.
/// Returns the symbol HString* (usable as a property key).
fn HString* ensure_iterator_symbol(Heap* heap) {
    // Fast path: already cached on the heap
    if (heap.iterator_symbol != null) return heap.iterator_symbol;
    char[] desc = "iterator";
    HString* existing = symbol_registry_get(heap, desc);
    if (existing != null) {
        heap.iterator_symbol = existing;
        ((types::HeapHeader*)existing).refcount = heap::STRING_PINNED_REFCOUNT;
        return existing;
    }
    HString* sym = create_symbol_string(heap, desc);
    if (sym == null) return null;
    symbol_registry_put(heap, desc, sym);
    heap.iterator_symbol = sym;
    ((types::HeapHeader*)sym).refcount = heap::STRING_PINNED_REFCOUNT;
    return sym;
}

/// Ensure the well-known @@toPrimitive symbol exists in the global registry.
/// Returns the symbol HString* (usable as a property key).
fn HString* ensure_toprimitive_symbol(Heap* heap) {
    if (heap.toprimitive_symbol != null) return heap.toprimitive_symbol;
    char[] desc = "toPrimitive";
    HString* existing = symbol_registry_get(heap, desc);
    if (existing != null) {
        heap.toprimitive_symbol = existing;
        ((types::HeapHeader*)existing).refcount = heap::STRING_PINNED_REFCOUNT;
        return existing;
    }
    HString* sym = create_symbol_string(heap, desc);
    if (sym == null) return null;
    symbol_registry_put(heap, desc, sym);
    heap.toprimitive_symbol = sym;
    ((types::HeapHeader*)sym).refcount = heap::STRING_PINNED_REFCOUNT;
    return sym;
}

// ============================================================================
// Symbol constructor (ES6 §19.4.1)
// ============================================================================
fn void builtin_symbol(BuiltinContext* ctx) {
    // Symbol is not constructable with new
    if (ctx.is_constructor) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_str = builtin_intern_string(ctx.heap, "Symbol is not a constructor");
            if (msg_str != null) {
                TVal msg_val;
                msg_val.set_string(msg_str);
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
            }
            ctx.throw_value.set_object(err);
        } else {
            ctx.throw_value.set_undefined();
        }
        ctx.should_throw = true;
        return;
    }

    // Get description from first argument (ToString if present)
    char[] desc = "";
    if (ctx.argc >= 1) {
        TVal arg = ctx.regs[ctx.base_reg];
        HString* desc_str = builtin_to_string(ctx.heap, &arg);
        if (desc_str != null) {
            desc = desc_str.get_data();
        }
    }

    HString* sym = create_symbol_string(ctx.heap, desc);
    if (sym == null) {
        ctx.result.set_undefined();
        return;
    }
    ctx.result.set_string(sym);
}

// ============================================================================
// Symbol.for(key) — ES6 §19.4.2.1
// ============================================================================
fn void builtin_symbol_for(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_undefined();
        return;
    }

    TVal key_val = ctx.regs[ctx.base_reg];
    HString* key_str = builtin_to_string(ctx.heap, &key_val);
    if (key_str == null) {
        ctx.result.set_undefined();
        return;
    }

    char[] key_bytes = key_str.get_data();

    // Check registry
    HString* existing = symbol_registry_get(ctx.heap, key_bytes);
    if (existing != null) {
        ctx.result.set_string(existing);
        return;
    }

    // Create new global symbol
    HString* sym = create_symbol_string(ctx.heap, key_bytes);
    if (sym == null) {
        ctx.result.set_undefined();
        return;
    }

    symbol_registry_put(ctx.heap, key_bytes, sym);

    ctx.result.set_string(sym);
}

// ============================================================================
// Symbol.keyFor(sym) — ES6 §19.4.2.5
// ============================================================================
fn void builtin_symbol_keyfor(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_undefined();
        return;
    }

    TVal sym_val = ctx.regs[ctx.base_reg];
    if (!is_symbol_val(sym_val)) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_str = builtin_intern_string(ctx.heap, "Symbol.keyFor requires a symbol argument");
            if (msg_str != null) {
                TVal msg_val;
                msg_val.set_string(msg_str);
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
            }
            ctx.throw_value.set_object(err);
        } else {
            ctx.throw_value.set_undefined();
        }
        ctx.should_throw = true;
        return;
    }

    HString* sym = (HString*)sym_val.get_heapptr();
    HString* key = symbol_registry_get_key(ctx.heap, sym);
    if (key != null) {
        ctx.result.set_string(key);
    } else {
        ctx.result.set_undefined();
    }
}

// ============================================================================
// Symbol.prototype.toString() — ES6 §19.4.3.2
// ============================================================================
fn void builtin_symbol_proto_toString(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];

    // this value must be a Symbol (primitive or wrapper)
    HString* sym = null;
    if (this_val.is_string()) {
        HString* s = (HString*)this_val.get_heapptr();
        if (s != null && s.is_symbol()) {
            sym = s;
        }
    } else if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        if (obj.flags.obj_class == hobject::ObjClass.SYMBOL) {
            // Extract [[SymbolData]] — for now, check if there's a stored symbol
            // We look for the "_symbol" property or just describe as "Symbol()"
        }
    }

    if (sym == null) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_str = builtin_intern_string(ctx.heap, "Symbol.prototype.toString called on non-Symbol");
            if (msg_str != null) {
                TVal msg_val;
                msg_val.set_string(msg_str);
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
            }
            ctx.throw_value.set_object(err);
        } else {
            ctx.throw_value.set_undefined();
        }
        ctx.should_throw = true;
        return;
    }

    // Build "Symbol(description)" string
    char[] desc = symbol_description(sym);
    char[512] result_buf;
    result_buf[0] = 'S';
    result_buf[1] = 'y';
    result_buf[2] = 'm';
    result_buf[3] = 'b';
    result_buf[4] = 'o';
    result_buf[5] = 'l';
    result_buf[6] = '(';
    int pos = 7;
    for (int i = 0; i < desc.len && pos < 510; i++) {
        result_buf[pos] = desc[i];
        pos++;
    }
    result_buf[pos] = ')';
    pos++;
    result_buf[pos] = 0;

    HString* result = builtin_intern_string(ctx.heap, result_buf[:(uint)pos]);
    ctx.result.set_string(result);
}

// ============================================================================
// Symbol.prototype.data.valueOf() — ES6 §19.4.3.3
// ============================================================================
fn void builtin_symbol_proto_valueOf(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];

    if (this_val.is_string()) {
        HString* s = (HString*)this_val.get_heapptr();
        if (s != null && s.is_symbol()) {
            *ctx.result = this_val;
            return;
        }
    } else if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        if (obj.flags.obj_class == hobject::ObjClass.SYMBOL) {
            // Return the [[SymbolData]] value
            // For now just return undefined for wrapper objects
        }
    }

    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_str = builtin_intern_string(ctx.heap, "Symbol.prototype.data.valueOf called on non-Symbol");
        if (msg_str != null) {
            TVal msg_val;
            msg_val.set_string(msg_str);
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
        }
        ctx.throw_value.set_object(err);
    } else {
        ctx.throw_value.set_undefined();
    }
    ctx.should_throw = true;
}

// ============================================================================
// Symbol constructor registration
// ============================================================================

fn bool register_symbol_constructor(EnvRecord* global_env, Heap* heap) {
    // Create Symbol.prototype
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.SYMBOL);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;
    heap.symbol_proto = proto;

    // Register prototype methods
    if (!register_string_proto_method(proto, heap, "toString", BUILTIN_SYMBOL_PROTO_TOSTRING)) return false;
    if (!register_string_proto_method(proto, heap, "valueOf", BUILTIN_SYMBOL_PROTO_VALUEOF)) return false;

    // Set @@toStringTag on prototype
    HString* tag_key = ensure_tostringtag_symbol(heap);
    if (tag_key != null) {
        TVal tag_tv;
        tag_tv.set_string(builtin_intern_string(heap, "Symbol"));
        proto.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC);
    }

    // Create Symbol function object
    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)BUILTIN_SYMBOL;

    // Wire prototype.constructor → ctor
    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(ctor);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);

    // Wire ctor.prototype → proto (non-writable, non-enumerable, non-configurable)
    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    ctor.put_prop(prototype_key, proto_tv, proto_pflags);

    // Symbol.length = 0
    HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    TVal length_tv;
    length_tv.set_fastint(0);
    ctor.put_prop(length_key, length_tv, hobject::PROP_FLAGS_NWC);

    // Register Symbol.for as a property of the Symbol function
    HString* for_key = builtin_intern_string(heap, "for");
    TVal for_tv;
    for_tv.set_lightfunc((void*)(usz)BUILTIN_SYMBOL_FOR);
    ctor.put_prop(for_key, for_tv, hobject::PROP_FLAGS_WC);

    // Register Symbol.keyFor as a property of the Symbol function
    HString* keyfor_key = builtin_intern_string(heap, "keyFor");
    TVal keyfor_tv;
    keyfor_tv.set_lightfunc((void*)(usz)BUILTIN_SYMBOL_KEYFOR);
    ctor.put_prop(keyfor_key, keyfor_tv, hobject::PROP_FLAGS_WC);

    // Register Symbol.toStringTag as a well-known symbol property
    HString* tostrtag_sym = ensure_tostringtag_symbol(heap);
    if (tostrtag_sym != null) {
        HString* tostrtag_key = builtin_intern_string(heap, "toStringTag");
        TVal tostrtag_val;
        tostrtag_val.set_string(tostrtag_sym);
        ctor.put_prop(tostrtag_key, tostrtag_val, hobject::PROP_FLAGS_WC);
    }

    // Register Symbol.iterator as a well-known symbol property (non-writable, non-enumerable, non-configurable per ES6 §19.4.2.12)
    HString* iter_sym = ensure_iterator_symbol(heap);
    if (iter_sym != null) {
        HString* iter_key = builtin_intern_string(heap, "iterator");
        if (iter_key != null) {
            TVal iter_val;
            iter_val.set_string(iter_sym);
            ctor.put_prop(iter_key, iter_val, hobject::PROP_FLAGS_NWC);
        }
    }

    // Register Symbol.toPrimitive as a well-known symbol property (non-writable, non-enumerable, non-configurable per ES6 §19.4.2.12)
    HString* toprim_sym = ensure_toprimitive_symbol(heap);
    if (toprim_sym != null) {
        HString* toprim_key = builtin_intern_string(heap, "toPrimitive");
        if (toprim_key != null) {
            TVal toprim_val;
            toprim_val.set_string(toprim_sym);
            ctor.put_prop(toprim_key, toprim_val, hobject::PROP_FLAGS_NWC);
        }
    }

    // Register "Symbol" in global environment
    uint hash = heap.hash_string("Symbol");
    HString* existing = heap.str_table_lookup("Symbol", hash);
    HString* sym_key;
    if (existing != null) {
        sym_key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, "Symbol", hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        sym_key = new_key;
    }
    TVal sym_val;
    sym_val.set_object(ctor);
    set_func_ctor_name(ctor, heap, "Symbol");
    env::env_declare_nonenum(global_env, sym_key, sym_val);

    return true;
}

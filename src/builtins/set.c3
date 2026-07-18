/// Set constructor and Set.prototype methods.
module duktape::builtins;

import duktape::types;
import duktape::heap;
import duktape::hobject;
import duktape::hstring;
import duktape::env;

// ============================================================================
// Set helpers
// ============================================================================

fn HObject* check_set(BuiltinContext* ctx) {
    return check_collection_class(ctx, hobject::ObjClass.SET, "Set.prototype method called on incompatible value");
}

/// Find the index in array_part where a value matches. Returns -1 if not found.
/// Set entries are stored as [v0, v1, ...] in array_part.
fn int set_find_value(HObject* set, TVal val) {
    return find_in_array_part(set, val, 1);
}

// ============================================================================
// Set constructor (ES6 §23.2.1)
// ============================================================================
fn void builtin_set(BuiltinContext* ctx) {
    coll_construct(ctx, hobject::ObjClass.SET, ctx.heap.set_proto,
        "Constructor Set requires 'new'",
        "Set constructor argument is not an object",
        "add", "Set.prototype.add is not callable",
        "Set: iterable argument is not iterable",
        false, false);
}

// ============================================================================
// Set.prototype.add(value) — ES6 §23.2.3.1
// ============================================================================
fn void builtin_set_proto_add(BuiltinContext* ctx) {
    HObject* set = check_set(ctx);
    if (set == null) { ctx.result.set_undefined(); return; }
    coll_add_value(ctx, set, false, "", true);
}

// ============================================================================
// Set.prototype.size getter — ES6 §23.2.3.9
// Counts non-deleted entries (deleted slots use TAG_DELETED sentinel).
// ============================================================================
fn void builtin_set_proto_size_get(BuiltinContext* ctx) {
    HObject* set = check_set(ctx);
    if (set == null) return;
    uint count = 0;
    TVal* arr = set.array_part();
    if (arr != null) {
        for (uint i = 0; i < set.array_used; i++) {
            if (!arr[i].is_deleted()) count++;
        }
    }
    ctx.result.set_fastint((long)count);
}

// ============================================================================
// Set.prototype.has(value) — ES6 §23.2.3.7
// ============================================================================
fn void builtin_set_proto_has(BuiltinContext* ctx) {
    HObject* set = check_set(ctx);
    if (set == null) { ctx.result.set_undefined(); return; }
    if (ctx.argc < 1) { ctx.result.set_boolean(false); return; }

    TVal value = ctx.regs[ctx.base_reg];
    int found = set_find_value(set, value);
    ctx.result.set_boolean((found >= 0));
}

// ============================================================================
// Set.prototype.delete(value) — ES6 §23.2.3.4
// Per ES6 spec, deletion marks the entry as "empty" rather than shifting so
// concurrent iteration sees the deletion and new entries appear at the end.
// ============================================================================
fn void builtin_set_proto_delete(BuiltinContext* ctx) {
    HObject* set = check_set(ctx);
    if (set == null) { ctx.result.set_undefined(); return; }
    if (ctx.argc < 1) { ctx.result.set_boolean(false); return; }
    coll_delete(ctx, set, ctx.regs[ctx.base_reg], 1, true);
}

// ============================================================================
// Set.prototype.clear() — ES6 §23.2.3.2
// ============================================================================
fn void builtin_set_proto_clear(BuiltinContext* ctx) {
    HObject* set = check_set(ctx);
    if (set == null) { ctx.result.set_undefined(); return; }

    uint cnt = set.array_used;
    for (uint i = 0; i < cnt; i++) {
        set.array_part()[i].set_undefined();
    }
    set.array_used = 0;

    ctx.result.set_undefined();
}

// ============================================================================
// Set.prototype.data.values() — ES6 §23.2.3.10
// Returns a SetIterator with kind=0.
// ============================================================================
fn void builtin_set_proto_values(BuiltinContext* ctx) {
    create_set_iterator(ctx, 0);
}

// ============================================================================
// Set.prototype.entries() — ES6 §23.2.3.5
// Returns [value, value] pairs as a SetIterator with kind=2.
// ============================================================================
fn void builtin_set_proto_entries(BuiltinContext* ctx) {
    create_set_iterator(ctx, 2);
}

// ============================================================================
// SetIterator.prototype.next() — ES6 §23.2.5.2.1
// ============================================================================
fn void builtin_set_iterator_next(BuiltinContext* ctx) {
    TVal this_val = ctx.this_val;
    Heap* heap = ctx.heap;

    if (!this_val.is_object()) {
        ctx.should_throw = true;
        ctx.result.set_undefined();
        return;
    }

    HObject* iter = (HObject*)this_val.get_heapptr();
    if (iter.get_class() != hobject::ObjClass.SET_ITERATOR) {
        ctx.should_throw = true;
        ctx.result.set_undefined();
        return;
    }

    HObject* target = (*iter.extra_ptr()).iter.target;
    if (target == null) {
        // Already exhausted — return {value: undefined, done: true}
        HObject*? result_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err = result_raw) { ctx.result.set_undefined(); return; }
        HObject* result = result_raw;
        result.prototype = null;
        TVal undef; undef.set_undefined();
        HString* value_key = (HString*)heap.strs[heap::BuiltinStr.VALUE];
        result.put_prop(value_key, undef, hobject::PROP_FLAGS_WEC);
        HString* done_key = (HString*)heap.strs[heap::BuiltinStr.DONE];
        TVal done_tv; done_tv.set_boolean(true);
        result.put_prop(done_key, done_tv, hobject::PROP_FLAGS_WEC);
        ctx.result.set_object(result);
        return;
    }

    uint idx = (*iter.extra_ptr()).iter.index;
    uint kind = (*iter.extra_ptr()).iter.kind;

    bool done = false;
    TVal value;
    value.set_undefined();

    // Skip over deleted slots — array_used is high water mark,
    // and array_part() may contain TAG_DELETED slots from deletes.
    TVal* entries = target.array_part();
    if (entries != null) {
        while (idx < target.array_used && entries[idx].is_deleted()) {
            idx++;
        }
    }

    if (idx < target.array_used) {
        if (entries != null) {
            TVal item = entries[idx];
            if (kind == 1 || kind == 0) {
                // keys()/values(): return the value
                value = item;
            } else {
                // entries(): return [value, value]
                HObject*? pair_raw = heap.alloc_object(hobject::ObjClass.ARRAY);
                if (try pair = pair_raw) {
                    pair.prototype = heap.array_proto;
                    pair.set_array_idx(0, item);
                    pair.set_array_idx(1, item);
                    pair.array_used = 2;
                    HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
                    if (len_key != null) {
                        TVal len_tv;
                        len_tv.set_fastint(2);
                        pair.put_prop(len_key, len_tv, hobject::PROP_FLAGS_WEC);
                    }
                    value.set_object(pair);
                }
            }
            (*iter.extra_ptr()).iter.index = idx + 1;
        } else {
            done = true;
        }
    } else {
        done = true;
    }

    if (done) {
        value.set_undefined();
        (*iter.extra_ptr()).iter.target = null;  // mark exhausted — no yielding after done
    }

    // Create result object: {value, done}
    HObject*? result_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = result_raw) { ctx.result.set_undefined(); return; }
    HObject* result = result_raw;
    result.prototype = null;

    HString* value_key = (HString*)heap.strs[heap::BuiltinStr.VALUE];
    result.put_prop(value_key, value, hobject::PROP_FLAGS_WEC);

    HString* done_key = (HString*)heap.strs[heap::BuiltinStr.DONE];
    TVal done_tv;
    done_tv.set_boolean(done);
    result.put_prop(done_key, done_tv, hobject::PROP_FLAGS_WEC);

    ctx.result.set_object(result);
}

// ============================================================================
// Set.prototype.forEach(callbackfn[, thisArg]) — ES6 §23.2.3.6
// ============================================================================
fn void builtin_set_proto_forEach(BuiltinContext* ctx) {
    HObject* set = check_set(ctx);
    if (set == null) { ctx.result.set_undefined(); return; }

    if (ctx.argc < 1) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_str = builtin_intern_string(ctx.heap, "missing argument 0 when calling function forEach");
            if (msg_str != null) {
                TVal msg_val;
                msg_val.set_string(msg_str);
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
            }
        }
        ctx.result.set_undefined();
        return;
    }

    TVal callback = ctx.regs[ctx.base_reg];

    // ES6 §23.2.3.6 step 4: If IsCallable(callbackfn) is false, throw TypeError
    if (!(callback.is_object() && callback.get_heapptr() != null && ((HObject*)callback.get_heapptr()).is_callable())) {
        builtin_throw(ctx, ctx.heap.type_err_proto, "object is not a function");
        return;
    }

    TVal thisArg;
    if (ctx.argc >= 2) { thisArg = ctx.regs[ctx.base_reg + 1]; } else { thisArg.set_undefined(); }

    TVal* entries = set.array_part();
    uint used = set.array_used;
    for (uint i = 0; i < used; i++) {
        TVal value = entries[i];
        if (value.is_deleted()) continue;  // skip deleted slot

        TVal[3] args;
        args[0] = value;
        args[1] = value;
        args[2].set_object((void*)set);
        ctx.heap.call_fn(ctx.vm, callback, &args[0], 3, thisArg);
        if (ctx.heap.has_error) {
            ctx.should_throw = true;
            ctx.throw_value = ctx.heap.error_value;
            ctx.heap.has_error = false;
            ctx.result.set_undefined();
            return;
        }
        // After callback, refresh used (entries may have been added).
        used = set.array_used;
        entries = set.array_part();
    }

    ctx.result.set_undefined();
}

// ============================================================================
// Set[Symbol.species] getter — ES6 §23.2.2.2. Returns the this value (the
// constructor itself), so a subclass like `class MySet extends Set {}` gets
// MySet back from SpeciesConstructor calls that inherit this accessor.
// ============================================================================
fn void builtin_set_species_getter(BuiltinContext* ctx) {
    *ctx.result = ctx.this_val;
}

// ============================================================================
// Set constructor registration
// ============================================================================

fn bool register_set_constructor(EnvRecord* global_env, Heap* heap) {
    // Create Set prototype (an ordinary object per ES6 §23.2.3 — must NOT
    // carry the SET ObjClass flag, otherwise set_check() would accept it as
    // a valid Set and methods like clear() would skip the TypeError guard).
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;
    heap.set_proto = proto;

    // Add .add(value) method
    if (!register_string_proto_method(proto, heap, "add", BUILTIN_SET_PROTO_ADD)) return false;
    // Add .has(value) method
    if (!register_string_proto_method(proto, heap, "has", BUILTIN_SET_PROTO_HAS)) return false;
    // Add .delete(value) method
    if (!register_string_proto_method(proto, heap, "delete", BUILTIN_SET_PROTO_DELETE)) return false;
    // Add .clear() method
    if (!register_string_proto_method(proto, heap, "clear", BUILTIN_SET_PROTO_CLEAR)) return false;
    // Add .values() method (register FIRST so .keys can alias it)
    if (!register_string_proto_method(proto, heap, "values", BUILTIN_SET_PROTO_VALUES)) return false;
    // .keys() must be the same function object as .values() per ES6 §23.2.3.8
    {
        HString* values_key = builtin_intern_string(heap, "values");
        HString* keys_key = builtin_intern_string(heap, "keys");
        if (values_key != null && keys_key != null) {
            PropValue*? values_prop_opt = proto.find_prop(values_key);
            if (try values_prop = values_prop_opt) {
                proto.put_prop(keys_key, *values_prop, hobject::PROP_FLAGS_WC);
            }
        }
    }
    // Add .entries() method
    if (!register_string_proto_method(proto, heap, "entries", BUILTIN_SET_PROTO_ENTRIES)) return false;
    // Add .forEach() method
    if (!register_string_proto_method(proto, heap, "forEach", BUILTIN_SET_PROTO_FOREACH)) return false;
    // Set.prototype[Symbol.iterator] must be the *same function object* as
    // .values (ES6 §23.2.3.11), not merely an equivalent implementation.
    {
        HString* iter_sym = ensure_iterator_symbol(heap);
        HString* values_key = builtin_intern_string(heap, "values");
        if (iter_sym != null && values_key != null) {
            PropValue*? values_prop_opt = proto.find_prop(values_key);
            if (try values_prop = values_prop_opt) {
                proto.put_prop(iter_sym, *values_prop, hobject::PROP_FLAGS_WC);
            }
        }
    }
    
    // Set @@toStringTag on Set.prototype
    HString* tag_key = ensure_tostringtag_symbol(heap);
    if (tag_key != null) {
        TVal tag_tv;
        tag_tv.set_string(builtin_intern_string(heap, "Set"));
        proto.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC);
    }

    // Register .size as a getter accessor property (ES6 §23.2.3.9)
    {
        HString* size_key = builtin_intern_string(heap, "size");
        if (size_key != null) {
            HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
            if (catch err = fn_raw) return false;
            HObject* fn_obj = fn_raw;
            (*fn_obj.extra_ptr()).func.builtin_fn_index = (int)BUILTIN_SET_PROTO_SIZE_GET;
            fn_obj.flags.callable = true;
            fn_obj.prototype = heap.function_proto;
            // Set .name = "get size"
            char[] fn_name = "get size";
            HString* name_str = builtin_intern_string(heap, fn_name);
            if (name_str != null) {
                TVal name_tv;
                name_tv.set_string(name_str);
                HString* name_key = builtin_intern_string(heap, "name");
                fn_obj.put_prop(name_key, name_tv, hobject::PROP_FLAGS_NWC);
            }
            HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
            if (length_key != null) {
                TVal len_tv;
                len_tv.set_fastint(0);
                fn_obj.put_prop(length_key, len_tv, hobject::PROP_FLAGS_NWC);
            }
            TVal getter_tv;
            getter_tv.set_object(fn_obj);
            TVal undef;
            undef.set_undefined();
            hobject::PropFlags acc_flags;
            acc_flags.writable = false;
            acc_flags.enumerable = false;
            acc_flags.configurable = true;
            acc_flags.is_accessor = true;
            proto.put_prop(size_key, hobject::hobject_create_accessors(heap, getter_tv, undef), acc_flags);
        }
    }

    // Create Set constructor as a proper function object
    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)BUILTIN_SET;

    // Set .constructor on Set.prototype
    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(ctor);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);

    // Set Set.prototype on the constructor (non-writable, non-enumerable, non-configurable)
    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    ctor.put_prop(prototype_key, proto_tv, proto_pflags);

    // Set Set.length
    HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    TVal length_tv;
    length_tv.set_fastint(0);
    ctor.put_prop(length_key, length_tv, hobject::PROP_FLAGS_NWC);

    // Set[Symbol.species] accessor — ES6 §23.2.2.2: getter returns `this`.
    {
        HString* species_sym = ensure_species_symbol(heap);
        if (species_sym != null) {
            HObject*? getter_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
            if (try getter = getter_raw) {
                getter.flags.callable = true;
                getter.flags.constructable = false;
                getter.prototype = heap.function_proto;
                (*getter.extra_ptr()).func.builtin_fn_index = (int)BUILTIN_SET_SPECIES_GETTER;
                HString* getter_name_key = builtin_intern_string(heap, "name");
                HString* getter_name_str = builtin_intern_string(heap, "get [Symbol.species]");
                if (getter_name_key != null && getter_name_str != null) {
                    TVal gn_tv; gn_tv.set_string(getter_name_str);
                    getter.put_prop(getter_name_key, gn_tv, hobject::PROP_FLAGS_NWC);
                }
                HString* getter_len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
                if (getter_len_key != null) {
                    TVal gl_tv; gl_tv.set_fastint(0);
                    getter.put_prop(getter_len_key, gl_tv, hobject::PROP_FLAGS_NWC);
                }
                TVal getter_tv; getter_tv.set_object(getter);
                TVal undef_tv; undef_tv.set_undefined();
                PropFlags acc_flags;
                acc_flags.writable = false;
                acc_flags.enumerable = false;
                acc_flags.configurable = true;
                acc_flags.is_accessor = true;
                ctor.put_prop(species_sym, hobject::hobject_create_accessors(heap, getter_tv, undef_tv), acc_flags);
            }
        }
    }

    // Register Set constructor globally
    uint hash = heap.hash_string("Set");
    HString* existing = heap.str_table_lookup("Set", hash);
    HString* set_key;
    if (existing != null) {
        set_key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, "Set", hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        set_key = new_key;
    }
    TVal set_val;
    set_val.set_object(ctor);
    set_func_ctor_name(ctor, heap, "Set");
    env::env_declare_nonenum(global_env, set_key, set_val);

    return true;
}

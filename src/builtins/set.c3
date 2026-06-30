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
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        if (obj.flags.obj_class == hobject::ObjClass.SET) return obj;
    }
    // TypeError
    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_str = builtin_intern_string(ctx.heap,
            "Set.prototype method called on incompatible value");
        if (msg_str != null) {
            TVal msg_val;
            msg_val.set_string(msg_str);
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
        }
        TVal err_val;
        err_val.set_object(err);
        ctx.should_throw = true;
        ctx.throw_value = err_val;
    }
    return null;
}

/// Find the index in array_part where a value matches. Returns -1 if not found.
/// Set entries are stored as [v0, v1, ...] in array_part.
fn int set_find_value(HObject* set, TVal val) {
    uint count = set.array_used;
    for (uint i = 0; i < count; i++) {
        if (same_value_zero(set.array_part()[i], val)) {
            return (int)i;
        }
    }
    return -1;
}

// ============================================================================
// Set constructor (ES6 §23.2.1)
// ============================================================================
fn void builtin_set(BuiltinContext* ctx) {
    // ES6 §23.2.1.1 step 1: throw TypeError if NewTarget is undefined.
    if (!ctx.is_constructor) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err = err_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_str = builtin_intern_string(ctx.heap, "Constructor Set requires 'new'");
        if (msg_str != null) {
            TVal msg_val; msg_val.set_string(msg_str);
            err.put_prop(builtin_intern_string(ctx.heap, "message"), msg_val, hobject::PROP_FLAGS_WC);
        }
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
        return;
    }
    HObject*? set_raw = ctx.heap.alloc_object(hobject::ObjClass.SET);
    if (catch err = set_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* set = set_raw;
    set.prototype = ctx.heap.set_proto;

    // If iterable argument, populate set per ES6 §23.2.1.1.5 AddEntriesFromIterable.
    if (ctx.argc >= 1) {
        TVal arg = ctx.regs[ctx.base_reg];
        if (!arg.is_null() && !arg.is_undefined()) {
            if (!arg.is_object()) {
                HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = ctx.heap.type_err_proto;
                    HString* msg_str = builtin_intern_string(ctx.heap, "Set constructor argument is not an object");
                    if (msg_str != null) {
                        TVal msg_val; msg_val.set_string(msg_str);
                        err.put_prop(builtin_intern_string(ctx.heap, "message"), msg_val, hobject::PROP_FLAGS_WC);
                    }
                    ctx.should_throw = true;
                    ctx.throw_value.set_object(err);
                }
                ctx.result.set_undefined();
                return;
            }
            // ES6 §23.2.1 step 6: Get(set, "add"); must throw/return abruptly.
            TVal set_tv; set_tv.set_object(set);
            HString* add_key = builtin_intern_string(ctx.heap, "add");
            TVal adder;
            adder.set_undefined();
            if (add_key != null) {
                if (catch err_g = set.get_prop_proto(add_key)) {
                    if (ctx.heap.has_error) {
                        ctx.should_throw = true;
                        ctx.throw_value = ctx.heap.error_value;
                        ctx.heap.has_error = false;
                    }
                    ctx.result.set_undefined();
                    return;
                }
                TVal? adder_opt = set.get_prop_proto(add_key);
                if (try av = adder_opt) adder = av;
            }
            bool adder_callable = adder.is_lightfunc() ||
                (adder.is_object() && adder.get_heapptr() != null &&
                 ((HObject*)adder.get_heapptr()).is_callable());
            if (!adder_callable) {
                HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = ctx.heap.type_err_proto;
                    HString* msg_str = builtin_intern_string(ctx.heap, "Set.prototype.add is not callable");
                    if (msg_str != null) {
                        TVal msg_val; msg_val.set_string(msg_str);
                        err.put_prop(builtin_intern_string(ctx.heap, "message"), msg_val, hobject::PROP_FLAGS_WC);
                    }
                    ctx.should_throw = true;
                    ctx.throw_value.set_object(err);
                }
                ctx.result.set_undefined();
                return;
            }
            HObject* iterable = (HObject*)arg.get_heapptr();
            HString* iter_sym = ensure_iterator_symbol(ctx.heap);
            if (iter_sym == null) { ctx.result.set_undefined(); return; }
            TVal iter_fn = iterable.get_prop_proto(iter_sym)!!;
            bool iter_callable = iter_fn.is_lightfunc() ||
                (iter_fn.is_object() && iter_fn.get_heapptr() != null &&
                 ((HObject*)iter_fn.get_heapptr()).is_callable());
            if (!iter_callable) {
                // Array-like fallback path.
                uint len = array_get_length(iterable, ctx.heap);
                for (uint i = 0; i < len; i++) {
                    TVal v = array_get_elem(iterable, i, ctx.heap);
                    if (!v.is_undefined()) {
                        TVal[1] adder_args = { v };
                        TVal set_tv2; set_tv2.set_object(set);
                        ctx.heap.call_fn(ctx.vm, adder, &adder_args[0], 1, set_tv2);
                        if (ctx.heap.has_error) {
                            ctx.should_throw = true;
                            ctx.throw_value = ctx.heap.error_value;
                            ctx.heap.has_error = false;
                            ctx.result.set_undefined();
                            return;
                        }
                    }
                }
            } else {
                // Iterator-based path per ES6 §23.2.1.1.5 AddEntriesFromIterable.
                TVal iterator = ctx.heap.call_fn(ctx.vm, iter_fn, null, 0, arg);
                if (ctx.heap.has_error) {
                    ctx.should_throw = true;
                    ctx.throw_value = ctx.heap.error_value;
                    ctx.heap.has_error = false;
                    ctx.result.set_undefined();
                    return;
                }
                if (!iterator.is_object() || iterator.get_heapptr() == null) {
                    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                    if (try err = err_raw) {
                        err.prototype = ctx.heap.type_err_proto;
                        HString* msg_str = builtin_intern_string(ctx.heap, "Iterator result is not an object");
                        if (msg_str != null) {
                            TVal msg_val; msg_val.set_string(msg_str);
                            err.put_prop(builtin_intern_string(ctx.heap, "message"), msg_val, hobject::PROP_FLAGS_WC);
                        }
                        ctx.should_throw = true;
                        ctx.throw_value.set_object(err);
                    }
                    ctx.result.set_undefined();
                    return;
                }
                HObject* iter_obj = (HObject*)iterator.get_heapptr();
                HString* next_key = builtin_intern_string(ctx.heap, "next");
                if (next_key == null) { ctx.result.set_undefined(); return; }
                while (true) {
                    TVal next_fn = iter_obj.get_prop_proto(next_key)!!;
                    if (!next_fn.is_object() || ((HObject*)next_fn.get_heapptr()) == null ||
                        !((HObject*)next_fn.get_heapptr()).is_callable()) {
                        break;
                    }
                    TVal result = ctx.heap.call_fn(ctx.vm, next_fn, null, 0, iterator);
                    if (ctx.heap.has_error) {
                        ctx.should_throw = true;
                        ctx.throw_value = ctx.heap.error_value;
                        ctx.heap.has_error = false;
                        ctx.result.set_undefined();
                        return;
                    }
                    if (!result.is_object() || result.get_heapptr() == null) break;
                    HObject* res_obj = (HObject*)result.get_heapptr();
                    HString* done_key = builtin_intern_string(ctx.heap, "done");
                    TVal done_val;
                    done_val.set_undefined();
                    if (done_key != null) {
                        TVal? dv = res_obj.get_prop_proto(done_key);
                        if (try d = dv) { done_val = d; }
                    }
                    if (done_val.is_boolean() && done_val.get_boolean()) break;

                    HString* value_key = builtin_intern_string(ctx.heap, "value");
                    TVal val;
                    val.set_undefined();
                    if (value_key != null) {
                        TVal? vv = res_obj.get_prop_proto(value_key);
                        if (try v = vv) { val = v; }
                    }
                    if (!val.is_undefined()) {
                        TVal[1] adder_args = { val };
                        TVal set_tv2; set_tv2.set_object(set);
                        ctx.heap.call_fn(ctx.vm, adder, &adder_args[0], 1, set_tv2);
                        if (ctx.heap.has_error) {
                            ctx.should_throw = true;
                            ctx.throw_value = ctx.heap.error_value;
                            ctx.heap.has_error = false;
                            ctx.result.set_undefined();
                            return;
                        }
                    }
                }
            }
        }
    }

    ctx.result.set_object(set);
}

// ============================================================================
// Set.prototype.add(value) — ES6 §23.2.3.1
// ============================================================================
fn void builtin_set_proto_add(BuiltinContext* ctx) {
    HObject* set = check_set(ctx);
    if (set == null) { ctx.result.set_undefined(); return; }
    if (ctx.argc < 1) { ctx.result.set_undefined(); return; }

    TVal value = ctx.regs[ctx.base_reg];
    int found = set_find_value(set, value);
    if (found < 0) {
        set.set_array_idx(set.array_used, value);
    }

    // Return the set
    ctx.result.set_object(set);
}

// ============================================================================
// Set.prototype.size getter — ES6 §23.2.3.9
// Counts non-empty entries (since delete marks slots as undefined).
// ============================================================================
fn void builtin_set_proto_size_get(BuiltinContext* ctx) {
    HObject* set = check_set(ctx);
    if (set == null) return;
    uint count = 0;
    TVal* arr = set.array_part();
    if (arr != null) {
        for (uint i = 0; i < set.array_used; i++) {
            if (!arr[i].is_undefined()) count++;
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

    TVal value = ctx.regs[ctx.base_reg];
    int found = set_find_value(set, value);
    if (found >= 0) {
        TVal* slot = &set.array_part()[(uint)found];
        if (slot.is_string()) ctx.heap.decref_tval(slot);
        slot.set_undefined();
        // array_used stays at high water mark; iteration skips empty slots.

        ctx.result.set_boolean(true);
    } else {
        ctx.result.set_boolean(false);
    }
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
// Set.prototype.keys() — ES6 §23.2.3.8
// Same as values() — returns a SetIterator with kind=1.
// ============================================================================
fn void builtin_set_proto_keys(BuiltinContext* ctx) {
    create_set_iterator(ctx, 1);
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
// Set.prototype[@@iterator] — ES6 §23.2.3.9
// Same as values().
// ============================================================================
fn void builtin_set_proto_symbol_iter(BuiltinContext* ctx) {
    create_set_iterator(ctx, 0);
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
        ctx.result.set_undefined();
        return;
    }

    uint idx = (*iter.extra_ptr()).iter.index;
    uint kind = (*iter.extra_ptr()).iter.kind;

    bool done = false;
    TVal value;
    value.set_undefined();

    // Skip over empty (deleted) slots — array_used is high water mark,
    // and array_part() may contain undefined slots from deletes.
    TVal* entries = target.array_part();
    if (entries != null) {
        while (idx < target.array_used && entries[idx].is_undefined()) {
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
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_str = builtin_intern_string(ctx.heap, "object is not a function");
            if (msg_str != null) {
                TVal msg_val;
                msg_val.set_string(msg_str);
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
            }
            TVal err_val;
            err_val.set_object(err);
            ctx.should_throw = true;
            ctx.throw_value = err_val;
        }
        ctx.result.set_undefined();
        return;
    }

    TVal thisArg;
    if (ctx.argc >= 2) { thisArg = ctx.regs[ctx.base_reg + 1]; } else { thisArg.set_undefined(); }

    TVal* entries = set.array_part();
    uint used = set.array_used;
    for (uint i = 0; i < used; i++) {
        TVal value = entries[i];
        if (value.is_undefined()) continue;  // skip deleted slot

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
// Set constructor registration
// ============================================================================

fn bool register_set_constructor(EnvRecord* global_env, Heap* heap) {
    // Create Set prototype
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.SET);
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
    // Add .keys() method
    if (!register_string_proto_method(proto, heap, "keys", BUILTIN_SET_PROTO_KEYS)) return false;
    // Add .values() method
    if (!register_string_proto_method(proto, heap, "values", BUILTIN_SET_PROTO_VALUES)) return false;
    // Add .entries() method
    if (!register_string_proto_method(proto, heap, "entries", BUILTIN_SET_PROTO_ENTRIES)) return false;
    // Add .forEach() method
    if (!register_string_proto_method(proto, heap, "forEach", BUILTIN_SET_PROTO_FOREACH)) return false;
    // Add [Symbol.iterator] = values
    HString* iter_sym = ensure_iterator_symbol(heap);
    if (iter_sym != null) {
        HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
        if (catch err = fn_raw) return false;
        HObject* fn_obj = fn_raw;
        (*fn_obj.extra_ptr()).func.builtin_fn_index = (int)BUILTIN_SET_PROTO_SYMBOL_ITER;
        fn_obj.flags.callable = true;
        fn_obj.prototype = heap.function_proto;
        // Set .name
        HString* name_key = builtin_intern_string(heap, "name");
        HString* name_val = builtin_intern_string(heap, "[Symbol.iterator]");
        if (name_key != null && name_val != null) {
            TVal name_tv;
            name_tv.set_string(name_val);
            fn_obj.put_prop(name_key, name_tv, hobject::PROP_FLAGS_NWC);
        }
        // Set .length = 0
        HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
        if (len_key != null) {
            TVal len_tv;
            len_tv.set_fastint(0);
            fn_obj.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NWC);
        }
        TVal iter_tv;
        iter_tv.set_object(fn_obj);
proto.put_prop(iter_sym, iter_tv, hobject::PROP_FLAGS_WC);
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

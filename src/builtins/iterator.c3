/// Iterator protocol: %IteratorPrototype%, Array/String/Map/Set iterators.
module duktape::builtins;
import duktape::types;
import libc;

import duktape::heap;
import duktape::hstring;
import duktape::hobject;

// ============================================================================
// Iterator protocol — built-in @@iterator methods and .next() functions
// ============================================================================

/// Array.prototype[Symbol.iterator] — creates an array iterator object.
fn void builtin_array_proto_symbol_iter(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;

    // Get `this` — must be an object
    TVal this_val = ctx.this_val;
    HObject* iterable;
    if (this_val.is_object()) {
        iterable = (HObject*)this_val.get_heapptr();
    } else {
        // Non-object `this`: wrap it
        HObject*? wrapped = heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err = wrapped) { ctx.result.set_undefined(); return; }
        iterable = wrapped;
    }

    // Create an ARRAY_ITERATOR object
    HObject*? iter_raw = heap.alloc_object(hobject::ObjClass.ARRAY_ITERATOR);
    if (catch err = iter_raw) { ctx.result.set_undefined(); return; }
    HObject* iter = iter_raw;
    iter.iterator_target = iterable;
    iter.iterator_index = 0;
    iter.prototype = heap.iterator_proto;

    // Add .next method as an own property
    HString* next_key = builtin_intern_string(heap, "next");
    if (next_key != null) {
        HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
        if (try fn_obj = fn_raw) {
            fn_obj.extra.func.builtin_fn_index = (int)BUILTIN_ARRAY_ITERATOR_NEXT;
            fn_obj.extra.func.callable_kind = hobject::CallableKind.BUILTIN_FN;
            fn_obj.flags.callable = true;
            fn_obj.prototype = heap.function_proto;
            TVal fn_tv;
            fn_tv.set_object(fn_obj);
            iter.put_prop(next_key, fn_tv, hobject::PROP_FLAGS_NWC);
        }
    }

    ctx.result.set_object(iter);
}

/// Helper: create an array iterator with a specific kind.
/// kind: 0=value (default), 1=key, 2=key+value (entries)
fn void create_array_iterator(BuiltinContext* ctx, uint kind) {
    Heap* heap = ctx.heap;
    TVal this_val = ctx.this_val;
    HObject* iterable;
    if (this_val.is_object()) {
        iterable = (HObject*)this_val.get_heapptr();
    } else {
        HObject*? wrapped = heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err = wrapped) { ctx.result.set_undefined(); return; }
        iterable = wrapped;
    }
    HObject*? iter_raw = heap.alloc_object(hobject::ObjClass.ARRAY_ITERATOR);
    if (catch err = iter_raw) { ctx.result.set_undefined(); return; }
    HObject* iter = iter_raw;
    iter.iterator_target = iterable;
    iter.iterator_index = 0;
    iter.iterator_kind = kind;
    iter.prototype = heap.iterator_proto;
    HString* next_key = builtin_intern_string(heap, "next");
    if (next_key != null) {
        HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
        if (try fn_obj = fn_raw) {
            fn_obj.extra.func.builtin_fn_index = (int)BUILTIN_ARRAY_ITERATOR_NEXT;
            fn_obj.extra.func.callable_kind = hobject::CallableKind.BUILTIN_FN;
            fn_obj.flags.callable = true;
            fn_obj.prototype = heap.function_proto;
            TVal fn_tv;
            fn_tv.set_object(fn_obj);
            iter.put_prop(next_key, fn_tv, hobject::PROP_FLAGS_NWC);
        }
    }
    ctx.result.set_object(iter);
}

/// Helper: create a Map iterator with a specific kind.
/// kind: 0=values, 1=keys, 2=entries
fn void create_map_iterator(BuiltinContext* ctx, uint kind) {
    Heap* heap = ctx.heap;
    HObject* map = check_map(ctx);
    if (map == null) { ctx.result.set_undefined(); return; }

    HObject*? iter_raw = heap.alloc_object(hobject::ObjClass.MAP_ITERATOR);
    if (catch err = iter_raw) { ctx.result.set_undefined(); return; }
    HObject* iter = iter_raw;
    iter.iterator_target = map;
    iter.iterator_index = 0;
    iter.iterator_kind = kind;
    iter.prototype = heap.iterator_proto;

    HString* next_key = builtin_intern_string(heap, "next");
    if (next_key != null) {
        HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
        if (try fn_obj = fn_raw) {
            fn_obj.extra.func.builtin_fn_index = (int)BUILTIN_MAP_ITERATOR_NEXT;
            fn_obj.extra.func.callable_kind = hobject::CallableKind.BUILTIN_FN;
            fn_obj.flags.callable = true;
            fn_obj.prototype = heap.function_proto;
            TVal fn_tv;
            fn_tv.set_object(fn_obj);
            iter.put_prop(next_key, fn_tv, hobject::PROP_FLAGS_NWC);
        }
    }
    ctx.result.set_object(iter);
}

/// Helper: create a Set iterator with a specific kind.
/// kind: 0=values, 1=keys, 2=entries
fn void create_set_iterator(BuiltinContext* ctx, uint kind) {
    Heap* heap = ctx.heap;
    HObject* set = check_set(ctx);
    if (set == null) { ctx.result.set_undefined(); return; }

    HObject*? iter_raw = heap.alloc_object(hobject::ObjClass.SET_ITERATOR);
    if (catch err = iter_raw) { ctx.result.set_undefined(); return; }
    HObject* iter = iter_raw;
    iter.iterator_target = set;
    iter.iterator_index = 0;
    iter.iterator_kind = kind;
    iter.prototype = heap.iterator_proto;

    HString* next_key = builtin_intern_string(heap, "next");
    if (next_key != null) {
        HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
        if (try fn_obj = fn_raw) {
            fn_obj.extra.func.builtin_fn_index = (int)BUILTIN_SET_ITERATOR_NEXT;
            fn_obj.extra.func.callable_kind = hobject::CallableKind.BUILTIN_FN;
            fn_obj.flags.callable = true;
            fn_obj.prototype = heap.function_proto;
            TVal fn_tv;
            fn_tv.set_object(fn_obj);
            iter.put_prop(next_key, fn_tv, hobject::PROP_FLAGS_NWC);
        }
    }
    ctx.result.set_object(iter);
}
fn void builtin_array_proto_values(BuiltinContext* ctx) {
    create_array_iterator(ctx, 0);
}

/// Array.prototype.keys — ES2015 §22.1.3.17 (kind=1)
fn void builtin_array_proto_keys(BuiltinContext* ctx) {
    create_array_iterator(ctx, 1);
}

/// Array.prototype.entries — ES2015 §22.1.3.5 (kind=2)
fn void builtin_array_proto_entries(BuiltinContext* ctx) {
    create_array_iterator(ctx, 2);
}

/// String.prototype[Symbol.iterator] — creates a string iterator object.
fn void builtin_string_proto_symbol_iter(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;

    // Get `this` — must be a string or String object
    TVal this_val = ctx.this_val;
    HString* str_data = null;
    if (this_val.is_string()) {
        str_data = (HString*)this_val.get_heapptr();
    } else if (this_val.is_object()) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        if (obj.extra.prim.primitive_value.is_string()) {
            str_data = (HString*)obj.extra.prim.primitive_value.get_heapptr();
        }
    }

    if (str_data == null) {
        ctx.result.set_undefined();
        return;
    }

    // Create a STRING_ITERATOR object
    HObject*? iter_raw = heap.alloc_object(hobject::ObjClass.STRING_ITERATOR);
    if (catch err = iter_raw) { ctx.result.set_undefined(); return; }
    HObject* iter = iter_raw;
    // Store the string as primitive_value (for GC tracing via mark_tval)
    iter.extra.prim.primitive_value.set_string(str_data);
    iter.iterator_index = 0;
    iter.prototype = heap.iterator_proto;

    // Add .next method as an own property
    HString* next_key = builtin_intern_string(heap, "next");
    if (next_key != null) {
        HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
        if (try fn_obj = fn_raw) {
            fn_obj.extra.func.builtin_fn_index = (int)BUILTIN_STRING_ITERATOR_NEXT;
            fn_obj.extra.func.callable_kind = hobject::CallableKind.BUILTIN_FN;
            fn_obj.flags.callable = true;
            fn_obj.prototype = heap.function_proto;
            TVal fn_tv;
            fn_tv.set_object(fn_obj);
            iter.put_prop(next_key, fn_tv, hobject::PROP_FLAGS_NWC);
        }
    }

    ctx.result.set_object(iter);
}

/// %IteratorPrototype%[@@iterator] (ES6 §25.1.2.1) — returns `this`.
fn void builtin_iterator_proto_symbol_iter(BuiltinContext* ctx) {
    *ctx.result = ctx.this_val;
}

/// Array iterator .next() — returns {value, done}.
fn void builtin_array_iterator_next(BuiltinContext* ctx) {
    TVal this_val = ctx.this_val;
    Heap* heap = ctx.heap;

    if (!this_val.is_object()) {
        ctx.should_throw = true;
        ctx.result.set_undefined();
        return;
    }

    HObject* iter = (HObject*)this_val.get_heapptr();
    if (iter.get_class() != hobject::ObjClass.ARRAY_ITERATOR) {
        ctx.should_throw = true;
        ctx.result.set_undefined();
        return;
    }

    HObject* target = iter.iterator_target;
    if (target == null) {
        ctx.result.set_undefined();
        return;
    }

    uint idx = iter.iterator_index;

    // Check if done — compare against target.array_used (fast path for arrays)
    bool done = false;
    TVal value;
    value.set_undefined();

    if (target.get_class() == hobject::ObjClass.ARRAY && target.array_part() != null) {
        if (idx >= target.array_used) {
            done = true;
        } else {
            TVal? elem = target.get_array_idx(idx);
            if (try v = elem) {
                value = v;
            } else {
                value.set_undefined();
            }
        }
    } else {
        // Fallback: use .length property
        TVal? len_val = target.get_prop_proto((HString*)heap.strs[heap::BuiltinStr.LENGTH]);
        long len = 0;
        if (try lv = len_val) {
            if (lv.is_fastint()) {
                len = lv.get_fastint();
            } else if (lv.is_number()) {
                len = (long)lv.get_number();
            }
        }
        if ((long)idx >= len) {
            done = true;
        } else {
            // Get element via stringified index key
            char[32] idx_buf;
            int idx_len = libc::snprintf(&idx_buf[0], 32, "%u", idx);
            uint idx_hash = heap.hash_string(idx_buf[:idx_len]);
            HString* idx_str = heap.str_table_lookup(idx_buf[:idx_len], idx_hash);
            if (idx_str == null) {
                HString*? new_str = hstring::hstring_alloc(heap, idx_buf[:idx_len], idx_hash);
                if (try s = new_str) {
                    heap.str_table_insert(s);
                    idx_str = s;
                }
            }
            if (idx_str != null) {
                TVal? elem_val = target.get_prop_proto(idx_str);
                if (try ev = elem_val) {
                    value = ev;
                } else {
                    value.set_undefined();
                }
            }
        }
    }

    if (!done) {
        iter.iterator_index = idx + 1;
    }

    // Adjust value based on iterator kind
    uint kind = iter.iterator_kind;
    if (kind == 1) {
        // keys() iterator: value = index
        value.set_fastint((long)idx);
    } else if (kind == 2) {
        // entries() iterator: value = [index, value]
        HObject*? pair_raw = heap.alloc_object(hobject::ObjClass.ARRAY);
        if (try pair = pair_raw) {
            pair.prototype = heap.array_proto;
            TVal idx_tv;
            idx_tv.set_fastint((long)idx);
            pair.set_array_idx(0, idx_tv);
            pair.set_array_idx(1, value);
            pair.array_used = 2;
            value.set_object(pair);
        }
    }
    // kind==0: value stays as-is (default/@@iterator)

    // Create result object: {value, done}
    HObject*? result_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = result_raw) { ctx.result.set_undefined(); return; }
    HObject* result = result_raw;
    result.prototype = null;

    // Set .value
    HString* value_key = (HString*)heap.strs[heap::BuiltinStr.VALUE];
    result.put_prop(value_key, value, hobject::PROP_FLAGS_WEC);

    // Set .done
    HString* done_key = (HString*)heap.strs[heap::BuiltinStr.DONE];
    TVal done_tv;
    done_tv.set_boolean(done);
    result.put_prop(done_key, done_tv, hobject::PROP_FLAGS_WEC);

    ctx.result.set_object(result);
}

/// String iterator .next() — returns {value, done}.
fn void builtin_string_iterator_next(BuiltinContext* ctx) {
    TVal this_val = ctx.this_val;
    Heap* heap = ctx.heap;

    if (!this_val.is_object()) {
        ctx.should_throw = true;
        ctx.result.set_undefined();
        return;
    }

    HObject* iter = (HObject*)this_val.get_heapptr();
    if (iter.get_class() != hobject::ObjClass.STRING_ITERATOR) {
        ctx.should_throw = true;
        ctx.result.set_undefined();
        return;
    }

    HString* str = (HString*)iter.extra.prim.primitive_value.get_heapptr();
    if (str == null) {
        ctx.result.set_undefined();
        return;
    }

    uint idx = iter.iterator_index;
    char[] data = str.get_data();

    // Check if done — for simplicity, iterate by code units (bytes for ASCII)
    // TODO: full Unicode support with code point iteration
    if (idx >= data.len) {
        // Done — return {value: undefined, done: true}
        HObject*? result_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err = result_raw) { ctx.result.set_undefined(); return; }
        HObject* result = result_raw;
        result.prototype = null;
        HString* done_key = (HString*)heap.strs[heap::BuiltinStr.DONE];
        TVal done_tv;
        done_tv.set_boolean(true);
        result.put_prop(done_key, done_tv, hobject::PROP_FLAGS_WEC);
        HString* value_key = (HString*)heap.strs[heap::BuiltinStr.VALUE];
        TVal undef;
        undef.set_undefined();
        result.put_prop(value_key, undef, hobject::PROP_FLAGS_WEC);
        ctx.result.set_object(result);
        return;
    }

    iter.iterator_index = idx + 1;

    // Create result object: {value: char, done: false}
    HObject*? result_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = result_raw) { ctx.result.set_undefined(); return; }
    HObject* result = result_raw;
    result.prototype = null;

    // Set .value — single character string
    HString* value_key = (HString*)heap.strs[heap::BuiltinStr.VALUE];
    char[1] ch = { data[idx] };
    HString* char_str = heap.str_intern(ch[:1]);
    if (char_str != null) {
        TVal value_tv;
        value_tv.set_string(char_str);
        result.put_prop(value_key, value_tv, hobject::PROP_FLAGS_WEC);
    }

    // Set .done
    HString* done_key = (HString*)heap.strs[heap::BuiltinStr.DONE];
    TVal done_tv;
    done_tv.set_boolean(false);
    result.put_prop(done_key, done_tv, hobject::PROP_FLAGS_WEC);

    ctx.result.set_object(result);
}

/// Create %IteratorPrototype% (ES6 §25.1.2).
/// %IteratorPrototype% has [Symbol.iterator]() that returns `this`.
fn bool register_iterator_prototype(Heap* heap) {
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;  // will be wired to object_proto later
    heap.iterator_proto = proto;

    // Add [Symbol.iterator]() → returns `this`
    HString* iter_sym = ensure_iterator_symbol(heap);
    if (iter_sym != null) {
        HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
        if (catch err = fn_raw) return false;
        HObject* fn_obj = fn_raw;
        fn_obj.extra.func.builtin_fn_index = (int)BUILTIN_ITERATOR_PROTO_SYMBOL_ITER;
        fn_obj.extra.func.callable_kind = hobject::CallableKind.BUILTIN_FN;
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
        proto.put_prop(iter_sym, iter_tv, hobject::PROP_FLAGS_NWC);
    }

    return true;
}

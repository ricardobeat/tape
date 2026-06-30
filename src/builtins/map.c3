/// Map constructor and Map.prototype methods.
module duktape::builtins;
import duktape::types;
import std::math;
import duktape::hstring;
import duktape::env;

import duktape::heap;
import duktape::hobject;

// Differs from === only in that NaN equals NaN.
// ============================================================================
fn bool same_value_zero(TVal a, TVal b) {
    if (a.get_tag() == b.get_tag()) {
        switch (a.get_tag()) {
            case UNDEFINED: return true;
            case NULL_VAL:  return true;
            case BOOLEAN:   return a.get_boolean() == b.get_boolean();
            case NUMBER:
                if (math::is_nan(a.get_number()) && math::is_nan(b.get_number())) return true;
                return a.get_number() == b.get_number();
            case FASTINT:   return a.get_fastint() == b.get_fastint();
            case STRING:    return a.get_heapptr() == b.get_heapptr();
            case OBJECT:    return a.get_heapptr() == b.get_heapptr();
            default: return false;
        }
    }
    if ((a.is_number() && b.is_fastint()) || (a.is_fastint() && b.is_number())) {
        double av = a.is_fastint() ? (double)a.get_fastint() : a.get_number();
        double bv = b.is_fastint() ? (double)b.get_fastint() : b.get_number();
        return av == bv;
    }
    return false;
}

// ============================================================================
// SameValue comparison (ES6 §7.2.9)
// Used by Object.is.
// Differs from SameValueZero in that +0 !== -0.
// ============================================================================
fn bool same_value(TVal a, TVal b) {
    if (a.get_tag() == b.get_tag()) {
        switch (a.get_tag()) {
            case UNDEFINED: return true;
            case NULL_VAL:  return true;
            case BOOLEAN:   return a.get_boolean() == b.get_boolean();
            case NUMBER:
                if (math::is_nan(a.get_number()) && math::is_nan(b.get_number())) return true;
                // +0 !== -0: check if both are zero with different signs
                if (a.get_number() == 0.0 && b.get_number() == 0.0) {
                    return 1.0 / a.get_number() == 1.0 / b.get_number();
                }
                return a.get_number() == b.get_number();
            case FASTINT:   return a.get_fastint() == b.get_fastint();
            case STRING:    return a.get_heapptr() == b.get_heapptr();
            case OBJECT:    return a.get_heapptr() == b.get_heapptr();
            default: return false;
        }
    }
    if ((a.is_number() && b.is_fastint()) || (a.is_fastint() && b.is_number())) {
        double av = a.is_fastint() ? (double)a.get_fastint() : a.get_number();
        double bv = b.is_fastint() ? (double)b.get_fastint() : b.get_number();
        if (math::is_nan(av) && math::is_nan(bv)) return true;
        // +0 !== -0: check if both are zero with different signs
        if (av == 0.0 && bv == 0.0) return 1.0 / av == 1.0 / bv;
        return av == bv;
    }
    return false;
}

// ============================================================================
// Map helpers
// ============================================================================

fn HObject* check_map(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        if (obj.flags.obj_class == hobject::ObjClass.MAP) return obj;
    }
    // TypeError
    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_str = builtin_intern_string(ctx.heap,
            "Map.prototype method called on incompatible value");
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

/// Find the index in array_part where a key matches. Returns -1 if not found.
/// Map entries are stored as [k0, v0, k1, v1, ...] in array_part.
fn int map_find_key(HObject* map, TVal key) {
    uint count = map.array_used;
    for (uint i = 0; i < count; i += 2) {
        if (same_value_zero(map.array_part()[i], key)) {
            return (int)i;
        }
    }
    return -1;
}

// ============================================================================
// Map constructor (ES6 §23.1.1)
// ============================================================================
fn void builtin_map(BuiltinContext* ctx) {
    // ES6 §23.1.1 step 1: throw TypeError if NewTarget is undefined.
    if (!ctx.is_constructor) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err = err_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_str = builtin_intern_string(ctx.heap, "Constructor Map requires 'new'");
        if (msg_str != null) {
            TVal msg_val; msg_val.set_string(msg_str);
            err.put_prop(builtin_intern_string(ctx.heap, "message"), msg_val, hobject::PROP_FLAGS_WC);
        }
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
        return;
    }
    HObject*? map_raw = ctx.heap.alloc_object(hobject::ObjClass.MAP);
    if (catch err = map_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* map = map_raw;
    map.prototype = ctx.heap.map_proto;

    // If iterable argument, populate map per ES6 §23.1.1.1.5 AddEntriesFromIterable.
    // The spec requires getting `set` (the adder) and calling it as Call(adder, map, k, v)
    // for each entry so user-overridable .set is observed.
    if (ctx.argc >= 1) {
        TVal arg = ctx.regs[ctx.base_reg];
        if (!arg.is_null() && !arg.is_undefined()) {
            if (!arg.is_object()) {
                // Non-object iterables throw TypeError per ES6 §23.1.1 step 6
                HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = ctx.heap.type_err_proto;
                    HString* msg_str = builtin_intern_string(ctx.heap, "Map constructor argument is not an object");
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
            // ES6 §23.1.1 step 6: Get(map, "set"); must throw/return abruptly.
            TVal map_tv; map_tv.set_object(map);
            HString* set_key = builtin_intern_string(ctx.heap, "set");
            TVal adder;
            adder.set_undefined();
            if (set_key != null) {
                if (catch err_g = map.get_prop_proto(set_key)) {
                    // Re-throw via ctx.
                    if (ctx.heap.has_error) {
                        ctx.should_throw = true;
                        ctx.throw_value = ctx.heap.error_value;
                        ctx.heap.has_error = false;
                    }
                    ctx.result.set_undefined();
                    return;
                }
                TVal? adder_opt = map.get_prop_proto(set_key);
                if (try av = adder_opt) adder = av;
            }
            bool adder_callable = adder.is_lightfunc() ||
                (adder.is_object() && adder.get_heapptr() != null &&
                 ((HObject*)adder.get_heapptr()).is_callable());
            if (!adder_callable) {
                HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = ctx.heap.type_err_proto;
                    HString* msg_str = builtin_intern_string(ctx.heap, "Map.prototype.set is not callable");
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
            // Iterate via @@iterator if available, otherwise plain array indexing.
            HObject* iterable = (HObject*)arg.get_heapptr();
            HString* iter_sym = ensure_iterator_symbol(ctx.heap);
            if (iter_sym == null) { ctx.result.set_undefined(); return; }
            TVal iter_fn = iterable.get_prop_proto(iter_sym)!!;
            bool iter_callable = iter_fn.is_lightfunc() ||
                (iter_fn.is_object() && iter_fn.get_heapptr() != null &&
                 ((HObject*)iter_fn.get_heapptr()).is_callable());
            if (!iter_callable) {
                // Fall back to simple array-like iteration. Per ES6 §23.1.1.2 SetStatus
                // step 6: k = Get(next, "key"); v = Get(next, "value"); status = Call(adder, M, k, v).
                uint len = array_get_length(iterable, ctx.heap);
                for (uint i = 0; i < len; i++) {
                    TVal pair = array_get_elem(iterable, i, ctx.heap);
                    if (pair.is_object() && pair.get_heapptr() != null) {
                        HObject* pair_obj = (HObject*)pair.get_heapptr();
                        TVal k = array_get_elem(pair_obj, 0, ctx.heap);
                        TVal v = array_get_elem(pair_obj, 1, ctx.heap);
                        TVal[2] adder_args = { k, v };
                        TVal map_tv2; map_tv2.set_object(map);
                        ctx.heap.call_fn(ctx.vm, adder, &adder_args[0], 2, map_tv2);
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
                // Iterator-based path per ES6 §23.1.1.1.5 AddEntriesFromIterable.
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

                    // Get entry value [key, value]
                    HString* value_key = builtin_intern_string(ctx.heap, "value");
                    TVal val_tv;
                    val_tv.set_undefined();
                    if (value_key != null) {
                        TVal? vv = res_obj.get_prop_proto(value_key);
                        if (try v = vv) { val_tv = v; }
                    }
                    if (val_tv.is_object() && val_tv.get_heapptr() != null) {
                        HObject* pair_obj = (HObject*)val_tv.get_heapptr();
                        TVal k = array_get_elem(pair_obj, 0, ctx.heap);
                        TVal v = array_get_elem(pair_obj, 1, ctx.heap);
                        TVal[2] adder_args = { k, v };
                        TVal map_tv2; map_tv2.set_object(map);
                        ctx.heap.call_fn(ctx.vm, adder, &adder_args[0], 2, map_tv2);
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

    ctx.result.set_object(map);
}

// ============================================================================
// Map.prototype.set(key, value) — ES6 §23.1.3.9
// ============================================================================
fn void builtin_map_proto_set(BuiltinContext* ctx) {
    HObject* map = check_map(ctx);
    if (map == null) { ctx.result.set_undefined(); return; }
    if (ctx.argc < 1) { ctx.result.set_undefined(); return; }

    TVal key = ctx.regs[ctx.base_reg];
    TVal value = ctx.regs[ctx.base_reg + 1];  // undefined if not provided

    int found = map_find_key(map, key);
    if (found >= 0) {
        // Update existing entry's value — decref old string value if any.
        TVal* v_slot = &map.array_part()[(uint)found + 1];
        if (v_slot.is_string()) ctx.heap.decref_tval(v_slot);
        *v_slot = value;
    } else {
        uint cnt = map.array_used;
        map.set_array_idx(cnt, key);
        map.set_array_idx(cnt + 1, value);
    }

    // Return the map itself
    ctx.result.set_object(map);
}

// ============================================================================
// Map.prototype.size getter — ES6 §23.1.3.10
// Counts non-empty entries (since delete marks slots as undefined).
// ============================================================================
fn void builtin_map_proto_size_get(BuiltinContext* ctx) {
    HObject* map = check_map(ctx);
    if (map == null) return;
    uint count = 0;
    TVal* arr = map.array_part();
    if (arr != null) {
        for (uint i = 0; i + 1 < map.array_used; i += 2) {
            if (!arr[i].is_undefined()) count++;
        }
    }
    ctx.result.set_fastint((long)count);
}

// ============================================================================
// Map.prototype.get(key) — ES6 §23.1.3.6
// ============================================================================
fn void builtin_map_proto_get(BuiltinContext* ctx) {
    HObject* map = check_map(ctx);
    if (map == null) { ctx.result.set_undefined(); return; }
    if (ctx.argc < 1) { ctx.result.set_undefined(); return; }

    TVal key = ctx.regs[ctx.base_reg];
    int found = map_find_key(map, key);
    if (found >= 0) {
        *ctx.result = map.array_part()[(uint)found + 1];
    } else {
        ctx.result.set_undefined();
    }
}

// ============================================================================
// Map.prototype.has(key) — ES6 §23.1.3.7
// ============================================================================
fn void builtin_map_proto_has(BuiltinContext* ctx) {
    HObject* map = check_map(ctx);
    if (map == null) { ctx.result.set_undefined(); return; }
    if (ctx.argc < 1) { ctx.result.set_boolean(false); return; }

    TVal key = ctx.regs[ctx.base_reg];
    int found = map_find_key(map, key);
    ctx.result.set_boolean((found >= 0));
}

// ============================================================================
// Map.prototype.delete(key) — ES6 §23.1.3.3
// Per ES6 spec, deletion marks the entry as "empty" (does not remove the slot)
// so concurrent iteration sees the deletion but new entries appear at the end.
// ============================================================================
fn void builtin_map_proto_delete(BuiltinContext* ctx) {
    HObject* map = check_map(ctx);
    if (map == null) { ctx.result.set_undefined(); return; }
    if (ctx.argc < 1) { ctx.result.set_boolean(false); return; }

    TVal key = ctx.regs[ctx.base_reg];
    int found = map_find_key(map, key);
    if (found >= 0) {
        // Mark slots as undefined rather than shifting — iteration over the
        // map must skip empty slots but new entries (added during forEach)
        // must still be visited. array_used stays as high water mark so the
        // iterator walks the full range.
        TVal* k_slot = &map.array_part()[(uint)found];
        TVal* v_slot = &map.array_part()[(uint)found + 1];
        if (k_slot.is_string()) ctx.heap.decref_tval(k_slot);
        if (v_slot.is_string()) ctx.heap.decref_tval(v_slot);
        k_slot.set_undefined();
        v_slot.set_undefined();

        ctx.result.set_boolean(true);
    } else {
        ctx.result.set_boolean(false);
    }
}

// ============================================================================
// Map.prototype.clear() — ES6 §23.1.3.1
// ============================================================================
fn void builtin_map_proto_clear(BuiltinContext* ctx) {
    HObject* map = check_map(ctx);
    if (map == null) { ctx.result.set_undefined(); return; }

    // Reset array_part
    uint cnt = map.array_used;
    for (uint i = 0; i < cnt; i++) {
        map.array_part()[i].set_undefined();
    }
    map.array_used = 0;

    ctx.result.set_undefined();
}

// ============================================================================
// Map.prototype.keys() — ES6 §23.1.3.8
// Returns a MapIterator with kind=1 (keys).
// ============================================================================
fn void builtin_map_proto_keys(BuiltinContext* ctx) {
    create_map_iterator(ctx, 1);
}

// ============================================================================
// Map.prototype.data.values() — ES6 §23.1.3.11
// Returns a MapIterator with kind=0 (values).
// ============================================================================
fn void builtin_map_proto_values(BuiltinContext* ctx) {
    create_map_iterator(ctx, 0);
}

// ============================================================================
// Map.prototype.entries() — ES6 §23.1.3.4
// Returns a MapIterator with kind=2 (entries).
// ============================================================================
fn void builtin_map_proto_entries(BuiltinContext* ctx) {
    create_map_iterator(ctx, 2);
}

// ============================================================================
// Map.prototype[@@iterator] — ES6 §23.1.3.10
// Same as entries().
// ============================================================================
fn void builtin_map_proto_symbol_iter(BuiltinContext* ctx) {
    create_map_iterator(ctx, 2);
}

// ============================================================================
// MapIterator.prototype.next() — ES6 §23.1.5.2.1
// ============================================================================
fn void builtin_map_iterator_next(BuiltinContext* ctx) {
    TVal this_val = ctx.this_val;
    Heap* heap = ctx.heap;

    if (!this_val.is_object()) {
        ctx.should_throw = true;
        ctx.result.set_undefined();
        return;
    }

    HObject* iter = (HObject*)this_val.get_heapptr();
    if (iter.get_class() != hobject::ObjClass.MAP_ITERATOR) {
        ctx.should_throw = true;
        ctx.result.set_undefined();
        return;
    }

    HObject* target = (*iter.extra_ptr()).iter.target;
    if (target == null) {
        ctx.result.set_undefined();
        return;
    }

    uint slot_idx = (*iter.extra_ptr()).iter.index * 2;  // Map entries are [k0,v0,k1,v1,...]
    uint kind = (*iter.extra_ptr()).iter.kind;

    bool done = false;
    TVal value;
    value.set_undefined();

    // Skip over empty (deleted) slots — array_used is high water mark,
    // and array_part() may contain undefined-keyed slots from deletes.
    while (slot_idx < target.array_used && target.array_part() != null &&
           target.array_part()[slot_idx].is_undefined()) {
        slot_idx += 2;
    }

    if (slot_idx < target.array_used) {
        TVal* entries = target.array_part();
        if (entries != null) {
            if (kind == 1) {
                // keys: return key at slot_idx
                value = entries[slot_idx];
            } else if (kind == 0) {
                // values: return value at slot_idx+1
                value = entries[slot_idx + 1];
            } else {
                // entries: return [key, value]
                HObject*? pair_raw = heap.alloc_object(hobject::ObjClass.ARRAY);
                if (try pair = pair_raw) {
                    pair.prototype = heap.array_proto;
                    pair.set_array_idx(0, entries[slot_idx]);
                    pair.set_array_idx(1, entries[slot_idx + 1]);
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
            (*iter.extra_ptr()).iter.index = (slot_idx / 2) + 1;
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
// Map.prototype.forEach(callbackfn[, thisArg]) — ES6 §23.1.3.5
// ============================================================================
fn void builtin_map_proto_forEach(BuiltinContext* ctx) {
    HObject* map = check_map(ctx);
    if (map == null) { ctx.result.set_undefined(); return; }

    if (ctx.argc < 1) {
        // Missing callback throws TypeError
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
    if (!(callback.is_object() && callback.get_heapptr() != null && ((HObject*)callback.get_heapptr()).flags.callable)) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err_k = err_raw) { ctx.result.set_undefined(); return; }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_str = builtin_intern_string(ctx.heap, "object is not a function");
        if (msg_str != null) {
            TVal msg_val;
            msg_val.set_string(msg_str);
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
        }
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
        ctx.result.set_undefined();
        return;
    }

    // ES6 §23.1.3.5 — forEach iterates all non-empty entries and calls
    // callbackfn(value, key, map). Entries deleted before being visited are
    // skipped; entries added during forEach (appended) are visited.
    TVal thisArg;
    if (ctx.argc >= 2) { thisArg = ctx.regs[ctx.base_reg + 1]; } else { thisArg.set_undefined(); }

    TVal* entries = map.array_part();
    uint used = map.array_used;
    for (uint i = 0; i + 1 < used; i += 2) {
        TVal key = entries[i];
        if (key.is_undefined()) continue;  // skip deleted slot
        TVal value = entries[i + 1];

        TVal[3] args;
        args[0] = value;
        args[1] = key;
        args[2].set_object((void*)map);
        ctx.heap.call_fn(ctx.vm, callback, &args[0], 3, thisArg);
        if (ctx.heap.has_error) {
            ctx.should_throw = true;
            ctx.throw_value = ctx.heap.error_value;
            ctx.heap.has_error = false;
            ctx.result.set_undefined();
            return;
        }
        // After callback, refresh used (entries may have been added).
        used = map.array_used;
        entries = map.array_part();
    }

    ctx.result.set_undefined();
}

// ============================================================================
// Map constructor registration
// ============================================================================

fn bool register_map_constructor(EnvRecord* global_env, Heap* heap) {
    // Create Map prototype
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.MAP);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;
    heap.map_proto = proto;

    // Add .set(key, value) method
    if (!register_string_proto_method(proto, heap, "set", BUILTIN_MAP_PROTO_SET)) return false;
    // Add .get(key) method
    if (!register_string_proto_method(proto, heap, "get", BUILTIN_MAP_PROTO_GET)) return false;
    // Add .has(key) method
    if (!register_string_proto_method(proto, heap, "has", BUILTIN_MAP_PROTO_HAS)) return false;
    // Add .delete(key) method
    if (!register_string_proto_method(proto, heap, "delete", BUILTIN_MAP_PROTO_DELETE)) return false;
    // Add .clear() method
    if (!register_string_proto_method(proto, heap, "clear", BUILTIN_MAP_PROTO_CLEAR)) return false;
    // Add .keys() method
    if (!register_string_proto_method(proto, heap, "keys", BUILTIN_MAP_PROTO_KEYS)) return false;
    // Add .values() method
    if (!register_string_proto_method(proto, heap, "values", BUILTIN_MAP_PROTO_VALUES)) return false;
    // Add .entries() method
    if (!register_string_proto_method(proto, heap, "entries", BUILTIN_MAP_PROTO_ENTRIES)) return false;
    // Add .forEach() method
    if (!register_string_proto_method(proto, heap, "forEach", BUILTIN_MAP_PROTO_FOREACH)) return false;
    // Add [Symbol.iterator] = entries
    HString* iter_sym = ensure_iterator_symbol(heap);
    if (iter_sym != null) {
        HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
        if (catch err = fn_raw) return false;
        HObject* fn_obj = fn_raw;
        (*fn_obj.extra_ptr()).func.builtin_fn_index = (int)BUILTIN_MAP_PROTO_SYMBOL_ITER;
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
    
    // Set @@toStringTag on Map.prototype
    HString* tag_key = ensure_tostringtag_symbol(heap);
    if (tag_key != null) {
        TVal tag_tv;
        tag_tv.set_string(builtin_intern_string(heap, "Map"));
        proto.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC);
    }

    // Register .size as a getter accessor property (ES6 §23.1.3.10)
    {
        HString* size_key = builtin_intern_string(heap, "size");
        if (size_key != null) {
            HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
            if (catch err = fn_raw) return false;
            HObject* fn_obj = fn_raw;
            (*fn_obj.extra_ptr()).func.builtin_fn_index = (int)BUILTIN_MAP_PROTO_SIZE_GET;
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

    // Create Map constructor as a proper function object
    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)BUILTIN_MAP;

    // Set .constructor on Map.prototype
    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(ctor);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);

    // Set Map.prototype on the constructor (non-writable, non-enumerable, non-configurable)
    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    ctor.put_prop(prototype_key, proto_tv, proto_pflags);

    // Set Map.length
    HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    TVal length_tv;
    length_tv.set_fastint(0);
    ctor.put_prop(length_key, length_tv, hobject::PROP_FLAGS_NWC);

    // Map.prototype's [[Prototype]] is set later (to Object.prototype)

    // Register Map constructor globally
    uint hash = heap.hash_string("Map");
    HString* existing = heap.str_table_lookup("Map", hash);
    HString* map_key;
    if (existing != null) {
        map_key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, "Map", hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        map_key = new_key;
    }
    TVal map_val;
    map_val.set_object(ctor);
    set_func_ctor_name(ctor, heap, "Map");
    env::env_declare_nonenum(global_env, map_key, map_val);

    return true;
}

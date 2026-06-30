/// WeakMap constructor and WeakMap.prototype methods.
module duktape::builtins;
import duktape::types;
import duktape::hstring;
import duktape::env;

import duktape::heap;
import duktape::hobject;

// ============================================================================
// WeakMap helpers
// ============================================================================

fn HObject* check_weakmap(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        if (obj.flags.obj_class == hobject::ObjClass.WEAKMAP) return obj;
    }
    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_str = builtin_intern_string(ctx.heap,
            "WeakMap.prototype method called on incompatible value");
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

fn int weakmap_find_key(HObject* wm, TVal key) {
    uint count = wm.array_used;
    for (uint i = 0; i < count; i += 2) {
        if (same_value_zero(wm.array_part()[i], key)) {
            return (int)i;
        }
    }
    return -1;
}

// ============================================================================
// WeakMap constructor (ES6 §23.3.1)
// ============================================================================
fn void builtin_weakmap(BuiltinContext* ctx) {
    // ES6 §23.3.1.1 step 1: throw TypeError if NewTarget is undefined.
    if (!ctx.is_constructor) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err = err_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_str = builtin_intern_string(ctx.heap, "Constructor WeakMap requires 'new'");
        if (msg_str != null) {
            TVal msg_val; msg_val.set_string(msg_str);
            err.put_prop(builtin_intern_string(ctx.heap, "message"), msg_val, hobject::PROP_FLAGS_WC);
        }
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
        return;
    }
    HObject*? wm_raw = ctx.heap.alloc_object(hobject::ObjClass.WEAKMAP);
    if (catch err = wm_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* wm = wm_raw;
    wm.prototype = ctx.heap.weakmap_proto;

    if (ctx.argc >= 1 && ctx.is_constructor) {
        TVal arg = ctx.regs[ctx.base_reg];
        if (!arg.is_null() && !arg.is_undefined()) {
            if (!arg.is_object()) {
                HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = ctx.heap.type_err_proto;
                    HString* msg_str = builtin_intern_string(ctx.heap, "WeakMap constructor argument is not an object");
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
            // ES6 §23.3.1 step 7: Get(wm, "set"); must throw/return abruptly.
            // Use builtins_generic_get which invokes prototype accessors
            // correctly (per ES5 §8.12.3 / ES2020 §10.1.8.1 OrdinaryGet)
            // and propagates accessor-throwing to ctx.should_throw.
            TVal wm_tv; wm_tv.set_object(wm);
            HString* set_key = builtin_intern_string(ctx.heap, "set");
            TVal adder;
            adder.set_undefined();
            if (set_key != null) {
                TVal? adder_opt = builtins::builtins_generic_get(wm, set_key, ctx);
                if (catch err = adder_opt) {
                    // Thrown — builtins_generic_get already propagated
                    // the abort to ctx.should_throw. Bail.
                    ctx.result.set_undefined();
                    return;
                }
                adder = adder_opt;
            }
            bool adder_callable = adder.is_lightfunc() ||
                (adder.is_object() && adder.get_heapptr() != null &&
                 ((HObject*)adder.get_heapptr()).is_callable());
            if (!adder_callable) {
                HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = ctx.heap.type_err_proto;
                    HString* msg_str = builtin_intern_string(ctx.heap, "WeakMap.prototype.set is not callable");
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
                uint len = array_get_length(iterable, ctx.heap);
                for (uint i = 0; i < len; i++) {
                    TVal pair = array_get_elem(iterable, i, ctx.heap);
                    if (pair.is_object() && pair.get_heapptr() != null) {
                        HObject* pair_obj = (HObject*)pair.get_heapptr();
                        TVal k = array_get_elem(pair_obj, 0, ctx.heap);
                        TVal v = array_get_elem(pair_obj, 1, ctx.heap);
                        TVal[2] adder_args = { k, v };
                        TVal wm_tv2; wm_tv2.set_object(wm);
                        ctx.heap.call_fn(ctx.vm, adder, &adder_args[0], 2, wm_tv2);
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
                TVal iterator = ctx.heap.call_fn(ctx.vm, iter_fn, null, 0, arg);
                if (ctx.heap.has_error) {
                    ctx.should_throw = true;
                    ctx.throw_value = ctx.heap.error_value;
                    ctx.heap.has_error = false;
                    ctx.result.set_undefined();
                    return;
                }
                if (!iterator.is_object() || iterator.get_heapptr() == null) {
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
                        TVal wm_tv2; wm_tv2.set_object(wm);
                        ctx.heap.call_fn(ctx.vm, adder, &adder_args[0], 2, wm_tv2);
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

    ctx.result.set_object(wm);
}

// ============================================================================
// WeakMap.prototype.set(key, value) — ES6 §23.3.3.5
// ============================================================================
fn void builtin_weakmap_proto_set(BuiltinContext* ctx) {
    HObject* wm = check_weakmap(ctx);
    if (wm == null) { ctx.result.set_undefined(); return; }
    if (ctx.argc < 1) { ctx.result.set_undefined(); return; }

    TVal key = ctx.regs[ctx.base_reg];
    if (!key.is_object() || key.get_heapptr() == null) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_str = builtin_intern_string(ctx.heap, "Invalid value used as weak map key");
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

    TVal value = ctx.regs[ctx.base_reg + 1];
    int found = weakmap_find_key(wm, key);
    if (found >= 0) {
        wm.array_part()[(uint)found + 1] = value;
    } else {
        uint cnt = wm.array_used;
        wm.set_array_idx(cnt, key);
        wm.set_array_idx(cnt + 1, value);
    }

    ctx.result.set_object(wm);
}

// ============================================================================
// WeakMap.prototype.get(key) — ES6 §23.3.3.3
// ============================================================================
fn void builtin_weakmap_proto_get(BuiltinContext* ctx) {
    HObject* wm = check_weakmap(ctx);
    if (wm == null) { ctx.result.set_undefined(); return; }
    if (ctx.argc < 1) { ctx.result.set_undefined(); return; }

    TVal key = ctx.regs[ctx.base_reg];
    int found = weakmap_find_key(wm, key);
    if (found >= 0) {
        *ctx.result = wm.array_part()[(uint)found + 1];
    } else {
        ctx.result.set_undefined();
    }
}

// ============================================================================
// WeakMap.prototype.has(key) — ES6 §23.3.3.4
// ============================================================================
fn void builtin_weakmap_proto_has(BuiltinContext* ctx) {
    HObject* wm = check_weakmap(ctx);
    if (wm == null) { ctx.result.set_undefined(); return; }
    if (ctx.argc < 1) { ctx.result.set_boolean(false); return; }

    TVal key = ctx.regs[ctx.base_reg];
    int found = weakmap_find_key(wm, key);
    ctx.result.set_boolean((found >= 0));
}

// ============================================================================
// WeakMap.prototype.delete(key) — ES6 §23.3.3.2
// ============================================================================
fn void builtin_weakmap_proto_delete(BuiltinContext* ctx) {
    HObject* wm = check_weakmap(ctx);
    if (wm == null) { ctx.result.set_undefined(); return; }
    if (ctx.argc < 1) { ctx.result.set_boolean(false); return; }

    TVal key = ctx.regs[ctx.base_reg];
    int found = weakmap_find_key(wm, key);
    if (found >= 0) {
        uint cnt = wm.array_used;
        for (uint i = (uint)found; i + 2 < cnt; i++) {
            wm.array_part()[i] = wm.array_part()[i + 2];
        }
        wm.array_part()[cnt - 2].set_undefined();
        wm.array_part()[cnt - 1].set_undefined();
        wm.array_used = (ushort)(cnt - 2);

        ctx.result.set_boolean(true);
    } else {
        ctx.result.set_boolean(false);
    }
}

// ============================================================================
// WeakMap constructor registration
// ============================================================================

fn bool register_weakmap_constructor(EnvRecord* global_env, Heap* heap) {
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.WEAKMAP);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;
    heap.weakmap_proto = proto;

    if (!register_string_proto_method(proto, heap, "set", BUILTIN_WEAKMAP_PROTO_SET)) return false;
    if (!register_string_proto_method(proto, heap, "get", BUILTIN_WEAKMAP_PROTO_GET)) return false;
    if (!register_string_proto_method(proto, heap, "has", BUILTIN_WEAKMAP_PROTO_HAS)) return false;
    if (!register_string_proto_method(proto, heap, "delete", BUILTIN_WEAKMAP_PROTO_DELETE)) return false;

    // Set @@toStringTag
    HString* tag_key = ensure_tostringtag_symbol(heap);
    if (tag_key != null) {
        TVal tag_tv;
        tag_tv.set_string(builtin_intern_string(heap, "WeakMap"));
        proto.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC);
    }

    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)BUILTIN_WEAKMAP;

    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(ctor);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);

    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    ctor.put_prop(prototype_key, proto_tv, proto_pflags);

    HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    TVal length_tv;
    length_tv.set_fastint(0);
    ctor.put_prop(length_key, length_tv, hobject::PROP_FLAGS_NWC);

    uint hash = heap.hash_string("WeakMap");
    HString* existing = heap.str_table_lookup("WeakMap", hash);
    HString* wm_key;
    if (existing != null) {
        wm_key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, "WeakMap", hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        wm_key = new_key;
    }
    TVal wm_val;
    wm_val.set_object(ctor);
    env::env_declare_nonenum(global_env, wm_key, wm_val);

    return true;
}

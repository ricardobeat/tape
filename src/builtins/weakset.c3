/// WeakSet constructor and WeakSet.prototype methods.
module duktape::builtins;
import duktape::types;
import duktape::hstring;
import duktape::env;

import duktape::heap;
import duktape::hobject;

// ============================================================================
// WeakSet helpers
// ============================================================================

fn HObject* check_weakset(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        if (obj.flags.obj_class == hobject::ObjClass.WEAKSET) return obj;
    }
    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_str = builtin_intern_string(ctx.heap,
            "WeakSet.prototype method called on incompatible value");
        if (msg_str != null) {
            TVal msg_val;
            msg_val.set_string(msg_str);
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
        }
    }
    return null;
}

fn int weakset_find_value(HObject* ws, TVal val) {
    uint count = ws.array_used;
    for (uint i = 0; i < count; i++) {
        if (same_value_zero(ws.array_part()[i], val)) {
            return (int)i;
        }
    }
    return -1;
}

// ============================================================================
// WeakSet constructor (ES6 §23.4.1)
// ============================================================================
fn void builtin_weakset(BuiltinContext* ctx) {
    HObject*? ws_raw = ctx.heap.alloc_object(hobject::ObjClass.WEAKSET);
    if (catch err = ws_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* ws = ws_raw;
    ws.prototype = ctx.heap.weakset_proto;

    if (ctx.argc >= 1 && ctx.is_constructor) {
        TVal arg = ctx.regs[ctx.base_reg];
        if (arg.is_object() && arg.get_heapptr() != null) {
            HObject* iterable = (HObject*)arg.get_heapptr();
            uint len = array_get_length(iterable, ctx.heap);
            for (uint i = 0; i < len; i++) {
                TVal v = array_get_elem(iterable, i, ctx.heap);
                if (!v.is_object() || v.get_heapptr() == null) {
                    ctx.result.set_undefined();
                    return;
                }
                int found = weakset_find_value(ws, v);
                if (found < 0) {
                    ws.set_array_idx(ws.array_used, v);
                }
            }
        }
    }

    ctx.result.set_object(ws);
}

// ============================================================================
// WeakSet.prototype.add(value) — ES6 §23.4.3.1
// ============================================================================
fn void builtin_weakset_proto_add(BuiltinContext* ctx) {
    HObject* ws = check_weakset(ctx);
    if (ws == null) { ctx.result.set_undefined(); return; }
    if (ctx.argc < 1) { ctx.result.set_undefined(); return; }

    TVal value = ctx.regs[ctx.base_reg];
    if (!value.is_object() || value.get_heapptr() == null) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_str = builtin_intern_string(ctx.heap, "Invalid value used in weak set");
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

    int found = weakset_find_value(ws, value);
    if (found < 0) {
        ws.set_array_idx(ws.array_used, value);
    }

    ctx.result.set_object(ws);
}

// ============================================================================
// WeakSet.prototype.has(value) — ES6 §23.4.3.4
// ============================================================================
fn void builtin_weakset_proto_has(BuiltinContext* ctx) {
    HObject* ws = check_weakset(ctx);
    if (ws == null) { ctx.result.set_undefined(); return; }
    if (ctx.argc < 1) { ctx.result.set_boolean(false); return; }

    TVal value = ctx.regs[ctx.base_reg];
    int found = weakset_find_value(ws, value);
    ctx.result.set_boolean((found >= 0));
}

// ============================================================================
// WeakSet.prototype.delete(value) — ES6 §23.4.3.3
// ============================================================================
fn void builtin_weakset_proto_delete(BuiltinContext* ctx) {
    HObject* ws = check_weakset(ctx);
    if (ws == null) { ctx.result.set_undefined(); return; }
    if (ctx.argc < 1) { ctx.result.set_boolean(false); return; }

    TVal value = ctx.regs[ctx.base_reg];
    int found = weakset_find_value(ws, value);
    if (found >= 0) {
        uint cnt = ws.array_used;
        for (uint i = (uint)found; i + 1 < cnt; i++) {
            ws.array_part()[i] = ws.array_part()[i + 1];
        }
        ws.array_part()[cnt - 1].set_undefined();
        ws.array_used = cnt - 1;

        ctx.result.set_boolean(true);
    } else {
        ctx.result.set_boolean(false);
    }
}

// ============================================================================
// WeakSet constructor registration
// ============================================================================

fn bool register_weakset_constructor(EnvRecord* global_env, Heap* heap) {
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.WEAKSET);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;
    heap.weakset_proto = proto;

    if (!register_string_proto_method(proto, heap, "add", BUILTIN_WEAKSET_PROTO_ADD)) return false;
    if (!register_string_proto_method(proto, heap, "has", BUILTIN_WEAKSET_PROTO_HAS)) return false;
    if (!register_string_proto_method(proto, heap, "delete", BUILTIN_WEAKSET_PROTO_DELETE)) return false;

    // Set @@toStringTag
    HString* tag_key = ensure_tostringtag_symbol(heap);
    if (tag_key != null) {
        TVal tag_tv;
        tag_tv.set_string(builtin_intern_string(heap, "WeakSet"));
        proto.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC);
    }

    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    ctor.extra.func.builtin_fn_index = (int)BUILTIN_WEAKSET;
    ctor.extra.func.callable_kind = hobject::CallableKind.BUILTIN_FN;

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
    ctor.put_prop(length_key, length_tv, hobject::PROP_FLAGS_WC);

    uint hash = heap.hash_string("WeakSet");
    HString* existing = heap.str_table_lookup("WeakSet", hash);
    HString* ws_key;
    if (existing != null) {
        ws_key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, "WeakSet", hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        ws_key = new_key;
    }
    TVal ws_val;
    ws_val.set_object(ctor);
    env::env_declare_nonenum(global_env, ws_key, ws_val);

    return true;
}

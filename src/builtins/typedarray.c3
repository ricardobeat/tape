/// Minimal TypedArray constructors: Int8Array, Uint8Array, Uint8ClampedArray,
/// Int16Array, Uint16Array, Int32Array, Uint32Array, Float32Array, Float64Array.
///
/// This is a stub implementation that creates proper HObject instances with the
/// correct ObjClass and a "length" property.  Sufficient for Object.seal/freeze/
/// preventExtensions and basic type checks.
module duktape::builtins;

import duktape::types;
import duktape::env;
import duktape::hstring;
import duktape::hobject;
import duktape::heap;

// ============================================================================
// Shared constructor
// ============================================================================

/// Shared typed array constructor.  `obj_class` determines the internal class
/// (e.g. INT16ARRAY).  Creates an empty typed array with length=0.
fn void builtin_typed_array_shared(BuiltinContext* ctx, hobject::ObjClass obj_class, HObject* proto) {
    HObject*? raw = ctx.heap.alloc_object(obj_class);
    if (catch err = raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* obj = raw;
    obj.prototype = proto;

    // TypedArray instances have "length" = 0 (empty)
    HString* length_key = (HString*)ctx.heap.strs[heap::BuiltinStr.LENGTH];
    TVal length_tv;
    length_tv.set_fastint(0);
    obj.put_prop(length_key, length_tv, hobject::PROP_FLAGS_WC);

    ctx.result.set_object(obj);
}

// ============================================================================
// Per-type constructors
// ============================================================================

fn void builtin_int8array(BuiltinContext* ctx) {
    builtin_typed_array_shared(ctx, hobject::ObjClass.INT8ARRAY, ctx.heap.typedarray_proto);
}

fn void builtin_uint8array(BuiltinContext* ctx) {
    builtin_typed_array_shared(ctx, hobject::ObjClass.UINT8ARRAY, ctx.heap.typedarray_proto);
}

fn void builtin_uint8clampedarray(BuiltinContext* ctx) {
    builtin_typed_array_shared(ctx, hobject::ObjClass.UINT8CLAMPEDARRAY, ctx.heap.typedarray_proto);
}

fn void builtin_int16array(BuiltinContext* ctx) {
    builtin_typed_array_shared(ctx, hobject::ObjClass.INT16ARRAY, ctx.heap.typedarray_proto);
}

fn void builtin_uint16array(BuiltinContext* ctx) {
    builtin_typed_array_shared(ctx, hobject::ObjClass.UINT16ARRAY, ctx.heap.typedarray_proto);
}

fn void builtin_int32array(BuiltinContext* ctx) {
    builtin_typed_array_shared(ctx, hobject::ObjClass.INT32ARRAY, ctx.heap.typedarray_proto);
}

fn void builtin_uint32array(BuiltinContext* ctx) {
    builtin_typed_array_shared(ctx, hobject::ObjClass.UINT32ARRAY, ctx.heap.typedarray_proto);
}

fn void builtin_float32array(BuiltinContext* ctx) {
    builtin_typed_array_shared(ctx, hobject::ObjClass.FLOAT32ARRAY, ctx.heap.typedarray_proto);
}

fn void builtin_float64array(BuiltinContext* ctx) {
    builtin_typed_array_shared(ctx, hobject::ObjClass.FLOAT64ARRAY, ctx.heap.typedarray_proto);
}

// ============================================================================
// Registration
// ============================================================================

/// Register a single typed array constructor globally.
fn bool register_ta_ctor(EnvRecord* global_env, Heap* heap, char[] name, uint fn_index, HObject* proto) {
    // Create constructor as a proper HObject (not lightfunc) so it's constructable
    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)fn_index;

    // Set .name
    HString* name_key = builtin_intern_string(heap, "name");
    HString* name_val = builtin_intern_string(heap, name);
    if (name_key != null && name_val != null) {
        TVal name_tv;
        name_tv.set_string(name_val);
        ctor.put_prop(name_key, name_tv, hobject::PROP_FLAGS_NWC);
    }

    // Set .length = 0
    HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    TVal length_tv;
    length_tv.set_fastint(0);
    ctor.put_prop(length_key, length_tv, hobject::PROP_FLAGS_NWC);

    // Wire .prototype
    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    ctor.put_prop(prototype_key, proto_tv, proto_pflags);

    // Register globally
    uint hash = heap.hash_string(name);
    HString* existing = heap.str_table_lookup(name, hash);
    HString* key;
    if (existing != null) {
        key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, name, hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        key = new_key;
    }
    TVal val;
    val.set_object(ctor);
    env::env_declare_nonenum(global_env, key, val);
    return true;
}

/// Register all TypedArray constructors.
fn bool register_typed_array_constructors(EnvRecord* global_env, Heap* heap) {
    // Create a shared %TypedArray%.prototype
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = heap.object_proto;
    heap.typedarray_proto = proto;

    // Set @@toStringTag to "TypedArray" on the shared prototype
    HString* tag_key = ensure_tostringtag_symbol(heap);
    if (tag_key != null) {
        TVal tag_tv;
        tag_tv.set_string(builtin_intern_string(heap, "TypedArray"));
        proto.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC);
    }

    // Register each typed array constructor
    if (!register_ta_ctor(global_env, heap, "Int8Array",               BUILTIN_INT8ARRAY,              proto)) return false;
    if (!register_ta_ctor(global_env, heap, "Uint8Array",              BUILTIN_UINT8ARRAY,             proto)) return false;
    if (!register_ta_ctor(global_env, heap, "Uint8ClampedArray",       BUILTIN_UINT8CLAMPEDARRAY,      proto)) return false;
    if (!register_ta_ctor(global_env, heap, "Int16Array",              BUILTIN_INT16ARRAY,             proto)) return false;
    if (!register_ta_ctor(global_env, heap, "Uint16Array",             BUILTIN_UINT16ARRAY,            proto)) return false;
    if (!register_ta_ctor(global_env, heap, "Int32Array",              BUILTIN_INT32ARRAY,             proto)) return false;
    if (!register_ta_ctor(global_env, heap, "Uint32Array",             BUILTIN_UINT32ARRAY,            proto)) return false;
    if (!register_ta_ctor(global_env, heap, "Float32Array",            BUILTIN_FLOAT32ARRAY,           proto)) return false;
    if (!register_ta_ctor(global_env, heap, "Float64Array",            BUILTIN_FLOAT64ARRAY,           proto)) return false;

    return true;
}

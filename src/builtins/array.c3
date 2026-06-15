/// Array constructor and Array.prototype methods.
module duktape::builtins;

import duktape::types;
import std::math;
import libc;
import duktape::heap;
import duktape::hstring;
import duktape::hobject;
import duktape::env;
import duktape::vm;

// ============================================================================
// Additional Array.prototype methods
// ============================================================================

/// Array.of(...items) — ES6 §22.1.2.3
fn void builtin_array_of(BuiltinContext* ctx) {
    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) { ctx.result.set_undefined(); return; }
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;

    uint len = (uint)ctx.argc;
    HString* len_key = builtin_intern_string(ctx.heap, "length");
    TVal len_val; len_val.set_fastint((long)len);
    arr.put_prop(len_key, len_val, hobject::PROP_FLAGS_WEC);

    for (uint i = 0; i < len; i++) {
        TVal elem = ctx.regs[ctx.base_reg + (uint)i];
        HString* idx_key = ctx.heap.int_to_hstring((long)i);
        if (idx_key != null) {
            arr.put_prop(idx_key, elem, hobject::PROP_FLAGS_WEC);
        }
    }
    ctx.result.set_object(arr);
}

/// Array.prototype.fill(value, start, end) — ES6 §22.1.3.6
fn void builtin_array_proto_fill(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    uint len = array_get_length(obj, ctx.heap);
    TVal fill_val;
    if (ctx.argc > 0) {
        fill_val = ctx.regs[ctx.base_reg];
    } else {
        fill_val.set_undefined();
    }

    int start_i = 0;
    if (ctx.argc > 1) {
        double sd = builtin_to_number_getdouble(ctx, &ctx.regs[ctx.base_reg + 1]);
        start_i = (int)(long)sd;
        if (start_i < 0) { start_i = (int)len + start_i; if (start_i < 0) start_i = 0; }
        if (start_i > (int)len) start_i = (int)len;
    }

    int end_i = (int)len;
    if (ctx.argc > 2) {
        double ed = builtin_to_number_getdouble(ctx, &ctx.regs[ctx.base_reg + 2]);
        end_i = (int)(long)ed;
        if (end_i < 0) { end_i = (int)len + end_i; if (end_i < 0) end_i = 0; }
        if (end_i > (int)len) end_i = (int)len;
    }

    for (int i = start_i; i < end_i; i++) {
        array_set_elem(obj, (uint)i, fill_val, ctx.heap);
    }
    ctx.result.set_object(obj);
}

/// Array.prototype.at(index) — ES2022 §22.1.3.1
fn void builtin_array_proto_at(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    uint len = array_get_length(obj, ctx.heap);
    double idx_d = (ctx.argc > 0) ? builtin_to_number_getdouble(ctx, &ctx.regs[ctx.base_reg]) : 0.0;
    if (math::is_nan(idx_d)) { ctx.result.set_undefined(); return; }

    long idx = (long)idx_d;
    if (idx < 0) idx = (long)len + idx;
    if (idx < 0 || idx >= (long)len) { ctx.result.set_undefined(); return; }

    *ctx.result = array_get_elem(obj, (uint)idx, ctx.heap);
}

/// Array.prototype.copyWithin(downstream, start, end) — ES6 §22.1.3.3
fn void builtin_array_proto_copyWithin(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    uint len = array_get_length(obj, ctx.heap);

    double downstream_d = (ctx.argc > 0) ? builtin_to_number_getdouble(ctx, &ctx.regs[ctx.base_reg]) : 0.0;
    int downstream_i = (int)(long)downstream_d;
    if (downstream_i < 0) downstream_i = (int)len + downstream_i < 0 ? 0 : (int)len + downstream_i;
    if (downstream_i > (int)len) downstream_i = (int)len;

    int start_i = 0;
    if (ctx.argc > 1) {
        double sd = builtin_to_number_getdouble(ctx, &ctx.regs[ctx.base_reg + 1]);
        start_i = (int)(long)sd;
        if (start_i < 0) { start_i = (int)len + start_i; if (start_i < 0) start_i = 0; }
        if (start_i > (int)len) start_i = (int)len;
    }

    int end_i = (int)len;
    if (ctx.argc > 2) {
        double ed = builtin_to_number_getdouble(ctx, &ctx.regs[ctx.base_reg + 2]);
        end_i = (int)(long)ed;
        if (end_i < 0) { end_i = (int)len + end_i; if (end_i < 0) end_i = 0; }
        if (end_i > (int)len) end_i = (int)len;
    }

    int count = end_i - start_i;
    if (count > (int)len - downstream_i) count = (int)len - downstream_i;
    if (count <= 0) { ctx.result.set_object(obj); return; }

    // Forward copy is safe when downstream < start; otherwise copy backwards
    if (downstream_i < start_i) {
        for (int i = 0; i < count; i++) {
            array_set_elem(obj, (uint)(downstream_i + i), array_get_elem(obj, (uint)(start_i + i), ctx.heap), ctx.heap);
        }
    } else {
        for (int i = count - 1; i >= 0; i--) {
            array_set_elem(obj, (uint)(downstream_i + i), array_get_elem(obj, (uint)(start_i + i), ctx.heap), ctx.heap);
        }
    }
    ctx.result.set_object(obj);
}

/// Array.prototype.includes(searchElement, fromIndex) — ES7 §22.1.3.13
fn void builtin_array_proto_includes(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    uint len = array_get_length(obj, ctx.heap);

    int start_i = 0;
    if (ctx.argc > 1) {
        double sd = builtin_to_number_getdouble(ctx, &ctx.regs[ctx.base_reg + 1]);
        start_i = (int)(long)sd;
        if (start_i < 0) { start_i = (int)len + start_i; if (start_i < 0) start_i = 0; }
        if (start_i > (int)len) start_i = (int)len;
    }

    TVal search_elem;
    if (ctx.argc > 0) {
        search_elem = ctx.regs[ctx.base_reg];
    } else {
        search_elem.set_undefined();
    }

    for (int i = start_i; i < (int)len; i++) {
        TVal v;
        if (arr_get_elem_vm(obj, (uint)i, ctx.heap, ctx.vm, &v)) {
            if (same_value_zero(v, search_elem)) {
                ctx.result.set_boolean(true);
                return;
            }
        }
    }
    ctx.result.set_boolean(false);
}

/// Helper: flatten source array into downstream array recursively.
/// Returns the next downstream index after all elements are inserted.
fn uint flatten_into(HObject* downstream, HObject* source, uint source_len, uint downstream_idx, double depth, Heap* heap) {
    for (uint i = 0; i < source_len; i++) {
        TVal elem = array_get_elem(source, i, heap);
        if (elem.is_object() && elem.get_heapptr() != null &&
            ((HObject*)elem.get_heapptr()).get_class() == hobject::ObjClass.ARRAY && depth > 0) {
            HObject* inner = (HObject*)elem.get_heapptr();
            uint inner_len = array_get_length(inner, heap);
            downstream_idx = flatten_into(downstream, inner, inner_len, downstream_idx, depth - 1, heap);
        } else {
            array_set_elem(downstream, downstream_idx, elem, heap);
            downstream_idx++;
        }
    }
    return downstream_idx;
}

/// Array.prototype.flat(depth) — ES2019 §22.1.3.10
fn void builtin_array_proto_flat(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.type_err_proto;
            HString* msg = builtin_intern_string(ctx.heap, "Array.prototype.flat requires 'this' to be an object");
            TVal msg_tv; msg_tv.set_string(msg);
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
            ctx.should_throw = true;
            ctx.throw_value.set_object(err);
        }
        return;
    }

    uint len = array_get_length(obj, ctx.heap);

    double depth_num = 1.0;
    if (ctx.argc > 0) {
        TVal* arg = &ctx.regs[ctx.base_reg];
        if (!arg.is_undefined()) {
            depth_num = builtin_to_integer(arg);
        }
    }
    if (depth_num < 0) depth_num = 0;

    HObject*? new_arr = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = new_arr) {
        ctx.result.set_undefined(); return;
    }
    HObject* result = new_arr;
    result.prototype = ctx.heap.array_proto;

    uint n = flatten_into(result, obj, len, 0, depth_num, ctx.heap);
    array_set_length(result, n, ctx.heap);

    ctx.result.set_object(result);
}

/// Array.prototype.flatMap(mapFn, thisArg) — ES2019 §22.1.3.11
fn void builtin_array_proto_flatMap(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.type_err_proto;
            HString* msg = builtin_intern_string(ctx.heap, "Array.prototype.flatMap requires 'this' to be an object");
            TVal msg_tv; msg_tv.set_string(msg);
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
            ctx.should_throw = true;
            ctx.throw_value.set_object(err);
        }
        return;
    }

    // Validate callbackfn is callable (if provided)
    if (ctx.argc >= 1) {
        TVal* arg = &ctx.regs[ctx.base_reg];
        if (!arg.is_object() || arg.get_heapptr() == null || !((HObject*)arg.get_heapptr()).is_callable()) {
            HObject*? err_raw2 = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (try err2 = err_raw2) {
                err2.prototype = ctx.heap.type_err_proto;
                HString* msg2 = builtin_intern_string(ctx.heap, "Array.prototype.flatMap callback is not callable");
                TVal msg_tv2; msg_tv2.set_string(msg2);
                HString* msg_key2 = builtin_intern_string(ctx.heap, "message");
                err2.put_prop(msg_key2, msg_tv2, hobject::PROP_FLAGS_WEC);
                ctx.should_throw = true;
                ctx.throw_value.set_object(err2);
            }
            return;
        }
    }

    // Stub: flatten without mapping (no VM callback support yet)
    uint len = array_get_length(obj, ctx.heap);

    HObject*? new_arr = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = new_arr) {
        ctx.result.set_undefined(); return;
    }
    HObject* result = new_arr;
    result.prototype = ctx.heap.array_proto;

    uint n = flatten_into(result, obj, len, 0, 1.0, ctx.heap);
    array_set_length(result, n, ctx.heap);

    ctx.result.set_object(result);
}

// ============================================================================
// Array constructor builtins
// ============================================================================

/// Array() as function (ES5 §15.4.1) or new Array() as constructor (§15.4.2).
/// Creates and returns a new Array object.
fn void builtin_array(BuiltinContext* ctx) {
    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;

    HString* len_key = builtin_intern_string(ctx.heap, "length");

    if (ctx.argc == 0) {
        // No args: empty array with length 0
        TVal len_val;
        len_val.set_fastint(0);
        arr.put_prop(len_key, len_val, hobject::PROP_FLAGS_WEC);
        ctx.result.set_object(arr);
        return;
    }

    if (ctx.argc == 1) {
        // Single arg: check if it's a number
        TVal arg = ctx.regs[ctx.base_reg];
        if (arg.is_number() || arg.is_fastint()) {
            // Single numeric arg: set array length
            // ES5 §15.4.2.2: If ToUint32(len) !== ToNumber(len), throw RangeError
            double d;
            if (arg.is_fastint()) {
                d = (double)arg.get_fastint();
            } else {
                d = arg.get_number();
            }
            // ToUint32 check per ES5 §9.6
            uint n = (uint)(long)d;
            if ((double)n != d) {
                // Invalid array length — throw RangeError
                arr_throw_range_error(ctx, "Invalid array length");
                ctx.result.set_object(arr);
                return;
            }
            TVal len_val;
            len_val.set_fastint((long)n);
            arr.put_prop(len_key, len_val, hobject::PROP_FLAGS_WEC);
        } else {
            // Single non-numeric arg: array with one element
            TVal len_val;
            len_val.set_fastint(1);
            arr.put_prop(len_key, len_val, hobject::PROP_FLAGS_WEC);

            // Set element at index 0
            HString* zero_key = builtin_intern_string(ctx.heap, "0");
            arr.put_prop(zero_key, arg, hobject::PROP_FLAGS_WEC);
        }
        ctx.result.set_object(arr);
        return;
    }

    // Multiple args: create array with given elements
    TVal len_val;
    len_val.set_fastint((long)ctx.argc);
    arr.put_prop(len_key, len_val, hobject::PROP_FLAGS_WEC);

    // Set each element
    for (ushort i = 0; i < ctx.argc; i++) {
        TVal elem = ctx.regs[ctx.base_reg + (uint)i];
        HString* idx_key = ctx.heap.int_to_hstring((long)i);
        if (idx_key != null) {
            arr.put_prop(idx_key, elem, hobject::PROP_FLAGS_WEC);
        }
    }

    ctx.result.set_object(arr);
}

/// Helper: get the 'this' value as an object for Array.prototype methods.
fn HObject* array_proto_get_this(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.is_object() && this_val.get_heapptr() != null) {
        return (HObject*)this_val.get_heapptr();
    }
    // TypeError: Array.prototype method called on non-object
    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_str = builtin_intern_string(ctx.heap,
            "Array.prototype method called on incompatible value");
        if (msg_str != null) {
            TVal msg_val;
            msg_val.set_string(msg_str);
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
        }
        TVal err_tv;
        err_tv.set_object(err);
        ctx.throw_value = err_tv;
    }
    ctx.should_throw = true;
    return null;
}

// ============================================================================
// Array.prototype helpers
// ============================================================================

/// ES5 §9.6 ToUint32 — convert a double to uint32 per the spec algorithm.
/// NaN, ±Infinity, ±0 → 0. Otherwise floor(abs(x)) mod 2^32.
fn uint to_uint32(double val) {
    // NaN: NaN != NaN is true in IEEE 754
    if (val != val) return 0;
    // ±Infinity
    if (val == 1.0 / 0.0 || val == -1.0 / 0.0) return 0;
    // Fast path: value fits in int32 without conversion issues
    if (val >= 0.0 && val < 4294967296.0 && val == math::floor(val)) {
        return (uint)val;
    }
    // General case: val mod 2^32 using floor-based modulo (ES5 §9.6 step 4)
    double two32 = 4294967296.0;
    double n = val - math::floor(val / two32) * two32;
    if (n < 0.0) n += two32;
    return (uint)n;
}

/// Check if a raw double length value is a valid array length per ES5 §15.4.4.x.
/// Returns false for NaN, ±Infinity, negative, non-integer, > 2^32-1, or -0.
fn bool is_valid_array_length(double raw) {
    if (raw != raw) return false;                                      // NaN
    if (raw < 0.0) return false;                                       // negative
    if (raw == 0.0 && 1.0 / raw < 0.0) return false;                  // -0
    if (raw > 4294967295.0) return false;                              // > 2^32-1 or Infinity
    return raw == math::floor(raw);                                     // must be integer
}

/// Throw a RangeError with the given message.
fn void arr_throw_range_error(BuiltinContext* ctx, char[] msg) {
    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = ctx.heap.range_err_proto;
        HString* msg_str = builtin_intern_string(ctx.heap, msg);
        if (msg_str != null) {
            TVal msg_val;
            msg_val.set_string(msg_str);
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
        }
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
    }
}

/// Helper to invoke a getter and return the result as double.
/// Propagates getter errors through ctx.should_throw / ctx.throw_value.
fn double invoke_getter_as_length(HObject* obj, TVal getter_fn, Heap* heap, BuiltinContext* ctx) {
    if (getter_fn.is_undefined() || getter_fn.is_null()) return 0;
    if (!getter_fn.is_object() || getter_fn.get_heapptr() == null) return 0;
    HObject* fn_obj = (HObject*)getter_fn.get_heapptr();
    void* vm_ptr = (ctx != null) ? ctx.vm : null;
    if (!fn_obj.is_callable() || heap.call_fn == null || vm_ptr == null) return 0;
    TVal this_val; this_val.set_object(obj);
    TVal result = heap.call_fn(vm_ptr, getter_fn, null, 0, this_val);
    if (heap.has_error) {
        // Propagate getter error instead of swallowing it
        if (ctx != null) {
            ctx.should_throw = true;
            ctx.throw_value = heap.error_value;
        }
        heap.has_error = false;
        return 0;
    }
    return builtin_to_number_getdouble(null, &result);
}

/// Read the raw 'length' property as a double from an array-like object.
/// Handles accessor properties by invoking the getter.
/// Propagates getter errors through ctx.should_throw / ctx.throw_value.
fn double array_get_length_raw(HObject* obj, Heap* heap, BuiltinContext* ctx) {

    if (obj.get_class() == ARRAY) {
        // For ARRAY class, also check if length is an accessor (set via defineProperty)
        HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
        if (len_key != null) {
            int own_idx = obj.find_prop_idx(len_key);
            if (own_idx >= 0) {
                PropFlags pf = obj.get_prop_flags((uint)own_idx);
                if (pf.is_accessor) {
                    TVal gs_slot = obj.prop_values()[own_idx];
                    TVal getter_fn = hobject::hobject_access_getter(gs_slot);
                    return invoke_getter_as_length(obj, getter_fn, heap, ctx);
                }
            }
        }
        return (double)*obj.array_len_ptr();
    }
    if (obj.get_class() == ARGUMENTS) {
        HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
        if (len_key == null) return 0;
        // Check own properties first for accessor
        int own_idx = obj.find_prop_idx(len_key);
        if (own_idx >= 0) {
            PropFlags pf = obj.get_prop_flags((uint)own_idx);
            if (pf.is_accessor) {
                TVal gs_slot = obj.prop_values()[own_idx];
                TVal getter_fn = hobject::hobject_access_getter(gs_slot);
                return invoke_getter_as_length(obj, getter_fn, heap, ctx);
            }
        }
        TVal? len_val = obj.get_prop(len_key);
        if (try v = len_val) {
            if (v.is_fastint()) return (double)v.get_fastint();
            if (v.is_number()) return v.get_number();
        }
        len_val = obj.get_prop_proto(len_key);
        if (try v = len_val) {
            if (v.is_fastint()) return (double)v.get_fastint();
            if (v.is_number()) return v.get_number();
        }
        return 0;
    }
    // For plain objects and other classes, use get_prop_or_accessor_proto
    HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    if (len_key == null) return 0;

    // Check own properties first for accessor
    int own_idx = obj.find_prop_idx(len_key);
    if (own_idx >= 0) {
        PropFlags pf = obj.get_prop_flags((uint)own_idx);
        if (pf.is_accessor) {
            TVal gs_slot = obj.prop_values()[own_idx];
            TVal getter_fn = hobject::hobject_access_getter(gs_slot);
            return invoke_getter_as_length(obj, getter_fn, heap, ctx);
        }
    }

    // Fallback to normal lookup
    hobject::PropLookupResult res = obj.get_prop_or_accessor_proto(len_key, true);
    if (res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
        TVal getter_fn = res.acc.accessor_fn;
        return invoke_getter_as_length(obj, getter_fn, heap, ctx);
    } else if (res.kind == hobject::PropLookupKind.PROP_DATA) {
        TVal v = res.data_val;
        if (v.is_fastint()) return (double)v.get_fastint();
        if (v.is_number()) return v.get_number();
    }
    return 0;
}

/// ES2022 §7.1.21 ToLength conversion for array iteration methods.
/// Converts a raw double to a length value per the spec:
///   1. ToIntegerOrInfinity: NaN → 0, +0/-0 → 0, ±Infinity → 0, otherwise truncate
///   2. If len ≤ 0, return 0
///   3. Return min(len, 2^53 − 1)
fn ulong arr_to_length(double raw) {
    // Step 1: ToIntegerOrInfinity
    if (raw != raw) return 0;           // NaN → 0
    if (raw == 0.0) return 0;           // +0 / -0 → 0
    if (raw == double::inf) return 9007199254740991L;  // +Infinity → 2^53-1
    if (raw == -double::inf) return 0;  // -Infinity → 0

    // Step 2-3: clamp to [0, 2^53-1]
    if (raw < 0) return 0;
    if (raw > 9007199254740991.0) return 9007199254740991L;
    return (ulong)raw;
}

/// ES2022 ToLength for Array.prototype iteration methods.
/// Applies ToLength conversion without RangeError validation.
/// NaN → 0, -0 → 0, Infinity → 2^53-1, negative → 0.
/// Returns true on success (out_len set). Returns false if the length getter threw.
fn bool array_to_length(HObject* obj, Heap* heap, BuiltinContext* ctx, uint* out_len) {
    double raw = array_get_length_raw(obj, heap, ctx);
    // Check if the length getter threw an error
    if (ctx != null && ctx.should_throw) return false;
    ulong len = arr_to_length(raw);
    if (len > 0xFFFFFFFF) len = 0xFFFFFFFF;
    *out_len = (uint)len;
    return true;
}

/// ES5 §15.4.4.x: Read length, validate as valid array length (RangeError on invalid).
/// Used by indexOf/lastIndexOf which DO require RangeError on invalid lengths.
/// Returns true on success (out_len set). Returns false and sets
/// ctx.should_throw + RangeError if the length is invalid (NaN, Infinity, negative),
/// or if the length getter threw.
fn bool array_to_length_checked(HObject* obj, Heap* heap, BuiltinContext* ctx, uint* out_len) {
    double raw = array_get_length_raw(obj, heap, ctx);
    // Check if the length getter threw an error
    if (ctx.should_throw) return false;
    // ES5 §15.4.4.x: validate via SameValue — NaN, Infinity, negative, -0 are invalid
    if (!is_valid_array_length(raw)) {
        arr_throw_range_error(ctx, "Invalid array length");
        return false;
    }
    *out_len = to_uint32(raw);
    return true;
}

/// Get the 'length' property of an array-like object as a uint.
/// Uses proper ToUint32 conversion (safe for Infinity, NaN, etc.).
fn uint array_get_length(HObject* obj, Heap* heap) {
    // Fast path: ARRAY uses cached array_length field (no prop table walk).
    if (obj.get_class() == ARRAY) {
        return *obj.array_len_ptr();
    }
    // For non-array objects, read raw and apply ToUint32.
    // Pass null for ctx since we don't need getter invocation here.
    return to_uint32(array_get_length_raw(obj, heap, null));
}

/// Set the 'length' property of an array-like object.
fn void array_set_length(HObject* obj, uint len_val, Heap* heap) {
    // Fast path: ARRAY uses cached array_length field + prop table sync.
    if (obj.get_class() == ARRAY) {
        *obj.array_len_ptr() = len_val;
        HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
        if (len_key != null) {
            int idx = obj.find_prop_idx(len_key);
            if (idx >= 0) {
                TVal tv;
                tv.set_fastint((long)len_val);
                obj.prop_values()[idx] = tv;
                return;
            }
        }
        return;
    }
    // ARGUMENTS: update prop table directly.
    if (obj.get_class() == ARGUMENTS) {
        HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
        if (len_key != null) {
            int idx = obj.find_prop_idx(len_key);
            if (idx >= 0) {
                TVal tv;
                tv.set_fastint((long)len_val);
                obj.prop_values()[idx] = tv;
                return;
            }
        }
    }
    HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    if (len_key == null) return;
    TVal tv;
    tv.set_fastint((long)len_val);
    obj.put_prop(len_key, tv, hobject::PROP_FLAGS_WEC);
}

/// Get array element at numeric index (returns undefined for holes).
/// Checks the dense array part first, then falls back to named properties.
fn TVal array_get_elem(HObject* obj, uint idx, Heap* heap) {
    // Try the dense array part first.
    if (obj.array_part() != null && idx < obj.array_size) {
        TVal v = obj.array_part()[idx];
        if (!v.is_undefined()) return v;
    }
    // Fall back to named property lookup (elements may be stored as named
    // properties via PUTPROP or Object.defineProperty).
    HString* key = heap.int_to_hstring((long)idx);
    if (key == null) { TVal undef; undef.set_undefined(); return undef; }
    TVal? result = obj.get_prop(key);
    if (try v = result) {
        return v;
    }
    TVal? result2 = obj.get_prop_proto(key);
    if (try v2 = result2) {
        return v2;
    }
    TVal undef; undef.set_undefined(); return undef;
}

/// Set array element at numeric index.
/// Uses the dense array part for numeric indices (O(1) push/append).
/// Falls back to put_prop (via property table) when the dense array cannot
/// accommodate the index (e.g. index beyond the ushort capacity cap).
fn void array_set_elem(HObject* obj, uint idx, TVal val, Heap* heap) {
    if (!obj.set_array_idx(idx, val)) {
        HString* key = heap.int_to_hstring((long)idx);
        if (key != null) {
            obj.put_prop(key, val, hobject::PROP_FLAGS_WEC);
        }
    }
}

/// Delete array element at numeric index (set to undefined in dense part).
fn void array_delete_elem(HObject* obj, uint idx, Heap* heap) {
    TVal undef; undef.set_undefined();
    obj.set_array_idx(idx, undef);
}

/// Strict equality comparison for Array.prototype.indexOf / lastIndexOf.
fn bool array_strict_equals(TVal a, TVal b) {
    if (a.get_tag() == b.get_tag()) {
        switch (a.get_tag()) {
            case UNDEFINED: return true;
            case NULL_VAL:  return true;
            case BOOLEAN:   return a.get_boolean() == b.get_boolean();
            case NUMBER:
                if (math::is_nan(a.get_number()) || math::is_nan(b.get_number())) return false;
                return a.get_number() == b.get_number();
            case FASTINT:   return a.get_fastint() == b.get_fastint();
            case STRING:    return a.get_heapptr() == b.get_heapptr();
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
// Array.prototype.toString (ES5 §15.4.4.2)
// ============================================================================
//
// Per ES5 §15.4.4.3: Let func be Get(array, "join").
// If IsCallable(func) is false, set func to Object.prototype.toString.
// Return Call(func, array).
fn void builtin_array_proto_toString(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];

    // Step 1: Let array be ToObject(this value)
    // For primitives, ToObject creates a wrapper (e.g. Boolean → Boolean wrapper).
    HObject* obj = null;
    if (this_val.is_object() && this_val.get_heapptr() != null) {
        obj = (HObject*)this_val.get_heapptr();
    } else if (this_val.is_null() || this_val.is_undefined()) {
        ctx.result.set_undefined();
        return;
    } else {
        // Box primitive via ToObject
        HObject*? boxed = arr_to_object(this_val, ctx.heap);
        if (try b = boxed) {
            obj = b;
        } else {
            ctx.result.set_undefined();
            return;
        }
    }

    // Step 2: Let func be Get(array, "join")
    HString* join_key = builtin_intern_string(ctx.heap, "join");
    TVal join_fn;
    bool join_found = false;
    if (obj != null) {
        TVal? join_val = obj.get_prop_proto(join_key);
        if (try jv = join_val) {
            join_fn = jv;
            join_found = true;
        }
    }

    // Step 3: If IsCallable(func) is false, set func to Object.prototype.toString
    bool join_callable = false;
    if (join_found) {
        if (join_fn.is_lightfunc()) {
            join_callable = true;
        } else if (join_fn.is_object() && join_fn.get_heapptr() != null) {
            join_callable = ((HObject*)join_fn.get_heapptr()).is_callable();
        }
    }

    if (!join_callable) {
        // Fall back to Object.prototype.toString
        // Build the toString result directly based on object class and Symbol.toStringTag
        if (obj != null) {
            char[64] buf;
            char* class_name = "Object";
            switch (obj.get_class()) {
                case hobject::ObjClass.ARRAY:     class_name = "Array"; break;
                case hobject::ObjClass.FUNCTION:  class_name = "Function"; break;
                case hobject::ObjClass.BOOLEAN:   class_name = "Boolean"; break;
                case hobject::ObjClass.NUMBER:    class_name = "Number"; break;
                case hobject::ObjClass.STRING:    class_name = "String"; break;
                case hobject::ObjClass.ERROR:     class_name = "Error"; break;
                case hobject::ObjClass.JSON:      class_name = "JSON"; break;
                case hobject::ObjClass.MATH:      class_name = "Math"; break;
                case hobject::ObjClass.DATE:      class_name = "Date"; break;
                case hobject::ObjClass.REGEXP:    class_name = "RegExp"; break;
                case hobject::ObjClass.MAP:       class_name = "Map"; break;
                case hobject::ObjClass.SET:       class_name = "Set"; break;
                case hobject::ObjClass.WEAKMAP:   class_name = "WeakMap"; break;
                case hobject::ObjClass.WEAKSET:   class_name = "WeakSet"; break;
                case hobject::ObjClass.SYMBOL:    class_name = "Symbol"; break;
                case hobject::ObjClass.PROMISE:   class_name = "Promise"; break;
                case hobject::ObjClass.GENERATOR: class_name = "Generator"; break;
                default:                          class_name = "Object"; break;
            }

            // Check @@toStringTag
            HString* tag_sym = ensure_tostringtag_symbol(ctx.heap);
            if (tag_sym != null) {
                TVal? tag_val = obj.get_prop_proto(tag_sym);
                if (try tv = tag_val) {
                    if (tv.is_string()) {
                        HString* tag_str = (HString*)tv.get_heapptr();
                        if (tag_str != null && !tag_str.is_symbol()) {
                            char[] tag_bytes = tag_str.get_data();
                            int tag_len = (int)tag_bytes.len;
                            if (tag_len > 0 && tag_len < 64) {
                                int pos = libc::snprintf(&buf, 64, "[object %.*s]", tag_len, tag_bytes.ptr);
                                if (pos > 0 && pos < 64) {
                                    ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:pos]));
                                    return;
                                }
                            }
                        }
                    }
                }
            }

            int len = libc::snprintf(&buf, 64, "[object %s]", class_name);
            if (len > 0 && len < 64) {
                ctx.result.set_string(builtin_intern_string(ctx.heap, buf[:len]));
                return;
            }
            ctx.result.set_undefined();
            return;
        } else if (this_val.is_undefined()) {
            ctx.result.set_string(builtin_intern_string(ctx.heap, "[object Undefined]"));
            return;
        } else if (this_val.is_null()) {
            ctx.result.set_string(builtin_intern_string(ctx.heap, "[object Null]"));
            return;
        } else {
            // Primitive (string, number, boolean) — use toString on the type
            // Actually Object.prototype.toString with a primitive this should return "[object <type>]"
            // But primitives get boxed by ToObject, so we'd need the wrapper's class.
            // For simplicity, call builtin_to_string.
            HString* s = builtin_to_string(ctx.heap, &this_val);
            if (s != null) {
                ctx.result.set_string(s);
                return;
            }
            ctx.result.set_undefined();
            return;
        }
    }

    // Step 4: Return Call(func, array) — call join with the object as this
    if (ctx.heap.call_fn != null && ctx.vm != null) {
        TVal this_tv;
        if (obj != null) {
            this_tv.set_object(obj);
        } else {
            this_tv = this_val;
        }
        *ctx.result = ctx.heap.call_fn(ctx.vm, join_fn, null, 0, this_tv);
        if (ctx.heap.has_error) {
            ctx.should_throw = true;
            ctx.heap.has_error = false;
        }
    } else {
        ctx.result.set_undefined();
    }
}

// ============================================================================
// Array.prototype.join (ES5 §15.4.4.5)
// ============================================================================
fn void builtin_array_proto_join(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    // Get separator (default ",")
    HString* sep_str = null;
    char[] sep = ",";
    if (ctx.argc > 0) {
        TVal sep_val = ctx.regs[ctx.base_reg];
        sep_str = builtin_to_string(ctx.heap, &sep_val);
        if (sep_str != null) {
            // Hold a reference: element toString calls below can trigger GC,
            // which sweeps strings only referenced by the string table.
            ((types::HeapHeader*)sep_str).incref();
            sep = sep_str.get_data();
        }
    }

    uint len = array_get_length(obj, ctx.heap);

    // Empty array returns ""
    if (len == 0) {
        if (sep_str != null) ctx.heap.decref((types::HeapHeader*)sep_str);
        HString* result = builtin_intern_string(ctx.heap, "");
        if (result == null) { ctx.result.set_undefined(); return; }
        ctx.result.set_string(result);
        return;
    }

    // PASS 1: Collect HString* pointers for each element and sum total length.
    // Use stack allocation for small arrays (up to 64 elements), heap allocation otherwise.
    HString*[] elem_strs;
    HString** elem_strs_heap = null;
    const usz STACK_THRESHOLD = 64;

    HString*[64] elem_strs_stack;
    if (len <= STACK_THRESHOLD) {
        elem_strs = elem_strs_stack[:len];
    } else {
        elem_strs_heap = (HString**)libc::malloc(HString*::size * len);
        if (elem_strs_heap == null) {
            if (sep_str != null) ctx.heap.decref((types::HeapHeader*)sep_str);
            ctx.result.set_undefined();
            return;
        }
        elem_strs = elem_strs_heap[:len];
    }

    // Sum the total byte count: each element string's bytes plus separator bytes between elements.
    usz total_len = 0;
    for (uint i = 0; i < len; i++) {
        TVal elem = array_get_elem(obj, i, ctx.heap);
        HString* elem_str;
        if (elem.is_undefined() || elem.is_null()) {
            // ES5 §15.4.4.5: undefined/null elements become empty strings, but separators
            // are still emitted between each pair of elements.
            elem_str = (HString*)ctx.heap.strs[heap::BuiltinStr.EMPTY];
        } else {
            elem_str = builtin_to_string(ctx.heap, &elem);
            if (elem_str == null) {
                elem_str = (HString*)ctx.heap.strs[heap::BuiltinStr.EMPTY];
            }
        }
        // Hold a reference: a later element's toString can trigger GC, which
        // sweeps strings that are only referenced by the string table.
        ((types::HeapHeader*)elem_str).incref();
        elem_strs[i] = elem_str;
        total_len += elem_str.blen;
    }
    // Add separator bytes between elements (len - 1 separators between len elements).
    if (len > 1) {
        total_len += sep.len * (usz)(len - 1);
    }

    // PASS 2: Allocate a single buffer and copy all pieces using memcpy.
    char* result_buf = (char*)libc::malloc(total_len);
    if (result_buf == null) {
        if (sep_str != null) ctx.heap.decref((types::HeapHeader*)sep_str);
        for (uint i = 0; i < len; i++) {
            ctx.heap.decref((types::HeapHeader*)elem_strs[i]);
        }
        if (elem_strs_heap != null) libc::free(elem_strs_heap);
        ctx.result.set_undefined();
        return;
    }

    usz offset = 0;
    for (uint i = 0; i < len; i++) {
        // Emit separator before element i (except before the first element).
        if (i > 0) {
            libc::memcpy(&result_buf[offset], &sep[0], sep.len);
            offset += sep.len;
        }
        // Emit element string.
        HString* elem_str = elem_strs[i];
        char[] elem_data = elem_str.get_data();
        if (elem_data.len > 0) {
            libc::memcpy(&result_buf[offset], &elem_data[0], elem_data.len);
            offset += elem_data.len;
        }
    }

    // Intern the result, then release the held references and buffers.
    HString* result = builtin_intern_string(ctx.heap, result_buf[:total_len]);
    libc::free(result_buf);
    if (sep_str != null) ctx.heap.decref((types::HeapHeader*)sep_str);
    for (uint i = 0; i < len; i++) {
        ctx.heap.decref((types::HeapHeader*)elem_strs[i]);
    }
    if (elem_strs_heap != null) {
        libc::free(elem_strs_heap);
    }

    if (result == null) {
        ctx.result.set_undefined();
        return;
    }
    ctx.result.set_string(result);
}

// ============================================================================
// Array.prototype.pop (ES5 §15.4.4.6)
// ============================================================================
fn void builtin_array_proto_pop(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    uint len = array_get_length(obj, ctx.heap);
    if (len == 0) {
        array_set_length(obj, 0, ctx.heap);
        ctx.result.set_undefined();
        return;
    }

    uint idx = len - 1;
    TVal elem = array_get_elem(obj, idx, ctx.heap);
    array_delete_elem(obj, idx, ctx.heap);
    array_set_length(obj, idx, ctx.heap);

    // Return the popped element
    *ctx.result = elem;
}

// ============================================================================
// Array.prototype.push (ES5 §15.4.4.7)
// ============================================================================
fn void builtin_array_proto_push(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    uint len = array_get_length(obj, ctx.heap);

    for (ushort i = 0; i < ctx.argc; i++) {
        TVal arg = ctx.regs[ctx.base_reg + i];
        array_set_elem(obj, len + i, arg, ctx.heap);
    }

    uint new_len = len + (uint)ctx.argc;
    array_set_length(obj, new_len, ctx.heap);

    ctx.result.set_fastint((long)new_len);
}

// ============================================================================
// Array.prototype.reverse (ES5 §15.4.4.8)
// ============================================================================
fn void builtin_array_proto_reverse(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    uint len = array_get_length(obj, ctx.heap);
    uint middle = len / 2;

    for (uint lower = 0; lower < middle; lower++) {
        uint upper = len - 1 - lower;
        TVal lower_val = array_get_elem(obj, lower, ctx.heap);
        TVal upper_val = array_get_elem(obj, upper, ctx.heap);
        array_set_elem(obj, lower, upper_val, ctx.heap);
        array_set_elem(obj, upper, lower_val, ctx.heap);
    }

    ctx.result.set_object(obj);
}

// ============================================================================
// Array.prototype.shift (ES5 §15.4.4.9)
// ============================================================================
fn void builtin_array_proto_shift(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    uint len = array_get_length(obj, ctx.heap);
    if (len == 0) {
        array_set_length(obj, 0, ctx.heap);
        ctx.result.set_undefined();
        return;
    }

    TVal first = array_get_elem(obj, 0, ctx.heap);

    for (uint k = 1; k < len; k++) {
        TVal elem = array_get_elem(obj, k, ctx.heap);
        array_set_elem(obj, k - 1, elem, ctx.heap);
    }

    array_delete_elem(obj, len - 1, ctx.heap);
    array_set_length(obj, len - 1, ctx.heap);

    // Return the first element
    *ctx.result = first;
}

// ============================================================================
// Array.prototype.slice (ES5 §15.4.4.10)
// ============================================================================
fn void builtin_array_proto_slice(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    uint len = array_get_length(obj, ctx.heap);

    // Determine start
    double relative_start = 0.0;
    if (ctx.argc > 0) {
        TVal* arg = &ctx.regs[ctx.base_reg];
        if (arg.is_fastint()) {
            relative_start = (double)arg.get_fastint();
        } else if (arg.is_number()) {
            relative_start = arg.get_number();
        }
    }

    uint k;
    if (relative_start < 0) {
        double tmp = (double)len + relative_start;
        k = tmp < 0 ? 0 : (uint)(long)tmp;
    } else {
        k = relative_start > (double)len ? len : (uint)(long)relative_start;
    }

    // Determine end
    double relative_end = (double)len;
    if (ctx.argc > 1) {
        TVal* arg = &ctx.regs[ctx.base_reg + 1];
        if (arg.is_fastint()) {
            relative_end = (double)arg.get_fastint();
        } else if (arg.is_number()) {
            relative_end = arg.get_number();
        }
    }

    uint final_val;
    if (relative_end < 0) {
        double tmp = (double)len + relative_end;
        final_val = tmp < 0 ? 0 : (uint)(long)tmp;
    } else {
        final_val = relative_end > (double)len ? len : (uint)(long)relative_end;
    }

    // Create result array
    HObject*? new_arr = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = new_arr) {
        ctx.result.set_undefined();
        return;
    }
    HObject* result_arr = new_arr;
    result_arr.prototype = ctx.heap.array_proto;

    uint n = 0;
    for (uint i = k; i < final_val; i++) {
        TVal elem = array_get_elem(obj, i, ctx.heap);
        array_set_elem(result_arr, n, elem, ctx.heap);
        n++;
    }
    array_set_length(result_arr, n, ctx.heap);

    ctx.result.set_object(result_arr);
}

// ============================================================================
// Array.prototype.sort (ES2022 §23.1.3.30) — with comparefn support
// ============================================================================
fn void builtin_array_proto_sort(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    // ES2022 step 1: check comparefn BEFORE accessing length
    bool has_comparefn = false;
    TVal comparefn;
    comparefn.set_undefined();
    if (ctx.argc > 0) {
        TVal* arg0 = &ctx.regs[ctx.base_reg];
        if (!arg0.is_undefined()) {
            if (!arg0.is_object() || arg0.get_heapptr() == null ||
                !((HObject*)arg0.get_heapptr()).is_callable()) {
                HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = ctx.heap.type_err_proto;
                    HString* msg_str = builtin_intern_string(ctx.heap,
                        "Array.prototype.sort: comparefn is not a function or undefined");
                    if (msg_str != null) {
                        TVal msg_val;
                        msg_val.set_string(msg_str);
                        HString* msg_key = builtin_intern_string(ctx.heap, "message");
                        err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
                    }
                    TVal err_tv;
                    err_tv.set_object(err);
                    ctx.throw_value = err_tv;
                }
                ctx.should_throw = true;
                return;
            }
            comparefn = *arg0;
            has_comparefn = true;
        }
    }

    // ES2022 step 3-4: get length
    uint len = array_get_length(obj, ctx.heap);
    if (len <= 1) {
        ctx.result.set_object(obj);
        return;
    }

    // ES2022: collect elements into temp buffer via [[Get]]
    uint max_buf = len > 4096 ? 4096 : len;
    TVal[4096] stack_buf;
    TVal[] buf;
    bool use_heap = len > 4096;
    if (use_heap) {
        buf = mem::temp_array(TVal, len);
    } else {
        buf = stack_buf[0:max_buf];
    }

    uint new_len = 0;
    for (uint i = 0; i < len; i++) {
        TVal elem = array_get_elem(obj, i, ctx.heap);
        if (!elem.is_undefined()) {
            buf[new_len] = elem;
            new_len++;
        }
    }

    // Bubble-sort the collected elements
    for (uint i = 0; i < new_len; i++) {
        for (uint j = 0; j < new_len - 1 - i; j++) {
            TVal a = buf[j];
            TVal b = buf[j + 1];
            int cmp = 0;

            if (has_comparefn && ctx.heap.call_fn != null && ctx.vm != null) {
                TVal[2] args;
                args[0] = a;
                args[1] = b;
                TVal this_val;
                this_val.set_undefined();
                TVal res = ctx.heap.call_fn(ctx.vm, comparefn, &args[0], 2, this_val);
                if (ctx.heap.has_error) {
                    ctx.should_throw = true;
                    ctx.throw_value = ctx.heap.error_value;
                    ctx.heap.has_error = false;
                    ctx.result.set_undefined();
                    return;
                }
                TVal num;
                builtin_to_number(&res, &num);
                if (num.is_number()) {
                    double d = num.get_number();
                    if (!math::is_nan(d)) {
                        cmp = d < 0 ? -1 : (d > 0 ? 1 : 0);
                    }
                } else if (num.is_fastint()) {
                    long v = num.get_fastint();
                    cmp = v < 0 ? -1 : (v > 0 ? 1 : 0);
                }
            } else {
                // ES5 SortCompare: use ToString (calls toString on objects)
                HString*? a_str_raw = vm::vm_to_string(ctx.vm, &a);
                HString* a_str = a_str_raw ?? builtin_to_string(ctx.heap, &a);
                HString*? b_str_raw = vm::vm_to_string(ctx.vm, &b);
                HString* b_str = b_str_raw ?? builtin_to_string(ctx.heap, &b);
                cmp = hstring::hstring_compare(a_str, b_str);
            }
            if (cmp > 0) {
                TVal tmp = buf[j];
                buf[j] = buf[j + 1];
                buf[j + 1] = tmp;
            }
        }
    }

    // ES2022: write sorted elements back, delete extras
    for (uint i = 0; i < new_len; i++) {
        array_set_elem(obj, i, buf[i], ctx.heap);
    }
    for (uint i = new_len; i < len; i++) {
        array_delete_elem(obj, i, ctx.heap);
        // Also remove named property to prevent stale fallback in array_get_elem
        HString* del_key = ctx.heap.int_to_hstring((long)i);
        if (del_key != null) {
            obj.delete_prop(del_key);
        }
    }

    ctx.result.set_object(obj);
}

// ============================================================================
// Array.prototype.splice (ES5 §15.4.4.12)
// ============================================================================
fn void builtin_array_proto_splice(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    uint len = array_get_length(obj, ctx.heap);

    // Get relativeStart (argument 0)
    double relative_start = 0.0;
    if (ctx.argc > 0) {
        TVal* arg = &ctx.regs[ctx.base_reg];
        if (arg.is_fastint()) {
            relative_start = (double)arg.get_fastint();
        } else if (arg.is_number()) {
            relative_start = arg.get_number();
        }
    }

    uint actual_start;
    if (relative_start < 0) {
        double tmp = (double)len + relative_start;
        actual_start = tmp < 0 ? 0 : (uint)(long)tmp;
    } else {
        actual_start = relative_start > (double)len ? len : (uint)(long)relative_start;
    }

    // Get actualDeleteCount
    uint actual_delete_count;
    if (ctx.argc <= 1) {
        actual_delete_count = len - actual_start;
    } else {
        TVal* arg = &ctx.regs[ctx.base_reg + 1];
        double delete_count;
        if (arg.is_fastint()) {
            delete_count = (double)arg.get_fastint();
        } else if (arg.is_number()) {
            delete_count = arg.get_number();
        } else {
            delete_count = 0;
        }

        if (delete_count < 0) delete_count = 0;
        uint dc = (uint)(long)delete_count;
        actual_delete_count = dc > (len - actual_start) ? (len - actual_start) : dc;
    }

    // Create result array with deleted items
    HObject*? result_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = result_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* result = result_raw;
    result.prototype = ctx.heap.array_proto;

    for (uint i = 0; i < actual_delete_count; i++) {
        TVal elem = array_get_elem(obj, actual_start + i, ctx.heap);
        array_set_elem(result, i, elem, ctx.heap);
    }
    array_set_length(result, actual_delete_count, ctx.heap);

    // Get items to insert
    ushort item_count = 0;
    if (ctx.argc > 2) {
        item_count = ctx.argc - 2;
    }

    // Shift elements left or right
    if (item_count < actual_delete_count) {
        uint shift_len = len - actual_start - actual_delete_count;
        for (uint k = 0; k < shift_len; k++) {
            TVal elem = array_get_elem(obj, actual_start + actual_delete_count + k, ctx.heap);
            array_set_elem(obj, actual_start + item_count + k, elem, ctx.heap);
        }
        uint new_len = len - actual_delete_count + item_count;
        for (uint k = new_len; k < len; k++) {
            array_delete_elem(obj, k, ctx.heap);
        }
        array_set_length(obj, new_len, ctx.heap);
    } else if (item_count > actual_delete_count) {
        uint shift_len = len - actual_start - actual_delete_count;
        for (uint k = shift_len; k > 0; k--) {
            uint from = actual_start + actual_delete_count + k - 1;
            uint to = actual_start + item_count + k - 1;
            TVal elem = array_get_elem(obj, from, ctx.heap);
            array_set_elem(obj, to, elem, ctx.heap);
        }
        array_set_length(obj, len - actual_delete_count + item_count, ctx.heap);
    }

    // Insert new items
    for (ushort i = 0; i < item_count; i++) {
        TVal item = ctx.regs[ctx.base_reg + 2 + i];
        array_set_elem(obj, actual_start + i, item, ctx.heap);
    }

    ctx.result.set_object(result);
}

// ============================================================================
// Array.prototype.toReversed (ES2023 §23.1.3.33)
// ============================================================================
fn void builtin_array_proto_toReversed(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) {
        TVal this_val = ctx.regs[ctx.base_reg - 1];
        if (this_val.is_undefined() || this_val.is_null()) {
            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (try err = err_raw) {
                err.prototype = ctx.heap.type_err_proto;
                HString* msg = builtin_intern_string(ctx.heap, "Array.prototype.toReversed called on null or undefined");
                TVal msg_tv; msg_tv.set_string(msg);
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                ctx.should_throw = true;
                ctx.throw_value.set_object(err);
            }
        }
        return;
    }

    uint len = array_get_length(obj, ctx.heap);

    HObject*? new_arr = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = new_arr) {
        ctx.result.set_undefined(); return;
    }
    HObject* result = new_arr;
    result.prototype = ctx.heap.array_proto;

    for (uint i = 0; i < len; i++) {
        TVal elem = array_get_elem(obj, len - 1 - i, ctx.heap);
        array_set_elem(result, i, elem, ctx.heap);
    }
    array_set_length(result, len, ctx.heap);

    ctx.result.set_object(result);
}

// ============================================================================
// Array.prototype.toSorted (ES2023 §23.1.3.34) — default compare (no comparefn)
// ============================================================================
fn void builtin_array_proto_toSorted(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) {
        TVal this_val = ctx.regs[ctx.base_reg - 1];
        if (this_val.is_undefined() || this_val.is_null()) {
            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (try err = err_raw) {
                err.prototype = ctx.heap.type_err_proto;
                HString* msg = builtin_intern_string(ctx.heap, "Array.prototype.toSorted called on null or undefined");
                TVal msg_tv; msg_tv.set_string(msg);
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                ctx.should_throw = true;
                ctx.throw_value.set_object(err);
            }
        }
        return;
    }

    uint len = array_get_length(obj, ctx.heap);

    // Create a copy
    HObject*? new_arr = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = new_arr) {
        ctx.result.set_undefined(); return;
    }
    HObject* result = new_arr;
    result.prototype = ctx.heap.array_proto;

    for (uint i = 0; i < len; i++) {
        TVal elem = array_get_elem(obj, i, ctx.heap);
        array_set_elem(result, i, elem, ctx.heap);
    }
    array_set_length(result, len, ctx.heap);

    // Compact defined elements to the front
    uint def_count = 0;
    for (uint i = 0; i < len; i++) {
        TVal elem = array_get_elem(result, i, ctx.heap);
        if (!elem.is_undefined()) {
            array_set_elem(result, def_count, elem, ctx.heap);
            def_count++;
        }
    }

    // Bubble-sort defined elements by string comparison
    for (uint i = 0; i < def_count; i++) {
        for (uint j = 0; j < def_count - 1 - i; j++) {
            TVal a = array_get_elem(result, j, ctx.heap);
            TVal b = array_get_elem(result, j + 1, ctx.heap);
            HString* a_str = builtin_to_string(ctx.heap, &a);
            HString* b_str = builtin_to_string(ctx.heap, &b);
            int cmp = 0;
            if (a_str != null && b_str != null) {
                cmp = hstring::hstring_compare(a_str, b_str);
            } else if (a_str == null && b_str == null) {
                cmp = 0;
            } else if (a_str == null) {
                cmp = 1;
            } else {
                cmp = -1;
            }
            if (cmp > 0) {
                array_set_elem(result, j, b, ctx.heap);
                array_set_elem(result, j + 1, a, ctx.heap);
            }
        }
    }

    ctx.result.set_object(result);
}

// ============================================================================
// Array.prototype.toSpliced (ES2023 §23.1.3.35)
// ============================================================================
fn void builtin_array_proto_toSpliced(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) {
        TVal this_val = ctx.regs[ctx.base_reg - 1];
        if (this_val.is_undefined() || this_val.is_null()) {
            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (try err = err_raw) {
                err.prototype = ctx.heap.type_err_proto;
                HString* msg = builtin_intern_string(ctx.heap, "Array.prototype.toSpliced called on null or undefined");
                TVal msg_tv; msg_tv.set_string(msg);
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                ctx.should_throw = true;
                ctx.throw_value.set_object(err);
            }
        }
        return;
    }

    uint len = array_get_length(obj, ctx.heap);

    // Get relativeStart (argument 0)
    double relative_start = 0.0;
    if (ctx.argc > 0) {
        TVal* arg = &ctx.regs[ctx.base_reg];
        if (arg.is_fastint()) {
            relative_start = (double)arg.get_fastint();
        } else if (arg.is_number()) {
            relative_start = arg.get_number();
        }
    }

    uint actual_start;
    if (relative_start < 0) {
        double tmp = (double)len + relative_start;
        actual_start = tmp < 0 ? 0 : (uint)(long)tmp;
    } else {
        actual_start = relative_start > (double)len ? len : (uint)(long)relative_start;
    }

    // Get actualDeleteCount
    uint actual_delete_count;
    if (ctx.argc <= 1) {
        actual_delete_count = len - actual_start;
    } else {
        TVal* arg = &ctx.regs[ctx.base_reg + 1];
        double delete_count;
        if (arg.is_fastint()) {
            delete_count = (double)arg.get_fastint();
        } else if (arg.is_number()) {
            delete_count = arg.get_number();
        } else {
            delete_count = 0;
        }

        if (delete_count < 0) delete_count = 0;
        uint dc = (uint)(long)delete_count;
        actual_delete_count = dc > (len - actual_start) ? (len - actual_start) : dc;
    }

    // Get items to insert
    ushort item_count = 0;
    if (ctx.argc > 2) {
        item_count = ctx.argc - 2;
    }

    // Create new array: prefix + items + suffix
    HObject*? new_arr = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = new_arr) {
        ctx.result.set_undefined(); return;
    }
    HObject* result = new_arr;
    result.prototype = ctx.heap.array_proto;

    uint n = 0;
    // Copy prefix [0, actual_start)
    for (uint i = 0; i < actual_start; i++) {
        TVal elem = array_get_elem(obj, i, ctx.heap);
        array_set_elem(result, n, elem, ctx.heap);
        n++;
    }
    // Insert new items
    for (ushort i = 0; i < item_count; i++) {
        TVal item = ctx.regs[ctx.base_reg + 2 + i];
        array_set_elem(result, n, item, ctx.heap);
        n++;
    }
    // Copy suffix [actual_start + actual_delete_count, len)
    for (uint i = actual_start + actual_delete_count; i < len; i++) {
        TVal elem = array_get_elem(obj, i, ctx.heap);
        array_set_elem(result, n, elem, ctx.heap);
        n++;
    }
    array_set_length(result, n, ctx.heap);

    ctx.result.set_object(result);
}

// ============================================================================
// Array.prototype.with (ES2023 §23.1.3.37)
// ============================================================================
fn void builtin_array_proto_with(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) {
        TVal this_val = ctx.regs[ctx.base_reg - 1];
        if (this_val.is_undefined() || this_val.is_null()) {
            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (try err = err_raw) {
                err.prototype = ctx.heap.type_err_proto;
                HString* msg = builtin_intern_string(ctx.heap, "Array.prototype.with called on null or undefined");
                TVal msg_tv; msg_tv.set_string(msg);
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
                ctx.should_throw = true;
                ctx.throw_value.set_object(err);
            }
        }
        return;
    }

    uint len = array_get_length(obj, ctx.heap);

    // Get index using ToIntegerOrInfinity
    double index_d = 0.0;
    if (ctx.argc > 0) {
        TVal* arg = &ctx.regs[ctx.base_reg];
        index_d = builtin_to_integer(arg);
    }

    uint actual_index;
    if (index_d < 0) {
        double tmp = (double)len + index_d;
        if (tmp < 0) {
            actual_index = len; // Out of range
        } else {
            actual_index = (uint)(long)tmp;
        }
    } else if (index_d < (double)len) {
        actual_index = (uint)(long)index_d;
    } else {
        actual_index = len; // Out of range (includes NaN, Infinity, >= len)
    }

    if (actual_index >= len) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.range_err_proto;
            HString* msg = builtin_intern_string(ctx.heap, "Invalid array index");
            TVal msg_tv; msg_tv.set_string(msg);
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
            ctx.should_throw = true;
            ctx.throw_value.set_object(err);
        }
        return;
    }

    // Get value to set
    TVal new_val;
    if (ctx.argc > 1) {
        new_val = ctx.regs[ctx.base_reg + 1];
    } else {
        new_val.set_undefined();
    }

    // Create new array
    HObject*? new_arr = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = new_arr) {
        ctx.result.set_undefined(); return;
    }
    HObject* result = new_arr;
    result.prototype = ctx.heap.array_proto;

    for (uint i = 0; i < len; i++) {
        if (i == actual_index) {
            array_set_elem(result, i, new_val, ctx.heap);
        } else {
            TVal elem = array_get_elem(obj, i, ctx.heap);
            array_set_elem(result, i, elem, ctx.heap);
        }
    }
    array_set_length(result, len, ctx.heap);

    ctx.result.set_object(result);
}

// ============================================================================
// Array.prototype.unshift (ES5 §15.4.4.13)
// ============================================================================
fn void builtin_array_proto_unshift(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    uint len = array_get_length(obj, ctx.heap);
    ushort arg_count = ctx.argc;

    // Shift existing elements right by arg_count
    for (uint k = len; k > 0; k--) {
        uint from = k - 1;
        uint to = k - 1 + arg_count;
        TVal elem = array_get_elem(obj, from, ctx.heap);
        array_set_elem(obj, to, elem, ctx.heap);
    }

    // Insert new items at the beginning
    for (ushort i = 0; i < arg_count; i++) {
        TVal arg = ctx.regs[ctx.base_reg + i];
        array_set_elem(obj, i, arg, ctx.heap);
    }

    uint new_len = len + (uint)arg_count;
    array_set_length(obj, new_len, ctx.heap);

    ctx.result.set_fastint((long)new_len);
}

// ============================================================================
// Array.prototype.indexOf (ES5 §15.4.4.14)
// ============================================================================
fn void builtin_array_proto_indexOf(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    uint len;
    if (!array_to_length_checked(obj, ctx.heap, ctx, &len)) { ctx.result.set_undefined(); return; }

    if (ctx.argc == 0) {
        ctx.result.set_fastint(-1);
        return;
    }

    TVal search_elem = ctx.regs[ctx.base_reg];

    // Get fromIndex (default 0)
    double relative_start = 0.0;
    if (ctx.argc > 1) {
        TVal* arg = &ctx.regs[ctx.base_reg + 1];
        if (arg.is_fastint()) {
            relative_start = (double)arg.get_fastint();
        } else if (arg.is_number()) {
            relative_start = arg.get_number();
        }
    }

    uint k;
    if (relative_start < 0) {
        double tmp = (double)len + relative_start;
        k = tmp < 0 ? 0 : (uint)(long)tmp;
    } else {
        k = relative_start > (double)len ? len : (uint)(long)relative_start;
    }

    for (; k < len; k++) {
        TVal v;
        if (arr_get_elem_vm(obj, k, ctx.heap, ctx.vm, &v)) {
            if (array_strict_equals(v, search_elem)) {
                ctx.result.set_fastint((long)k);
                return;
            }
        }
    }

    ctx.result.set_fastint(-1);
}

// ============================================================================
// Array.prototype.lastIndexOf (ES5 §15.4.4.15)
// ============================================================================
fn void builtin_array_proto_lastIndexOf(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    uint len;
    if (!array_to_length_checked(obj, ctx.heap, ctx, &len)) { ctx.result.set_undefined(); return; }

    if (ctx.argc == 0) {
        ctx.result.set_fastint(-1);
        return;
    }

    TVal search_elem = ctx.regs[ctx.base_reg];

    // Get fromIndex (default len - 1)
    double relative_start = (double)(len - 1);
    if (ctx.argc > 1) {
        TVal* arg = &ctx.regs[ctx.base_reg + 1];
        if (arg.is_fastint()) {
            relative_start = (double)arg.get_fastint();
        } else if (arg.is_number()) {
            relative_start = arg.get_number();
        }
    }

    int k;
    if (relative_start < 0) {
        double tmp = (double)len + relative_start;
        k = tmp < 0 ? -1 : (int)(long)tmp;
    } else {
        k = relative_start > (double)len ? (int)len - 1 : (int)(long)relative_start;
    }

    for (; k >= 0; k--) {
        TVal v;
        if (arr_get_elem_vm(obj, (uint)k, ctx.heap, ctx.vm, &v)) {
            if (array_strict_equals(v, search_elem)) {
                ctx.result.set_fastint((long)k);
                return;
            }
        }
    }

    ctx.result.set_fastint(-1);
}

// ============================================================================
// Array.prototype.concat (ES6 §22.1.3.1 — with Symbol.isConcatSpreadable)
// ============================================================================
fn void builtin_array_proto_concat(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    // Create result array
    HObject*? new_arr = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = new_arr) {
        ctx.result.set_undefined();
        return;
    }
    HObject* result = new_arr;
    result.prototype = ctx.heap.array_proto;

    uint n = 0;

    // First, copy 'this' elements
    uint this_len = array_get_length(obj, ctx.heap);
    for (uint i = 0; i < this_len; i++) {
        TVal elem = array_get_elem(obj, i, ctx.heap);
        array_set_elem(result, n, elem, ctx.heap);
        n++;
    }

    // Get the @@isConcatSpreadable symbol key (cached on heap)
    HString* concat_sym = ensure_concatspreadable_symbol(ctx.heap);

    // Then process each argument (ES6 §22.1.3.1.2)
    for (ushort arg_i = 0; arg_i < ctx.argc; arg_i++) {
        TVal arg = ctx.regs[ctx.base_reg + arg_i];

        // Default: spread if Array, otherwise add as element
        bool spread = false;

        if (arg.is_object() && arg.get_heapptr() != null) {
            HObject* arg_obj = (HObject*)arg.get_heapptr();
            bool is_array = arg_obj.get_class() == hobject::ObjClass.ARRAY;

            if (concat_sym != null) {
                // Look up @@isConcatSpreadable on the argument
                TVal? spreadable_val = arg_obj.get_prop_proto(concat_sym);
                if (try spreadable = spreadable_val) {
                    // Symbol property found — use its truthiness to decide
                    spread = builtin_to_boolean(&spreadable);
                } else {
                    // Symbol property absent — fall back to default
                    spread = is_array;
                }
            } else {
                // Symbol not available — fall back to default
                spread = is_array;
            }

            if (spread) {
                // Spread elements from the argument
                uint arg_len = array_get_length(arg_obj, ctx.heap);
                for (uint i = 0; i < arg_len; i++) {
                    TVal elem = array_get_elem(arg_obj, i, ctx.heap);
                    array_set_elem(result, n, elem, ctx.heap);
                    n++;
                }
            } else {
                // Add as single element
                array_set_elem(result, n, arg, ctx.heap);
                n++;
            }
        } else {
            // Primitive — add as single element
            array_set_elem(result, n, arg, ctx.heap);
            n++;
        }
    }

    array_set_length(result, n, ctx.heap);

    ctx.result.set_object(result);
}

fn void builtin_array_from(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;

    // Step 1: Get items (first arg) — use undefined if missing
    TVal items;
    if (ctx.argc > 0) {
        items = ctx.regs[ctx.base_reg];
    } else {
        items.set_undefined();
    }

    // Step 2: Check mapfn (second arg, optional)
    TVal mapfn;
    bool mapping = false;
    TVal this_arg;
    if (ctx.argc > 1) {
        mapfn = ctx.regs[ctx.base_reg + 1];
        if (!mapfn.is_undefined() && !mapfn.is_null()) {
            bool callable = false;
            if (mapfn.is_lightfunc()) {
                callable = true;
            } else if (mapfn.is_object() && mapfn.get_heapptr() != null) {
                HObject* fn_obj = (HObject*)mapfn.get_heapptr();
                callable = fn_obj.is_callable();
            }
            if (!callable) {
                HObject*? err_raw = heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = heap.type_err_proto;
                    HString* msg_str = builtin_intern_string(heap, "The second argument to Array.from is not callable");
                    if (msg_str != null) {
                        TVal msg_val;
                        msg_val.set_string(msg_str);
                        HString* msg_key = builtin_intern_string(heap, "message");
                        err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
                    }
                    ctx.should_throw = true;
                    ctx.throw_value.set_object(err);
                }
                ctx.result.set_undefined();
                return;
            }
            mapping = true;
            if (ctx.argc > 2) {
                this_arg = ctx.regs[ctx.base_reg + 2];
            } else {
                this_arg.set_undefined();
            }
        }
    }

    // Step 3: Try iterable path — get @@iterator from items
    HString* iter_sym = ensure_iterator_symbol(heap);
    bool use_iter = false;
    TVal iterator;
    TVal iterable = items;

    if (iter_sym != null) {
        // GetMethod(items, @@iterator) — ToObject if needed for property access
        HObject* items_obj = null;
        if (items.is_object() && items.get_heapptr() != null) {
            items_obj = (HObject*)items.get_heapptr();
        } else if (!items.is_undefined() && !items.is_null()) {
            // Wrap primitive in temporary object to look up @@iterator
            HObject*? wrapped = heap.alloc_object(hobject::ObjClass.OBJECT);
            if (try w = wrapped) {
                items_obj = w;
                // For strings, set the wrapped primitive value
                if (items.is_string()) {
                    (*items_obj.extra_ptr()).prim.primitive_value = items;
                }
                HString* proto_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
                if (proto_key != null && heap.string_proto != null) {
                    TVal proto_tv; proto_tv.set_object(heap.string_proto);
                    PropFlags pf; pf.writable = false; pf.enumerable = false; pf.configurable = false; pf.is_accessor = false;
                    items_obj.put_prop(proto_key, proto_tv, pf);
                }
            }
        }

        if (items_obj != null) {
            TVal? iter_method_opt = items_obj.get_prop_proto(iter_sym);
            if (try iter_method = iter_method_opt) {
                bool callable = false;
                if (iter_method.is_lightfunc()) {
                    callable = true;
                } else if (iter_method.is_object() && iter_method.get_heapptr() != null) {
                    HObject* fn_hobj = (HObject*)iter_method.get_heapptr();
                    callable = fn_hobj.is_callable();
                }
                if (callable && heap.call_fn != null && ctx.vm != null) {
                    iterator = heap.call_fn(ctx.vm, iter_method, null, 0, items);
                    if (ctx.heap.has_error) { ctx.should_throw = true; ctx.heap.has_error = false; return; }
                    use_iter = true;
                }
            }
        }
    }

    if (use_iter) {
        // === Iterable path ===
        HObject*? arr_raw = heap.alloc_object(hobject::ObjClass.ARRAY);
        if (catch err = arr_raw) { ctx.result.set_undefined(); return; }
        HObject* arr = arr_raw;
        arr.prototype = heap.array_proto;

        HString* next_key = builtin_intern_string(heap, "next");
        HString* done_key = builtin_intern_string(heap, "done");
        HString* value_key = builtin_intern_string(heap, "value");

        uint k = 0;
        while (heap.call_fn != null && ctx.vm != null) {
            if (!iterator.is_object() || iterator.get_heapptr() == null) break;
            HObject* iter_obj = (HObject*)iterator.get_heapptr();

            TVal? next_method_opt = iter_obj.get_prop_proto(next_key);
            TVal next_method;
            if (try nm = next_method_opt) {
                next_method = nm;
            } else { break; }

            bool callable = false;
            if (next_method.is_lightfunc()) {
                callable = true;
            } else if (next_method.is_object() && next_method.get_heapptr() != null) {
                callable = ((HObject*)next_method.get_heapptr()).is_callable();
            }
            if (!callable) break;

            TVal result = heap.call_fn(ctx.vm, next_method, null, 0, iterator);
            if (ctx.heap.has_error) { ctx.should_throw = true; ctx.heap.has_error = false; return; }
            if (!result.is_object() || result.get_heapptr() == null) break;

            HObject* result_obj = (HObject*)result.get_heapptr();
            TVal? done_opt = result_obj.get_prop_proto(done_key);
            bool done = false;
            if (try dv = done_opt) {
                done = builtin_to_boolean(&dv);
            }
            if (done) break;

            TVal? value_opt = result_obj.get_prop_proto(value_key);
            TVal next_value;
            if (try vv = value_opt) {
                next_value = vv;
            } else { break; }

            // Apply mapfn if mapping
            TVal final_value = next_value;
            if (mapping) {
                TVal[2] map_args;
                map_args[0] = next_value;
                TVal k_tv; k_tv.set_fastint((long)k);
                map_args[1] = k_tv;
                final_value = heap.call_fn(ctx.vm, mapfn, &map_args[0], 2, this_arg);
                if (ctx.heap.has_error) { ctx.should_throw = true; ctx.heap.has_error = false; return; }
            }
            HString* pk = heap.int_to_hstring((long)k);
            if (pk != null) {
                arr.put_prop(pk, final_value, hobject::PROP_FLAGS_WEC);
            }
            k++;
        }

        HString* len_key = builtin_intern_string(heap, "length");
        if (len_key != null) {
            TVal len_tv; len_tv.set_fastint((long)k);
            arr.put_prop(len_key, len_tv, hobject::PROP_FLAGS_WEC);
        }

        ctx.result.set_object(arr);
        return;
    }

    // === Array-like path ===
    // Step: items must not be null or undefined
    if (items.is_undefined() || items.is_null()) {
        HObject*? err_raw = heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = heap.type_err_proto;
            HString* msg_str = builtin_intern_string(heap, "Cannot convert undefined or null to object");
            if (msg_str != null) {
                TVal msg_val;
                msg_val.set_string(msg_str);
                HString* msg_key = builtin_intern_string(heap, "message");
                err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
            }
            ctx.should_throw = true;
            ctx.throw_value.set_object(err);
        }
        ctx.result.set_undefined();
        return;
    }

    // ToObject — handle strings specially (direct char access)
    HObject* array_like;
    bool is_string_prim = items.is_string();
    HString* str_val = null;
    if (is_string_prim) {
        str_val = (HString*)items.get_heapptr();
    } else if (items.is_object() && items.get_heapptr() != null) {
        array_like = (HObject*)items.get_heapptr();
    } else {
        HObject*? wrapped = heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err = wrapped) { ctx.result.set_undefined(); return; }
        array_like = wrapped;
        (*array_like.extra_ptr()).prim.primitive_value = items;
    }

    // Get .length
    HString* len_key = builtin_intern_string(heap, "length");
    uint len = 0;
    if (is_string_prim) {
        len = str_val.char_length();
    } else if (len_key != null) {
        TVal? len_opt = array_like.get_prop_proto(len_key);
        if (try lv = len_opt) {
            double len_d = builtin_to_number_getdouble(ctx, &lv);
            if (len_d <= 0) {
                len = 0;
            } else if (math::is_inf(len_d)) {
                len = 0xFFFFFFFF;  // max uint
            } else if (len_d > (double)0xFFFFFFFF) {
                len = 0xFFFFFFFF;
            } else {
                len = (uint)(long)len_d;
            }
        }
    }

    // Create result array
    HObject*? arr_raw = heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) { ctx.result.set_undefined(); return; }
    HObject* arr = arr_raw;
    arr.prototype = heap.array_proto;

    for (uint k = 0; k < len; k++) {
        HString* pk = heap.int_to_hstring((long)k);
        TVal k_value;
        k_value.set_undefined();

        if (is_string_prim && str_val != null) {
            // String primitive: direct character access by byte index
            char* data = str_val.get_cstr();
            uint blen = str_val.blen;
            if (k < blen) {
                char[2] char_buf;
                char_buf[0] = data[k];
                char_buf[1] = 0;
                HString* ch_str = builtin_intern_string(heap, char_buf[:1]);
                if (ch_str != null) k_value.set_string(ch_str);
            }
        } else if (pk != null) {
            TVal? elem_opt = array_like.get_prop_proto(pk);
            if (try elem = elem_opt) {
                k_value = elem;
            }
        }

        TVal final_value = k_value;
        if (mapping) {
            TVal[2] map_args;
            map_args[0] = k_value;
            TVal k_tv; k_tv.set_fastint((long)k);
            map_args[1] = k_tv;
            if (heap.call_fn != null && ctx.vm != null) {
                final_value = heap.call_fn(ctx.vm, mapfn, &map_args[0], 2, this_arg);
                if (ctx.heap.has_error) { ctx.should_throw = true; ctx.heap.has_error = false; return; }
            }
        }

        if (pk != null) {
            arr.put_prop(pk, final_value, hobject::PROP_FLAGS_WEC);
        }
    }

    // Set arr.length = len
    if (len_key != null) {
        TVal len_tv; len_tv.set_fastint((long)len);
        arr.put_prop(len_key, len_tv, hobject::PROP_FLAGS_WEC);
    }

    ctx.result.set_object(arr);
}

/// Array.isArray(arg) — ES6 §22.1.2.2
fn void builtin_array_isArray(BuiltinContext* ctx) {
    if (ctx.argc == 0) {
        ctx.result.set_boolean(false);
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    if (!arg.is_object() || arg.get_heapptr() == null) {
        ctx.result.set_boolean(false);
        return;
    }
    HObject* obj = (HObject*)arg.get_heapptr();
    ctx.result.set_boolean(obj.get_class() == hobject::ObjClass.ARRAY);
}

// ============================================================================
// Array constructor registration

// ============================================================================
// Array.prototype callback methods — native implementations using heap.call_fn
// ============================================================================

/// Helper: ToObject for Array.prototype methods (ES5 §9.9).
/// Wraps primitives (Boolean/Number/String) into wrapper objects.
/// Returns null-optional for null/undefined (caller should throw TypeError).
fn HObject*? arr_to_object(TVal val, Heap* heap) {
    if (val.is_object() && val.get_heapptr() != null) {
        return (HObject*)val.get_heapptr();
    }
    if (val.is_null() || val.is_undefined()) {
        return null;
    }
    // Boolean → Boolean wrapper
    if (val.is_boolean()) {
        HObject*? obj_raw = heap.alloc_object(hobject::ObjClass.BOOLEAN);
        if (try obj = obj_raw) {
            obj.prototype = heap.bool_proto;
            (*obj.extra_ptr()).prim.primitive_value.set_boolean(val.get_boolean());
            return obj;
        }
        return null;
    }
    // Number/fastint → Number wrapper
    if (val.is_number() || val.is_fastint()) {
        HObject*? obj_raw = heap.alloc_object(hobject::ObjClass.NUMBER);
        if (try obj = obj_raw) {
            obj.prototype = heap.number_proto;
            (*obj.extra_ptr()).prim.primitive_value = val;
            return obj;
        }
        return null;
    }
    // String → String wrapper with indexed properties
    if (val.is_string()) {
        HObject*? obj_raw = heap.alloc_object(hobject::ObjClass.STRING);
        if (try obj = obj_raw) {
            obj.flags.exotic_stringobj = true;
            obj.prototype = heap.string_proto;
            HString* prim_str = (HString*)val.get_heapptr();
            (*obj.extra_ptr()).prim.primitive_value.set_string(prim_str);
            HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
            TVal len_tv;
            len_tv.set_fastint((long)prim_str.char_length());
            obj.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NNC);
            // Indexed character properties are served lazily via the exotic_stringobj flag;
            // no per-character own properties are materialised at construction time.
            return obj;
        }
        return null;
    }
    return null;
}

/// Helper: throw TypeError with a message.
fn void arr_throw_type_error(BuiltinContext* ctx, char[] msg) {
    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_str = builtin_intern_string(ctx.heap, msg);
        if (msg_str != null) {
            TVal msg_val;
            msg_val.set_string(msg_str);
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
        }
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
    }
}

/// Helper: check if numeric key exists on object (ES5 §15.4.5.1 step 4 "k in O").
/// Uses get_prop_or_accessor_proto to handle accessor properties.
fn bool arr_has_prop(HObject* obj, uint key, Heap* heap) {
    // Fast path: dense array storage
    if (obj.get_class() == hobject::ObjClass.ARRAY) {
        if (try v = obj.get_array_idx(key)) { return true; }
        // Fall through: element may be stored as a named property (sparse or pre-dense)
    }
    HString* pk = heap.int_to_hstring((long)key);
    if (pk == null) return false;
    // Check own properties first (handles accessor properties set via defineProperty)
    int own_idx = obj.find_prop_idx(pk);
    if (own_idx >= 0) return true;
    // Then check prototype chain
    TVal? found = obj.get_prop_proto(pk);
    return @ok(found);
}

/// Helper: invoke a getter function. Returns the getter result or undefined.
/// Used by arr_get_elem to handle accessor properties at numeric indices.
fn TVal arr_invoke_getter(HObject* obj, TVal getter_fn, Heap* heap, void* vm_ptr) {
    if (getter_fn.is_undefined() || getter_fn.is_null()) {
        TVal undef; undef.set_undefined(); return undef;
    }
    if (!getter_fn.is_object() || getter_fn.get_heapptr() == null) {
        TVal undef; undef.set_undefined(); return undef;
    }
    HObject* fn_obj = (HObject*)getter_fn.get_heapptr();
    if (!fn_obj.is_callable()) {
        TVal undef; undef.set_undefined(); return undef;
    }
    if (heap.call_fn != null && vm_ptr != null) {
        TVal this_val;
        this_val.set_object(obj);
        TVal result = heap.call_fn(vm_ptr, getter_fn, null, 0, this_val);
        if (heap.has_error) {
            heap.has_error = false;
            TVal undef; undef.set_undefined(); return undef;
        }
        return result;
    }
    TVal undef; undef.set_undefined(); return undef;
}

/// Helper: get value at numeric index, returns false if not present.
/// Handles accessor properties by invoking the getter.
fn bool arr_get_elem(HObject* obj, uint key, Heap* heap, TVal* out) {
    HString* pk = heap.int_to_hstring((long)key);
    if (pk == null) return false;

    // Check own properties first — may be an accessor (set via defineProperty)
    // This must come BEFORE the dense array fast path because accessor properties
    // at numeric indices override the dense array value.
    int own_idx = obj.find_prop_idx(pk);
    if (own_idx >= 0) {
        PropFlags pf = obj.get_prop_flags((uint)own_idx);
        if (pf.is_accessor) {
            TVal gs_slot = obj.prop_values()[own_idx];
            TVal getter_fn = hobject::hobject_access_getter(gs_slot);
            *out = arr_invoke_getter(obj, getter_fn, heap, null);
            return true;
        }
        *out = obj.prop_values()[own_idx];
        return true;
    }

    // Fast path: dense array storage (no accessor at this index)
    if (obj.get_class() == hobject::ObjClass.ARRAY) {
        if (try v = obj.get_array_idx(key)) {
            *out = v;
            return true;
        }
        // Fall through: element may be stored as a named property (sparse or pre-dense)
    }

    // Prototype chain lookup
    hobject::PropLookupResult res = obj.get_prop_or_accessor_proto(pk, true);
    if (res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
        *out = arr_invoke_getter(obj, res.acc.accessor_fn, heap, null);
        return true;
    } else if (res.kind == hobject::PropLookupKind.PROP_DATA) {
        *out = res.data_val;
        return true;
    }
    return false;
}

/// Helper: get value at numeric index with VM context (for getter invocation).
/// Handles accessor properties by invoking the getter via VM.
fn bool arr_get_elem_vm(HObject* obj, uint key, Heap* heap, void* vm_ptr, TVal* out) {
    // Fast path: dense array storage (covers the vast majority of cases)
    if (obj.get_class() == hobject::ObjClass.ARRAY) {
        if (try v = obj.get_array_idx(key)) {
            *out = v;
            return true;
        }
    }

    HString* pk = heap.int_to_hstring((long)key);
    if (pk == null) return false;

    // Check own properties — may be an accessor (set via defineProperty)
    int own_idx = obj.find_prop_idx(pk);
    if (own_idx >= 0) {
        PropFlags pf = obj.get_prop_flags((uint)own_idx);
        if (pf.is_accessor) {
            TVal gs_slot = obj.prop_values()[own_idx];
            TVal getter_fn = hobject::hobject_access_getter(gs_slot);
            *out = arr_invoke_getter(obj, getter_fn, heap, vm_ptr);
            return true;
        }
        *out = obj.prop_values()[own_idx];
        return true;
    }

    // Prototype chain lookup
    hobject::PropLookupResult res = obj.get_prop_or_accessor_proto(pk, true);
    if (res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
        *out = arr_invoke_getter(obj, res.acc.accessor_fn, heap, vm_ptr);
        return true;
    } else if (res.kind == hobject::PropLookupKind.PROP_DATA) {
        *out = res.data_val;
        return true;
    }
    return false;
}

/// Helper: check if callback is callable, throw TypeError if not.
fn bool arr_check_callback(TVal val, BuiltinContext* ctx) {
    if (val.is_object() && val.get_heapptr() != null && ((HObject*)val.get_heapptr()).is_callable()) {
        return true;
    }
    arr_throw_type_error(ctx, "callback is not a function");
    return false;
}

/// Helper: call a function with (v, k, O) args and thisArg.
/// If the callback throws, set ctx.should_throw and ctx.throw_value so the
/// CALL handler in vm.c3 propagates the error back to an outer JS try/catch.
fn TVal arr_call_callback(BuiltinContext* ctx, TVal callback, TVal thisArg, TVal v, uint k, HObject* o) {
    TVal[3] args;
    args[0] = v;
    TVal k_tv; k_tv.set_fastint((long)k);
    args[1] = k_tv;
    args[2].set_object((void*)o);
    TVal res = ctx.heap.call_fn(ctx.vm, callback, &args[0], 3, thisArg);
    if (ctx.heap.has_error) {
        ctx.should_throw = true;
        ctx.throw_value = ctx.heap.error_value;
        ctx.heap.has_error = false;
    }
    return res;
}

/// Array.prototype.forEach(callbackfn[, thisArg]) — ES5 §15.4.4.18
fn void builtin_array_proto_forEach(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    HObject*? o_raw = arr_to_object(this_val, ctx.heap);
    if (catch err = o_raw) {
        arr_throw_type_error(ctx, "Cannot convert undefined or null to object");
        return;
    }
    HObject* o = o_raw;
    if (ctx.argc < 1 || !arr_check_callback(ctx.regs[ctx.base_reg], ctx)) {
        return;
    }
    TVal callback = ctx.regs[ctx.base_reg];
    TVal thisArg;
    if (ctx.argc >= 2) { thisArg = ctx.regs[ctx.base_reg + 1]; } else { thisArg.set_undefined(); }
    uint len;
    if (!array_to_length(o, ctx.heap, ctx, &len)) { ctx.result.set_undefined(); return; }
    for (uint k = 0; k < len; k++) {
        if (arr_has_prop(o, k, ctx.heap)) {
            TVal v;
            if (arr_get_elem_vm(o, k, ctx.heap, ctx.vm, &v)) {
                arr_call_callback(ctx, callback, thisArg, v, k, o);
                if (ctx.should_throw) { ctx.result.set_undefined(); return; }
            }
        }
    }
    ctx.result.set_undefined();
}

/// Array.prototype.map(callbackfn[, thisArg]) — ES5 §15.4.4.19
fn void builtin_array_proto_map(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    HObject*? o_raw = arr_to_object(this_val, ctx.heap);
    if (catch err = o_raw) {
        arr_throw_type_error(ctx, "Cannot convert undefined or null to object");
        return;
    }
    HObject* o = o_raw;
    if (ctx.argc < 1 || !arr_check_callback(ctx.regs[ctx.base_reg], ctx)) {
        return;
    }
    TVal callback = ctx.regs[ctx.base_reg];
    TVal thisArg;
    if (ctx.argc >= 2) { thisArg = ctx.regs[ctx.base_reg + 1]; } else { thisArg.set_undefined(); }
    uint len;
    if (!array_to_length(o, ctx.heap, ctx, &len)) { ctx.result.set_undefined(); return; }
    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) { ctx.result.set_undefined(); ctx.should_throw = true; return; }
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;
    uint aj = 0;
    for (uint k = 0; k < len; k++) {
        if (arr_has_prop(o, k, ctx.heap)) {
            TVal v;
            if (arr_get_elem_vm(o, k, ctx.heap, ctx.vm, &v)) {
                TVal mapped = arr_call_callback(ctx, callback, thisArg, v, k, o);
                if (ctx.should_throw) { ctx.result.set_undefined(); return; }
                HString* akey = ctx.heap.int_to_hstring((long)aj);
                if (akey != null) {
                    arr.put_prop(akey, mapped, hobject::PROP_FLAGS_WEC);
                }
                aj++;
            }
        }
    }
    HString* len_key = (HString*)ctx.heap.strs[heap::BuiltinStr.LENGTH];
    TVal len_tv; len_tv.set_fastint((long)aj);
    arr.put_prop(len_key, len_tv, hobject::PROP_FLAGS_WEC);
    ctx.result.set_object((void*)arr);
}

/// Array.prototype.filter(callbackfn[, thisArg]) — ES5 §15.4.4.20
fn void builtin_array_proto_filter(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    HObject*? o_raw = arr_to_object(this_val, ctx.heap);
    if (catch err = o_raw) {
        arr_throw_type_error(ctx, "Cannot convert undefined or null to object");
        return;
    }
    HObject* o = o_raw;
    if (ctx.argc < 1 || !arr_check_callback(ctx.regs[ctx.base_reg], ctx)) {
        return;
    }
    TVal callback = ctx.regs[ctx.base_reg];
    TVal thisArg;
    if (ctx.argc >= 2) { thisArg = ctx.regs[ctx.base_reg + 1]; } else { thisArg.set_undefined(); }
    uint len;
    if (!array_to_length(o, ctx.heap, ctx, &len)) { ctx.result.set_undefined(); return; }
    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) { ctx.result.set_undefined(); ctx.should_throw = true; return; }
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;
    uint aj = 0;
    for (uint k = 0; k < len; k++) {
        if (arr_has_prop(o, k, ctx.heap)) {
            TVal v;
            if (arr_get_elem_vm(o, k, ctx.heap, ctx.vm, &v)) {
                TVal sel = arr_call_callback(ctx, callback, thisArg, v, k, o);
                if (ctx.should_throw) { ctx.result.set_undefined(); return; }
                if (builtin_to_boolean(&sel)) {
                    HString* akey = ctx.heap.int_to_hstring((long)aj);
                    if (akey != null) {
                        arr.put_prop(akey, v, hobject::PROP_FLAGS_WEC);
                    }
                    aj++;
                }
            }
        }
    }
    HString* len_key = (HString*)ctx.heap.strs[heap::BuiltinStr.LENGTH];
    TVal len_tv; len_tv.set_fastint((long)aj);
    arr.put_prop(len_key, len_tv, hobject::PROP_FLAGS_WEC);
    ctx.result.set_object((void*)arr);
}

/// Array.prototype.find(callbackfn[, thisArg]) — ES6 §22.1.3.8
/// Returns the first element for which callbackfn returns truthy,
/// or undefined if none.
fn void builtin_array_proto_find(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    HObject*? o_raw = arr_to_object(this_val, ctx.heap);
    if (catch err = o_raw) {
        arr_throw_type_error(ctx, "Cannot convert undefined or null to object");
        return;
    }
    HObject* o = o_raw;
    if (ctx.argc < 1 || !arr_check_callback(ctx.regs[ctx.base_reg], ctx)) {
        return;
    }
    TVal callback = ctx.regs[ctx.base_reg];
    TVal thisArg;
    if (ctx.argc >= 2) { thisArg = ctx.regs[ctx.base_reg + 1]; } else { thisArg.set_undefined(); }
    uint len = array_get_length(o, ctx.heap);
    for (uint k = 0; k < len; k++) {
        if (arr_has_prop(o, k, ctx.heap)) {
            TVal v;
            if (arr_get_elem_vm(o, k, ctx.heap, ctx.vm, &v)) {
                TVal test = arr_call_callback(ctx, callback, thisArg, v, k, o);
                if (ctx.should_throw) { ctx.result.set_undefined(); return; }
                if (builtin_to_boolean(&test)) {
                    (*ctx.result) = v;
                    return;
                }
            }
        }
    }
    ctx.result.set_undefined();
}

/// Array.prototype.findLast(callbackfn[, thisArg]) — ES2023 §22.1.3.9
/// Returns the last element for which callbackfn returns truthy,
/// or undefined if none.
fn void builtin_array_proto_findLast(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    HObject*? o_raw = arr_to_object(this_val, ctx.heap);
    if (catch err = o_raw) {
        arr_throw_type_error(ctx, "Cannot convert undefined or null to object");
        return;
    }
    HObject* o = o_raw;
    if (ctx.argc < 1 || !arr_check_callback(ctx.regs[ctx.base_reg], ctx)) {
        return;
    }
    TVal callback = ctx.regs[ctx.base_reg];
    TVal thisArg;
    if (ctx.argc >= 2) { thisArg = ctx.regs[ctx.base_reg + 1]; } else { thisArg.set_undefined(); }
    uint len = array_get_length(o, ctx.heap);
    for (long k = (long)len - 1; k >= 0; k--) {
        if (arr_has_prop(o, (uint)k, ctx.heap)) {
            TVal v;
            if (arr_get_elem_vm(o, (uint)k, ctx.heap, ctx.vm, &v)) {
                TVal test = arr_call_callback(ctx, callback, thisArg, v, (uint)k, o);
                if (ctx.should_throw) { ctx.result.set_undefined(); return; }
                if (builtin_to_boolean(&test)) {
                    (*ctx.result) = v;
                    return;
                }
            }
        }
    }
    ctx.result.set_undefined();
}

/// Array.prototype.findLastIndex(callbackfn[, thisArg]) — ES2023 §22.1.3.10
/// Returns the last index for which callbackfn returns truthy,
/// or -1 if none.
fn void builtin_array_proto_findLastIndex(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    HObject*? o_raw = arr_to_object(this_val, ctx.heap);
    if (catch err = o_raw) {
        arr_throw_type_error(ctx, "Cannot convert undefined or null to object");
        return;
    }
    HObject* o = o_raw;
    if (ctx.argc < 1 || !arr_check_callback(ctx.regs[ctx.base_reg], ctx)) {
        return;
    }
    TVal callback = ctx.regs[ctx.base_reg];
    TVal thisArg;
    if (ctx.argc >= 2) { thisArg = ctx.regs[ctx.base_reg + 1]; } else { thisArg.set_undefined(); }
    uint len = array_get_length(o, ctx.heap);
    for (long k = (long)len - 1; k >= 0; k--) {
        if (arr_has_prop(o, (uint)k, ctx.heap)) {
            TVal v;
            if (arr_get_elem_vm(o, (uint)k, ctx.heap, ctx.vm, &v)) {
                TVal test = arr_call_callback(ctx, callback, thisArg, v, (uint)k, o);
                if (ctx.should_throw) { ctx.result.set_undefined(); return; }
                if (builtin_to_boolean(&test)) {
                    TVal k_tv; k_tv.set_fastint(k);
                    (*ctx.result) = k_tv;
                    return;
                }
            }
        }
    }
    TVal neg; neg.set_fastint(-1);
    (*ctx.result) = neg;
}

/// Array.prototype.findIndex(callbackfn[, thisArg]) — ES6 §22.1.3.9
/// Returns the index of the first element for which callbackfn returns truthy,
/// or -1 if none.
fn void builtin_array_proto_findIndex(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    HObject*? o_raw = arr_to_object(this_val, ctx.heap);
    if (catch err = o_raw) {
        arr_throw_type_error(ctx, "Cannot convert undefined or null to object");
        return;
    }
    HObject* o = o_raw;
    if (ctx.argc < 1 || !arr_check_callback(ctx.regs[ctx.base_reg], ctx)) {
        return;
    }
    TVal callback = ctx.regs[ctx.base_reg];
    TVal thisArg;
    if (ctx.argc >= 2) { thisArg = ctx.regs[ctx.base_reg + 1]; } else { thisArg.set_undefined(); }
    uint len = array_get_length(o, ctx.heap);
    for (uint k = 0; k < len; k++) {
        if (arr_has_prop(o, k, ctx.heap)) {
            TVal v;
            if (arr_get_elem_vm(o, k, ctx.heap, ctx.vm, &v)) {
                TVal test = arr_call_callback(ctx, callback, thisArg, v, k, o);
                if (ctx.should_throw) { ctx.result.set_undefined(); return; }
                if (builtin_to_boolean(&test)) {
                    TVal k_tv; k_tv.set_fastint((long)k);
                    (*ctx.result) = k_tv;
                    return;
                }
            }
        }
    }
    TVal neg; neg.set_fastint(-1);
    (*ctx.result) = neg;
}

/// Array.prototype.every(callbackfn[, thisArg]) — ES5 §15.4.4.17
fn void builtin_array_proto_every(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    HObject*? o_raw = arr_to_object(this_val, ctx.heap);
    if (catch err = o_raw) {
        arr_throw_type_error(ctx, "Cannot convert undefined or null to object");
        return;
    }
    HObject* o = o_raw;
    if (ctx.argc < 1 || !arr_check_callback(ctx.regs[ctx.base_reg], ctx)) {
        return;
    }
    TVal callback = ctx.regs[ctx.base_reg];
    TVal thisArg;
    if (ctx.argc >= 2) { thisArg = ctx.regs[ctx.base_reg + 1]; } else { thisArg.set_undefined(); }
    uint len;
    if (!array_to_length(o, ctx.heap, ctx, &len)) { ctx.result.set_undefined(); return; }
    for (uint k = 0; k < len; k++) {
        if (arr_has_prop(o, k, ctx.heap)) {
            TVal v;
            if (arr_get_elem_vm(o, k, ctx.heap, ctx.vm, &v)) {
                TVal test = arr_call_callback(ctx, callback, thisArg, v, k, o);
                if (ctx.should_throw) { ctx.result.set_undefined(); return; }
                if (!builtin_to_boolean(&test)) {
                    ctx.result.set_boolean(false);
                    return;
                }
            }
        }
    }
    ctx.result.set_boolean(true);
}

/// Array.prototype.some(callbackfn[, thisArg]) — ES5 §15.4.4.16
fn void builtin_array_proto_some(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    HObject*? o_raw = arr_to_object(this_val, ctx.heap);
    if (catch err = o_raw) {
        arr_throw_type_error(ctx, "Cannot convert undefined or null to object");
        return;
    }
    HObject* o = o_raw;
    if (ctx.argc < 1 || !arr_check_callback(ctx.regs[ctx.base_reg], ctx)) {
        return;
    }
    TVal callback = ctx.regs[ctx.base_reg];
    TVal thisArg;
    if (ctx.argc >= 2) { thisArg = ctx.regs[ctx.base_reg + 1]; } else { thisArg.set_undefined(); }
    uint len;
    if (!array_to_length(o, ctx.heap, ctx, &len)) { ctx.result.set_undefined(); return; }
    for (uint k = 0; k < len; k++) {
        if (arr_has_prop(o, k, ctx.heap)) {
            TVal v;
            if (arr_get_elem_vm(o, k, ctx.heap, ctx.vm, &v)) {
                TVal test = arr_call_callback(ctx, callback, thisArg, v, k, o);
                if (ctx.should_throw) { ctx.result.set_undefined(); return; }
                if (builtin_to_boolean(&test)) {
                    ctx.result.set_boolean(true);
                    return;
                }
            }
        }
    }
    ctx.result.set_boolean(false);
}

/// Array.prototype.reduce(callbackfn[, initialValue]) — ES5 §15.4.4.21
fn void builtin_array_proto_reduce(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    HObject*? o_raw = arr_to_object(this_val, ctx.heap);
    if (catch err = o_raw) {
        arr_throw_type_error(ctx, "Cannot convert undefined or null to object");
        return;
    }
    HObject* o = o_raw;
    if (ctx.argc < 1 || !arr_check_callback(ctx.regs[ctx.base_reg], ctx)) {
        return;
    }
    TVal callback = ctx.regs[ctx.base_reg];
    uint len;
    if (!array_to_length(o, ctx.heap, ctx, &len)) { ctx.result.set_undefined(); return; }
    uint k = 0;
    TVal acc;
    bool has_acc;
    if (ctx.argc > 1) {
        acc = ctx.regs[ctx.base_reg + 1];
        has_acc = true;
    } else {
        has_acc = false;
        while (k < len && !arr_has_prop(o, k, ctx.heap)) { k++; }
        if (k >= len) {
            arr_throw_type_error(ctx, "Reduce of empty array with no initial value");
            return;
        }
        arr_get_elem_vm(o, k, ctx.heap, ctx.vm, &acc);
        has_acc = true;
        k++;
    }
    while (k < len) {
        if (arr_has_prop(o, k, ctx.heap)) {
            TVal v;
            if (arr_get_elem_vm(o, k, ctx.heap, ctx.vm, &v)) {
                TVal[4] args;
                args[0] = acc;
                args[1] = v;
                TVal k_tv; k_tv.set_fastint((long)k);
                args[2] = k_tv;
                args[3].set_object((void*)o);
                acc = ctx.heap.call_fn(ctx.vm, callback, &args[0], 4, acc);
                if (ctx.heap.has_error) {
                    ctx.should_throw = true;
                    ctx.throw_value = ctx.heap.error_value;
                    ctx.heap.has_error = false;
                    ctx.result.set_undefined();
                    return;
                }
            }
        }
        k++;
    }
    (*ctx.result) = acc;
}

/// Array.prototype.reduceRight(callbackfn[, initialValue]) — ES5 §15.4.4.22
fn void builtin_array_proto_reduceRight(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    HObject*? o_raw = arr_to_object(this_val, ctx.heap);
    if (catch err = o_raw) {
        arr_throw_type_error(ctx, "Cannot convert undefined or null to object");
        return;
    }
    HObject* o = o_raw;
    if (ctx.argc < 1 || !arr_check_callback(ctx.regs[ctx.base_reg], ctx)) {
        return;
    }
    TVal callback = ctx.regs[ctx.base_reg];
    uint len;
    if (!array_to_length(o, ctx.heap, ctx, &len)) { ctx.result.set_undefined(); return; }
    if (len == 0 && ctx.argc < 2) {
        arr_throw_type_error(ctx, "Reduce of empty array with no initial value");
        return;
    }
    int k = (len > 0) ? (int)len - 1 : 0;
    TVal acc;
    bool has_acc;
    if (ctx.argc > 1) {
        acc = ctx.regs[ctx.base_reg + 1];
        has_acc = true;
    } else {
        has_acc = false;
        while (k >= 0 && !arr_has_prop(o, (uint)k, ctx.heap)) { k--; }
        if (k < 0) {
            arr_throw_type_error(ctx, "Reduce of empty array with no initial value");
            return;
        }
        arr_get_elem_vm(o, (uint)k, ctx.heap, ctx.vm, &acc);
        has_acc = true;
        k--;
    }
    while (k >= 0) {
        if (arr_has_prop(o, (uint)k, ctx.heap)) {
            TVal v;
            if (arr_get_elem_vm(o, (uint)k, ctx.heap, ctx.vm, &v)) {
                TVal[4] args;
                args[0] = acc;
                args[1] = v;
                TVal k_tv; k_tv.set_fastint((long)k);
                args[2] = k_tv;
                args[3].set_object((void*)o);
                acc = ctx.heap.call_fn(ctx.vm, callback, &args[0], 4, acc);
                if (ctx.heap.has_error) {
                    ctx.should_throw = true;
                    ctx.throw_value = ctx.heap.error_value;
                    ctx.heap.has_error = false;
                    ctx.result.set_undefined();
                    return;
                }
            }
        }
        k--;
    }
    (*ctx.result) = acc;
}

fn bool register_array_constructor(EnvRecord* global_env, Heap* heap) {
    // Create Array.prototype
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;  // Will be Object.prototype in later phases
    heap.array_proto = proto;

    // Create Array constructor as a proper HObject (not LIGHTFUNC)
    // so it can carry static methods like Array.isArray
    HObject*? arr_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = arr_raw) return false;
    HObject* arr = arr_raw;
    (*arr.extra_ptr()).func.builtin_fn_index = (int)BUILTIN_ARRAY;

    // Set .constructor on Array.prototype to point to the actual Array constructor object
    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(arr);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);

    // Set Array.prototype on the constructor (non-writable, non-enumerable, non-configurable)
    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    arr.put_prop(prototype_key, proto_tv, proto_pflags);

    // Register Array.prototype methods
    if (!register_array_proto_method(proto, heap, "toString",  BUILTIN_ARRAY_PROTO_TOSTRING))  return false;
    if (!register_array_proto_method(proto, heap, "join",      BUILTIN_ARRAY_PROTO_JOIN))      return false;
    if (!register_array_proto_method(proto, heap, "pop",       BUILTIN_ARRAY_PROTO_POP))       return false;
    if (!register_array_proto_method(proto, heap, "push",      BUILTIN_ARRAY_PROTO_PUSH))      return false;
    if (!register_array_proto_method(proto, heap, "reverse",   BUILTIN_ARRAY_PROTO_REVERSE))   return false;
    if (!register_array_proto_method(proto, heap, "shift",     BUILTIN_ARRAY_PROTO_SHIFT))     return false;
    if (!register_array_proto_method(proto, heap, "slice",     BUILTIN_ARRAY_PROTO_SLICE))     return false;
    if (!register_array_proto_method(proto, heap, "sort",      BUILTIN_ARRAY_PROTO_SORT))      return false;
    if (!register_array_proto_method(proto, heap, "splice",    BUILTIN_ARRAY_PROTO_SPLICE))    return false;
    if (!register_array_proto_method(proto, heap, "unshift",   BUILTIN_ARRAY_PROTO_UNSHIFT))   return false;
    if (!register_array_proto_method(proto, heap, "indexOf",   BUILTIN_ARRAY_PROTO_INDEXOF))   return false;
    if (!register_array_proto_method(proto, heap, "lastIndexOf", BUILTIN_ARRAY_PROTO_LASTINDEXOF)) return false;
    if (!register_array_proto_method(proto, heap, "concat",    BUILTIN_ARRAY_PROTO_CONCAT))    return false;
    if (!register_array_proto_method(proto, heap, "fill",      BUILTIN_ARRAY_PROTO_FILL))      return false;
    if (!register_array_proto_method(proto, heap, "includes",  BUILTIN_ARRAY_PROTO_INCLUDES))  return false;
    if (!register_array_proto_method(proto, heap, "at",        BUILTIN_ARRAY_PROTO_AT))        return false;
    if (!register_array_proto_method(proto, heap, "copyWithin", BUILTIN_ARRAY_PROTO_COPYWITHIN)) return false;
    if (!register_array_proto_method(proto, heap, "find",       BUILTIN_ARRAY_PROTO_FIND))       return false;
    if (!register_array_proto_method(proto, heap, "findIndex",  BUILTIN_ARRAY_PROTO_FINDINDEX))  return false;
    if (!register_array_proto_method(proto, heap, "findLast",      BUILTIN_ARRAY_PROTO_FINDLAST))      return false;
    if (!register_array_proto_method(proto, heap, "findLastIndex", BUILTIN_ARRAY_PROTO_FINDLASTINDEX)) return false;
    if (!register_array_proto_method(proto, heap, "flat",      BUILTIN_ARRAY_PROTO_FLAT))      return false;
    if (!register_compiled_proto_method(proto, heap, global_env, "flatMap",
        "(callback,thisArg){var O=Object(this);var len=O.length;var A=[];var k=0;while(k<len){if(k in O){var mapped=callback.call(thisArg,O[k],k,O);if(Array.isArray(mapped)){var j=0;while(j<mapped.length){A.push(mapped[j]);j++}}else{A.push(mapped)}}k++}return A}", 1)) return false;
    if (!register_array_proto_method(proto, heap, "toReversed", BUILTIN_ARRAY_PROTO_TOREVERSED)) return false;
    if (!register_array_proto_method(proto, heap, "toSorted",  BUILTIN_ARRAY_PROTO_TOSORTED))  return false;
    if (!register_array_proto_method(proto, heap, "toSpliced", BUILTIN_ARRAY_PROTO_TOSPLICED)) return false;
    if (!register_array_proto_method(proto, heap, "with",      BUILTIN_ARRAY_PROTO_WITH))      return false;

// Array.prototype.keys/values/entries (ES2015 §22.1.3.x)
    if (!register_array_proto_method(proto, heap, "keys",      BUILTIN_ARRAY_PROTO_KEYS))      return false;
    if (!register_array_proto_method(proto, heap, "values",    BUILTIN_ARRAY_PROTO_VALUES))    return false;
    if (!register_array_proto_method(proto, heap, "entries",   BUILTIN_ARRAY_PROTO_ENTRIES))   return false;

    // Register callback-based Array.prototype methods as native builtins.
    // Uses heap.call_fn for proper this-binding via Function.prototype.call semantics.
    if (!register_array_proto_method(proto, heap, "forEach",   BUILTIN_ARRAY_PROTO_FOREACH))   return false;
    if (!register_array_proto_method(proto, heap, "map",        BUILTIN_ARRAY_PROTO_MAP))        return false;
    if (!register_array_proto_method(proto, heap, "filter",     BUILTIN_ARRAY_PROTO_FILTER))     return false;
    if (!register_array_proto_method(proto, heap, "every",      BUILTIN_ARRAY_PROTO_EVERY))      return false;
    if (!register_array_proto_method(proto, heap, "some",       BUILTIN_ARRAY_PROTO_SOME))       return false;
    if (!register_array_proto_method(proto, heap, "reduce",     BUILTIN_ARRAY_PROTO_REDUCE))     return false;
    if (!register_array_proto_method(proto, heap, "reduceRight",BUILTIN_ARRAY_PROTO_REDUCERIGHT)) return false;

    // Register Array.prototype[@@iterator] (ES6 §22.1.3.30)
    {
        HString* iter_sym = ensure_iterator_symbol(heap);
        if (iter_sym != null) {
            HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
            if (catch err = fn_raw) return false;
            HObject* fn_obj = fn_raw;
            (*fn_obj.extra_ptr()).func.builtin_fn_index = (int)BUILTIN_ARRAY_PROTO_SYMBOL_ITER;
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
    }

    // Add Array.isArray (ES6 §22.1.2.2) as static method on the constructor
    HString* isarray_key = builtin_intern_string(heap, "isArray");
    if (isarray_key == null) return false;
    TVal isarray_tv;
    isarray_tv.set_lightfunc((void*)(usz)BUILTIN_ARRAY_ISARRAY);
    arr.put_prop(isarray_key, isarray_tv, hobject::PROP_FLAGS_WC);

    // Add Array.of (ES6 §22.1.2.3) as static method on the constructor
    HString* of_key = builtin_intern_string(heap, "of");
    if (of_key == null) return false;
    TVal of_tv;
    of_tv.set_lightfunc((void*)(usz)BUILTIN_ARRAY_OF);
    arr.put_prop(of_key, of_tv, hobject::PROP_FLAGS_WC);

    // Add Array.from (ES6 §22.1.2.1) as static method on the constructor
    HString* from_key = builtin_intern_string(heap, "from");
    if (from_key == null) return false;
    TVal from_tv;
    from_tv.set_lightfunc((void*)(usz)BUILTIN_ARRAY_FROM);
    arr.put_prop(from_key, from_tv, hobject::PROP_FLAGS_WC);

    // Register Array constructor globally as an OBJECT (not LIGHTFUNC)
    uint hash = heap.hash_string("Array");
    HString* existing = heap.str_table_lookup("Array", hash);
    HString* arr_key;
    if (existing != null) {
        arr_key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, "Array", hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        arr_key = new_key;
    }
    TVal arr_val;
    arr_val.set_object(arr);
    set_func_ctor_name_length(arr, heap, "Array", 1);
    env::env_declare_nonenum(global_env, arr_key, arr_val);

    return true;
}

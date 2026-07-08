/// TypedArray constructors and element access (ES2015 §22.2) — Stage 2 of
/// plan 049. Buffer allocation reuses the ArrayBuffer primitives from
/// arraybuffer.c3; element read/write conversion lives in vm_property.c3.
module duktape::builtins;

import duktape::types;
import duktape::env;
import duktape::hstring;
import duktape::hobject;
import duktape::heap;
import duktape::vm;
import libc;
import std::math;

// ============================================================================
// Element size / shift tables — indexed by (cls - INT8ARRAY)
// ============================================================================

const char[9] TA_ELEM_SIZES  = { 1, 1, 1, 2, 2, 4, 4, 4, 8 };
const char[9] TA_ELEM_SHIFT  = { 0, 0, 0, 1, 1, 2, 2, 2, 3 };

fn uint ta_elem_size(hobject::ObjClass cls) {
    return TA_ELEM_SIZES[(int)cls - (int)hobject::ObjClass.INT8ARRAY];
}

fn uint ta_elem_shift(hobject::ObjClass cls) {
    return TA_ELEM_SHIFT[(int)cls - (int)hobject::ObjClass.INT8ARRAY];
}

fn char[] ta_class_name(hobject::ObjClass cls) {
    switch (cls) {
        case hobject::ObjClass.INT8ARRAY: return "Int8Array";
        case hobject::ObjClass.UINT8ARRAY: return "Uint8Array";
        case hobject::ObjClass.UINT8CLAMPEDARRAY: return "Uint8ClampedArray";
        case hobject::ObjClass.INT16ARRAY: return "Int16Array";
        case hobject::ObjClass.UINT16ARRAY: return "Uint16Array";
        case hobject::ObjClass.INT32ARRAY: return "Int32Array";
        case hobject::ObjClass.UINT32ARRAY: return "Uint32Array";
        case hobject::ObjClass.FLOAT32ARRAY: return "Float32Array";
        case hobject::ObjClass.FLOAT64ARRAY: return "Float64Array";
        default: return "";
    }
}

fn bool is_typed_array_class(hobject::ObjClass cls) {
    return cls >= hobject::ObjClass.INT8ARRAY && cls <= hobject::ObjClass.FLOAT64ARRAY;
}

/// ES2022 §7.1.21 CanonicalNumericIndexString — true iff `s` is "-0" or the
/// ToString of some number that round-trips back to the same text (e.g.
/// "1.5", "NaN", "Infinity"). Plain array-index integer strings ("0", "1",
/// ...) are handled separately via HString.is_arridx() and never reach here.
fn bool is_canonical_numeric_index(Heap* heap, HString* s, double* out) {
    char[] bytes = s.get_data();
    if (bytes.len == 2 && bytes[0] == '-' && bytes[1] == '0') {
        *out = -0.0;
        return true;
    }
    double d = vm::hstring_to_number(s);
    if (d != d) {
        // NaN parses only when the source text was literally "NaN".
        if (bytes.len == 3 && bytes[0] == 'N' && bytes[1] == 'a' && bytes[2] == 'N') {
            *out = d;
            return true;
        }
        return false;
    }
    HString* restr = builtin_number_to_hstring(heap, d);
    if (restr == null) return false;
    if (restr.blen != s.blen) return false;
    if (libc::memcmp(restr.get_cstr(), s.get_cstr(), s.blen) != 0) return false;
    *out = d;
    return true;
}

// ============================================================================
// Buffer allocation helper (shared with ArrayBuffer construction)
// ============================================================================

/// Allocate a fresh, zeroed ArrayBuffer object of `byte_length` bytes.
/// Returns null (without throwing) on allocation failure so the caller can
/// decide the exact error to raise.
fn HObject* typedarray_alloc_buffer(BuiltinContext* ctx, uint byte_length) {
    char* data = null;
    if (byte_length > 0) {
        data = (char*)ctx.heap.alloc_func(ctx.heap.heap_udata, (usz)byte_length);
        if (data == null) return null;
        libc::memset(data, 0, (usz)byte_length);
    }
    HObject*? raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAYBUFFER);
    if (catch err = raw) {
        if (data != null) ctx.heap.free_func(ctx.heap.heap_udata, data);
        return null;
    }
    HObject* buf = raw;
    buf.prototype = ctx.heap.arraybuffer_proto;
    (*buf.extra_ptr()).ab.data = data;
    (*buf.extra_ptr()).ab.byte_length = byte_length;
    (*buf.extra_ptr()).ab.views_head = null;
    return buf;
}

/// Link a freshly created view object into its buffer's views_head chain.
fn void typedarray_link_view(HObject* buf, HObject* view) {
    (*view.extra_ptr()).view.buffer = buf;
    (*view.extra_ptr()).view.next_view = (*buf.extra_ptr()).ab.views_head;
    (*buf.extra_ptr()).ab.views_head = view;
}

/// Resolve the constructor's `.prototype` (falling back to the shared
/// %TypedArray%.prototype-derived per-class prototype) for `new.target`-style
/// prototype inheritance.
fn HObject* typedarray_instance_proto(BuiltinContext* ctx, HObject* fallback_proto) {
    HObject* instance_proto = fallback_proto;
    if (ctx.callee_obj != null) {
        HString* prototype_key = (HString*)ctx.heap.strs[heap::BuiltinStr.PROTOTYPE];
        TVal? proto_tv = ctx.callee_obj.get_prop(prototype_key);
        if (try ptv = proto_tv) {
            if (ptv.is_object()) {
                HObject* cp = (HObject*)ptv.get_heapptr();
                if (cp != null) instance_proto = cp;
            }
        }
    }
    return instance_proto;
}

/// Store one converted element into `buf`'s backing store at element index
/// `idx` for typed array class `cls`. Assumes bounds have already been
/// validated (used during construction, where the buffer freshly allocated
/// is always large enough).
fn void typedarray_store_converted(HObject* buf, uint byte_offset, hobject::ObjClass cls, uint idx, TVal* val, BuiltinContext* ctx) {
    char* base = (*buf.extra_ptr()).ab.data;
    if (base == null) return;
    uint shift = ta_elem_shift(cls);
    char* p = base + byte_offset + (idx << shift);
    ta_write_element(p, cls, val, ctx);
}

// ============================================================================
// Byte-level element load/store — shared by construction and the VM
// GETPROP/PUTPROP fast paths (vm_property.c3).
// ============================================================================

/// Load one element at byte pointer `p` (already offset into the backing
/// store) for typed array class `cls`, converting to a TVal per §22.2 read
/// rules (small int kinds -> fastint, wide/float kinds -> number).
fn TVal ta_load_element(char* p, hobject::ObjClass cls, uint idx) {
    TVal out;
    uint shift = ta_elem_shift(cls);
    char* ep = p + (idx << shift);
    switch (cls) {
        case hobject::ObjClass.INT8ARRAY: {
            ichar v = *(ichar*)ep;
            out.set_fastint((long)v);
            break;
        }
        case hobject::ObjClass.UINT8ARRAY:
        case hobject::ObjClass.UINT8CLAMPEDARRAY: {
            char v = *(char*)ep;
            out.set_fastint((long)v);
            break;
        }
        case hobject::ObjClass.INT16ARRAY: {
            short v;
            libc::memcpy(&v, ep, 2);
            out.set_fastint((long)v);
            break;
        }
        case hobject::ObjClass.UINT16ARRAY: {
            ushort v;
            libc::memcpy(&v, ep, 2);
            out.set_fastint((long)v);
            break;
        }
        case hobject::ObjClass.INT32ARRAY: {
            int v;
            libc::memcpy(&v, ep, 4);
            out.set_fastint((long)v);
            break;
        }
        case hobject::ObjClass.UINT32ARRAY: {
            uint v;
            libc::memcpy(&v, ep, 4);
            if (v < 2147483648u) {
                out.set_fastint((long)v);
            } else {
                out.set_number((double)v);
            }
            break;
        }
        case hobject::ObjClass.FLOAT32ARRAY: {
            float v;
            libc::memcpy(&v, ep, 4);
            out.set_number((double)v);
            break;
        }
        case hobject::ObjClass.FLOAT64ARRAY: {
            double v;
            libc::memcpy(&v, ep, 8);
            out.set_number(v);
            break;
        }
        default:
            out.set_undefined();
            break;
    }
    return out;
}

/// ES2022 §7.1.11 ToUint8Clamp — NaN -> 0, clamp to [0,255], banker's
/// rounding (round half to even) on ties. Matches QuickJS JS_ToUint8ClampFree.
fn char ta_to_uint8_clamped(double d) {
    if (d != d) return 0; // NaN
    if (d <= 0.0) return 0;
    if (d >= 255.0) return 255;
    double fl = (double)(long)d;
    double diff = d - fl;
    if (diff < 0.5) return (char)(long)fl;
    if (diff > 0.5) return (char)((long)fl + 1);
    // Exactly .5 — round to even.
    long fli = (long)fl;
    if (fli % 2 == 0) return (char)fli;
    return (char)(fli + 1);
}

/// Convert `val` (already-available TVal) to a JS double per ToNumber,
/// using the VM when the value is an object. Used for element writes.
fn double ta_val_to_number(TVal* val, BuiltinContext* ctx) {
    if (val.is_fastint()) return (double)val.get_fastint();
    if (val.is_number()) return val.get_number();
    return builtin_to_number_vm(ctx, val);
}

/// Write one converted element at byte pointer `p` for class `cls`. Performs
/// the ToNumber/ToInt32/ToUint32/clamp conversion first (per spec, this may
/// run user code that detaches the buffer); the caller is responsible for
/// bounds/detach checking AFTER conversion and for skipping the store if so.
fn void ta_write_element(char* p, hobject::ObjClass cls, TVal* val, BuiltinContext* ctx) {
    switch (cls) {
        case hobject::ObjClass.INT8ARRAY:
        case hobject::ObjClass.UINT8ARRAY: {
            double d = ta_val_to_number(val, ctx);
            if (ctx.should_throw) return;
            long iv = double_to_int32(d);
            char b = (char)(iv & 0xFF);
            *(char*)p = b;
            break;
        }
        case hobject::ObjClass.UINT8CLAMPEDARRAY: {
            double d = ta_val_to_number(val, ctx);
            if (ctx.should_throw) return;
            *(char*)p = ta_to_uint8_clamped(d);
            break;
        }
        case hobject::ObjClass.INT16ARRAY:
        case hobject::ObjClass.UINT16ARRAY: {
            double d = ta_val_to_number(val, ctx);
            if (ctx.should_throw) return;
            long iv = double_to_int32(d);
            short sv = (short)(iv & 0xFFFF);
            libc::memcpy(p, &sv, 2);
            break;
        }
        case hobject::ObjClass.INT32ARRAY:
        case hobject::ObjClass.UINT32ARRAY: {
            double d = ta_val_to_number(val, ctx);
            if (ctx.should_throw) return;
            long iv = double_to_int32(d);
            int v32 = (int)iv;
            libc::memcpy(p, &v32, 4);
            break;
        }
        case hobject::ObjClass.FLOAT32ARRAY: {
            double d = ta_val_to_number(val, ctx);
            if (ctx.should_throw) return;
            float f = (float)d;
            libc::memcpy(p, &f, 4);
            break;
        }
        case hobject::ObjClass.FLOAT64ARRAY: {
            double d = ta_val_to_number(val, ctx);
            if (ctx.should_throw) return;
            libc::memcpy(p, &d, 8);
            break;
        }
        default:
            break;
    }
}

/// ES2022 §7.1.6 ToInt32 core, applied to an already-computed double.
/// NaN/Infinity -> 0; otherwise truncate toward zero mod 2^32, reinterpreted
/// as signed 32-bit (sign bit set -> negative).
fn long double_to_int32(double d) {
    if (d != d) return 0; // NaN
    if (d == 1.0 / 0.0 || d == -1.0 / 0.0) return 0;
    double trunc = d < 0.0 ? -math::floor(-d) : math::floor(d);
    double m = trunc - math::floor(trunc / 4294967296.0) * 4294967296.0;
    if (m < 0) m += 4294967296.0;
    uint u = (uint)(ulong)m;
    return (long)(int)u;
}

// ============================================================================
// Shared constructor — dispatch on argv[0]
// ============================================================================

fn void typed_array_construct(BuiltinContext* ctx, hobject::ObjClass obj_class) {
    if (!ctx.is_constructor) {
        arraybuffer_throw_type_error(ctx, "Constructor TypedArray requires 'new'");
        return;
    }

    Heap* heap = ctx.heap;
    uint elem_size = ta_elem_size(obj_class);
    uint shift = ta_elem_shift(obj_class);

    HObject* instance_proto = typedarray_instance_proto(ctx, heap.typedarray_proto);

    TVal arg0; arg0.set_undefined();
    if (ctx.argc >= 1) arg0 = ctx.regs[ctx.base_reg];

    HObject* buf = null;
    uint byte_offset = 0;
    uint byte_length = 0;

    if (ctx.argc == 0 || !arg0.is_object()) {
        // --- Overload 1: no args / number-like ---
        uint len = 0;
        if (!arraybuffer_to_index(ctx, &arg0, &len)) return;
        uint total_bytes = len * elem_size;
        buf = typedarray_alloc_buffer(ctx, total_bytes);
        if (buf == null) {
            arraybuffer_throw_range_error(ctx, "Out of memory allocating TypedArray");
            return;
        }
        byte_offset = 0;
        byte_length = total_bytes;
    } else {
        HObject* arg_obj = (HObject*)arg0.get_heapptr();

        if (arg_obj != null && is_arraybuffer_obj(arg_obj)) {
            // --- Overload 5: ArrayBuffer shared view ---
            TVal off_arg; off_arg.set_undefined();
            if (ctx.argc >= 2) off_arg = ctx.regs[ctx.base_reg + 1];
            uint off = 0;
            if (!off_arg.is_undefined()) {
                if (!arraybuffer_to_index(ctx, &off_arg, &off)) return;
            }
            if (off % elem_size != 0) {
                arraybuffer_throw_range_error(ctx, "start offset must be a multiple of the element size");
                return;
            }
            uint buf_len = (*arg_obj.extra_ptr()).ab.byte_length;
            if ((*arg_obj.extra_ptr()).ab.data == null) {
                arraybuffer_throw_type_error(ctx, "Cannot construct TypedArray on a detached ArrayBuffer");
                return;
            }
            if (off > buf_len) {
                arraybuffer_throw_range_error(ctx, "start offset out of bounds");
                return;
            }

            TVal len_arg; len_arg.set_undefined();
            if (ctx.argc >= 3) len_arg = ctx.regs[ctx.base_reg + 2];

            uint view_len_bytes;
            if (len_arg.is_undefined()) {
                uint remainder = buf_len - off;
                if (remainder % elem_size != 0) {
                    arraybuffer_throw_range_error(ctx, "buffer length minus byteOffset must be a multiple of the element size");
                    return;
                }
                view_len_bytes = remainder;
            } else {
                uint n = 0;
                if (!arraybuffer_to_index(ctx, &len_arg, &n)) return;
                view_len_bytes = n * elem_size;
                if (off + view_len_bytes > buf_len) {
                    arraybuffer_throw_range_error(ctx, "length out of bounds");
                    return;
                }
            }

            HObject*? raw = heap.alloc_object(obj_class);
            if (catch err = raw) { ctx.result.set_undefined(); return; }
            HObject* obj = raw;
            obj.prototype = instance_proto;
            (*obj.extra_ptr()).view.byte_offset = off;
            (*obj.extra_ptr()).view.byte_length = view_len_bytes;
            typedarray_link_view(arg_obj, obj);
            ctx.result.set_object(obj);
            return;
        }

        if (arg_obj != null && is_typed_array_class(arg_obj.flags.obj_class)) {
            // --- Overload 4: from another TypedArray ---
            hobject::ObjClass src_cls = arg_obj.flags.obj_class;
            HObject* src_buf = (*arg_obj.extra_ptr()).view.buffer;
            if (src_buf == null || (*src_buf.extra_ptr()).ab.data == null) {
                // Detached source: treat as zero-length.
                buf = typedarray_alloc_buffer(ctx, 0);
                if (buf == null) { ctx.result.set_undefined(); return; }
                byte_offset = 0;
                byte_length = 0;
            } else {
                uint src_shift = ta_elem_shift(src_cls);
                uint count = (*arg_obj.extra_ptr()).view.byte_length >> src_shift;
                uint total_bytes = count * elem_size;
                buf = typedarray_alloc_buffer(ctx, total_bytes);
                if (buf == null) {
                    arraybuffer_throw_range_error(ctx, "Out of memory allocating TypedArray");
                    return;
                }
                byte_offset = 0;
                byte_length = total_bytes;

                char* src_base = (*src_buf.extra_ptr()).ab.data + (*arg_obj.extra_ptr()).view.byte_offset;
                if (src_cls == obj_class) {
                    if (total_bytes > 0) libc::memcpy((*buf.extra_ptr()).ab.data, src_base, (usz)total_bytes);
                } else {
                    for (uint i = 0; i < count; i++) {
                        TVal v = ta_load_element(src_base, src_cls, i);
                        typedarray_store_converted(buf, 0, obj_class, i, &v, ctx);
                        if (ctx.should_throw) return;
                    }
                }
            }
        } else {
            // --- Overload 2/3: iterable or array-like object ---
            HString* iter_sym = ensure_iterator_symbol(heap);
            TVal iter_method; iter_method.set_undefined();
            bool has_iter = false;
            if (iter_sym != null && arg_obj != null) {
                TVal? im = arg_obj.get_prop_proto(iter_sym);
                if (try v = im) {
                    if (!v.is_undefined() && !v.is_null()) {
                        iter_method = v;
                        has_iter = true;
                    }
                }
            }

            if (has_iter) {
                // Collect into a growing TVal buffer via the iterator protocol.
                bool callable = false;
                if (iter_method.is_lightfunc()) {
                    callable = true;
                } else if (iter_method.is_object() && iter_method.get_heapptr() != null) {
                    callable = ((HObject*)iter_method.get_heapptr()).is_callable();
                }
                if (!callable || heap.call_fn == null || ctx.vm == null) {
                    arraybuffer_throw_type_error(ctx, "TypedArray source is not iterable");
                    return;
                }
                TVal iterator = heap.call_fn(ctx.vm, iter_method, null, 0, arg0);
                if (ctx.heap.has_error) { ctx.should_throw = true; ctx.heap.has_error = false; return; }

                uint cap = 4;
                TVal* items = (TVal*)heap.alloc_func(heap.heap_udata, (usz)cap * TVal::size);
                if (items == null) { ctx.result.set_undefined(); return; }
                uint count = 0;

                HString* next_key = builtin_intern_string(heap, "next");
                HString* done_key = builtin_intern_string(heap, "done");
                HString* value_key = builtin_intern_string(heap, "value");

                while (true) {
                    if (!iterator.is_object() || iterator.get_heapptr() == null) break;
                    HObject* iter_obj = (HObject*)iterator.get_heapptr();
                    TVal? next_method_opt = iter_obj.get_prop_proto(next_key);
                    TVal next_method;
                    if (try nm = next_method_opt) { next_method = nm; } else { break; }
                    bool next_callable = false;
                    if (next_method.is_lightfunc()) {
                        next_callable = true;
                    } else if (next_method.is_object() && next_method.get_heapptr() != null) {
                        next_callable = ((HObject*)next_method.get_heapptr()).is_callable();
                    }
                    if (!next_callable) break;

                    TVal result = heap.call_fn(ctx.vm, next_method, null, 0, iterator);
                    if (ctx.heap.has_error) {
                        heap.free_func(heap.heap_udata, items);
                        ctx.should_throw = true; ctx.heap.has_error = false; return;
                    }
                    if (!result.is_object() || result.get_heapptr() == null) break;
                    HObject* result_obj = (HObject*)result.get_heapptr();

                    TVal? done_opt = result_obj.get_prop_proto(done_key);
                    bool done = false;
                    if (try dv = done_opt) done = builtin_to_boolean(&dv);
                    if (done) break;

                    TVal? value_opt = result_obj.get_prop_proto(value_key);
                    TVal next_value; next_value.set_undefined();
                    if (try vv = value_opt) next_value = vv;

                    if (count == cap) {
                        uint new_cap = cap * 2;
                        TVal* new_items = (TVal*)heap.alloc_func(heap.heap_udata, (usz)new_cap * TVal::size);
                        if (new_items == null) { heap.free_func(heap.heap_udata, items); ctx.result.set_undefined(); return; }
                        libc::memcpy(new_items, items, (usz)count * TVal::size);
                        heap.free_func(heap.heap_udata, items);
                        items = new_items;
                        cap = new_cap;
                    }
                    items[count] = next_value;
                    count++;
                }

                uint total_bytes = count * elem_size;
                buf = typedarray_alloc_buffer(ctx, total_bytes);
                if (buf == null) {
                    heap.free_func(heap.heap_udata, items);
                    arraybuffer_throw_range_error(ctx, "Out of memory allocating TypedArray");
                    return;
                }
                byte_offset = 0;
                byte_length = total_bytes;
                for (uint i = 0; i < count; i++) {
                    typedarray_store_converted(buf, 0, obj_class, i, &items[i], ctx);
                    if (ctx.should_throw) { heap.free_func(heap.heap_udata, items); return; }
                }
                heap.free_func(heap.heap_udata, items);
            } else {
                // Array-like: read .length then Get(o, i) for i in [0, length).
                HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
                TVal len_tv; len_tv.set_fastint(0);
                if (arg_obj != null) {
                    TVal? lv = builtins_generic_get(arg_obj, length_key, ctx);
                    if (ctx.should_throw) return;
                    if (try v = lv) len_tv = v;
                }
                double len_d = builtin_to_integer_vm(ctx, &len_tv);
                if (ctx.should_throw) return;
                if (len_d < 0.0) len_d = 0.0;
                uint count = (uint)len_d;

                uint total_bytes = count * elem_size;
                buf = typedarray_alloc_buffer(ctx, total_bytes);
                if (buf == null) {
                    arraybuffer_throw_range_error(ctx, "Out of memory allocating TypedArray");
                    return;
                }
                byte_offset = 0;
                byte_length = total_bytes;

                for (uint i = 0; i < count; i++) {
                    HString* idx_key = heap.int_to_hstring((long)i);
                    TVal elem; elem.set_undefined();
                    if (idx_key != null && arg_obj != null) {
                        TVal? ev = builtins_generic_get(arg_obj, idx_key, ctx);
                        if (ctx.should_throw) return;
                        if (try v = ev) elem = v;
                    }
                    typedarray_store_converted(buf, 0, obj_class, i, &elem, ctx);
                    if (ctx.should_throw) return;
                }
            }
        }
    }

    HObject*? raw = heap.alloc_object(obj_class);
    if (catch err = raw) { ctx.result.set_undefined(); return; }
    HObject* obj = raw;
    obj.prototype = instance_proto;
    (*obj.extra_ptr()).view.byte_offset = byte_offset;
    (*obj.extra_ptr()).view.byte_length = byte_length;
    typedarray_link_view(buf, obj);
    ctx.result.set_object(obj);
}

// ============================================================================
// Per-type constructors
// ============================================================================

fn void builtin_int8array(BuiltinContext* ctx) {
    typed_array_construct(ctx, hobject::ObjClass.INT8ARRAY);
}

fn void builtin_uint8array(BuiltinContext* ctx) {
    typed_array_construct(ctx, hobject::ObjClass.UINT8ARRAY);
}

fn void builtin_uint8clampedarray(BuiltinContext* ctx) {
    typed_array_construct(ctx, hobject::ObjClass.UINT8CLAMPEDARRAY);
}

fn void builtin_int16array(BuiltinContext* ctx) {
    typed_array_construct(ctx, hobject::ObjClass.INT16ARRAY);
}

fn void builtin_uint16array(BuiltinContext* ctx) {
    typed_array_construct(ctx, hobject::ObjClass.UINT16ARRAY);
}

fn void builtin_int32array(BuiltinContext* ctx) {
    typed_array_construct(ctx, hobject::ObjClass.INT32ARRAY);
}

fn void builtin_uint32array(BuiltinContext* ctx) {
    typed_array_construct(ctx, hobject::ObjClass.UINT32ARRAY);
}

fn void builtin_float32array(BuiltinContext* ctx) {
    typed_array_construct(ctx, hobject::ObjClass.FLOAT32ARRAY);
}

fn void builtin_float64array(BuiltinContext* ctx) {
    typed_array_construct(ctx, hobject::ObjClass.FLOAT64ARRAY);
}

// ============================================================================
// %TypedArray%.prototype accessors — length / byteLength / byteOffset / buffer
// ============================================================================

/// Resolve `ctx.this_val` as a TypedArray instance, or return null.
fn HObject* ta_this_receiver(BuiltinContext* ctx) {
    if (!ctx.this_val.is_object() || ctx.this_val.get_heapptr() == null) return null;
    HObject* obj = (HObject*)ctx.this_val.get_heapptr();
    if (!is_typed_array_class(obj.flags.obj_class)) return null;
    return obj;
}

fn void builtin_typedarray_proto_length_get(BuiltinContext* ctx) {
    HObject* obj = ta_this_receiver(ctx);
    if (obj == null) {
        arraybuffer_throw_type_error(ctx, "TypedArray.prototype.length called on incompatible receiver");
        return;
    }
    HObject* buf = (*obj.extra_ptr()).view.buffer;
    if (buf == null || (*buf.extra_ptr()).ab.data == null) {
        ctx.result.set_fastint(0);
        return;
    }
    uint shift = ta_elem_shift(obj.flags.obj_class);
    ctx.result.set_fastint((long)((*obj.extra_ptr()).view.byte_length >> shift));
}

fn void builtin_typedarray_proto_bytelength_get(BuiltinContext* ctx) {
    HObject* obj = ta_this_receiver(ctx);
    if (obj == null) {
        arraybuffer_throw_type_error(ctx, "TypedArray.prototype.byteLength called on incompatible receiver");
        return;
    }
    HObject* buf = (*obj.extra_ptr()).view.buffer;
    if (buf == null || (*buf.extra_ptr()).ab.data == null) {
        ctx.result.set_fastint(0);
        return;
    }
    ctx.result.set_fastint((long)(*obj.extra_ptr()).view.byte_length);
}

fn void builtin_typedarray_proto_byteoffset_get(BuiltinContext* ctx) {
    HObject* obj = ta_this_receiver(ctx);
    if (obj == null) {
        arraybuffer_throw_type_error(ctx, "TypedArray.prototype.byteOffset called on incompatible receiver");
        return;
    }
    HObject* buf = (*obj.extra_ptr()).view.buffer;
    if (buf == null || (*buf.extra_ptr()).ab.data == null) {
        ctx.result.set_fastint(0);
        return;
    }
    ctx.result.set_fastint((long)(*obj.extra_ptr()).view.byte_offset);
}

fn void builtin_typedarray_proto_buffer_get(BuiltinContext* ctx) {
    HObject* obj = ta_this_receiver(ctx);
    if (obj == null) {
        arraybuffer_throw_type_error(ctx, "TypedArray.prototype.buffer called on incompatible receiver");
        return;
    }
    HObject* buf = (*obj.extra_ptr()).view.buffer;
    if (buf == null) {
        ctx.result.set_undefined();
        return;
    }
    ctx.result.set_object(buf);
}

/// [Symbol.toStringTag] getter — returns the class name for TA receivers,
/// undefined otherwise (per spec, this getter never throws).
fn void builtin_typedarray_proto_tostringtag_get(BuiltinContext* ctx) {
    HObject* obj = ta_this_receiver(ctx);
    if (obj == null) {
        ctx.result.set_undefined();
        return;
    }
    HString* name = builtin_intern_string(ctx.heap, ta_class_name(obj.flags.obj_class));
    if (name == null) {
        ctx.result.set_undefined();
        return;
    }
    ctx.result.set_string(name);
}

// ============================================================================
// Wave A: %TypedArray%.prototype methods (plan 049 stage 4)
// ============================================================================

/// Validate that ctx.this_val is a live (non-detached) TypedArray.
/// Returns the object on success, null + sets should_throw on failure.
fn HObject* ta_validate(BuiltinContext* ctx) {
    HObject* obj = ta_this_receiver(ctx);
    if (obj == null) {
        arraybuffer_throw_type_error(ctx, "TypedArray method called on incompatible receiver");
        return null;
    }
    HObject* buf = (*obj.extra_ptr()).view.buffer;
    if (buf == null || (*buf.extra_ptr()).ab.data == null) {
        arraybuffer_throw_type_error(ctx, "Typed array buffer is detached");
        return null;
    }
    return obj;
}

/// Check detach status without throwing — inline guard after user-code calls.
fn bool ta_is_detached(HObject* obj) {
    HObject* buf = (*obj.extra_ptr()).view.buffer;
    return buf == null || (*buf.extra_ptr()).ab.data == null;
}

/// Normalize a relative index (ES2022 §23.2.4.1 ToIntegerOrInfinity + clamp).
fn uint ta_norm_index(double d, uint len) {
    if (d != d || d == 0.0) return 0;
    if (d < 0.0) {
        double v = (double)len + d;
        return v < 0.0 ? 0u : (uint)(long)v;
    }
    if (d >= (double)len) return len;
    return (uint)(long)d;
}

// ---- Iterator forwarders ----

/// %TypedArray%.prototype.values() — §23.2.3.32. Returns array iterator kind=0.
fn void builtin_ta_proto_values(BuiltinContext* ctx) {
    HObject* obj = ta_validate(ctx);
    if (obj == null) return;
    create_array_iterator(ctx, 0);
}

/// %TypedArray%.prototype.keys() — §23.2.3.16. Returns array iterator kind=1.
fn void builtin_ta_proto_keys(BuiltinContext* ctx) {
    HObject* obj = ta_validate(ctx);
    if (obj == null) return;
    create_array_iterator(ctx, 1);
}

/// %TypedArray%.prototype.entries() — §23.2.3.6. Returns array iterator kind=2.
fn void builtin_ta_proto_entries(BuiltinContext* ctx) {
    HObject* obj = ta_validate(ctx);
    if (obj == null) return;
    create_array_iterator(ctx, 2);
}

/// %TypedArray%.prototype[@@iterator] — alias for values().
fn void builtin_ta_proto_symbol_iterator(BuiltinContext* ctx) {
    HObject* obj = ta_validate(ctx);
    if (obj == null) return;
    create_array_iterator(ctx, 0);
}

// ---- set ----

/// %TypedArray%.prototype.set(source [, offset]) — §23.2.3.24.
fn void builtin_ta_proto_set(BuiltinContext* ctx) {
    HObject* dst = ta_validate(ctx);
    if (dst == null) return;
    Heap* heap = ctx.heap;

    hobject::ObjClass dst_cls = dst.flags.obj_class;
    uint dst_shift = ta_elem_shift(dst_cls);
    HObject* dst_buf = (*dst.extra_ptr()).view.buffer;
    uint dst_byte_off = (*dst.extra_ptr()).view.byte_offset;
    uint dst_len = (*dst.extra_ptr()).view.byte_length >> dst_shift;

    // Resolve offset argument
    TVal offset_arg; offset_arg.set_undefined();
    if (ctx.argc >= 2) offset_arg = ctx.regs[ctx.base_reg + 1];
    double off_d = builtin_to_integer_vm(ctx, &offset_arg);
    if (ctx.should_throw) return;
    if (off_d < 0.0) {
        arraybuffer_throw_range_error(ctx, "TypedArray.set: offset is negative");
        return;
    }
    uint target_offset = (uint)(long)off_d;

    TVal source_arg; source_arg.set_undefined();
    if (ctx.argc >= 1) source_arg = ctx.regs[ctx.base_reg];

    if (source_arg.is_object() && source_arg.get_heapptr() != null) {
        HObject* src_obj = (HObject*)source_arg.get_heapptr();

        if (is_typed_array_class(src_obj.flags.obj_class)) {
            // TypedArray source path
            hobject::ObjClass src_cls = src_obj.flags.obj_class;
            HObject* src_buf = (*src_obj.extra_ptr()).view.buffer;
            if (src_buf == null || (*src_buf.extra_ptr()).ab.data == null) {
                arraybuffer_throw_type_error(ctx, "TypedArray.set: source buffer is detached");
                return;
            }
            uint src_shift = ta_elem_shift(src_cls);
            uint src_len = (*src_obj.extra_ptr()).view.byte_length >> src_shift;
            uint src_byte_off = (*src_obj.extra_ptr()).view.byte_offset;

            if (src_len + target_offset > dst_len) {
                arraybuffer_throw_range_error(ctx, "TypedArray.set: source is too large");
                return;
            }

            char* src_data = (*src_buf.extra_ptr()).ab.data + src_byte_off;
            char* dst_data = (*dst_buf.extra_ptr()).ab.data + dst_byte_off + (target_offset << dst_shift);

            if (src_cls == dst_cls) {
                // Same element type: memmove handles overlap (same buffer).
                uint byte_count = src_len << dst_shift;
                if (byte_count > 0) libc::memmove(dst_data, src_data, (usz)byte_count);
            } else if (src_buf == dst_buf) {
                // Cross-class, same buffer: copy elements via temporary scratch.
                uint scratch_bytes = src_len * TVal::size;
                TVal* scratch = (TVal*)heap.alloc_func(heap.heap_udata, (usz)scratch_bytes);
                if (scratch == null) {
                    arraybuffer_throw_range_error(ctx, "TypedArray.set: out of memory");
                    return;
                }
                for (uint i = 0; i < src_len; i++) {
                    scratch[i] = ta_load_element(src_data, src_cls, i);
                }
                for (uint i = 0; i < src_len; i++) {
                    char* dp = (*dst_buf.extra_ptr()).ab.data + dst_byte_off + ((target_offset + i) << dst_shift);
                    ta_write_element(dp, dst_cls, &scratch[i], ctx);
                    if (ctx.should_throw) { heap.free_func(heap.heap_udata, scratch); return; }
                }
                heap.free_func(heap.heap_udata, scratch);
            } else {
                // Cross-class, different buffers: element loop.
                for (uint i = 0; i < src_len; i++) {
                    TVal v = ta_load_element(src_data, src_cls, i);
                    char* dp = (*dst_buf.extra_ptr()).ab.data + dst_byte_off + ((target_offset + i) << dst_shift);
                    ta_write_element(dp, dst_cls, &v, ctx);
                    if (ctx.should_throw) return;
                    if (ta_is_detached(dst)) {
                        arraybuffer_throw_type_error(ctx, "TypedArray buffer detached during set");
                        return;
                    }
                }
            }
            *ctx.result = ctx.this_val;
            return;
        }
    }

    // Array-like source path
    HObject* src_arr = null;
    if (source_arg.is_object() && source_arg.get_heapptr() != null) {
        src_arr = (HObject*)source_arg.get_heapptr();
    }

    HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    TVal len_tv; len_tv.set_fastint(0);
    if (src_arr != null) {
        TVal? lv = builtins_generic_get(src_arr, length_key, ctx);
        if (ctx.should_throw) return;
        if (try v = lv) len_tv = v;
    }
    double src_len_d = builtin_to_integer_vm(ctx, &len_tv);
    if (ctx.should_throw) return;
    if (src_len_d < 0.0) src_len_d = 0.0;
    uint src_len = (uint)(long)src_len_d;

    if (src_len + target_offset > dst_len) {
        arraybuffer_throw_range_error(ctx, "TypedArray.set: source is too large");
        return;
    }

    for (uint i = 0; i < src_len; i++) {
        HString* idx_key = heap.int_to_hstring((long)i);
        TVal elem; elem.set_undefined();
        if (idx_key != null && src_arr != null) {
            TVal? ev = builtins_generic_get(src_arr, idx_key, ctx);
            if (ctx.should_throw) return;
            if (try v = ev) elem = v;
        }
        // Convert first; then re-check detach.
        double d = ta_val_to_number(&elem, ctx);
        if (ctx.should_throw) return;
        if (ta_is_detached(dst)) {
            arraybuffer_throw_type_error(ctx, "TypedArray buffer detached during set");
            return;
        }
        char* dp = (*dst_buf.extra_ptr()).ab.data + dst_byte_off + ((target_offset + i) << dst_shift);
        // Write the pre-converted double as a TVal.
        TVal num_tv; num_tv.set_number(d);
        ta_write_element(dp, dst_cls, &num_tv, ctx);
        if (ctx.should_throw) return;
    }
    *ctx.result = ctx.this_val;
}

// ---- subarray ----

/// %TypedArray%.prototype.subarray(begin, end) — §23.2.3.27.
/// Returns a new TA of the same class sharing the same ArrayBuffer.
fn void builtin_ta_proto_subarray(BuiltinContext* ctx) {
    HObject* obj = ta_validate(ctx);
    if (obj == null) return;
    Heap* heap = ctx.heap;

    hobject::ObjClass cls = obj.flags.obj_class;
    uint shift = ta_elem_shift(cls);
    HObject* buf = (*obj.extra_ptr()).view.buffer;
    uint byte_off = (*obj.extra_ptr()).view.byte_offset;
    uint byte_len = (*obj.extra_ptr()).view.byte_length;
    uint len = byte_len >> shift;

    TVal begin_arg; begin_arg.set_undefined();
    TVal end_arg;   end_arg.set_undefined();
    if (ctx.argc >= 1) begin_arg = ctx.regs[ctx.base_reg];
    if (ctx.argc >= 2) end_arg   = ctx.regs[ctx.base_reg + 1];

    double begin_d = builtin_to_integer_vm(ctx, &begin_arg);
    if (ctx.should_throw) return;
    double end_d;
    if (end_arg.is_undefined()) {
        end_d = (double)len;
    } else {
        end_d = builtin_to_integer_vm(ctx, &end_arg);
        if (ctx.should_throw) return;
    }

    uint begin_idx = ta_norm_index(begin_d, len);
    uint end_idx   = ta_norm_index(end_d, len);
    uint new_len   = end_idx > begin_idx ? end_idx - begin_idx : 0;

    uint new_byte_off = byte_off + (begin_idx << shift);
    uint new_byte_len = new_len << shift;

    HObject*? raw = heap.alloc_object(cls);
    if (catch err = raw) { ctx.result.set_undefined(); return; }
    HObject* sub = raw;
    sub.prototype = heap.typedarray_proto;
    (*sub.extra_ptr()).view.byte_offset = new_byte_off;
    (*sub.extra_ptr()).view.byte_length = new_byte_len;
    typedarray_link_view(buf, sub);
    ctx.result.set_object(sub);
}

// ---- fill ----

/// %TypedArray%.prototype.fill(value, start, end) — §23.2.3.9.
fn void builtin_ta_proto_fill(BuiltinContext* ctx) {
    HObject* obj = ta_validate(ctx);
    if (obj == null) return;
    Heap* heap = ctx.heap;

    hobject::ObjClass cls = obj.flags.obj_class;
    uint shift = ta_elem_shift(cls);
    HObject* buf = (*obj.extra_ptr()).view.buffer;
    uint byte_off = (*obj.extra_ptr()).view.byte_offset;
    uint len = (*obj.extra_ptr()).view.byte_length >> shift;

    TVal val_arg; val_arg.set_undefined();
    if (ctx.argc >= 1) val_arg = ctx.regs[ctx.base_reg];

    // Convert value first (may run user code).
    double fill_d = ta_val_to_number(&val_arg, ctx);
    if (ctx.should_throw) return;
    if (ta_is_detached(obj)) {
        arraybuffer_throw_type_error(ctx, "TypedArray buffer detached during fill");
        return;
    }

    TVal start_arg; start_arg.set_undefined();
    TVal end_arg;   end_arg.set_undefined();
    if (ctx.argc >= 2) start_arg = ctx.regs[ctx.base_reg + 1];
    if (ctx.argc >= 3) end_arg   = ctx.regs[ctx.base_reg + 2];

    double start_d = builtin_to_integer_vm(ctx, &start_arg);
    if (ctx.should_throw) return;
    double end_d;
    if (end_arg.is_undefined()) {
        end_d = (double)len;
    } else {
        end_d = builtin_to_integer_vm(ctx, &end_arg);
        if (ctx.should_throw) return;
    }

    uint k = ta_norm_index(start_d, len);
    uint final_k = ta_norm_index(end_d, len);

    if (k < final_k) {
        char* base = (*buf.extra_ptr()).ab.data + byte_off;
        if (cls == hobject::ObjClass.UINT8ARRAY || cls == hobject::ObjClass.INT8ARRAY) {
            // Single-byte fill: truncate to int8, then bulk memset.
            char fill_byte = (char)(double_to_int32(fill_d) & 0xFF);
            libc::memset(base + k, (int)fill_byte, (usz)(final_k - k));
        } else if (cls == hobject::ObjClass.UINT8CLAMPEDARRAY) {
            char clamped = ta_to_uint8_clamped(fill_d);
            libc::memset(base + k, (int)clamped, (usz)(final_k - k));
        } else {
            TVal fill_tv; fill_tv.set_number(fill_d);
            for (uint i = k; i < final_k; i++) {
                char* p = base + (i << shift);
                ta_write_element(p, cls, &fill_tv, ctx);
                if (ctx.should_throw) return;
            }
        }
    }

    *ctx.result = ctx.this_val;
}

// ---- copyWithin ----

/// %TypedArray%.prototype.copyWithin(target, start [, end]) — §23.2.3.6.
fn void builtin_ta_proto_copyWithin(BuiltinContext* ctx) {
    HObject* obj = ta_validate(ctx);
    if (obj == null) return;
    Heap* heap = ctx.heap;

    hobject::ObjClass cls = obj.flags.obj_class;
    uint shift = ta_elem_shift(cls);
    HObject* buf = (*obj.extra_ptr()).view.buffer;
    uint byte_off = (*obj.extra_ptr()).view.byte_offset;
    uint len = (*obj.extra_ptr()).view.byte_length >> shift;

    TVal target_arg; target_arg.set_undefined();
    TVal start_arg;  start_arg.set_undefined();
    TVal end_arg;    end_arg.set_undefined();
    if (ctx.argc >= 1) target_arg = ctx.regs[ctx.base_reg];
    if (ctx.argc >= 2) start_arg  = ctx.regs[ctx.base_reg + 1];
    if (ctx.argc >= 3) end_arg    = ctx.regs[ctx.base_reg + 2];

    double to_d    = builtin_to_integer_vm(ctx, &target_arg);
    if (ctx.should_throw) return;
    double from_d  = builtin_to_integer_vm(ctx, &start_arg);
    if (ctx.should_throw) return;
    double final_d;
    if (end_arg.is_undefined()) {
        final_d = (double)len;
    } else {
        final_d = builtin_to_integer_vm(ctx, &end_arg);
        if (ctx.should_throw) return;
    }

    // Re-check detach after argument coercions (may have run user code).
    if (ta_is_detached(obj)) {
        arraybuffer_throw_type_error(ctx, "TypedArray buffer detached during copyWithin");
        return;
    }

    uint to    = ta_norm_index(to_d, len);
    uint from  = ta_norm_index(from_d, len);
    uint final_end = ta_norm_index(final_d, len);

    uint count = final_end > from ? final_end - from : 0;
    if (len > to && count > len - to) count = len - to;

    if (count > 0) {
        char* base = (*buf.extra_ptr()).ab.data + byte_off;
        libc::memmove(base + (to << shift), base + (from << shift), (usz)(count << shift));
    }

    *ctx.result = ctx.this_val;
}

// ---- slice ----

/// %TypedArray%.prototype.slice(start, end) — §23.2.3.25.
/// Returns a new same-class TA with a fresh copy of the slice.
fn void builtin_ta_proto_slice(BuiltinContext* ctx) {
    HObject* obj = ta_validate(ctx);
    if (obj == null) return;
    Heap* heap = ctx.heap;

    hobject::ObjClass cls = obj.flags.obj_class;
    uint shift = ta_elem_shift(cls);
    HObject* src_buf = (*obj.extra_ptr()).view.buffer;
    uint byte_off = (*obj.extra_ptr()).view.byte_offset;
    uint len = (*obj.extra_ptr()).view.byte_length >> shift;

    TVal start_arg; start_arg.set_undefined();
    TVal end_arg;   end_arg.set_undefined();
    if (ctx.argc >= 1) start_arg = ctx.regs[ctx.base_reg];
    if (ctx.argc >= 2) end_arg   = ctx.regs[ctx.base_reg + 1];

    double start_d = builtin_to_integer_vm(ctx, &start_arg);
    if (ctx.should_throw) return;
    double end_d;
    if (end_arg.is_undefined()) {
        end_d = (double)len;
    } else {
        end_d = builtin_to_integer_vm(ctx, &end_arg);
        if (ctx.should_throw) return;
    }

    uint k = ta_norm_index(start_d, len);
    uint final_k = ta_norm_index(end_d, len);
    uint count = final_k > k ? final_k - k : 0;

    // Fresh buffer of count<<shift bytes.
    uint new_bytes = count << shift;
    HObject* new_buf = typedarray_alloc_buffer(ctx, new_bytes);
    if (new_buf == null) {
        arraybuffer_throw_range_error(ctx, "TypedArray.slice: out of memory");
        return;
    }

    if (count > 0) {
        char* src_data = (*src_buf.extra_ptr()).ab.data + byte_off + (k << shift);
        char* dst_data = (*new_buf.extra_ptr()).ab.data;
        libc::memcpy(dst_data, src_data, (usz)new_bytes);
    }

    HObject*? raw = heap.alloc_object(cls);
    if (catch err = raw) { ctx.result.set_undefined(); return; }
    HObject* result = raw;
    result.prototype = heap.typedarray_proto;
    (*result.extra_ptr()).view.byte_offset = 0;
    (*result.extra_ptr()).view.byte_length = new_bytes;
    typedarray_link_view(new_buf, result);
    ctx.result.set_object(result);
}

// ============================================================================
// Registration
// ============================================================================

/// Register a %TypedArray%.prototype accessor getter (shared implementation
/// pattern with register_arraybuffer_accessor in arraybuffer.c3).
fn bool register_typedarray_accessor(HObject* proto, Heap* heap, char[] name, uint getter_index) {
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

    HObject*? func_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = func_raw) return false;
    HObject* func_obj = func_raw;
    (*func_obj.extra_ptr()).func.builtin_fn_index = (int)getter_index;
    func_obj.flags.callable = true;
    func_obj.flags.constructable = false;
    func_obj.prototype = heap.function_proto;

    char[64] name_buf;
    libc::snprintf(&name_buf, 64, "get %s", name.ptr);
    usz total_len = libc::strlen((ZString)&name_buf);
    HString* fn_name = builtin_intern_string(heap, name_buf[:total_len]);
    if (fn_name != null) {
        TVal name_tv;
        name_tv.set_string(fn_name);
        HString* name_prop_key = builtin_intern_string(heap, "name");
        func_obj.put_prop(name_prop_key, name_tv, hobject::PROP_FLAGS_NWC);
    }
    HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    if (length_key != null) {
        TVal len_tv;
        len_tv.set_fastint(0);
        func_obj.put_prop(length_key, len_tv, hobject::PROP_FLAGS_NWC);
    }

    TVal getter_tv;
    getter_tv.set_object(func_obj);
    TVal undef;
    undef.set_undefined();
    hobject::PropFlags acc_flags;
    acc_flags.writable = false;
    acc_flags.enumerable = false;
    acc_flags.configurable = true;
    acc_flags.is_accessor = true;
    proto.put_prop(key, hobject::hobject_create_accessors(heap, getter_tv, undef), acc_flags);
    return true;
}

/// Register a %TypedArray%.prototype Symbol-keyed accessor getter.
fn bool register_typedarray_symbol_accessor(HObject* proto, Heap* heap, HString* key, uint getter_index) {
    HObject*? func_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = func_raw) return false;
    HObject* func_obj = func_raw;
    (*func_obj.extra_ptr()).func.builtin_fn_index = (int)getter_index;
    func_obj.flags.callable = true;
    func_obj.flags.constructable = false;
    func_obj.prototype = heap.function_proto;

    TVal getter_tv;
    getter_tv.set_object(func_obj);
    TVal undef;
    undef.set_undefined();
    hobject::PropFlags acc_flags;
    acc_flags.writable = false;
    acc_flags.enumerable = false;
    acc_flags.configurable = true;
    acc_flags.is_accessor = true;
    proto.put_prop(key, hobject::hobject_create_accessors(heap, getter_tv, undef), acc_flags);
    return true;
}

/// Register a single typed array constructor globally.
fn bool register_ta_ctor(EnvRecord* global_env, Heap* heap, char[] name, uint fn_index, HObject* proto) {
    // Create constructor as a proper HObject (not lightfunc) so it's constructable
    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)fn_index;
    ctor.flags.callable = true;
    ctor.flags.constructable = true;
    ctor.prototype = heap.function_proto;

    // Set .name
    HString* name_key = builtin_intern_string(heap, "name");
    HString* name_val = builtin_intern_string(heap, name);
    if (name_key != null && name_val != null) {
        TVal name_tv;
        name_tv.set_string(name_val);
        ctor.put_prop(name_key, name_tv, hobject::PROP_FLAGS_NWC);
    }

    // Set .length = 3 (buffer, byteOffset, length — the widest overload)
    HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    TVal length_tv;
    length_tv.set_fastint(3);
    ctor.put_prop(length_key, length_tv, hobject::PROP_FLAGS_NWC);

    // Per ES6 §22.2, each TypedArray constructor has its own .prototype that
    // inherits from the shared %TypedArray%.prototype. We set @@toStringTag on
    // that per-ctor prototype so Object.prototype.toString.call(instance)
    // returns "[object <Name>]" rather than "[object TypedArray]".
    HObject*? ctor_proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err_cp = ctor_proto_raw) return false;
    HObject* ctor_proto = ctor_proto_raw;
    ctor_proto.prototype = proto;

    // Wire .prototype
    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(ctor_proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    ctor.put_prop(prototype_key, proto_tv, proto_pflags);

    // .constructor back-reference on the per-ctor prototype.
    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal ctor_val_tv; ctor_val_tv.set_object(ctor);
    ctor_proto.put_prop(constructor_key, ctor_val_tv, hobject::PROP_FLAGS_WC);

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

    // Shared prototype accessors (length/byteLength/byteOffset/buffer).
    if (!register_typedarray_accessor(proto, heap, "length", BUILTIN_TYPEDARRAY_PROTO_LENGTH_GET)) return false;
    if (!register_typedarray_accessor(proto, heap, "byteLength", BUILTIN_TYPEDARRAY_PROTO_BYTELENGTH_GET)) return false;
    if (!register_typedarray_accessor(proto, heap, "byteOffset", BUILTIN_TYPEDARRAY_PROTO_BYTEOFFSET_GET)) return false;
    if (!register_typedarray_accessor(proto, heap, "buffer", BUILTIN_TYPEDARRAY_PROTO_BUFFER_GET)) return false;

    // [Symbol.toStringTag] getter on the shared prototype: returns the
    // per-instance class name, or undefined for non-TA receivers.
    HString* tag_key = ensure_tostringtag_symbol(heap);
    if (tag_key != null) {
        if (!register_typedarray_symbol_accessor(proto, heap, tag_key, BUILTIN_TYPEDARRAY_PROTO_TOSTRINGTAG_GET)) return false;
    }

    // Wave A prototype methods (plan 049 stage 4)
    if (!register_string_proto_method(proto, heap, "values",      BUILTIN_TA_PROTO_VALUES))      return false;
    if (!register_string_proto_method(proto, heap, "keys",        BUILTIN_TA_PROTO_KEYS))        return false;
    if (!register_string_proto_method(proto, heap, "entries",     BUILTIN_TA_PROTO_ENTRIES))     return false;
    if (!register_string_proto_method(proto, heap, "set",         BUILTIN_TA_PROTO_SET))         return false;
    if (!register_string_proto_method(proto, heap, "subarray",    BUILTIN_TA_PROTO_SUBARRAY))    return false;
    if (!register_string_proto_method(proto, heap, "fill",        BUILTIN_TA_PROTO_FILL))        return false;
    if (!register_string_proto_method(proto, heap, "copyWithin",  BUILTIN_TA_PROTO_COPYWITHIN))  return false;
    if (!register_string_proto_method(proto, heap, "slice",       BUILTIN_TA_PROTO_SLICE))       return false;

    // %TypedArray%.prototype[@@iterator] = values
    {
        HString* iter_sym = ensure_iterator_symbol(heap);
        if (iter_sym != null) {
            HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
            if (catch err = fn_raw) return false;
            HObject* fn_obj = fn_raw;
            (*fn_obj.extra_ptr()).func.builtin_fn_index = (int)BUILTIN_TA_PROTO_SYMBOL_ITERATOR;
            fn_obj.flags.callable = true;
            fn_obj.prototype = heap.function_proto;
            HString* name_key = builtin_intern_string(heap, "name");
            HString* name_val = builtin_intern_string(heap, "[Symbol.iterator]");
            if (name_key != null && name_val != null) {
                TVal name_tv;
                name_tv.set_string(name_val);
                fn_obj.put_prop(name_key, name_tv, hobject::PROP_FLAGS_NWC);
            }
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

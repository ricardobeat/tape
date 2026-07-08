/// JSON.parse and JSON.stringify.
module duktape::builtins;
import duktape::types;
import std::math;
import libc;

import duktape::heap;
import duktape::hstring;
import duktape::hobject;
import duktape::env;
import duktape::dtoa_bindings;
import std::io;

// ============================================================================
// JSON.parse (ES5 §15.12.2)
// ============================================================================

struct JsonParseCtx {
    char* src;
    uint pos;
    uint len;
    Heap* heap;
}

fn void json_skip_ws(JsonParseCtx* jctx) {
    while (jctx.pos < jctx.len) {
        char c = jctx.src[jctx.pos];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
            jctx.pos++;
        } else {
            break;
        }
    }
}

/// Parse a 4-digit hex escape (\uXXXX).
fn uint json_parse_hex4(JsonParseCtx* jctx) {
    uint val = 0;
    for (int i = 0; i < 4; i++) {
        if (jctx.pos >= jctx.len) return 0xFFFFFFFF;
        char c = jctx.src[jctx.pos];
        uint d;
        if (c >= '0' && c <= '9') {
            d = (uint)(c - '0');
        } else if (c >= 'a' && c <= 'f') {
            d = (uint)(c - 'a' + 10);
        } else if (c >= 'A' && c <= 'F') {
            d = (uint)(c - 'A' + 10);
        } else {
            return 0xFFFFFFFF;
        }
        val = (val << 4) | d;
        jctx.pos++;
    }
    return val;
}

/// Parse a JSON string (between quotes).
fn HString*? json_parse_string(JsonParseCtx* jctx) {
    if (jctx.pos >= jctx.len || jctx.src[jctx.pos] != '\"') {
        return null;
    }
    jctx.pos++; // skip opening quote

    char[1024] buf;
    usz out_len = 0;

    while (jctx.pos < jctx.len) {
        char c = jctx.src[jctx.pos];
        if (c == '\"') {
            jctx.pos++; // skip closing quote
            return builtin_intern_string(jctx.heap, buf[:out_len]);
        }
        if (c == '\\') {
            jctx.pos++;
            if (jctx.pos >= jctx.len) return null;
            char esc = jctx.src[jctx.pos];
            jctx.pos++;
            char ch;
            switch (esc) {
                case '\"': ch = '\"'; break;
                case '\\': ch = '\\'; break;
                case '/':  ch = '/';  break;
                case 'b':  ch = '\b'; break;
                case 'f':  ch = '\f'; break;
                case 'n':  ch = '\n'; break;
                case 'r':  ch = '\r'; break;
                case 't':  ch = '\t'; break;
                case 'u': {
                    uint cp = json_parse_hex4(jctx);
                    if (cp == 0xFFFFFFFF) return null;
                    // Simple ASCII-range unicode (for now, just low bytes)
                    if (cp <= 0x7F) {
                        ch = (char)cp;
                    } else if (cp <= 0x7FF) {
                        // UTF-8 2-byte sequence
                        if (out_len + 2 > 1024) return null;
                        buf[out_len++] = (char)(0xC0 | (cp >> 6));
                        ch = (char)(0x80 | (cp & 0x3F));
                    } else {
                        // UTF-8 3-byte sequence
                        if (out_len + 3 > 1024) return null;
                        buf[out_len++] = (char)(0xE0 | (cp >> 12));
                        buf[out_len++] = (char)(0x80 | ((cp >> 6) & 0x3F));
                        ch = (char)(0x80 | (cp & 0x3F));
                    }
                    break;
                }
                default:
                    return null;
            }
            if (out_len >= 1024) return null;
            buf[out_len++] = ch;
        } else if (c < 0x20) {
            // Control characters not allowed
            return null;
        } else {
            if (out_len >= 1024) return null;
            buf[out_len++] = c;
            jctx.pos++;
        }
    }
    return null; // unterminated string
}

/// Parse a JSON number.
fn TVal json_parse_number(JsonParseCtx* jctx) {
    uint start = jctx.pos;

    // Optional minus
    if (jctx.pos < jctx.len && jctx.src[jctx.pos] == '-') {
        jctx.pos++;
    }

    // Integer part
    if (jctx.pos >= jctx.len) {
        TVal r; r.set_undefined(); return r;
    }
    if (jctx.src[jctx.pos] == '0') {
        jctx.pos++;
    } else if (jctx.src[jctx.pos] >= '1' && jctx.src[jctx.pos] <= '9') {
        jctx.pos++;
        while (jctx.pos < jctx.len && jctx.src[jctx.pos] >= '0' && jctx.src[jctx.pos] <= '9') {
            jctx.pos++;
        }
    } else {
        TVal r; r.set_undefined(); return r;
    }

    // Fractional part
    if (jctx.pos < jctx.len && jctx.src[jctx.pos] == '.') {
        jctx.pos++;
        if (jctx.pos >= jctx.len || jctx.src[jctx.pos] < '0' || jctx.src[jctx.pos] > '9') {
            TVal r; r.set_undefined(); return r;
        }
        while (jctx.pos < jctx.len && jctx.src[jctx.pos] >= '0' && jctx.src[jctx.pos] <= '9') {
            jctx.pos++;
        }
    }

    // Exponent part
    if (jctx.pos < jctx.len && (jctx.src[jctx.pos] == 'e' || jctx.src[jctx.pos] == 'E')) {
        jctx.pos++;
        if (jctx.pos < jctx.len && (jctx.src[jctx.pos] == '+' || jctx.src[jctx.pos] == '-')) {
            jctx.pos++;
        }
        if (jctx.pos >= jctx.len || jctx.src[jctx.pos] < '0' || jctx.src[jctx.pos] > '9') {
            TVal r; r.set_undefined(); return r;
        }
        while (jctx.pos < jctx.len && jctx.src[jctx.pos] >= '0' && jctx.src[jctx.pos] <= '9') {
            jctx.pos++;
        }
    }

    // Convert to double
    uint end = jctx.pos;
    char saved = jctx.src[end];
    jctx.src[end] = 0;
    char* endptr;
    double d = libc::strtod(jctx.src + start, &endptr);
    jctx.src[end] = saved;

    // Try fastint preservation
    long fi = (long)d;
    if ((double)fi == d && fi >= types::DUK_MIN_SAFE_INT && fi <= types::DUK_MAX_SAFE_INT) {
        TVal r; r.set_fastint(fi); return r;
    }
    TVal r; r.set_number(d); return r;
}

/// Parse a JSON array: [value, ...]
fn TVal json_parse_array(JsonParseCtx* jctx) {
    jctx.pos++; // skip '['
    json_skip_ws(jctx);

    HObject*? arr_raw = jctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    HObject* arr;
    if (try a = arr_raw) {
        arr = a;
        arr.prototype = jctx.heap.array_proto;
    } else {
        TVal r; r.set_undefined(); return r;
    }

    HString* len_key = builtin_intern_string(jctx.heap, "length");
    uint idx = 0;

    if (jctx.pos < jctx.len && jctx.src[jctx.pos] != ']') {
        while (true) {
            json_skip_ws(jctx);
            TVal elem = json_parse_value(jctx);
            if (elem.is_undefined() && elem.get_heapptr() == null && jctx.pos < jctx.len) {
                TVal r; r.set_undefined(); return r; // parse error
            }
            json_skip_ws(jctx);

            HString* idx_key = jctx.heap.int_to_hstring((long)idx);
            if (idx_key != null) {
                arr.put_prop(idx_key, elem, hobject::PROP_FLAGS_WEC);
            }
            idx++;

            if (jctx.pos >= jctx.len) {
                TVal r; r.set_undefined(); return r;
            }
            if (jctx.src[jctx.pos] == ',') {
                jctx.pos++;
            } else {
                break;
            }
        }
    }

    if (jctx.pos >= jctx.len || jctx.src[jctx.pos] != ']') {
        TVal r; r.set_undefined(); return r;
    }
    jctx.pos++; // skip ']'

    TVal len_val;
    len_val.set_fastint((long)idx);
    arr.put_prop(len_key, len_val, hobject::PROP_FLAGS_WEC);

    TVal result;
    result.set_object(arr);
    return result;
}

/// Parse a JSON object: {key: value, ...}
fn TVal json_parse_object(JsonParseCtx* jctx) {
    jctx.pos++; // skip '{'
    json_skip_ws(jctx);

    HObject*? obj_raw = jctx.heap.alloc_object(hobject::ObjClass.OBJECT);
    HObject* obj;
    if (try o = obj_raw) {
        obj = o;
        obj.prototype = jctx.heap.object_proto;
    } else {
        TVal r; r.set_undefined(); return r;
    }

    if (jctx.pos < jctx.len && jctx.src[jctx.pos] != '}') {
        while (true) {
            json_skip_ws(jctx);
            if (jctx.pos >= jctx.len || jctx.src[jctx.pos] != '\"') {
                TVal r; r.set_undefined(); return r;
            }
            HString*? key_str = json_parse_string(jctx);
            if (try k = key_str) {
                json_skip_ws(jctx);
                if (jctx.pos >= jctx.len || jctx.src[jctx.pos] != ':') {
                    TVal r; r.set_undefined(); return r;
                }
                jctx.pos++; // skip ':'
                json_skip_ws(jctx);
                TVal val = json_parse_value(jctx);
                if (val.is_undefined() && val.get_heapptr() == null && jctx.pos < jctx.len) {
                    TVal r; r.set_undefined(); return r;
                }
                obj.put_prop(k, val, hobject::PROP_FLAGS_WEC);
                json_skip_ws(jctx);
                if (jctx.pos >= jctx.len) {
                    TVal r; r.set_undefined(); return r;
                }
                if (jctx.src[jctx.pos] == ',') {
                    jctx.pos++;
                } else {
                    break;
                }
            } else {
                TVal r; r.set_undefined(); return r;
            }
        }
    }

    if (jctx.pos >= jctx.len || jctx.src[jctx.pos] != '}') {
        TVal r; r.set_undefined(); return r;
    }
    jctx.pos++; // skip '}'

    TVal result;
    result.set_object(obj);
    return result;
}

/// Parse a JSON value.
fn TVal json_parse_value(JsonParseCtx* jctx) {
    json_skip_ws(jctx);
    if (jctx.pos >= jctx.len) {
        TVal r; r.set_undefined(); return r;
    }

    char c = jctx.src[jctx.pos];
    switch (c) {
        case '\"':
            // String
            {
                HString*? s = json_parse_string(jctx);
                if (try str = s) {
                    TVal r; r.set_string(str); return r;
                }
                TVal r; r.set_undefined(); return r;
            }
        case '{':
            return json_parse_object(jctx);
        case '[':
            return json_parse_array(jctx);
        case 't':
            // true
            if (jctx.pos + 4 <= jctx.len &&
                jctx.src[jctx.pos + 1] == 'r' &&
                jctx.src[jctx.pos + 2] == 'u' &&
                jctx.src[jctx.pos + 3] == 'e') {
                jctx.pos += 4;
                TVal r; r.set_boolean(true); return r;
            }
            { TVal r; r.set_undefined(); return r; }
        case 'f':
            // false
            if (jctx.pos + 5 <= jctx.len &&
                jctx.src[jctx.pos + 1] == 'a' &&
                jctx.src[jctx.pos + 2] == 'l' &&
                jctx.src[jctx.pos + 3] == 's' &&
                jctx.src[jctx.pos + 4] == 'e') {
                jctx.pos += 5;
                TVal r; r.set_boolean(false); return r;
            }
            { TVal r; r.set_undefined(); return r; }
        case 'n':
            // null
            if (jctx.pos + 4 <= jctx.len &&
                jctx.src[jctx.pos + 1] == 'u' &&
                jctx.src[jctx.pos + 2] == 'l' &&
                jctx.src[jctx.pos + 3] == 'l') {
                jctx.pos += 4;
                TVal r; r.set_null(); return r;
            }
            { TVal r; r.set_undefined(); return r; }
        case '-':
        case '0'..'9':
            return json_parse_number(jctx);
        default:
            { TVal r; r.set_undefined(); return r; }
    }
}

/// Walk helper for reviver (ES5 §15.12.2, step 4 — internalize properties).
fn TVal json_walk(void* vm, Heap* heap, TVal reviver, TVal holder, HString* name) {
    TVal val;
    if (holder.is_object() && holder.get_heapptr() != null) {
        HObject* obj = (HObject*)holder.get_heapptr();
        TVal? prop = obj.get_prop_proto(name);
        if (try p = prop) {
            val = p;
        } else {
            val.set_undefined();
        }
    } else {
        val.set_undefined();
    }

    // ES5 §15.12.2 step 4.b: if value is an object, walk its properties recursively
    if (val.is_object() && val.get_heapptr() != null) {
        HObject* obj = (HObject*)val.get_heapptr();
        if (obj.get_class() == ObjClass.ARRAY) {
            HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
            TVal? len_prop = obj.get_prop_proto(len_key);
            uint len = 0;
            if (try l = len_prop) {
                if (l.is_fastint()) len = (uint)l.get_fastint();
            }
            for (uint i = 0; i < len; i++) {
                HString* idx_key = heap.int_to_hstring((long)i);
                if (idx_key == null) continue;
                TVal new_elem = json_walk(vm, heap, reviver, val, idx_key);
                if (new_elem.is_undefined()) {
                    obj.delete_prop(idx_key);
                } else {
                    obj.put_prop(idx_key, new_elem, hobject::PROP_FLAGS_WEC);
                }
            }
        } else if (obj.get_class() == ObjClass.OBJECT) {
            // Walk own properties
            for (uint i = 0; i < obj.prop_count; i++) {
                HString* key_str = obj.prop_key_at(i);
                if (key_str != null) {
                    TVal new_val = json_walk(vm, heap, reviver, val, key_str);
                    if (new_val.is_undefined()) {
                        obj.delete_prop(key_str);
                    } else {
                        obj.put_prop(key_str, new_val, hobject::PROP_FLAGS_WEC);
                    }
                }
            }
        }
    }

    // ES5 §15.12.2 step 4.c: Call reviver(this=holder, name, val)
    TVal name_str;
    name_str.set_string(name);

    if (heap.call_fn != null && vm != null) {
        bool callable = false;
        if (reviver.is_object() && reviver.get_heapptr() != null) {
            callable = ((HObject*)reviver.get_heapptr()).is_callable();
        } else if (reviver.is_lightfunc()) {
            callable = true;
        }
        if (callable) {
            TVal[2] rev_args;
            rev_args[0] = name_str;
            rev_args[1] = val;
            val = heap.call_fn(vm, reviver, &rev_args[0], 2, holder);
        }
    }

    return val;
}

/// Helper: throw a SyntaxError from a JSON builtin.
fn void json_throw_syntax_error(BuiltinContext* ctx, char[] msg) {
    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = ctx.heap.syntax_err_proto;
        HString* msg_str = builtin_intern_string(ctx.heap, msg);
        TVal msg_tv;
        msg_tv.set_string(msg_str);
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        ctx.throw_value.set_object(err);
    } else {
        ctx.throw_value.set_undefined();
    }
    ctx.should_throw = true;
}

/// JSON.parse(text [, reviver]) — ES5 §15.12.2
fn void builtin_json_parse(BuiltinContext* ctx) {
    // Step 1: Coerce first argument to string
    if (ctx.argc < 1) {
        json_throw_syntax_error(ctx, "JSON.parse requires at least 1 argument");
        return;
    }

    TVal* text_arg = &ctx.regs[ctx.base_reg];
    HString* text_str;

    if (text_arg.is_string()) {
        text_str = (HString*)text_arg.get_heapptr();
    } else {
        text_str = builtin_to_string(ctx.heap, text_arg);
        if (text_str == null) {
            json_throw_syntax_error(ctx, "Invalid JSON");
            return;
        }
    }

    char* src = text_str.get_cstr();
    uint len = text_str.blen;

    JsonParseCtx jctx;
    jctx.src = src;
    jctx.pos = 0;
    jctx.len = len;
    jctx.heap = ctx.heap;

    TVal result = json_parse_value(&jctx);

    // Check parse error (undefined == error)
    if (result.is_undefined() && result.get_heapptr() == null) {
        json_throw_syntax_error(ctx, "Unexpected token in JSON");
        return;
    }

    // Skip trailing whitespace
    json_skip_ws(&jctx);
    if (jctx.pos != jctx.len) {
        // Trailing non-whitespace characters → SyntaxError
        json_throw_syntax_error(ctx, "Unexpected token in JSON");
        return;
    }

    // Set prototype on the result object if it's an object
    if (result.is_object() && result.get_heapptr() != null) {
        HObject* obj = (HObject*)result.get_heapptr();
        if (obj.prototype == null) {
            if (obj.get_class() == hobject::ObjClass.ARRAY) {
                obj.prototype = ctx.heap.array_proto;
            } else {
                obj.prototype = ctx.heap.object_proto;
            }
        }
    }

    // Reviver support (ES5 §15.12.2 step 4)
    if (ctx.argc > 1) {
        TVal* reviver_arg = &ctx.regs[ctx.base_reg + 1];
        if (reviver_arg.is_lightfunc() || (reviver_arg.is_object() &&
            ((HObject*)reviver_arg.get_heapptr()) != null &&
            ((HObject*)reviver_arg.get_heapptr()).is_callable())) {
            // Create holder object { "": result }
            HObject*? holder_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
            if (try holder = holder_raw) {
                HString* empty_key = builtin_intern_string(ctx.heap, "");
                holder.put_prop(empty_key, result, hobject::PROP_FLAGS_WEC);

                TVal holder_tv;
                holder_tv.set_object(holder);

                // ES5 §15.12.2 step 4: walk the root value through the reviver
                TVal walked = json_walk(ctx.vm, ctx.heap, *reviver_arg, holder_tv, empty_key);
                *ctx.result = walked;
            } else {
                *ctx.result = result;
            }
        } else {
            *ctx.result = result;
        }
    } else {
        *ctx.result = result;
    }
}

// ============================================================================
// JSON.stringify (ES5 §15.12.3)
// ============================================================================

/// Helper: append a JSON-escaped string to a buffer.
fn usz json_escape_string(char* src, uint len, char* buf, usz buf_size) {
    usz pos = 0;
    if (pos < buf_size) buf[pos++] = '\"';
    for (uint i = 0; i < len && pos < buf_size; i++) {
        char c = src[i];
        switch (c) {
            case '\"': if (pos + 2 > buf_size) { break; } buf[pos++] = '\\'; buf[pos++] = '\"'; break;
            case '\\': if (pos + 2 > buf_size) { break; } buf[pos++] = '\\'; buf[pos++] = '\\'; break;
            case '\b': if (pos + 2 > buf_size) { break; } buf[pos++] = '\\'; buf[pos++] = 'b'; break;
            case '\f': if (pos + 2 > buf_size) { break; } buf[pos++] = '\\'; buf[pos++] = 'f'; break;
            case '\n': if (pos + 2 > buf_size) { break; } buf[pos++] = '\\'; buf[pos++] = 'n'; break;
            case '\r': if (pos + 2 > buf_size) { break; } buf[pos++] = '\\'; buf[pos++] = 'r'; break;
            case '\t': if (pos + 2 > buf_size) { break; } buf[pos++] = '\\'; buf[pos++] = 't'; break;
            default:
                if ((c & 0x80) != 0) {
                    // Non-ASCII: pass through as-is (valid UTF-8)
                    if (pos >= buf_size) break;
                    buf[pos++] = c;
                } else if (c < 0x20) {
                    // Control char: \uXXXX
                    if (pos + 6 > buf_size) break;
                    buf[pos++] = '\\';
                    buf[pos++] = 'u';
                    buf[pos++] = '0';
                    buf[pos++] = '0';
                    char[16] hex_digits = { '0','1','2','3','4','5','6','7','8','9','a','b','c','d','e','f' };
                    buf[pos++] = hex_digits[(c >> 4) & 0xF];
                    buf[pos++] = hex_digits[c & 0xF];
                } else {
                    // Regular ASCII
                    if (pos >= buf_size) break;
                    buf[pos++] = c;
                }
                break;
        }
    }
    if (pos < buf_size) buf[pos++] = '\"';
    return pos;
}

/// Serialize a JSON value (internal recursive helper).
/// Returns 0 on success, non-zero on error.
/// Writes to buf starting at offset, updates offset.
struct JsonSerializeCtx {
    Heap* heap;
    void* vm;                    // VM pointer for calling JS functions
    char* buf;
    usz buf_size;
    usz offset;
    usz indent_level;
    char* gap;
    usz gap_len;
    /// Current stack depth for cycle detection
    uint depth;
    /// Replacer function (undefined if none)
    TVal replacer_func;
    /// Property list from replacer array (null if none)
    HString** prop_keys;
    uint prop_key_count;
    /// True when a replacer array was provided (even if empty)
    bool has_replacer_array;
    /// Set when a call_fn error occurred (toJSON/replacer threw)
    bool error;
    /// Stack of object pointers for circular reference detection
    HObject*[128] visited_stack;
    uint visited_count;
}

const uint JSON_MAX_DEPTH = 128;

/// Helper: throw a TypeError from the serialization context.
fn void json_throw_type_error(JsonSerializeCtx* jctx, char[] msg) {
    HObject*? err_raw = jctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = jctx.heap.type_err_proto;
        HString* msg_str = builtin_intern_string(jctx.heap, msg);
        if (msg_str != null) {
            TVal msg_val;
            msg_val.set_string(msg_str);
            HString* msg_key = builtin_intern_string(jctx.heap, "message");
            err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WC);
        }
        jctx.heap.has_error = true;
        jctx.heap.error_value.set_object(err);
    }
    jctx.error = true;
}

/// Check if object is already on the serialization stack (circular reference detection).
fn bool json_stack_has(JsonSerializeCtx* jctx, HObject* obj) {
    for (uint i = 0; i < jctx.visited_count; i++) {
        if (jctx.visited_stack[i] == obj) return true;
    }
    return false;
}

/// Push an object onto the serialization stack.
fn void json_stack_push(JsonSerializeCtx* jctx, HObject* obj) {
    if (jctx.visited_count < JSON_MAX_DEPTH) {
        jctx.visited_stack[jctx.visited_count++] = obj;
    }
}

/// Pop the last object from the serialization stack.
fn void json_stack_pop(JsonSerializeCtx* jctx) {
    if (jctx.visited_count > 0) jctx.visited_count--;
}

/// ES5 §9.8.1 ToString for Number values — produces the shortest string that
/// uniquely identifies the IEEE 754 double.  Writes into `buf` and returns the
/// number of characters written.
fn usz json_number_to_string(double d, char* buf, usz buf_size) {
    // NaN → "NaN"
    if (math::is_nan(d)) {
        libc::memcpy(buf, "NaN", 3);
        return 3;
    }
    // +Infinity → "Infinity"
    if (math::is_inf(d) && d > 0.0) {
        libc::memcpy(buf, "Infinity", 8);
        return 8;
    }
    // -Infinity → "-Infinity"
    if (math::is_inf(d) && d < 0.0) {
        libc::memcpy(buf, "-Infinity", 9);
        return 9;
    }
    // +0 / -0 → "0"  (ES5 §9.8.1 step 2)
    if (d == 0.0) {
        buf[0] = '0';
        return 1;
    }
    // Shortest round-trip decimal via QuickJS js_dtoa (FREE mode), same as
    // ToString(Number) — spec exponent format, correct final-digit rounding.
    if (buf_size < 64) {
        int glen = libc::snprintf(buf, buf_size, "%.17g", d);
        return (glen > 0) ? (usz)glen : 0;
    }
    char[dtoa_bindings::DTOA_FORMAT_TMP_SIZE] tmp;
    int len = dtoa_bindings::duktape_js_dtoa(buf, d, 10, 0,
        dtoa_bindings::JS_DTOA_FORMAT_FREE, &tmp);
    if (len > 0 && (usz)len < buf_size) {
        return (usz)len;
    }
    int flen = libc::snprintf(buf, buf_size, "%.17g", d);
    return (flen > 0) ? (usz)flen : 0;
}

/// ES5 §15.12.3 step 5: Type unwrapping via ToString/ToNumber/ToBoolean.
/// For String/Number wrapper objects, calls toString()/valueOf() (per spec)
/// rather than reading the cached primitive_value (which ignores overrides).
/// Returns the unwrapped TVal. Sets *had_error=true if the method threw.
/// For non-wrapper objects, returns the value unchanged.
fn TVal json_unwrap_wrapper(JsonSerializeCtx* jctx, TVal val, bool* had_error) {
    *had_error = false;
    if (!val.is_object() || val.get_heapptr() == null) return val;
    HObject* obj = (HObject*)val.get_heapptr();
    ObjClass cls = obj.get_class();

    // Boolean wrapper: just read [[BooleanData]] per spec
    if (cls == ObjClass.BOOLEAN) {
        if ((*obj.extra_ptr()).prim.primitive_value.is_boolean()) {
            TVal result;
            result.set_boolean((*obj.extra_ptr()).prim.primitive_value.get_boolean());
            return result;
        }
        return val;
    }

    // String wrapper: ToString → call toString()
    if (cls == ObjClass.STRING) {
        HString* to_str_key = (HString*)jctx.heap.strs[heap::BuiltinStr.TO_STRING];
        if (to_str_key == null) return val;
        TVal? toString_fn_opt = obj.get_prop_proto(to_str_key);
        if (try toString_fn = toString_fn_opt) {
            bool callable = false;
            if (toString_fn.is_object() && toString_fn.get_heapptr() != null) {
                HObject* fn_hobj = (HObject*)toString_fn.get_heapptr();
                callable = fn_hobj.is_callable();
            } else if (toString_fn.is_lightfunc()) {
                callable = true;
            }
            if (callable && jctx.heap.call_fn != null && jctx.vm != null) {
                TVal result = jctx.heap.call_fn(jctx.vm, toString_fn, null, 0, val);
                if (jctx.heap.has_error) { *had_error = true; return val; }
                return result;
            }
        }
        // No callable toString — fall back to primitive value
        if ((*obj.extra_ptr()).prim.primitive_value.is_string()) {
            return (*obj.extra_ptr()).prim.primitive_value;
        }
        return val;
    }

    // Number wrapper: ToNumber → call valueOf() first (per ES §9.3 / §15.12.3.4)
    if (cls == ObjClass.NUMBER) {
        HString* vo_key = (HString*)jctx.heap.strs[heap::BuiltinStr.VALUE_OF];
        if (vo_key != null) {
            TVal? valueOf_fn_opt = obj.get_prop_proto(vo_key);
            if (try valueOf_fn = valueOf_fn_opt) {
                bool callable = false;
                if (valueOf_fn.is_object() && valueOf_fn.get_heapptr() != null) {
                    HObject* fn_hobj = (HObject*)valueOf_fn.get_heapptr();
                    callable = fn_hobj.is_callable();
                } else if (valueOf_fn.is_lightfunc()) {
                    callable = true;
                }
                if (callable && jctx.heap.call_fn != null && jctx.vm != null) {
                    TVal result = jctx.heap.call_fn(jctx.vm, valueOf_fn, null, 0, val);
                    if (jctx.heap.has_error) { *had_error = true; return val; }
                    return result;
                }
            }
        }
        // Fallback: primitive value
        return (*obj.extra_ptr()).prim.primitive_value;
    }

    return val;
}

/// Apply toJSON + replacer function + type unwrapping per ES5 §15.12.3
/// SerializeJSONProperty steps 1-4. Returns the processed value.
/// If the result should be omitted (undefined/functions), sets *omit=true.
fn TVal json_check_property(JsonSerializeCtx* jctx, HString* key, TVal val, TVal holder, bool* omit) {
    *omit = false;

    // Step 2: Check toJSON on objects
    if (val.is_object() && val.get_heapptr() != null) {
        HObject* obj = (HObject*)val.get_heapptr();
        HString* toJSON_key = builtin_intern_string(jctx.heap, "toJSON");
        TVal? toJSON_val = obj.get_prop_proto(toJSON_key);
        if (try toJSON_fn = toJSON_val) {
            bool callable = false;
            if (toJSON_fn.is_object() && toJSON_fn.get_heapptr() != null) {
                HObject* fn_hobj = (HObject*)toJSON_fn.get_heapptr();
                callable = fn_hobj.is_callable();
            } else if (toJSON_fn.is_lightfunc()) {
                callable = true;
            }
            if (callable) {
                TVal key_tv;
                key_tv.set_string(key);
                TVal[1] json_args;
                json_args[0] = key_tv;
                if (jctx.heap.call_fn != null && jctx.vm != null) {
                    val = jctx.heap.call_fn(jctx.vm, toJSON_fn, &json_args[0], 1, val);
                    if (jctx.heap.has_error) { jctx.error = true; *omit = true; return val; }
                }
            }
        }
    }

    // Step 3: Call replacer function
    if (!jctx.replacer_func.is_undefined()) {
        bool callable = false;
        if (jctx.replacer_func.is_object() && jctx.replacer_func.get_heapptr() != null) {
            HObject* fn_hobj = (HObject*)jctx.replacer_func.get_heapptr();
            callable = fn_hobj.is_callable();
        } else if (jctx.replacer_func.is_lightfunc()) {
            callable = true;
        }
        if (callable) {
            TVal key_tv;
            key_tv.set_string(key);
            TVal[2] rep_args;
            rep_args[0] = key_tv;
            rep_args[1] = val;
            if (jctx.heap.call_fn != null && jctx.vm != null) {
                val = jctx.heap.call_fn(jctx.vm, jctx.replacer_func, &rep_args[0], 2, holder);
                if (jctx.heap.has_error) { jctx.error = true; *omit = true; return val; }
            }
        }
    }

    // Step 4: Unwrap wrapper objects (String/Number/Boolean) per ES5 §15.12.3
    // For String/Number wrappers, ToString/ToNumber calls toString()/valueOf()
    // — must respect any overridden methods on the wrapper.
    if (val.is_object() && val.get_heapptr() != null) {
        HObject* obj = (HObject*)val.get_heapptr();
        ObjClass cls = obj.get_class();
        if (cls == ObjClass.STRING || cls == ObjClass.NUMBER || cls == ObjClass.BOOLEAN) {
            bool unwrap_err = false;
            TVal unwrapped = json_unwrap_wrapper(jctx, val, &unwrap_err);
            if (unwrap_err) { jctx.error = true; *omit = true; return unwrapped; }
            val = unwrapped;
        }
    }

    // Step 5-12: Determine if value should be omitted
    // undefined and functions → omit
    if (val.is_undefined()) { *omit = true; return val; }
    if (val.is_lightfunc()) { *omit = true; return val; }
    if (val.is_object() && val.get_heapptr() != null) {
        HObject* obj = (HObject*)val.get_heapptr();
        if (obj.get_class() == ObjClass.FUNCTION) { *omit = true; return val; }
    }

    return val;
}

/// Check if a value is an array-like object per ES5 spec (HasProperty with "length")
fn bool json_is_array(HObject* obj) {
    return obj.get_class() == ObjClass.ARRAY ||
           obj.get_class() == ObjClass.ARGUMENTS;
}

/// Serialize an object's properties
fn int json_serialize_object(JsonSerializeCtx* jctx, HObject* obj) {
    if (jctx.error) return -1;
    if (jctx.offset >= jctx.buf_size) return -1;

    // ES5 §15.12.3 step 1: If stack contains value, throw TypeError
    if (json_stack_has(jctx, obj)) {
        json_throw_type_error(jctx, "Converting circular structure to JSON");
        return -1;
    }
    json_stack_push(jctx, obj);
    defer json_stack_pop(jctx);

    jctx.indent_level++;

    jctx.buf[jctx.offset++] = '{';

    // Create holder TVal for replacer calls
    TVal holder;
    holder.set_object(obj);

    // Build the key list: use property_list if replacer array, else own properties
    bool has_replacer = jctx.has_replacer_array;
    bool has_props = false;


    if (!has_replacer) {
        // Check if object has own properties (including accessor properties with getters)
        for (uint i = 0; i < obj.prop_count; i++) {
            if (obj.prop_key_at(i) != null) {
                has_props = true;
                break;
            }
        }
    } else {
        has_props = true;
    }

    if (!has_props) {
        if (jctx.offset >= jctx.buf_size) return -1;
        jctx.buf[jctx.offset++] = '}';
        return 0;
    }

    bool first = true;

    if (has_replacer) {
        // Iterate property list from replacer array
        for (uint p = 0; p < jctx.prop_key_count; p++) {
            HString* key_hstr = jctx.prop_keys[p];

            // Get value from object — must handle accessor properties (getters)
            TVal val;
            bool found_prop = false;
            for (uint pi = 0; pi < obj.prop_count; pi++) {
                if (obj.prop_key_at(pi) == key_hstr) {
                    if (obj.get_prop_flags(pi).is_accessor) {
                        // Invoke the getter to get the property value
                        TVal getter_fn = hobject::hobject_access_getter(obj.prop_values()[pi]);
                        if (getter_fn.is_undefined() || getter_fn.is_null()) {
                            val.set_undefined();
                        } else if (jctx.heap.call_fn != null && jctx.vm != null) {
                            val = jctx.heap.call_fn(jctx.vm, getter_fn, null, 0, holder);
                            if (jctx.heap.has_error) { jctx.error = true; return -1; }
                        } else {
                            val.set_undefined();
                        }
                    } else {
                        val = obj.prop_values()[pi];
                    }
                    found_prop = true;
                    break;
                }
            }
            if (!found_prop) {
                val.set_undefined();
            }

            // Apply toJSON + replacer
            bool omit = false;
            val = json_check_property(jctx, key_hstr, val, holder, &omit);
            if (jctx.error) return -1;
            if (omit) continue;

            if (!first) {
                if (jctx.offset >= jctx.buf_size) return -1;
                jctx.buf[jctx.offset++] = ',';
            }
            first = false;

            // Indentation
            if (jctx.gap_len > 0) {
                if (jctx.offset >= jctx.buf_size) return -1;
                jctx.buf[jctx.offset++] = '\n';
                for (usz g = 0; g < jctx.indent_level * jctx.gap_len && jctx.offset < jctx.buf_size; g++) {
                    jctx.buf[jctx.offset++] = jctx.gap[g % jctx.gap_len];
                }
            }

            // Key
            char* key_data = key_hstr.get_cstr();
            uint key_len = key_hstr.blen;
            char[1024] key_buf;
            usz key_out = json_escape_string(key_data, key_len, &key_buf, 1024);
            usz copy = key_out < (jctx.buf_size - jctx.offset) ? key_out : (jctx.buf_size - jctx.offset);
            for (usz k = 0; k < copy; k++) {
                jctx.buf[jctx.offset++] = key_buf[k];
            }

            if (jctx.offset + 2 > jctx.buf_size) return -1;
            jctx.buf[jctx.offset++] = ':';
            if (jctx.gap_len > 0) {
                jctx.buf[jctx.offset++] = ' ';
            }

            // Value
            jctx.depth++;
            if (jctx.depth > JSON_MAX_DEPTH) {
                jctx.depth--;
                return -1;
            }
            int r = json_serialize_val(jctx, &val);
            jctx.depth--;
            if (r != 0) return r;
        }
    } else {
        // Snapshot property keys before iterating, so that getters that delete
        // properties don't cause keys to be skipped (ES5 §15.12.3 step 4.b).
        // We use prop_key_at(i) for i in 0..prop_count-1 — this iterates in
        // insertion order (HObject.prop_key_at walks the shape chain, returning
        // the i-th property in insertion order).
        HString*[64] snap_keys;
        uint[64]   snap_value_idx;  // prop_values index of this key
        uint snap_count = 0;
        for (uint i = 0; i < obj.prop_count && snap_count < 64; i++) {
            HString* k = (HString*)obj.prop_key_at(i);
            if (k != null) {
                snap_keys[snap_count] = k;
                snap_value_idx[snap_count] = i;
                snap_count++;
            }
        }
        // Per ES5 §15.12.3 step 4.b.ii: integer-indexed keys are output first in
        // ascending numeric order; remaining string keys follow in their original
        // order. We split into two lists, sort the integer list numerically, then
        // concatenate.
        HString*[64] int_keys;
        uint[64]   int_value_idx;
        uint int_count = 0;
        for (uint k = 0; k < snap_count; k++) {
            HString* kk = snap_keys[k];
            if (kk.is_arridx()) {
                int_keys[int_count] = kk;
                int_value_idx[int_count] = snap_value_idx[k];
                int_count++;
            }
        }
        // Compact snap_keys to keep only non-integer keys (preserving order).
        uint string_count = 0;
        for (uint k = 0; k < snap_count; k++) {
            if (!snap_keys[k].is_arridx()) {
                snap_keys[string_count] = snap_keys[k];
                snap_value_idx[string_count] = snap_value_idx[k];
                string_count++;
            }
        }
        snap_count = string_count;
        // Insertion sort the integer keys by their numeric index.
        for (uint i = 1; i < int_count; i++) {
            HString* tk = int_keys[i];
            uint     ti = int_value_idx[i];
            uint j = i;
            while (j > 0 && int_keys[j - 1].array_index() > tk.array_index()) {
                int_keys[j] = int_keys[j - 1];
                int_value_idx[j] = int_value_idx[j - 1];
                j--;
            }
            int_keys[j] = tk;
            int_value_idx[j] = ti;
        }
        // Concatenate: integer keys first (sorted), then string keys (in
        // insertion order). Use a separate buffer to avoid clobbering snap_keys.
        HString*[128] final_keys;
        uint[128]   final_value_idx;
        uint final_count = 0;
        for (uint i = 0; i < int_count; i++) {
            final_keys[final_count] = int_keys[i];
            final_value_idx[final_count] = int_value_idx[i];
            final_count++;
        }
        for (uint i = 0; i < snap_count; i++) {
            final_keys[final_count] = snap_keys[i];
            final_value_idx[final_count] = snap_value_idx[i];
            final_count++;
        }
        // Now iterate the final list.
        for (uint si = 0; si < final_count; si++) {
            HString* key_hstr = final_keys[si];
            uint pi = final_value_idx[si];
            TVal val;
            // Check if property still exists and read its value
            if (pi < obj.prop_count && obj.prop_key_at(pi) == key_hstr) {
                if (obj.get_prop_flags(pi).is_accessor) {
                    // Invoke the getter to get the property value
                    TVal getter_fn = hobject::hobject_access_getter(obj.prop_values()[pi]);
                    if (getter_fn.is_undefined() || getter_fn.is_null()) {
                        val.set_undefined();
                    } else if (jctx.heap.call_fn != null && jctx.vm != null) {
                        TVal holder_tv;
                        holder_tv.set_object(obj);
                        val = jctx.heap.call_fn(jctx.vm, getter_fn, null, 0, holder_tv);
                        if (jctx.heap.has_error) { jctx.error = true; return -1; }
                    } else {
                        continue;
                    }
                } else {
                    val = obj.prop_values()[pi];
                }
            } else {
                // Property was deleted (e.g., by a getter) — treat as undefined
                val.set_undefined();
            }

            // Apply toJSON + replacer (even without explicit replacer, this
            // handles the spec correctly — when replacer_func is undefined
            // the check just does toJSON + type unwrapping)
            bool omit = false;
            val = json_check_property(jctx, key_hstr, val, holder, &omit);
            if (jctx.error) return -1;
            if (omit) continue;

            if (!first) {
                if (jctx.offset >= jctx.buf_size) return -1;
                jctx.buf[jctx.offset++] = ',';
            }
            first = false;

            // Indentation
            if (jctx.gap_len > 0) {
                if (jctx.offset >= jctx.buf_size) return -1;
                jctx.buf[jctx.offset++] = '\n';
                for (usz g = 0; g < jctx.indent_level * jctx.gap_len && jctx.offset < jctx.buf_size; g++) {
                    jctx.buf[jctx.offset++] = jctx.gap[g % jctx.gap_len];
                }
            }

            // Key
            char* key_data = key_hstr.get_cstr();
            uint key_len = key_hstr.blen;
            char[1024] key_buf;
            usz key_out = json_escape_string(key_data, key_len, &key_buf, 1024);
            usz copy = key_out < (jctx.buf_size - jctx.offset) ? key_out : (jctx.buf_size - jctx.offset);
            for (usz k = 0; k < copy; k++) {
                jctx.buf[jctx.offset++] = key_buf[k];
            }

            if (jctx.offset + 2 > jctx.buf_size) return -1;
            jctx.buf[jctx.offset++] = ':';
            if (jctx.gap_len > 0) {
                jctx.buf[jctx.offset++] = ' ';
            }

            // Value
            jctx.depth++;
            if (jctx.depth > JSON_MAX_DEPTH) {
                jctx.depth--;
                return -1;
            }
            int rc2 = json_serialize_val(jctx, &val);
            jctx.depth--;
            if (rc2 != 0) return rc2;
        }
    }

    jctx.indent_level--;
    if (jctx.gap_len > 0) {
        if (jctx.offset >= jctx.buf_size) return -1;
        jctx.buf[jctx.offset++] = '\n';
        for (usz g = 0; g < jctx.indent_level * jctx.gap_len && jctx.offset < jctx.buf_size; g++) {
            jctx.buf[jctx.offset++] = jctx.gap[g % jctx.gap_len];
        }
    }

    if (jctx.offset >= jctx.buf_size) return -1;
    jctx.buf[jctx.offset++] = '}';
    return 0;
}

/// Serialize an array
fn int json_serialize_array(JsonSerializeCtx* jctx, HObject* arr) {
    if (jctx.error) return -1;
    if (jctx.offset >= jctx.buf_size) return -1;

    // ES5 §15.12.3 step 1: If stack contains value, throw TypeError
    if (json_stack_has(jctx, arr)) {
        json_throw_type_error(jctx, "Converting circular structure to JSON");
        return -1;
    }
    json_stack_push(jctx, arr);
    defer json_stack_pop(jctx);

    jctx.indent_level++;

    jctx.buf[jctx.offset++] = '[';

    // Create holder TVal for replacer calls
    TVal holder;
    holder.set_object(arr);

    // Check if dense array fast path is available for element reads
    bool is_dense = (arr.get_class() == ObjClass.ARRAY || arr.get_class() == ObjClass.ARGUMENTS)
                    && arr.array_part() != null;

    // Always read length from the property when possible, otherwise fall back
    // to the cached array_length pointer (used by arrays whose length is in
    // array_part rather than the named prop table, e.g. result of slice()).
    HString* len_key = builtin_intern_string(jctx.heap, "length");
    TVal? len_prop = arr.get_prop_proto(len_key);
    uint len = 0;
    if (try l = len_prop) {
        if (l.is_fastint()) {
            len = (uint)l.get_fastint();
        } else if (l.is_number()) {
            len = (uint)(long)l.get_number();
        }
        // Non-numeric length is not expected for arrays; if it occurs, len stays 0
    } else if (arr.get_class() == ObjClass.ARRAY) {
        // Cached array_length pointer (set by array_set_length for arrays
        // whose length lives in array_part, not the named prop table).
        len = (uint)*arr.array_len_ptr();
    }

    if (len == 0) {
        if (jctx.offset >= jctx.buf_size) return -1;
        jctx.buf[jctx.offset++] = ']';
        return 0;
    }

    bool first = true;
    for (uint i = 0; i < len; i++) {
        // Read element: try array_part fast path first, then fall back to prop lookup
        TVal elem;
        bool found = false;
        if (is_dense && i < arr.array_size) {
            TVal av = arr.array_part()[i];
            if (!av.is_undefined()) {
                elem = av;
                found = true;
            }
            // undefined in array_part means hole — fall through to prop lookup
        }

        // Build the index key for this element
        HString* idx_key = jctx.heap.int_to_hstring((long)i);

        if (!found) {
            TVal? elem_prop = arr.get_prop_proto(idx_key);
            if (try e = elem_prop) {
                elem = e;
                found = true;
            } else {
                elem.set_undefined();
            }
        }

        // Apply toJSON + replacer
        bool omit = false;
        elem = json_check_property(jctx, idx_key, elem, holder, &omit);
        if (jctx.error) return -1;

        if (!first) {
            if (jctx.offset >= jctx.buf_size) return -1;
            jctx.buf[jctx.offset++] = ',';
        }
        first = false;

        // Indentation
        if (jctx.gap_len > 0) {
            if (jctx.offset >= jctx.buf_size) return -1;
            jctx.buf[jctx.offset++] = '\n';
            for (usz g = 0; g < jctx.indent_level * jctx.gap_len && jctx.offset < jctx.buf_size; g++) {
                jctx.buf[jctx.offset++] = jctx.gap[g % jctx.gap_len];
            }
        }

        // null for omitted/undefined elements
        if (omit || elem.is_undefined()) {
            if (jctx.offset + 5 > jctx.buf_size) return -1;
            libc::memcpy(jctx.buf + jctx.offset, "null", 4);
            jctx.offset += 4;
        } else if (elem.is_lightfunc()) {
            if (jctx.offset + 5 > jctx.buf_size) return -1;
            libc::memcpy(jctx.buf + jctx.offset, "null", 4);
            jctx.offset += 4;
        } else if (elem.is_object() && elem.get_heapptr() != null) {
            HObject* vobj = (HObject*)elem.get_heapptr();
            if (vobj.get_class() == ObjClass.FUNCTION) {
                if (jctx.offset + 5 > jctx.buf_size) return -1;
                libc::memcpy(jctx.buf + jctx.offset, "null", 4);
                jctx.offset += 4;
            } else {
                jctx.depth++;
                if (jctx.depth > JSON_MAX_DEPTH) {
                    jctx.depth--;
                    return -1;
                }
                int r = json_serialize_val(jctx, &elem);
                jctx.depth--;
                if (r != 0) return r;
            }
        } else {
            jctx.depth++;
            if (jctx.depth > JSON_MAX_DEPTH) {
                jctx.depth--;
                return -1;
            }
            int r = json_serialize_val(jctx, &elem);
            jctx.depth--;
            if (r != 0) return r;
        }
    }

    jctx.indent_level--;
    if (jctx.gap_len > 0) {
        if (jctx.offset >= jctx.buf_size) return -1;
        jctx.buf[jctx.offset++] = '\n';
        for (usz g = 0; g < jctx.indent_level * jctx.gap_len && jctx.offset < jctx.buf_size; g++) {
            jctx.buf[jctx.offset++] = jctx.gap[g % jctx.gap_len];
        }
    }

    if (jctx.offset >= jctx.buf_size) return -1;
    jctx.buf[jctx.offset++] = ']';
    return 0;
}

/// Serialize a value to JSON
fn int json_serialize_val(JsonSerializeCtx* jctx, TVal* val) {
    switch (val.get_tag()) {
        case NULL_VAL: {
            if (jctx.offset + 5 > jctx.buf_size) return -1;
            jctx.buf[jctx.offset++] = 'n';
            jctx.buf[jctx.offset++] = 'u';
            jctx.buf[jctx.offset++] = 'l';
            jctx.buf[jctx.offset++] = 'l';
            return 0;
        }
        case BOOLEAN: {
            if (val.get_boolean()) {
                if (jctx.offset + 5 > jctx.buf_size) return -1;
                libc::memcpy(jctx.buf + jctx.offset, "true", 4);
                jctx.offset += 4;
            } else {
                if (jctx.offset + 6 > jctx.buf_size) return -1;
                libc::memcpy(jctx.buf + jctx.offset, "false", 5);
                jctx.offset += 5;
            }
            return 0;
        }
        case NUMBER: {
            double d = val.get_number();
            if (math::is_nan(d) || math::is_inf(d)) {
                if (jctx.offset + 5 > jctx.buf_size) return -1;
                libc::memcpy(jctx.buf + jctx.offset, "null", 4);
                jctx.offset += 4;
                return 0;
            }
            char[64] num_buf;
            usz num_len = json_number_to_string(d, &num_buf, 64);
            if (jctx.offset + num_len > jctx.buf_size) return -1;
            for (usz i = 0; i < num_len; i++) {
                jctx.buf[jctx.offset++] = num_buf[i];
            }
            return 0;
        }
        case FASTINT: {
            char[24] buf;
            int len = hstring::int_to_buf(val.get_fastint(), &buf, 24);
            if (len <= 0) return -1;
            if (jctx.offset + (usz)len > jctx.buf_size) return -1;
            for (int i = 0; i < len; i++) {
                jctx.buf[jctx.offset++] = buf[i];
            }
            return 0;
        }
        case STRING: {
            HString* s = (HString*)val.get_heapptr();
            char* data = s.get_cstr();
            uint slen = s.blen;
            usz max_out = (usz)(slen * 6 + 3);
            char[4096] str_buf;
            usz out_len = json_escape_string(data, slen, &str_buf, 4096);
            if (out_len == 0) return -1;
            usz copy = out_len < (jctx.buf_size - jctx.offset) ? out_len : (jctx.buf_size - jctx.offset);
            for (usz i = 0; i < copy; i++) {
                jctx.buf[jctx.offset++] = str_buf[i];
            }
            return 0;
        }
        case OBJECT: {
            if (val.get_heapptr() == null) {
                if (jctx.offset + 5 > jctx.buf_size) return -1;
                libc::memcpy(jctx.buf + jctx.offset, "null", 4);
                jctx.offset += 4;
                return 0;
            }
            HObject* obj = (HObject*)val.get_heapptr();
            if (obj.get_class() == ObjClass.ARRAY) {
                return json_serialize_array(jctx, obj);
            } else if (obj.get_class() == ObjClass.FUNCTION) {
                // Functions serialize as null in JSON
                if (jctx.offset + 5 > jctx.buf_size) return -1;
                libc::memcpy(jctx.buf + jctx.offset, "null", 4);
                jctx.offset += 4;
                return 0;
            } else {
                return json_serialize_object(jctx, obj);
            }
        }
        case LIGHTFUNC: {
            // Functions serialize as null
            if (jctx.offset + 5 > jctx.buf_size) return -1;
            libc::memcpy(jctx.buf + jctx.offset, "null", 4);
            jctx.offset += 4;
            return 0;
        }
        case UNDEFINED:
        case BUFFER:
        case POINTER:
        default:
            // Undefined, Buffer, Pointer -> serialize as null
            if (jctx.offset + 5 > jctx.buf_size) return -1;
            libc::memcpy(jctx.buf + jctx.offset, "null", 4);
            jctx.offset += 4;
            return 0;
    }
}

/// JSON.stringify(value [, replacer [, space]]) — ES5 §15.12.3
fn void builtin_json_stringify(BuiltinContext* ctx) {
    // Clear any stale error flag and value
    ctx.heap.has_error = false;
    ctx.heap.error_value.set_undefined();
    // Get the value
    if (ctx.argc < 1) {
        ctx.result.set_undefined();
        return;
    }
    TVal value = ctx.regs[ctx.base_reg];

    // Process replacer argument
    TVal replacer_func;
    replacer_func.set_undefined();
    HString** prop_keys = null;
    uint prop_key_count = 0;
    bool has_replacer_array_flag = false;

    if (ctx.argc > 1) {
        TVal replacer = ctx.regs[ctx.base_reg + 1];

        if (replacer.is_object() && replacer.get_heapptr() != null) {
            HObject* robj = (HObject*)replacer.get_heapptr();
            if (robj.is_callable()) {
                replacer_func = replacer;
            } else if (robj.get_class() == ObjClass.ARRAY) {
                // Build PropertyList from array elements
                // Max 256 keys in property list
                HString*[256] temp_keys;
                uint count = 0;
                has_replacer_array_flag = true;

                // Get length
                HString* len_key = builtin_intern_string(ctx.heap, "length");
                TVal? len_prop = robj.get_prop_proto(len_key);
                uint arr_len = 0;
                if (try l = len_prop) {
                    if (l.is_fastint()) {
                        arr_len = (uint)l.get_fastint();
                    } else if (l.is_number()) {
                        arr_len = (uint)(long)l.get_number();
                    }
                }


                bool is_dense = robj.get_class() == ObjClass.ARRAY && robj.array_part() != null;

                for (uint i = 0; i < arr_len && count < 256; i++) {
                    // Read element: try dense array fast path, then prop lookup
                    TVal elem;
                    bool found = false;
                    if (is_dense && i < robj.array_size) {
                        TVal av = robj.array_part()[i];
                        if (!av.is_undefined()) {
                            elem = av;
                            found = true;
                        }
                    }
                    if (!found) {
                        HString* idx_key = ctx.heap.int_to_hstring((long)i);
                        if (idx_key == null) continue;
                        TVal? elem_opt = robj.get_prop_proto(idx_key);
                        if (try e = elem_opt) {
                            elem = e;
                            found = true;
                        }
                    }
                    if (!found) continue;

                    // Convert to string key per spec:
                    // String → use as-is
                    // Number → ToString
                    // String object → ToString (via .toString())
                    // Number object → ToString (via .toString())
                    // Everything else → skip
                    HString* str_key = null;

                    if (elem.is_string()) {
                        str_key = (HString*)elem.get_heapptr();
                    } else if (elem.is_fastint()) {
                        str_key = ctx.heap.int_to_hstring(elem.get_fastint());
                    } else if (elem.is_number()) {
                        char[64] num_buf;
                        usz num_len = json_number_to_string(elem.get_number(), &num_buf, 64);
                        str_key = builtin_intern_string(ctx.heap, num_buf[:num_len]);
                    } else if (elem.is_object() && elem.get_heapptr() != null) {
                        HObject* eobj = (HObject*)elem.get_heapptr();
                        if (eobj.get_class() == ObjClass.STRING) {
                            // ToString(value): call toString() to respect overrides
                            HString* ts_key = (HString*)ctx.heap.strs[heap::BuiltinStr.TO_STRING];
                            if (ts_key != null) {
                                TVal? toString_fn_opt = eobj.get_prop_proto(ts_key);
                                if (try toString_fn = toString_fn_opt) {
                                    bool callable = false;
                                    if (toString_fn.is_object() && toString_fn.get_heapptr() != null) {
                                        callable = ((HObject*)toString_fn.get_heapptr()).is_callable();
                                    } else if (toString_fn.is_lightfunc()) {
                                        callable = true;
                                    }
                                    if (callable && ctx.heap.call_fn != null && ctx.vm != null) {
                                        TVal res = ctx.heap.call_fn(ctx.vm, toString_fn, null, 0, elem);
                                        if (ctx.heap.has_error) { ctx.should_throw = true; if (prop_keys != null) ctx.heap.free_func(ctx.heap.heap_udata, prop_keys); return; }
                                        else if (res.is_string()) {
                                            str_key = (HString*)res.get_heapptr();
                                        }
                                    }
                                }
                            }
                            // Fallback: primitive value
                            if (str_key == null && (*eobj.extra_ptr()).prim.primitive_value.is_string()) {
                                str_key = (HString*)(*eobj.extra_ptr()).prim.primitive_value.get_heapptr();
                            }
                        } else if (eobj.get_class() == ObjClass.NUMBER) {
                            // ToString(value): call toString() to respect overrides
                            HString* ts_key = (HString*)ctx.heap.strs[heap::BuiltinStr.TO_STRING];
                            if (ts_key != null) {
                                TVal? toString_fn_opt = eobj.get_prop_proto(ts_key);
                                if (try toString_fn = toString_fn_opt) {
                                    bool callable = false;
                                    if (toString_fn.is_object() && toString_fn.get_heapptr() != null) {
                                        callable = ((HObject*)toString_fn.get_heapptr()).is_callable();
                                    } else if (toString_fn.is_lightfunc()) {
                                        callable = true;
                                    }
                                    if (callable && ctx.heap.call_fn != null && ctx.vm != null) {
                                        TVal res = ctx.heap.call_fn(ctx.vm, toString_fn, null, 0, elem);
                                        if (ctx.heap.has_error) { ctx.should_throw = true; if (prop_keys != null) ctx.heap.free_func(ctx.heap.heap_udata, prop_keys); return; }
                                        else if (res.is_string()) {
                                            str_key = (HString*)res.get_heapptr();
                                        } else if (res.is_fastint() || res.is_number()) {
                                            char[64] nb;
                                            usz nl = json_number_to_string(
                                                res.is_fastint() ? (double)res.get_fastint() : res.get_number(), &nb, 64);
                                            str_key = builtin_intern_string(ctx.heap, nb[:nl]);
                                        }
                                    }
                                }
                            }
                            // Fallback: primitive value
                            if (str_key == null) {
                                TVal pv = (*eobj.extra_ptr()).prim.primitive_value;
                                if (pv.is_fastint()) {
                                    str_key = ctx.heap.int_to_hstring(pv.get_fastint());
                                } else if (pv.is_number()) {
                                    char[64] num_buf;
                                    usz num_len = json_number_to_string(pv.get_number(), &num_buf, 64);
                                    str_key = builtin_intern_string(ctx.heap, num_buf[:num_len]);
                                }
                            }
                        }
                    }

                    if (str_key == null) continue;

                    // Deduplicate: check if already in list
                    bool dup = false;
                    for (uint d = 0; d < count; d++) {
                        if (temp_keys[d] == str_key) { dup = true; break; }
                    }
                    if (dup) continue;

                    temp_keys[count] = str_key;
                    count++;
                }

                if (count > 0) {
                    prop_keys = (HString**)ctx.heap.alloc_func(ctx.heap.heap_udata, count * HString*::size);
                    if (prop_keys != null) {
                        libc::memcpy(prop_keys, &temp_keys[0], count * HString*::size);
                        prop_key_count = count;
                    }
                }

            }
        }
        // Non-callable, non-array replacer → ignore (leave replacer_func undefined)
    }

    // Check space parameter — unwrap Number/String wrappers
    uint space_num = 0;
    char[16] gap_buf;
    usz gap_len = 0;

    if (ctx.argc > 2) {
        TVal space_arg = ctx.regs[ctx.base_reg + 2];

        // Unwrap Number/String wrapper objects via ToString/ToNumber per spec
        if (space_arg.is_object() && space_arg.get_heapptr() != null) {
            HObject* sobj = (HObject*)space_arg.get_heapptr();
            if (sobj.get_class() == ObjClass.NUMBER) {
                // ToNumber(space) → call valueOf()
                HString* vo_key = (HString*)ctx.heap.strs[heap::BuiltinStr.VALUE_OF];
                if (vo_key != null) {
                    TVal? vo_opt = sobj.get_prop_proto(vo_key);
                    if (try vo_fn = vo_opt) {
                        bool callable = false;
                        if (vo_fn.is_object() && vo_fn.get_heapptr() != null) {
                            callable = ((HObject*)vo_fn.get_heapptr()).is_callable();
                        } else if (vo_fn.is_lightfunc()) {
                            callable = true;
                        }
                        if (callable && ctx.heap.call_fn != null && ctx.vm != null) {
                            TVal res = ctx.heap.call_fn(ctx.vm, vo_fn, null, 0, space_arg);
                            if (ctx.heap.has_error) {
                                ctx.throw_value = ctx.heap.error_value;
                                ctx.heap.has_error = false;
                                ctx.should_throw = true;
                                if (prop_keys != null) ctx.heap.free_func(ctx.heap.heap_udata, prop_keys);
                                return;
                            }
                            else { space_arg = res; }
                        }
                    }
                }
                if (space_arg.is_object() && space_arg.get_heapptr() != null) {
                    space_arg = (*sobj.extra_ptr()).prim.primitive_value;
                }
            } else if (sobj.get_class() == ObjClass.STRING) {
                // ToString(space) → call toString()
                HString* ts_key = (HString*)ctx.heap.strs[heap::BuiltinStr.TO_STRING];
                if (ts_key != null) {
                    TVal? ts_opt = sobj.get_prop_proto(ts_key);
                    if (try ts_fn = ts_opt) {
                        bool callable = false;
                        if (ts_fn.is_object() && ts_fn.get_heapptr() != null) {
                            callable = ((HObject*)ts_fn.get_heapptr()).is_callable();
                        } else if (ts_fn.is_lightfunc()) {
                            callable = true;
                        }
                        if (callable && ctx.heap.call_fn != null && ctx.vm != null) {
                            TVal res = ctx.heap.call_fn(ctx.vm, ts_fn, null, 0, space_arg);
                            if (ctx.heap.has_error) {
                                ctx.throw_value = ctx.heap.error_value;
                                ctx.heap.has_error = false;
                                ctx.should_throw = true;
                                if (prop_keys != null) ctx.heap.free_func(ctx.heap.heap_udata, prop_keys);
                                return;
                            }
                            else { space_arg = res; }
                        }
                    }
                }
                if (space_arg.is_object() && space_arg.get_heapptr() != null &&
                    (*sobj.extra_ptr()).prim.primitive_value.is_string()) {
                    space_arg = (*sobj.extra_ptr()).prim.primitive_value;
                }
            }
        }

        if (space_arg.is_fastint()) {
            // ES5 §15.12.3 step 6: min(10, ToInteger(space)); if < 1, gap is empty
            long si = space_arg.get_fastint();
            if (si < 0) si = 0;
            if (si > 10) si = 10;
            space_num = (uint)si;
        } else if (space_arg.is_number()) {
            long si = (long)space_arg.get_number();
            if (si < 0) si = 0;
            if (si > 10) si = 10;
            space_num = (uint)si;
        } else if (space_arg.is_string()) {
            HString* s = (HString*)space_arg.get_heapptr();
            char* data = s.get_cstr();
            uint slen = s.blen;
            if (slen > 10) slen = 10;
            for (uint i = 0; i < slen; i++) {
                gap_buf[i] = data[i];
            }
            gap_len = slen;
        }
    }

    // Build gap string
    char[16] gap_str;
    if (space_num > 0) {
        gap_len = space_num;
        for (uint i = 0; i < gap_len && i < 16; i++) {
            gap_str[i] = ' ';
        }
    } else if (gap_len > 0) {
        // String gap: copy from gap_buf to gap_str
        for (usz i = 0; i < gap_len && i < 16; i++) {
            gap_str[i] = gap_buf[i];
        }
    }

    // Apply root-level toJSON + replacer per spec:
    // 1. Create wrapper = { "": value }
    // 2. If ReplacerFunction: value = Call(replacer, wrapper, ["", value])
    // 3. Process the result

    // Create wrapper object
    HObject*? wrapper_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch werr = wrapper_raw) {
        ctx.result.set_undefined();
        if (prop_keys != null) ctx.heap.free_func(ctx.heap.heap_udata, prop_keys);
        return;
    }
    HObject* wrapper = wrapper_raw;
    wrapper.prototype = ctx.heap.object_proto;

    TVal wrapper_tv;
    wrapper_tv.set_object(wrapper);

    // Set wrapper[""] = value
    HString* empty_key = builtin_intern_string(ctx.heap, "");
    wrapper.put_prop(empty_key, value, hobject::PROP_FLAGS_WEC);

    // Initialize serialization context
    char[16384] buf;
    JsonSerializeCtx jctx;
    jctx.heap = ctx.heap;
    jctx.vm = ctx.vm;
    jctx.buf = &buf;
    jctx.buf_size = 16384;
    jctx.offset = 0;
    jctx.indent_level = 0;
    jctx.gap = &gap_str;
    jctx.gap_len = gap_len;
    jctx.depth = 0;
    jctx.replacer_func = replacer_func;
    jctx.prop_keys = prop_keys;
    jctx.prop_key_count = prop_key_count;
    jctx.has_replacer_array = has_replacer_array_flag;

    // Apply root-level check: get value from wrapper, apply toJSON + replacer
    bool root_omit = false;
    TVal root_val = json_check_property(&jctx, empty_key, value, wrapper_tv, &root_omit);

    if (jctx.error || ctx.heap.has_error) {
        ctx.should_throw = true;
        ctx.throw_value = ctx.heap.error_value;
        ctx.heap.has_error = false;
        if (prop_keys != null) ctx.heap.free_func(ctx.heap.heap_udata, prop_keys);
        return;
    }

    if (root_omit) {
        ctx.result.set_undefined();
        if (prop_keys != null) ctx.heap.free_func(ctx.heap.heap_udata, prop_keys);
        return;
    }

    // Serialize the processed value
    int result = json_serialize_val(&jctx, &root_val);

    if (jctx.error || ctx.heap.has_error) {
        ctx.should_throw = true;
        ctx.throw_value = ctx.heap.error_value;
        ctx.heap.has_error = false;
        if (prop_keys != null) ctx.heap.free_func(ctx.heap.heap_udata, prop_keys);
        return;
    }

    if (prop_keys != null) ctx.heap.free_func(ctx.heap.heap_udata, prop_keys);

    if (result != 0) {
        ctx.result.set_undefined();
        return;
    }

    HString* result_str = builtin_intern_string(ctx.heap, buf[:jctx.offset]);
    ctx.result.set_string(result_str);
}
fn bool register_json_object(EnvRecord* global_env, Heap* heap) {
    HObject*? json_raw = heap.alloc_object(hobject::ObjClass.JSON);
    if (catch err = json_raw) return false;
    HObject* json = json_raw;
    json.prototype = heap.object_proto;

    // Register JSON.parse
    if (!register_math_method(json, heap, "parse", BUILTIN_JSON_PARSE)) return false;
    // Register JSON.stringify
    if (!register_math_method(json, heap, "stringify", BUILTIN_JSON_STRINGIFY)) return false;

    // Set @@toStringTag on JSON
    HString* tag_key = ensure_tostringtag_symbol(heap);
    if (tag_key != null) {
        TVal tag_tv;
        tag_tv.set_string(builtin_intern_string(heap, "JSON"));
        json.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC);
    }

    TVal json_tv;
    json_tv.set_object(null);
    json_tv.set_fastint(0);
    json_tv.set_object(json);
    return register_named_value(global_env, heap, "JSON", json_tv);
}

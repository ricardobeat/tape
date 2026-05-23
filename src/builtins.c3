/// Built-in function registry for the Duktape C3 port.
module duktape::builtins;

import duktape::types;
import duktape::hstring;
import duktape::hobject;
import duktape::heap;
import duktape::env;
import std::io;
import std::math;
import libc;

const uint BUILTIN_PRINT       = 0;
const uint BUILTIN_CONSOLE_LOG = 1;
const uint BUILTIN_PARSE_INT   = 2;
const uint BUILTIN_PARSE_FLOAT = 3;
const uint BUILTIN_IS_NAN      = 4;
const uint BUILTIN_IS_FINITE   = 5;
const uint BUILTIN_ERROR           = 6;
const uint BUILTIN_TYPE_ERROR      = 7;
const uint BUILTIN_RANGE_ERROR     = 8;
const uint BUILTIN_REFERENCE_ERROR = 9;
const uint BUILTIN_SYNTAX_ERROR    = 10;
const uint BUILTIN_EVAL_ERROR      = 11;
const uint BUILTIN_ERROR_PROTO_TOSTRING = 12;
const uint BUILTIN_BOOLEAN                 = 13;
const uint BUILTIN_BOOLEAN_PROTO_TOSTRING  = 14;
const uint BUILTIN_BOOLEAN_PROTO_VALUEOF   = 15;
const uint BUILTIN_STRING                 = 16;
const uint BUILTIN_STRING_PROTO_TOSTRING  = 17;
const uint BUILTIN_STRING_PROTO_VALUEOF   = 18;
const uint BUILTIN_NUMBER                 = 19;
const uint BUILTIN_NUMBER_PROTO_TOSTRING  = 20;
const uint BUILTIN_NUMBER_PROTO_VALUEOF   = 21;
const uint BUILTIN_OBJECT                  = 22;
const uint BUILTIN_OBJECT_PROTO_TOSTRING   = 23;
const uint BUILTIN_OBJECT_PROTO_VALUEOF    = 24;
const uint BUILTIN_ARRAY                   = 25;
const uint BUILTIN_COUNT                   = 26;

struct BuiltinContext {
    void* vm;
    TVal* regs;
    ushort base_reg;
    ushort argc;
    TVal* result;
    Heap* heap;
    TVal  this_val;
    bool  is_constructor;
}

alias BuiltinFunc = fn void(BuiltinContext*);

fn void print_tval(TVal* val) {
    switch (val.tag) {
        case UNDEFINED:
            io::printf("undefined");
        case NULL_VAL:
            io::printf("null");
        case BOOLEAN:
            if (val.boolean) {
                io::printf("true");
            } else {
                io::printf("false");
            }
        case NUMBER:
            double v = val.number;
            if (math::is_nan(v)) {
                io::printf("NaN");
            } else if (math::is_inf(v)) {
                if (v > 0) { io::printf("Infinity"); } else { io::printf("-Infinity"); }
            } else {
                long iv = (long)v;
                if ((double)iv == v && iv >= -9007199254740991 && iv <= 9007199254740991) {
                    io::printf("%d", iv);
                } else {
                    io::printf("%f", v);
                }
            }
        case FASTINT:
            io::printf("%d", val.fastint);
        case STRING:
            HString* s = (HString*)val.pointer;
            if (s != null) {
                char[] d = s.get_data();
                for (usz i = 0; i < d.len; i++) {
                    io::putchar(d[i]);
                }
            } else {
                io::printf("[null string]");
            }
        case OBJECT:
            io::printf("[object Object]");
        case LIGHTFUNC:
            io::printf("[function]");
        default:
            io::printf("[unknown]");
    }
}

fn void builtin_print(BuiltinContext* ctx) {
    for (ushort i = 0; i < ctx.argc; i++) {
        if (i > 0) {
            io::putchar(' ');
        }
        print_tval(&ctx.regs[ctx.base_reg + i]);
    }
    io::putchar('\n');
    ctx.result.tag = UNDEFINED;
    ctx.result.pointer = null;
}

fn void builtin_console_log(BuiltinContext* ctx) {
    for (ushort i = 0; i < ctx.argc; i++) {
        if (i > 0) {
            io::putchar(' ');
        }
        print_tval(&ctx.regs[ctx.base_reg + i]);
    }
    io::putchar('\n');
    ctx.result.tag = UNDEFINED;
    ctx.result.pointer = null;
}

fn double string_to_double(TVal* val) {
    if (val.tag == FASTINT) return (double)val.fastint;
    if (val.tag == NUMBER) return val.number;
    if (val.tag == STRING) {
        HString* h = (HString*)val.pointer;
        if (h == null || h.blen == 0) return double::nan;
        char* end;
        double r = libc::strtod((ZString)h.get_cstr(), &end);
        if (end == h.get_cstr()) return double::nan;
        return r;
    }
    return double::nan;
}

// ============================================================================
// ECMAScript whitespace check (ASCII subset)
// ============================================================================

/// ECMAScript whitespace (ASCII subset: Tab, VT, FF, Space, NBSP, LF, CR).
fn bool is_ecma_whitespace(char c) @inline {
    return c == 0x09 || c == 0x0B || c == 0x0C
        || c == 0x20 || c == 0xA0
        || c == 0x0A || c == 0x0D;
}

/// ECMAScript ToNumber for strings (§7.1.3.1).
///
/// Converts an HString* to a double, trimming ECMAScript whitespace and
/// parsing numeric literals (decimal, hex, Infinity).  Returns NaN when
/// the string does not represent a valid numeric literal.
fn double builtin_string_to_number(HString* hstr) {
    char* cstr = hstr.get_cstr();
    uint blen = hstr.blen;

    // --- skip leading ECMAScript whitespace ---
    uint start = 0;
    while (start < blen && is_ecma_whitespace(cstr[start])) {
        start++;
    }

    // Empty or all-whitespace -> +0
    if (start == blen) {
        return 0.0;
    }

    char* p = cstr + start;

    // --- Infinity / -Infinity / +Infinity ---
    if (libc::strcmp((ZString)p, "Infinity") == 0)   return double::inf;
    if (libc::strcmp((ZString)p, "+Infinity") == 0)  return double::inf;
    if (libc::strcmp((ZString)p, "-Infinity") == 0)  return -double::inf;

    // --- Hex integer literal (0x...) ---
    if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) {
        uint j = 2;
        ulong val = 0;
        while (p[j] != 0) {
            char c = p[j];
            uint digit;
            if      (c >= '0' && c <= '9') { digit = (uint)(c - '0'); }
            else if (c >= 'a' && c <= 'f') { digit = (uint)(c - 'a' + 10); }
            else if (c >= 'A' && c <= 'F') { digit = (uint)(c - 'A' + 10); }
            else { break; }   // non-hex terminates the literal

            val = (val << 4) | digit;
            j++;
        }
        // Trailing must be whitespace
        while (p[j] != 0) {
            if (!is_ecma_whitespace(p[j])) return double::nan;
            j++;
        }
        return (double)val;
    }

    // --- Decimal via libc::strtod ---
    char* endptr;
    double result = libc::strtod(p, &endptr);

    // Nothing was consumed -> NaN
    if (endptr == p) {
        return double::nan;
    }

    // Trailing characters must be whitespace only
    while (*endptr != 0) {
        if (!is_ecma_whitespace(*endptr)) {
            return double::nan;
        }
        endptr++;
    }

    return result;
}

// ============================================================================
// ToNumber (ES5 §9.3)
// ============================================================================

/// Convert any TVal to a numeric TVal per ES5 §9.3.
/// Preserves FASTINT where possible.
fn void builtin_to_number(TVal* val, TVal* result) {
    switch (val.tag) {
        case UNDEFINED:
            result.tag = NUMBER;
            result.number = double::nan;
            return;
        case NULL_VAL:
            result.tag = FASTINT;
            result.fastint = 0;
            return;
        case BOOLEAN:
            result.tag = FASTINT;
            result.fastint = val.boolean ? 1 : 0;
            return;
        case NUMBER:
            *result = *val;
            return;
        case FASTINT:
            *result = *val;
            return;
        case STRING: {
            double d = builtin_string_to_number((HString*)val.pointer);
            // Try fastint preservation
            long fi = (long)d;
            if ((double)fi == d && fi >= -9007199254740991 && fi <= 9007199254740991) {
                result.tag = FASTINT;
                result.fastint = fi;
                return;
            }
            result.tag = NUMBER;
            result.number = d;
            return;
        }
        case OBJECT: {
            // For wrapper objects, unwrap via ToPrimitive
            TVal prim = to_primitive_value_local(val);
            if (prim.tag != OBJECT) {
                builtin_to_number(&prim, result);
                return;
            }
            // Non-wrapper objects -> NaN
            result.tag = NUMBER;
            result.number = double::nan;
            return;
        }
        default:
            result.tag = NUMBER;
            result.number = double::nan;
            return;
    }
}

/// Simplified ToPrimitive for builtins — unwraps Boolean/Number/String wrapper objects.
fn TVal to_primitive_value_local(TVal* val) {
    if (val.tag == OBJECT && val.pointer != null) {
        HObject* obj = (HObject*)val.pointer;
        hobject::ObjClass cls = obj.get_class();
        if (cls == hobject::ObjClass.BOOLEAN &&
            obj.primitive_value.tag == BOOLEAN) {
            TVal result;
            result.tag = BOOLEAN;
            result.boolean = obj.primitive_value.boolean;
            return result;
        }
        if (cls == hobject::ObjClass.NUMBER &&
            (obj.primitive_value.tag == NUMBER || obj.primitive_value.tag == FASTINT)) {
            TVal result;
            result.tag = obj.primitive_value.tag;
            result.number = obj.primitive_value.number;
            return result;
        }
        if (cls == hobject::ObjClass.STRING &&
            obj.primitive_value.tag == STRING) {
            TVal result;
            result.tag = STRING;
            result.pointer = obj.primitive_value.pointer;
            return result;
        }
    }
    return *val;
}

fn void builtin_parse_int(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.tag = NUMBER;
        ctx.result.number = double::nan;
        return;
    }
    TVal* arg = &ctx.regs[ctx.base_reg];
    if (arg.tag == FASTINT) {
        ctx.result.tag = FASTINT;
        ctx.result.fastint = arg.fastint;
        return;
    }
    if (arg.tag != STRING) {
        ctx.result.tag = NUMBER;
        ctx.result.number = double::nan;
        return;
    }
    HString* h = (HString*)arg.pointer;
    if (h == null || h.blen == 0) {
        ctx.result.tag = NUMBER;
        ctx.result.number = double::nan;
        return;
    }
    char* cstr = h.get_cstr();
    // Skip leading whitespace
    char* p = cstr;
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;

    int radix;
    if (ctx.argc > 1) {
        TVal* rad_arg = &ctx.regs[ctx.base_reg + 1];
        radix = (int)(rad_arg.tag == FASTINT ? rad_arg.fastint : rad_arg.number);
    } else {
        radix = 0;  // auto-detect (0x = hex, 0 = octal legacy, else decimal)
    }

    char* end;
    long result = libc::strtol(p, &end, radix);
    if (end == cstr) {
        ctx.result.tag = NUMBER;
        ctx.result.number = double::nan;
        return;
    }
    ctx.result.tag = FASTINT;
    ctx.result.fastint = result;
}

fn void builtin_parse_float(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.tag = NUMBER;
        ctx.result.number = double::nan;
        return;
    }
    double d = string_to_double(&ctx.regs[ctx.base_reg]);
    ctx.result.tag = NUMBER;
    ctx.result.number = d;
}

fn void builtin_is_nan(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.tag = BOOLEAN;
        ctx.result.boolean = false;
        return;
    }
    double d = string_to_double(&ctx.regs[ctx.base_reg]);
    ctx.result.tag = BOOLEAN;
    ctx.result.boolean = math::is_nan(d);
}

fn void builtin_is_finite(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.tag = BOOLEAN;
        ctx.result.boolean = false;
        return;
    }
    double d = string_to_double(&ctx.regs[ctx.base_reg]);
    ctx.result.tag = BOOLEAN;
    ctx.result.boolean = !math::is_nan(d) && !math::is_inf(d);
}

// ============================================================================
// ToBoolean (ES5 §9.2)
// ============================================================================

fn bool builtin_to_boolean(TVal* val) {
    switch (val.tag) {
        case UNDEFINED:
        case NULL_VAL:
            return false;
        case BOOLEAN:
            return val.boolean;
        case NUMBER:
            return !math::is_nan(val.number) && val.number != 0.0;
        case FASTINT:
            return val.fastint != 0;
        case STRING: {
            HString* s = (HString*)val.pointer;
            return s != null && s.blen > 0;
        }
        case OBJECT:
        case LIGHTFUNC:
        case BUFFER:
        case POINTER:
            return true;
        default:
            return false;
    }
}

// ============================================================================
// Intern helper (mirrors vm.c3 intern_string but needs only Heap)
// ============================================================================

fn HString* builtin_intern_string(Heap* heap, char[] data) {
    uint hash = heap.hash_string(data);
    HString* existing = heap.str_table_lookup(data, hash);
    if (existing != null) {
        return existing;
    }
    HString*? new_s = hstring::hstring_alloc(heap, data, hash);
    if (try s = new_s) {
        heap.str_table_insert(s);
        return s;
    }
    return null;
}

// ============================================================================
// ToString helper (ES3 ToString for primitive types)
// ============================================================================

fn HString* builtin_to_string(Heap* heap, TVal* val) {
    switch (val.tag) {
        case STRING:
            return (HString*)val.pointer;
        case NUMBER: {
            char[64] buf;
            int len = libc::snprintf(&buf, 64, "%.17g", val.number);
            if (len < 0 || len >= 64) return null;
            return builtin_intern_string(heap, buf[:len]);
        }
        case FASTINT: {
            char[64] buf;
            int len = libc::snprintf(&buf, 64, "%ld", (long)val.fastint);
            if (len < 0 || len >= 64) return null;
            return builtin_intern_string(heap, buf[:len]);
        }
        case BOOLEAN:
            return builtin_intern_string(heap, val.boolean ? "true" : "false");
        case UNDEFINED:
            return builtin_intern_string(heap, "undefined");
        case NULL_VAL:
            return builtin_intern_string(heap, "null");
        case OBJECT:
            return builtin_intern_string(heap, "[object Object]");
        case LIGHTFUNC:
            return builtin_intern_string(heap, "[function]");
        default:
            return null;
    }
}

// ============================================================================
// Error constructor builtins
// ============================================================================

/// Shared constructor: create an error object with ObjClass.ERROR,
/// set prototype to `proto`, and set .message from args[0] if provided.
fn void builtin_error_constructor_shared(BuiltinContext* ctx, HObject* proto) {
    HObject*? err_raw = hobject::hobject_alloc(ctx.heap, hobject::ObjClass.ERROR);
    if (catch err = err_raw) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }
    HObject* err = err_raw;
    err.prototype = proto;

    // Set .message if first arg is provided and not undefined
    if (ctx.argc > 0) {
        TVal* msg_arg = &ctx.regs[ctx.base_reg];
        if (msg_arg.tag != UNDEFINED) {
            HString* msg_str = builtin_to_string(ctx.heap, msg_arg);
            if (msg_str != null) {
                TVal msg_val;
                msg_val.tag = STRING;
                msg_val.pointer = msg_str;
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
            }
        }
    }

    ctx.result.tag = OBJECT;
    ctx.result.fastint = 0;
    ctx.result.pointer = err;
}

fn void builtin_error(BuiltinContext* ctx) {
    builtin_error_constructor_shared(ctx, ctx.heap.err_proto);
}

fn void builtin_type_error(BuiltinContext* ctx) {
    builtin_error_constructor_shared(ctx, ctx.heap.type_err_proto);
}

fn void builtin_range_error(BuiltinContext* ctx) {
    builtin_error_constructor_shared(ctx, ctx.heap.range_err_proto);
}

fn void builtin_reference_error(BuiltinContext* ctx) {
    builtin_error_constructor_shared(ctx, ctx.heap.ref_err_proto);
}

fn void builtin_syntax_error(BuiltinContext* ctx) {
    builtin_error_constructor_shared(ctx, ctx.heap.syntax_err_proto);
}

fn void builtin_eval_error(BuiltinContext* ctx) {
    builtin_error_constructor_shared(ctx, ctx.heap.eval_err_proto);
}

// ============================================================================
// Error.prototype.toString — returns "name: message" per ES5 §15.11.4.4
// ============================================================================

fn void builtin_error_prototype_to_string(BuiltinContext* ctx) {
    // Get 'this' value (stored at base_reg - 1 in the value stack)
    TVal this_val = ctx.regs[ctx.base_reg - 1];

    // Default name is "Error"
    HString* name_str = builtin_intern_string(ctx.heap, "Error");
    HString* msg_str  = builtin_intern_string(ctx.heap, "");

    if (this_val.tag == OBJECT && this_val.pointer != null) {
        HObject* obj = (HObject*)this_val.pointer;

        // Read .name property
        HString* name_key = builtin_intern_string(ctx.heap, "name");
        TVal? name_prop = obj.get_prop_proto(name_key);
        if (try nv = name_prop) {
            io::eprintfn("DEBUG toString: name found tag=%d", nv.tag);
            if (!nv.is_undefined()) {
                HString* tmp = builtin_to_string(ctx.heap, &nv);
                if (tmp != null) name_str = tmp;
            }
        }

        // Read .message property
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        TVal? msg_prop = obj.get_prop_proto(msg_key);
        if (try mv = msg_prop) {
            if (!mv.is_undefined()) {
                HString* tmp = builtin_to_string(ctx.heap, &mv);
                if (tmp != null) {
                    msg_str = tmp;
                }
            }
        }
    }
    if (name_str.blen == 0) {
        ctx.result.tag = STRING;
        ctx.result.pointer = msg_str;
    } else if (msg_str.blen == 0) {
        ctx.result.tag = STRING;
        ctx.result.pointer = name_str;
    } else {
        // Format: "name: message"
        usz total = (usz)name_str.blen + 2 + (usz)msg_str.blen;
        char[256] buf;
        char* name_cstr = name_str.get_cstr();
        char* msg_cstr = msg_str.get_cstr();
        int len = libc::snprintf(&buf, 256, "%s: %s", name_cstr, msg_cstr);
        if (len > 0 && len < 256) {
            HString* result_str = builtin_intern_string(ctx.heap, buf[:len]);
            ctx.result.tag = STRING;
            ctx.result.pointer = result_str;
        } else {
            ctx.result.tag = UNDEFINED;
            ctx.result.pointer = null;
        }
    }
}

// ============================================================================
// Boolean constructor builtins
// ============================================================================

/// ToBoolean then return boolean primitive (function call) or
/// a Boolean wrapper object (constructor call).
fn void builtin_boolean(BuiltinContext* ctx) {
    bool b;
    if (ctx.argc > 0) {
        b = builtin_to_boolean(&ctx.regs[ctx.base_reg]);
    } else {
        b = false;
    }

    if (ctx.is_constructor) {
        HObject*? obj_raw = hobject::hobject_alloc(ctx.heap, hobject::ObjClass.BOOLEAN);
        if (catch err = obj_raw) {
            ctx.result.tag = UNDEFINED;
            ctx.result.pointer = null;
            return;
        }
        HObject* obj = obj_raw;
        obj.prototype = ctx.heap.bool_proto;
        obj.primitive_value.tag = BOOLEAN;
        obj.primitive_value.boolean = b;
        ctx.result.tag = OBJECT;
        ctx.result.pointer = obj;
    } else {
        ctx.result.tag = BOOLEAN;
        ctx.result.boolean = b;
    }
}

/// Boolean.prototype.toString — returns "true" or "false"
fn void builtin_boolean_proto_toString(BuiltinContext* ctx) {
    // 'this' is at base_reg - 1
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    bool b = false;
    if (this_val.tag == OBJECT && this_val.pointer != null) {
        HObject* obj = (HObject*)this_val.pointer;
        if (obj.get_class() == hobject::ObjClass.BOOLEAN &&
            obj.primitive_value.tag == BOOLEAN) {
            b = obj.primitive_value.boolean;
        }
    } else if (this_val.tag == BOOLEAN) {
        b = this_val.boolean;
    }
    HString* s = builtin_intern_string(ctx.heap, b ? "true" : "false");
    ctx.result.tag = STRING;
    ctx.result.pointer = s;
}

/// Boolean.prototype.valueOf — returns the wrapped boolean value
// ============================================================================
// String constructor builtins
// ============================================================================

/// ToString then return string primitive (function call) or
/// a String wrapper object (constructor call).
fn void builtin_string(BuiltinContext* ctx) {
    HString* s;
    if (ctx.argc > 0) {
        s = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg]);
    } else {
        s = builtin_intern_string(ctx.heap, "");
    }

    if (ctx.is_constructor) {
        HObject*? obj_raw = hobject::hobject_alloc(ctx.heap, hobject::ObjClass.STRING);
        if (catch err = obj_raw) {
            ctx.result.tag = UNDEFINED;
            ctx.result.pointer = null;
            return;
        }
        HObject* obj = obj_raw;
        obj.prototype = ctx.heap.string_proto;
        obj.primitive_value.tag = STRING;
        obj.primitive_value.pointer = s;
        ctx.result.tag = OBJECT;
        ctx.result.pointer = obj;
    } else {
        ctx.result.tag = STRING;
        ctx.result.pointer = s;
    }
}

/// String.prototype.toString — returns the wrapped string value
fn void builtin_string_proto_toString(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.tag == OBJECT && this_val.pointer != null) {
        HObject* obj = (HObject*)this_val.pointer;
        if (obj.get_class() == hobject::ObjClass.STRING &&
            obj.primitive_value.tag == STRING) {
            ctx.result.tag = STRING;
            ctx.result.pointer = obj.primitive_value.pointer;
            return;
        }
    } else if (this_val.tag == STRING) {
        ctx.result.tag = STRING;
        ctx.result.pointer = this_val.pointer;
        return;
    }
    ctx.result.tag = UNDEFINED;
    ctx.result.pointer = null;
}

/// String.prototype.valueOf — returns the wrapped string primitive
fn void builtin_string_proto_valueOf(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.tag == OBJECT && this_val.pointer != null) {
        HObject* obj = (HObject*)this_val.pointer;
        if (obj.get_class() == hobject::ObjClass.STRING &&
            obj.primitive_value.tag == STRING) {
            ctx.result.tag = STRING;
            ctx.result.pointer = obj.primitive_value.pointer;
            return;
        }
    } else if (this_val.tag == STRING) {
        ctx.result.tag = STRING;
        ctx.result.pointer = this_val.pointer;
        return;
    }
    ctx.result.tag = UNDEFINED;
    ctx.result.pointer = null;
}

fn void builtin_boolean_proto_valueOf(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.tag == OBJECT && this_val.pointer != null) {
        HObject* obj = (HObject*)this_val.pointer;
        if (obj.get_class() == hobject::ObjClass.BOOLEAN &&
            obj.primitive_value.tag == BOOLEAN) {
            ctx.result.tag = BOOLEAN;
            ctx.result.boolean = obj.primitive_value.boolean;
            return;
        }
    } else if (this_val.tag == BOOLEAN) {
        ctx.result.tag = BOOLEAN;
        ctx.result.boolean = this_val.boolean;
        return;
    }
    ctx.result.tag = UNDEFINED;
    ctx.result.pointer = null;
}

// ============================================================================
// Number constructor builtins
// ============================================================================

/// ToNumber then return number primitive (function call) or
/// a Number wrapper object (constructor call).
fn void builtin_number(BuiltinContext* ctx) {
    TVal num;
    if (ctx.argc > 0) {
        builtin_to_number(&ctx.regs[ctx.base_reg], &num);
    } else {
        num.tag = FASTINT;
        num.fastint = 0;
    }

    if (ctx.is_constructor) {
        HObject*? obj_raw = hobject::hobject_alloc(ctx.heap, hobject::ObjClass.NUMBER);
        if (catch err = obj_raw) {
            ctx.result.tag = UNDEFINED;
            ctx.result.pointer = null;
            return;
        }
        HObject* obj = obj_raw;
        obj.prototype = ctx.heap.number_proto;
        obj.primitive_value = num;
        ctx.result.tag = OBJECT;
        ctx.result.pointer = obj;
    } else {
        if (num.tag == FASTINT) {
            ctx.result.tag = FASTINT;
            ctx.result.fastint = num.fastint;
        } else {
            ctx.result.tag = NUMBER;
            ctx.result.number = num.number;
        }
    }
}

/// Number.prototype.toString — returns string representation of the number.
/// For now uses a basic conversion; later will support radix argument.
fn void builtin_number_proto_toString(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double d;
    if (this_val.tag == OBJECT && this_val.pointer != null) {
        HObject* obj = (HObject*)this_val.pointer;
        if (obj.get_class() == hobject::ObjClass.NUMBER &&
            (obj.primitive_value.tag == NUMBER || obj.primitive_value.tag == FASTINT)) {
            if (obj.primitive_value.tag == FASTINT) {
                d = (double)obj.primitive_value.fastint;
            } else {
                d = obj.primitive_value.number;
            }
        } else {
            ctx.result.tag = UNDEFINED;
            ctx.result.pointer = null;
            return;
        }
    } else if (this_val.tag == NUMBER) {
        d = this_val.number;
    } else if (this_val.tag == FASTINT) {
        d = (double)this_val.fastint;
    } else {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }

    char[64] buf;
    if (math::is_nan(d)) {
        HString* s = builtin_intern_string(ctx.heap, "NaN");
        ctx.result.tag = STRING;
        ctx.result.pointer = s;
    } else if (math::is_inf(d)) {
        if (d > 0) {
            HString* s = builtin_intern_string(ctx.heap, "Infinity");
            ctx.result.tag = STRING;
            ctx.result.pointer = s;
        } else {
            HString* s = builtin_intern_string(ctx.heap, "-Infinity");
            ctx.result.tag = STRING;
            ctx.result.pointer = s;
        }
    } else {
        int len = libc::snprintf(&buf, 64, "%.17g", d);
        if (len < 0 || len >= 64) {
            ctx.result.tag = UNDEFINED;
            ctx.result.pointer = null;
            return;
        }
        HString* s = builtin_intern_string(ctx.heap, buf[:len]);
        ctx.result.tag = STRING;
        ctx.result.pointer = s;
    }
}

/// Number.prototype.valueOf — returns the wrapped number primitive
fn void builtin_number_proto_valueOf(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.tag == OBJECT && this_val.pointer != null) {
        HObject* obj = (HObject*)this_val.pointer;
        if (obj.get_class() == hobject::ObjClass.NUMBER &&
            (obj.primitive_value.tag == NUMBER || obj.primitive_value.tag == FASTINT)) {
            ctx.result.tag = obj.primitive_value.tag;
            ctx.result.number = obj.primitive_value.number;
            return;
        }
    } else if (this_val.tag == NUMBER) {
        ctx.result.tag = NUMBER;
        ctx.result.number = this_val.number;
        return;
    } else if (this_val.tag == FASTINT) {
        ctx.result.tag = FASTINT;
        ctx.result.fastint = this_val.fastint;
        return;
    }
    ctx.result.tag = UNDEFINED;
    ctx.result.pointer = null;
}

// ============================================================================
// Object constructor builtins
// ============================================================================

/// Object() as function (ES5 §15.2.1.1) or new Object() as constructor (§15.2.2.1).
/// If value is null/undefined/absent, returns a new empty Object.
/// If value is already an Object, returns it.
/// Otherwise, wraps the primitive (boolean/number/string) in a wrapper object.
fn void builtin_object(BuiltinContext* ctx) {
    // Handle object prototype method calls (this-value dispatch)
    if (!ctx.is_constructor && ctx.argc == 0) {
        // Object() with no args — create and return new empty object
        HObject*? obj_raw = hobject::hobject_alloc(ctx.heap, hobject::ObjClass.OBJECT);
        if (catch err = obj_raw) {
            ctx.result.tag = UNDEFINED;
            ctx.result.pointer = null;
            return;
        }
        HObject* obj = obj_raw;
        obj.prototype = ctx.heap.object_proto;
        ctx.result.tag = OBJECT;
        ctx.result.pointer = obj;
        return;
    }

    // Get the first argument
    TVal arg = ctx.regs[ctx.base_reg];

    // null/undefined/not supplied → new empty object
    if (arg.tag == NULL_VAL || arg.tag == UNDEFINED) {
        HObject*? obj_raw = hobject::hobject_alloc(ctx.heap, hobject::ObjClass.OBJECT);
        if (catch err = obj_raw) {
            ctx.result.tag = UNDEFINED;
            ctx.result.pointer = null;
            return;
        }
        HObject* obj = obj_raw;
        obj.prototype = ctx.heap.object_proto;
        ctx.result.tag = OBJECT;
        ctx.result.pointer = obj;
        return;
    }

    // Already an object → return as-is
    if (arg.tag == OBJECT) {
        ctx.result.tag = OBJECT;
        ctx.result.pointer = arg.pointer;
        return;
    }

    // Primitive → create wrapper object (ToObject per ES5 §9.9)
    if (arg.tag == BOOLEAN) {
        HObject*? obj_raw = hobject::hobject_alloc(ctx.heap, hobject::ObjClass.BOOLEAN);
        if (catch err = obj_raw) {
            ctx.result.tag = UNDEFINED;
            ctx.result.pointer = null;
            return;
        }
        HObject* obj = obj_raw;
        obj.prototype = ctx.heap.bool_proto;
        obj.primitive_value.tag = BOOLEAN;
        obj.primitive_value.boolean = arg.boolean;
        ctx.result.tag = OBJECT;
        ctx.result.pointer = obj;
        return;
    }

    if (arg.tag == NUMBER || arg.tag == FASTINT) {
        HObject*? obj_raw = hobject::hobject_alloc(ctx.heap, hobject::ObjClass.NUMBER);
        if (catch err = obj_raw) {
            ctx.result.tag = UNDEFINED;
            ctx.result.pointer = null;
            return;
        }
        HObject* obj = obj_raw;
        obj.prototype = ctx.heap.number_proto;
        obj.primitive_value = arg;
        ctx.result.tag = OBJECT;
        ctx.result.pointer = obj;
        return;
    }

    if (arg.tag == STRING) {
        HObject*? obj_raw = hobject::hobject_alloc(ctx.heap, hobject::ObjClass.STRING);
        if (catch err = obj_raw) {
            ctx.result.tag = UNDEFINED;
            ctx.result.pointer = null;
            return;
        }
        HObject* obj = obj_raw;
        obj.prototype = ctx.heap.string_proto;
        obj.primitive_value.tag = STRING;
        obj.primitive_value.pointer = arg.pointer;
        ctx.result.tag = OBJECT;
        ctx.result.pointer = obj;
        return;
    }

    // Fallback — new empty object
    HObject*? obj_raw = hobject::hobject_alloc(ctx.heap, hobject::ObjClass.OBJECT);
    if (catch err = obj_raw) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }
    HObject* obj = obj_raw;
    obj.prototype = ctx.heap.object_proto;
    ctx.result.tag = OBJECT;
    ctx.result.pointer = obj;
}

/// Object.prototype.toString — returns "[object Class]"
fn void builtin_object_proto_toString(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.tag == OBJECT && this_val.pointer != null) {
        HObject* obj = (HObject*)this_val.pointer;
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
            default:                          class_name = "Object"; break;
        }
        int len = libc::snprintf(&buf, 64, "[object %s]", class_name);
        if (len > 0 && len < 64) {
            HString* s = builtin_intern_string(ctx.heap, buf[:len]);
            ctx.result.tag = STRING;
            ctx.result.pointer = s;
            return;
        }
    } else if (this_val.tag == UNDEFINED) {
        HString* s = builtin_intern_string(ctx.heap, "[object Undefined]");
        ctx.result.tag = STRING;
        ctx.result.pointer = s;
        return;
    } else if (this_val.tag == NULL_VAL) {
        HString* s = builtin_intern_string(ctx.heap, "[object Null]");
        ctx.result.tag = STRING;
        ctx.result.pointer = s;
        return;
    }
    HString* s = builtin_intern_string(ctx.heap, "[object Object]");
    ctx.result.tag = STRING;
    ctx.result.pointer = s;
}

/// Object.prototype.valueOf — returns 'this'
fn void builtin_object_proto_valueOf(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    ctx.result.tag = this_val.tag;
    ctx.result.fastint = this_val.fastint;
    ctx.result.number = this_val.number;
    ctx.result.pointer = this_val.pointer;
}

// ============================================================================
// Array constructor builtins
// ============================================================================

/// Array() as function (ES5 §15.4.1) or new Array() as constructor (§15.4.2).
/// Creates and returns a new Array object.
fn void builtin_array(BuiltinContext* ctx) {
    HObject*? arr_raw = hobject::hobject_alloc(ctx.heap, hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;

    HString* len_key = builtin_intern_string(ctx.heap, "length");

    if (ctx.argc == 0) {
        // No args: empty array with length 0
        TVal len_val;
        len_val.tag = FASTINT;
        len_val.fastint = 0;
        arr.put_prop(len_key, len_val, hobject::PROP_FLAGS_WEC);
        ctx.result.tag = OBJECT;
        ctx.result.pointer = arr;
        return;
    }

    if (ctx.argc == 1) {
        // Single arg: check if it's a number
        TVal arg = ctx.regs[ctx.base_reg];
        if (arg.tag == NUMBER || arg.tag == FASTINT) {
            // Single numeric arg: set array length
            double d;
            if (arg.tag == FASTINT) {
                d = (double)arg.fastint;
            } else {
                d = arg.number;
            }
            // ToUint32 check per ES5
            uint n = (uint)(long)d;
            if ((double)n != d) {
                // Invalid array length — create empty array as fallback
                TVal len_val;
                len_val.tag = FASTINT;
                len_val.fastint = 0;
                arr.put_prop(len_key, len_val, hobject::PROP_FLAGS_WEC);
            } else {
                TVal len_val;
                len_val.tag = FASTINT;
                len_val.fastint = (long)n;
                arr.put_prop(len_key, len_val, hobject::PROP_FLAGS_WEC);
            }
        } else {
            // Single non-numeric arg: array with one element
            TVal len_val;
            len_val.tag = FASTINT;
            len_val.fastint = 1;
            arr.put_prop(len_key, len_val, hobject::PROP_FLAGS_WEC);

            // Set element at index 0
            HString* zero_key = builtin_intern_string(ctx.heap, "0");
            arr.put_prop(zero_key, arg, hobject::PROP_FLAGS_WEC);
        }
        ctx.result.tag = OBJECT;
        ctx.result.pointer = arr;
        return;
    }

    // Multiple args: create array with given elements
    TVal len_val;
    len_val.tag = FASTINT;
    len_val.fastint = (long)ctx.argc;
    arr.put_prop(len_key, len_val, hobject::PROP_FLAGS_WEC);

    // Set each element
    for (ushort i = 0; i < ctx.argc; i++) {
        TVal elem = ctx.regs[ctx.base_reg + (uint)i];
        char[16] buf;
        int len = libc::snprintf(&buf, 16, "%d", i);
        if (len > 0 && len < 16) {
            HString* idx_key = builtin_intern_string(ctx.heap, buf[:len]);
            arr.put_prop(idx_key, elem, hobject::PROP_FLAGS_WEC);
        }
    }

    ctx.result.tag = OBJECT;
    ctx.result.pointer = arr;
}

fn void dispatch_builtin(uint fn_index, BuiltinContext* ctx) {
    switch (fn_index) {
        case BUILTIN_PRINT:
            builtin_print(ctx);
        case BUILTIN_CONSOLE_LOG:
            builtin_console_log(ctx);
        case BUILTIN_PARSE_INT:
            builtin_parse_int(ctx);
        case BUILTIN_PARSE_FLOAT:
            builtin_parse_float(ctx);
        case BUILTIN_IS_NAN:
            builtin_is_nan(ctx);
        case BUILTIN_IS_FINITE:
            builtin_is_finite(ctx);
        case BUILTIN_ERROR:
            builtin_error(ctx);
        case BUILTIN_TYPE_ERROR:
            builtin_type_error(ctx);
        case BUILTIN_RANGE_ERROR:
            builtin_range_error(ctx);
        case BUILTIN_REFERENCE_ERROR:
            builtin_reference_error(ctx);
        case BUILTIN_SYNTAX_ERROR:
            builtin_syntax_error(ctx);
        case BUILTIN_EVAL_ERROR:
            builtin_eval_error(ctx);
        case BUILTIN_ERROR_PROTO_TOSTRING:
            builtin_error_prototype_to_string(ctx);
        case BUILTIN_BOOLEAN:
            builtin_boolean(ctx);
        case BUILTIN_BOOLEAN_PROTO_TOSTRING:
            builtin_boolean_proto_toString(ctx);
        case BUILTIN_BOOLEAN_PROTO_VALUEOF:
            builtin_boolean_proto_valueOf(ctx);
        case BUILTIN_STRING:
            builtin_string(ctx);
        case BUILTIN_STRING_PROTO_TOSTRING:
            builtin_string_proto_toString(ctx);
        case BUILTIN_STRING_PROTO_VALUEOF:
            builtin_string_proto_valueOf(ctx);
        case BUILTIN_NUMBER:
            builtin_number(ctx);
        case BUILTIN_NUMBER_PROTO_TOSTRING:
            builtin_number_proto_toString(ctx);
        case BUILTIN_NUMBER_PROTO_VALUEOF:
            builtin_number_proto_valueOf(ctx);
        case BUILTIN_OBJECT:
            builtin_object(ctx);
        case BUILTIN_OBJECT_PROTO_TOSTRING:
            builtin_object_proto_toString(ctx);
        case BUILTIN_OBJECT_PROTO_VALUEOF:
            builtin_object_proto_valueOf(ctx);
        case BUILTIN_ARRAY:
            builtin_array(ctx);
        default:
            ctx.result.tag = UNDEFINED;
            ctx.result.pointer = null;
    }
}

fn bool register_builtins(EnvRecord* global_env, Heap* heap) {
    char[] print_name = "print";
    uint print_hash = heap.hash_string(print_name);
    HString*? print_key = hstring::hstring_alloc(heap, print_name, print_hash);
    if (catch err = print_key) {
        return false;
    }
    heap.str_table_insert(print_key);

    TVal print_val;
    print_val.tag = LIGHTFUNC;
    print_val.fastint = (long)BUILTIN_PRINT;
    env::env_declare(global_env, print_key, print_val);

    char[] console_name = "console";
    uint console_hash = heap.hash_string(console_name);
    HString*? console_key = hstring::hstring_alloc(heap, console_name, console_hash);
    if (catch err = console_key) {
        return false;
    }
    heap.str_table_insert(console_key);

    HObject*? console_obj = hobject::hobject_alloc(heap, hobject::ObjClass.OBJECT);
    if (catch err = console_obj) {
        return false;
    }

    TVal console_val;
    console_val.tag = OBJECT;
    console_val.pointer = console_obj;

    char[] log_name = "log";
    uint log_hash = heap.hash_string(log_name);
    HString*? log_key = hstring::hstring_alloc(heap, log_name, log_hash);
    if (catch err = log_key) {
        return false;
    }
    heap.str_table_insert(log_key);

    TVal log_val;
    log_val.tag = LIGHTFUNC;
    log_val.fastint = (long)BUILTIN_CONSOLE_LOG;
    console_obj.put_prop(log_key, log_val, hobject::PROP_FLAGS_WEC);

    env::env_declare(global_env, console_key, console_val);

    // Register parseInt
    if (!register_simple_builtin(global_env, heap, "parseInt", BUILTIN_PARSE_INT)) return false;

    // Register parseFloat
    if (!register_simple_builtin(global_env, heap, "parseFloat", BUILTIN_PARSE_FLOAT)) return false;

    // Register isNaN
    if (!register_simple_builtin(global_env, heap, "isNaN", BUILTIN_IS_NAN)) return false;

    // Register isFinite
    if (!register_simple_builtin(global_env, heap, "isFinite", BUILTIN_IS_FINITE)) return false;

    // Register global constants: NaN, Infinity, undefined
    if (!register_global_constant(global_env, heap, "NaN", NUMBER, double::nan, 0)) return false;
    if (!register_global_constant(global_env, heap, "Infinity", NUMBER, double::inf, 0)) return false;

    // Register Object constructor FIRST — creates Object.prototype (root of all chains)
    if (!register_object_constructor(global_env, heap)) return false;

    // Register Number constructor (with prototype and static properties)
    if (!register_number_constructor(global_env, heap)) return false;

    // Register Math object
    if (!register_math_object(global_env, heap)) return false;

    // Register Error constructors (Error, TypeError, RangeError, ReferenceError, SyntaxError, EvalError)
    if (!register_error_builtins(global_env, heap)) return false;

    // Register Boolean constructor
    if (!register_boolean_constructor(global_env, heap)) return false;

    // Register String constructor
    if (!register_string_constructor(global_env, heap)) return false;

    // Register Array constructor
    if (!register_array_constructor(global_env, heap)) return false;

    // Wire all prototype chains to Object.prototype
    if (heap.number_proto != null) heap.number_proto.prototype = heap.object_proto;
    if (heap.bool_proto != null)   heap.bool_proto.prototype = heap.object_proto;
    if (heap.string_proto != null) heap.string_proto.prototype = heap.object_proto;
    if (heap.err_proto != null)    heap.err_proto.prototype = heap.object_proto;
    if (heap.array_proto != null)  heap.array_proto.prototype = heap.object_proto;

    return true;
}

fn bool register_object_constructor(EnvRecord* global_env, Heap* heap) {
    // Create Object.prototype — the root of all prototype chains
    HObject*? proto_raw = hobject::hobject_alloc(heap, hobject::ObjClass.OBJECT);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;  // Object.prototype is the root — its [[Prototype]] is null
    heap.object_proto = proto;

    // Add .constructor to Object.prototype pointing to Object builtin
    HString* constructor_key = builtin_intern_string(heap, "constructor");
    TVal constructor_tv;
    constructor_tv.tag = LIGHTFUNC;
    constructor_tv.fastint = (long)BUILTIN_OBJECT;
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WEC);

    // Add .toString() method to Object.prototype
    HString* tostring_key = builtin_intern_string(heap, "toString");
    TVal tostring_tv;
    tostring_tv.tag = LIGHTFUNC;
    tostring_tv.fastint = (long)BUILTIN_OBJECT_PROTO_TOSTRING;
    proto.put_prop(tostring_key, tostring_tv, hobject::PROP_FLAGS_WEC);

    // Add .valueOf() method to Object.prototype (returns 'this')
    HString* valueof_key = builtin_intern_string(heap, "valueOf");
    TVal valueof_tv;
    valueof_tv.tag = LIGHTFUNC;
    valueof_tv.fastint = (long)BUILTIN_OBJECT_PROTO_VALUEOF;
    proto.put_prop(valueof_key, valueof_tv, hobject::PROP_FLAGS_WEC);

    // Register Object as a global constructor (lightfunc)
    return register_simple_builtin(global_env, heap, "Object", BUILTIN_OBJECT);
}

fn bool register_math_object(EnvRecord* global_env, Heap* heap) {
    HObject*? math_raw = hobject::hobject_alloc(heap, hobject::ObjClass.OBJECT);
    if (catch err = math_raw) return false;
    HObject* math = math_raw;
    if (!set_num_prop_lookup(math, heap, "E", 2.718281828459045)) return false;
    if (!set_num_prop_lookup(math, heap, "PI", 3.141592653589793)) return false;
    if (!set_num_prop_lookup(math, heap, "LN2", 0.6931471805599453)) return false;
    if (!set_num_prop_lookup(math, heap, "LN10", 2.302585092994046)) return false;
    if (!set_num_prop_lookup(math, heap, "LOG2E", 1.4426950408889634)) return false;
    if (!set_num_prop_lookup(math, heap, "LOG10E", 0.4342944819032518)) return false;
    if (!set_num_prop_lookup(math, heap, "SQRT1_2", 0.7071067811865476)) return false;
    if (!set_num_prop_lookup(math, heap, "SQRT2", 1.4142135623730951)) return false;
    TVal math_tv;
    math_tv.tag = OBJECT;
    math_tv.fastint = 0;
    math_tv.pointer = math;
    return register_named_value(global_env, heap, "Math", math_tv);
}

fn bool set_num_prop_lookup(HObject* obj, Heap* heap, char[] name, double val) {
    uint hash = heap.hash_string(name);
    HString* existing = heap.str_table_lookup(name, hash);
    void* key = existing;
    if (key == null) {
        HString*? new_key = hstring::hstring_alloc(heap, name, hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        key = new_key;
    }
    TVal tv;
    tv.tag = NUMBER;
    tv.number = val;
    obj.put_prop(key, tv, hobject::PROP_FLAGS_WEC);
    return true;
}

// ============================================================================
// Number constructor registration
// ============================================================================

/// Create Number.prototype and register the Number constructor globally.
fn bool register_number_constructor(EnvRecord* global_env, Heap* heap) {
    // Create Number.prototype
    HObject*? proto_raw = hobject::hobject_alloc(heap, hobject::ObjClass.NUMBER);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;  // Will be Object.prototype in later phases
    heap.number_proto = proto;

    // Set .constructor to Number lightfunc
    HString* constructor_key = builtin_intern_string(heap, "constructor");
    TVal constructor_tv;
    constructor_tv.tag = LIGHTFUNC;
    constructor_tv.fastint = (long)BUILTIN_NUMBER;
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WEC);

    // Add .toString() method
    HString* tostring_key = builtin_intern_string(heap, "toString");
    TVal tostring_tv;
    tostring_tv.tag = LIGHTFUNC;
    tostring_tv.fastint = (long)BUILTIN_NUMBER_PROTO_TOSTRING;
    proto.put_prop(tostring_key, tostring_tv, hobject::PROP_FLAGS_WEC);

    // Add .valueOf() method
    HString* valueof_key = builtin_intern_string(heap, "valueOf");
    TVal valueof_tv;
    valueof_tv.tag = LIGHTFUNC;
    valueof_tv.fastint = (long)BUILTIN_NUMBER_PROTO_VALUEOF;
    proto.put_prop(valueof_key, valueof_tv, hobject::PROP_FLAGS_WEC);

    // Register Number as a global constructor
    if (!register_simple_builtin(global_env, heap, "Number", BUILTIN_NUMBER)) return false;

    return true;
}

fn bool set_num_prop(HObject* obj, Heap* heap, char[] name, double val) {
    uint hash = heap.hash_string(name);
    // Use lookup-first to avoid duplicate HString pointers
    HString* existing = heap.str_table_lookup(name, hash);
    void* key;
    if (existing != null) {
        key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, name, hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        key = new_key;
    }
    TVal tv;
    tv.tag = NUMBER;
    tv.number = val;
    obj.put_prop(key, tv, hobject::PROP_FLAGS_WEC);
    return true;
}

fn bool register_named_value(EnvRecord* global_env, Heap* heap, char[] name, TVal val) {
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
    return env::env_declare(global_env, key, val);
}

fn bool register_global_constant(EnvRecord* global_env, Heap* heap, char[] name,
                                  TValTag tag, double number_val, long fastint_val) {
    uint hash = heap.hash_string(name);
    HString* existing = heap.str_table_lookup(name, hash);
    HString* key;
    if (existing != null) {
        key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, name, hash);
        if (catch err = new_key) {
            return false;
        }
        heap.str_table_insert(new_key);
        key = new_key;
    }
    TVal val;
    val.tag = tag;
    if (tag == FASTINT) {
        val.fastint = fastint_val;
        val.pointer = null;
    } else if (tag == STRING || tag == OBJECT) {
        val.number = 0.0;
        val.pointer = null;  // caller must set pointer
    } else {
        val.number = number_val;
        // Don't touch pointer — it shares union with number
    }
    env::env_declare(global_env, key, val);
    return true;
}

fn bool register_simple_builtin(EnvRecord* global_env, Heap* heap, char[] name, uint fn_index) {
    uint hash = heap.hash_string(name);
    HString* existing = heap.str_table_lookup(name, hash);
    HString* key;
    if (existing != null) {
        key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, name, hash);
        if (catch err = new_key) {
            return false;
        }
        heap.str_table_insert(new_key);
        key = new_key;
    }

    TVal val;
    val.tag = LIGHTFUNC;
    val.fastint = (long)fn_index;
    env::env_declare(global_env, key, val);
    return true;
}

// ============================================================================
// Error built-in registration
// ============================================================================

/// Helper: create a prototype object for an error type.
/// proto_parent is the [[Prototype]] (e.g. Error.prototype for subclasses).
fn HObject* register_error_prototype(Heap* heap, HObject* proto_parent, char[] name_str) {
    HObject*? proto_raw = hobject::hobject_alloc(heap, hobject::ObjClass.ERROR);
    if (catch err = proto_raw) return null;
    HObject* proto = proto_raw;
    proto.prototype = proto_parent;

    // Set .name property
    HString* name_key = builtin_intern_string(heap, "name");
    HString* name_hstr = builtin_intern_string(heap, name_str);
    TVal name_tv;
    name_tv.tag = STRING;
    name_tv.pointer = name_hstr;
    proto.put_prop(name_key, name_tv, hobject::PROP_FLAGS_WEC);

    // Set .message property (empty string)
    HString* msg_key = builtin_intern_string(heap, "message");
    HString* msg_hstr = builtin_intern_string(heap, "");
    TVal msg_tv;
    msg_tv.tag = STRING;
    msg_tv.pointer = msg_hstr;
    proto.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);

    return proto;
}

/// Register all Error constructors and prototypes.
fn bool register_error_builtins(EnvRecord* global_env, Heap* heap) {
    // --- Create Error.prototype ---
    HObject* err_proto = register_error_prototype(heap, null, "Error");
    if (err_proto == null) return false;
    heap.err_proto = err_proto;

    // Add .toString() method to Error.prototype
    HString* tostring_key = builtin_intern_string(heap, "toString");
    TVal tostring_tv;
    tostring_tv.tag = LIGHTFUNC;
    tostring_tv.fastint = (long)BUILTIN_ERROR_PROTO_TOSTRING;
    err_proto.put_prop(tostring_key, tostring_tv, hobject::PROP_FLAGS_WEC);

    // --- Create TypeError.prototype ---
    HObject* type_err_proto = register_error_prototype(heap, err_proto, "TypeError");
    if (type_err_proto == null) return false;
    heap.type_err_proto = type_err_proto;

    // --- Create RangeError.prototype ---
    HObject* range_err_proto = register_error_prototype(heap, err_proto, "RangeError");
    if (range_err_proto == null) return false;
    heap.range_err_proto = range_err_proto;

    // --- Create ReferenceError.prototype ---
    HObject* ref_err_proto = register_error_prototype(heap, err_proto, "ReferenceError");
    if (ref_err_proto == null) return false;
    heap.ref_err_proto = ref_err_proto;

    // --- Create SyntaxError.prototype ---
    HObject* syntax_err_proto = register_error_prototype(heap, err_proto, "SyntaxError");
    if (syntax_err_proto == null) return false;
    heap.syntax_err_proto = syntax_err_proto;

    // --- Create EvalError.prototype ---
    HObject* eval_err_proto = register_error_prototype(heap, err_proto, "EvalError");
    if (eval_err_proto == null) return false;
    heap.eval_err_proto = eval_err_proto;

    // --- Register Error global constructor ---
    if (!register_simple_builtin(global_env, heap, "Error", BUILTIN_ERROR)) return false;

    // --- Register TypeError ---
    if (!register_simple_builtin(global_env, heap, "TypeError", BUILTIN_TYPE_ERROR)) return false;

    // --- Register RangeError ---
    if (!register_simple_builtin(global_env, heap, "RangeError", BUILTIN_RANGE_ERROR)) return false;

    // --- Register ReferenceError ---
    if (!register_simple_builtin(global_env, heap, "ReferenceError", BUILTIN_REFERENCE_ERROR)) return false;

    // --- Register SyntaxError ---
    if (!register_simple_builtin(global_env, heap, "SyntaxError", BUILTIN_SYNTAX_ERROR)) return false;

    // --- Register EvalError ---
    if (!register_simple_builtin(global_env, heap, "EvalError", BUILTIN_EVAL_ERROR)) return false;

    return true;
}

// ============================================================================
// Boolean constructor registration
// ============================================================================

/// Create Boolean.prototype and register the Boolean constructor globally.
fn bool register_boolean_constructor(EnvRecord* global_env, Heap* heap) {
    // Create Boolean.prototype
    HObject*? proto_raw = hobject::hobject_alloc(heap, hobject::ObjClass.BOOLEAN);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;  // Will be Object.prototype in later phases
    heap.bool_proto = proto;

    // Set .constructor to Boolean lightfunc
    HString* constructor_key = builtin_intern_string(heap, "constructor");
    TVal constructor_tv;
    constructor_tv.tag = LIGHTFUNC;
    constructor_tv.fastint = (long)BUILTIN_BOOLEAN;
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WEC);

    // Add .toString() method
    HString* tostring_key = builtin_intern_string(heap, "toString");
    TVal tostring_tv;
    tostring_tv.tag = LIGHTFUNC;
    tostring_tv.fastint = (long)BUILTIN_BOOLEAN_PROTO_TOSTRING;
    proto.put_prop(tostring_key, tostring_tv, hobject::PROP_FLAGS_WEC);

    // Add .valueOf() method
    HString* valueof_key = builtin_intern_string(heap, "valueOf");
    TVal valueof_tv;
    valueof_tv.tag = LIGHTFUNC;
    valueof_tv.fastint = (long)BUILTIN_BOOLEAN_PROTO_VALUEOF;
    proto.put_prop(valueof_key, valueof_tv, hobject::PROP_FLAGS_WEC);

    // Register Boolean as a global constructor
    if (!register_simple_builtin(global_env, heap, "Boolean", BUILTIN_BOOLEAN)) return false;

    return true;
}

// ============================================================================
// String constructor registration
// ============================================================================

/// Create String.prototype and register the String constructor globally.
fn bool register_string_constructor(EnvRecord* global_env, Heap* heap) {
    // Create String.prototype
    HObject*? proto_raw = hobject::hobject_alloc(heap, hobject::ObjClass.STRING);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;  // Will be Object.prototype in later phases
    heap.string_proto = proto;

    // Set .constructor to String lightfunc
    HString* constructor_key = builtin_intern_string(heap, "constructor");
    TVal constructor_tv;
    constructor_tv.tag = LIGHTFUNC;
    constructor_tv.fastint = (long)BUILTIN_STRING;
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WEC);

    // Add .toString() method
    HString* tostring_key = builtin_intern_string(heap, "toString");
    TVal tostring_tv;
    tostring_tv.tag = LIGHTFUNC;
    tostring_tv.fastint = (long)BUILTIN_STRING_PROTO_TOSTRING;
    proto.put_prop(tostring_key, tostring_tv, hobject::PROP_FLAGS_WEC);

    // Add .valueOf() method
    HString* valueof_key = builtin_intern_string(heap, "valueOf");
    TVal valueof_tv;
    valueof_tv.tag = LIGHTFUNC;
    valueof_tv.fastint = (long)BUILTIN_STRING_PROTO_VALUEOF;
    proto.put_prop(valueof_key, valueof_tv, hobject::PROP_FLAGS_WEC);

    // Register String as a global constructor
    if (!register_simple_builtin(global_env, heap, "String", BUILTIN_STRING)) return false;

    return true;
}

// ============================================================================
// Array constructor registration
// ============================================================================

/// Create Array.prototype and register the Array constructor globally.
fn bool register_array_constructor(EnvRecord* global_env, Heap* heap) {
    // Create Array.prototype
    HObject*? proto_raw = hobject::hobject_alloc(heap, hobject::ObjClass.ARRAY);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;  // Will be Object.prototype in later phases
    heap.array_proto = proto;

    // Set .constructor to Array lightfunc
    HString* constructor_key = builtin_intern_string(heap, "constructor");
    TVal constructor_tv;
    constructor_tv.tag = LIGHTFUNC;
    constructor_tv.fastint = (long)BUILTIN_ARRAY;
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WEC);

    // Register Array as a global constructor
    if (!register_simple_builtin(global_env, heap, "Array", BUILTIN_ARRAY)) return false;

    return true;
}


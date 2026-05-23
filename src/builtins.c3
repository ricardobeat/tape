/// Built-in function registry for the Duktape C3 port.
module duktape::builtins;

import duktape::types;
import duktape::bytecode;
import duktape::hstring;
import duktape::hobject;
import duktape::heap;
import duktape::env;
import duktape::compiler;
import duktape::lexer;
import std::io;
import std::math;
import libc;

// Math library externals (link-time resolved via @MathLibc)
extern fn double math_pow(double x, double y) @MathLibc("pow");
extern fn double math_sqrt(double x)          @MathLibc("sqrt");
extern fn double math_exp(double x)           @MathLibc("exp");
extern fn double math_log(double x)           @MathLibc("log");
extern fn double math_sin(double x)           @MathLibc("sin");
extern fn double math_cos(double x)           @MathLibc("cos");
extern fn double math_tan(double x)           @MathLibc("tan");

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
const uint BUILTIN_MATH_ABS   = 26;
const uint BUILTIN_MATH_FLOOR = 27;
const uint BUILTIN_MATH_CEIL  = 28;
const uint BUILTIN_MATH_ROUND = 29;
const uint BUILTIN_MATH_MAX   = 30;
const uint BUILTIN_MATH_MIN   = 31;
const uint BUILTIN_MATH_POW   = 32;
const uint BUILTIN_MATH_SQRT  = 33;
const uint BUILTIN_MATH_EXP   = 34;
const uint BUILTIN_MATH_LOG   = 35;
const uint BUILTIN_MATH_SIN   = 36;
const uint BUILTIN_MATH_COS   = 37;
const uint BUILTIN_MATH_TAN   = 38;
const uint BUILTIN_MATH_RANDOM = 39;
const uint BUILTIN_STRING_PROTO_CHARAT     = 40;
const uint BUILTIN_STRING_PROTO_CHARCODEAT = 41;
const uint BUILTIN_STRING_PROTO_INDEXOF    = 42;
const uint BUILTIN_STRING_PROTO_SLICE      = 43;
const uint BUILTIN_STRING_PROTO_SUBSTRING  = 44;
const uint BUILTIN_STRING_PROTO_SUBSTR     = 45;
const uint BUILTIN_STRING_PROTO_TOUPPERCASE = 46;
const uint BUILTIN_STRING_PROTO_TOLOWERCASE = 47;
const uint BUILTIN_STRING_PROTO_TRIM       = 48;
const uint BUILTIN_STRING_PROTO_SPLIT      = 49;
const uint BUILTIN_STRING_PROTO_CONCAT     = 50;
const uint BUILTIN_STRING_PROTO_REPLACE    = 51;
const uint BUILTIN_ARRAY_PROTO_TOSTRING    = 52;
const uint BUILTIN_ARRAY_PROTO_JOIN        = 53;
const uint BUILTIN_ARRAY_PROTO_POP         = 54;
const uint BUILTIN_ARRAY_PROTO_PUSH        = 55;
const uint BUILTIN_ARRAY_PROTO_REVERSE     = 56;
const uint BUILTIN_ARRAY_PROTO_SHIFT       = 57;
const uint BUILTIN_ARRAY_PROTO_SLICE       = 58;
const uint BUILTIN_ARRAY_PROTO_SORT        = 59;
const uint BUILTIN_ARRAY_PROTO_SPLICE      = 60;
const uint BUILTIN_ARRAY_PROTO_UNSHIFT     = 61;
const uint BUILTIN_ARRAY_PROTO_INDEXOF     = 62;
const uint BUILTIN_ARRAY_PROTO_LASTINDEXOF = 63;
const uint BUILTIN_ARRAY_PROTO_CONCAT      = 64;
const uint BUILTIN_ARRAY_PROTO_EVERY       = 65;
const uint BUILTIN_ARRAY_PROTO_SOME        = 66;
const uint BUILTIN_ARRAY_PROTO_FOREACH     = 67;
const uint BUILTIN_ARRAY_PROTO_MAP         = 68;
const uint BUILTIN_ARRAY_PROTO_FILTER      = 69;
const uint BUILTIN_ARRAY_PROTO_REDUCE      = 70;
const uint BUILTIN_ARRAY_PROTO_REDUCERIGHT = 71;
const uint BUILTIN_NUMBER_PROTO_TOFIXED       = 73;
const uint BUILTIN_NUMBER_PROTO_TOEXPONENTIAL = 74;
const uint BUILTIN_NUMBER_PROTO_TOPRECISION   = 75;
const uint BUILTIN_FUNCTION_PROTO_CALL  = 77;
const uint BUILTIN_FUNCTION_PROTO_APPLY = 78;
const uint BUILTIN_FUNCTION_PROTO_BIND  = 79;
const uint BUILTIN_BOUND_CALL           = 80;
const uint BUILTIN_EVAL                 = 81;
const uint BUILTIN_COUNT               = 82;

struct BuiltinContext {
    void* vm;
    TVal* regs;
    ushort base_reg;
    ushort argc;
    TVal* result;
    Heap* heap;
    TVal  this_val;
    bool  is_constructor;
    /// Re-dispatch signal: when true, the CALL handler should re-read the
    /// function from the callee slot and re-dispatch with modified args.
    /// Used by Function.prototype.call/apply.
    bool  needs_re_dispatch;
    /// New argument count for re-dispatch (only valid when needs_re_dispatch).
    ushort re_nargs;
    /// Global environment pointer (for eval and other scope-sensitive builtins).
    EnvRecord* global_env;
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
    TVal num;
    builtin_to_number(&ctx.regs[ctx.base_reg], &num);
    ctx.result.tag = BOOLEAN;
    ctx.result.boolean = (num.tag == NUMBER) ? math::is_nan(num.number) : false;
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
// Eval (ES5 §15.1.2.1)
// ============================================================================

fn void builtin_eval(BuiltinContext* ctx) {
    // ES5 §15.1.2.1: eval(x)
    if (ctx.argc < 1) {
        // No args → return undefined
        ctx.result.set_undefined();
        return;
    }

    TVal* arg = &ctx.regs[ctx.base_reg];

    // If Type(x) is not String, return x unchanged
    if (arg.tag != STRING) {
        ctx.result.tag = arg.tag;
        ctx.result.fastint = arg.fastint;
        ctx.result.number = arg.number;
        ctx.result.pointer = arg.pointer;
        return;
    }

    HString* source = (HString*)arg.pointer;
    char* src_cstr = source.get_cstr();
    usz src_len = source.blen;

    // Compile the source string as eval code
    Lexer lex = lexer::lexer_init(src_cstr[:src_len], ctx.heap);
    CompiledFunction*? cf = compiler::compile_eval(&lex, ctx.heap);
    CompiledFunction* func;
    if (try f = cf) {
        func = f;
    } else {
        // Compilation failed: throw SyntaxError
        HObject*? err_raw = hobject::hobject_alloc(ctx.heap, hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.syntax_err_proto;
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            HString* msg_str = builtin_intern_string(ctx.heap, "SyntaxError in eval code");
            TVal msg_tv;
            msg_tv.tag = STRING;
            msg_tv.pointer = msg_str;
            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
            TVal err_tv;
            err_tv.tag = OBJECT;
            err_tv.pointer = err;
            ctx.result.tag = err_tv.tag;
            ctx.result.pointer = err_tv.pointer;
        } else {
            ctx.result.set_undefined();
        }
        return;
    }

    // Create an HObject for the compiled function
    HObject*? func_obj_raw = hobject::hobject_alloc(ctx.heap, hobject::ObjClass.FUNCTION);
    if (catch err = func_obj_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* func_obj = func_obj_raw;
    func_obj.flags.callable = true;
    func_obj.comp_func = func;
    func_obj.builtin_fn_index = -1;

    // For eval, use the global environment
    func_obj.var_env = ctx.global_env;
    func_obj.lex_env = ctx.global_env;

    // Replace the callee slot with the compiled function HObject
    TVal func_tv;
    func_tv.tag = OBJECT;
    func_tv.pointer = func_obj;
    ctx.regs[ctx.base_reg - 2] = func_tv;

    // Set this binding to the global object (required for indirect eval per §10.4.2)
    if (ctx.global_env != null && ctx.global_env.bindings != null) {
        TVal this_tv;
        this_tv.tag = OBJECT;
        this_tv.pointer = ctx.global_env.bindings;
        ctx.regs[ctx.base_reg - 1] = this_tv;
    }

    // Signal the CALL handler to re-dispatch to the compiled function with 0 args
    ctx.needs_re_dispatch = true;
    ctx.re_nargs = 0;
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
// String.prototype methods (Phase 6b)
// ============================================================================

/// Helper: extract the string data and length from `this`, handling both
/// primitive strings and String wrapper objects. Returns null on failure.
fn HString* string_proto_get_this(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.tag == STRING) {
        return (HString*)this_val.pointer;
    }
    if (this_val.tag == OBJECT && this_val.pointer != null) {
        HObject* obj = (HObject*)this_val.pointer;
        if (obj.get_class() == hobject::ObjClass.STRING &&
            obj.primitive_value.tag == STRING) {
            return (HString*)obj.primitive_value.pointer;
        }
    }
    // TypeError: String.prototype method called on incompatible value
    HString* type_str = builtin_intern_string(ctx.heap, "String");
    HObject*? err_raw = hobject::hobject_alloc(ctx.heap, hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_str = builtin_intern_string(ctx.heap, "String.prototype method called on incompatible value");
        TVal msg_val;
        msg_val.tag = STRING;
        msg_val.pointer = msg_str;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
        // Store the error for bubbling — but for now just return null
    }
    return null;
}

/// Helper: convert TVal to integer (ES5 §9.4 ToInteger).
fn double builtin_to_integer(TVal* val) {
    switch (val.tag) {
        case UNDEFINED:
            return 0.0;
        case NULL_VAL:
            return 0.0;
        case BOOLEAN:
            return val.boolean ? 1.0 : 0.0;
        case NUMBER:
            double d = val.number;
            if (math::is_nan(d)) return 0.0;
            if (math::is_inf(d) || d == 0.0) return d;
            return math::trunc(d);
        case FASTINT:
            return (double)val.fastint;
        case STRING: {
            double d = builtin_string_to_number((HString*)val.pointer);
            if (math::is_nan(d)) return 0.0;
            if (math::is_inf(d) || d == 0.0) return d;
            return math::trunc(d);
        }
        case OBJECT: {
            TVal prim = to_primitive_value_local(val);
            if (prim.tag != OBJECT) {
                return builtin_to_integer(&prim);
            }
            return 0.0;
        }
        default:
            return 0.0;
    }
}

/// Helper: clamp to int and coerce to range [0, len].
fn uint clamp_index(double d, uint len) {
    if (math::is_nan(d)) return 0;
    if (d < 0) return 0;
    if (d >= (double)len) return len;
    return (uint)(long)d;
}

/// String.prototype.charAt(pos) — ES5 §15.5.4.4
fn void builtin_string_proto_charAt(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;
    double pos = (ctx.argc > 0) ? builtin_to_integer(&ctx.regs[ctx.base_reg]) : 0.0;
    if (pos < 0 || pos >= (double)len) {
        // Return empty string
        ctx.result.tag = STRING;
        ctx.result.pointer = builtin_intern_string(ctx.heap, "");
        return;
    }
    uint idx = (uint)(long)pos;
    char[2] buf;
    buf[0] = data[idx];
    buf[1] = 0;
    HString* result = builtin_intern_string(ctx.heap, buf[:1]);
    ctx.result.tag = STRING;
    ctx.result.pointer = result;
}

/// String.prototype.charCodeAt(pos) — ES5 §15.5.4.5
fn void builtin_string_proto_charCodeAt(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;
    double pos = (ctx.argc > 0) ? builtin_to_integer(&ctx.regs[ctx.base_reg]) : 0.0;
    if (pos < 0 || pos >= (double)len) {
        ctx.result.tag = NUMBER;
        ctx.result.number = double::nan;
        return;
    }
    uint idx = (uint)(long)pos;
    ctx.result.tag = FASTINT;
    ctx.result.fastint = (long)(data[idx] & 0xFF);
}

/// String.prototype.indexOf(searchString, position) — ES5 §15.5.4.7
fn void builtin_string_proto_indexOf(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;

    // Get search string
    HString* search_hstr;
    if (ctx.argc > 0) {
        search_hstr = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg]);
    } else {
        search_hstr = builtin_intern_string(ctx.heap, "undefined");
    }
    if (search_hstr == null) {
        ctx.result.tag = FASTINT;
        ctx.result.fastint = -1;
        return;
    }

    // Get position
    double pos_d = (ctx.argc > 1) ? builtin_to_integer(&ctx.regs[ctx.base_reg + 1]) : 0.0;
    uint pos;
    if (math::is_nan(pos_d) || pos_d < 0) {
        pos = 0;
    } else if (pos_d >= (double)len) {
        pos = len;
    } else {
        pos = (uint)(long)pos_d;
    }

    char* search_data = search_hstr.get_cstr();
    uint search_len = search_hstr.blen;

    // Search for occurrence
    if (search_len == 0) {
        ctx.result.tag = FASTINT;
        ctx.result.fastint = (long)pos;
        return;
    }

    int result = -1;
    for (uint i = pos; i + search_len <= len; i++) {
        bool found = true;
        for (uint j = 0; j < search_len; j++) {
            if (data[i + j] != search_data[j]) {
                found = false;
                break;
            }
        }
        if (found) {
            result = (int)i;
            break;
        }
    }
    ctx.result.tag = FASTINT;
    ctx.result.fastint = (long)result;
}

/// String.prototype.slice(start, end) — ES5 §15.5.4.13
fn void builtin_string_proto_slice(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;

    double start_d = (ctx.argc > 0) ? builtin_to_integer(&ctx.regs[ctx.base_reg]) : 0.0;
    double end_d = (ctx.argc > 1) ? builtin_to_integer(&ctx.regs[ctx.base_reg + 1]) : (double)len;

    // Handle negative start
    int start_i;
    if (math::is_nan(start_d)) {
        start_i = 0;
    } else if (start_d < 0) {
        start_i = (int)(long)start_d + (int)len;
        if (start_i < 0) start_i = 0;
    } else {
        start_i = (int)(long)start_d;
        if (start_i > (int)len) start_i = (int)len;
    }

    // Handle negative end
    int end_i;
    if (math::is_nan(end_d)) {
        end_i = (int)len;
    } else if (end_d < 0) {
        end_i = (int)(long)end_d + (int)len;
        if (end_i < 0) end_i = 0;
    } else {
        end_i = (int)(long)end_d;
        if (end_i > (int)len) end_i = (int)len;
    }

    if (start_i >= end_i) {
        ctx.result.tag = STRING;
        ctx.result.pointer = builtin_intern_string(ctx.heap, "");
        return;
    }

    uint substr_len = (uint)(end_i - start_i);
    char[256] buf;
    usz copy_len = (usz)(substr_len < 256 ? substr_len : 256);
    for (usz i = 0; i < copy_len; i++) {
        buf[i] = data[(uint)start_i + i];
    }
    HString* result = builtin_intern_string(ctx.heap, buf[:copy_len]);
    ctx.result.tag = STRING;
    ctx.result.pointer = result;
}

/// String.prototype.substring(start, end) — ES5 §15.5.4.15
fn void builtin_string_proto_substring(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }
    uint len = s_hstr.blen;

    double start_d = (ctx.argc > 0) ? builtin_to_integer(&ctx.regs[ctx.base_reg]) : 0.0;
    double end_d = (ctx.argc > 1) ? builtin_to_integer(&ctx.regs[ctx.base_reg + 1]) : (double)len;

    uint start = clamp_index(start_d, len);
    uint end = clamp_index(end_d, len);

    uint from = start < end ? start : end;
    uint to = start < end ? end : start;

    if (from >= to) {
        ctx.result.tag = STRING;
        ctx.result.pointer = builtin_intern_string(ctx.heap, "");
        return;
    }

    uint substr_len = to - from;
    char* cstr = s_hstr.get_cstr();
    char[256] buf;
    usz copy_len = (usz)(substr_len < 256 ? substr_len : 256);
    for (usz i = 0; i < copy_len; i++) {
        buf[i] = cstr[from + i];
    }
    HString* result = builtin_intern_string(ctx.heap, buf[:copy_len]);
    ctx.result.tag = STRING;
    ctx.result.pointer = result;
}

/// String.prototype.substr(start, length) — ES5 §B.2.3
fn void builtin_string_proto_substr(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }
    uint len = s_hstr.blen;

    double start_d = (ctx.argc > 0) ? builtin_to_integer(&ctx.regs[ctx.base_reg]) : 0.0;

    int start_i;
    if (math::is_nan(start_d)) {
        start_i = 0;
    } else if (start_d < 0) {
        start_i = (int)(long)start_d + (int)len;
        if (start_i < 0) start_i = 0;
    } else {
        start_i = (int)(long)start_d;
        if (start_i > (int)len) start_i = (int)len;
    }

    double length_d;
    if (ctx.argc > 1) {
        length_d = builtin_to_integer(&ctx.regs[ctx.base_reg + 1]);
    } else {
        length_d = (double)(len - (uint)start_i);
    }

    int length_i;
    if (math::is_nan(length_d) || length_d <= 0) {
        ctx.result.tag = STRING;
        ctx.result.pointer = builtin_intern_string(ctx.heap, "");
        return;
    }
    length_i = (int)(long)length_d;
    if (length_i > (int)len - start_i) {
        length_i = (int)len - start_i;
    }
    if (length_i <= 0) {
        ctx.result.tag = STRING;
        ctx.result.pointer = builtin_intern_string(ctx.heap, "");
        return;
    }

    char* cstr = s_hstr.get_cstr();
    char[256] buf;
    usz copy_len = (usz)((uint)length_i < 256 ? (uint)length_i : 256);
    for (usz i = 0; i < copy_len; i++) {
        buf[i] = cstr[(uint)start_i + i];
    }
    HString* result = builtin_intern_string(ctx.heap, buf[:copy_len]);
    ctx.result.tag = STRING;
    ctx.result.pointer = result;
}

/// String.prototype.toLowerCase() — ES5 §15.5.4.17 (ASCII-only)
fn void builtin_string_proto_toLowerCase(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;

    char[256] buf;
    usz copy_len = len < 256 ? (usz)len : 256;
    for (usz i = 0; i < copy_len; i++) {
        char c = data[i];
        if (c >= 'A' && c <= 'Z') {
            buf[i] = (char)(c + 32);
        } else {
            buf[i] = c;
        }
    }
    HString* result = builtin_intern_string(ctx.heap, buf[:copy_len]);
    ctx.result.tag = STRING;
    ctx.result.pointer = result;
}

/// String.prototype.toUpperCase() — ES5 §15.5.4.18 (ASCII-only)
fn void builtin_string_proto_toUpperCase(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;

    char[256] buf;
    usz copy_len = len < 256 ? (usz)len : 256;
    for (usz i = 0; i < copy_len; i++) {
        char c = data[i];
        if (c >= 'a' && c <= 'z') {
            buf[i] = (char)(c - 32);
        } else {
            buf[i] = c;
        }
    }
    HString* result = builtin_intern_string(ctx.heap, buf[:copy_len]);
    ctx.result.tag = STRING;
    ctx.result.pointer = result;
}

/// String.prototype.trim() — ES5 §15.5.4.20
fn void builtin_string_proto_trim(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;

    // Trim leading whitespace
    uint start = 0;
    while (start < len && is_ecma_whitespace(data[start])) {
        start++;
    }

    // All whitespace
    if (start == len) {
        ctx.result.tag = STRING;
        ctx.result.pointer = builtin_intern_string(ctx.heap, "");
        return;
    }

    // Trim trailing whitespace
    uint end = len;
    while (end > start && is_ecma_whitespace(data[end - 1])) {
        end--;
    }

    uint substr_len = end - start;
    char[256] buf;
    usz copy_len = substr_len < 256 ? (usz)substr_len : 256;
    for (usz i = 0; i < copy_len; i++) {
        buf[i] = data[start + i];
    }
    HString* result = builtin_intern_string(ctx.heap, buf[:copy_len]);
    ctx.result.tag = STRING;
    ctx.result.pointer = result;
}

/// String.prototype.split(separator, limit) — ES5 §15.5.4.14 (string-only separator)
fn void builtin_string_proto_split(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;

    // Create result array
    HObject*? arr_raw = hobject::hobject_alloc(ctx.heap, hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;

    // If separator is undefined, return [string]
    if (ctx.argc == 0 || ctx.regs[ctx.base_reg].tag == UNDEFINED) {
        TVal elem;
        elem.tag = STRING;
        elem.pointer = s_hstr;
        HString* zero_key = builtin_intern_string(ctx.heap, "0");
        arr.put_prop(zero_key, elem, hobject::PROP_FLAGS_WEC);
        TVal len_val;
        len_val.tag = FASTINT;
        len_val.fastint = 1;
        HString* len_key = builtin_intern_string(ctx.heap, "length");
        arr.put_prop(len_key, len_val, hobject::PROP_FLAGS_WEC);
        ctx.result.tag = OBJECT;
        ctx.result.pointer = arr;
        return;
    }

    // Get separator string
    HString* sep_hstr = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg]);
    if (sep_hstr == null) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }

    // Get limit
    uint limit = 0xFFFFFFFF;
    if (ctx.argc > 1) {
        double limit_d = builtin_to_integer(&ctx.regs[ctx.base_reg + 1]);
        if (!math::is_nan(limit_d) && limit_d >= 0) {
            limit = (uint)(long)limit_d;
        }
    }

    char* sep_data = sep_hstr.get_cstr();
    uint sep_len = sep_hstr.blen;

    // Empty separator: split by character
    if (sep_len == 0) {
        uint count = len < limit ? len : limit;
        HString* len_key = builtin_intern_string(ctx.heap, "length");
        TVal len_val;
        len_val.tag = FASTINT;
        len_val.fastint = (long)count;
        arr.put_prop(len_key, len_val, hobject::PROP_FLAGS_WEC);
        for (uint i = 0; i < count; i++) {
            char[2] buf;
            buf[0] = data[i];
            buf[1] = 0;
            HString* ch_str = builtin_intern_string(ctx.heap, buf[:1]);
            TVal elem;
            elem.tag = STRING;
            elem.pointer = ch_str;
            char[16] idx_buf;
            int idx_len = libc::snprintf(&idx_buf, 16, "%d", i);
            HString* idx_key = builtin_intern_string(ctx.heap, idx_buf[:idx_len]);
            arr.put_prop(idx_key, elem, hobject::PROP_FLAGS_WEC);
        }
        ctx.result.tag = OBJECT;
        ctx.result.pointer = arr;
        return;
    }

    // Non-empty separator: split by separator
    uint arr_idx = 0;
    uint search_pos = 0;
    HString* len_key = builtin_intern_string(ctx.heap, "length");

    while (search_pos + sep_len <= len && arr_idx < limit) {
        // Find separator
        int found_pos = -1;
        for (uint i = search_pos; i + sep_len <= len; i++) {
            bool match = true;
            for (uint j = 0; j < sep_len; j++) {
                if (data[i + j] != sep_data[j]) {
                    match = false;
                    break;
                }
            }
            if (match) {
                found_pos = (int)i;
                break;
            }
        }

        if (found_pos < 0) break;

        // Extract substring from search_pos to found_pos
        uint substr_len = (uint)found_pos - search_pos;
        HString* substr;
        if (substr_len == 0) {
            substr = builtin_intern_string(ctx.heap, "");
        } else {
            char[256] buf;
            usz copy_len = substr_len < 256 ? (usz)substr_len : 256;
            for (usz i = 0; i < copy_len; i++) {
                buf[i] = data[search_pos + i];
            }
            substr = builtin_intern_string(ctx.heap, buf[:copy_len]);
        }

        // Add to array
        TVal elem;
        elem.tag = STRING;
        elem.pointer = substr;
        char[16] idx_buf;
        int idx_len = libc::snprintf(&idx_buf, 16, "%d", arr_idx);
        HString* idx_key = builtin_intern_string(ctx.heap, idx_buf[:idx_len]);
        arr.put_prop(idx_key, elem, hobject::PROP_FLAGS_WEC);
        arr_idx++;

        search_pos = (uint)(found_pos + (int)sep_len);
    }

    // Add remaining part if not at limit
    if (arr_idx < limit) {
        uint substr_len = len - search_pos;
        HString* substr;
        if (substr_len == 0) {
            substr = builtin_intern_string(ctx.heap, "");
        } else {
            char[256] buf;
            usz copy_len = substr_len < 256 ? (usz)substr_len : 256;
            for (usz i = 0; i < copy_len; i++) {
                buf[i] = data[search_pos + i];
            }
            substr = builtin_intern_string(ctx.heap, buf[:copy_len]);
        }
        TVal elem;
        elem.tag = STRING;
        elem.pointer = substr;
        char[16] idx_buf;
        int idx_len = libc::snprintf(&idx_buf, 16, "%d", arr_idx);
        HString* idx_key = builtin_intern_string(ctx.heap, idx_buf[:idx_len]);
        arr.put_prop(idx_key, elem, hobject::PROP_FLAGS_WEC);
        arr_idx++;
    }

    TVal len_val;
    len_val.tag = FASTINT;
    len_val.fastint = (long)arr_idx;
    arr.put_prop(len_key, len_val, hobject::PROP_FLAGS_WEC);

    ctx.result.tag = OBJECT;
    ctx.result.pointer = arr;
}

/// String.prototype.concat(...args) — ES5 §15.5.4.6
fn void builtin_string_proto_concat(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }

    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;

    // Concatenate all into a buffer
    // First, compute total length
    uint total_len = len;
    usz max_args = ctx.argc < 256 ? (usz)ctx.argc : 256;
    for (usz i = 0; i < max_args; i++) {
        HString* arg_str = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg + i]);
        if (arg_str == null) continue;
        total_len += arg_str.blen;
    }

    if (total_len > 512) total_len = 512;  // cap buffer size

    char[512] buf;
    usz offset = 0;

    // Copy original string
    usz orig_copy = (usz)(len < 512 ? len : 512);
    for (usz i = 0; i < orig_copy; i++) {
        buf[offset++] = data[i];
    }

    // Copy each arg
    for (usz i = 0; i < max_args && offset < 512; i++) {
        HString* arg_str = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg + i]);
        if (arg_str == null) continue;
        char* arg_data = arg_str.get_cstr();
        uint arg_len = arg_str.blen;
        usz copy = (usz)(arg_len < (512 - offset) ? arg_len : (512 - offset));
        for (usz j = 0; j < copy; j++) {
            buf[offset++] = arg_data[j];
        }
    }

    HString* result = builtin_intern_string(ctx.heap, buf[:offset]);
    ctx.result.tag = STRING;
    ctx.result.pointer = result;
}

/// String.prototype.replace(searchValue, replaceValue) — ES5 §15.5.4.11 (string-only)
fn void builtin_string_proto_replace(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }

    // If not enough args or searchValue is RegExp-like (object), return string as-is
    if (ctx.argc < 1) {
        ctx.result.tag = STRING;
        ctx.result.pointer = s_hstr;
        return;
    }

    TVal* search_val = &ctx.regs[ctx.base_reg];

    // If searchValue is an object (RegExp), return original string for now
    if (search_val.tag == OBJECT) {
        ctx.result.tag = STRING;
        ctx.result.pointer = s_hstr;
        return;
    }

    HString* search_hstr = builtin_to_string(ctx.heap, search_val);
    if (search_hstr == null) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }

    // Get replaceValue
    HString* replace_hstr;
    if (ctx.argc > 1) {
        replace_hstr = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg + 1]);
    } else {
        replace_hstr = builtin_intern_string(ctx.heap, "undefined");
    }
    if (replace_hstr == null) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }

    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;
    char* search_data = search_hstr.get_cstr();
    uint search_len = search_hstr.blen;

    // Find first occurrence
    int found_pos = -1;
    for (uint i = 0; i + search_len <= len; i++) {
        bool match = true;
        for (uint j = 0; j < search_len; j++) {
            if (data[i + j] != search_data[j]) {
                match = false;
                break;
            }
        }
        if (match) {
            found_pos = (int)i;
            break;
        }
    }

    if (found_pos < 0) {
        // Not found: return original string
        ctx.result.tag = STRING;
        ctx.result.pointer = s_hstr;
        return;
    }

    // Build result: prefix + replacement + suffix
    char* replace_data = replace_hstr.get_cstr();
    uint replace_len = replace_hstr.blen;

    uint total = len - search_len + replace_len;
    if (total > 512) total = 512;

    char[512] buf;
    usz offset = 0;

    // Copy prefix (before match)
    for (usz i = 0; i < (usz)found_pos && offset < 512; i++) {
        buf[offset++] = data[i];
    }

    // Copy replacement
    for (usz i = 0; i < (usz)replace_len && offset < 512; i++) {
        buf[offset++] = replace_data[i];
    }

    // Copy suffix (after match)
    uint suffix_start = (uint)(found_pos + (int)search_len);
    for (usz i = (usz)suffix_start; i < (usz)len && offset < 512; i++) {
        buf[offset++] = data[i];
    }

    HString* result = builtin_intern_string(ctx.heap, buf[:offset]);
    ctx.result.tag = STRING;
    ctx.result.pointer = result;
}

// ============================================================================
// Number constructor builtins
// ============================================================================

/// Helper: extract the double value from 'this' for Number.prototype methods.
/// Returns NaN on incompatible 'this' (caller checks via isnan).
fn double number_proto_get_this(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.tag == OBJECT && this_val.pointer != null) {
        HObject* obj = (HObject*)this_val.pointer;
        if (obj.get_class() == hobject::ObjClass.NUMBER &&
            (obj.primitive_value.tag == NUMBER || obj.primitive_value.tag == FASTINT)) {
            return obj.primitive_value.get_number_or_fastint();
        }
    } else if (this_val.tag == NUMBER) {
        return this_val.number;
    } else if (this_val.tag == FASTINT) {
        return (double)this_val.fastint;
    }
    return double::nan;
}

/// Helper: check if a double is -0.
fn bool is_neg_zero(double d) {
    return d == 0.0 && math::signbit(d);
}

/// Helper: convert a positive integer to a string in the given radix (2-36).
/// Writes at most 64 chars into buf. Returns the number of chars written.
fn int number_to_radix_str(ulong val, uint radix, char* buf, usz buf_size) {
    if (val == 0) {
        buf[0] = '0';
        return 1;
    }
    char[64] tmp;
    int pos = 0;
    while (val > 0 && pos < 64) {
        uint digit = (uint)(val % (ulong)radix);
        val /= (ulong)radix;
        if (digit < 10) {
            tmp[pos++] = (char)('0' + digit);
        } else {
            tmp[pos++] = (char)('a' + digit - 10);
        }
    }
    // Reverse into buf
    int write_pos = 0;
    while (pos > 0 && write_pos < (int)buf_size - 1) {
        pos--;
        buf[write_pos++] = tmp[pos];
    }
    buf[write_pos] = 0;
    return write_pos;
}

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

/// Number.prototype.toString(radix) — ES5 §15.7.4.2
/// Returns string representation in the given radix (2-36), default 10.
fn void builtin_number_proto_toString(BuiltinContext* ctx) {
    double d = number_proto_get_this(ctx);
    if (math::is_nan(d) && !is_neg_zero(d)) {
        HString* s = builtin_intern_string(ctx.heap, "NaN");
        ctx.result.tag = STRING;
        ctx.result.pointer = s;
        return;
    }

    // Determine radix
    int radix = 10;
    if (ctx.argc > 0) {
        TVal* rad_arg = &ctx.regs[ctx.base_reg];
        if (rad_arg.tag == FASTINT) {
            radix = (int)rad_arg.fastint;
        } else if (rad_arg.tag == NUMBER) {
            radix = (int)(long)rad_arg.number;
        } else {
            radix = 10;
        }
        if (radix < 2 || radix > 36) {
            // RangeError
            ctx.result.tag = UNDEFINED;
            ctx.result.pointer = null;
            return;
        }
    }

    // Handle special values
    if (math::is_nan(d) && !is_neg_zero(d)) {
        HString* s = builtin_intern_string(ctx.heap, "NaN");
        ctx.result.tag = STRING;
        ctx.result.pointer = s;
        return;
    }
    if (math::is_inf(d)) {
        HString* s = builtin_intern_string(ctx.heap, d > 0 ? "Infinity" : "-Infinity");
        ctx.result.tag = STRING;
        ctx.result.pointer = s;
        return;
    }
    if (d == 0.0) {
        HString* s = builtin_intern_string(ctx.heap, "0");
        ctx.result.tag = STRING;
        ctx.result.pointer = s;
        return;
    }

    // Radix 10: use existing ToString formatting
    if (radix == 10) {
        char[64] buf;
        int len = libc::snprintf(&buf, 64, "%.17g", d);
        if (len < 0 || len >= 64) {
            ctx.result.tag = UNDEFINED;
            ctx.result.pointer = null;
            return;
        }
        HString* s = builtin_intern_string(ctx.heap, buf[:len]);
        ctx.result.tag = STRING;
        ctx.result.pointer = s;
        return;
    }

    // Radix 2-36: manual conversion
    bool negative = d < 0;
    if (negative) d = -d;

    // Split into integer and fractional parts
    double int_part = math::trunc(d);
    double frac_part = d - int_part;

    char[128] buf;
    usz offset = 0;

    if (negative) {
        buf[offset++] = '-';
    }

    // Convert integer part
    ulong int_val = (ulong)(long)int_part;
    char[64] int_digits;
    int int_len = number_to_radix_str(int_val, (uint)radix, &int_digits, 64);
    for (int i = 0; i < int_len; i++) {
        buf[offset++] = int_digits[i];
    }

    // Convert fractional part (up to 20 digits)
    if (frac_part > 0.0 && offset < 120) {
        buf[offset++] = '.';
        int max_frac_digits = 20;
        if ((int)offset + max_frac_digits > 127) max_frac_digits = 127 - (int)offset;
        for (int i = 0; i < max_frac_digits; i++) {
            frac_part *= (double)radix;
            uint digit = (uint)(long)frac_part;
            if (digit >= (uint)radix) digit = (uint)radix - 1;
            frac_part -= (double)digit;
            if (digit < 10) {
                buf[offset++] = (char)('0' + digit);
            } else {
                buf[offset++] = (char)('a' + digit - 10);
            }
            if (frac_part <= 0.0) break;
        }
    }

    HString* result = builtin_intern_string(ctx.heap, buf[:offset]);
    if (result == null) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }
    ctx.result.tag = STRING;
    ctx.result.pointer = result;
}

/// Number.prototype.toFixed(fractionDigits) — ES5 §15.7.4.5
fn void builtin_number_proto_toFixed(BuiltinContext* ctx) {
    double d = number_proto_get_this(ctx);
    if (math::is_nan(d) && !is_neg_zero(d)) {
        // Use isnan check
        double test = d;
        if (math::is_nan(test) && !is_neg_zero(d)) {
            // Actually re-check — the first call with NaN might fail
            // Just use a simpler approach
        }
    }
    // Re-get properly
    d = number_proto_get_this(ctx);
    if (math::is_nan(d) && !is_neg_zero(d)) {
        HString* s = builtin_intern_string(ctx.heap, "NaN");
        ctx.result.tag = STRING;
        ctx.result.pointer = s;
        return;
    }
    if (math::is_inf(d)) {
        HString* s = builtin_intern_string(ctx.heap, d > 0 ? "Infinity" : "-Infinity");
        ctx.result.tag = STRING;
        ctx.result.pointer = s;
        return;
    }

    int f = 0;
    if (ctx.argc > 0) {
        double f_d = builtin_to_integer(&ctx.regs[ctx.base_reg]);
        if (f_d < 0 || f_d > 20) {
            ctx.result.tag = UNDEFINED;
            ctx.result.pointer = null;
            return;
        }
        f = (int)(long)f_d;
    }

    char[64] buf;
    int len = libc::snprintf(&buf, 64, "%.*f", f, d);
    if (len < 0 || len >= 64) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }
    HString* s = builtin_intern_string(ctx.heap, buf[:len]);
    ctx.result.tag = STRING;
    ctx.result.pointer = s;
}

/// Number.prototype.toExponential(fractionDigits) — ES5 §15.7.4.6
fn void builtin_number_proto_toExponential(BuiltinContext* ctx) {
    double d = number_proto_get_this(ctx);
    if (math::is_nan(d) && !is_neg_zero(d)) {
        HString* s = builtin_intern_string(ctx.heap, "NaN");
        ctx.result.tag = STRING;
        ctx.result.pointer = s;
        return;
    }
    if (math::is_inf(d)) {
        HString* s = builtin_intern_string(ctx.heap, d > 0 ? "Infinity" : "-Infinity");
        ctx.result.tag = STRING;
        ctx.result.pointer = s;
        return;
    }

    if (ctx.argc == 0) {
        // No arg: use default ToString behavior via %.17g (same as toString)
        char[64] buf;
        int len = libc::snprintf(&buf, 64, "%.17g", d);
        if (len < 0 || len >= 64) {
            ctx.result.tag = UNDEFINED;
            ctx.result.pointer = null;
            return;
        }
        HString* s = builtin_intern_string(ctx.heap, buf[:len]);
        ctx.result.tag = STRING;
        ctx.result.pointer = s;
        return;
    }

    double f_d = builtin_to_integer(&ctx.regs[ctx.base_reg]);
    if (f_d < 0 || f_d > 20) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }
    int f = (int)(long)f_d;

    char[64] buf;
    int len = libc::snprintf(&buf, 64, "%.*e", f, d);
    if (len < 0 || len >= 64) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }
    HString* s = builtin_intern_string(ctx.heap, buf[:len]);
    ctx.result.tag = STRING;
    ctx.result.pointer = s;
}

/// Number.prototype.toPrecision(precision) — ES5 §15.7.4.7
fn void builtin_number_proto_toPrecision(BuiltinContext* ctx) {
    double d = number_proto_get_this(ctx);
    if (math::is_nan(d) && !is_neg_zero(d)) {
        HString* s = builtin_intern_string(ctx.heap, "NaN");
        ctx.result.tag = STRING;
        ctx.result.pointer = s;
        return;
    }
    if (math::is_inf(d)) {
        HString* s = builtin_intern_string(ctx.heap, d > 0 ? "Infinity" : "-Infinity");
        ctx.result.tag = STRING;
        ctx.result.pointer = s;
        return;
    }

    if (ctx.argc == 0) {
        // No arg: return ToString(x)
        char[64] buf;
        int len = libc::snprintf(&buf, 64, "%.17g", d);
        if (len < 0 || len >= 64) {
            ctx.result.tag = UNDEFINED;
            ctx.result.pointer = null;
            return;
        }
        HString* s = builtin_intern_string(ctx.heap, buf[:len]);
        ctx.result.tag = STRING;
        ctx.result.pointer = s;
        return;
    }

    double p_d = builtin_to_integer(&ctx.regs[ctx.base_reg]);
    if (p_d < 1 || p_d > 21) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }
    int p = (int)(long)p_d;

    char[64] buf;
    int len = libc::snprintf(&buf, 64, "%.*g", p, d);
    if (len < 0 || len >= 64) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }
    HString* s = builtin_intern_string(ctx.heap, buf[:len]);
    ctx.result.tag = STRING;
    ctx.result.pointer = s;
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

// ============================================================================
// Array.prototype helpers
// ============================================================================

/// Helper: get the 'this' value as an object for Array.prototype methods.
fn HObject* array_proto_get_this(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.tag == OBJECT && this_val.pointer != null) {
        return (HObject*)this_val.pointer;
    }
    // TypeError: Array.prototype method called on non-object
    HObject*? err_raw = hobject::hobject_alloc(ctx.heap, hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_str = builtin_intern_string(ctx.heap,
            "Array.prototype method called on incompatible value");
        if (msg_str != null) {
            TVal msg_val;
            msg_val.tag = STRING;
            msg_val.pointer = msg_str;
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
        }
    }
    return null;
}

/// Get the 'length' property of an array-like object as a uint.
fn uint array_get_length(HObject* obj, Heap* heap) {
    HString* len_key = builtin_intern_string(heap, "length");
    if (len_key == null) return 0;
    TVal? len_val = obj.get_prop_proto(len_key);
    if (try v = len_val) {
        if (v.tag == FASTINT) return (uint)(long)v.fastint;
        if (v.tag == NUMBER) return (uint)(long)v.number;
    }
    return 0;
}

/// Set the 'length' property of an array-like object.
fn void array_set_length(HObject* obj, uint len_val, Heap* heap) {
    HString* len_key = builtin_intern_string(heap, "length");
    if (len_key == null) return;
    TVal tv;
    tv.tag = FASTINT;
    tv.fastint = (long)len_val;
    obj.put_prop(len_key, tv, hobject::PROP_FLAGS_WEC);
}

/// Get array element at numeric index (returns undefined for holes).
fn TVal array_get_elem(HObject* obj, uint idx, Heap* heap) {
    char[16] buf;
    int len = libc::snprintf(&buf, 16, "%d", idx);
    if (len <= 0 || len >= 16) { TVal undef; undef.tag = UNDEFINED; undef.pointer = null; return undef; }
    HString* key = builtin_intern_string(heap, buf[:len]);
    if (key == null) { TVal undef; undef.tag = UNDEFINED; undef.pointer = null; return undef; }
    TVal? result = obj.get_prop_proto(key);
    if (try v = result) return v;
    TVal undef; undef.tag = UNDEFINED; undef.pointer = null; return undef;
}

/// Set array element at numeric index.
fn void array_set_elem(HObject* obj, uint idx, TVal val, Heap* heap) {
    char[16] buf;
    int len = libc::snprintf(&buf, 16, "%d", idx);
    if (len <= 0 || len >= 16) return;
    HString* key = builtin_intern_string(heap, buf[:len]);
    if (key == null) return;
    obj.put_prop(key, val, hobject::PROP_FLAGS_WEC);
}

/// Delete array element at numeric index (remove the property entirely).
fn void array_delete_elem(HObject* obj, uint idx, Heap* heap) {
    char[16] buf;
    int len = libc::snprintf(&buf, 16, "%d", idx);
    if (len <= 0 || len >= 16) return;
    HString* key = builtin_intern_string(heap, buf[:len]);
    if (key == null) return;
    obj.delete_prop(key);
}

/// Strict equality comparison for Array.prototype.indexOf / lastIndexOf.
fn bool array_strict_equals(TVal a, TVal b) {
    if (a.tag == b.tag) {
        switch (a.tag) {
            case UNDEFINED: return true;
            case NULL_VAL:  return true;
            case BOOLEAN:   return a.boolean == b.boolean;
            case NUMBER:
                if (math::is_nan(a.number) || math::is_nan(b.number)) return false;
                return a.number == b.number;
            case FASTINT:   return a.fastint == b.fastint;
            case STRING:    return a.pointer == b.pointer;
            default: return false;
        }
    }
    if ((a.tag == NUMBER && b.tag == FASTINT) || (a.tag == FASTINT && b.tag == NUMBER)) {
        double av = a.tag == FASTINT ? (double)a.fastint : a.number;
        double bv = b.tag == FASTINT ? (double)b.fastint : b.number;
        return av == bv;
    }
    return false;
}

/// Helper: register a method on Array.prototype.
fn bool register_array_proto_method(HObject* proto, Heap* heap, char[] name, uint fn_index) {
    uint hash = heap.hash_string(name);
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
    tv.tag = LIGHTFUNC;
    tv.fastint = (long)fn_index;
    proto.put_prop(key, tv, hobject::PROP_FLAGS_WEC);
    return true;
}

// ============================================================================
// Array.prototype.toString (ES5 §15.4.4.2)
// ============================================================================
//
// Join all elements with comma separator.
fn void builtin_array_proto_toString(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }

    uint len = array_get_length(obj, ctx.heap);
    char[4096] buf;
    usz offset = 0;

    for (uint i = 0; i < len; i++) {
        if (i > 0) {
            if (offset < 4095) buf[offset++] = ',';
        }
        TVal elem = array_get_elem(obj, i, ctx.heap);
        if (elem.tag != UNDEFINED && elem.tag != NULL_VAL) {
            HString* elem_str = builtin_to_string(ctx.heap, &elem);
            if (elem_str != null) {
                char* data = elem_str.get_cstr();
                uint blen = elem_str.blen;
                uint max_copy = blen;
                if ((uint)offset + max_copy > 4090) max_copy = 4090 - (uint)offset;
                for (uint j = 0; j < max_copy; j++) {
                    buf[offset++] = data[j];
                }
            }
        }
    }

    HString* result = builtin_intern_string(ctx.heap, buf[:offset]);
    if (result == null) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }
    ctx.result.tag = STRING;
    ctx.result.pointer = result;
}

// ============================================================================
// Array.prototype.join (ES5 §15.4.4.5)
// ============================================================================
fn void builtin_array_proto_join(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }

    // Get separator (default ",")
    char[] sep = ",";
    if (ctx.argc > 0) {
        TVal sep_val = ctx.regs[ctx.base_reg];
        HString* sep_str = builtin_to_string(ctx.heap, &sep_val);
        if (sep_str != null) {
            sep = sep_str.get_data();
        }
    }

    uint len = array_get_length(obj, ctx.heap);

    // Empty array returns ""
    if (len == 0) {
        HString* result = builtin_intern_string(ctx.heap, "");
        if (result == null) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }
        ctx.result.tag = STRING;
        ctx.result.pointer = result;
        return;
    }

    char[4096] buf;
    usz offset = 0;

    for (uint i = 0; i < len; i++) {
        if (i > 0) {
            for (usz si = 0; si < sep.len && offset < 4090; si++) {
                buf[offset++] = sep[si];
            }
        }
        TVal elem = array_get_elem(obj, i, ctx.heap);
        if (elem.tag != UNDEFINED && elem.tag != NULL_VAL) {
            HString* elem_str = builtin_to_string(ctx.heap, &elem);
            if (elem_str != null) {
                char* data = elem_str.get_cstr();
                uint blen = elem_str.blen;
                uint max_copy = blen;
                if (offset + max_copy > 4090) max_copy = 4090 - (uint)offset;
                for (uint j = 0; j < max_copy; j++) {
                    buf[offset++] = data[j];
                }
            }
        }
    }

    HString* result = builtin_intern_string(ctx.heap, buf[:offset]);
    if (result == null) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }
    ctx.result.tag = STRING;
    ctx.result.pointer = result;
}

// ============================================================================
// Array.prototype.pop (ES5 §15.4.4.6)
// ============================================================================
fn void builtin_array_proto_pop(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }

    uint len = array_get_length(obj, ctx.heap);
    if (len == 0) {
        array_set_length(obj, 0, ctx.heap);
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }

    uint idx = len - 1;
    TVal elem = array_get_elem(obj, idx, ctx.heap);
    array_delete_elem(obj, idx, ctx.heap);
    array_set_length(obj, idx, ctx.heap);

    // Return the popped element
    ctx.result.tag = elem.tag;
    ctx.result.fastint = elem.fastint;
    ctx.result.boolean = elem.boolean;
    ctx.result.pointer = elem.pointer;
    ctx.result.number = elem.number;
}

// ============================================================================
// Array.prototype.push (ES5 §15.4.4.7)
// ============================================================================
fn void builtin_array_proto_push(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }

    uint len = array_get_length(obj, ctx.heap);

    for (ushort i = 0; i < ctx.argc; i++) {
        TVal arg = ctx.regs[ctx.base_reg + i];
        array_set_elem(obj, len + i, arg, ctx.heap);
    }

    uint new_len = len + (uint)ctx.argc;
    array_set_length(obj, new_len, ctx.heap);

    ctx.result.tag = FASTINT;
    ctx.result.fastint = (long)new_len;
}

// ============================================================================
// Array.prototype.reverse (ES5 §15.4.4.8)
// ============================================================================
fn void builtin_array_proto_reverse(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }

    uint len = array_get_length(obj, ctx.heap);
    uint middle = len / 2;

    for (uint lower = 0; lower < middle; lower++) {
        uint upper = len - 1 - lower;
        TVal lower_val = array_get_elem(obj, lower, ctx.heap);
        TVal upper_val = array_get_elem(obj, upper, ctx.heap);
        array_set_elem(obj, lower, upper_val, ctx.heap);
        array_set_elem(obj, upper, lower_val, ctx.heap);
    }

    ctx.result.tag = OBJECT;
    ctx.result.pointer = obj;
}

// ============================================================================
// Array.prototype.shift (ES5 §15.4.4.9)
// ============================================================================
fn void builtin_array_proto_shift(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }

    uint len = array_get_length(obj, ctx.heap);
    if (len == 0) {
        array_set_length(obj, 0, ctx.heap);
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
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
    ctx.result.tag = first.tag;
    ctx.result.fastint = first.fastint;
    ctx.result.boolean = first.boolean;
    ctx.result.pointer = first.pointer;
    ctx.result.number = first.number;
}

// ============================================================================
// Array.prototype.slice (ES5 §15.4.4.10)
// ============================================================================
fn void builtin_array_proto_slice(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }

    uint len = array_get_length(obj, ctx.heap);

    // Determine start
    double relative_start = 0.0;
    if (ctx.argc > 0) {
        TVal* arg = &ctx.regs[ctx.base_reg];
        if (arg.tag == FASTINT) {
            relative_start = (double)arg.fastint;
        } else if (arg.tag == NUMBER) {
            relative_start = arg.number;
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
        if (arg.tag == FASTINT) {
            relative_end = (double)arg.fastint;
        } else if (arg.tag == NUMBER) {
            relative_end = arg.number;
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
    HObject*? new_arr = hobject::hobject_alloc(ctx.heap, hobject::ObjClass.ARRAY);
    if (catch err = new_arr) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
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

    ctx.result.tag = OBJECT;
    ctx.result.pointer = result_arr;
}

// ============================================================================
// Array.prototype.sort (ES5 §15.4.4.11) — default compare (no comparefn)
// ============================================================================
fn void builtin_array_proto_sort(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }

    uint len = array_get_length(obj, ctx.heap);
    if (len <= 1) {
        ctx.result.tag = OBJECT;
        ctx.result.pointer = obj;
        return;
    }

    // Compact defined elements to the front
    uint def_count = 0;
    for (uint i = 0; i < len; i++) {
        TVal elem = array_get_elem(obj, i, ctx.heap);
        if (elem.tag != UNDEFINED) {
            array_set_elem(obj, def_count, elem, ctx.heap);
            def_count++;
        }
    }

    // Bubble-sort defined elements by string comparison
    for (uint i = 0; i < def_count; i++) {
        for (uint j = 0; j < def_count - 1 - i; j++) {
            TVal a = array_get_elem(obj, j, ctx.heap);
            TVal b = array_get_elem(obj, j + 1, ctx.heap);
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
                array_set_elem(obj, j, b, ctx.heap);
                array_set_elem(obj, j + 1, a, ctx.heap);
            }
        }
    }

    // Delete remaining elements (holes/undefined go to end)
    for (uint i = def_count; i < len; i++) {
        array_delete_elem(obj, i, ctx.heap);
    }

    ctx.result.tag = OBJECT;
    ctx.result.pointer = obj;
}

// ============================================================================
// Array.prototype.splice (ES5 §15.4.4.12)
// ============================================================================
fn void builtin_array_proto_splice(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }

    uint len = array_get_length(obj, ctx.heap);

    // Get relativeStart (argument 0)
    double relative_start = 0.0;
    if (ctx.argc > 0) {
        TVal* arg = &ctx.regs[ctx.base_reg];
        if (arg.tag == FASTINT) {
            relative_start = (double)arg.fastint;
        } else if (arg.tag == NUMBER) {
            relative_start = arg.number;
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
        if (arg.tag == FASTINT) {
            delete_count = (double)arg.fastint;
        } else if (arg.tag == NUMBER) {
            delete_count = arg.number;
        } else {
            delete_count = 0;
        }

        if (delete_count < 0) delete_count = 0;
        uint dc = (uint)(long)delete_count;
        actual_delete_count = dc > (len - actual_start) ? (len - actual_start) : dc;
    }

    // Create result array with deleted items
    HObject*? result_raw = hobject::hobject_alloc(ctx.heap, hobject::ObjClass.ARRAY);
    if (catch err = result_raw) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
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

    ctx.result.tag = OBJECT;
    ctx.result.pointer = result;
}

// ============================================================================
// Array.prototype.unshift (ES5 §15.4.4.13)
// ============================================================================
fn void builtin_array_proto_unshift(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }

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

    ctx.result.tag = FASTINT;
    ctx.result.fastint = (long)new_len;
}

// ============================================================================
// Array.prototype.indexOf (ES5 §15.4.4.14)
// ============================================================================
fn void builtin_array_proto_indexOf(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }

    uint len = array_get_length(obj, ctx.heap);

    if (ctx.argc == 0) {
        ctx.result.tag = FASTINT;
        ctx.result.fastint = -1;
        return;
    }

    TVal search_elem = ctx.regs[ctx.base_reg];

    // Get fromIndex (default 0)
    double relative_start = 0.0;
    if (ctx.argc > 1) {
        TVal* arg = &ctx.regs[ctx.base_reg + 1];
        if (arg.tag == FASTINT) {
            relative_start = (double)arg.fastint;
        } else if (arg.tag == NUMBER) {
            relative_start = arg.number;
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
        TVal elem = array_get_elem(obj, k, ctx.heap);
        if (array_strict_equals(elem, search_elem)) {
            ctx.result.tag = FASTINT;
            ctx.result.fastint = (long)k;
            return;
        }
    }

    ctx.result.tag = FASTINT;
    ctx.result.fastint = -1;
}

// ============================================================================
// Array.prototype.lastIndexOf (ES5 §15.4.4.15)
// ============================================================================
fn void builtin_array_proto_lastIndexOf(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }

    uint len = array_get_length(obj, ctx.heap);

    if (ctx.argc == 0) {
        ctx.result.tag = FASTINT;
        ctx.result.fastint = -1;
        return;
    }

    TVal search_elem = ctx.regs[ctx.base_reg];

    // Get fromIndex (default len - 1)
    double relative_start = (double)(len - 1);
    if (ctx.argc > 1) {
        TVal* arg = &ctx.regs[ctx.base_reg + 1];
        if (arg.tag == FASTINT) {
            relative_start = (double)arg.fastint;
        } else if (arg.tag == NUMBER) {
            relative_start = arg.number;
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
        TVal elem = array_get_elem(obj, (uint)k, ctx.heap);
        if (array_strict_equals(elem, search_elem)) {
            ctx.result.tag = FASTINT;
            ctx.result.fastint = (long)k;
            return;
        }
    }

    ctx.result.tag = FASTINT;
    ctx.result.fastint = -1;
}

// ============================================================================
// Array.prototype.concat (ES5 §15.4.4.4)
// ============================================================================
fn void builtin_array_proto_concat(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }

    // Create result array
    HObject*? new_arr = hobject::hobject_alloc(ctx.heap, hobject::ObjClass.ARRAY);
    if (catch err = new_arr) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
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

    // Then process each argument
    for (ushort arg_i = 0; arg_i < ctx.argc; arg_i++) {
        TVal arg = ctx.regs[ctx.base_reg + arg_i];

        if (arg.tag == OBJECT && ((HObject*)arg.pointer).get_class() == hobject::ObjClass.ARRAY) {
            // If argument is an Array, copy its elements
            HObject* arg_arr = (HObject*)arg.pointer;
            uint arg_len = array_get_length(arg_arr, ctx.heap);
            for (uint i = 0; i < arg_len; i++) {
                TVal elem = array_get_elem(arg_arr, i, ctx.heap);
                array_set_elem(result, n, elem, ctx.heap);
                n++;
            }
        } else {
            // Otherwise, add the argument itself
            array_set_elem(result, n, arg, ctx.heap);
            n++;
        }
    }

    array_set_length(result, n, ctx.heap);

    ctx.result.tag = OBJECT;
    ctx.result.pointer = result;
}

// ============================================================================
// Math method builtins
// ============================================================================

/// Helper: get numeric arg at index i, defaulting to NaN if absent.
fn double math_arg(BuiltinContext* ctx, ushort i) {
    if (i >= ctx.argc) return double::nan;
    TVal* arg = &ctx.regs[ctx.base_reg + i];
    if (arg.tag == FASTINT) return (double)arg.fastint;
    if (arg.tag == NUMBER) return arg.number;
    // Non-numeric — need ToNumber
    TVal num;
    builtin_to_number(arg, &num);
    return num.tag == FASTINT ? (double)num.fastint : num.number;
}

fn void builtin_math_abs(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.tag = NUMBER;
    ctx.result.number = math::abs(x);
}

fn void builtin_math_floor(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.tag = NUMBER;
    ctx.result.number = math::floor(x);
}

fn void builtin_math_ceil(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.tag = NUMBER;
    ctx.result.number = math::ceil(x);
}

fn void builtin_math_round(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.tag = NUMBER;
    // ES5 §15.8.2.15: round half away from zero
    if (math::is_nan(x)) {
        ctx.result.number = double::nan;
    } else if (math::is_inf(x) || x == 0.0) {
        ctx.result.number = x;
    } else {
        // round half up (away from zero)
        double frac = x - math::floor(x);
        if (frac < 0.5) {
            ctx.result.number = math::floor(x);
        } else if (frac > 0.5) {
            ctx.result.number = math::ceil(x);
        } else {
            // exactly 0.5 — round away from zero
            ctx.result.number = math::floor(x) + 1.0;
        }
    }
}

fn void builtin_math_max(BuiltinContext* ctx) {
    if (ctx.argc == 0) {
        ctx.result.tag = NUMBER;
        ctx.result.number = -double::inf;
        return;
    }
    double max = math_arg(ctx, 0);
    for (ushort i = 1; i < ctx.argc; i++) {
        double v = math_arg(ctx, i);
        if (math::is_nan(v)) {
            max = double::nan;
        } else if (v > max || math::is_nan(max)) {
            max = v;
        }
    }
    ctx.result.tag = NUMBER;
    ctx.result.number = max;
}

fn void builtin_math_min(BuiltinContext* ctx) {
    if (ctx.argc == 0) {
        ctx.result.tag = NUMBER;
        ctx.result.number = double::inf;
        return;
    }
    double min = math_arg(ctx, 0);
    for (ushort i = 1; i < ctx.argc; i++) {
        double v = math_arg(ctx, i);
        if (math::is_nan(v)) {
            min = double::nan;
        } else if (v < min || math::is_nan(min)) {
            min = v;
        }
    }
    ctx.result.tag = NUMBER;
    ctx.result.number = min;
}

fn void builtin_math_pow(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    double y = math_arg(ctx, 1);
    ctx.result.tag = NUMBER;
    if (math::is_nan(y) && x != 1.0) {
        ctx.result.number = double::nan;
    } else {
        ctx.result.number = math_pow(x, y);
    }
}

fn void builtin_math_sqrt(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.tag = NUMBER;
    ctx.result.number = math_sqrt(x);
}

fn void builtin_math_exp(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.tag = NUMBER;
    ctx.result.number = math_exp(x);
}

fn void builtin_math_log(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.tag = NUMBER;
    ctx.result.number = math_log(x);
}

fn void builtin_math_sin(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.tag = NUMBER;
    ctx.result.number = math_sin(x);
}

fn void builtin_math_cos(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.tag = NUMBER;
    ctx.result.number = math_cos(x);
}

fn void builtin_math_tan(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.tag = NUMBER;
    ctx.result.number = math_tan(x);
}

/// Math.random() — uses the heap's PRNG state (xorshift32).
fn void builtin_math_random(BuiltinContext* ctx) {
    uint state = ctx.heap.rnd_state;
    state ^= state << 13;
    state ^= state >> 17;
    state ^= state << 5;
    ctx.heap.rnd_state = state;
    ctx.result.tag = NUMBER;
    ctx.result.number = (double)state / 4294967296.0;
}

// ============================================================================
// Function.prototype methods
// ============================================================================

/// Helper: get argument from the value stack by index (0-based within the call).
fn TVal builtin_arg(BuiltinContext* ctx, uint idx) {
    if (idx < ctx.argc) {
        return ctx.regs[ctx.base_reg + idx];
    }
    TVal undef;
    undef.tag = UNDEFINED;
    undef.pointer = null;
    return undef;
}

/// Function.prototype.call(thisArg, ...args)
///
/// Calls `this` (the target function) with `thisArg` as `this` and the
/// remaining arguments passed individually.
///
/// ES5 §15.3.4.4
fn void builtin_function_proto_call(BuiltinContext* ctx) {
    TVal target = ctx.this_val;

    // Validate target is callable
    bool callable = false;
    if (target.tag == LIGHTFUNC) {
        callable = true;
    } else if (target.tag == OBJECT) {
        HObject* hobj = (HObject*)target.pointer;
        if (hobj != null) {
            callable = hobj.is_callable();
        }
    }

    if (!callable) {
        // Throw TypeError
        HObject*? err_raw = hobject::hobject_alloc(ctx.heap, hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.type_err_proto;
            // Cannot easily throw from here — set needs_throw or similar
        }
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }

    // Determine new this value
    TVal new_this;
    if (ctx.argc > 0) {
        new_this = builtin_arg(ctx, 0);
    } else {
        new_this.tag = UNDEFINED;
        new_this.pointer = null;
    }

    // Number of remaining args after thisArg
    ushort remaining = (ctx.argc > 0) ? (ushort)(ctx.argc - 1) : 0;

    // For LIGHTFUNC targets, dispatch directly after shifting args
    if (target.tag == LIGHTFUNC) {
        uint fn_idx = (uint)target.fastint;
        builtins::BuiltinContext inner_ctx;
        inner_ctx.vm = ctx.vm;
        inner_ctx.regs = ctx.regs;
        inner_ctx.base_reg = ctx.base_reg;
        inner_ctx.argc = remaining;
        inner_ctx.result = ctx.result;
        inner_ctx.heap = ctx.heap;
        inner_ctx.this_val = new_this;
        inner_ctx.is_constructor = false;
        inner_ctx.needs_re_dispatch = false;
        inner_ctx.re_nargs = 0;
        // Shift remaining args to start at base_reg
        for (ushort i = 0; i < remaining; i++) {
            ctx.regs[ctx.base_reg + i] = builtin_arg(ctx, i + 1);
        }
        builtins::dispatch_builtin(fn_idx, &inner_ctx);
        return;
    }

    // For OBJECT targets, use re-dispatch mechanism
    if (target.tag == OBJECT) {
        // Replace the function slot with target
        ctx.regs[ctx.base_reg - 2] = target;
        // Replace the this slot with new_this
        ctx.regs[ctx.base_reg - 1] = new_this;
        // Shift remaining args to start at base_reg
        for (ushort i = 0; i < remaining; i++) {
            ctx.regs[ctx.base_reg + i] = builtin_arg(ctx, i + 1);
        }
        // Signal re-dispatch
        ctx.needs_re_dispatch = true;
        ctx.re_nargs = remaining;
    } else {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
    }
}

/// Function.prototype.apply(thisArg, argArray)
///
/// Calls `this` (the target function) with `thisArg` as `this` and the
/// elements of `argArray` passed as individual arguments.
///
/// ES5 §15.3.4.3
fn void builtin_function_proto_apply(BuiltinContext* ctx) {
    TVal target = ctx.this_val;

    // Validate target is callable
    bool callable = false;
    if (target.tag == LIGHTFUNC) {
        callable = true;
    } else if (target.tag == OBJECT) {
        HObject* hobj = (HObject*)target.pointer;
        if (hobj != null) {
            callable = hobj.is_callable();
        }
    }

    if (!callable) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }

    // Get new this value
    TVal new_this;
    if (ctx.argc > 0) {
        new_this = builtin_arg(ctx, 0);
    } else {
        new_this.tag = UNDEFINED;
        new_this.pointer = null;
    }

    // If argArray is undefined or null, call with no args
    TVal arg_array;
    bool has_array = ctx.argc > 1;
    if (has_array) {
        arg_array = builtin_arg(ctx, 1);
        if (arg_array.tag == UNDEFINED || arg_array.tag == NULL_VAL) {
            has_array = false;
        }
    }

    if (!has_array) {
        // Call with no args
        if (target.tag == LIGHTFUNC) {
            uint fn_idx = (uint)target.fastint;
            builtins::BuiltinContext inner_ctx;
            inner_ctx.vm = ctx.vm;
            inner_ctx.regs = ctx.regs;
            inner_ctx.base_reg = ctx.base_reg;
            inner_ctx.argc = 0;
            inner_ctx.result = ctx.result;
            inner_ctx.heap = ctx.heap;
            inner_ctx.this_val = new_this;
            inner_ctx.is_constructor = false;
            inner_ctx.needs_re_dispatch = false;
            inner_ctx.re_nargs = 0;
            builtins::dispatch_builtin(fn_idx, &inner_ctx);
            return;
        }
        if (target.tag == OBJECT) {
            ctx.regs[ctx.base_reg - 2] = target;
            ctx.regs[ctx.base_reg - 1] = new_this;
            ctx.needs_re_dispatch = true;
            ctx.re_nargs = 0;
        } else {
            ctx.result.tag = UNDEFINED;
            ctx.result.pointer = null;
        }
        return;
    }

    // argArray must be an object (array-like)
    if (arg_array.tag != OBJECT || arg_array.pointer == null) {
        // TypeError
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }

    HObject* arr_obj = (HObject*)arg_array.pointer;

    // Get length via property lookup (arrays store length as a named property)
    uint len = 0;
    HString* length_key = builtin_intern_string(ctx.heap, "length");
    TVal? len_val = arr_obj.get_prop_proto(length_key);
    if (try lv = len_val) {
        if (lv.tag == NUMBER || lv.tag == FASTINT) {
            double d = lv.tag == FASTINT ? (double)lv.fastint : lv.number;
            if (d < 0) d = 0;
            if (math::is_nan(d)) d = 0;
            if (d > 4294967295.0) d = 4294967295.0;
            len = (uint)d;
        }
    }

    // Extract elements from argArray — use heap allocation
    uint max_extract = len < 1024 ? len : 1024;
    uint actual_count = 0;
    TVal* extracted_args = null;
    if (max_extract > 0) {
        extracted_args = (TVal*)libc::malloc(TVal::size * max_extract);
    }
    bool is_dense_array = (arr_obj.get_class() == hobject::ObjClass.ARRAY && arr_obj.array_part != null);
    for (uint i = 0; i < max_extract; i++) {
        TVal elem;
        if (is_dense_array && i < arr_obj.array_size) {
            elem = arr_obj.array_part[i];
            if (elem.tag == UNDEFINED) {
                char[20] buf;
                int n = libc::snprintf(&buf, 20, "%d", i);
                if (n <= 0 || n >= 20) break;
                HString* key_hstr = builtin_intern_string(ctx.heap, buf[:n]);
                TVal? prop = arr_obj.get_prop_proto(key_hstr);
                if (try p = prop) {
                    elem = p;
                }
            }
        } else {
            char[20] buf;
            int n = libc::snprintf(&buf, 20, "%d", i);
            if (n <= 0 || n >= 20) break;
            HString* key_hstr = builtin_intern_string(ctx.heap, buf[:n]);
            if (key_hstr == null) { break; }
            TVal? prop = arr_obj.get_prop_proto(key_hstr);
            if (try p = prop) {
                elem = p;
            } else {
                elem.tag = UNDEFINED;
                elem.pointer = null;
            }
        }
        if (actual_count < max_extract) extracted_args[actual_count++] = elem;
    }

    if (target.tag == LIGHTFUNC) {
        uint fn_idx = (uint)target.fastint;
        builtins::BuiltinContext inner_ctx;
        inner_ctx.vm = ctx.vm;
        inner_ctx.regs = ctx.regs;
        inner_ctx.base_reg = ctx.base_reg;
        inner_ctx.argc = (ushort)actual_count;
        inner_ctx.result = ctx.result;
        inner_ctx.heap = ctx.heap;
        inner_ctx.this_val = new_this;
        inner_ctx.is_constructor = false;
        inner_ctx.needs_re_dispatch = false;
        inner_ctx.re_nargs = 0;

        // Write extracted args onto stack
        for (uint i = 0; i < actual_count; i++) {
            ctx.regs[ctx.base_reg + i] = extracted_args[i];
        }

        if (extracted_args != null) libc::free(extracted_args);
        builtins::dispatch_builtin(fn_idx, &inner_ctx);
        return;
    }

    if (target.tag == OBJECT) {
        ctx.regs[ctx.base_reg - 2] = target;
        ctx.regs[ctx.base_reg - 1] = new_this;
        for (uint i = 0; i < actual_count; i++) {
            ctx.regs[ctx.base_reg + i] = extracted_args[i];
        }
        if (extracted_args != null) libc::free(extracted_args);
        ctx.needs_re_dispatch = true;
        ctx.re_nargs = (ushort)actual_count;
    } else {
        if (extracted_args != null) libc::free(extracted_args);
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
    }
}

/// Helper for extracting bound function data from internal properties.
fn void bound_get_data(HObject* bound_obj, TVal* target, TVal* bound_this,
                       TVal* bound_args, uint* bound_argc) {
    HString* target_key = null;
    HString* this_key = null;
    {
        char[50] buf1 = "\\x00bound_target";
        // Use a simple approach — keyed by pointer stored as internal property
    }
    // For simplicity, we store bound data in special internal properties.
    // These are non-enumerable, non-writable, non-configurable properties.
    HString* key_target = null;
    // We'll use the property table directly via known interned strings
}

/// Function.prototype.bind(thisArg, ...args)
///
/// Creates a new function that, when called, has its `this` bound to `thisArg`
/// and prepends any additional arguments.
///
/// ES5 §15.3.4.5
fn void builtin_function_proto_bind(BuiltinContext* ctx) {
    TVal target = ctx.this_val;

    // Validate target is callable
    bool callable = false;
    if (target.tag == LIGHTFUNC) {
        callable = true;
    } else if (target.tag == OBJECT) {
        HObject* hobj = (HObject*)target.pointer;
        if (hobj != null) {
            callable = hobj.is_callable();
        }
    }

    if (!callable) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }

    // Get bound this
    TVal bound_this;
    if (ctx.argc > 0) {
        bound_this = builtin_arg(ctx, 0);
    } else {
        bound_this.tag = UNDEFINED;
        bound_this.pointer = null;
    }

    // Collect bound args
    ushort bound_argc = (ctx.argc > 0) ? (ushort)(ctx.argc - 1) : 0;
    TVal* bound_args_arr = null;

    if (bound_argc > 0) {
        bound_args_arr = (TVal*)libc::malloc(TVal::size * bound_argc);
        if (bound_args_arr == null) {
            ctx.result.tag = UNDEFINED;
            ctx.result.pointer = null;
            return;
        }
        for (ushort i = 0; i < bound_argc; i++) {
            bound_args_arr[i] = builtin_arg(ctx, i + 1);
        }
    }

    // Create bound function object
    HObject*? bound_raw = hobject::hobject_alloc(ctx.heap, hobject::ObjClass.FUNCTION);
    if (catch err = bound_raw) {
        if (bound_args_arr != null) libc::free(bound_args_arr);
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }
    HObject* bound_obj = bound_raw;

    // Set up bound function properties
    bound_obj.flags.callable = true;
    bound_obj.flags.is_bound = true;
    bound_obj.prototype = ctx.heap.function_proto;
    bound_obj.builtin_fn_index = (int)BUILTIN_BOUND_CALL;

    // Also maintain constructable flag if target is constructable
    bool target_constructable = false;
    if (target.tag == OBJECT) {
        HObject* tobj = (HObject*)target.pointer;
        if (tobj != null) target_constructable = tobj.flags.constructable;
    }
    bound_obj.flags.constructable = target_constructable;

    // Store bound data as internal properties (non-enumerable, non-writable, non-configurable)
    // Key: use special strings "\x00bound_target", "\x00bound_this", "\x00bound_args"
    HString* key_target = builtin_intern_string(ctx.heap, { '\x00', 'b', 'o', 'u', 'n', 'd', '_', 't', 'a', 'r', 'g', 'e', 't' });
    HString* key_this   = builtin_intern_string(ctx.heap, { '\x00', 'b', 'o', 'u', 'n', 'd', '_', 't', 'h', 'i', 's' });
    HString* key_args   = builtin_intern_string(ctx.heap, { '\x00', 'b', 'o', 'u', 'n', 'd', '_', 'a', 'r', 'g', 's' });

    PropFlags internal_flags;
    internal_flags.writable = false;
    internal_flags.enumerable = false;
    internal_flags.configurable = false;
    internal_flags.is_accessor = false;

    bound_obj.put_prop(key_target, target, internal_flags);
    bound_obj.put_prop(key_this, bound_this, internal_flags);

    // Store bound args as a JS array
    HObject*? args_arr_raw = hobject::hobject_alloc(ctx.heap, hobject::ObjClass.ARRAY);
    HObject* args_arr = null;
    if (try a = args_arr_raw) {
        args_arr = a;
        args_arr.prototype = ctx.heap.array_proto;
        // Set length
        HString* len_key = builtin_intern_string(ctx.heap, "length");
        TVal len_tv;
        len_tv.tag = FASTINT;
        len_tv.fastint = bound_argc;
        args_arr.put_prop(len_key, len_tv, hobject::PROP_FLAGS_WEC);
        // Set elements
        for (ushort i = 0; i < bound_argc; i++) {
            char[20] buf;
            int n = libc::snprintf(&buf, 20, "%d", i);
            if (n > 0 && n < 20) {
                HString* elem_key = builtin_intern_string(ctx.heap, buf[:n]);
                args_arr.put_prop(elem_key, bound_args_arr[i], hobject::PROP_FLAGS_WEC);
            }
        }
    }

    if (bound_args_arr != null) libc::free(bound_args_arr);

    TVal args_tv;
    if (args_arr != null) {
        args_tv.tag = OBJECT;
        args_tv.pointer = args_arr;
    } else {
        args_tv.tag = UNDEFINED;
        args_tv.pointer = null;
    }
    bound_obj.put_prop(key_args, args_tv, internal_flags);

    // Set .length on the bound function
    // Length = max(0, target.length - bound_argc)
    int target_len = 0;
    if (target.tag == OBJECT) {
        HObject* tobj = (HObject*)target.pointer;
        if (tobj != null && tobj.comp_func != null) {
            target_len = (int)tobj.comp_func.num_formals;
        }
    }

    int bound_len = target_len - (int)bound_argc;
    if (bound_len < 0) bound_len = 0;

    HString* len_key = builtin_intern_string(ctx.heap, "length");
    TVal len_tv;
    len_tv.tag = FASTINT;
    len_tv.fastint = (long)bound_len;
    PropFlags wec = hobject::PROP_FLAGS_WEC;
    bound_obj.put_prop(len_key, len_tv, wec);

    // Result
    ctx.result.tag = OBJECT;
    ctx.result.pointer = bound_obj;
}

/// Bound function [[Call]] handler.
/// When a bound function is called, this handler unwraps the bound data,
/// prepends bound args to the call args, and re-dispatches.
fn void builtin_bound_call(BuiltinContext* ctx) {
    TVal func_val = ctx.regs[ctx.base_reg - 2];
    if (func_val.tag != OBJECT) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }
    HObject* bound_obj = (HObject*)func_val.pointer;
    if (bound_obj == null || !bound_obj.flags.is_bound) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }

    // Extract bound data from internal properties
    HString* key_target = builtin_intern_string(ctx.heap, { '\x00', 'b', 'o', 'u', 'n', 'd', '_', 't', 'a', 'r', 'g', 'e', 't' });
    HString* key_this   = builtin_intern_string(ctx.heap, { '\x00', 'b', 'o', 'u', 'n', 'd', '_', 't', 'h', 'i', 's' });
    HString* key_args   = builtin_intern_string(ctx.heap, { '\x00', 'b', 'o', 'u', 'n', 'd', '_', 'a', 'r', 'g', 's' });

    TVal? target_val = bound_obj.get_prop_proto(key_target);
    TVal? this_val   = bound_obj.get_prop_proto(key_this);
    TVal? args_val   = bound_obj.get_prop_proto(key_args);

    TVal target;
    TVal bound_this;
    if (try tv = target_val) { target = tv; }
    else { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }
    if (try tv = this_val) { bound_this = tv; }
    else { bound_this.tag = UNDEFINED; bound_this.pointer = null; }

    // Extract bound args array
    uint bound_argc = 0;
    if (try av = args_val) {
        if (av.tag == OBJECT) {
            HObject* arr = (HObject*)av.pointer;
            if (arr != null && arr.get_class() == hobject::ObjClass.ARRAY) {
                HString* len_key = builtin_intern_string(ctx.heap, "length");
                TVal? lv = arr.get_prop_proto(len_key);
                if (try l = lv) {
                    if (l.tag == FASTINT) {
                        bound_argc = (uint)l.fastint;
                    } else if (l.tag == NUMBER) {
                        bound_argc = (uint)l.number;
                    }
                }
            }
        }
    }

    TVal* all_args = null;
    uint max_total = bound_argc + ctx.argc;
    if (max_total > 0) {
        all_args = (TVal*)libc::malloc(TVal::size * max_total);
        if (all_args == null) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }
    }
    uint actual_total = 0;

    // Copy bound args from stored array
    if (try av = args_val) {
        if (av.tag == OBJECT) {
            HObject* arr = (HObject*)av.pointer;
            if (arr != null && arr.get_class() == hobject::ObjClass.ARRAY) {
                for (uint i = 0; i < bound_argc && actual_total < max_total; i++) {
                    char[20] buf;
                    int n = libc::snprintf(&buf, 20, "%d", i);
                    if (n > 0 && n < 20) {
                        HString* ek = builtin_intern_string(ctx.heap, buf[:n]);
                        TVal? e = arr.get_prop_proto(ek);
                        if (try ev = e) all_args[actual_total++] = ev;
                    }
                }
            }
        }
    }

    // Append call args
    uint total_argc = bound_argc + ctx.argc;
    for (uint i = 0; i < (uint)ctx.argc && bound_argc + i < 65535; i++) {
        all_args[bound_argc + i] = ctx.regs[ctx.base_reg + i];
    }

    // Determine if target is LIGHTFUNC or OBJECT
    if (target.tag == LIGHTFUNC) {
        uint fn_idx = (uint)target.fastint;
        builtins::BuiltinContext inner_ctx;
        inner_ctx.vm = ctx.vm;
        inner_ctx.regs = ctx.regs;
        inner_ctx.base_reg = ctx.base_reg;
        inner_ctx.argc = (ushort)total_argc;
        inner_ctx.result = ctx.result;
        inner_ctx.heap = ctx.heap;
        inner_ctx.this_val = bound_this;
        inner_ctx.is_constructor = ctx.is_constructor;
        inner_ctx.needs_re_dispatch = false;
        inner_ctx.re_nargs = 0;

        for (uint i = 0; i < total_argc && i < 65535; i++) {
            ctx.regs[ctx.base_reg + i] = all_args[i];
        }
        builtins::dispatch_builtin(fn_idx, &inner_ctx);
        return;
    }

    if (target.tag == OBJECT) {
        HObject* tobj = (HObject*)target.pointer;
        if (tobj != null && tobj.is_callable()) {
            ctx.regs[ctx.base_reg - 2] = target;
            ctx.regs[ctx.base_reg - 1] = bound_this;
            for (uint i = 0; i < total_argc && i < 65535; i++) {
                ctx.regs[ctx.base_reg + i] = all_args[i];
            }
            ctx.needs_re_dispatch = true;
            ctx.re_nargs = (ushort)total_argc;
            return;
        }
    }

    ctx.result.tag = UNDEFINED;
    ctx.result.pointer = null;
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
        case BUILTIN_NUMBER_PROTO_TOFIXED:
            builtin_number_proto_toFixed(ctx);
        case BUILTIN_NUMBER_PROTO_TOEXPONENTIAL:
            builtin_number_proto_toExponential(ctx);
        case BUILTIN_NUMBER_PROTO_TOPRECISION:
            builtin_number_proto_toPrecision(ctx);
        case BUILTIN_OBJECT:
            builtin_object(ctx);
        case BUILTIN_OBJECT_PROTO_TOSTRING:
            builtin_object_proto_toString(ctx);
        case BUILTIN_OBJECT_PROTO_VALUEOF:
            builtin_object_proto_valueOf(ctx);
        case BUILTIN_ARRAY:
            builtin_array(ctx);
        case BUILTIN_MATH_ABS:
            builtin_math_abs(ctx);
        case BUILTIN_MATH_FLOOR:
            builtin_math_floor(ctx);
        case BUILTIN_MATH_CEIL:
            builtin_math_ceil(ctx);
        case BUILTIN_MATH_ROUND:
            builtin_math_round(ctx);
        case BUILTIN_MATH_MAX:
            builtin_math_max(ctx);
        case BUILTIN_MATH_MIN:
            builtin_math_min(ctx);
        case BUILTIN_MATH_POW:
            builtin_math_pow(ctx);
        case BUILTIN_MATH_SQRT:
            builtin_math_sqrt(ctx);
        case BUILTIN_MATH_EXP:
            builtin_math_exp(ctx);
        case BUILTIN_MATH_LOG:
            builtin_math_log(ctx);
        case BUILTIN_MATH_SIN:
            builtin_math_sin(ctx);
        case BUILTIN_MATH_COS:
            builtin_math_cos(ctx);
        case BUILTIN_MATH_TAN:
            builtin_math_tan(ctx);
        case BUILTIN_MATH_RANDOM:
            builtin_math_random(ctx);
        case BUILTIN_STRING_PROTO_CHARAT:
            builtin_string_proto_charAt(ctx);
        case BUILTIN_STRING_PROTO_CHARCODEAT:
            builtin_string_proto_charCodeAt(ctx);
        case BUILTIN_STRING_PROTO_INDEXOF:
            builtin_string_proto_indexOf(ctx);
        case BUILTIN_STRING_PROTO_SLICE:
            builtin_string_proto_slice(ctx);
        case BUILTIN_STRING_PROTO_SUBSTRING:
            builtin_string_proto_substring(ctx);
        case BUILTIN_STRING_PROTO_SUBSTR:
            builtin_string_proto_substr(ctx);
        case BUILTIN_STRING_PROTO_TOUPPERCASE:
            builtin_string_proto_toUpperCase(ctx);
        case BUILTIN_STRING_PROTO_TOLOWERCASE:
            builtin_string_proto_toLowerCase(ctx);
        case BUILTIN_STRING_PROTO_TRIM:
            builtin_string_proto_trim(ctx);
        case BUILTIN_STRING_PROTO_SPLIT:
            builtin_string_proto_split(ctx);
        case BUILTIN_STRING_PROTO_CONCAT:
            builtin_string_proto_concat(ctx);
        case BUILTIN_STRING_PROTO_REPLACE:
            builtin_string_proto_replace(ctx);
        case BUILTIN_ARRAY_PROTO_TOSTRING:
            builtin_array_proto_toString(ctx);
        case BUILTIN_ARRAY_PROTO_JOIN:
            builtin_array_proto_join(ctx);
        case BUILTIN_ARRAY_PROTO_POP:
            builtin_array_proto_pop(ctx);
        case BUILTIN_ARRAY_PROTO_PUSH:
            builtin_array_proto_push(ctx);
        case BUILTIN_ARRAY_PROTO_REVERSE:
            builtin_array_proto_reverse(ctx);
        case BUILTIN_ARRAY_PROTO_SHIFT:
            builtin_array_proto_shift(ctx);
        case BUILTIN_ARRAY_PROTO_SLICE:
            builtin_array_proto_slice(ctx);
        case BUILTIN_ARRAY_PROTO_SORT:
            builtin_array_proto_sort(ctx);
        case BUILTIN_ARRAY_PROTO_SPLICE:
            builtin_array_proto_splice(ctx);
        case BUILTIN_ARRAY_PROTO_UNSHIFT:
            builtin_array_proto_unshift(ctx);
        case BUILTIN_ARRAY_PROTO_INDEXOF:
            builtin_array_proto_indexOf(ctx);
        case BUILTIN_ARRAY_PROTO_LASTINDEXOF:
            builtin_array_proto_lastIndexOf(ctx);
        case BUILTIN_ARRAY_PROTO_CONCAT:
            builtin_array_proto_concat(ctx);
        case BUILTIN_FUNCTION_PROTO_CALL:
            builtin_function_proto_call(ctx);
        case BUILTIN_FUNCTION_PROTO_APPLY:
            builtin_function_proto_apply(ctx);
        case BUILTIN_FUNCTION_PROTO_BIND:
            builtin_function_proto_bind(ctx);
        case BUILTIN_BOUND_CALL:
            builtin_bound_call(ctx);
        case BUILTIN_EVAL:
            builtin_eval(ctx);
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

    // Register eval (ES5 §15.1.2.1)
    if (!register_simple_builtin(global_env, heap, "eval", BUILTIN_EVAL)) return false;

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

    // Register Function.prototype (call, apply, bind)
    if (!register_function_prototype(global_env, heap)) return false;

    // Wire all prototype chains to Object.prototype
    if (heap.number_proto != null) heap.number_proto.prototype = heap.object_proto;
    if (heap.bool_proto != null)   heap.bool_proto.prototype = heap.object_proto;
    if (heap.string_proto != null) heap.string_proto.prototype = heap.object_proto;
    if (heap.err_proto != null)    heap.err_proto.prototype = heap.object_proto;
    if (heap.array_proto != null)  heap.array_proto.prototype = heap.object_proto;
    if (heap.function_proto != null) heap.function_proto.prototype = heap.object_proto;

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

    // Math methods (registered as lightfuncs on the Math object)
    if (!register_math_method(math, heap, "abs",    BUILTIN_MATH_ABS))    return false;
    if (!register_math_method(math, heap, "floor",  BUILTIN_MATH_FLOOR))  return false;
    if (!register_math_method(math, heap, "ceil",   BUILTIN_MATH_CEIL))   return false;
    if (!register_math_method(math, heap, "round",  BUILTIN_MATH_ROUND))  return false;
    if (!register_math_method(math, heap, "max",    BUILTIN_MATH_MAX))    return false;
    if (!register_math_method(math, heap, "min",    BUILTIN_MATH_MIN))    return false;
    if (!register_math_method(math, heap, "pow",    BUILTIN_MATH_POW))    return false;
    if (!register_math_method(math, heap, "sqrt",   BUILTIN_MATH_SQRT))   return false;
    if (!register_math_method(math, heap, "exp",    BUILTIN_MATH_EXP))    return false;
    if (!register_math_method(math, heap, "log",    BUILTIN_MATH_LOG))    return false;
    if (!register_math_method(math, heap, "sin",    BUILTIN_MATH_SIN))    return false;
    if (!register_math_method(math, heap, "cos",    BUILTIN_MATH_COS))    return false;
    if (!register_math_method(math, heap, "tan",    BUILTIN_MATH_TAN))    return false;
    if (!register_math_method(math, heap, "random", BUILTIN_MATH_RANDOM)) return false;

    TVal math_tv;
    math_tv.tag = OBJECT;
    math_tv.fastint = 0;
    math_tv.pointer = math;
    return register_named_value(global_env, heap, "Math", math_tv);
}

/// Helper: register a Math method as a lightfunc property on the Math object.
fn bool register_math_method(HObject* math, Heap* heap, char[] name, uint fn_index) {
    uint hash = heap.hash_string(name);
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
    tv.tag = LIGHTFUNC;
    tv.fastint = (long)fn_index;
    math.put_prop(key, tv, hobject::PROP_FLAGS_WEC);
    return true;
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

    // Add .toFixed() method (Phase 6d)
    if (!register_string_proto_method(proto, heap, "toFixed", BUILTIN_NUMBER_PROTO_TOFIXED)) return false;
    // Add .toExponential() method
    if (!register_string_proto_method(proto, heap, "toExponential", BUILTIN_NUMBER_PROTO_TOEXPONENTIAL)) return false;
    // Add .toPrecision() method
    if (!register_string_proto_method(proto, heap, "toPrecision", BUILTIN_NUMBER_PROTO_TOPRECISION)) return false;

    // Create Number constructor as a proper function object (not LIGHTFUNC)
    // so it can carry static properties like Number.MAX_VALUE, Number.NaN, etc.
    HObject*? num_raw = hobject::hobject_alloc(heap, hobject::ObjClass.FUNCTION);
    if (catch err = num_raw) return false;
    HObject* num = num_raw;
    num.builtin_fn_index = (int)BUILTIN_NUMBER;

    // Set Number.prototype on the constructor (non-writable, non-enumerable, non-configurable)
    HString* prototype_key = builtin_intern_string(heap, "prototype");
    TVal proto_tv;
    proto_tv.tag = OBJECT;
    proto_tv.pointer = proto;
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    num.put_prop(prototype_key, proto_tv, proto_pflags);

    // Add Number.MAX_VALUE (ES5 §15.7.3.2) — non-writable, non-enumerable, non-configurable
    if (!set_num_static_prop(num, heap, "MAX_VALUE", 1.7976931348623157e+308)) return false;
    // Add Number.MIN_VALUE (ES5 §15.7.3.3)
    if (!set_num_static_prop(num, heap, "MIN_VALUE", 5e-324)) return false;
    // Add Number.NaN (ES5 §15.7.3.4)
    if (!set_num_static_prop(num, heap, "NaN", double::nan)) return false;
    // Add Number.NEGATIVE_INFINITY (ES5 §15.7.3.5)
    if (!set_num_static_prop(num, heap, "NEGATIVE_INFINITY", -double::inf)) return false;
    // Add Number.POSITIVE_INFINITY (ES5 §15.7.3.6)
    if (!set_num_static_prop(num, heap, "POSITIVE_INFINITY", double::inf)) return false;

    // Register Number constructor globally as an OBJECT (not LIGHTFUNC)
    uint hash = heap.hash_string("Number");
    HString* existing = heap.str_table_lookup("Number", hash);
    HString* num_key;
    if (existing != null) {
        num_key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, "Number", hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        num_key = new_key;
    }
    TVal num_val;
    num_val.tag = OBJECT;
    num_val.pointer = num;
    env::env_declare(global_env, num_key, num_val);

    return true;
}

/// Helper: set a non-writable, non-enumerable, non-configurable number property.
fn bool set_num_static_prop(HObject* obj, Heap* heap, char[] name, double val) {
    uint hash = heap.hash_string(name);
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
    PropFlags pflags;
    pflags.writable = false;
    pflags.enumerable = false;
    pflags.configurable = false;
    pflags.is_accessor = false;
    obj.put_prop(key, tv, pflags);
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

    // Add String.prototype methods (Phase 6b)
    if (!register_string_proto_method(proto, heap, "charAt",     BUILTIN_STRING_PROTO_CHARAT))     return false;
    if (!register_string_proto_method(proto, heap, "charCodeAt", BUILTIN_STRING_PROTO_CHARCODEAT)) return false;
    if (!register_string_proto_method(proto, heap, "indexOf",    BUILTIN_STRING_PROTO_INDEXOF))    return false;
    if (!register_string_proto_method(proto, heap, "slice",      BUILTIN_STRING_PROTO_SLICE))      return false;
    if (!register_string_proto_method(proto, heap, "substring",  BUILTIN_STRING_PROTO_SUBSTRING))  return false;
    if (!register_string_proto_method(proto, heap, "substr",     BUILTIN_STRING_PROTO_SUBSTR))     return false;
    if (!register_string_proto_method(proto, heap, "toLowerCase",BUILTIN_STRING_PROTO_TOLOWERCASE)) return false;
    if (!register_string_proto_method(proto, heap, "toUpperCase",BUILTIN_STRING_PROTO_TOUPPERCASE)) return false;
    if (!register_string_proto_method(proto, heap, "trim",       BUILTIN_STRING_PROTO_TRIM))       return false;
    if (!register_string_proto_method(proto, heap, "split",      BUILTIN_STRING_PROTO_SPLIT))      return false;
    if (!register_string_proto_method(proto, heap, "concat",     BUILTIN_STRING_PROTO_CONCAT))     return false;
    if (!register_string_proto_method(proto, heap, "replace",    BUILTIN_STRING_PROTO_REPLACE))    return false;

    // Register String as a global constructor
    if (!register_simple_builtin(global_env, heap, "String", BUILTIN_STRING)) return false;

    return true;
}

/// Helper: register a String.prototype method as a lightfunc property.
fn bool register_string_proto_method(HObject* proto, Heap* heap, char[] name, uint fn_index) {
    uint hash = heap.hash_string(name);
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
    tv.tag = LIGHTFUNC;
    tv.fastint = (long)fn_index;
    proto.put_prop(key, tv, hobject::PROP_FLAGS_WEC);
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

    // Register Array as a global constructor
    if (!register_simple_builtin(global_env, heap, "Array", BUILTIN_ARRAY)) return false;

    return true;
}

// ============================================================================
// Function.prototype registration (call, apply, bind)
// ============================================================================

/// Create Function.prototype and register call/apply/bind methods.
fn bool register_function_prototype(EnvRecord* global_env, Heap* heap) {
    // Create Function.prototype
    HObject*? proto_raw = hobject::hobject_alloc(heap, hobject::ObjClass.FUNCTION);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;  // Will be Object.prototype
    heap.function_proto = proto;

    // Add .call method
    HString* call_key = builtin_intern_string(heap, "call");
    TVal call_tv;
    call_tv.tag = LIGHTFUNC;
    call_tv.fastint = (long)BUILTIN_FUNCTION_PROTO_CALL;
    proto.put_prop(call_key, call_tv, hobject::PROP_FLAGS_WEC);

    // Add .apply method
    HString* apply_key = builtin_intern_string(heap, "apply");
    TVal apply_tv;
    apply_tv.tag = LIGHTFUNC;
    apply_tv.fastint = (long)BUILTIN_FUNCTION_PROTO_APPLY;
    proto.put_prop(apply_key, apply_tv, hobject::PROP_FLAGS_WEC);

    // Add .bind method
    HString* bind_key = builtin_intern_string(heap, "bind");
    TVal bind_tv;
    bind_tv.tag = LIGHTFUNC;
    bind_tv.fastint = (long)BUILTIN_FUNCTION_PROTO_BIND;
    proto.put_prop(bind_key, bind_tv, hobject::PROP_FLAGS_WEC);

    // Add .constructor
    HString* constructor_key = builtin_intern_string(heap, "constructor");
    TVal constructor_tv;
    constructor_tv.tag = UNDEFINED;
    constructor_tv.pointer = null;
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WEC);

    return true;
}


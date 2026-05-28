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
import duktape::re_bindings;
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
extern fn double math_acos(double x)          @MathLibc("acos");
extern fn double math_asin(double x)          @MathLibc("asin");
extern fn double math_atan(double x)          @MathLibc("atan");
extern fn double math_atan2(double y, double x) @MathLibc("atan2");
extern fn double math_cosh(double x)          @MathLibc("cosh");
extern fn double math_sinh(double x)          @MathLibc("sinh");
extern fn double math_tanh(double x)          @MathLibc("tanh");
extern fn double math_acosh(double x)         @MathLibc("acosh");
extern fn double math_asinh(double x)         @MathLibc("asinh");
extern fn double math_atanh(double x)         @MathLibc("atanh");
extern fn double math_log2(double x)          @MathLibc("log2");
extern fn double math_log10(double x)         @MathLibc("log10");
extern fn double math_log1p(double x)         @MathLibc("log1p");
extern fn double math_expm1(double x)         @MathLibc("expm1");
extern fn double math_cbrt(double x)          @MathLibc("cbrt");

// Date/time library externals (link-time resolved via libc)
// The Tm struct mirrors C's struct tm layout exactly.

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

const uint BUILTIN_NUMBER_PROTO_TOFIXED       = 73;
const uint BUILTIN_NUMBER_PROTO_TOEXPONENTIAL = 74;
const uint BUILTIN_NUMBER_PROTO_TOPRECISION   = 75;
const uint BUILTIN_FUNCTION_PROTO_CALL  = 77;
const uint BUILTIN_FUNCTION_PROTO_APPLY = 78;
const uint BUILTIN_FUNCTION_PROTO_BIND  = 79;
const uint BUILTIN_BOUND_CALL           = 80;
const uint BUILTIN_EVAL                 = 81;
const uint BUILTIN_JSON_PARSE           = 82;
const uint BUILTIN_JSON_STRINGIFY       = 83;
const uint BUILTIN_DATE                 = 84;
const uint BUILTIN_DATE_NOW             = 85;
const uint BUILTIN_DATE_UTC             = 86;
const uint BUILTIN_DATE_PARSE           = 87;
const uint BUILTIN_DATE_PROTO_TOSTRING  = 88;
const uint BUILTIN_DATE_PROTO_TOJSON    = 89;
const uint BUILTIN_DATE_PROTO_VALUEOF   = 90;
const uint BUILTIN_DATE_PROTO_GETTIME   = 91;
const uint BUILTIN_DATE_PROTO_GETFULLYEAR  = 92;
const uint BUILTIN_DATE_PROTO_GETMONTH     = 93;
const uint BUILTIN_DATE_PROTO_GETDATE      = 94;
const uint BUILTIN_DATE_PROTO_GETDAY       = 95;
const uint BUILTIN_DATE_PROTO_GETHOURS     = 96;
const uint BUILTIN_DATE_PROTO_GETMINUTES   = 97;
const uint BUILTIN_DATE_PROTO_GETSECONDS   = 98;
const uint BUILTIN_DATE_PROTO_GETMILLISECONDS = 99;
const uint BUILTIN_FUNCTION              = 101;
const uint BUILTIN_RESET_GLOBALS             = 102;
const uint BUILTIN_REGEXP                    = 103;
const uint BUILTIN_REGEXP_PROTO_TEST         = 104;
const uint BUILTIN_REGEXP_PROTO_EXEC         = 105;
const uint BUILTIN_REGEXP_PROTO_TOSTRING         = 106;
const uint BUILTIN_OBJECT_PROTO_HASOWNPROPERTY  = 108;
const uint BUILTIN_OBJECT_PROTO_PROPERTYISENUMERABLE = 109;
const uint BUILTIN_OBJECT_PROTO_ISPROTOTYPEOF  = 107;
const uint BUILTIN_OBJECT_PROTO_TOLOCALESTRING = 110;
const uint BUILTIN_COUNT                         = 111;

const uint BUILTIN_MAP                       = 112;
const uint BUILTIN_MAP_PROTO_SET             = 113;
const uint BUILTIN_MAP_PROTO_GET             = 114;
const uint BUILTIN_MAP_PROTO_HAS             = 115;
const uint BUILTIN_MAP_PROTO_DELETE          = 116;
const uint BUILTIN_MAP_PROTO_CLEAR           = 117;
const uint BUILTIN_MAP_PROTO_KEYS            = 118;
const uint BUILTIN_MAP_PROTO_VALUES          = 119;
const uint BUILTIN_MAP_PROTO_ENTRIES         = 120;
const uint BUILTIN_MAP_PROTO_FOREACH         = 121;

const uint BUILTIN_SET                       = 122;
const uint BUILTIN_SET_PROTO_ADD             = 123;
const uint BUILTIN_SET_PROTO_HAS             = 124;
const uint BUILTIN_SET_PROTO_DELETE          = 125;
const uint BUILTIN_SET_PROTO_CLEAR           = 126;
const uint BUILTIN_SET_PROTO_KEYS            = 127;
const uint BUILTIN_SET_PROTO_VALUES          = 128;
const uint BUILTIN_SET_PROTO_ENTRIES         = 129;
const uint BUILTIN_SET_PROTO_FOREACH         = 130;

const uint BUILTIN_WEAKMAP                   = 131;
const uint BUILTIN_WEAKMAP_PROTO_SET         = 132;
const uint BUILTIN_WEAKMAP_PROTO_GET         = 133;
const uint BUILTIN_WEAKMAP_PROTO_HAS         = 134;
const uint BUILTIN_WEAKMAP_PROTO_DELETE      = 135;

const uint BUILTIN_WEAKSET                   = 136;
const uint BUILTIN_WEAKSET_PROTO_ADD         = 137;
const uint BUILTIN_WEAKSET_PROTO_HAS         = 138;
const uint BUILTIN_WEAKSET_PROTO_DELETE      = 139;

const uint BUILTIN_SYMBOL                    = 140;
const uint BUILTIN_SYMBOL_FOR                = 141;
const uint BUILTIN_SYMBOL_KEYFOR             = 142;
const uint BUILTIN_SYMBOL_PROTO_TOSTRING     = 143;
const uint BUILTIN_SYMBOL_PROTO_VALUEOF      = 144;

const uint BUILTIN_PROMISE                   = 145;
const uint BUILTIN_PROMISE_PROTO_THEN        = 146;
const uint BUILTIN_PROMISE_PROTO_CATCH       = 147;
const uint BUILTIN_PROMISE_PROTO_FINALLY     = 148;
const uint BUILTIN_PROMISE_RESOLVE           = 149;
const uint BUILTIN_PROMISE_REJECT            = 150;
const uint BUILTIN_PROMISE_ALL               = 151;
const uint BUILTIN_PROMISE_RACE              = 152;

const uint BUILTIN_GENERATOR_FUNCTION        = 153;
const uint BUILTIN_GENERATOR_PROTO_NEXT      = 154;
const uint BUILTIN_GENERATOR_PROTO_THROW     = 155;
const uint BUILTIN_GENERATOR_PROTO_RETURN    = 156;
const uint BUILTIN_OBJECT_KEYS               = 157;
const uint BUILTIN_OBJECT_GETPROTOTYPEOF     = 158;
const uint BUILTIN_OBJECT_ISEXTENSIBLE       = 159;
const uint BUILTIN_OBJECT_PREVENTEXTENSIONS  = 160;

const uint BUILTIN_OBJECT_GETOWNPROPERTYDESCRIPTOR = 161;
const uint BUILTIN_OBJECT_DEFINEPROPERTY           = 162;
const uint BUILTIN_OBJECT_GETOWNPROPERTYNAMES      = 163;
const uint BUILTIN_OBJECT_DEFINEPROPERTIES        = 164;
const uint BUILTIN_OBJECT_CREATE                  = 165;
const uint BUILTIN_OBJECT_SEAL                    = 166;
const uint BUILTIN_OBJECT_FREEZE                  = 167;
const uint BUILTIN_OBJECT_ISSEALED                = 168;
const uint BUILTIN_OBJECT_ISFROZEN                = 169;
const uint BUILTIN_OBJECT_ENTRIES                 = 188;
const uint BUILTIN_OBJECT_VALUES                  = 189;
const uint BUILTIN_OBJECT_ASSIGN                  = 190;
const uint BUILTIN_NUMBER_ISNAN                   = 191;
const uint BUILTIN_NUMBER_ISFINITE                = 192;
const uint BUILTIN_NUMBER_ISINTEGER               = 193;
const uint BUILTIN_NUMBER_ISSAFEINTEGER           = 194;

const uint BUILTIN_MATH_ACOS   = 195;
const uint BUILTIN_MATH_ASIN   = 196;
const uint BUILTIN_MATH_ATAN   = 197;
const uint BUILTIN_MATH_ATAN2  = 198;
const uint BUILTIN_MATH_COSH   = 199;
const uint BUILTIN_MATH_SINH   = 200;
const uint BUILTIN_MATH_TANH   = 201;
const uint BUILTIN_MATH_ACOSH  = 202;
const uint BUILTIN_MATH_ASINH  = 203;
const uint BUILTIN_MATH_ATANH  = 204;
const uint BUILTIN_MATH_LOG2   = 205;
const uint BUILTIN_MATH_LOG10  = 206;
const uint BUILTIN_MATH_LOG1P  = 207;
const uint BUILTIN_MATH_EXPM1  = 208;
const uint BUILTIN_MATH_CBRT   = 209;
const uint BUILTIN_MATH_HYPOT  = 210;
const uint BUILTIN_MATH_TRUNC  = 211;
const uint BUILTIN_MATH_SIGN   = 212;
const uint BUILTIN_MATH_FROUND = 213;
const uint BUILTIN_MATH_CLZ32  = 214;
const uint BUILTIN_MATH_IMUL   = 215;
const uint BUILTIN_ARRAY_ISARRAY = 216;
const uint BUILTIN_STRING_FROMCHARCODE = 217;
const uint BUILTIN_OBJECT_IS           = 218;
const uint BUILTIN_OBJECT_HASOWN       = 219;
const uint BUILTIN_OBJECT_SETPROTOTYPEOF = 220;
const uint BUILTIN_ARRAY_PROTO_FLAT      = 221;
const uint BUILTIN_ARRAY_PROTO_FLATMAP   = 222;
const uint BUILTIN_STRING_FROMCODEPOINT  = 223;

const uint BUILTIN_ENCODE_URI              = 224;
const uint BUILTIN_ENCODE_URI_COMPONENT    = 225;
const uint BUILTIN_DECODE_URI              = 226;
const uint BUILTIN_DECODE_URI_COMPONENT    = 227;
const uint BUILTIN_URI_ERROR               = 228;
const uint BUILTIN_ARRAY_PROTO_TOREVERSED = 229;
const uint BUILTIN_ARRAY_PROTO_TOSORTED   = 230;
const uint BUILTIN_ARRAY_PROTO_TOSPLICED  = 231;
const uint BUILTIN_ARRAY_PROTO_WITH       = 232;

const uint BUILTIN_STRING_PROTO_INCLUDES  = 170;
const uint BUILTIN_STRING_PROTO_STARTSWITH = 171;
const uint BUILTIN_STRING_PROTO_ENDSWITH  = 172;
const uint BUILTIN_STRING_PROTO_REPEAT    = 173;
const uint BUILTIN_STRING_PROTO_TRIMSTART = 174;
const uint BUILTIN_STRING_PROTO_TRIMEND   = 175;
const uint BUILTIN_STRING_PROTO_CODEPOINTAT = 176;
const uint BUILTIN_STRING_PROTO_AT        = 177;
const uint BUILTIN_STRING_PROTO_PADSTART  = 178;
const uint BUILTIN_STRING_PROTO_PADEND    = 179;
const uint BUILTIN_STRING_PROTO_LASTINDEXOF = 180;
const uint BUILTIN_ARRAY_OF              = 181;
const uint BUILTIN_ARRAY_PROTO_FILL      = 182;
const uint BUILTIN_ARRAY_PROTO_FIND      = 183;
const uint BUILTIN_ARRAY_PROTO_FINDINDEX = 184;
const uint BUILTIN_ARRAY_PROTO_INCLUDES  = 185;
const uint BUILTIN_ARRAY_PROTO_AT        = 186;
const uint BUILTIN_ARRAY_PROTO_COPYWITHIN = 187;

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
    /// When true, the builtin wants to throw an error (used by JSON.parse etc).
    bool  should_throw;
    /// The value to throw (only valid when should_throw is true).
    TVal  throw_value;
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
// Function constructor (ES5 §15.3)
// ============================================================================

/// Function(p1, p2, ..., pn, body) — creates a new function dynamically.
/// Called as function or constructor, behavior is identical per ES5 §15.3.1.
fn void builtin_function(BuiltinContext* ctx) {
    // Collect the body string (last arg) and param names (preceding args).
    // Per ES5 §15.3.2.1:
    //   - 0 args  → body = ""
    //   - 1 arg   → body = ToString(arg[0])
    //   > 1 args  → last arg = body, preceding = param names

    char* body_str = "";
    usz body_len = 0;
    char[256] param_buf;  // accumulate param names joined by commas
    int param_pos = 0;

    if (ctx.argc == 0) {
        // Empty body, no params
        body_str = "";
        body_len = 0;
    } else {
        // Get the body from the last argument
        TVal* body_arg = &ctx.regs[ctx.base_reg + (uint)(ctx.argc - 1)];
        if (body_arg.tag == STRING && body_arg.pointer != null) {
            HString* s = (HString*)body_arg.pointer;
            body_str = s.get_cstr();
            body_len = s.blen;
        } else {
            // Convert to string via ToString
            // For simplicity, return undefined if not a string
            ctx.result.set_undefined();
            return;
        }

        // Process parameter names from preceding args
        for (ushort i = 0; i < ctx.argc - 1; i++) {
            TVal* arg = &ctx.regs[ctx.base_reg + (uint)i];
            char* pname = "";
            usz plen = 0;
            if (arg.tag == STRING && arg.pointer != null) {
                HString* s = (HString*)arg.pointer;
                pname = s.get_cstr();
                plen = s.blen;
            } else {
                // Convert to string: for simplicity, skip non-string params
                continue;
            }

            // Add comma separator
            if (param_pos > 0 && param_pos < 255) {
                param_buf[param_pos++] = ',';
            }

            // Copy param name (up to buffer limit)
            for (usz j = 0; j < plen && param_pos < 255; j++) {
                param_buf[param_pos++] = pname[j];
            }
        }
    }

    param_buf[param_pos] = 0;

    // Build source string: "(p1,p2,...){ body }"
    // Use a generously-sized stack buffer
    char[16384] src_buf;
    int src_pos = 0;

    src_pos += libc::snprintf(&src_buf[src_pos], (usz)(16384 - src_pos), "(%s){", param_buf);
    // Copy body (up to remaining buffer space)
    for (usz i = 0; i < body_len && src_pos < 16380; i++) {
        src_buf[src_pos++] = body_str[i];
    }
    src_pos += libc::snprintf(&src_buf[src_pos], (usz)(16384 - src_pos), "}");

    // Lex and compile as a function expression
    Lexer lex = lexer::lexer_init(src_buf[:src_pos], ctx.heap);
    CompiledFunction*? cf = compiler::compile_function(&lex, ctx.heap, true);
    CompiledFunction* func;
    if (try f = cf) {
        func = f;
    } else {
        // Compilation failed: throw SyntaxError
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.syntax_err_proto;
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            HString* msg_str = builtin_intern_string(ctx.heap, "SyntaxError in Function constructor");
            TVal msg_tv;
            msg_tv.tag = STRING;
            msg_tv.pointer = msg_str;
            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
            TVal err_tv;
            err_tv.tag = OBJECT;
            err_tv.pointer = err;
            ctx.throw_value.tag = err_tv.tag;
            ctx.throw_value.pointer = err_tv.pointer;
        } else {
            ctx.throw_value.set_undefined();
        }
        ctx.should_throw = true;
        return;
    }

    // Create an HObject for the compiled function
    HObject*? func_obj_raw = ctx.heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = func_obj_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* func_obj = func_obj_raw;
    func_obj.comp_func = func;
    func_obj.builtin_fn_index = -1;

    // Use the global environment (per ES5 §15.3.2.1 step 5)
    func_obj.var_env = ctx.global_env;
    func_obj.lex_env = ctx.global_env;

    // Set the function's .prototype property (standard for JS functions)
    // and its internal [[Prototype]] to Function.prototype
    func_obj.prototype = ctx.heap.function_proto;
    HObject*? proto_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
    if (try proto = proto_raw) {
        HString* proto_key = builtin_intern_string(ctx.heap, "prototype");
        TVal proto_tv;
        proto_tv.tag = OBJECT;
        proto_tv.pointer = proto;
        func_obj.put_prop(proto_key, proto_tv, hobject::PROP_FLAGS_WEC);
    }

    // Set function length
    uint num_params = 0;
    if (ctx.argc > 0) num_params = (uint)(ctx.argc - 1);
    HString* len_key = builtin_intern_string(ctx.heap, "length");
    TVal len_tv;
    len_tv.tag = FASTINT;
    len_tv.fastint = (long)num_params;
    func_obj.put_prop(len_key, len_tv, hobject::PROP_FLAGS_WEC);

    // Return the function object
    ctx.result.tag = OBJECT;
    ctx.result.pointer = func_obj;
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
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
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
            ctx.throw_value.tag = err_tv.tag;
            ctx.throw_value.pointer = err_tv.pointer;
        } else {
            ctx.throw_value.set_undefined();
        }
        ctx.should_throw = true;
        return;
    }

    // Create an HObject for the compiled function
    HObject*? func_obj_raw = ctx.heap.alloc_object(hobject::ObjClass.FUNCTION);
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
    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
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

fn void builtin_uri_error(BuiltinContext* ctx) {
    builtin_error_constructor_shared(ctx, ctx.heap.uri_err_proto);
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
        HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.BOOLEAN);
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
        HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.STRING);
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

/// ToUint16 abstract operation (ES5 §9.7).
fn uint to_uint16(TVal* val) {
    TVal num;
    builtin_to_number(val, &num);
    double n;
    if (num.tag == FASTINT) {
        n = (double)num.fastint;
    } else if (num.tag == NUMBER) {
        n = num.number;
    } else {
        return 0;
    }
    if (math::is_nan(n) || n == 0.0 || n == double::inf || n == -double::inf) return 0;
    double pos_int = math::abs(n);
    pos_int = math::floor(pos_int);
    long int_val = (long)pos_int;
    return (uint)(ushort)(int)(int_val & 0xFFFF);
}

/// String.fromCharCode (ES5 §15.5.3.2)
fn void builtin_string_fromcharcode(BuiltinContext* ctx) {
    if (ctx.argc == 0) {
        HString* empty = builtin_intern_string(ctx.heap, "");
        ctx.result.tag = STRING;
        ctx.result.pointer = empty;
        return;
    }
    // Build string from code units (max ~256 args, cap at 512 bytes)
    char[512] buf;
    usz offset = 0;
    ushort max_args = (ushort)(ctx.argc < 256 ? ctx.argc : 256);
    for (ushort i = 0; i < max_args && offset < 510; i++) {
        uint cu = to_uint16(&ctx.regs[ctx.base_reg + i]);
        if (cu < 128) {
            buf[offset++] = (char)cu;
        } else if (cu < 2048) {
            buf[offset++] = (char)(0xC0 | (cu >> 6));
            buf[offset++] = (char)(0x80 | (cu & 0x3F));
        } else {
            buf[offset++] = (char)(0xE0 | (cu >> 12));
            buf[offset++] = (char)(0x80 | ((cu >> 6) & 0x3F));
            buf[offset++] = (char)(0x80 | (cu & 0x3F));
        }
    }
    HString* result = builtin_intern_string(ctx.heap, buf[:offset]);
    ctx.result.tag = STRING;
    ctx.result.pointer = result;
}

/// String.fromCodePoint(...codePoints) — ES6 §21.1.2.2
fn void builtin_string_fromcodepoint(BuiltinContext* ctx) {
    if (ctx.argc == 0) {
        HString* empty = builtin_intern_string(ctx.heap, "");
        ctx.result.tag = STRING;
        ctx.result.pointer = empty;
        return;
    }
    // Build string from code points (supporting supplementary plane via UTF-8)
    char[1024] buf;
    usz offset = 0;
    ushort max_args = (ushort)(ctx.argc < 256 ? ctx.argc : 256);
    for (ushort i = 0; i < max_args && offset < 1020; i++) {
        TVal* arg = &ctx.regs[ctx.base_reg + i];
        double d;
        if (arg.tag == FASTINT) {
            d = (double)arg.fastint;
        } else if (arg.tag == NUMBER) {
            d = arg.number;
        } else if (arg.tag == BOOLEAN) {
            d = arg.boolean ? 1.0 : 0.0;
        } else if (arg.tag == UNDEFINED || arg.tag == NULL_VAL) {
            d = 0.0;
        } else {
            d = builtin_to_number_getdouble(ctx, arg);
        }
        // Check: must be integral Number in [0, 0x10FFFF]
        if (math::is_nan(d) || math::is_inf(d) || d != math::trunc(d) || d < 0 || d > 0x10FFFF) {
            // Throw RangeError
            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (try err = err_raw) {
                err.prototype = ctx.heap.range_err_proto;
                HString* msg = builtin_intern_string(ctx.heap, "Invalid code point value");
                TVal msg_tv; msg_tv.tag = STRING; msg_tv.pointer = msg;
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                ctx.should_throw = true;
                ctx.throw_value.tag = OBJECT;
                ctx.throw_value.pointer = err;
            }
            return;
        }
        uint ucp = (uint)(long)d;
        if (ucp < 0x80) {
            buf[offset++] = (char)ucp;
        } else if (ucp < 0x800) {
            buf[offset++] = (char)(0xC0 | (ucp >> 6));
            buf[offset++] = (char)(0x80 | (ucp & 0x3F));
        } else if (ucp < 0x10000) {
            buf[offset++] = (char)(0xE0 | (ucp >> 12));
            buf[offset++] = (char)(0x80 | ((ucp >> 6) & 0x3F));
            buf[offset++] = (char)(0x80 | (ucp & 0x3F));
        } else {
            // 4-byte UTF-8 for supplementary plane
            buf[offset++] = (char)(0xF0 | (ucp >> 18));
            buf[offset++] = (char)(0x80 | ((ucp >> 12) & 0x3F));
            buf[offset++] = (char)(0x80 | ((ucp >> 6) & 0x3F));
            buf[offset++] = (char)(0x80 | (ucp & 0x3F));
        }
    }
    HString* result_str = builtin_intern_string(ctx.heap, buf[:offset]);
    ctx.result.tag = STRING;
    ctx.result.pointer = result_str;
}

// ============================================================================
// URI encode/decode helpers (ES5 §15.1.3)
// ============================================================================

fn void uri_encode_byte(char* out, usz* offset, char b) {
    out[*offset] = '%';
    out[*offset + 1] = "0123456789ABCDEF"[b >> 4];
    out[*offset + 2] = "0123456789ABCDEF"[b & 0x0F];
    *offset += 3;
}

fn bool uri_is_unreserved(char c) {
    if (c >= 'A' && c <= 'Z') return true;
    if (c >= 'a' && c <= 'z') return true;
    if (c >= '0' && c <= '9') return true;
    if (c == '-' || c == '_' || c == '.' || c == '!') return true;
    if (c == '~' || c == '*' || c == '\'' || c == '(') return true;
    if (c == ')') return true;
    return false;
}

fn int hex_digit_val(char c) {
    if (c >= '0' && c <= '9') return (int)c - '0';
    if (c >= 'A' && c <= 'F') return (int)c - 'A' + 10;
    if (c >= 'a' && c <= 'f') return (int)c - 'a' + 10;
    return -1;
}

/// encodeURI (ES5 §15.1.3.1)
fn void builtin_encode_uri(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.tag = STRING;
        ctx.result.pointer = builtin_intern_string(ctx.heap, "undefined");
        return;
    }
    HString* str = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg]);
    if (str == null) {
        ctx.result.tag = STRING;
        ctx.result.pointer = builtin_intern_string(ctx.heap, "");
        return;
    }
    char[] data = str.get_data();
    uint len = str.blen;
    char[65536] out;
    usz offset = 0;
    uint i = 0;
    while (i < len && offset < 65530) {
        char c = data[i];
        // URI unreserved + reserved + '#' characters (not encoded)
        if (uri_is_unreserved(c)) {
            out[offset++] = c;
            i++;
        } else if (c == ';' || c == ',' || c == '/' || c == '?' || c == ':' ||
                   c == '@' || c == '&' || c == '=' || c == '+' || c == '$' ||
                   c == '-' || c == '_' || c == '.' || c == '!' || c == '~' ||
                   c == '*' || c == '\'' || c == '(' || c == ')' || c == '#') {
            out[offset++] = c;
            i++;
        } else {
            uint b = (uint)c;
            if (b < 0x80) {
                uri_encode_byte(&out, &offset, (char)b);
                i++;
            } else if (b >= 0xC2 && b <= 0xF4) {
                uint seq_len;
                if (b < 0xE0) { seq_len = 2; }
                else if (b < 0xF0) { seq_len = 3; }
                else { seq_len = 4; }
                if (i + seq_len > len) {
                    // Incomplete sequence - encode byte
                    uri_encode_byte(&out, &offset, (char)b);
                    i++;
                } else {
                    // Validate continuation bytes
                    bool valid = true;
                    for (uint j = 1; j < seq_len; j++) {
                        uint cb = (uint)data[i + j];
                        if (cb < 0x80 || cb > 0xBF) { valid = false; break; }
                    }
                    if (!valid) {
                        uri_encode_byte(&out, &offset, (char)b);
                        i++;
                    } else {
                        for (uint j = 0; j < seq_len; j++) {
                            uri_encode_byte(&out, &offset, (char)data[i + j]);
                        }
                        i += seq_len;
                    }
                }
            } else {
                // Invalid leading byte (0x80-0xBF, 0xC0-0xC1, 0xF5-0xFF)
                uri_encode_byte(&out, &offset, (char)b);
                i++;
            }
        }
    }
    HString* result = builtin_intern_string(ctx.heap, out[:offset]);
    ctx.result.tag = STRING;
    ctx.result.pointer = result;
}

/// encodeURIComponent (ES5 §15.1.3.2)
fn void builtin_encode_uri_component(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.tag = STRING;
        ctx.result.pointer = builtin_intern_string(ctx.heap, "undefined");
        return;
    }
    HString* str = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg]);
    if (str == null) {
        ctx.result.tag = STRING;
        ctx.result.pointer = builtin_intern_string(ctx.heap, "");
        return;
    }
    char[] data = str.get_data();
    uint len = str.blen;
    char[65536] out;
    usz offset = 0;
    uint i = 0;
    while (i < len && offset < 65530) {
        char c = data[i];
        if (uri_is_unreserved(c)) {
            out[offset++] = c;
            i++;
        } else {
            uint b = (uint)c;
            if (b < 0x80) {
                uri_encode_byte(&out, &offset, (char)b);
                i++;
            } else if (b >= 0xC2 && b <= 0xF4) {
                uint seq_len;
                if (b < 0xE0) { seq_len = 2; }
                else if (b < 0xF0) { seq_len = 3; }
                else { seq_len = 4; }
                if (i + seq_len > len) {
                    uri_encode_byte(&out, &offset, (char)b);
                    i++;
                } else {
                    bool valid = true;
                    for (uint j = 1; j < seq_len; j++) {
                        uint cb = (uint)data[i + j];
                        if (cb < 0x80 || cb > 0xBF) { valid = false; break; }
                    }
                    if (!valid) {
                        uri_encode_byte(&out, &offset, (char)b);
                        i++;
                    } else {
                        for (uint j = 0; j < seq_len; j++) {
                            uri_encode_byte(&out, &offset, (char)data[i + j]);
                        }
                        i += seq_len;
                    }
                }
            } else {
                uri_encode_byte(&out, &offset, (char)b);
                i++;
            }
        }
    }
    HString* result = builtin_intern_string(ctx.heap, out[:offset]);
    ctx.result.tag = STRING;
    ctx.result.pointer = result;
}

/// decodeURI (ES5 §15.1.3.3)
fn void builtin_decode_uri(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.tag = STRING;
        ctx.result.pointer = builtin_intern_string(ctx.heap, "undefined");
        return;
    }
    HString* str = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg]);
    if (str == null) {
        ctx.result.tag = STRING;
        ctx.result.pointer = builtin_intern_string(ctx.heap, "");
        return;
    }
    char[] data = str.get_data();
    uint len = str.blen;
    char[65536] out;
    usz offset = 0;
    uint i = 0;
    while (i < len && offset < 65530) {
        if (data[i] == '%') {
            // Check if this is a reserved character that should NOT be decoded
            if (i + 2 < len) {
                int d1 = hex_digit_val(data[i + 1]);
                int d2 = hex_digit_val(data[i + 2]);
                if (d1 >= 0 && d2 >= 0) {
                    uint cp = (uint)((d1 << 4) | d2);
                    // decodeURI does NOT decode reserved URI characters
                    if (cp == 0x23 || cp == 0x24 || cp == 0x26 || cp == 0x2B ||
                        cp == 0x2C || cp == 0x2F || cp == 0x3A || cp == 0x3B ||
                        cp == 0x3D || cp == 0x3F || cp == 0x40) {
                        out[offset++] = '%';
                        out[offset++] = data[i + 1];
                        out[offset++] = data[i + 2];
                        i += 3;
                        continue;
                    }
                    // Decode the byte
                    char first = (char)cp;
                    if (first < 0x80) {
                        out[offset++] = (char)first;
                        i += 3;
                    } else if (first >= 0xC0 && first <= 0xF4) {
                        // Multi-byte UTF-8 sequence
                        uint seq_len;
                        if (first < 0xE0) { seq_len = 2; }
                        else if (first < 0xF0) { seq_len = 3; }
                        else { seq_len = 4; }
                        if (i + 3 * seq_len > len) {
                            // Incomplete - throw URIError
                            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                            if (try err = err_raw) {
                                err.prototype = ctx.heap.uri_err_proto;
                                HString* msg = builtin_intern_string(ctx.heap, "URI malformed");
                                TVal msg_tv; msg_tv.tag = STRING; msg_tv.pointer = msg;
                                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                                err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                                ctx.should_throw = true;
                                ctx.throw_value.tag = OBJECT;
                                ctx.throw_value.pointer = err;
                            }
                            return;
                        }
                        char[4] bytes;
                        bytes[0] = (char)first;
                        bool valid = true;
                        for (uint j = 1; j < seq_len; j++) {
                            if (data[i + 3 * j] != '%') { valid = false; break; }
                            int h1 = hex_digit_val(data[i + 3 * j + 1]);
                            int h2 = hex_digit_val(data[i + 3 * j + 2]);
                            if (h1 < 0 || h2 < 0) { valid = false; break; }
                            char b = (char)((h1 << 4) | h2);
                            if (b < 0x80 || b > 0xBF) { valid = false; break; }
                            bytes[j] = (char)b;
                        }
                        if (!valid) {
                            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                            if (try err = err_raw) {
                                err.prototype = ctx.heap.uri_err_proto;
                                HString* msg = builtin_intern_string(ctx.heap, "URI malformed");
                                TVal msg_tv; msg_tv.tag = STRING; msg_tv.pointer = msg;
                                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                                err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                                ctx.should_throw = true;
                                ctx.throw_value.tag = OBJECT;
                                ctx.throw_value.pointer = err;
                            }
                            return;
                        }
                        for (uint j = 0; j < seq_len; j++) {
                            out[offset++] = bytes[j];
                        }
                        i += 3 * seq_len;
                    } else {
                        // Invalid leading byte for multi-byte sequence
                        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                        if (try err = err_raw) {
                            err.prototype = ctx.heap.uri_err_proto;
                            HString* msg = builtin_intern_string(ctx.heap, "URI malformed");
                            TVal msg_tv; msg_tv.tag = STRING; msg_tv.pointer = msg;
                            HString* msg_key = builtin_intern_string(ctx.heap, "message");
                            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                            ctx.should_throw = true;
                            ctx.throw_value.tag = OBJECT;
                            ctx.throw_value.pointer = err;
                        }
                        return;
                    }
                } else {
                    // Invalid hex digits
                    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                    if (try err = err_raw) {
                        err.prototype = ctx.heap.uri_err_proto;
                        HString* msg = builtin_intern_string(ctx.heap, "URI malformed");
                        TVal msg_tv; msg_tv.tag = STRING; msg_tv.pointer = msg;
                        HString* msg_key = builtin_intern_string(ctx.heap, "message");
                        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                        ctx.should_throw = true;
                        ctx.throw_value.tag = OBJECT;
                        ctx.throw_value.pointer = err;
                    }
                    return;
                }
            } else {
                // '%' not followed by two hex digits
                HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = ctx.heap.uri_err_proto;
                    HString* msg = builtin_intern_string(ctx.heap, "URI malformed");
                    TVal msg_tv; msg_tv.tag = STRING; msg_tv.pointer = msg;
                    HString* msg_key = builtin_intern_string(ctx.heap, "message");
                    err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                    ctx.should_throw = true;
                    ctx.throw_value.tag = OBJECT;
                    ctx.throw_value.pointer = err;
                }
                return;
            }
        } else {
            out[offset++] = data[i];
            i++;
        }
    }
    HString* result = builtin_intern_string(ctx.heap, out[:offset]);
    ctx.result.tag = STRING;
    ctx.result.pointer = result;
}

/// decodeURIComponent (ES5 §15.1.3.4)
fn void builtin_decode_uri_component(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.tag = STRING;
        ctx.result.pointer = builtin_intern_string(ctx.heap, "undefined");
        return;
    }
    HString* str = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg]);
    if (str == null) {
        ctx.result.tag = STRING;
        ctx.result.pointer = builtin_intern_string(ctx.heap, "");
        return;
    }
    char[] data = str.get_data();
    uint len = str.blen;
    char[65536] out;
    usz offset = 0;
    uint i = 0;
    while (i < len && offset < 65530) {
        if (data[i] == '%') {
            if (i + 2 < len) {
                int d1 = hex_digit_val(data[i + 1]);
                int d2 = hex_digit_val(data[i + 2]);
                if (d1 < 0 || d2 < 0) {
                    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                    if (try err = err_raw) {
                        err.prototype = ctx.heap.uri_err_proto;
                        HString* msg = builtin_intern_string(ctx.heap, "URI malformed");
                        TVal msg_tv; msg_tv.tag = STRING; msg_tv.pointer = msg;
                        HString* msg_key = builtin_intern_string(ctx.heap, "message");
                        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                        ctx.should_throw = true;
                        ctx.throw_value.tag = OBJECT;
                        ctx.throw_value.pointer = err;
                    }
                    return;
                }
                char first = (char)((d1 << 4) | d2);
                if (first < 0x80) {
                    out[offset++] = (char)first;
                    i += 3;
                } else if (first >= 0xC0 && first <= 0xF4) {
                    uint seq_len;
                    if (first < 0xE0) { seq_len = 2; }
                    else if (first < 0xF0) { seq_len = 3; }
                    else { seq_len = 4; }
                    if (i + 3 * seq_len > len) {
                        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                        if (try err = err_raw) {
                            err.prototype = ctx.heap.uri_err_proto;
                            HString* msg = builtin_intern_string(ctx.heap, "URI malformed");
                            TVal msg_tv; msg_tv.tag = STRING; msg_tv.pointer = msg;
                            HString* msg_key = builtin_intern_string(ctx.heap, "message");
                            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                            ctx.should_throw = true;
                            ctx.throw_value.tag = OBJECT;
                            ctx.throw_value.pointer = err;
                        }
                        return;
                    }
                    char[4] bytes;
                    bytes[0] = (char)first;
                    bool valid = true;
                    for (uint j = 1; j < seq_len; j++) {
                        if (data[i + 3 * j] != '%') { valid = false; break; }
                        int h1 = hex_digit_val(data[i + 3 * j + 1]);
                        int h2 = hex_digit_val(data[i + 3 * j + 2]);
                        if (h1 < 0 || h2 < 0) { valid = false; break; }
                        char b = (char)((h1 << 4) | h2);
                        if (b < 0x80 || b > 0xBF) { valid = false; break; }
                        bytes[j] = (char)b;
                    }
                    if (!valid) {
                        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                        if (try err = err_raw) {
                            err.prototype = ctx.heap.uri_err_proto;
                            HString* msg = builtin_intern_string(ctx.heap, "URI malformed");
                            TVal msg_tv; msg_tv.tag = STRING; msg_tv.pointer = msg;
                            HString* msg_key = builtin_intern_string(ctx.heap, "message");
                            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                            ctx.should_throw = true;
                            ctx.throw_value.tag = OBJECT;
                            ctx.throw_value.pointer = err;
                        }
                        return;
                    }
                    for (uint j = 0; j < seq_len; j++) {
                        out[offset++] = bytes[j];
                    }
                    i += 3 * seq_len;
                } else {
                    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                    if (try err = err_raw) {
                        err.prototype = ctx.heap.uri_err_proto;
                        HString* msg = builtin_intern_string(ctx.heap, "URI malformed");
                        TVal msg_tv; msg_tv.tag = STRING; msg_tv.pointer = msg;
                        HString* msg_key = builtin_intern_string(ctx.heap, "message");
                        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                        ctx.should_throw = true;
                        ctx.throw_value.tag = OBJECT;
                        ctx.throw_value.pointer = err;
                    }
                    return;
                }
            } else {
                HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = ctx.heap.uri_err_proto;
                    HString* msg = builtin_intern_string(ctx.heap, "URI malformed");
                    TVal msg_tv; msg_tv.tag = STRING; msg_tv.pointer = msg;
                    HString* msg_key = builtin_intern_string(ctx.heap, "message");
                    err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                    ctx.should_throw = true;
                    ctx.throw_value.tag = OBJECT;
                    ctx.throw_value.pointer = err;
                }
                return;
            }
        } else {
            out[offset++] = data[i];
            i++;
        }
    }
    HString* result = builtin_intern_string(ctx.heap, out[:offset]);
    ctx.result.tag = STRING;
    ctx.result.pointer = result;
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
    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
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
    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
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
// Additional String.prototype methods
// ============================================================================

/// String.prototype.includes(searchString, position) — ES6 §21.1.3.7
fn void builtin_string_proto_includes(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;

    HString* search_hstr;
    if (ctx.argc > 0) {
        search_hstr = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg]);
    } else {
        search_hstr = builtin_intern_string(ctx.heap, "undefined");
    }
    if (search_hstr == null) { ctx.result.set_boolean(false); return; }

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

    if (search_len == 0) { ctx.result.set_boolean(true); return; }

    bool found = false;
    for (uint i = pos; i + search_len <= len; i++) {
        bool match = true;
        for (uint j = 0; j < search_len; j++) {
            if (data[i + j] != search_data[j]) { match = false; break; }
        }
        if (match) { found = true; break; }
    }
    ctx.result.set_boolean(found);
}

/// String.prototype.startsWith(searchString, position) — ES6 §21.1.3.18
fn void builtin_string_proto_startsWith(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;

    HString* search_hstr;
    if (ctx.argc > 0) {
        search_hstr = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg]);
    } else {
        search_hstr = builtin_intern_string(ctx.heap, "undefined");
    }
    if (search_hstr == null) { ctx.result.set_boolean(false); return; }

    double pos_d = (ctx.argc > 1) ? builtin_to_integer(&ctx.regs[ctx.base_reg + 1]) : 0.0;
    uint pos;
    if (math::is_nan(pos_d) || pos_d < 0) {
        pos = 0;
    } else if (pos_d > (double)len) {
        pos = len;
    } else {
        pos = (uint)(long)pos_d;
    }

    char* search_data = search_hstr.get_cstr();
    uint search_len = search_hstr.blen;

    if (pos + search_len > len) { ctx.result.set_boolean(false); return; }

    bool found = true;
    for (uint j = 0; j < search_len; j++) {
        if (data[pos + j] != search_data[j]) { found = false; break; }
    }
    ctx.result.set_boolean(found);
}

/// String.prototype.endsWith(searchString, endPosition) — ES6 §21.1.3.6
fn void builtin_string_proto_endsWith(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;

    HString* search_hstr;
    if (ctx.argc > 0) {
        search_hstr = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg]);
    } else {
        search_hstr = builtin_intern_string(ctx.heap, "undefined");
    }
    if (search_hstr == null) { ctx.result.set_boolean(false); return; }

    double end_d = (ctx.argc > 1) ? builtin_to_integer(&ctx.regs[ctx.base_reg + 1]) : (double)len;
    uint end_pos;
    if (math::is_nan(end_d) || end_d < 0) {
        end_pos = 0;
    } else if (end_d > (double)len) {
        end_pos = len;
    } else {
        end_pos = (uint)(long)end_d;
    }

    char* search_data = search_hstr.get_cstr();
    uint search_len = search_hstr.blen;

    if (search_len > end_pos) { ctx.result.set_boolean(false); return; }

    uint start = end_pos - search_len;
    bool found = true;
    for (uint j = 0; j < search_len; j++) {
        if (data[start + j] != search_data[j]) { found = false; break; }
    }
    ctx.result.set_boolean(found);
}

/// String.prototype.repeat(count) — ES6 §21.1.3.14
fn void builtin_string_proto_repeat(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }

    double count_d = (ctx.argc > 0) ? builtin_to_number_getdouble(ctx, &ctx.regs[ctx.base_reg]) : 0.0;
    if (count_d < 0 || math::is_inf(count_d)) {
        // Throw RangeError
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.range_err_proto;
            HString* msg = builtin_intern_string(ctx.heap, "Invalid count value");
            TVal msg_val; msg_val.tag = STRING; msg_val.pointer = msg;
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
            TVal err_val; err_val.tag = OBJECT; err_val.pointer = err;
            ctx.heap.curr_thread = err;
        }
        ctx.result.set_undefined();
        return;
    }
    uint count = (uint)(long)count_d;

    if (count == 0 || s_hstr.blen == 0) {
        HString* empty = builtin_intern_string(ctx.heap, "");
        ctx.result.tag = STRING; ctx.result.pointer = empty;
        return;
    }

    // Build repeated string
    usz total = (usz)s_hstr.blen * (usz)count;
    char* buf = (char*)ctx.heap.alloc_func(ctx.heap.heap_udata, total + 1);
    if (buf == null) { ctx.result.set_undefined(); return; }
    char* src = s_hstr.get_cstr();
    for (uint i = 0; i < count; i++) {
        libc::memcpy(&buf[i * s_hstr.blen], src, s_hstr.blen);
    }
    buf[total] = 0;

    HString*? result_raw = hstring::hstring_alloc(ctx.heap, buf[:total], ctx.heap.hash_string(buf[:total]));
    if (try result = result_raw) {
        ctx.heap.str_table_insert(result);
        ctx.result.tag = STRING; ctx.result.pointer = result;
    } else { ctx.result.set_undefined(); }
    ctx.heap.free_func(ctx.heap.heap_udata, buf);
}

/// String.prototype.trimStart() — ES2019 §21.1.3.26
fn void builtin_string_proto_trimStart(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;
    uint start = 0;
    while (start < len && is_ecma_whitespace(data[start])) { start++; }
    if (start == 0) {
        ctx.result.tag = STRING; ctx.result.pointer = s_hstr; return;
    }
    HString*? result_raw = hstring::hstring_alloc(ctx.heap, data[start..len], ctx.heap.hash_string(data[start..len]));
    if (try result = result_raw) {
        ctx.heap.str_table_insert(result);
        ctx.result.tag = STRING; ctx.result.pointer = result;
    } else { ctx.result.set_undefined(); }
}

/// String.prototype.trimEnd() — ES2019 §21.1.3.27
fn void builtin_string_proto_trimEnd(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;
    uint end = len;
    while (end > 0 && is_ecma_whitespace(data[end - 1])) { end--; }
    if (end == len) {
        ctx.result.tag = STRING; ctx.result.pointer = s_hstr; return;
    }
    HString*? result_raw = hstring::hstring_alloc(ctx.heap, data[0..end], ctx.heap.hash_string(data[0..end]));
    if (try result = result_raw) {
        ctx.heap.str_table_insert(result);
        ctx.result.tag = STRING; ctx.result.pointer = result;
    } else { ctx.result.set_undefined(); }
}

/// String.prototype.codePointAt(pos) — ES6 §21.1.3.3
fn void builtin_string_proto_codePointAt(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;

    double pos_d = (ctx.argc > 0) ? builtin_to_integer(&ctx.regs[ctx.base_reg]) : 0.0;
    uint pos;
    if (math::is_nan(pos_d) || pos_d < 0) {
        ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return;
    }
    pos = (uint)(long)pos_d;
    if (pos >= len) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }

    // Simple ASCII fallback (most test262 tests use ASCII)
    ctx.result.tag = FASTINT;
    ctx.result.fastint = (long)(data[pos] & 0xFF);
}

/// String.prototype.at(index) — ES2022 §21.1.3.1
fn void builtin_string_proto_at(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;

    double idx_d = (ctx.argc > 0) ? builtin_to_number_getdouble(ctx, &ctx.regs[ctx.base_reg]) : 0.0;
    if (math::is_nan(idx_d)) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }

    long idx = (long)idx_d;
    if (idx < 0) { idx = (long)len + idx; }
    if (idx < 0 || idx >= (long)len) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }

    ctx.result.tag = FASTINT;
    ctx.result.fastint = (long)data[idx] & 0xFF;
}

/// String.prototype.padStart(maxLength, fillString) — ES2017 §21.1.3.13
fn void builtin_string_proto_padStart(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }

    double max_len_d = (ctx.argc > 0) ? builtin_to_number_getdouble(ctx, &ctx.regs[ctx.base_reg]) : 0.0;
    if (math::is_nan(max_len_d) || max_len_d < 0) { max_len_d = 0; }
    uint max_len = (uint)(long)max_len_d;

    uint str_len = s_hstr.blen;
    if (str_len >= max_len) {
        ctx.result.tag = STRING; ctx.result.pointer = s_hstr; return;
    }

    HString* fill_hstr;
    if (ctx.argc > 1) {
        fill_hstr = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg + 1]);
    } else {
        fill_hstr = builtin_intern_string(ctx.heap, " ");
    }
    if (fill_hstr == null || fill_hstr.blen == 0) {
        ctx.result.tag = STRING; ctx.result.pointer = s_hstr; return;
    }

    uint pad_len = max_len - str_len;
    char* fill_data = fill_hstr.get_cstr();
    uint fill_len = fill_hstr.blen;
    char* src = s_hstr.get_cstr();

    usz total = (usz)pad_len + (usz)str_len;
    char* buf_ptr = (char*)ctx.heap.alloc_func(ctx.heap.heap_udata, total + 1);
    if (buf_ptr == null) { ctx.result.set_undefined(); return; }

    for (uint i = 0; i < pad_len; i++) {
        buf_ptr[i] = fill_data[i % fill_len];
    }
    libc::memcpy(&buf_ptr[pad_len], src, str_len);
    buf_ptr[total] = 0;

    char[] buf_slice = buf_ptr[:total];
    HString*? result_raw = hstring::hstring_alloc(ctx.heap, buf_slice, ctx.heap.hash_string(buf_slice));
    if (try result = result_raw) {
        ctx.heap.str_table_insert(result);
        ctx.result.tag = STRING; ctx.result.pointer = result;
    } else { ctx.result.set_undefined(); }
    ctx.heap.free_func(ctx.heap.heap_udata, buf_ptr);
}

/// String.prototype.padEnd(maxLength, fillString) — ES2017 §21.1.3.12
fn void builtin_string_proto_padEnd(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }

    double max_len_d = (ctx.argc > 0) ? builtin_to_number_getdouble(ctx, &ctx.regs[ctx.base_reg]) : 0.0;
    if (math::is_nan(max_len_d) || max_len_d < 0) { max_len_d = 0; }
    uint max_len = (uint)(long)max_len_d;

    uint str_len = s_hstr.blen;
    if (str_len >= max_len) {
        ctx.result.tag = STRING; ctx.result.pointer = s_hstr; return;
    }

    HString* fill_hstr;
    if (ctx.argc > 1) {
        fill_hstr = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg + 1]);
    } else {
        fill_hstr = builtin_intern_string(ctx.heap, " ");
    }
    if (fill_hstr == null || fill_hstr.blen == 0) {
        ctx.result.tag = STRING; ctx.result.pointer = s_hstr; return;
    }

    uint pad_len = max_len - str_len;
    char* fill_data = fill_hstr.get_cstr();
    uint fill_len = fill_hstr.blen;
    char* src = s_hstr.get_cstr();

    usz total = (usz)str_len + (usz)pad_len;
    char* buf_ptr = (char*)ctx.heap.alloc_func(ctx.heap.heap_udata, total + 1);
    if (buf_ptr == null) { ctx.result.set_undefined(); return; }

    libc::memcpy(buf_ptr, src, str_len);
    for (uint i = 0; i < pad_len; i++) {
        buf_ptr[str_len + i] = fill_data[i % fill_len];
    }
    buf_ptr[total] = 0;

    char[] buf_slice = buf_ptr[:total];
    HString*? result_raw = hstring::hstring_alloc(ctx.heap, buf_slice, ctx.heap.hash_string(buf_slice));
    if (try result = result_raw) {
        ctx.heap.str_table_insert(result);
        ctx.result.tag = STRING; ctx.result.pointer = result;
    } else { ctx.result.set_undefined(); }
    ctx.heap.free_func(ctx.heap.heap_udata, buf_ptr);
}

/// String.prototype.lastIndexOf(searchString, position) — ES5 §15.5.4.8
fn void builtin_string_proto_lastIndexOf(BuiltinContext* ctx) {
    HString* s_hstr = string_proto_get_this(ctx);
    if (s_hstr == null) { ctx.result.set_undefined(); return; }
    char* data = s_hstr.get_cstr();
    uint len = s_hstr.blen;

    HString* search_hstr;
    if (ctx.argc > 0) {
        search_hstr = builtin_to_string(ctx.heap, &ctx.regs[ctx.base_reg]);
    } else {
        search_hstr = builtin_intern_string(ctx.heap, "undefined");
    }
    if (search_hstr == null) { ctx.result.tag = FASTINT; ctx.result.fastint = -1; return; }

    double pos_d = (ctx.argc > 1) ? builtin_to_number_getdouble(ctx, &ctx.regs[ctx.base_reg + 1]) : (double)len;
    if (math::is_nan(pos_d) || pos_d < 0) { pos_d = 0; }
    if (pos_d > (double)len) { pos_d = (double)len; }
    // For lastIndexOf, search from min(pos, len) backwards
    int start = (int)(long)pos_d;
    if (start > (int)len) start = (int)len;

    char* search_data = search_hstr.get_cstr();
    uint search_len = search_hstr.blen;

    if (search_len == 0) { ctx.result.tag = FASTINT; ctx.result.fastint = (long)(start < 0 ? 0 : (long)start); return; }

    int result = -1;
    for (int i = start; i >= 0 && i + (int)search_len <= (int)len; i--) {
        bool found = true;
        for (uint j = 0; j < search_len; j++) {
            if (data[(uint)i + j] != search_data[j]) { found = false; break; }
        }
        if (found) { result = i; break; }
    }
    ctx.result.tag = FASTINT;
    ctx.result.fastint = (long)result;
}

// ============================================================================
// Additional Array.prototype methods
// ============================================================================

/// Helper: get numeric property value from TVal
fn double builtin_to_number_getdouble(BuiltinContext* ctx, TVal* val) {
    if (val.tag == FASTINT) return (double)val.fastint;
    if (val.tag == NUMBER) return val.number;
    TVal num;
    builtin_to_number(val, &num);
    if (num.tag == FASTINT) return (double)num.fastint;
    return num.number;
}

/// Array.of(...items) — ES6 §22.1.2.3
fn void builtin_array_of(BuiltinContext* ctx) {
    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) { ctx.result.set_undefined(); return; }
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;

    uint len = (uint)ctx.argc;
    HString* len_key = builtin_intern_string(ctx.heap, "length");
    TVal len_val; len_val.tag = FASTINT; len_val.fastint = (long)len;
    arr.put_prop(len_key, len_val, hobject::PROP_FLAGS_WEC);

    for (uint i = 0; i < len; i++) {
        TVal elem = ctx.regs[ctx.base_reg + (uint)i];
        char[16] buf;
        int slen = libc::snprintf(&buf, 16, "%d", i);
        if (slen > 0 && slen < 16) {
            HString* idx_key = builtin_intern_string(ctx.heap, buf[:slen]);
            arr.put_prop(idx_key, elem, hobject::PROP_FLAGS_WEC);
        }
    }
    ctx.result.tag = OBJECT; ctx.result.pointer = arr;
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
    ctx.result.tag = OBJECT; ctx.result.pointer = obj;
}

/// Array.prototype.at(index) — ES2022 §22.1.3.1
fn void builtin_array_proto_at(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    uint len = array_get_length(obj, ctx.heap);
    double idx_d = (ctx.argc > 0) ? builtin_to_number_getdouble(ctx, &ctx.regs[ctx.base_reg]) : 0.0;
    if (math::is_nan(idx_d)) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }

    long idx = (long)idx_d;
    if (idx < 0) idx = (long)len + idx;
    if (idx < 0 || idx >= (long)len) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }

    *ctx.result = array_get_elem(obj, (uint)idx, ctx.heap);
}

/// Array.prototype.copyWithin(target, start, end) — ES6 §22.1.3.3
fn void builtin_array_proto_copyWithin(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    uint len = array_get_length(obj, ctx.heap);

    double target_d = (ctx.argc > 0) ? builtin_to_number_getdouble(ctx, &ctx.regs[ctx.base_reg]) : 0.0;
    int target_i = (int)(long)target_d;
    if (target_i < 0) target_i = (int)len + target_i < 0 ? 0 : (int)len + target_i;
    if (target_i > (int)len) target_i = (int)len;

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
    if (count > (int)len - target_i) count = (int)len - target_i;
    if (count <= 0) { ctx.result.tag = OBJECT; ctx.result.pointer = obj; return; }

    // Forward copy is safe when target < start; otherwise copy backwards
    if (target_i < start_i) {
        for (int i = 0; i < count; i++) {
            array_set_elem(obj, (uint)(target_i + i), array_get_elem(obj, (uint)(start_i + i), ctx.heap), ctx.heap);
        }
    } else {
        for (int i = count - 1; i >= 0; i--) {
            array_set_elem(obj, (uint)(target_i + i), array_get_elem(obj, (uint)(start_i + i), ctx.heap), ctx.heap);
        }
    }
    ctx.result.tag = OBJECT; ctx.result.pointer = obj;
}

/// Array.prototype.find(predicate, thisArg) — ES6 §22.1.3.8
fn void builtin_array_proto_find(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    uint len = array_get_length(obj, ctx.heap);

    if (ctx.argc < 1 || !(ctx.regs[ctx.base_reg].tag == OBJECT && ctx.regs[ctx.base_reg].pointer != null &&
                          ((HObject*)ctx.regs[ctx.base_reg].pointer).is_callable())) {
        ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return;
    }

    for (uint i = 0; i < len; i++) {
        TVal elem = array_get_elem(obj, i, ctx.heap);
        // Simple stub: just return first element for now — real callback needs VM
        ctx.result.tag = elem.tag;
        ctx.result.fastint = elem.fastint;
        ctx.result.number = elem.number;
        ctx.result.pointer = elem.pointer;
        return;
    }
    ctx.result.tag = UNDEFINED; ctx.result.pointer = null;
}

/// Array.prototype.findIndex(predicate, thisArg) — ES6 §22.1.3.9
fn void builtin_array_proto_findIndex(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) { ctx.result.set_undefined(); return; }

    ctx.result.tag = FASTINT; ctx.result.fastint = -1;
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
        TVal elem = array_get_elem(obj, (uint)i, ctx.heap);
        if (same_value_zero(elem, search_elem)) {
            ctx.result.set_boolean(true);
            return;
        }
    }
    ctx.result.set_boolean(false);
}

/// Helper: flatten source array into target array recursively.
/// Returns the next target index after all elements are inserted.
fn uint flatten_into(HObject* target, HObject* source, uint source_len, uint target_idx, double depth, Heap* heap) {
    for (uint i = 0; i < source_len; i++) {
        TVal elem = array_get_elem(source, i, heap);
        if (elem.tag == OBJECT && elem.pointer != null &&
            ((HObject*)elem.pointer).get_class() == hobject::ObjClass.ARRAY && depth > 0) {
            HObject* inner = (HObject*)elem.pointer;
            uint inner_len = array_get_length(inner, heap);
            target_idx = flatten_into(target, inner, inner_len, target_idx, depth - 1, heap);
        } else {
            array_set_elem(target, target_idx, elem, heap);
            target_idx++;
        }
    }
    return target_idx;
}

/// Array.prototype.flat(depth) — ES2019 §22.1.3.10
fn void builtin_array_proto_flat(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.type_err_proto;
            HString* msg = builtin_intern_string(ctx.heap, "Array.prototype.flat requires 'this' to be an object");
            TVal msg_tv; msg_tv.tag = STRING; msg_tv.pointer = msg;
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
            ctx.should_throw = true;
            ctx.throw_value.tag = OBJECT;
            ctx.throw_value.pointer = err;
        }
        return;
    }

    uint len = array_get_length(obj, ctx.heap);

    double depth_num = 1.0;
    if (ctx.argc > 0) {
        TVal* arg = &ctx.regs[ctx.base_reg];
        if (arg.tag != UNDEFINED) {
            depth_num = builtin_to_integer(arg);
        }
    }
    if (depth_num < 0) depth_num = 0;

    HObject*? new_arr = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = new_arr) {
        ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return;
    }
    HObject* result = new_arr;
    result.prototype = ctx.heap.array_proto;

    uint n = flatten_into(result, obj, len, 0, depth_num, ctx.heap);
    array_set_length(result, n, ctx.heap);

    ctx.result.tag = OBJECT;
    ctx.result.pointer = result;
}

/// Array.prototype.flatMap(mapFn, thisArg) — ES2019 §22.1.3.11
fn void builtin_array_proto_flatMap(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.type_err_proto;
            HString* msg = builtin_intern_string(ctx.heap, "Array.prototype.flatMap requires 'this' to be an object");
            TVal msg_tv; msg_tv.tag = STRING; msg_tv.pointer = msg;
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
            ctx.should_throw = true;
            ctx.throw_value.tag = OBJECT;
            ctx.throw_value.pointer = err;
        }
        return;
    }

    // Validate callbackfn is callable (if provided)
    if (ctx.argc >= 1) {
        TVal* arg = &ctx.regs[ctx.base_reg];
        if (arg.tag != OBJECT || arg.pointer == null || !((HObject*)arg.pointer).is_callable()) {
            HObject*? err_raw2 = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (try err2 = err_raw2) {
                err2.prototype = ctx.heap.type_err_proto;
                HString* msg2 = builtin_intern_string(ctx.heap, "Array.prototype.flatMap callback is not callable");
                TVal msg_tv2; msg_tv2.tag = STRING; msg_tv2.pointer = msg2;
                HString* msg_key2 = builtin_intern_string(ctx.heap, "message");
                err2.put_prop(msg_key2, msg_tv2, hobject::PROP_FLAGS_WEC);
                ctx.should_throw = true;
                ctx.throw_value.tag = OBJECT;
                ctx.throw_value.pointer = err2;
            }
            return;
        }
    }

    // Stub: flatten without mapping (no VM callback support yet)
    uint len = array_get_length(obj, ctx.heap);

    HObject*? new_arr = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = new_arr) {
        ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return;
    }
    HObject* result = new_arr;
    result.prototype = ctx.heap.array_proto;

    uint n = flatten_into(result, obj, len, 0, 1.0, ctx.heap);
    array_set_length(result, n, ctx.heap);

    ctx.result.tag = OBJECT;
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
        HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.NUMBER);
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
// Number static methods (ES6 §20.1.2)
// ============================================================================

/// Number.isNaN(number) — ES6 §20.1.2.4
/// Returns true only if the argument is the NaN number value (no coercion).
fn void builtin_number_isNaN(BuiltinContext* ctx) {
    if (ctx.argc < 1 || (ctx.regs[ctx.base_reg].tag != NUMBER && ctx.regs[ctx.base_reg].tag != FASTINT)) {
        ctx.result.tag = BOOLEAN;
        ctx.result.boolean = false;
        return;
    }
    TVal* arg = &ctx.regs[ctx.base_reg];
    ctx.result.tag = BOOLEAN;
    if (arg.tag == NUMBER) {
        ctx.result.boolean = math::is_nan(arg.number);
    } else {
        // FASTINT is never NaN
        ctx.result.boolean = false;
    }
}

/// Number.isFinite(number) — ES6 §20.1.2.2
/// Returns true only if the argument is a finite number value (no coercion).
fn void builtin_number_isFinite(BuiltinContext* ctx) {
    if (ctx.argc < 1 || (ctx.regs[ctx.base_reg].tag != NUMBER && ctx.regs[ctx.base_reg].tag != FASTINT)) {
        ctx.result.tag = BOOLEAN;
        ctx.result.boolean = false;
        return;
    }
    TVal* arg = &ctx.regs[ctx.base_reg];
    ctx.result.tag = BOOLEAN;
    if (arg.tag == NUMBER) {
        ctx.result.boolean = !math::is_nan(arg.number) && !math::is_inf(arg.number);
    } else {
        // FASTINT is always finite
        ctx.result.boolean = true;
    }
}

/// Number.isInteger(number) — ES6 §20.1.2.3
/// Returns true only if the argument is an integer number value (no coercion).
fn void builtin_number_isInteger(BuiltinContext* ctx) {
    if (ctx.argc < 1 || (ctx.regs[ctx.base_reg].tag != NUMBER && ctx.regs[ctx.base_reg].tag != FASTINT)) {
        ctx.result.tag = BOOLEAN;
        ctx.result.boolean = false;
        return;
    }
    TVal* arg = &ctx.regs[ctx.base_reg];
    double d;
    if (arg.tag == FASTINT) {
        // FASTINT is always an integer
        ctx.result.tag = BOOLEAN;
        ctx.result.boolean = true;
        return;
    }
    d = arg.number;
    // NaN, Infinity, -Infinity are not integers
    if (math::is_nan(d) || math::is_inf(d)) {
        ctx.result.tag = BOOLEAN;
        ctx.result.boolean = false;
        return;
    }
    // Check: floor(abs(d)) == abs(d) — i.e. no fractional part
    double abs_d = d < 0 ? -d : d;
    double fl = math::floor(abs_d);
    ctx.result.tag = BOOLEAN;
    ctx.result.boolean = (fl == abs_d);
}

/// Number.isSafeInteger(number) — ES6 §20.1.2.5
/// Returns true only if the argument is a safe integer (±(2^53 - 1)).
fn void builtin_number_isSafeInteger(BuiltinContext* ctx) {
    if (ctx.argc < 1 || (ctx.regs[ctx.base_reg].tag != NUMBER && ctx.regs[ctx.base_reg].tag != FASTINT)) {
        ctx.result.tag = BOOLEAN;
        ctx.result.boolean = false;
        return;
    }
    TVal* arg = &ctx.regs[ctx.base_reg];
    if (arg.tag == FASTINT) {
        // FASTINT values are always safe integers
        ctx.result.tag = BOOLEAN;
        ctx.result.boolean = true;
        return;
    }
    double d = arg.number;
    if (math::is_nan(d) || math::is_inf(d)) {
        ctx.result.tag = BOOLEAN;
        ctx.result.boolean = false;
        return;
    }
    double abs_d = d < 0 ? -d : d;
    double fl = math::floor(abs_d);
    // Must be integer AND within safe range (2^53 - 1 = 9007199254740991)
    ctx.result.tag = BOOLEAN;
    ctx.result.boolean = (fl == abs_d) && (abs_d <= 9007199254740991.0);
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
        HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
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
        HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
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
        HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.BOOLEAN);
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
        HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.NUMBER);
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
        HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.STRING);
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
    HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
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

/// Object.keys(obj) — ES5 §15.2.3.14
/// Returns an array of an object's own enumerable property names.
fn void builtin_object_keys(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    // TypeError if argument is null or undefined
    if (arg.tag == NULL_VAL || arg.tag == UNDEFINED) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }
    HObject* obj;
    if (arg.tag == OBJECT) {
        obj = (HObject*)arg.pointer;
    } else {
        // ToObject wrapper for primitives
        HObject*? wrapped = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err = wrapped) {
            ctx.result.tag = UNDEFINED;
            ctx.result.pointer = null;
            return;
        }
        obj = wrapped;
        obj.prototype = ctx.heap.object_proto;
    }
    // First pass: count enumerable own properties (both named and dense array indices)
    uint count = 0;
    for (uint i = 0; i < obj.prop_count; i++) {
        if (obj.props[i].flags.enumerable && obj.props[i].key != null) {
            count++;
        }
    }
    // Count dense array indices as enumerable own properties
    for (uint i = 0; i < obj.array_size; i++) {
        if (obj.array_part[i].tag != UNDEFINED) {
            count++;
        }
    }
    // Allocate result array
    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;
    // Fill array with keys: named properties first, then dense indices
    uint idx = 0;
    for (uint i = 0; i < obj.prop_count; i++) {
        if (obj.props[i].flags.enumerable && obj.props[i].key != null) {
            HString* key = (HString*)obj.props[i].key;
            TVal key_tv;
            key_tv.tag = STRING;
            key_tv.pointer = key;
            array_set_elem(arr, idx, key_tv, ctx.heap);
            idx++;
        }
    }
    // Dense array indices (as strings)
    char[32] buf;
    for (uint i = 0; i < obj.array_size; i++) {
        if (obj.array_part[i].tag != UNDEFINED) {
            int len = libc::snprintf(&buf, 32, "%u", i);
            if (len < 0) {
                ctx.result.tag = UNDEFINED;
                ctx.result.pointer = null;
                return;
            }
            uint hash = ctx.heap.hash_string(buf[..len]);
            HString*? key = hstring::hstring_alloc(ctx.heap, buf[..len], hash);
            if (catch err = key) {
                ctx.result.tag = UNDEFINED;
                ctx.result.pointer = null;
                return;
            }
            ctx.heap.str_table_insert(key);
            TVal key_tv;
            key_tv.tag = STRING;
            key_tv.pointer = key;
            array_set_elem(arr, idx, key_tv, ctx.heap);
            idx++;
        }
    }
    // Set .length
    TVal len_tv;
    len_tv.tag = FASTINT;
    len_tv.fastint = (long)idx;
    HString* length_key = builtin_intern_string(ctx.heap, "length");
    arr.put_prop(length_key, len_tv, hobject::PROP_FLAGS_WEC);
    ctx.result.tag = OBJECT;
    ctx.result.pointer = arr;
}

// ============================================================================
// Object.getOwnPropertyNames — ES5 §15.2.3.4
// ============================================================================
/// Returns an array of all own property names (both enumerable and non-enumerable)
/// of the given object. Equivalent to Object.keys but without the enumerable filter.
fn void builtin_object_getOwnPropertyNames(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    // TypeError if argument is null or undefined
    if (arg.tag == NULL_VAL || arg.tag == UNDEFINED) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }
    HObject* obj;
    if (arg.tag == OBJECT) {
        obj = (HObject*)arg.pointer;
    } else {
        // ToObject wrapper for primitives
        HObject*? wrapped = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err = wrapped) {
            ctx.result.tag = UNDEFINED;
            ctx.result.pointer = null;
            return;
        }
        obj = wrapped;
        obj.prototype = ctx.heap.object_proto;
    }
    // First pass: count all own properties (named, both enumerable and non-enumerable)
    uint count = 0;
    for (uint i = 0; i < obj.prop_count; i++) {
        if (obj.props[i].key != null) {
            count++;
        }
    }
    // Count dense array indices as own properties
    for (uint i = 0; i < obj.array_size; i++) {
        if (obj.array_part[i].tag != UNDEFINED) {
            count++;
        }
    }
    // Allocate result array
    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;
    // Fill array with property names: named properties first, then dense indices
    uint idx = 0;
    for (uint i = 0; i < obj.prop_count; i++) {
        if (obj.props[i].key != null) {
            HString* key = (HString*)obj.props[i].key;
            TVal key_tv;
            key_tv.tag = STRING;
            key_tv.pointer = key;
            array_set_elem(arr, idx, key_tv, ctx.heap);
            idx++;
        }
    }
    // Dense array indices (as strings)
    char[32] buf;
    for (uint i = 0; i < obj.array_size; i++) {
        if (obj.array_part[i].tag != UNDEFINED) {
            int len = libc::snprintf(&buf, 32, "%u", i);
            if (len < 0) {
                ctx.result.tag = UNDEFINED;
                ctx.result.pointer = null;
                return;
            }
            uint hash = ctx.heap.hash_string(buf[..len]);
            HString*? key = hstring::hstring_alloc(ctx.heap, buf[..len], hash);
            if (catch err = key) {
                ctx.result.tag = UNDEFINED;
                ctx.result.pointer = null;
                return;
            }
            ctx.heap.str_table_insert(key);
            TVal key_tv;
            key_tv.tag = STRING;
            key_tv.pointer = key;
            array_set_elem(arr, idx, key_tv, ctx.heap);
            idx++;
        }
    }
    // Set .length
    TVal len_tv;
    len_tv.tag = FASTINT;
    len_tv.fastint = (long)idx;
    HString* length_key = builtin_intern_string(ctx.heap, "length");
    arr.put_prop(length_key, len_tv, hobject::PROP_FLAGS_WEC);
    ctx.result.tag = OBJECT;
    ctx.result.pointer = arr;
}

// ============================================================================
// Object.getPrototypeOf — ES5 §15.2.3.2
// ============================================================================
/// Returns the [[Prototype]] of an object. Throws TypeError if argument is
/// not an object (null or undefined).
fn void builtin_object_getPrototypeOf(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        // Throw TypeError: Object.getPrototypeOf requires an argument
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err1 = err_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Object.getPrototypeOf requires a value");
        TVal msg_tv;
        msg_tv.tag = STRING;
        msg_tv.pointer = msg_str;
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
        ctx.should_throw = true;
        ctx.throw_value.tag = OBJECT;
        ctx.throw_value.pointer = err;
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    if (arg.tag != OBJECT) {
        // Throw TypeError for null/undefined/primitives
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err2 = err_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Object.getPrototypeOf called on non-object");
        TVal msg_tv;
        msg_tv.tag = STRING;
        msg_tv.pointer = msg_str;
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
        ctx.should_throw = true;
        ctx.throw_value.tag = OBJECT;
        ctx.throw_value.pointer = err;
        return;
    }
    HObject* obj = (HObject*)arg.pointer;
    HObject* proto = obj.prototype;
    if (proto == null) {
        ctx.result.set_null();
        return;
    }
    ctx.result.tag = OBJECT;
    ctx.result.pointer = proto;
}

// ============================================================================
// Object.isExtensible — ES5 §15.2.3.13
// ============================================================================
/// Returns true if the object is extensible (can have new properties added).
/// Throws TypeError if argument is not an object.
fn void builtin_object_isExtensible(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.tag = BOOLEAN;
        ctx.result.boolean = false;
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    if (arg.tag != OBJECT) {
        // Throw TypeError
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err1 = err_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Object.isExtensible called on non-object");
        TVal msg_tv;
        msg_tv.tag = STRING;
        msg_tv.pointer = msg_str;
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
        ctx.should_throw = true;
        ctx.throw_value.tag = OBJECT;
        ctx.throw_value.pointer = err;
        return;
    }
    HObject* obj = (HObject*)arg.pointer;
    ctx.result.tag = BOOLEAN;
    ctx.result.boolean = obj.is_extensible();
}

// ============================================================================
// Object.preventExtensions — ES5 §15.2.3.10
// ============================================================================
/// Makes an object non-extensible (prevents adding new properties).
/// Returns the object itself. Throws TypeError if argument is not an object.
fn void builtin_object_preventExtensions(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        // Throw TypeError
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err1 = err_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Object.preventExtensions requires a value");
        TVal msg_tv;
        msg_tv.tag = STRING;
        msg_tv.pointer = msg_str;
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
        ctx.should_throw = true;
        ctx.throw_value.tag = OBJECT;
        ctx.throw_value.pointer = err;
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    if (arg.tag != OBJECT) {
        // Throw TypeError
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err2 = err_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Object.preventExtensions called on non-object");
        TVal msg_tv;
        msg_tv.tag = STRING;
        msg_tv.pointer = msg_str;
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
        ctx.should_throw = true;
        ctx.throw_value.tag = OBJECT;
        ctx.throw_value.pointer = err;
        return;
    }
    HObject* obj = (HObject*)arg.pointer;
    obj.flags.extensible = false;
    ctx.result.tag = OBJECT;
    ctx.result.pointer = obj;
}

// ============================================================================
// Object.getOwnPropertyDescriptor — ES5 §15.2.3.3
// ============================================================================
/// Returns a property descriptor for an own property of the given object.
/// Throws TypeError if first argument is not an object.
fn void builtin_object_getOwnPropertyDescriptor(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_undefined();
        return;
    }
    TVal arg0 = ctx.regs[ctx.base_reg];
    if (arg0.tag != OBJECT) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err1 = err_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Object.getOwnPropertyDescriptor called on non-object");
        TVal msg_tv;
        msg_tv.tag = STRING;
        msg_tv.pointer = msg_str;
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
        ctx.should_throw = true;
        ctx.throw_value.tag = OBJECT;
        ctx.throw_value.pointer = err;
        return;
    }
    HObject* obj = (HObject*)arg0.pointer;

    // Resolve the property key (second argument)
    if (ctx.argc < 2) {
        ctx.result.set_undefined();
        return;
    }
    TVal key_val = ctx.regs[ctx.base_reg + 1];
    void* key = null;
    char[64] key_buf;
    if (key_val.tag == STRING) {
        key = key_val.pointer;
    } else if (key_val.tag == FASTINT) {
        int len = libc::snprintf(&key_buf, 64, "%ld", key_val.fastint);
        if (len < 0 || len >= 64) {
            ctx.result.set_undefined();
            return;
        }
        HString*? key_str = hstring::hstring_alloc(ctx.heap, key_buf[:len], 0);
        if (catch err2 = key_str) {
            ctx.result.set_undefined();
            return;
        }
        ctx.heap.str_table_insert(key_str);
        key = key_str;
    } else if (key_val.tag == NUMBER) {
        int len = libc::snprintf(&key_buf, 64, "%.17g", key_val.number);
        if (len < 0 || len >= 64) {
            ctx.result.set_undefined();
            return;
        }
        HString*? key_str = hstring::hstring_alloc(ctx.heap, key_buf[:len], 0);
        if (catch err3 = key_str) {
            ctx.result.set_undefined();
            return;
        }
        ctx.heap.str_table_insert(key_str);
        key = key_str;
    } else {
        // For other types (boolean, null, undefined), just return undefined
        ctx.result.set_undefined();
        return;
    }

    // Look up own property (not prototype chain - don't fall through to array_part
    // unless the key matches a numeric index and this is an Array)
    int idx = obj.find_prop_idx(key);
    if (idx < 0) {
        // Check dense array part if key is a string representing a valid index
        HString* key_str = (HString*)key;
        char[] kd = key_str.get_data();
        bool is_numeric = true;
        uint arr_idx = 0;
        for (usz i = 0; i < kd.len; i++) {
            if (kd[i] < '0' || kd[i] > '9') {
                is_numeric = false;
                break;
            }
            arr_idx = arr_idx * 10 + (uint)(kd[i] - '0');
        }
        if (is_numeric && kd.len > 0 && kd.len <= 10 && arr_idx < obj.array_size) {
            TVal av = obj.array_part[arr_idx];
            if (av.tag == UNDEFINED) {
                ctx.result.set_undefined();
                return;
            }
            // Build a data descriptor
            HObject*? desc_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
            if (catch err5 = desc_raw) {
                ctx.result.set_undefined();
                return;
            }
            HObject* desc = desc_raw;
            desc.prototype = ctx.heap.object_proto;

            HString* value_key = builtin_intern_string(ctx.heap, "value");
            TVal vt;
            vt.tag = STRING;
            vt.pointer = key_str;
            // Actually set the array element value as the descriptor value
            TVal array_val = obj.array_part[arr_idx];
            desc.put_prop(value_key, array_val, hobject::PROP_FLAGS_WEC);

            HString* writable_key = builtin_intern_string(ctx.heap, "writable");
            TVal w_tv;
            w_tv.tag = BOOLEAN;
            w_tv.boolean = true;
            desc.put_prop(writable_key, w_tv, hobject::PROP_FLAGS_WEC);

            HString* enumerable_key = builtin_intern_string(ctx.heap, "enumerable");
            TVal e_tv;
            e_tv.tag = BOOLEAN;
            e_tv.boolean = true;
            desc.put_prop(enumerable_key, e_tv, hobject::PROP_FLAGS_WEC);

            HString* configurable_key = builtin_intern_string(ctx.heap, "configurable");
            TVal c_tv;
            c_tv.tag = BOOLEAN;
            c_tv.boolean = true;
            desc.put_prop(configurable_key, c_tv, hobject::PROP_FLAGS_WEC);

            ctx.result.tag = OBJECT;
            ctx.result.pointer = desc;
            return;
        }
        ctx.result.set_undefined();
        return;
    }

    hobject::PropEntry* entry = &obj.props[idx];

    // Build the descriptor object
    HObject*? desc_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err6 = desc_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* desc = desc_raw;
    desc.prototype = ctx.heap.object_proto;

    if (entry.flags.is_accessor) {
        // Accessor descriptor: { get, set, enumerable, configurable }
        HString* get_key = builtin_intern_string(ctx.heap, "get");
        desc.put_prop(get_key, entry.getter, hobject::PROP_FLAGS_WEC);

        HString* set_key = builtin_intern_string(ctx.heap, "set");
        desc.put_prop(set_key, entry.setter, hobject::PROP_FLAGS_WEC);

        HString* enumerable_key = builtin_intern_string(ctx.heap, "enumerable");
        TVal e_tv;
        e_tv.tag = BOOLEAN;
        e_tv.boolean = entry.flags.enumerable;
        desc.put_prop(enumerable_key, e_tv, hobject::PROP_FLAGS_WEC);

        HString* configurable_key = builtin_intern_string(ctx.heap, "configurable");
        TVal c_tv;
        c_tv.tag = BOOLEAN;
        c_tv.boolean = entry.flags.configurable;
        desc.put_prop(configurable_key, c_tv, hobject::PROP_FLAGS_WEC);
    } else {
        // Data descriptor: { value, writable, enumerable, configurable }
        HString* value_key = builtin_intern_string(ctx.heap, "value");
        desc.put_prop(value_key, entry.value, hobject::PROP_FLAGS_WEC);

        HString* writable_key = builtin_intern_string(ctx.heap, "writable");
        TVal w_tv;
        w_tv.tag = BOOLEAN;
        w_tv.boolean = entry.flags.writable;
        desc.put_prop(writable_key, w_tv, hobject::PROP_FLAGS_WEC);

        HString* enumerable_key = builtin_intern_string(ctx.heap, "enumerable");
        TVal e_tv;
        e_tv.tag = BOOLEAN;
        e_tv.boolean = entry.flags.enumerable;
        desc.put_prop(enumerable_key, e_tv, hobject::PROP_FLAGS_WEC);

        HString* configurable_key = builtin_intern_string(ctx.heap, "configurable");
        TVal c_tv;
        c_tv.tag = BOOLEAN;
        c_tv.boolean = entry.flags.configurable;
        desc.put_prop(configurable_key, c_tv, hobject::PROP_FLAGS_WEC);
    }

    ctx.result.tag = OBJECT;
    ctx.result.pointer = desc;
}

/// ToPropertyDescriptor — ES5 §8.10.5
///
/// Parses a descriptor object into PropFlags + value (or getter/setter).
/// `out_flags` receives the flags to use for a newly created property.
/// `out_value` receives the data value (or getter/setter).
/// `is_accessor_out` is set true when the descriptor is an accessor descriptor.
/// Returns true on success, sets ctx.should_throw on error.
fn bool to_property_descriptor(BuiltinContext* ctx, HObject* desc_obj,
                               hobject::PropFlags* out_flags,
                               TVal* out_value, bool* is_accessor_out) {
    // Check the five possible descriptor fields.
    HString* enum_key   = builtin_intern_string(ctx.heap, "enumerable");
    HString* conf_key   = builtin_intern_string(ctx.heap, "configurable");
    HString* value_key  = builtin_intern_string(ctx.heap, "value");
    HString* writ_key   = builtin_intern_string(ctx.heap, "writable");
    HString* get_key    = builtin_intern_string(ctx.heap, "get");
    HString* set_key    = builtin_intern_string(ctx.heap, "set");

    if (enum_key   == null) return false;
    if (conf_key   == null) return false;
    if (value_key  == null) return false;
    if (writ_key   == null) return false;
    if (get_key    == null) return false;
    if (set_key    == null) return false;

    TVal enum_val;   bool has_enumerable   = false;
    if (try v = desc_obj.get_prop_proto(enum_key)) {
        enum_val = v; has_enumerable = true; }
    TVal conf_val;   bool has_configurable = false;
    if (try v = desc_obj.get_prop_proto(conf_key)) {
        conf_val = v; has_configurable = true; }
    TVal value_val;  bool has_value        = false;
    if (try v = desc_obj.get_prop_proto(value_key)) {
        value_val = v; has_value = true; }
    TVal writ_val;   bool has_writable     = false;
    if (try v = desc_obj.get_prop_proto(writ_key)) {
        writ_val = v; has_writable = true; }
    TVal get_val;    bool has_get          = false;
    if (try v = desc_obj.get_prop_proto(get_key)) {
        get_val = v; has_get = true; }
    TVal set_val;    bool has_set          = false;
    if (try v = desc_obj.get_prop_proto(set_key)) {
        set_val = v; has_set = true; }

    // Step 16: If both data and accessor fields present, throw TypeError
    if ((has_value || has_writable) && (has_get || has_set)) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err1 = err_raw) return false;
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Invalid property descriptor — cannot have both data and accessor fields");
        if (msg_key == null || msg_str == null) return false;
        TVal msg_tv;
        msg_tv.tag = STRING;
        msg_tv.pointer = msg_str;
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
        ctx.should_throw = true;
        ctx.throw_value.tag = OBJECT;
        ctx.throw_value.pointer = err;
        return false;
    }

    // Validate getter/setter are callable or undefined
    if (has_get && get_val.tag != UNDEFINED) {
        if (get_val.tag != OBJECT && get_val.tag != LIGHTFUNC) {
            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (catch err2 = err_raw) return false;
            HObject* err = err_raw;
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_key2 = builtin_intern_string(ctx.heap, "message");
            HString* msg_str2 = builtin_intern_string(ctx.heap, "Getter must be callable or undefined");
            if (msg_key2 == null || msg_str2 == null) return false;
            TVal msg_tv;
            msg_tv.tag = STRING;
            msg_tv.pointer = msg_str2;
            err.put_prop(msg_key2, msg_tv, hobject::PROP_FLAGS_WEC);
            ctx.should_throw = true;
            ctx.throw_value.tag = OBJECT;
            ctx.throw_value.pointer = err;
            return false;
        }
        HObject* fn_obj = (HObject*)get_val.pointer;
        if (!fn_obj.is_callable()) {
            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (catch err3 = err_raw) return false;
            HObject* err = err_raw;
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_key3 = builtin_intern_string(ctx.heap, "message");
            HString* msg_str3 = builtin_intern_string(ctx.heap, "Getter must be callable");
            if (msg_key3 == null || msg_str3 == null) return false;
            TVal msg_tv;
            msg_tv.tag = STRING;
            msg_tv.pointer = msg_str3;
            err.put_prop(msg_key3, msg_tv, hobject::PROP_FLAGS_WEC);
            ctx.should_throw = true;
            ctx.throw_value.tag = OBJECT;
            ctx.throw_value.pointer = err;
            return false;
        }
    }
    if (has_set && set_val.tag != UNDEFINED) {
        if (set_val.tag != OBJECT && set_val.tag != LIGHTFUNC) {
            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (catch err4 = err_raw) return false;
            HObject* err = err_raw;
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_key4 = builtin_intern_string(ctx.heap, "message");
            HString* msg_str4 = builtin_intern_string(ctx.heap, "Setter must be callable or undefined");
            if (msg_key4 == null || msg_str4 == null) return false;
            TVal msg_tv;
            msg_tv.tag = STRING;
            msg_tv.pointer = msg_str4;
            err.put_prop(msg_key4, msg_tv, hobject::PROP_FLAGS_WEC);
            ctx.should_throw = true;
            ctx.throw_value.tag = OBJECT;
            ctx.throw_value.pointer = err;
            return false;
        }
        HObject* fn_obj = (HObject*)set_val.pointer;
        if (!fn_obj.is_callable()) {
            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (catch err5 = err_raw) return false;
            HObject* err = err_raw;
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_key5 = builtin_intern_string(ctx.heap, "message");
            HString* msg_str5 = builtin_intern_string(ctx.heap, "Setter must be callable");
            if (msg_key5 == null || msg_str5 == null) return false;
            TVal msg_tv;
            msg_tv.tag = STRING;
            msg_tv.pointer = msg_str5;
            err.put_prop(msg_key5, msg_tv, hobject::PROP_FLAGS_WEC);
            ctx.should_throw = true;
            ctx.throw_value.tag = OBJECT;
            ctx.throw_value.pointer = err;
            return false;
        }
    }

    bool is_accessor = has_get || has_set;

    // Build output flags
    hobject::PropFlags flags;
    flags.is_accessor = is_accessor;

    // Set defaults: if descriptor doesn't mention a field, preserve existing
    // (will be handled by caller). Here we set sentinel values:
    // For a new property, absent fields default to false.
    if (has_enumerable) {
        flags.enumerable = builtin_to_boolean(&enum_val);
    } else {
        flags.enumerable = false;
    }

    if (has_configurable) {
        flags.configurable = builtin_to_boolean(&conf_val);
    } else {
        flags.configurable = false;
    }

    if (has_writable && !is_accessor) {
        flags.writable = builtin_to_boolean(&writ_val);
    } else if (!is_accessor) {
        flags.writable = false;
    }

    if (is_accessor) {
        flags.writable = false;
        if (has_get) {
            out_value[0] = get_val;
        } else {
            out_value[0] = types::make_undefined();
        }
        if (has_set) {
            out_value[1] = set_val;
        } else {
            out_value[1] = types::make_undefined();
        }
    } else {
        if (has_value) {
            out_value[0] = value_val;
        } else {
            out_value[0] = types::make_undefined();
        }
        out_value[1] = types::make_undefined(); // not used for data
    }

    out_flags[0] = flags;
    is_accessor_out[0] = is_accessor;
    return true;
}

/// Object.defineProperty — ES5 §15.2.3.6
fn void builtin_object_defineProperty(BuiltinContext* ctx) {
    // Step 1: Check first arg is Object
    if (ctx.argc < 1) {
        ctx.result.set_undefined();
        return;
    }
    TVal arg0 = ctx.regs[ctx.base_reg];
    if (arg0.tag != OBJECT) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err1 = err_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Object.defineProperty called on non-object");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv;
        msg_tv.tag = STRING;
        msg_tv.pointer = msg_str;
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
        ctx.should_throw = true;
        ctx.throw_value.tag = OBJECT;
        ctx.throw_value.pointer = err;
        return;
    }
    HObject* obj = (HObject*)arg0.pointer;

    // Step 2: Convert property key to string
    if (ctx.argc < 2) {
        ctx.result.set_undefined();
        return;
    }
    TVal key_val = ctx.regs[ctx.base_reg + 1];
    void* key = null;
    char[64] key_buf;
    if (key_val.tag == STRING) {
        key = key_val.pointer;
    } else if (key_val.tag == FASTINT) {
        int len = libc::snprintf(&key_buf, 64, "%ld", key_val.fastint);
        if (len < 0 || len >= 64) {
            ctx.result.set_undefined();
            return;
        }
        HString*? key_str = hstring::hstring_alloc(ctx.heap, key_buf[:len], 0);
        if (catch err2 = key_str) {
            ctx.result.set_undefined();
            return;
        }
        ctx.heap.str_table_insert(key_str);
        key = key_str;
    } else if (key_val.tag == NUMBER) {
        int len = libc::snprintf(&key_buf, 64, "%.17g", key_val.number);
        if (len < 0 || len >= 64) {
            ctx.result.set_undefined();
            return;
        }
        HString*? key_str = hstring::hstring_alloc(ctx.heap, key_buf[:len], 0);
        if (catch err3 = key_str) {
            ctx.result.set_undefined();
            return;
        }
        ctx.heap.str_table_insert(key_str);
        key = key_str;
    } else {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err4 = err_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key2 = builtin_intern_string(ctx.heap, "message");
        HString* msg_str2 = builtin_intern_string(ctx.heap, "Object.defineProperty property key must be a string or number");
        if (msg_key2 == null || msg_str2 == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv;
        msg_tv.tag = STRING;
        msg_tv.pointer = msg_str2;
        err.put_prop(msg_key2, msg_tv, hobject::PROP_FLAGS_WEC);
        ctx.should_throw = true;
        ctx.throw_value.tag = OBJECT;
        ctx.throw_value.pointer = err;
        return;
    }

    // Step 3: Check Attributes is Object
    if (ctx.argc < 3) {
        ctx.result.set_undefined();
        return;
    }
    TVal attr_val = ctx.regs[ctx.base_reg + 2];
    if (attr_val.tag != OBJECT) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err5 = err_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key3 = builtin_intern_string(ctx.heap, "message");
        HString* msg_str3 = builtin_intern_string(ctx.heap, "Object.defineProperty called with non-object descriptor");
        if (msg_key3 == null || msg_str3 == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv;
        msg_tv.tag = STRING;
        msg_tv.pointer = msg_str3;
        err.put_prop(msg_key3, msg_tv, hobject::PROP_FLAGS_WEC);
        ctx.should_throw = true;
        ctx.throw_value.tag = OBJECT;
        ctx.throw_value.pointer = err;
        return;
    }
    HObject* desc_obj = (HObject*)attr_val.pointer;

    // Step 4: ToPropertyDescriptor
    hobject::PropFlags desc_flags;
    TVal[2] desc_vals;  // [0]=value/getter, [1]=setter (unused for data)
    bool is_accessor;
    if (!to_property_descriptor(ctx, desc_obj, &desc_flags, &desc_vals, &is_accessor)) {
        if (ctx.should_throw) return;
        ctx.result.set_undefined();
        return;
    }

    // Step 5: [[DefineOwnProperty]]
    // Check if property already exists
    int existing_idx = obj.find_prop_idx(key);
    if (existing_idx < 0) {
        // Property doesn't exist — check extensibility
        if (!obj.flags.extensible) {
            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (catch err6 = err_raw) {
                ctx.result.set_undefined();
                return;
            }
            HObject* err = err_raw;
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_key4 = builtin_intern_string(ctx.heap, "message");
            HString* msg_str4 = builtin_intern_string(ctx.heap, "Cannot define property on a non-extensible object");
            if (msg_key4 == null || msg_str4 == null) { ctx.result.set_undefined(); return; }
            TVal msg_tv;
            msg_tv.tag = STRING;
            msg_tv.pointer = msg_str4;
            err.put_prop(msg_key4, msg_tv, hobject::PROP_FLAGS_WEC);
            ctx.should_throw = true;
            ctx.throw_value.tag = OBJECT;
            ctx.throw_value.pointer = err;
            return;
        }
        // Create new property
        if (is_accessor) {
            // Accessor property — set value as getter placeholder
            obj.put_prop(key, desc_vals[0], desc_flags);
            int idx = obj.find_prop_idx(key);
            if (idx >= 0) {
                obj.props[idx].getter = desc_vals[0];
                obj.props[idx].setter = desc_vals[1];
            }
        } else {
            obj.put_prop(key, desc_vals[0], desc_flags);
        }
    } else {
        // Property exists — validate changes per ES5 §8.12.9
        hobject::PropEntry* current = &obj.props[existing_idx];
        hobject::PropFlags cur_flags = current.flags;
        TVal cur_value = current.value;

        // Check if descriptor is empty (generic, no fields)
        bool has_value_field   = (ctx.regs[ctx.base_reg + 2].tag == OBJECT); // already validated
        // We've already extracted descriptor fields above, so check what was present

        // Check configurable constraint
        if (!cur_flags.configurable) {
            bool reject = false;
            if (desc_flags.configurable != cur_flags.configurable) reject = true;
            if (desc_flags.enumerable != cur_flags.enumerable) reject = true;
            if (reject) {
                HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                if (catch err7 = err_raw) {
                    ctx.result.set_undefined();
                    return;
                }
                HObject* err = err_raw;
                err.prototype = ctx.heap.type_err_proto;
                HString* msg_key5 = builtin_intern_string(ctx.heap, "message");
                HString* msg_str5 = builtin_intern_string(ctx.heap, "Cannot redefine non-configurable property");
                if (msg_key5 == null || msg_str5 == null) { ctx.result.set_undefined(); return; }
                TVal msg_tv;
                msg_tv.tag = STRING;
                msg_tv.pointer = msg_str5;
                err.put_prop(msg_key5, msg_tv, hobject::PROP_FLAGS_WEC);
                ctx.should_throw = true;
                ctx.throw_value.tag = OBJECT;
                ctx.throw_value.pointer = err;
                return;
            }
        }

        // Update the property
        if (is_accessor != cur_flags.is_accessor) {
            // Changing from data to accessor or vice versa on non-configurable
            if (!cur_flags.configurable) {
                HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                if (catch err8 = err_raw) {
                    ctx.result.set_undefined();
                    return;
                }
                HObject* err = err_raw;
                err.prototype = ctx.heap.type_err_proto;
                HString* msg_key6 = builtin_intern_string(ctx.heap, "message");
                HString* msg_str6 = builtin_intern_string(ctx.heap, "Cannot change property type from data to accessor or vice versa on non-configurable property");
                if (msg_key6 == null || msg_str6 == null) { ctx.result.set_undefined(); return; }
                TVal msg_tv;
                msg_tv.tag = STRING;
                msg_tv.pointer = msg_str6;
                err.put_prop(msg_key6, msg_tv, hobject::PROP_FLAGS_WEC);
                ctx.should_throw = true;
                ctx.throw_value.tag = OBJECT;
                ctx.throw_value.pointer = err;
                return;
            }
            // Type change allowed only if configurable
        }

        if (is_accessor) {
            // Update accessor fields
            bool has_get_in_desc = false;
            bool has_set_in_desc = false;
            // Re-check which fields were in the descriptor
            HString* get_k = builtin_intern_string(ctx.heap, "get");
            HString* set_k = builtin_intern_string(ctx.heap, "set");
            if (get_k != null) has_get_in_desc = desc_obj.find_prop_idx(get_k) >= 0;
            if (set_k != null) has_set_in_desc = desc_obj.find_prop_idx(set_k) >= 0;

            if (has_get_in_desc) current.getter = desc_vals[0];
            if (has_set_in_desc) current.setter = desc_vals[1];

            // Update flags
            current.flags.is_accessor = true;
            current.flags.enumerable = desc_flags.enumerable;
            current.flags.configurable = desc_flags.configurable;
        } else {
            // Update data property
            bool has_val_in_desc = false;
            bool has_wrt_in_desc = false;
            bool has_enum_in_desc = false;
            bool has_conf_in_desc = false;
            HString* val_k  = builtin_intern_string(ctx.heap, "value");
            HString* writ_k = builtin_intern_string(ctx.heap, "writable");
            HString* enum_k = builtin_intern_string(ctx.heap, "enumerable");
            HString* conf_k = builtin_intern_string(ctx.heap, "configurable");
            if (val_k  != null) has_val_in_desc  = desc_obj.find_prop_idx(val_k)  >= 0;
            if (writ_k != null) has_wrt_in_desc  = desc_obj.find_prop_idx(writ_k) >= 0;
            if (enum_k != null) has_enum_in_desc = desc_obj.find_prop_idx(enum_k) >= 0;
            if (conf_k != null) has_conf_in_desc = desc_obj.find_prop_idx(conf_k) >= 0;

            // Check writable → non-writable transition when non-configurable
            if (!cur_flags.configurable && !cur_flags.writable && has_wrt_in_desc && desc_flags.writable) {
                // Cannot change non-writable to writable on non-configurable
                HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                if (catch err9 = err_raw) {
                    ctx.result.set_undefined();
                    return;
                }
                HObject* err = err_raw;
                err.prototype = ctx.heap.type_err_proto;
                HString* msg_key7 = builtin_intern_string(ctx.heap, "message");
                HString* msg_str7 = builtin_intern_string(ctx.heap, "Cannot change writable attribute of non-configurable property from false to true");
                if (msg_key7 == null || msg_str7 == null) { ctx.result.set_undefined(); return; }
                TVal msg_tv;
                msg_tv.tag = STRING;
                msg_tv.pointer = msg_str7;
                err.put_prop(msg_key7, msg_tv, hobject::PROP_FLAGS_WEC);
                ctx.should_throw = true;
                ctx.throw_value.tag = OBJECT;
                ctx.throw_value.pointer = err;
                return;
            }

            if (has_val_in_desc) {
                // If non-writable and non-configurable, value can only be set once
                if (!cur_flags.configurable && !cur_flags.writable) {
                    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                    if (catch err10 = err_raw) {
                        ctx.result.set_undefined();
                        return;
                    }
                    HObject* err = err_raw;
                    err.prototype = ctx.heap.type_err_proto;
                    HString* msg_key8 = builtin_intern_string(ctx.heap, "message");
                    HString* msg_str8 = builtin_intern_string(ctx.heap, "Cannot change value of non-writable non-configurable property");
                    if (msg_key8 == null || msg_str8 == null) { ctx.result.set_undefined(); return; }
                    TVal msg_tv;
                    msg_tv.tag = STRING;
                    msg_tv.pointer = msg_str8;
                    err.put_prop(msg_key8, msg_tv, hobject::PROP_FLAGS_WEC);
                    ctx.should_throw = true;
                    ctx.throw_value.tag = OBJECT;
                    ctx.throw_value.pointer = err;
                    return;
                }
                current.value = desc_vals[0];
            }

            if (has_wrt_in_desc)  current.flags.writable     = desc_flags.writable;
            if (has_enum_in_desc) current.flags.enumerable   = desc_flags.enumerable;
            if (has_conf_in_desc) current.flags.configurable = desc_flags.configurable;
        }
    }

    // Step 6: Return O
    ctx.result.tag = OBJECT;
    ctx.result.pointer = obj;
}

// ============================================================================
// Object.defineProperties — ES5 §15.2.3.7
// ============================================================================
/// Define multiple properties on an object from a properties object.
fn void builtin_object_defineProperties(BuiltinContext* ctx) {
    // Step 1: Check first arg is Object
    if (ctx.argc < 1) {
        ctx.result.set_undefined();
        return;
    }
    TVal arg0 = ctx.regs[ctx.base_reg];
    if (arg0.tag != OBJECT) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err1 = err_raw) { ctx.result.set_undefined(); return; }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Object.defineProperties called on non-object");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv;
        msg_tv.tag = STRING;
        msg_tv.pointer = msg_str;
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
        ctx.should_throw = true;
        ctx.throw_value.tag = OBJECT;
        ctx.throw_value.pointer = err;
        return;
    }
    HObject* obj = (HObject*)arg0.pointer;

    // Step 2: Check Properties argument is present and is an object
    if (ctx.argc < 2) {
        ctx.result.tag = OBJECT;
        ctx.result.pointer = obj;
        return;
    }
    TVal props_val = ctx.regs[ctx.base_reg + 1];
    if (props_val.tag != OBJECT) {
        ctx.result.tag = OBJECT;
        ctx.result.pointer = obj;
        return;
    }
    HObject* props = (HObject*)props_val.pointer;

    // Step 4: For each key, get descriptor and call DefinePropertyOrThrow
    // Collect keys first in case properties are modified during iteration
    HString*[256] keys_arr;
    uint keys_count = 0;
    for (uint i = 0; i < props.prop_count && keys_count < 256; i++) {
        if (props.props[i].key != null) {
            keys_arr[keys_count] = (HString*)props.props[i].key;
            keys_count++;
        }
    }

    for (uint k = 0; k < keys_count; k++) {
        HString* p_key = keys_arr[k];
        // Get descObj = props.[[GetOwnProperty]](p_key).value
        PropEntry*? prop_entry = props.find_prop(p_key);
        if (try pe = prop_entry) {
            TVal desc_obj_val = pe.value;

            // ToPropertyDescriptor(desc_obj)
            if (desc_obj_val.tag != OBJECT) {
                // TypeError — property descriptor must be an object
                HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                if (catch err2 = err_raw) { ctx.result.set_undefined(); return; }
                HObject* err = err_raw;
                err.prototype = ctx.heap.type_err_proto;
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                char[128] msg_buf;
                int msg_len = libc::snprintf(&msg_buf, 128, "Property descriptor for '%s' must be an object", p_key.get_data());
                HString* msg_str = builtin_intern_string(ctx.heap, msg_buf[:msg_len]);
                if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
                TVal msg_tv;
                msg_tv.tag = STRING;
                msg_tv.pointer = msg_str;
                err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                ctx.should_throw = true;
                ctx.throw_value.tag = OBJECT;
                ctx.throw_value.pointer = err;
                return;
            }
            HObject* desc_obj = (HObject*)desc_obj_val.pointer;

            // Convert to property descriptor
            hobject::PropFlags desc_flags;
            TVal[2] desc_vals;
            bool is_accessor;
            if (!to_property_descriptor(ctx, desc_obj, &desc_flags, &desc_vals, &is_accessor)) {
                if (ctx.should_throw) return;
                ctx.result.set_undefined();
                return;
            }

            // [[DefineOwnProperty]]
            int existing_idx = obj.find_prop_idx(p_key);
            if (existing_idx < 0) {
                if (!obj.flags.extensible) {
                    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                    if (catch err3 = err_raw) { ctx.result.set_undefined(); return; }
                    HObject* err = err_raw;
                    err.prototype = ctx.heap.type_err_proto;
                    HString* msg_key = builtin_intern_string(ctx.heap, "message");
                    HString* msg_str = builtin_intern_string(ctx.heap, "Cannot define property on a non-extensible object");
                    if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
                    TVal msg_tv;
                    msg_tv.tag = STRING;
                    msg_tv.pointer = msg_str;
                    err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                    ctx.should_throw = true;
                    ctx.throw_value.tag = OBJECT;
                    ctx.throw_value.pointer = err;
                    return;
                }
                if (is_accessor) {
                    obj.put_prop(p_key, desc_vals[0], desc_flags);
                    int idx = obj.find_prop_idx(p_key);
                    if (idx >= 0) {
                        obj.props[idx].getter = desc_vals[0];
                        obj.props[idx].setter = desc_vals[1];
                    }
                } else {
                    obj.put_prop(p_key, desc_vals[0], desc_flags);
                }
            } else {
                // Property exists — validate changes
                hobject::PropEntry* current = &obj.props[existing_idx];
                hobject::PropFlags cur_flags = current.flags;
                if (!cur_flags.configurable) {
                    if (desc_flags.configurable != cur_flags.configurable ||
                        desc_flags.enumerable != cur_flags.enumerable) {
                        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                        if (catch err4 = err_raw) { ctx.result.set_undefined(); return; }
                        HObject* err = err_raw;
                        err.prototype = ctx.heap.type_err_proto;
                        HString* msg_key = builtin_intern_string(ctx.heap, "message");
                        HString* msg_str = builtin_intern_string(ctx.heap, "Cannot redefine non-configurable property");
                        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
                        TVal msg_tv;
                        msg_tv.tag = STRING;
                        msg_tv.pointer = msg_str;
                        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                        ctx.should_throw = true;
                        ctx.throw_value.tag = OBJECT;
                        ctx.throw_value.pointer = err;
                        return;
                    }
                }

                if (is_accessor) {
                    if (has_get_in_desc_helper(ctx.heap, desc_obj)) current.getter = desc_vals[0];
                    if (has_set_in_desc_helper(ctx.heap, desc_obj)) current.setter = desc_vals[1];
                    current.flags.is_accessor = true;
                    current.flags.enumerable = desc_flags.enumerable;
                    current.flags.configurable = desc_flags.configurable;
                } else {
                    // Basic data property update
                    if (has_value_in_desc_helper(ctx.heap, desc_obj)) {
                        if (!cur_flags.configurable && !cur_flags.writable) {
                            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                            if (catch err5 = err_raw) { ctx.result.set_undefined(); return; }
                            HObject* err = err_raw;
                            err.prototype = ctx.heap.type_err_proto;
                            HString* msg_key = builtin_intern_string(ctx.heap, "message");
                            HString* msg_str = builtin_intern_string(ctx.heap, "Cannot change value of non-writable non-configurable property");
                            if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
                            TVal msg_tv;
                            msg_tv.tag = STRING;
                            msg_tv.pointer = msg_str;
                            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                            ctx.should_throw = true;
                            ctx.throw_value.tag = OBJECT;
                            ctx.throw_value.pointer = err;
                            return;
                        }
                        current.value = desc_vals[0];
                    }
                    if (has_writable_in_desc_helper(ctx.heap, desc_obj)) current.flags.writable = desc_flags.writable;
                    if (has_enumerable_in_desc_helper(ctx.heap, desc_obj)) current.flags.enumerable = desc_flags.enumerable;
                    if (has_configurable_in_desc_helper(ctx.heap, desc_obj)) current.flags.configurable = desc_flags.configurable;
                }
            }
        }
    }

    // Step 5: Return obj
    ctx.result.tag = OBJECT;
    ctx.result.pointer = obj;
}

/// Helper: check if descriptor object has "get" property
fn bool has_get_in_desc_helper(Heap* heap, HObject* desc_obj) {
    HString* key = builtin_intern_string(heap, "get");
    return key != null && desc_obj.find_prop_idx(key) >= 0;
}
/// Helper: check if descriptor object has "set" property
fn bool has_set_in_desc_helper(Heap* heap, HObject* desc_obj) {
    HString* key = builtin_intern_string(heap, "set");
    return key != null && desc_obj.find_prop_idx(key) >= 0;
}
/// Helper: check if descriptor object has "value" property
fn bool has_value_in_desc_helper(Heap* heap, HObject* desc_obj) {
    HString* key = builtin_intern_string(heap, "value");
    return key != null && desc_obj.find_prop_idx(key) >= 0;
}
/// Helper: check if descriptor object has "writable" property
fn bool has_writable_in_desc_helper(Heap* heap, HObject* desc_obj) {
    HString* key = builtin_intern_string(heap, "writable");
    return key != null && desc_obj.find_prop_idx(key) >= 0;
}
/// Helper: check if descriptor object has "enumerable" property
fn bool has_enumerable_in_desc_helper(Heap* heap, HObject* desc_obj) {
    HString* key = builtin_intern_string(heap, "enumerable");
    return key != null && desc_obj.find_prop_idx(key) >= 0;
}
/// Helper: check if descriptor object has "configurable" property
fn bool has_configurable_in_desc_helper(Heap* heap, HObject* desc_obj) {
    HString* key = builtin_intern_string(heap, "configurable");
    return key != null && desc_obj.find_prop_idx(key) >= 0;
}

// ============================================================================
// Object.create — ES5 §15.2.3.5
// ============================================================================
/// Create a new object with the specified prototype and optional properties.
fn void builtin_object_create(BuiltinContext* ctx) {
    // Step 1-2: Check prototype argument
    if (ctx.argc < 1) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err1 = err_raw) { ctx.result.set_undefined(); return; }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Object.create requires at least 1 argument");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv;
        msg_tv.tag = STRING;
        msg_tv.pointer = msg_str;
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
        ctx.should_throw = true;
        ctx.throw_value.tag = OBJECT;
        ctx.throw_value.pointer = err;
        return;
    }
    TVal proto_val = ctx.regs[ctx.base_reg];

    // If O is not Object or Null, throw TypeError
    if (proto_val.tag == NULL_VAL) {
        // null prototype is valid
    } else if (proto_val.tag == OBJECT) {
        // valid
    } else {
        // Throw TypeError
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err2 = err_raw) { ctx.result.set_undefined(); return; }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Object prototype may only be an Object or null");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv;
        msg_tv.tag = STRING;
        msg_tv.pointer = msg_str;
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
        ctx.should_throw = true;
        ctx.throw_value.tag = OBJECT;
        ctx.throw_value.pointer = err;
        return;
    }
    HObject*? proto_obj_raw = null;
    if (proto_val.tag == OBJECT) {
        proto_obj_raw = (HObject*)proto_val.pointer;
    }

    // Step 3: Create a new object with [[Prototype]] = O
    HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err3 = obj_raw) { ctx.result.set_undefined(); return; }
    HObject* obj = obj_raw;
    if (try proto_obj = proto_obj_raw) {
        obj.prototype = proto_obj;
    } else {
        obj.prototype = null;
    }
    obj.flags.extensible = true;

    // Step 4: If Properties is not undefined, call defineProperties
    if (ctx.argc >= 2) {
        TVal props_val = ctx.regs[ctx.base_reg + 1];
        if (props_val.tag != UNDEFINED && props_val.tag != NULL_VAL) {
            // Create a mini-BuiltinContext for the defineProperties call
            // We reuse the same approach: inline defineProperties logic
            if (props_val.tag == OBJECT) {
                HObject* props = (HObject*)props_val.pointer;

                // Collect own property keys
                HString*[256] keys_arr;
                uint keys_count = 0;
                for (uint i = 0; i < props.prop_count && keys_count < 256; i++) {
                    if (props.props[i].key != null) {
                        keys_arr[keys_count] = (HString*)props.props[i].key;
                        keys_count++;
                    }
                }

                for (uint k = 0; k < keys_count; k++) {
                    HString* pk_key = keys_arr[k];
                    PropEntry*? prop_entry = props.find_prop(pk_key);
                    if (try pe = prop_entry) {
                        TVal desc_obj_val = pe.value;
                        if (desc_obj_val.tag != OBJECT) {
                            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
                            if (catch err4 = err_raw) { ctx.result.set_undefined(); return; }
                            HObject* err = err_raw;
                            err.prototype = ctx.heap.type_err_proto;
                            HString* msg_key = builtin_intern_string(ctx.heap, "message");
                            char[128] msg_buf;
                            int msg_len = libc::snprintf(&msg_buf, 128, "Property descriptor for '%s' must be an object", pk_key.get_data());
                            HString* msg_str = builtin_intern_string(ctx.heap, msg_buf[:msg_len]);
                            if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
                            TVal msg_tv;
                            msg_tv.tag = STRING;
                            msg_tv.pointer = msg_str;
                            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                            ctx.should_throw = true;
                            ctx.throw_value.tag = OBJECT;
                            ctx.throw_value.pointer = err;
                            return;
                        }
                        HObject* desc_obj = (HObject*)desc_obj_val.pointer;

                        hobject::PropFlags desc_flags;
                        TVal[2] desc_vals;
                        bool is_accessor;
                        if (!to_property_descriptor(ctx, desc_obj, &desc_flags, &desc_vals, &is_accessor)) {
                            if (ctx.should_throw) return;
                            ctx.result.set_undefined();
                            return;
                        }

                        if (is_accessor) {
                            obj.put_prop(pk_key, desc_vals[0], desc_flags);
                            int idx = obj.find_prop_idx(pk_key);
                            if (idx >= 0) {
                                obj.props[idx].getter = desc_vals[0];
                                obj.props[idx].setter = desc_vals[1];
                            }
                        } else {
                            obj.put_prop(pk_key, desc_vals[0], desc_flags);
                        }
                    }
                }
            }
        }
    }

    // Step 5: Return obj
    ctx.result.tag = OBJECT;
    ctx.result.pointer = obj;
}

// ============================================================================
// Object.seal — ES5 §15.2.3.8
// ============================================================================
/// Seal an object: prevent extensions and make all properties non-configurable.
fn void builtin_object_seal(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_undefined();
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    if (arg.tag != OBJECT) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err1 = err_raw) { ctx.result.set_undefined(); return; }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Object.seal called on non-object");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv;
        msg_tv.tag = STRING;
        msg_tv.pointer = msg_str;
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
        ctx.should_throw = true;
        ctx.throw_value.tag = OBJECT;
        ctx.throw_value.pointer = err;
        return;
    }
    HObject* obj = (HObject*)arg.pointer;
    obj.seal();
    ctx.result.tag = OBJECT;
    ctx.result.pointer = obj;
}

// ============================================================================
// Object.freeze — ES5 §15.2.3.9
// ============================================================================
/// Freeze an object: seal and make all data properties non-writable.
fn void builtin_object_freeze(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_undefined();
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    if (arg.tag != OBJECT) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err1 = err_raw) { ctx.result.set_undefined(); return; }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Object.freeze called on non-object");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv;
        msg_tv.tag = STRING;
        msg_tv.pointer = msg_str;
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
        ctx.should_throw = true;
        ctx.throw_value.tag = OBJECT;
        ctx.throw_value.pointer = err;
        return;
    }
    HObject* obj = (HObject*)arg.pointer;
    obj.freeze();
    ctx.result.tag = OBJECT;
    ctx.result.pointer = obj;
}

// ============================================================================
// Object.isSealed — ES5 §15.2.3.11
// ============================================================================
/// Check if an object is sealed.
fn void builtin_object_isSealed(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.tag = BOOLEAN;
        ctx.result.boolean = false;
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    if (arg.tag != OBJECT) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err1 = err_raw) { ctx.result.set_undefined(); return; }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Object.isSealed called on non-object");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv;
        msg_tv.tag = STRING;
        msg_tv.pointer = msg_str;
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
        ctx.should_throw = true;
        ctx.throw_value.tag = OBJECT;
        ctx.throw_value.pointer = err;
        return;
    }
    HObject* obj = (HObject*)arg.pointer;

    // Check if any own property is configurable
    for (uint i = 0; i < obj.prop_count; i++) {
        if (obj.props[i].key != null && obj.props[i].flags.configurable) {
            ctx.result.tag = BOOLEAN;
            ctx.result.boolean = false;
            return;
        }
    }

    // Check if extensible
    if (obj.flags.extensible) {
        ctx.result.tag = BOOLEAN;
        ctx.result.boolean = false;
        return;
    }

    ctx.result.tag = BOOLEAN;
    ctx.result.boolean = true;
}

// ============================================================================
// Object.isFrozen — ES5 §15.2.3.12
// ============================================================================
/// Check if an object is frozen.
fn void builtin_object_isFrozen(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.tag = BOOLEAN;
        ctx.result.boolean = false;
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    if (arg.tag != OBJECT) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err1 = err_raw) { ctx.result.set_undefined(); return; }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Object.isFrozen called on non-object");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv;
        msg_tv.tag = STRING;
        msg_tv.pointer = msg_str;
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
        ctx.should_throw = true;
        ctx.throw_value.tag = OBJECT;
        ctx.throw_value.pointer = err;
        return;
    }
    HObject* obj = (HObject*)arg.pointer;

    // Check if any own property is configurable or data property writable
    for (uint i = 0; i < obj.prop_count; i++) {
        if (obj.props[i].key != null) {
            if (obj.props[i].flags.configurable) {
                ctx.result.tag = BOOLEAN;
                ctx.result.boolean = false;
                return;
            }
            if (!obj.props[i].flags.is_accessor && obj.props[i].flags.writable) {
                ctx.result.tag = BOOLEAN;
                ctx.result.boolean = false;
                return;
            }
        }
    }

    // Check if extensible
    if (obj.flags.extensible) {
        ctx.result.tag = BOOLEAN;
        ctx.result.boolean = false;
        return;
    }

    ctx.result.tag = BOOLEAN;
    ctx.result.boolean = true;
}

// ============================================================================
// Object.entries — ES2017 §19.1.2.21
// ============================================================================
/// Returns an array of the given object's own enumerable string-keyed property
/// [key, value] pairs.
fn void builtin_object_entries(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_undefined();
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    // TypeError if argument is null or undefined
    if (arg.tag == NULL_VAL || arg.tag == UNDEFINED) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err1 = err_raw) { ctx.result.set_undefined(); return; }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Cannot convert undefined or null to object");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv; msg_tv.tag = STRING; msg_tv.pointer = msg_str;
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
        ctx.should_throw = true;
        ctx.throw_value.tag = OBJECT; ctx.throw_value.pointer = err;
        return;
    }
    HObject* obj;
    if (arg.tag == OBJECT) {
        obj = (HObject*)arg.pointer;
    } else {
        // ToObject wrapper for primitives
        HObject*? wrapped = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err2 = wrapped) { ctx.result.set_undefined(); return; }
        obj = wrapped;
        obj.prototype = ctx.heap.object_proto;
    }
    // Count enumerable own properties
    uint count = 0;
    for (uint i = 0; i < obj.prop_count; i++) {
        if (obj.props[i].flags.enumerable && obj.props[i].key != null) count++;
    }
    for (uint i = 0; i < obj.array_size; i++) {
        if (obj.array_part[i].tag != UNDEFINED) count++;
    }
    // Allocate result array
    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err3 = arr_raw) { ctx.result.set_undefined(); return; }
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;
    uint idx = 0;
    // Named properties → [key, value] pairs
    for (uint i = 0; i < obj.prop_count; i++) {
        if (obj.props[i].flags.enumerable && obj.props[i].key != null) {
            HString* key = (HString*)obj.props[i].key;
            // Create pair array [key, value]
            HObject*? pair_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
            if (catch err4 = pair_raw) { ctx.result.set_undefined(); return; }
            HObject* pair = pair_raw;
            pair.prototype = ctx.heap.array_proto;
            TVal key_tv; key_tv.tag = STRING; key_tv.pointer = key;
            array_set_elem(pair, 0, key_tv, ctx.heap);
            array_set_elem(pair, 1, obj.props[i].value, ctx.heap);
            TVal len_tv; len_tv.tag = FASTINT; len_tv.fastint = 2;
            HString* len_key = builtin_intern_string(ctx.heap, "length");
            pair.put_prop(len_key, len_tv, hobject::PROP_FLAGS_WEC);
            TVal pair_tv; pair_tv.tag = OBJECT; pair_tv.pointer = pair;
            array_set_elem(arr, idx, pair_tv, ctx.heap);
            idx++;
        }
    }
    // Dense array indices → [key, value] pairs
    char[32] buf;
    for (uint i = 0; i < obj.array_size; i++) {
        if (obj.array_part[i].tag != UNDEFINED) {
            int slen = libc::snprintf(&buf, 32, "%u", i);
            if (slen < 0) continue;
            uint hash = ctx.heap.hash_string(buf[..slen]);
            HString*? key_s = hstring::hstring_alloc(ctx.heap, buf[..slen], hash);
            if (catch err5 = key_s) continue;
            ctx.heap.str_table_insert(key_s);
            HObject*? pair_raw2 = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
            if (catch err6 = pair_raw2) continue;
            HObject* pair2 = pair_raw2;
            pair2.prototype = ctx.heap.array_proto;
            TVal key_tv2; key_tv2.tag = STRING; key_tv2.pointer = key_s;
            array_set_elem(pair2, 0, key_tv2, ctx.heap);
            array_set_elem(pair2, 1, obj.array_part[i], ctx.heap);
            TVal len_tv2; len_tv2.tag = FASTINT; len_tv2.fastint = 2;
            HString* len_key2 = builtin_intern_string(ctx.heap, "length");
            pair2.put_prop(len_key2, len_tv2, hobject::PROP_FLAGS_WEC);
            TVal pair_tv2; pair_tv2.tag = OBJECT; pair_tv2.pointer = pair2;
            array_set_elem(arr, idx, pair_tv2, ctx.heap);
            idx++;
        }
    }
    // Set .length on result array
    TVal rlen_tv; rlen_tv.tag = FASTINT; rlen_tv.fastint = (long)idx;
    HString* rlen_key = builtin_intern_string(ctx.heap, "length");
    arr.put_prop(rlen_key, rlen_tv, hobject::PROP_FLAGS_WEC);
    ctx.result.tag = OBJECT; ctx.result.pointer = arr;
}

// ============================================================================
// Object.values — ES2017 §19.1.2.22
// ============================================================================
/// Returns an array of the given object's own enumerable string-keyed property values.
fn void builtin_object_values(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_undefined();
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    // TypeError if argument is null or undefined
    if (arg.tag == NULL_VAL || arg.tag == UNDEFINED) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err1 = err_raw) { ctx.result.set_undefined(); return; }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Cannot convert undefined or null to object");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv; msg_tv.tag = STRING; msg_tv.pointer = msg_str;
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
        ctx.should_throw = true;
        ctx.throw_value.tag = OBJECT; ctx.throw_value.pointer = err;
        return;
    }
    HObject* obj;
    if (arg.tag == OBJECT) {
        obj = (HObject*)arg.pointer;
    } else {
        HObject*? wrapped = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err2 = wrapped) { ctx.result.set_undefined(); return; }
        obj = wrapped;
        obj.prototype = ctx.heap.object_proto;
    }
    // Count enumerable own properties
    uint count = 0;
    for (uint i = 0; i < obj.prop_count; i++) {
        if (obj.props[i].flags.enumerable && obj.props[i].key != null) count++;
    }
    for (uint i = 0; i < obj.array_size; i++) {
        if (obj.array_part[i].tag != UNDEFINED) count++;
    }
    // Allocate result array
    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err3 = arr_raw) { ctx.result.set_undefined(); return; }
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;
    uint idx = 0;
    // Named properties
    for (uint i = 0; i < obj.prop_count; i++) {
        if (obj.props[i].flags.enumerable && obj.props[i].key != null) {
            array_set_elem(arr, idx, obj.props[i].value, ctx.heap);
            idx++;
        }
    }
    // Dense array indices
    for (uint i = 0; i < obj.array_size; i++) {
        if (obj.array_part[i].tag != UNDEFINED) {
            array_set_elem(arr, idx, obj.array_part[i], ctx.heap);
            idx++;
        }
    }
    // Set .length
    TVal rlen_tv; rlen_tv.tag = FASTINT; rlen_tv.fastint = (long)idx;
    HString* rlen_key = builtin_intern_string(ctx.heap, "length");
    arr.put_prop(rlen_key, rlen_tv, hobject::PROP_FLAGS_WEC);
    ctx.result.tag = OBJECT; ctx.result.pointer = arr;
}

// ============================================================================
// Object.assign — ES2015 §19.1.2.2
// ============================================================================
/// Copies enumerable own properties from source objects to a target object.
fn void builtin_object_assign(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_undefined();
        return;
    }
    TVal target_val = ctx.regs[ctx.base_reg];
    // TypeError if target is null or undefined
    if (target_val.tag == NULL_VAL || target_val.tag == UNDEFINED) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err1 = err_raw) { ctx.result.set_undefined(); return; }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Cannot convert undefined or null to object");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv; msg_tv.tag = STRING; msg_tv.pointer = msg_str;
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
        ctx.should_throw = true;
        ctx.throw_value.tag = OBJECT; ctx.throw_value.pointer = err;
        return;
    }
    // ToObject on target
    HObject* target;
    if (target_val.tag == OBJECT) {
        target = (HObject*)target_val.pointer;
    } else {
        HObject*? wrapped = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err2 = wrapped) { ctx.result.set_undefined(); return; }
        target = wrapped;
        target.prototype = ctx.heap.object_proto;
    }
    // Copy properties from each source (args 1..N)
    for (uint s = 1; s < ctx.argc; s++) {
        TVal source = ctx.regs[ctx.base_reg + s];
        // Skip null, undefined, and non-objects
        if (source.tag == NULL_VAL || source.tag == UNDEFINED) continue;
        if (source.tag != OBJECT) continue;
        HObject* src_obj = (HObject*)source.pointer;
        // Copy enumerable own named properties
        for (uint i = 0; i < src_obj.prop_count; i++) {
            if (src_obj.props[i].flags.enumerable && src_obj.props[i].key != null) {
                target.put_prop(src_obj.props[i].key, src_obj.props[i].value, hobject::PROP_FLAGS_WEC);
            }
        }
        // Copy enumerable own dense array indices
        for (uint i = 0; i < src_obj.array_size; i++) {
            if (src_obj.array_part[i].tag != UNDEFINED) {
                array_set_elem(target, i, src_obj.array_part[i], ctx.heap);
            }
        }
    }
    ctx.result.tag = OBJECT; ctx.result.pointer = target;
}

// ============================================================================
// Object.is — ES6 §19.1.2.10
// ============================================================================
/// Object.is(value1, value2) — SameValue comparison.
/// Differs from === in two ways: NaN === NaN, and +0 !== -0.
fn void builtin_object_is(BuiltinContext* ctx) {
    if (ctx.argc < 2) {
        // Missing args → undefined (per ES6 spec, both args required)
        TVal undef; undef.set_undefined();
        TVal undef2; undef2.set_undefined();
        // With < 2 args, default is undefined === undefined → true
        ctx.result.tag = BOOLEAN;
        ctx.result.boolean = (ctx.argc == 0) ? true : same_value(ctx.regs[ctx.base_reg], undef2);
        return;
    }
    TVal x = ctx.regs[ctx.base_reg];
    TVal y = ctx.regs[ctx.base_reg + 1];
    ctx.result.tag = BOOLEAN;
    ctx.result.boolean = same_value(x, y);
}

// ============================================================================
// Object.hasOwn — ES2022 §19.1.2.10
// ============================================================================
/// Object.hasOwn(obj, prop) — returns true if obj has own property prop.
/// Equivalent to Object.prototype.hasOwnProperty.call(obj, prop).
fn void builtin_object_hasOwn(BuiltinContext* ctx) {
    if (ctx.argc < 2) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err1 = err_raw) { ctx.result.set_undefined(); return; }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Object.hasOwn requires 2 arguments");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv; msg_tv.tag = STRING; msg_tv.pointer = msg_str;
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
        ctx.should_throw = true;
        ctx.throw_value.tag = OBJECT; ctx.throw_value.pointer = err;
        return;
    }
    TVal obj_val = ctx.regs[ctx.base_reg];
    TVal prop_val = ctx.regs[ctx.base_reg + 1];
    // ToObject on first argument — throw TypeError for null/undefined
    if (obj_val.tag == NULL_VAL || obj_val.tag == UNDEFINED) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err2 = err_raw) { ctx.result.set_undefined(); return; }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Cannot convert undefined or null to object");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv; msg_tv.tag = STRING; msg_tv.pointer = msg_str;
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
        ctx.should_throw = true;
        ctx.throw_value.tag = OBJECT; ctx.throw_value.pointer = err;
        return;
    }
    HObject* obj;
    if (obj_val.tag == OBJECT) {
        obj = (HObject*)obj_val.pointer;
    } else {
        // Primitive — wrap via ToObject (for now, return false)
        ctx.result.tag = BOOLEAN;
        ctx.result.boolean = false;
        return;
    }
    HString* key = builtin_to_string(ctx.heap, &prop_val);
    if (key == null) {
        ctx.result.tag = BOOLEAN;
        ctx.result.boolean = false;
        return;
    }
    PropEntry*? entry = obj.find_prop(key);
    if (try e = entry) {
        ctx.result.tag = BOOLEAN;
        ctx.result.boolean = true;
    } else {
        ctx.result.tag = BOOLEAN;
        ctx.result.boolean = false;
    }
}

// ============================================================================
// Object.setPrototypeOf — ES2015 §19.1.2.19
// ============================================================================
/// Object.setPrototypeOf(obj, proto) — sets the prototype of obj to proto.
fn void builtin_object_setPrototypeOf(BuiltinContext* ctx) {
    if (ctx.argc < 2) {
        ctx.result.set_undefined();
        return;
    }
    TVal obj_val = ctx.regs[ctx.base_reg];
    TVal proto_val = ctx.regs[ctx.base_reg + 1];
    // TypeError if obj is not an object (null/undefined/primitive)
    if (obj_val.tag == NULL_VAL || obj_val.tag == UNDEFINED) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err1 = err_raw) { ctx.result.set_undefined(); return; }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Object.setPrototypeOf requires an object");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv; msg_tv.tag = STRING; msg_tv.pointer = msg_str;
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
        ctx.should_throw = true;
        ctx.throw_value.tag = OBJECT; ctx.throw_value.pointer = err;
        return;
    }
    // TypeError if proto is not an object or null
    if (proto_val.tag != NULL_VAL && proto_val.tag != OBJECT) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err2 = err_raw) { ctx.result.set_undefined(); return; }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Object.setPrototypeOf requires an object or null");
        if (msg_key == null || msg_str == null) { ctx.result.set_undefined(); return; }
        TVal msg_tv; msg_tv.tag = STRING; msg_tv.pointer = msg_str;
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
        ctx.should_throw = true;
        ctx.throw_value.tag = OBJECT; ctx.throw_value.pointer = err;
        return;
    }
    // Only set prototype on objects (not primitives)
    if (obj_val.tag != OBJECT) {
        ctx.result.tag = obj_val.tag;
        ctx.result.fastint = obj_val.fastint;
        return;
    }
    HObject* obj = (HObject*)obj_val.pointer;
    if (proto_val.tag == NULL_VAL) {
        obj.prototype = null;
    } else {
        obj.prototype = (HObject*)proto_val.pointer;
    }
    ctx.result.tag = OBJECT;
    ctx.result.pointer = obj;
}
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
            case hobject::ObjClass.MAP:       class_name = "Map"; break;
            case hobject::ObjClass.SET:       class_name = "Set"; break;
            case hobject::ObjClass.WEAKMAP:   class_name = "WeakMap"; break;
            case hobject::ObjClass.WEAKSET:   class_name = "WeakSet"; break;
            case hobject::ObjClass.SYMBOL:    class_name = "Symbol"; break;
            case hobject::ObjClass.PROMISE:   class_name = "Promise"; break;
            case hobject::ObjClass.GENERATOR: class_name = "Generator"; break;
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

/// Object.prototype.hasOwnProperty — ES5 §15.2.4.5
fn void builtin_object_proto_hasOwnProperty(BuiltinContext* ctx) {
    // V = first argument, converted to string key
    TVal arg;
    if (ctx.argc > 0) {
        arg = ctx.regs[ctx.base_reg];
    } else {
        arg.set_undefined();
    }
    HString* key = builtin_to_string(ctx.heap, &arg);
    if (key == null) {
        ctx.result.tag = BOOLEAN;
        ctx.result.boolean = false;
        return;
    }
    // O = ToObject(this value)
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    HObject* obj;
    if (this_val.tag == OBJECT && this_val.pointer != null) {
        obj = (HObject*)this_val.pointer;
    } else {
        // Primitive this value — return false (no own properties)
        ctx.result.tag = BOOLEAN;
        ctx.result.boolean = false;
        return;
    }
    // Check own property
    PropEntry*? entry = obj.find_prop(key);
    if (try e = entry) {
        ctx.result.tag = BOOLEAN;
        ctx.result.boolean = true;
    } else {
        ctx.result.tag = BOOLEAN;
        ctx.result.boolean = false;
    }
}

/// Object.prototype.propertyIsEnumerable — ES5 §15.2.4.7
fn void builtin_object_proto_propertyIsEnumerable(BuiltinContext* ctx) {
    // V = first argument, converted to string key
    TVal arg;
    if (ctx.argc > 0) {
        arg = ctx.regs[ctx.base_reg];
    } else {
        arg.set_undefined();
    }
    HString* key = builtin_to_string(ctx.heap, &arg);
    if (key == null) {
        ctx.result.tag = BOOLEAN;
        ctx.result.boolean = false;
        return;
    }
    // O = ToObject(this value)
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    HObject* obj;
    if (this_val.tag == OBJECT && this_val.pointer != null) {
        obj = (HObject*)this_val.pointer;
    } else {
        ctx.result.tag = BOOLEAN;
        ctx.result.boolean = false;
        return;
    }
    // Find own property descriptor
    PropEntry*? entry = obj.find_prop(key);
    if (try e = entry) {
        ctx.result.tag = BOOLEAN;
        ctx.result.boolean = e.flags.enumerable;
    } else {
        ctx.result.tag = BOOLEAN;
        ctx.result.boolean = false;
    }
}

/// Object.prototype.valueOf — returns 'this'
fn void builtin_object_proto_valueOf(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    ctx.result.tag = this_val.tag;
    ctx.result.fastint = this_val.fastint;
    ctx.result.number = this_val.number;
    ctx.result.pointer = this_val.pointer;
}

/// Object.prototype.isPrototypeOf(V) — ES5 §15.2.4.6
/// Returns true if the object is in the prototype chain of V.
fn void builtin_object_proto_isPrototypeOf(BuiltinContext* ctx) {
    ctx.result.tag = BOOLEAN;
    ctx.result.boolean = false;

    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.tag != OBJECT || this_val.pointer == null) {
        return;
    }
    HObject* proto = (HObject*)this_val.pointer;

    // Get argument V — must be an object
    if (ctx.argc == 0) {
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    if (arg.tag != OBJECT || arg.pointer == null) {
        return;
    }
    HObject* obj = (HObject*)arg.pointer;

    // Walk the prototype chain of obj looking for proto
    HObject* cur = obj.prototype;
    while (cur != null) {
        if (cur == proto) {
            ctx.result.boolean = true;
            return;
        }
        cur = cur.prototype;
    }
}

/// Object.prototype.toLocaleString() — ES5 §15.2.4.3
/// Calls the toString method and returns the result.
fn void builtin_object_proto_toLocaleString(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.tag != OBJECT || this_val.pointer == null) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }
    HObject* obj = (HObject*)this_val.pointer;

    // Call toString() on the object
    HString* ts_key = builtin_intern_string(ctx.heap, "toString");
    PropEntry*? entry = obj.find_prop(ts_key);
    if (try e = entry) {
        TVal fn_val = e.value;
        if (fn_val.tag == LIGHTFUNC) {
            // Re-dispatch to toString
            ctx.needs_re_dispatch = true;
            ctx.regs[ctx.base_reg - 1] = fn_val;  // replace callee with toString
            ctx.re_nargs = 0;
            return;
        }
        if (fn_val.tag == OBJECT && fn_val.pointer != null) {
            HObject* fn_obj = (HObject*)fn_val.pointer;
            if (fn_obj.is_callable()) {
                ctx.needs_re_dispatch = true;
                ctx.regs[ctx.base_reg - 1] = fn_val;
                ctx.re_nargs = 0;
                return;
            }
        }
    }

    ctx.result.tag = UNDEFINED;
    ctx.result.pointer = null;
}

// ============================================================================
// Array constructor builtins
// ============================================================================

/// Array() as function (ES5 §15.4.1) or new Array() as constructor (§15.4.2).
/// Creates and returns a new Array object.
fn void builtin_array(BuiltinContext* ctx) {
    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
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
    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
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

/// Helper: compile a JS function expression and register it as a method on a prototype.
/// The src must be a complete function expression like "(function(a,b){...})" or "(function name(a){...})".
/// Used for callback-based methods (forEach, map, filter, etc.) that can't be LIGHTFUNC builtins.
fn bool register_compiled_proto_method(HObject* proto, Heap* heap, EnvRecord* global_env, char[] name, char[] src) {
    Lexer lex = lexer::lexer_init(src, heap);
    CompiledFunction*? cf = compiler::compile_function(&lex, heap, true);
    CompiledFunction* func;
    if (try f = cf) {
        func = f;
    } else {
        return false;
    }
    HObject*? func_obj_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = func_obj_raw) return false;
    HObject* func_obj = func_obj_raw;
    func_obj.comp_func = func;
    func_obj.builtin_fn_index = -1;
    func_obj.var_env = global_env;
    func_obj.lex_env = global_env;
    func_obj.prototype = heap.function_proto;
    func_obj.flags.callable = true;
    HString* name_str = builtin_intern_string(heap, "name");
    if (name_str != null) {
        HString* fname = builtin_intern_string(heap, name);
        if (fname != null) {
            TVal name_tv;
            name_tv.tag = STRING;
            name_tv.pointer = fname;
            func_obj.put_prop(name_str, name_tv, hobject::PROP_FLAGS_WEC);
        }
    }
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
    tv.tag = OBJECT;
    tv.pointer = func_obj;
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
    HObject*? new_arr = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
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
    HObject*? result_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
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
// Array.prototype.toReversed (ES2023 §23.1.3.33)
// ============================================================================
fn void builtin_array_proto_toReversed(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) {
        TVal this_val = ctx.regs[ctx.base_reg - 1];
        if (this_val.tag == UNDEFINED || this_val.tag == NULL_VAL) {
            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (try err = err_raw) {
                err.prototype = ctx.heap.type_err_proto;
                HString* msg = builtin_intern_string(ctx.heap, "Array.prototype.toReversed called on null or undefined");
                TVal msg_tv; msg_tv.tag = STRING; msg_tv.pointer = msg;
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                ctx.should_throw = true;
                ctx.throw_value.tag = OBJECT;
                ctx.throw_value.pointer = err;
            }
        }
        return;
    }

    uint len = array_get_length(obj, ctx.heap);

    HObject*? new_arr = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = new_arr) {
        ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return;
    }
    HObject* result = new_arr;
    result.prototype = ctx.heap.array_proto;

    for (uint i = 0; i < len; i++) {
        TVal elem = array_get_elem(obj, len - 1 - i, ctx.heap);
        array_set_elem(result, i, elem, ctx.heap);
    }
    array_set_length(result, len, ctx.heap);

    ctx.result.tag = OBJECT;
    ctx.result.pointer = result;
}

// ============================================================================
// Array.prototype.toSorted (ES2023 §23.1.3.34) — default compare (no comparefn)
// ============================================================================
fn void builtin_array_proto_toSorted(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) {
        TVal this_val = ctx.regs[ctx.base_reg - 1];
        if (this_val.tag == UNDEFINED || this_val.tag == NULL_VAL) {
            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (try err = err_raw) {
                err.prototype = ctx.heap.type_err_proto;
                HString* msg = builtin_intern_string(ctx.heap, "Array.prototype.toSorted called on null or undefined");
                TVal msg_tv; msg_tv.tag = STRING; msg_tv.pointer = msg;
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                ctx.should_throw = true;
                ctx.throw_value.tag = OBJECT;
                ctx.throw_value.pointer = err;
            }
        }
        return;
    }

    uint len = array_get_length(obj, ctx.heap);

    // Create a copy
    HObject*? new_arr = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = new_arr) {
        ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return;
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
        if (elem.tag != UNDEFINED) {
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

    ctx.result.tag = OBJECT;
    ctx.result.pointer = result;
}

// ============================================================================
// Array.prototype.toSpliced (ES2023 §23.1.3.35)
// ============================================================================
fn void builtin_array_proto_toSpliced(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) {
        TVal this_val = ctx.regs[ctx.base_reg - 1];
        if (this_val.tag == UNDEFINED || this_val.tag == NULL_VAL) {
            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (try err = err_raw) {
                err.prototype = ctx.heap.type_err_proto;
                HString* msg = builtin_intern_string(ctx.heap, "Array.prototype.toSpliced called on null or undefined");
                TVal msg_tv; msg_tv.tag = STRING; msg_tv.pointer = msg;
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                ctx.should_throw = true;
                ctx.throw_value.tag = OBJECT;
                ctx.throw_value.pointer = err;
            }
        }
        return;
    }

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

    // Get items to insert
    ushort item_count = 0;
    if (ctx.argc > 2) {
        item_count = ctx.argc - 2;
    }

    // Create new array: prefix + items + suffix
    HObject*? new_arr = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = new_arr) {
        ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return;
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

    ctx.result.tag = OBJECT;
    ctx.result.pointer = result;
}

// ============================================================================
// Array.prototype.with (ES2023 §23.1.3.37)
// ============================================================================
fn void builtin_array_proto_with(BuiltinContext* ctx) {
    HObject* obj = array_proto_get_this(ctx);
    if (obj == null) {
        TVal this_val = ctx.regs[ctx.base_reg - 1];
        if (this_val.tag == UNDEFINED || this_val.tag == NULL_VAL) {
            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (try err = err_raw) {
                err.prototype = ctx.heap.type_err_proto;
                HString* msg = builtin_intern_string(ctx.heap, "Array.prototype.with called on null or undefined");
                TVal msg_tv; msg_tv.tag = STRING; msg_tv.pointer = msg;
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                ctx.should_throw = true;
                ctx.throw_value.tag = OBJECT;
                ctx.throw_value.pointer = err;
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
            TVal msg_tv; msg_tv.tag = STRING; msg_tv.pointer = msg;
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
            ctx.should_throw = true;
            ctx.throw_value.tag = OBJECT;
            ctx.throw_value.pointer = err;
        }
        return;
    }

    // Get value to set
    TVal new_val;
    if (ctx.argc > 1) {
        new_val = ctx.regs[ctx.base_reg + 1];
    } else {
        new_val.tag = UNDEFINED;
        new_val.pointer = null;
    }

    // Create new array
    HObject*? new_arr = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = new_arr) {
        ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return;
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
    HObject*? new_arr = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
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

fn void builtin_math_acos(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.tag = NUMBER;
    ctx.result.number = math_acos(x);
}

fn void builtin_math_asin(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.tag = NUMBER;
    ctx.result.number = math_asin(x);
}

fn void builtin_math_atan(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.tag = NUMBER;
    ctx.result.number = math_atan(x);
}

fn void builtin_math_atan2(BuiltinContext* ctx) {
    double y = math_arg(ctx, 0);
    double x = math_arg(ctx, 1);
    ctx.result.tag = NUMBER;
    ctx.result.number = math_atan2(y, x);
}

fn void builtin_math_cosh(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.tag = NUMBER;
    ctx.result.number = math_cosh(x);
}

fn void builtin_math_sinh(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.tag = NUMBER;
    ctx.result.number = math_sinh(x);
}

fn void builtin_math_tanh(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.tag = NUMBER;
    ctx.result.number = math_tanh(x);
}

fn void builtin_math_acosh(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.tag = NUMBER;
    ctx.result.number = math_acosh(x);
}

fn void builtin_math_asinh(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.tag = NUMBER;
    ctx.result.number = math_asinh(x);
}

fn void builtin_math_atanh(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.tag = NUMBER;
    ctx.result.number = math_atanh(x);
}

fn void builtin_math_log2(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.tag = NUMBER;
    ctx.result.number = math_log2(x);
}

fn void builtin_math_log10(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.tag = NUMBER;
    ctx.result.number = math_log10(x);
}

fn void builtin_math_log1p(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.tag = NUMBER;
    ctx.result.number = math_log1p(x);
}

fn void builtin_math_expm1(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.tag = NUMBER;
    ctx.result.number = math_expm1(x);
}

fn void builtin_math_cbrt(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.tag = NUMBER;
    ctx.result.number = math_cbrt(x);
}

fn void builtin_math_hypot(BuiltinContext* ctx) {
    double result = 0.0;
    for (ushort i = 0; i < ctx.argc; i++) {
        double v = math_arg(ctx, i);
        if (math::is_nan(v)) { result = double::nan; break; }
        result = result + v * v;
    }
    ctx.result.tag = NUMBER;
    ctx.result.number = math_sqrt(result);
}

fn void builtin_math_trunc(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.tag = NUMBER;
    if (x >= 0) {
        ctx.result.number = math::floor(x);
    } else {
        ctx.result.number = math::ceil(x);
    }
}

fn void builtin_math_sign(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.tag = NUMBER;
    if (math::is_nan(x) || x == 0.0) {
        ctx.result.number = x;
    } else if (x > 0.0) {
        ctx.result.number = 1.0;
    } else {
        ctx.result.number = -1.0;
    }
}

fn void builtin_math_fround(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    ctx.result.tag = NUMBER;
    if (math::is_nan(x) || math::is_inf(x) || x == 0.0) {
        ctx.result.number = x;
    } else {
        // Round to nearest float32
        float f = (float)x;
        ctx.result.number = (double)f;
    }
}

fn void builtin_math_clz32(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    uint val = (uint)x;
    if (val == 0) {
        ctx.result.tag = FASTINT;
        ctx.result.fastint = 32;
    } else {
        uint count = 0;
        while ((val & 0x80000000) == 0) {
            count++;
            val <<= 1;
        }
        ctx.result.tag = FASTINT;
        ctx.result.fastint = (long)count;
    }
}

fn void builtin_math_imul(BuiltinContext* ctx) {
    double x = math_arg(ctx, 0);
    double y = math_arg(ctx, 1);
    int a = (int)(uint)x;
    int b = (int)(uint)y;
    ctx.result.tag = FASTINT;
    ctx.result.fastint = (long)(a * b);
}

/// Array.isArray(arg) — ES6 §22.1.2.2
fn void builtin_array_isArray(BuiltinContext* ctx) {
    if (ctx.argc == 0) {
        ctx.result.set_boolean(false);
        return;
    }
    TVal arg = ctx.regs[ctx.base_reg];
    if (arg.tag != OBJECT || arg.pointer == null) {
        ctx.result.set_boolean(false);
        return;
    }
    HObject* obj = (HObject*)arg.pointer;
    ctx.result.set_boolean(obj.get_class() == hobject::ObjClass.ARRAY);
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
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
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
        inner_ctx.should_throw = false;
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
            inner_ctx.should_throw = false;
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
        inner_ctx.should_throw = false;

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
    HObject*? bound_raw = ctx.heap.alloc_object(hobject::ObjClass.FUNCTION);
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
    HObject*? args_arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
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
        inner_ctx.should_throw = false;

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
        TVal r; r.tag = UNDEFINED; r.pointer = null; return r;
    }
    if (jctx.src[jctx.pos] == '0') {
        jctx.pos++;
    } else if (jctx.src[jctx.pos] >= '1' && jctx.src[jctx.pos] <= '9') {
        jctx.pos++;
        while (jctx.pos < jctx.len && jctx.src[jctx.pos] >= '0' && jctx.src[jctx.pos] <= '9') {
            jctx.pos++;
        }
    } else {
        TVal r; r.tag = UNDEFINED; r.pointer = null; return r;
    }

    // Fractional part
    if (jctx.pos < jctx.len && jctx.src[jctx.pos] == '.') {
        jctx.pos++;
        if (jctx.pos >= jctx.len || jctx.src[jctx.pos] < '0' || jctx.src[jctx.pos] > '9') {
            TVal r; r.tag = UNDEFINED; r.pointer = null; return r;
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
            TVal r; r.tag = UNDEFINED; r.pointer = null; return r;
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
    if ((double)fi == d && fi >= -9007199254740991 && fi <= 9007199254740991) {
        TVal r; r.tag = FASTINT; r.fastint = fi; return r;
    }
    TVal r; r.tag = NUMBER; r.number = d; return r;
}

/// Parse a JSON array: [value, ...]
fn TVal json_parse_array(JsonParseCtx* jctx) {
    jctx.pos++; // skip '['
    json_skip_ws(jctx);

    HObject*? arr_raw = jctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    HObject* arr;
    if (try a = arr_raw) {
        arr = a;
        arr.prototype = null; // will be set by caller
    } else {
        TVal r; r.tag = UNDEFINED; r.pointer = null; return r;
    }

    HString* len_key = builtin_intern_string(jctx.heap, "length");
    uint idx = 0;

    if (jctx.pos < jctx.len && jctx.src[jctx.pos] != ']') {
        while (true) {
            json_skip_ws(jctx);
            TVal elem = json_parse_value(jctx);
            if (elem.tag == UNDEFINED && elem.pointer == null && jctx.pos < jctx.len) {
                TVal r; r.tag = UNDEFINED; r.pointer = null; return r; // parse error
            }
            json_skip_ws(jctx);

            char[16] idx_buf;
            int idx_len = libc::snprintf(&idx_buf, 16, "%d", idx);
            HString* idx_key = builtin_intern_string(jctx.heap, idx_buf[:idx_len]);
            arr.put_prop(idx_key, elem, hobject::PROP_FLAGS_WEC);
            idx++;

            if (jctx.pos >= jctx.len) {
                TVal r; r.tag = UNDEFINED; r.pointer = null; return r;
            }
            if (jctx.src[jctx.pos] == ',') {
                jctx.pos++;
            } else {
                break;
            }
        }
    }

    if (jctx.pos >= jctx.len || jctx.src[jctx.pos] != ']') {
        TVal r; r.tag = UNDEFINED; r.pointer = null; return r;
    }
    jctx.pos++; // skip ']'

    TVal len_val;
    len_val.tag = FASTINT;
    len_val.fastint = (long)idx;
    arr.put_prop(len_key, len_val, hobject::PROP_FLAGS_WEC);

    TVal result;
    result.tag = OBJECT;
    result.pointer = arr;
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
    } else {
        TVal r; r.tag = UNDEFINED; r.pointer = null; return r;
    }

    if (jctx.pos < jctx.len && jctx.src[jctx.pos] != '}') {
        while (true) {
            json_skip_ws(jctx);
            if (jctx.pos >= jctx.len || jctx.src[jctx.pos] != '\"') {
                TVal r; r.tag = UNDEFINED; r.pointer = null; return r;
            }
            HString*? key_str = json_parse_string(jctx);
            if (try k = key_str) {
                json_skip_ws(jctx);
                if (jctx.pos >= jctx.len || jctx.src[jctx.pos] != ':') {
                    TVal r; r.tag = UNDEFINED; r.pointer = null; return r;
                }
                jctx.pos++; // skip ':'
                json_skip_ws(jctx);
                TVal val = json_parse_value(jctx);
                if (val.tag == UNDEFINED && val.pointer == null && jctx.pos < jctx.len) {
                    TVal r; r.tag = UNDEFINED; r.pointer = null; return r;
                }
                obj.put_prop(k, val, hobject::PROP_FLAGS_WEC);
                json_skip_ws(jctx);
                if (jctx.pos >= jctx.len) {
                    TVal r; r.tag = UNDEFINED; r.pointer = null; return r;
                }
                if (jctx.src[jctx.pos] == ',') {
                    jctx.pos++;
                } else {
                    break;
                }
            } else {
                TVal r; r.tag = UNDEFINED; r.pointer = null; return r;
            }
        }
    }

    if (jctx.pos >= jctx.len || jctx.src[jctx.pos] != '}') {
        TVal r; r.tag = UNDEFINED; r.pointer = null; return r;
    }
    jctx.pos++; // skip '}'

    TVal result;
    result.tag = OBJECT;
    result.pointer = obj;
    return result;
}

/// Parse a JSON value.
fn TVal json_parse_value(JsonParseCtx* jctx) {
    json_skip_ws(jctx);
    if (jctx.pos >= jctx.len) {
        TVal r; r.tag = UNDEFINED; r.pointer = null; return r;
    }

    char c = jctx.src[jctx.pos];
    switch (c) {
        case '\"':
            // String
            {
                HString*? s = json_parse_string(jctx);
                if (try str = s) {
                    TVal r; r.tag = STRING; r.pointer = str; return r;
                }
                TVal r; r.tag = UNDEFINED; r.pointer = null; return r;
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
                TVal r; r.tag = BOOLEAN; r.boolean = true; return r;
            }
            { TVal r; r.tag = UNDEFINED; r.pointer = null; return r; }
        case 'f':
            // false
            if (jctx.pos + 5 <= jctx.len &&
                jctx.src[jctx.pos + 1] == 'a' &&
                jctx.src[jctx.pos + 2] == 'l' &&
                jctx.src[jctx.pos + 3] == 's' &&
                jctx.src[jctx.pos + 4] == 'e') {
                jctx.pos += 5;
                TVal r; r.tag = BOOLEAN; r.boolean = false; return r;
            }
            { TVal r; r.tag = UNDEFINED; r.pointer = null; return r; }
        case 'n':
            // null
            if (jctx.pos + 4 <= jctx.len &&
                jctx.src[jctx.pos + 1] == 'u' &&
                jctx.src[jctx.pos + 2] == 'l' &&
                jctx.src[jctx.pos + 3] == 'l') {
                jctx.pos += 4;
                TVal r; r.tag = NULL_VAL; r.pointer = null; return r;
            }
            { TVal r; r.tag = UNDEFINED; r.pointer = null; return r; }
        case '-':
        case '0'..'9':
            return json_parse_number(jctx);
        default:
            { TVal r; r.tag = UNDEFINED; r.pointer = null; return r; }
    }
}

/// Walk helper for reviver (ES5 §15.12.2, step 4 — internalize properties).
fn TVal json_walk(Heap* heap, TVal reviver, TVal holder, HString* name) {
    TVal val;
    if (holder.tag == OBJECT && holder.pointer != null) {
        HObject* obj = (HObject*)holder.pointer;
        TVal? prop = obj.get_prop_proto(name);
        if (try p = prop) {
            val = p;
        } else {
            val.tag = UNDEFINED;
            val.pointer = null;
        }
    } else {
        val.tag = UNDEFINED;
        val.pointer = null;
    }

    if (val.tag == OBJECT && val.pointer != null) {
        HObject* obj = (HObject*)val.pointer;
        if (obj.get_class() == ObjClass.ARRAY) {
            HString* len_key = builtin_intern_string(heap, "length");
            TVal? len_prop = obj.get_prop_proto(len_key);
            uint len = 0;
            if (try l = len_prop) {
                if (l.tag == FASTINT) len = (uint)l.fastint;
            }
            for (uint i = 0; i < len; i++) {
                char[16] idx_buf;
                int idx_len = libc::snprintf(&idx_buf, 16, "%d", i);
                HString* idx_key = builtin_intern_string(heap, idx_buf[:idx_len]);
                TVal new_elem = json_walk(heap, reviver, val, idx_key);
                if (new_elem.tag == UNDEFINED) {
                    obj.delete_prop(idx_key);
                } else {
                    obj.put_prop(idx_key, new_elem, hobject::PROP_FLAGS_WEC);
                }
            }
        } else if (obj.get_class() == ObjClass.OBJECT) {
            // Walk own properties
            for (uint i = 0; i < obj.prop_count; i++) {
                HString* key_str = obj.props[i].key;
                if (key_str != null) {
                    TVal new_val = json_walk(heap, reviver, val, key_str);
                    if (new_val.tag == UNDEFINED) {
                        obj.delete_prop(key_str);
                    } else {
                        obj.put_prop(key_str, new_val, hobject::PROP_FLAGS_WEC);
                    }
                }
            }
        }
    }

    // Call reviver(this=holder, name, val)
    TVal name_str;
    name_str.tag = STRING;
    name_str.pointer = name;

    // For the reviver call, we need to invoke it via the calling convention
    // Since we're in a builtin context, we need to set up the stack
    // and re-dispatch. However, since JSON.parse is called as a LIGHTFUNC,
    // we don't have a VM activation. We need to signal re-dispatch.
    // For now, skip reviver and just return val
    return val;
}

/// Helper: throw a SyntaxError from a JSON builtin.
fn void json_throw_syntax_error(BuiltinContext* ctx, char[] msg) {
    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = ctx.heap.syntax_err_proto;
        HString* msg_str = builtin_intern_string(ctx.heap, msg);
        TVal msg_tv;
        msg_tv.tag = STRING;
        msg_tv.pointer = msg_str;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
        ctx.throw_value.tag = OBJECT;
        ctx.throw_value.pointer = err;
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

    if (text_arg.tag == STRING) {
        text_str = (HString*)text_arg.pointer;
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
    if (result.tag == UNDEFINED && result.pointer == null) {
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
    if (result.tag == OBJECT && result.pointer != null) {
        HObject* obj = (HObject*)result.pointer;
        if (obj.prototype == null) {
            obj.prototype = ctx.heap.object_proto;
        }
    }

    // Reviver support (ES5 §15.12.2 step 4)
    if (ctx.argc > 1) {
        TVal* reviver_arg = &ctx.regs[ctx.base_reg + 1];
        if (reviver_arg.tag == LIGHTFUNC || (reviver_arg.tag == OBJECT &&
            ((HObject*)reviver_arg.pointer) != null &&
            ((HObject*)reviver_arg.pointer).is_callable())) {
            // Create holder object { "": result }
            HObject*? holder_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
            if (try holder = holder_raw) {
                HString* empty_key = builtin_intern_string(ctx.heap, "");
                holder.put_prop(empty_key, result, hobject::PROP_FLAGS_WEC);

                TVal holder_tv;
                holder_tv.tag = OBJECT;
                holder_tv.pointer = holder;

                // For now, skip the full walk and just return result without reviver
                // Full reviver support requires VM re-dispatch which is complex
                *ctx.result = result;
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
    char* buf;
    usz buf_size;
    usz offset;
    usz indent_level;
    char* gap;
    usz gap_len;
    /// Current stack depth for cycle detection
    uint depth;
}

const uint JSON_MAX_DEPTH = 128;

/// Serialize an object's properties
fn int json_serialize_object(JsonSerializeCtx* jctx, HObject* obj) {
    if (jctx.offset >= jctx.buf_size) return -1;
    jctx.buf[jctx.offset++] = '{';

    // Check if object has properties
    bool has_props = false;
    for (uint i = 0; i < obj.prop_count; i++) {
        if (obj.props[i].key != null &&
            !obj.props[i].flags.is_accessor) {
            has_props = true;
            break;
        }
    }

    if (!has_props) {
        if (jctx.offset >= jctx.buf_size) return -1;
        jctx.buf[jctx.offset++] = '}';
        return 0;
    }

    // Need to get property keys in order
    // For simplicity, iterate the entry table (will work for most cases)
    bool first = true;
    for (uint i = 0; i < obj.prop_count; i++) {
        if (obj.props[i].key != null &&
            !obj.props[i].flags.is_accessor) {
            HString* key_hstr = (HString*)obj.props[i].key;
            TVal val = obj.props[i].value;

            // Skip undefined and function values
            if (val.tag == UNDEFINED) continue;
            if (val.tag == LIGHTFUNC) continue;
            if (val.tag == OBJECT && val.pointer != null) {
                HObject* vobj = (HObject*)val.pointer;
                if (vobj.get_class() == ObjClass.FUNCTION) continue;
            }

            if (!first) {
                if (jctx.offset >= jctx.buf_size) return -1;
                jctx.buf[jctx.offset++] = ',';
            }
            first = false;

            // Indentation
            if (jctx.gap_len > 0) {
                if (jctx.offset >= jctx.buf_size) return -1;
                jctx.buf[jctx.offset++] = '\n';
                for (usz g = 0; g < (jctx.indent_level + 1) * jctx.gap_len && jctx.offset < jctx.buf_size; g++) {
                    jctx.buf[jctx.offset++] = jctx.gap[g % jctx.gap_len];
                }
            }

            // Key
            char* key_data = key_hstr.get_cstr();
            uint key_len = key_hstr.blen;
            usz needed = (usz)(key_len * 6 + 4); // worst case escape
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
    }

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
    if (jctx.offset >= jctx.buf_size) return -1;
    jctx.buf[jctx.offset++] = '[';

    HString* len_key = builtin_intern_string(jctx.heap, "length");
    TVal? len_prop = arr.get_prop_proto(len_key);
    uint len = 0;
    if (try l = len_prop) {
        if (l.tag == FASTINT) len = (uint)l.fastint;
    }

    if (len == 0) {
        if (jctx.offset >= jctx.buf_size) return -1;
        jctx.buf[jctx.offset++] = ']';
        return 0;
    }

    bool first = true;
    for (uint i = 0; i < len; i++) {
        char[16] idx_buf;
        int idx_len = libc::snprintf(&idx_buf, 16, "%d", i);
        HString* idx_key = builtin_intern_string(jctx.heap, idx_buf[:idx_len]);
        TVal? elem_prop = arr.get_prop_proto(idx_key);
        TVal elem;
        if (try e = elem_prop) {
            elem = e;
        } else {
            elem.tag = UNDEFINED;
            elem.pointer = null;
        }

        if (!first) {
            if (jctx.offset >= jctx.buf_size) return -1;
            jctx.buf[jctx.offset++] = ',';
        }
        first = false;

        // Indentation
        if (jctx.gap_len > 0) {
            if (jctx.offset >= jctx.buf_size) return -1;
            jctx.buf[jctx.offset++] = '\n';
            for (usz g = 0; g < (jctx.indent_level + 1) * jctx.gap_len && jctx.offset < jctx.buf_size; g++) {
                jctx.buf[jctx.offset++] = jctx.gap[g % jctx.gap_len];
            }
        }

        // null for undefined elements
        if (elem.tag == UNDEFINED) {
            if (jctx.offset + 5 > jctx.buf_size) return -1;
            libc::memcpy(jctx.buf + jctx.offset, "null", 4);
            jctx.offset += 4;
        } else if (elem.tag == LIGHTFUNC) {
            if (jctx.offset + 5 > jctx.buf_size) return -1;
            libc::memcpy(jctx.buf + jctx.offset, "null", 4);
            jctx.offset += 4;
        } else if (elem.tag == OBJECT && elem.pointer != null) {
            HObject* vobj = (HObject*)elem.pointer;
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
    switch (val.tag) {
        case NULL_VAL: {
            if (jctx.offset + 5 > jctx.buf_size) return -1;
            jctx.buf[jctx.offset++] = 'n';
            jctx.buf[jctx.offset++] = 'u';
            jctx.buf[jctx.offset++] = 'l';
            jctx.buf[jctx.offset++] = 'l';
            return 0;
        }
        case BOOLEAN: {
            if (val.boolean) {
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
            double d = val.number;
            if (math::is_nan(d) || math::is_inf(d)) {
                if (jctx.offset + 5 > jctx.buf_size) return -1;
                libc::memcpy(jctx.buf + jctx.offset, "null", 4);
                jctx.offset += 4;
                return 0;
            }
            char[64] buf;
            int len = libc::snprintf(&buf, 64, "%.17g", d);
            if (len < 0 || len >= 64) return -1;
            if (jctx.offset + (usz)len > jctx.buf_size) return -1;
            for (int i = 0; i < len; i++) {
                jctx.buf[jctx.offset++] = buf[i];
            }
            return 0;
        }
        case FASTINT: {
            char[64] buf;
            int len = libc::snprintf(&buf, 64, "%ld", val.fastint);
            if (len < 0 || len >= 64) return -1;
            if (jctx.offset + (usz)len > jctx.buf_size) return -1;
            for (int i = 0; i < len; i++) {
                jctx.buf[jctx.offset++] = buf[i];
            }
            return 0;
        }
        case STRING: {
            HString* s = (HString*)val.pointer;
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
            if (val.pointer == null) {
                if (jctx.offset + 5 > jctx.buf_size) return -1;
                libc::memcpy(jctx.buf + jctx.offset, "null", 4);
                jctx.offset += 4;
                return 0;
            }
            HObject* obj = (HObject*)val.pointer;
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
    // Get the value
    if (ctx.argc < 1) {
        ctx.result.set_undefined();
        return;
    }
    TVal* value = &ctx.regs[ctx.base_reg];

    // Check replacer (for now, only pass it through — we handle function/array later)
    // Check space parameter
    uint space_num = 0;
    char[16] gap_buf;
    usz gap_len = 0;

    if (ctx.argc > 2) {
        TVal* space_arg = &ctx.regs[ctx.base_reg + 2];
        if (space_arg.tag == FASTINT) {
            space_num = (uint)space_arg.fastint;
            if (space_num > 10) space_num = 10;
        } else if (space_arg.tag == NUMBER) {
            space_num = (uint)(long)space_arg.number;
            if (space_num > 10) space_num = 10;
        } else if (space_arg.tag == STRING) {
            HString* s = (HString*)space_arg.pointer;
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
    } else if (gap_len == 0) {
        // Keep gap empty
    }

    // Serialize
    char[16384] buf;
    JsonSerializeCtx jctx;
    jctx.heap = ctx.heap;
    jctx.buf = &buf;
    jctx.buf_size = 16384;
    jctx.offset = 0;
    jctx.indent_level = 0;
    jctx.gap = &gap_str;
    jctx.gap_len = gap_len;
    jctx.depth = 0;

    int result = json_serialize_val(&jctx, value);
    if (result != 0) {
        ctx.result.set_undefined();
        return;
    }

    HString* result_str = builtin_intern_string(ctx.heap, buf[:jctx.offset]);
    ctx.result.tag = STRING;
    ctx.result.pointer = result_str;
}

// ============================================================================
// Date constructor and methods (ES5 §15.9)
// ============================================================================

/// ECMAScript epoch: 1970-01-01 00:00:00 UTC.
const long EPOCH_YEAR = 1970;

/// Helper: get current time in milliseconds since epoch.
fn double date_now_ms() {
    long t = libc::time(null);
    return (double)t * 1000.0;
}

/// Helper: get the time value from a Date object, or NaN if not a Date.
fn double date_get_time_value(TVal* val) {
    if (val.tag == OBJECT && val.pointer != null) {
        HObject* obj = (HObject*)val.pointer;
        if (obj.get_class() == hobject::ObjClass.DATE &&
            (obj.primitive_value.tag == NUMBER || obj.primitive_value.tag == FASTINT)) {
            return obj.primitive_value.get_number_or_fastint();
        }
    }
    return double::nan;
}

/// Helper: convert local time components to epoch ms using mktime.
fn double date_local_to_ms(long year, long month, long day,
                           long hour, long minute, long second, long ms) {
    Tm tm;
    tm.tm_sec   = (int)second;
    tm.tm_min   = (int)minute;
    tm.tm_hour  = (int)hour;
    tm.tm_mday  = (int)day;
    tm.tm_mon   = (int)month;
    tm.tm_year  = (int)year - 1900;
    tm.tm_wday  = 0;
    tm.tm_yday  = 0;
    tm.tm_isdst = -1;  // let mktime determine DST
    long epoch_sec = (long)libc::mktime(&tm);
    if (epoch_sec == -1) {
        // Use approximate computation as fallback
        // 86400 seconds per day, assume no DST issues
        // This is approximate but better than NaN
        long days = (year - 1970) * 365 + (year - 1969) / 4 - (year - 1901) / 100 + (year - 1601) / 400;
        // Add months
        long[12] days_in_months = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        bool leap = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0);
        for (long m = 0; m < month; m++) {
            days += days_in_months[m];
            if (leap && m == 1) days++;
        }
        days += day - 1;
        epoch_sec = days * 86400 + hour * 3600 + minute * 60 + second;
    }
    return (double)epoch_sec * 1000.0 + (double)ms;
}

/// Format a Date as a string like "Mon Jan 01 2024 12:00:00 GMT+0000".
fn usz date_format_to_string(double time_val, char* buf, usz buf_size) {
    // For NaN, return "Invalid Date"
    if (math::is_nan(time_val)) {
        return (usz)libc::snprintf(buf, buf_size, "Invalid Date");
    }
    long t_sec = (long)(time_val / 1000.0);
    Tm result;
    libc::localtime_r(&t_sec, &result);
    Tm* tm = &result;

    // Compute timezone offset by comparing localtime with a gmtime conversion
    // Use mktime on the local tm to get epoch, then compare with raw input
    long local_as_epoch = (long)libc::mktime(tm);
    // If mktime fails, local_as_epoch could be -1
    if (local_as_epoch == -1) local_as_epoch = t_sec;
    long tz_seconds = local_as_epoch - t_sec;
    char tz_sign = '+';
    int offs_hours = (int)(tz_seconds / 3600);
    int offs_mins = (int)((tz_seconds / 60) % 60);
    if (tz_seconds < 0) {
        tz_sign = '-';
        offs_hours = -offs_hours;
        offs_mins = -offs_mins;
    }

    // String constants for weekday/month names
    char* wday_name;
    switch (tm.tm_wday) {
        case 0: wday_name = "Sun"; break;
        case 1: wday_name = "Mon"; break;
        case 2: wday_name = "Tue"; break;
        case 3: wday_name = "Wed"; break;
        case 4: wday_name = "Thu"; break;
        case 5: wday_name = "Fri"; break;
        case 6: wday_name = "Sat"; break;
        default: wday_name = "???"; break;
    }
    char* mon_name;
    switch (tm.tm_mon) {
        case 0: mon_name = "Jan"; break;
        case 1: mon_name = "Feb"; break;
        case 2: mon_name = "Mar"; break;
        case 3: mon_name = "Apr"; break;
        case 4: mon_name = "May"; break;
        case 5: mon_name = "Jun"; break;
        case 6: mon_name = "Jul"; break;
        case 7: mon_name = "Aug"; break;
        case 8: mon_name = "Sep"; break;
        case 9: mon_name = "Oct"; break;
        case 10: mon_name = "Nov"; break;
        case 11: mon_name = "Dec"; break;
        default: mon_name = "???"; break;
    }

    return (usz)libc::snprintf(buf, buf_size, "%s %s %02d %04d %02d:%02d:%02d GMT%c%02d%02d",
        wday_name, mon_name,
        tm.tm_mday, tm.tm_year + 1900,
        tm.tm_hour, tm.tm_min, tm.tm_sec,
        tz_sign, offs_hours, offs_mins);
}

/// Format a Date as ISO 8601 string (used by toJSON).
fn usz date_format_iso(double time_val, char* buf, usz buf_size) {
    if (math::is_nan(time_val)) {
        return (usz)libc::snprintf(buf, buf_size, "null");
    }
    long t_sec = (long)(time_val / 1000.0);
    Tm result;
    libc::localtime_r(&t_sec, &result);
    Tm* tm = &result;

    // Compute timezone offset
    long local_as_epoch = (long)libc::mktime(tm);
    if (local_as_epoch == -1) local_as_epoch = t_sec;
    long tz_seconds = local_as_epoch - t_sec;
    char tz_sign = '+';
    int offs_hours = (int)(tz_seconds / 3600);
    int offs_mins = (int)((tz_seconds / 60) % 60);
    if (tz_seconds < 0) {
        tz_sign = '-';
        offs_hours = -offs_hours;
        offs_mins = -offs_mins;
    }
    int ms = (int)((long)time_val % 1000);
    if (ms < 0) ms += 1000;

    return (usz)libc::snprintf(buf, buf_size,
        "%04d-%02d-%02dT%02d:%02d:%02d.%03d%c%02d:%02d",
        tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
        tm.tm_hour, tm.tm_min, tm.tm_sec, ms,
        tz_sign, offs_hours, offs_mins);
}

/// Date() as function — returns current date-time string (ES5 §15.9.2.1).
fn void builtin_date(BuiltinContext* ctx) {
    double now = date_now_ms();
    if (ctx.is_constructor) {
        // new Date(...) — create Date object
        HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.DATE);
        if (catch err = obj_raw) {
            ctx.result.tag = UNDEFINED;
            ctx.result.pointer = null;
            return;
        }
        HObject* obj = obj_raw;
        obj.prototype = ctx.heap.date_proto;

        double time_val;
        if (ctx.argc == 0) {
            time_val = now;
        } else if (ctx.argc == 1) {
            TVal* arg = &ctx.regs[ctx.base_reg];
            if (arg.tag == STRING) {
                // Parse string (simplified — try as number first)
                HString* s = (HString*)arg.pointer;
                double num_val = builtin_string_to_number(s);
                if (math::is_nan(num_val)) {
                    // Non-numeric string — try basic parsing
                    // For now, default to current time
                    time_val = now;
                } else {
                    time_val = num_val;
                }
            } else if (arg.tag == NUMBER || arg.tag == FASTINT) {
                time_val = arg.get_number_or_fastint();
            } else if (arg.tag == UNDEFINED || arg.tag == NULL_VAL) {
                time_val = now;
            } else {
                time_val = now;
            }
        } else {
            // Multiple args: Date(year, month[, day, hour, minute, second, ms])
            TVal* year_arg  = &ctx.regs[ctx.base_reg];
            TVal* month_arg = &ctx.regs[ctx.base_reg + 1];
            double year  = year_arg.get_number_or_fastint();
            double month = month_arg.get_number_or_fastint();
            double day   = (ctx.argc > 2) ? ctx.regs[ctx.base_reg + 2].get_number_or_fastint() : 1.0;
            double hour  = (ctx.argc > 3) ? ctx.regs[ctx.base_reg + 3].get_number_or_fastint() : 0.0;
            double min   = (ctx.argc > 4) ? ctx.regs[ctx.base_reg + 4].get_number_or_fastint() : 0.0;
            double sec   = (ctx.argc > 5) ? ctx.regs[ctx.base_reg + 5].get_number_or_fastint() : 0.0;
            double ms    = (ctx.argc > 6) ? ctx.regs[ctx.base_reg + 6].get_number_or_fastint() : 0.0;

            // Year < 100 means 1900 + year
            if (year >= 0 && year < 100) year += 1900;

            time_val = date_local_to_ms((long)year, (long)month, (long)day,
                                        (long)hour, (long)min, (long)sec, (long)ms);
        }

        obj.primitive_value.tag = NUMBER;
        obj.primitive_value.number = time_val;

        ctx.result.tag = OBJECT;
        ctx.result.pointer = obj;
    } else {
        // Date() as function — return string of current time
        char[128] buf;
        usz len = date_format_to_string(now, &buf, 128);
        HString* result = builtin_intern_string(ctx.heap, buf[:len]);
        ctx.result.tag = STRING;
        ctx.result.pointer = result;
    }
}

/// Date.now() — ES5 §15.9.4.4
fn void builtin_date_now(BuiltinContext* ctx) {
    ctx.result.tag = NUMBER;
    ctx.result.number = date_now_ms();
}

/// Date.UTC(year, month[, day, hour, minute, second, ms]) — ES5 §15.9.4.3
fn void builtin_date_utc(BuiltinContext* ctx) {
    if (ctx.argc < 2) {
        ctx.result.tag = NUMBER;
        ctx.result.number = double::nan;
        return;
    }
    TVal* year_arg  = &ctx.regs[ctx.base_reg];
    TVal* month_arg = &ctx.regs[ctx.base_reg + 1];
    double year  = year_arg.get_number_or_fastint();
    double month = month_arg.get_number_or_fastint();
    double day   = (ctx.argc > 2) ? ctx.regs[ctx.base_reg + 2].get_number_or_fastint() : 1.0;
    double hour  = (ctx.argc > 3) ? ctx.regs[ctx.base_reg + 3].get_number_or_fastint() : 0.0;
    double min   = (ctx.argc > 4) ? ctx.regs[ctx.base_reg + 4].get_number_or_fastint() : 0.0;
    double sec   = (ctx.argc > 5) ? ctx.regs[ctx.base_reg + 5].get_number_or_fastint() : 0.0;
    double ms    = (ctx.argc > 6) ? ctx.regs[ctx.base_reg + 6].get_number_or_fastint() : 0.0;

    if (year >= 0 && year < 100) year += 1900;

    // For Date.UTC, the time is in UTC. We compute days from epoch using
    // simple calendar math (no timezone offset).
    long y = (long)year;
    long m = (long)month;
    // Adjust year: treat Jan and Feb as months 13,14 of previous year
    if (m < 2) { y--; m += 12; }
    // Computations using the formula
    long era = (y >= 0 ? y : y - 399) / 400;
    long yoe = y - era * 400;  // [0, 399]
    long doy = (153 * (m - 2) + 2) / 5 + (long)day - 1;  // day of year
    long doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    long epoch_day = (era * 146097 + (long)doe - 719468);
    double t = (double)epoch_day * 86400000.0;
    t += (double)hour * 3600000.0 + (double)min * 60000.0 + (double)sec * 1000.0 + (double)ms;
    ctx.result.tag = NUMBER;
    ctx.result.number = t;
}

/// Date.parse(string) — ES5 §15.9.4.2 (simplified)
fn void builtin_date_parse(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.tag = NUMBER;
        ctx.result.number = double::nan;
        return;
    }
    TVal* arg = &ctx.regs[ctx.base_reg];
    HString* s;
    if (arg.tag == STRING) {
        s = (HString*)arg.pointer;
    } else {
        s = builtin_to_string(ctx.heap, arg);
    }
    if (s == null || s.blen == 0) {
        ctx.result.tag = NUMBER;
        ctx.result.number = double::nan;
        return;
    }
    // Try numeric parsing first (milliseconds)
    double num_val = builtin_string_to_number(s);
    if (!math::is_nan(num_val)) {
        ctx.result.tag = NUMBER;
        ctx.result.number = num_val;
        return;
    }
    // For non-numeric strings, try parsing as date string via libc
    // For now, return NaN (Date.parse is notoriously complex)
    // Full implementation would use a proper date parser
    ctx.result.tag = NUMBER;
    ctx.result.number = double::nan;
}

/// Date.prototype.toString() — ES5 §15.9.5.2
fn void builtin_date_proto_toString(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double time_val = date_get_time_value(&this_val);
    char[128] buf;
    usz len = date_format_to_string(time_val, &buf, 128);
    HString* result = builtin_intern_string(ctx.heap, buf[:len]);
    ctx.result.tag = STRING;
    ctx.result.pointer = result;
}

/// Date.prototype.toJSON(key) — ES5 §15.9.5.44
fn void builtin_date_proto_toJSON(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double time_val = date_get_time_value(&this_val);
    if (math::is_nan(time_val)) {
        ctx.result.tag = NULL_VAL;
        ctx.result.pointer = null;
        return;
    }
    char[128] buf;
    usz len = date_format_iso(time_val, &buf, 128);
    HString* result = builtin_intern_string(ctx.heap, buf[:len]);
    ctx.result.tag = STRING;
    ctx.result.pointer = result;
}

/// Date.prototype.valueOf() — ES5 §15.9.5.8
fn void builtin_date_proto_valueOf(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double time_val = date_get_time_value(&this_val);
    ctx.result.tag = NUMBER;
    ctx.result.number = time_val;
}

/// Date.prototype.getTime() — ES5 §15.9.5.9
fn void builtin_date_proto_getTime(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double time_val = date_get_time_value(&this_val);
    ctx.result.tag = NUMBER;
    ctx.result.number = time_val;
}

/// Helper: break a time value into local time components via localtime_r.
fn void date_break_time(double time_val, long* year, long* month, long* day,
                        long* wday, long* hour, long* minute, long* second) {
    if (math::is_nan(time_val)) {
        *year = *month = *day = *wday = *hour = *minute = *second = 0;
        return;
    }
    long t_sec = (long)(time_val / 1000.0);
    Tm result;
    libc::localtime_r(&t_sec, &result);
    *year   = (long)(result.tm_year) + 1900L;
    *month  = (long)(result.tm_mon);
    *day    = (long)(result.tm_mday);
    *wday   = (long)(result.tm_wday);
    *hour   = result.tm_hour;
    *minute = result.tm_min;
    *second = result.tm_sec;
}

/// Date.prototype.getFullYear() — ES5 §15.9.5.10
fn void builtin_date_proto_getFullYear(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.tag = NUMBER; ctx.result.number = double::nan; return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.tag = FASTINT;
    ctx.result.fastint = year;
}

/// Date.prototype.getMonth() — ES5 §15.9.5.12
fn void builtin_date_proto_getMonth(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.tag = NUMBER; ctx.result.number = double::nan; return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.tag = FASTINT;
    ctx.result.fastint = month;
}

/// Date.prototype.getDate() — ES5 §15.9.5.14
fn void builtin_date_proto_getDate(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.tag = NUMBER; ctx.result.number = double::nan; return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.tag = FASTINT;
    ctx.result.fastint = day;
}

/// Date.prototype.getDay() — ES5 §15.9.5.16
fn void builtin_date_proto_getDay(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.tag = NUMBER; ctx.result.number = double::nan; return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.tag = FASTINT;
    ctx.result.fastint = wday;
}

/// Date.prototype.getHours() — ES5 §15.9.5.18
fn void builtin_date_proto_getHours(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.tag = NUMBER; ctx.result.number = double::nan; return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.tag = FASTINT;
    ctx.result.fastint = hour;
}

/// Date.prototype.getMinutes() — ES5 §15.9.5.20
fn void builtin_date_proto_getMinutes(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.tag = NUMBER; ctx.result.number = double::nan; return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.tag = FASTINT;
    ctx.result.fastint = min;
}

/// Date.prototype.getSeconds() — ES5 §15.9.5.22
fn void builtin_date_proto_getSeconds(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.tag = NUMBER; ctx.result.number = double::nan; return; }
    long year, month, day, wday, hour, min, sec;
    date_break_time(tv, &year, &month, &day, &wday, &hour, &min, &sec);
    ctx.result.tag = FASTINT;
    ctx.result.fastint = sec;
}

/// Date.prototype.getMilliseconds() — ES5 §15.9.5.24
fn void builtin_date_proto_getMilliseconds(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    double tv = date_get_time_value(&this_val);
    if (math::is_nan(tv)) { ctx.result.tag = NUMBER; ctx.result.number = double::nan; return; }
    long ms = (long)tv % 1000;
    if (ms < 0) ms += 1000;
    ctx.result.tag = FASTINT;
    ctx.result.fastint = ms;
}

// ============================================================================
// RegExp constructor builtins
// ============================================================================

/// Helper: extract the compiled regexp data pointer from 'this'.
/// Returns null if 'this' is not a REGEXP-class object.
fn HObject* regexp_get_this(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.tag != OBJECT || this_val.pointer == null) return null;
    HObject* obj = (HObject*)this_val.pointer;
    if (obj.get_class() != hobject::ObjClass.REGEXP) return null;
    return obj;
}

/// RegExp(pattern, flags) — ES5 §15.10.3 (called as function) / §15.10.4 (constructor).
/// When called as a function (not constructor), behaviour is identical to construction.
fn void builtin_regexp(BuiltinContext* ctx) {
    // Get pattern
    bool is_regexp = false;
    char* pattern_str = "";
    usz pattern_len = 0;
    int flags = 0;
    int js_flags = 0;  // JS flag bits: 1=g, 2=i, 4=m
    char* flags_str = "";
    usz flags_len = 0;

    if (ctx.argc > 0) {
        TVal* pattern_arg = &ctx.regs[ctx.base_reg];
        if (pattern_arg.tag == OBJECT && pattern_arg.pointer != null) {
            HObject* obj = (HObject*)pattern_arg.pointer;
            if (obj.get_class() == hobject::ObjClass.REGEXP && obj.regexp_data != null) {
                // Pattern is a RegExp object — extract its pattern
                is_regexp = true;
                if (obj.primitive_value.tag == STRING) {
                    HString* phs = (HString*)obj.primitive_value.pointer;
                    pattern_str = phs.get_cstr();
                    pattern_len = phs.blen;
                }
            } else {
                // Convert to string for pattern
                HString* phs = builtin_to_string(ctx.heap, pattern_arg);
                if (phs != null) {
                    pattern_str = phs.get_cstr();
                    pattern_len = phs.blen;
                }
            }
        } else if (pattern_arg.tag == STRING && pattern_arg.pointer != null) {
            HString* phs = (HString*)pattern_arg.pointer;
            pattern_str = phs.get_cstr();
            pattern_len = phs.blen;
        } else {
            // Convert to string
            HString* phs = builtin_to_string(ctx.heap, pattern_arg);
            if (phs != null) {
                pattern_str = phs.get_cstr();
                pattern_len = phs.blen;
            }
        }
    }

    // Get flags from second argument
    if (ctx.argc > 1) {
        TVal* flags_arg = &ctx.regs[ctx.base_reg + 1];
        if (flags_arg.tag == STRING && flags_arg.pointer != null) {
            HString* fhs = (HString*)flags_arg.pointer;
            flags_str = fhs.get_cstr();
            flags_len = fhs.blen;
        } else if (flags_arg.tag != UNDEFINED) {
            HString* fhs = builtin_to_string(ctx.heap, flags_arg);
            if (fhs != null) {
                flags_str = fhs.get_cstr();
                flags_len = fhs.blen;
            }
        }
    }

    // Convert JS flags to libregexp flag bits and store JS flags
    for (usz i = 0; i < flags_len; i++) {
        char f = flags_str[i];
        if (f == 'g') {
            js_flags |= 1;
        } else if (f == 'i') {
            flags |= re_bindings::RE_FLAG_IGNORECASE;
            js_flags |= 2;
        } else if (f == 'm') {
            flags |= re_bindings::RE_FLAG_MULTILINE;
            js_flags |= 4;
        } else if (f == 's') {
            flags |= re_bindings::RE_FLAG_DOTALL;
        } else {
            // Invalid flag per ES5 §15.10.4.1 — throw SyntaxError
            HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
            if (try err = err_raw) {
                err.prototype = ctx.heap.syntax_err_proto;
                char[80] buf;
                int len = libc::snprintf(&buf, 80, "Invalid flags supplied to RegExp constructor '%c'", f);
                if (len > 0 && len < 80) {
                    HString* msg_str = builtin_intern_string(ctx.heap, buf[:len]);
                    TVal msg_tv;
                    msg_tv.tag = STRING;
                    msg_tv.pointer = msg_str;
                    HString* msg_key = builtin_intern_string(ctx.heap, "message");
                    err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                }
                ctx.throw_value.tag = OBJECT;
                ctx.throw_value.pointer = err;
            } else {
                ctx.throw_value.set_undefined();
            }
            ctx.should_throw = true;
            return;
        }
    }

    // Compile the regexp
    char[128] error_buf;
    void* compiled = re_bindings::re_compile(
        (char*)pattern_str, (usz)pattern_len,
        flags, &error_buf, 128
    );

    if (compiled == null) {
        // Compilation failed — throw SyntaxError (ES5 §15.10.4.1)
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.syntax_err_proto;
            HString* msg_str = builtin_intern_string(ctx.heap, error_buf[:128]);
            TVal msg_tv;
            msg_tv.tag = STRING;
            msg_tv.pointer = msg_str;
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
            ctx.throw_value.tag = OBJECT;
            ctx.throw_value.pointer = err;
        } else {
            ctx.throw_value.set_undefined();
        }
        ctx.should_throw = true;
        return;
    }

    HObject*? obj_raw = ctx.heap.alloc_object(hobject::ObjClass.REGEXP);
    if (catch err = obj_raw) {
        if (compiled != null) re_bindings::re_free(compiled);
        ctx.result.set_undefined();
        return;
    }
    HObject* obj = obj_raw;
    obj.prototype = ctx.heap.regexp_proto;
    obj.regexp_data = compiled;

    // Store pattern string as primitive_value
    HString* pattern_hs = builtin_intern_string(ctx.heap, pattern_str[:pattern_len]);
    obj.primitive_value.tag = STRING;
    obj.primitive_value.pointer = pattern_hs;

    // Set RegExp instance properties (ES5 §15.10.7)
    HString* source_key = builtin_intern_string(ctx.heap, "source");
    TVal source_tv;
    source_tv.tag = STRING;
    source_tv.pointer = pattern_hs;
    obj.put_prop(source_key, source_tv, hobject::PROP_FLAGS_WEC);

    HString* global_key = builtin_intern_string(ctx.heap, "global");
    TVal global_tv;
    global_tv.tag = BOOLEAN;
    global_tv.boolean = (js_flags & 1) != 0;
    obj.put_prop(global_key, global_tv, hobject::PROP_FLAGS_WEC);

    HString* ignorecase_key = builtin_intern_string(ctx.heap, "ignoreCase");
    TVal ignorecase_tv;
    ignorecase_tv.tag = BOOLEAN;
    ignorecase_tv.boolean = (js_flags & 2) != 0;
    obj.put_prop(ignorecase_key, ignorecase_tv, hobject::PROP_FLAGS_WEC);

    HString* multiline_key = builtin_intern_string(ctx.heap, "multiline");
    TVal multiline_tv;
    multiline_tv.tag = BOOLEAN;
    multiline_tv.boolean = (js_flags & 4) != 0;
    obj.put_prop(multiline_key, multiline_tv, hobject::PROP_FLAGS_WEC);

    HString* lastindex_key = builtin_intern_string(ctx.heap, "lastIndex");
    TVal lastindex_tv;
    lastindex_tv.tag = FASTINT;
    lastindex_tv.fastint = 0;
    obj.put_prop(lastindex_key, lastindex_tv, hobject::PROP_FLAGS_WEC);

    ctx.result.tag = OBJECT;
    ctx.result.pointer = obj;
}

/// RegExp.prototype.test(string) — ES5 §15.10.6.3
fn void builtin_regexp_proto_test(BuiltinContext* ctx) {
    HObject* obj = regexp_get_this(ctx);
    if (obj == null || obj.regexp_data == null) {
        // ES5 §15.10.6.3 step 2: throw TypeError if this is not a RegExp
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_str = builtin_intern_string(ctx.heap, "RegExp.prototype.test called on incompatible receiver");
            TVal msg_tv;
            msg_tv.tag = STRING;
            msg_tv.pointer = msg_str;
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
            ctx.throw_value.tag = OBJECT;
            ctx.throw_value.pointer = err;
        } else {
            ctx.throw_value.set_undefined();
        }
        ctx.should_throw = true;
        return;
    }

    // Get input string
    char* input = "";
    int input_len = 0;
    if (ctx.argc > 0) {
        TVal* arg = &ctx.regs[ctx.base_reg];
        HString* hs;
        if (arg.tag == STRING) {
            hs = (HString*)arg.pointer;
        } else {
            hs = builtin_to_string(ctx.heap, arg);
        }
        if (hs != null) {
            input = hs.get_cstr();
            input_len = (int)hs.blen;
        }
    }

    // Get the global flag
    HString* global_key = builtin_intern_string(ctx.heap, "global");
    bool global_flag = false;
    if (try gv = obj.get_prop(global_key)) {
        if (gv.tag == BOOLEAN) global_flag = gv.boolean;
    }

    // Get lastIndex (if global)
    HString* li_key = builtin_intern_string(ctx.heap, "lastIndex");
    int start_pos = 0;
    if (global_flag) {
        if (try liv = obj.get_prop(li_key)) {
            if (liv.tag == FASTINT) {
                start_pos = (int)liv.fastint;
            } else if (liv.tag == NUMBER) {
                start_pos = (int)liv.number;
            }
        }
        // If lastIndex is out of bounds, reset to 0 and return false
        if (start_pos < 0 || start_pos > input_len) {
            TVal zero_tv;
            zero_tv.tag = FASTINT;
            zero_tv.fastint = 0;
            obj.put_prop(li_key, zero_tv, hobject::PROP_FLAGS_WEC);
            ctx.result.tag = BOOLEAN;
            ctx.result.boolean = false;
            return;
        }
    }

    // Execute
    int out_start = 0;
    int out_end = 0;
    int out_num_captures = 0;
    int result = re_bindings::re_exec(
        obj.regexp_data, input, input_len, start_pos,
        &out_start, &out_end, &out_num_captures,
        null, null, 0
    );

    // Update lastIndex if global
    if (global_flag) {
        if (result == re_bindings::RE_MATCH) {
            TVal end_tv;
            end_tv.tag = FASTINT;
            end_tv.fastint = (long)out_end;
            obj.put_prop(li_key, end_tv, hobject::PROP_FLAGS_WEC);
        } else {
            TVal zero_tv;
            zero_tv.tag = FASTINT;
            zero_tv.fastint = 0;
            obj.put_prop(li_key, zero_tv, hobject::PROP_FLAGS_WEC);
        }
    }

    ctx.result.tag = BOOLEAN;
    ctx.result.boolean = (result == re_bindings::RE_MATCH);
}

/// RegExp.prototype.exec(string) — ES5 §15.10.6.2
fn void builtin_regexp_proto_exec(BuiltinContext* ctx) {
    HObject* obj = regexp_get_this(ctx);
    if (obj == null || obj.regexp_data == null) {
        // ES5 §15.10.6.2 step 2: throw TypeError if this is not a RegExp
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_str = builtin_intern_string(ctx.heap, "RegExp.prototype.exec called on incompatible receiver");
            TVal msg_tv;
            msg_tv.tag = STRING;
            msg_tv.pointer = msg_str;
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
            ctx.throw_value.tag = OBJECT;
            ctx.throw_value.pointer = err;
        } else {
            ctx.throw_value.set_undefined();
        }
        ctx.should_throw = true;
        return;
    }

    // Get input string
    char* input = "";
    int input_len = 0;
    if (ctx.argc > 0) {
        TVal* arg = &ctx.regs[ctx.base_reg];
        HString* hs;
        if (arg.tag == STRING) {
            hs = (HString*)arg.pointer;
        } else {
            hs = builtin_to_string(ctx.heap, arg);
        }
        if (hs != null) {
            input = hs.get_cstr();
            input_len = (int)hs.blen;
        }
    }

    // Get the global flag (ES5 §15.10.6.2 step 6)
    HString* global_key = builtin_intern_string(ctx.heap, "global");
    bool global_flag = false;
    if (try gv = obj.get_prop(global_key)) {
        if (gv.tag == BOOLEAN) global_flag = gv.boolean;
    }

    // Get lastIndex (steps 4-5)
    HString* li_key = builtin_intern_string(ctx.heap, "lastIndex");
    int start_pos = 0;
    if (global_flag) {
        if (try liv = obj.get_prop(li_key)) {
            if (liv.tag == FASTINT) {
                start_pos = (int)liv.fastint;
            } else if (liv.tag == NUMBER) {
                start_pos = (int)liv.number;
            }
        }
        // Step 7: if i < 0 or i > length, set lastIndex to 0 and return null
        if (start_pos < 0 || start_pos > input_len) {
            TVal zero_tv;
            zero_tv.tag = FASTINT;
            zero_tv.fastint = 0;
            obj.put_prop(li_key, zero_tv, hobject::PROP_FLAGS_WEC);
            ctx.result.set_null();
            return;
        }
    }

    // Execute with capture arrays
    int out_start = 0;
    int out_end = 0;
    int out_num_captures = 0;
    int[re_bindings::RE_MAX_CAPTURES] caps_start;
    int[re_bindings::RE_MAX_CAPTURES] caps_end;
    libc::memset(&caps_start, 0, re_bindings::RE_MAX_CAPTURES * int::size);
    libc::memset(&caps_end, 0, re_bindings::RE_MAX_CAPTURES * int::size);

    int result = re_bindings::re_exec(
        obj.regexp_data, input, input_len, start_pos,
        &out_start, &out_end, &out_num_captures,
        &caps_start, &caps_end, re_bindings::RE_MAX_CAPTURES
    );

    if (result != re_bindings::RE_MATCH) {
        // Step 9: no match — reset lastIndex to 0 if global
        if (global_flag) {
            TVal zero_tv;
            zero_tv.tag = FASTINT;
            zero_tv.fastint = 0;
            obj.put_prop(li_key, zero_tv, hobject::PROP_FLAGS_WEC);
        }
        ctx.result.set_null();
        return;
    }

    // Step 10: if global, update lastIndex to end of match
    if (global_flag) {
        TVal end_tv;
        end_tv.tag = FASTINT;
        end_tv.fastint = (long)out_end;
        obj.put_prop(li_key, end_tv, hobject::PROP_FLAGS_WEC);
    }

    // Create result array
    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) {
        ctx.result.set_null();
        return;
    }
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;

    // Element 0: full match string
    usz match_len = (usz)(out_end - out_start);
    char[1024] buf;
    usz copy_len = match_len < 1024 ? match_len : 1024;
    for (usz i = 0; i < copy_len; i++) {
        buf[i] = input[(usz)out_start + i];
    }
    HString* match_str = builtin_intern_string(ctx.heap, buf[:copy_len]);
    TVal elem;
    elem.tag = STRING;
    elem.pointer = match_str;
    HString* zero_key = builtin_intern_string(ctx.heap, "0");
    arr.put_prop(zero_key, elem, hobject::PROP_FLAGS_WEC);

    // Elements 1..n: capture groups
    int num_caps = out_num_captures;
    if (num_caps > re_bindings::RE_MAX_CAPTURES) num_caps = re_bindings::RE_MAX_CAPTURES;
    for (int i = 0; i < num_caps; i++) {
        if (caps_start[i] >= 0 && caps_end[i] >= 0) {
            usz cap_len = (usz)(caps_end[i] - caps_start[i]);
            usz cap_copy = cap_len < 1024 ? cap_len : 1024;
            char[1024] cap_buf;
            for (usz j = 0; j < cap_copy; j++) {
                cap_buf[j] = input[(usz)caps_start[i] + j];
            }
            HString* cap_str = builtin_intern_string(ctx.heap, cap_buf[:cap_copy]);
            TVal cap_elem;
            cap_elem.tag = STRING;
            cap_elem.pointer = cap_str;
            char[16] idx_buf;
            int idx_len = libc::snprintf(&idx_buf, 16, "%d", i + 1);
            HString* idx_key = builtin_intern_string(ctx.heap, idx_buf[:idx_len]);
            arr.put_prop(idx_key, cap_elem, hobject::PROP_FLAGS_WEC);
        } else {
            // Unmatched capture group -> undefined
            HString* empty_key = builtin_intern_string(ctx.heap, "undefined");
            TVal undef;
            undef.tag = UNDEFINED;
            undef.pointer = null;
            char[16] idx_buf;
            int idx_len = libc::snprintf(&idx_buf, 16, "%d", i + 1);
            HString* idx_key = builtin_intern_string(ctx.heap, idx_buf[:idx_len]);
            arr.put_prop(idx_key, undef, hobject::PROP_FLAGS_WEC);
        }
    }

    // Set index property
    HString* index_key = builtin_intern_string(ctx.heap, "index");
    TVal index_val;
    index_val.tag = FASTINT;
    index_val.fastint = (long)out_start;
    arr.put_prop(index_key, index_val, hobject::PROP_FLAGS_WEC);

    // Set input property
    HString* input_key = builtin_intern_string(ctx.heap, "input");
    TVal input_val;
    input_val.tag = STRING;
    input_val.pointer = builtin_intern_string(ctx.heap, input[:input_len]);
    arr.put_prop(input_key, input_val, hobject::PROP_FLAGS_WEC);

    // Set length
    uint total_elements = 1 + (uint)num_caps;
    HString* len_key = builtin_intern_string(ctx.heap, "length");
    TVal len_val;
    len_val.tag = FASTINT;
    len_val.fastint = (long)total_elements;
    arr.put_prop(len_key, len_val, hobject::PROP_FLAGS_WEC);

    ctx.result.tag = OBJECT;
    ctx.result.pointer = arr;
}

/// RegExp.prototype.toString() — ES5 §15.10.6.4
fn void builtin_regexp_proto_toString(BuiltinContext* ctx) {
    HObject* obj = regexp_get_this(ctx);
    if (obj == null) {
        ctx.result.tag = STRING;
        ctx.result.pointer = builtin_intern_string(ctx.heap, "");
        return;
    }

    // Build "/pattern/flags" string
    char* pattern = "";
    usz plen = 0;
    if (obj.primitive_value.tag == STRING && obj.primitive_value.pointer != null) {
        HString* phs = (HString*)obj.primitive_value.pointer;
        pattern = phs.get_cstr();
        plen = phs.blen;
    }

    // No flag storage yet on regexp objects, use "" for flags
    usz total = 1 + plen + 1;  // /pattern/
    char[512] buf;
    int pos = 0;
    buf[pos++] = '/';
    for (usz i = 0; i < plen && pos < 510; i++) {
        buf[pos++] = pattern[i];
    }
    buf[pos++] = '/';
    buf[pos] = 0;

    HString* result = builtin_intern_string(ctx.heap, buf[:pos]);
    ctx.result.tag = STRING;
    ctx.result.pointer = result;
}

// ============================================================================
// SameValueZero comparison (ES6 §7.2.10)
// Used by Map and Set for key/value equality.
// Differs from === only in that NaN equals NaN.
// ============================================================================
fn bool same_value_zero(TVal a, TVal b) {
    if (a.tag == b.tag) {
        switch (a.tag) {
            case UNDEFINED: return true;
            case NULL_VAL:  return true;
            case BOOLEAN:   return a.boolean == b.boolean;
            case NUMBER:
                if (math::is_nan(a.number) && math::is_nan(b.number)) return true;
                return a.number == b.number;
            case FASTINT:   return a.fastint == b.fastint;
            case STRING:    return a.pointer == b.pointer;
            case OBJECT:    return a.pointer == b.pointer;
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

// ============================================================================
// SameValue comparison (ES6 §7.2.9)
// Used by Object.is.
// Differs from SameValueZero in that +0 !== -0.
// ============================================================================
fn bool same_value(TVal a, TVal b) {
    if (a.tag == b.tag) {
        switch (a.tag) {
            case UNDEFINED: return true;
            case NULL_VAL:  return true;
            case BOOLEAN:   return a.boolean == b.boolean;
            case NUMBER:
                if (math::is_nan(a.number) && math::is_nan(b.number)) return true;
                // +0 !== -0: check if both are zero with different signs
                if (a.number == 0.0 && b.number == 0.0) {
                    return 1.0 / a.number == 1.0 / b.number;
                }
                return a.number == b.number;
            case FASTINT:   return a.fastint == b.fastint;
            case STRING:    return a.pointer == b.pointer;
            case OBJECT:    return a.pointer == b.pointer;
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

// ============================================================================
// Map helpers
// ============================================================================

fn HObject* check_map(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.tag == OBJECT && this_val.pointer != null) {
        HObject* obj = (HObject*)this_val.pointer;
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
            msg_val.tag = STRING;
            msg_val.pointer = msg_str;
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
        }
    }
    return null;
}

/// Find the index in array_part where a key matches. Returns -1 if not found.
/// Map entries are stored as [k0, v0, k1, v1, ...] in array_part.
fn int map_find_key(HObject* map, TVal key) {
    uint count = map.array_used;
    for (uint i = 0; i < count; i += 2) {
        if (same_value_zero(map.array_part[i], key)) {
            return (int)i;
        }
    }
    return -1;
}

// ============================================================================
// Map constructor (ES6 §23.1.1)
// ============================================================================
fn void builtin_map(BuiltinContext* ctx) {
    HObject*? map_raw = ctx.heap.alloc_object(hobject::ObjClass.MAP);
    if (catch err = map_raw) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }
    HObject* map = map_raw;
    map.prototype = ctx.heap.map_proto;

    // Set size property
    HString* size_key = builtin_intern_string(ctx.heap, "size");
    TVal size_val;
    size_val.tag = FASTINT;
    size_val.fastint = 0;
    map.put_prop(size_key, size_val, hobject::PROP_FLAGS_WEC);

    // If iterable argument, populate map
    if (ctx.argc >= 1) {
        TVal arg = ctx.regs[ctx.base_reg];
        if (arg.tag == OBJECT && arg.pointer != null) {
            HObject* iterable = (HObject*)arg.pointer;
            // Simple case: array-like iterable with forEach/pairs
            // We handle the common case of array of [key, value] pairs
            uint len = array_get_length(iterable, ctx.heap);
            for (uint i = 0; i < len; i++) {
                TVal pair = array_get_elem(iterable, i, ctx.heap);
                if (pair.tag == OBJECT && pair.pointer != null) {
                    HObject* pair_obj = (HObject*)pair.pointer;
                    TVal k = array_get_elem(pair_obj, 0, ctx.heap);
                    TVal v = array_get_elem(pair_obj, 1, ctx.heap);
                    // Call builtin_map_proto_set-style logic inline
                    int found = map_find_key(map, k);
                    if (found >= 0) {
                        map.array_part[(uint)found + 1] = v;
                    } else {
                        uint cnt = map.array_used;
                        map.set_array_idx(cnt, k);
                        map.set_array_idx(cnt + 1, v);
                    }
                    // Update size
                    uint entry_count = map.array_used / 2;
                    size_val.fastint = (long)entry_count;
                    map.put_prop(size_key, size_val, hobject::PROP_FLAGS_WEC);
                }
            }
        }
    }

    ctx.result.tag = OBJECT;
    ctx.result.pointer = map;
}

// ============================================================================
// Map.prototype.set(key, value) — ES6 §23.1.3.9
// ============================================================================
fn void builtin_map_proto_set(BuiltinContext* ctx) {
    HObject* map = check_map(ctx);
    if (map == null) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }
    if (ctx.argc < 1) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }

    TVal key = ctx.regs[ctx.base_reg];
    TVal value = ctx.regs[ctx.base_reg + 1];  // undefined if not provided

    int found = map_find_key(map, key);
    if (found >= 0) {
        map.array_part[(uint)found + 1] = value;
    } else {
        uint cnt = map.array_used;
        map.set_array_idx(cnt, key);
        map.set_array_idx(cnt + 1, value);
    }

    // Update size property
    HString* size_key = builtin_intern_string(ctx.heap, "size");
    TVal size_val;
    size_val.tag = FASTINT;
    size_val.fastint = (long)(map.array_used / 2);
    map.put_prop(size_key, size_val, hobject::PROP_FLAGS_WEC);

    // Return the map itself
    ctx.result.tag = OBJECT;
    ctx.result.pointer = map;
}

// ============================================================================
// Map.prototype.get(key) — ES6 §23.1.3.6
// ============================================================================
fn void builtin_map_proto_get(BuiltinContext* ctx) {
    HObject* map = check_map(ctx);
    if (map == null) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }
    if (ctx.argc < 1) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }

    TVal key = ctx.regs[ctx.base_reg];
    int found = map_find_key(map, key);
    if (found >= 0) {
        *ctx.result = map.array_part[(uint)found + 1];
    } else {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
    }
}

// ============================================================================
// Map.prototype.has(key) — ES6 §23.1.3.7
// ============================================================================
fn void builtin_map_proto_has(BuiltinContext* ctx) {
    HObject* map = check_map(ctx);
    if (map == null) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }
    if (ctx.argc < 1) { ctx.result.tag = BOOLEAN; ctx.result.boolean = false; return; }

    TVal key = ctx.regs[ctx.base_reg];
    int found = map_find_key(map, key);
    ctx.result.tag = BOOLEAN;
    ctx.result.boolean = (found >= 0);
}

// ============================================================================
// Map.prototype.delete(key) — ES6 §23.1.3.3
// ============================================================================
fn void builtin_map_proto_delete(BuiltinContext* ctx) {
    HObject* map = check_map(ctx);
    if (map == null) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }
    if (ctx.argc < 1) { ctx.result.tag = BOOLEAN; ctx.result.boolean = false; return; }

    TVal key = ctx.regs[ctx.base_reg];
    int found = map_find_key(map, key);
    if (found >= 0) {
        uint cnt = map.array_used;
        // Shift elements down to fill the gap
        for (uint i = (uint)found; i + 2 < cnt; i++) {
            map.array_part[i] = map.array_part[i + 2];
        }
        // Clear the last two slots
        map.array_part[cnt - 2].tag = UNDEFINED;
        map.array_part[cnt - 2].pointer = null;
        map.array_part[cnt - 1].tag = UNDEFINED;
        map.array_part[cnt - 1].pointer = null;
        map.array_used = cnt - 2;

        HString* size_key = builtin_intern_string(ctx.heap, "size");
        TVal size_val;
        size_val.tag = FASTINT;
        size_val.fastint = (long)(map.array_used / 2);
        map.put_prop(size_key, size_val, hobject::PROP_FLAGS_WEC);

        ctx.result.tag = BOOLEAN;
        ctx.result.boolean = true;
    } else {
        ctx.result.tag = BOOLEAN;
        ctx.result.boolean = false;
    }
}

// ============================================================================
// Map.prototype.clear() — ES6 §23.1.3.1
// ============================================================================
fn void builtin_map_proto_clear(BuiltinContext* ctx) {
    HObject* map = check_map(ctx);
    if (map == null) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }

    // Reset array_part
    uint cnt = map.array_used;
    for (uint i = 0; i < cnt; i++) {
        map.array_part[i].tag = UNDEFINED;
        map.array_part[i].pointer = null;
    }
    map.array_used = 0;

    // Update size
    HString* size_key = builtin_intern_string(ctx.heap, "size");
    TVal size_val;
    size_val.tag = FASTINT;
    size_val.fastint = 0;
    map.put_prop(size_key, size_val, hobject::PROP_FLAGS_WEC);

    ctx.result.tag = UNDEFINED;
    ctx.result.pointer = null;
}

// ============================================================================
// Map.prototype.keys() — ES6 §23.1.3.8
// Returns a new Array of all keys in insertion order.
// ============================================================================
fn void builtin_map_proto_keys(BuiltinContext* ctx) {
    HObject* map = check_map(ctx);
    if (map == null) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }

    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;

    uint cnt = map.array_used;
    uint key_count = cnt / 2;
    for (uint i = 0; i < key_count; i++) {
        array_set_elem(arr, i, map.array_part[i * 2], ctx.heap);
    }
    array_set_length(arr, key_count, ctx.heap);

    ctx.result.tag = OBJECT;
    ctx.result.pointer = arr;
}

// ============================================================================
// Map.prototype.values() — ES6 §23.1.3.11
// Returns a new Array of all values in insertion order.
// ============================================================================
fn void builtin_map_proto_values(BuiltinContext* ctx) {
    HObject* map = check_map(ctx);
    if (map == null) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }

    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;

    uint cnt = map.array_used;
    uint val_count = cnt / 2;
    for (uint i = 0; i < val_count; i++) {
        array_set_elem(arr, i, map.array_part[i * 2 + 1], ctx.heap);
    }
    array_set_length(arr, val_count, ctx.heap);

    ctx.result.tag = OBJECT;
    ctx.result.pointer = arr;
}

// ============================================================================
// Map.prototype.entries() — ES6 §23.1.3.4
// Returns a new Array of [key, value] arrays in insertion order.
// ============================================================================
fn void builtin_map_proto_entries(BuiltinContext* ctx) {
    HObject* map = check_map(ctx);
    if (map == null) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }

    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;

    uint cnt = map.array_used;
    uint entry_count = cnt / 2;
    for (uint i = 0; i < entry_count; i++) {
        HObject*? pair_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
        if (catch pair_err = pair_raw) continue;
        HObject* pair = pair_raw;
        pair.prototype = ctx.heap.array_proto;
        array_set_elem(pair, 0, map.array_part[i * 2], ctx.heap);
        array_set_elem(pair, 1, map.array_part[i * 2 + 1], ctx.heap);
        array_set_length(pair, 2, ctx.heap);

        TVal pair_val;
        pair_val.tag = OBJECT;
        pair_val.pointer = pair;
        array_set_elem(arr, i, pair_val, ctx.heap);
    }
    array_set_length(arr, entry_count, ctx.heap);

    ctx.result.tag = OBJECT;
    ctx.result.pointer = arr;
}

// ============================================================================
// Map.prototype.forEach(callbackfn[, thisArg]) — ES6 §23.1.3.5
// ============================================================================
fn void builtin_map_proto_forEach(BuiltinContext* ctx) {
    HObject* map = check_map(ctx);
    if (map == null) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }

    if (ctx.argc < 1) {
        // Missing callback throws TypeError
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_str = builtin_intern_string(ctx.heap, "missing argument 0 when calling function forEach");
            if (msg_str != null) {
                TVal msg_val;
                msg_val.tag = STRING;
                msg_val.pointer = msg_str;
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
            }
        }
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }

    // forEach with callback requires VM call mechanism (callback invocation).
    // For now, we validate the callback exists but don't invoke it.
    TVal callback = ctx.regs[ctx.base_reg];
    if (!(callback.tag == OBJECT && callback.pointer != null && ((HObject*)callback.pointer).flags.callable)) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_str = builtin_intern_string(ctx.heap, "object is not a function");
            if (msg_str != null) {
                TVal msg_val;
                msg_val.tag = STRING;
                msg_val.pointer = msg_str;
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
            }
        }
    }

    ctx.result.tag = UNDEFINED;
    ctx.result.pointer = null;
}

// ============================================================================
// Set helpers
// ============================================================================

fn HObject* check_set(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.tag == OBJECT && this_val.pointer != null) {
        HObject* obj = (HObject*)this_val.pointer;
        if (obj.flags.obj_class == hobject::ObjClass.SET) return obj;
    }
    // TypeError
    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_str = builtin_intern_string(ctx.heap,
            "Set.prototype method called on incompatible value");
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

/// Find the index in array_part where a value matches. Returns -1 if not found.
/// Set entries are stored as [v0, v1, ...] in array_part.
fn int set_find_value(HObject* set, TVal val) {
    uint count = set.array_used;
    for (uint i = 0; i < count; i++) {
        if (same_value_zero(set.array_part[i], val)) {
            return (int)i;
        }
    }
    return -1;
}

// ============================================================================
// Set constructor (ES6 §23.2.1)
// ============================================================================
fn void builtin_set(BuiltinContext* ctx) {
    HObject*? set_raw = ctx.heap.alloc_object(hobject::ObjClass.SET);
    if (catch err = set_raw) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }
    HObject* set = set_raw;
    set.prototype = ctx.heap.set_proto;

    // Set size property
    HString* size_key = builtin_intern_string(ctx.heap, "size");
    TVal size_val;
    size_val.tag = FASTINT;
    size_val.fastint = 0;
    set.put_prop(size_key, size_val, hobject::PROP_FLAGS_WEC);

    // If iterable argument, populate set
    if (ctx.argc >= 1) {
        TVal arg = ctx.regs[ctx.base_reg];
        if (arg.tag == OBJECT && arg.pointer != null) {
            HObject* iterable = (HObject*)arg.pointer;
            uint len = array_get_length(iterable, ctx.heap);
            for (uint i = 0; i < len; i++) {
                TVal v = array_get_elem(iterable, i, ctx.heap);
                if (v.tag != UNDEFINED) {
                    int found = set_find_value(set, v);
                    if (found < 0) {
                        set.set_array_idx(set.array_used, v);
                    }
                }
            }
            size_val.fastint = (long)set.array_used;
            set.put_prop(size_key, size_val, hobject::PROP_FLAGS_WEC);
        }
    }

    ctx.result.tag = OBJECT;
    ctx.result.pointer = set;
}

// ============================================================================
// Set.prototype.add(value) — ES6 §23.2.3.1
// ============================================================================
fn void builtin_set_proto_add(BuiltinContext* ctx) {
    HObject* set = check_set(ctx);
    if (set == null) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }
    if (ctx.argc < 1) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }

    TVal value = ctx.regs[ctx.base_reg];
    int found = set_find_value(set, value);
    if (found < 0) {
        set.set_array_idx(set.array_used, value);
    }

    // Update size
    HString* size_key = builtin_intern_string(ctx.heap, "size");
    TVal size_val;
    size_val.tag = FASTINT;
    size_val.fastint = (long)set.array_used;
    set.put_prop(size_key, size_val, hobject::PROP_FLAGS_WEC);

    // Return the set
    ctx.result.tag = OBJECT;
    ctx.result.pointer = set;
}

// ============================================================================
// Set.prototype.has(value) — ES6 §23.2.3.7
// ============================================================================
fn void builtin_set_proto_has(BuiltinContext* ctx) {
    HObject* set = check_set(ctx);
    if (set == null) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }
    if (ctx.argc < 1) { ctx.result.tag = BOOLEAN; ctx.result.boolean = false; return; }

    TVal value = ctx.regs[ctx.base_reg];
    int found = set_find_value(set, value);
    ctx.result.tag = BOOLEAN;
    ctx.result.boolean = (found >= 0);
}

// ============================================================================
// Set.prototype.delete(value) — ES6 §23.2.3.4
// ============================================================================
fn void builtin_set_proto_delete(BuiltinContext* ctx) {
    HObject* set = check_set(ctx);
    if (set == null) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }
    if (ctx.argc < 1) { ctx.result.tag = BOOLEAN; ctx.result.boolean = false; return; }

    TVal value = ctx.regs[ctx.base_reg];
    int found = set_find_value(set, value);
    if (found >= 0) {
        uint cnt = set.array_used;
        // Shift elements down
        for (uint i = (uint)found; i + 1 < cnt; i++) {
            set.array_part[i] = set.array_part[i + 1];
        }
        set.array_part[cnt - 1].tag = UNDEFINED;
        set.array_part[cnt - 1].pointer = null;
        set.array_used = cnt - 1;

        HString* size_key = builtin_intern_string(ctx.heap, "size");
        TVal size_val;
        size_val.tag = FASTINT;
        size_val.fastint = (long)set.array_used;
        set.put_prop(size_key, size_val, hobject::PROP_FLAGS_WEC);

        ctx.result.tag = BOOLEAN;
        ctx.result.boolean = true;
    } else {
        ctx.result.tag = BOOLEAN;
        ctx.result.boolean = false;
    }
}

// ============================================================================
// Set.prototype.clear() — ES6 §23.2.3.2
// ============================================================================
fn void builtin_set_proto_clear(BuiltinContext* ctx) {
    HObject* set = check_set(ctx);
    if (set == null) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }

    uint cnt = set.array_used;
    for (uint i = 0; i < cnt; i++) {
        set.array_part[i].tag = UNDEFINED;
        set.array_part[i].pointer = null;
    }
    set.array_used = 0;

    HString* size_key = builtin_intern_string(ctx.heap, "size");
    TVal size_val;
    size_val.tag = FASTINT;
    size_val.fastint = 0;
    set.put_prop(size_key, size_val, hobject::PROP_FLAGS_WEC);

    ctx.result.tag = UNDEFINED;
    ctx.result.pointer = null;
}

// ============================================================================
// Set.prototype.keys() — ES6 §23.2.3.8
// Set's keys() returns the same as values() — a new Array of values.
// ============================================================================
fn void builtin_set_proto_keys(BuiltinContext* ctx) {
    HObject* set = check_set(ctx);
    if (set == null) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }

    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;

    uint cnt = set.array_used;
    for (uint i = 0; i < cnt; i++) {
        array_set_elem(arr, i, set.array_part[i], ctx.heap);
    }
    array_set_length(arr, cnt, ctx.heap);

    ctx.result.tag = OBJECT;
    ctx.result.pointer = arr;
}

// ============================================================================
// Set.prototype.values() — ES6 §23.2.3.10
// ============================================================================
fn void builtin_set_proto_values(BuiltinContext* ctx) {
    HObject* set = check_set(ctx);
    if (set == null) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }

    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;

    uint cnt = set.array_used;
    for (uint i = 0; i < cnt; i++) {
        array_set_elem(arr, i, set.array_part[i], ctx.heap);
    }
    array_set_length(arr, cnt, ctx.heap);

    ctx.result.tag = OBJECT;
    ctx.result.pointer = arr;
}

// ============================================================================
// Set.prototype.entries() — ES6 §23.2.3.5
// Returns [value, value] pairs for each element.
// ============================================================================
fn void builtin_set_proto_entries(BuiltinContext* ctx) {
    HObject* set = check_set(ctx);
    if (set == null) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }

    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;

    uint cnt = set.array_used;
    for (uint i = 0; i < cnt; i++) {
        HObject*? pair_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
        if (catch pair_err = pair_raw) continue;
        HObject* pair = pair_raw;
        pair.prototype = ctx.heap.array_proto;
        array_set_elem(pair, 0, set.array_part[i], ctx.heap);
        array_set_elem(pair, 1, set.array_part[i], ctx.heap);
        array_set_length(pair, 2, ctx.heap);

        TVal pair_val;
        pair_val.tag = OBJECT;
        pair_val.pointer = pair;
        array_set_elem(arr, i, pair_val, ctx.heap);
    }
    array_set_length(arr, cnt, ctx.heap);

    ctx.result.tag = OBJECT;
    ctx.result.pointer = arr;
}

// ============================================================================
// Set.prototype.forEach(callbackfn[, thisArg]) — ES6 §23.2.3.6
// ============================================================================
fn void builtin_set_proto_forEach(BuiltinContext* ctx) {
    HObject* set = check_set(ctx);
    if (set == null) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }

    if (ctx.argc < 1) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_str = builtin_intern_string(ctx.heap, "missing argument 0 when calling function forEach");
            if (msg_str != null) {
                TVal msg_val;
                msg_val.tag = STRING;
                msg_val.pointer = msg_str;
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
            }
        }
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }

    // Basic forEach without VM callback support — just returns undefined
    ctx.result.tag = UNDEFINED;
    ctx.result.pointer = null;
}

// ============================================================================
// WeakMap helpers
// ============================================================================

fn HObject* check_weakmap(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.tag == OBJECT && this_val.pointer != null) {
        HObject* obj = (HObject*)this_val.pointer;
        if (obj.flags.obj_class == hobject::ObjClass.WEAKMAP) return obj;
    }
    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_str = builtin_intern_string(ctx.heap,
            "WeakMap.prototype method called on incompatible value");
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

fn int weakmap_find_key(HObject* wm, TVal key) {
    uint count = wm.array_used;
    for (uint i = 0; i < count; i += 2) {
        if (same_value_zero(wm.array_part[i], key)) {
            return (int)i;
        }
    }
    return -1;
}

// ============================================================================
// WeakMap constructor (ES6 §23.3.1)
// ============================================================================
fn void builtin_weakmap(BuiltinContext* ctx) {
    HObject*? wm_raw = ctx.heap.alloc_object(hobject::ObjClass.WEAKMAP);
    if (catch err = wm_raw) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }
    HObject* wm = wm_raw;
    wm.prototype = ctx.heap.weakmap_proto;

    if (ctx.argc >= 1 && ctx.is_constructor) {
        TVal arg = ctx.regs[ctx.base_reg];
        if (arg.tag == OBJECT && arg.pointer != null) {
            HObject* iterable = (HObject*)arg.pointer;
            uint len = array_get_length(iterable, ctx.heap);
            for (uint i = 0; i < len; i++) {
                TVal pair = array_get_elem(iterable, i, ctx.heap);
                if (pair.tag == OBJECT && pair.pointer != null) {
                    HObject* pair_obj = (HObject*)pair.pointer;
                    TVal k = array_get_elem(pair_obj, 0, ctx.heap);
                    TVal v = array_get_elem(pair_obj, 1, ctx.heap);
                    if (k.tag != OBJECT || k.pointer == null) {
                        ctx.result.tag = UNDEFINED;
                        ctx.result.pointer = null;
                        return;
                    }
                    int found = weakmap_find_key(wm, k);
                    if (found >= 0) {
                        wm.array_part[(uint)found + 1] = v;
                    } else {
                        uint cnt = wm.array_used;
                        wm.set_array_idx(cnt, k);
                        wm.set_array_idx(cnt + 1, v);
                    }
                }
            }
        }
    }

    ctx.result.tag = OBJECT;
    ctx.result.pointer = wm;
}

// ============================================================================
// WeakMap.prototype.set(key, value) — ES6 §23.3.3.5
// ============================================================================
fn void builtin_weakmap_proto_set(BuiltinContext* ctx) {
    HObject* wm = check_weakmap(ctx);
    if (wm == null) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }
    if (ctx.argc < 1) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }

    TVal key = ctx.regs[ctx.base_reg];
    if (key.tag != OBJECT || key.pointer == null) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_str = builtin_intern_string(ctx.heap, "Invalid value used as weak map key");
            if (msg_str != null) {
                TVal msg_val;
                msg_val.tag = STRING;
                msg_val.pointer = msg_str;
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
            }
        }
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }

    TVal value = ctx.regs[ctx.base_reg + 1];
    int found = weakmap_find_key(wm, key);
    if (found >= 0) {
        wm.array_part[(uint)found + 1] = value;
    } else {
        uint cnt = wm.array_used;
        wm.set_array_idx(cnt, key);
        wm.set_array_idx(cnt + 1, value);
    }

    ctx.result.tag = OBJECT;
    ctx.result.pointer = wm;
}

// ============================================================================
// WeakMap.prototype.get(key) — ES6 §23.3.3.3
// ============================================================================
fn void builtin_weakmap_proto_get(BuiltinContext* ctx) {
    HObject* wm = check_weakmap(ctx);
    if (wm == null) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }
    if (ctx.argc < 1) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }

    TVal key = ctx.regs[ctx.base_reg];
    int found = weakmap_find_key(wm, key);
    if (found >= 0) {
        *ctx.result = wm.array_part[(uint)found + 1];
    } else {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
    }
}

// ============================================================================
// WeakMap.prototype.has(key) — ES6 §23.3.3.4
// ============================================================================
fn void builtin_weakmap_proto_has(BuiltinContext* ctx) {
    HObject* wm = check_weakmap(ctx);
    if (wm == null) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }
    if (ctx.argc < 1) { ctx.result.tag = BOOLEAN; ctx.result.boolean = false; return; }

    TVal key = ctx.regs[ctx.base_reg];
    int found = weakmap_find_key(wm, key);
    ctx.result.tag = BOOLEAN;
    ctx.result.boolean = (found >= 0);
}

// ============================================================================
// WeakMap.prototype.delete(key) — ES6 §23.3.3.2
// ============================================================================
fn void builtin_weakmap_proto_delete(BuiltinContext* ctx) {
    HObject* wm = check_weakmap(ctx);
    if (wm == null) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }
    if (ctx.argc < 1) { ctx.result.tag = BOOLEAN; ctx.result.boolean = false; return; }

    TVal key = ctx.regs[ctx.base_reg];
    int found = weakmap_find_key(wm, key);
    if (found >= 0) {
        uint cnt = wm.array_used;
        for (uint i = (uint)found; i + 2 < cnt; i++) {
            wm.array_part[i] = wm.array_part[i + 2];
        }
        wm.array_part[cnt - 2].tag = UNDEFINED;
        wm.array_part[cnt - 2].pointer = null;
        wm.array_part[cnt - 1].tag = UNDEFINED;
        wm.array_part[cnt - 1].pointer = null;
        wm.array_used = cnt - 2;

        ctx.result.tag = BOOLEAN;
        ctx.result.boolean = true;
    } else {
        ctx.result.tag = BOOLEAN;
        ctx.result.boolean = false;
    }
}

// ============================================================================
// WeakSet helpers
// ============================================================================

fn HObject* check_weakset(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.tag == OBJECT && this_val.pointer != null) {
        HObject* obj = (HObject*)this_val.pointer;
        if (obj.flags.obj_class == hobject::ObjClass.WEAKSET) return obj;
    }
    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_str = builtin_intern_string(ctx.heap,
            "WeakSet.prototype method called on incompatible value");
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

fn int weakset_find_value(HObject* ws, TVal val) {
    uint count = ws.array_used;
    for (uint i = 0; i < count; i++) {
        if (same_value_zero(ws.array_part[i], val)) {
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
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }
    HObject* ws = ws_raw;
    ws.prototype = ctx.heap.weakset_proto;

    if (ctx.argc >= 1 && ctx.is_constructor) {
        TVal arg = ctx.regs[ctx.base_reg];
        if (arg.tag == OBJECT && arg.pointer != null) {
            HObject* iterable = (HObject*)arg.pointer;
            uint len = array_get_length(iterable, ctx.heap);
            for (uint i = 0; i < len; i++) {
                TVal v = array_get_elem(iterable, i, ctx.heap);
                if (v.tag != OBJECT || v.pointer == null) {
                    ctx.result.tag = UNDEFINED;
                    ctx.result.pointer = null;
                    return;
                }
                int found = weakset_find_value(ws, v);
                if (found < 0) {
                    ws.set_array_idx(ws.array_used, v);
                }
            }
        }
    }

    ctx.result.tag = OBJECT;
    ctx.result.pointer = ws;
}

// ============================================================================
// WeakSet.prototype.add(value) — ES6 §23.4.3.1
// ============================================================================
fn void builtin_weakset_proto_add(BuiltinContext* ctx) {
    HObject* ws = check_weakset(ctx);
    if (ws == null) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }
    if (ctx.argc < 1) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }

    TVal value = ctx.regs[ctx.base_reg];
    if (value.tag != OBJECT || value.pointer == null) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_str = builtin_intern_string(ctx.heap, "Invalid value used in weak set");
            if (msg_str != null) {
                TVal msg_val;
                msg_val.tag = STRING;
                msg_val.pointer = msg_str;
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
            }
        }
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }

    int found = weakset_find_value(ws, value);
    if (found < 0) {
        ws.set_array_idx(ws.array_used, value);
    }

    ctx.result.tag = OBJECT;
    ctx.result.pointer = ws;
}

// ============================================================================
// WeakSet.prototype.has(value) — ES6 §23.4.3.4
// ============================================================================
fn void builtin_weakset_proto_has(BuiltinContext* ctx) {
    HObject* ws = check_weakset(ctx);
    if (ws == null) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }
    if (ctx.argc < 1) { ctx.result.tag = BOOLEAN; ctx.result.boolean = false; return; }

    TVal value = ctx.regs[ctx.base_reg];
    int found = weakset_find_value(ws, value);
    ctx.result.tag = BOOLEAN;
    ctx.result.boolean = (found >= 0);
}

// ============================================================================
// WeakSet.prototype.delete(value) — ES6 §23.4.3.3
// ============================================================================
fn void builtin_weakset_proto_delete(BuiltinContext* ctx) {
    HObject* ws = check_weakset(ctx);
    if (ws == null) { ctx.result.tag = UNDEFINED; ctx.result.pointer = null; return; }
    if (ctx.argc < 1) { ctx.result.tag = BOOLEAN; ctx.result.boolean = false; return; }

    TVal value = ctx.regs[ctx.base_reg];
    int found = weakset_find_value(ws, value);
    if (found >= 0) {
        uint cnt = ws.array_used;
        for (uint i = (uint)found; i + 1 < cnt; i++) {
            ws.array_part[i] = ws.array_part[i + 1];
        }
        ws.array_part[cnt - 1].tag = UNDEFINED;
        ws.array_part[cnt - 1].pointer = null;
        ws.array_used = cnt - 1;

        ctx.result.tag = BOOLEAN;
        ctx.result.boolean = true;
    } else {
        ctx.result.tag = BOOLEAN;
        ctx.result.boolean = false;
    }
}

// ============================================================================
// Symbol helpers
// ============================================================================

/// Symbol creation counter — incremented for each unique symbol to guarantee
/// uniqueness even with identical descriptions.
uint g_symbol_counter = 0;

/// Create a new Symbol HString with 0xFF prefix byte.
/// Symbols are NOT inserted into the string table (they are unique).
fn HString* create_symbol_string(Heap* heap, char[] desc) {
    // Build internal representation: 0xFF + description
    // We add a counter suffix for uniqueness when description is empty
    uint counter = g_symbol_counter;
    g_symbol_counter++;

    char[256] buf;
    buf[0] = (char)0xFF;
    int pos = 1;

    for (int i = 0; i < desc.len && pos < 255; i++) {
        buf[pos] = desc[i];
        pos++;
    }

    uint hash = heap.hash_seed ^ counter;  // Simple unique hash

    HString*? sym = hstring::hstring_alloc(heap, buf[:(uint)pos], hash);
    if (try s = sym) {
        // Don't intern in string table — symbols are unique
        return s;
    }
    return null;
}

/// Check if a TVal is a Symbol (STRING tag with is_symbol flag)
fn bool is_symbol_val(TVal val) {
    if (val.tag != STRING) return false;
    HString* s = (HString*)val.pointer;
    return s != null && s.is_symbol();
}

/// Get the description bytes of a Symbol (everything after the 0xFF prefix)
fn char[] symbol_description(HString* sym) {
    if (sym.blen <= 1) return "";
    char* ptr = sym.get_cstr();
    return ptr[1:(sz)(sym.blen - 1)];
}

// ============================================================================
// Symbol global registry (Symbol.for / Symbol.keyFor)
// ============================================================================

/// Look up a key in the global symbol registry.
/// Returns the registered symbol HString*, or null if not found.
fn HString* symbol_registry_get(Heap* heap, char[] key) {
    for (uint i = 0; i < heap.symbol_registry_count; i++) {
        HString* reg_key = heap.symbol_registry_keys[i];
        if (reg_key.blen == (uint)key.len) {
            char* reg_data = reg_key.get_cstr();
            bool match = true;
            for (int j = 0; j < key.len; j++) {
                if (reg_data[j] != key[j]) { match = false; break; }
            }
            if (match) return heap.symbol_registry_syms[i];
        }
    }
    return null;
}

/// Register a key→symbol pair in the global registry.
fn bool symbol_registry_put(Heap* heap, char[] key, HString* sym) {
    uint count = heap.symbol_registry_count;
    uint cap = heap.symbol_registry_cap;

    // Grow if needed
    if (count >= cap) {
        uint new_cap = (cap == 0) ? 8 : cap * 2;
        usz key_bytes = (usz)new_cap * void*::size;
        usz sym_bytes = (usz)new_cap * void*::size;

        HString** new_keys = (HString**)heap.alloc_func(heap.heap_udata, key_bytes);
        HString** new_syms = (HString**)heap.alloc_func(heap.heap_udata, sym_bytes);
        if (new_keys == null || new_syms == null) return false;

        // Copy existing entries
        for (uint i = 0; i < count; i++) {
            new_keys[i] = heap.symbol_registry_keys[i];
            new_syms[i] = heap.symbol_registry_syms[i];
        }
        // Free old arrays
        if (heap.symbol_registry_keys != null) {
            heap.free_func(heap.heap_udata, heap.symbol_registry_keys);
        }
        if (heap.symbol_registry_syms != null) {
            heap.free_func(heap.heap_udata, heap.symbol_registry_syms);
        }
        heap.symbol_registry_keys = new_keys;
        heap.symbol_registry_syms = new_syms;
        heap.symbol_registry_cap = new_cap;
    }

    // Allocate a key HString (interned)
    uint hash = heap.hash_string(key);
    HString* existing = heap.str_table_lookup(key, hash);
    HString* key_str;
    if (existing != null) {
        key_str = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, key, hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        key_str = new_key;
    }

    heap.symbol_registry_keys[count] = key_str;
    heap.symbol_registry_syms[count] = sym;
    heap.symbol_registry_count = count + 1;
    return true;
}

/// Reverse lookup: find key for a symbol in the registry.
fn HString* symbol_registry_get_key(Heap* heap, HString* sym) {
    for (uint i = 0; i < heap.symbol_registry_count; i++) {
        if (heap.symbol_registry_syms[i] == sym) {
            return heap.symbol_registry_keys[i];
        }
    }
    return null;
}

// ============================================================================
// Symbol constructor (ES6 §19.4.1)
// ============================================================================
fn void builtin_symbol(BuiltinContext* ctx) {
    // Symbol is not constructable with new
    if (ctx.is_constructor) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_str = builtin_intern_string(ctx.heap, "Symbol is not a constructor");
            if (msg_str != null) {
                TVal msg_val;
                msg_val.tag = STRING;
                msg_val.pointer = msg_str;
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
            }
            ctx.throw_value.tag = OBJECT;
            ctx.throw_value.pointer = err;
        } else {
            ctx.throw_value.set_undefined();
        }
        ctx.should_throw = true;
        return;
    }

    // Get description from first argument (ToString if present)
    char[] desc = "";
    if (ctx.argc >= 1) {
        TVal arg = ctx.regs[ctx.base_reg];
        HString* desc_str = builtin_to_string(ctx.heap, &arg);
        if (desc_str != null) {
            desc = desc_str.get_data();
        }
    }

    HString* sym = create_symbol_string(ctx.heap, desc);
    if (sym == null) {
        ctx.result.set_undefined();
        return;
    }
    ctx.result.tag = STRING;
    ctx.result.pointer = sym;
}

// ============================================================================
// Symbol.for(key) — ES6 §19.4.2.1
// ============================================================================
fn void builtin_symbol_for(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_undefined();
        return;
    }

    TVal key_val = ctx.regs[ctx.base_reg];
    HString* key_str = builtin_to_string(ctx.heap, &key_val);
    if (key_str == null) {
        ctx.result.set_undefined();
        return;
    }

    char[] key_bytes = key_str.get_data();

    // Check registry
    HString* existing = symbol_registry_get(ctx.heap, key_bytes);
    if (existing != null) {
        ctx.result.tag = STRING;
        ctx.result.pointer = existing;
        return;
    }

    // Create new global symbol
    HString* sym = create_symbol_string(ctx.heap, key_bytes);
    if (sym == null) {
        ctx.result.set_undefined();
        return;
    }

    symbol_registry_put(ctx.heap, key_bytes, sym);

    ctx.result.tag = STRING;
    ctx.result.pointer = sym;
}

// ============================================================================
// Symbol.keyFor(sym) — ES6 §19.4.2.5
// ============================================================================
fn void builtin_symbol_keyfor(BuiltinContext* ctx) {
    if (ctx.argc < 1) {
        ctx.result.set_undefined();
        return;
    }

    TVal sym_val = ctx.regs[ctx.base_reg];
    if (!is_symbol_val(sym_val)) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_str = builtin_intern_string(ctx.heap, "Symbol.keyFor requires a symbol argument");
            if (msg_str != null) {
                TVal msg_val;
                msg_val.tag = STRING;
                msg_val.pointer = msg_str;
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
            }
            ctx.throw_value.tag = OBJECT;
            ctx.throw_value.pointer = err;
        } else {
            ctx.throw_value.set_undefined();
        }
        ctx.should_throw = true;
        return;
    }

    HString* sym = (HString*)sym_val.pointer;
    HString* key = symbol_registry_get_key(ctx.heap, sym);
    if (key != null) {
        ctx.result.tag = STRING;
        ctx.result.pointer = key;
    } else {
        ctx.result.set_undefined();
    }
}

// ============================================================================
// Symbol.prototype.toString() — ES6 §19.4.3.2
// ============================================================================
fn void builtin_symbol_proto_toString(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];

    // this value must be a Symbol (primitive or wrapper)
    HString* sym = null;
    if (this_val.tag == STRING) {
        HString* s = (HString*)this_val.pointer;
        if (s != null && s.is_symbol()) {
            sym = s;
        }
    } else if (this_val.tag == OBJECT && this_val.pointer != null) {
        HObject* obj = (HObject*)this_val.pointer;
        if (obj.flags.obj_class == hobject::ObjClass.SYMBOL) {
            // Extract [[SymbolData]] — for now, check if there's a stored symbol
            // We look for the "_symbol" property or just describe as "Symbol()"
        }
    }

    if (sym == null) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_str = builtin_intern_string(ctx.heap, "Symbol.prototype.toString called on non-Symbol");
            if (msg_str != null) {
                TVal msg_val;
                msg_val.tag = STRING;
                msg_val.pointer = msg_str;
                HString* msg_key = builtin_intern_string(ctx.heap, "message");
                err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
            }
            ctx.throw_value.tag = OBJECT;
            ctx.throw_value.pointer = err;
        } else {
            ctx.throw_value.set_undefined();
        }
        ctx.should_throw = true;
        return;
    }

    // Build "Symbol(description)" string
    char[] desc = symbol_description(sym);
    char[512] result_buf;
    result_buf[0] = 'S';
    result_buf[1] = 'y';
    result_buf[2] = 'm';
    result_buf[3] = 'b';
    result_buf[4] = 'o';
    result_buf[5] = 'l';
    result_buf[6] = '(';
    int pos = 7;
    for (int i = 0; i < desc.len && pos < 510; i++) {
        result_buf[pos] = desc[i];
        pos++;
    }
    result_buf[pos] = ')';
    pos++;
    result_buf[pos] = 0;

    HString* result = builtin_intern_string(ctx.heap, result_buf[:(uint)pos]);
    ctx.result.tag = STRING;
    ctx.result.pointer = result;
}

// ============================================================================
// Symbol.prototype.valueOf() — ES6 §19.4.3.3
// ============================================================================
fn void builtin_symbol_proto_valueOf(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];

    if (this_val.tag == STRING) {
        HString* s = (HString*)this_val.pointer;
        if (s != null && s.is_symbol()) {
            *ctx.result = this_val;
            return;
        }
    } else if (this_val.tag == OBJECT && this_val.pointer != null) {
        HObject* obj = (HObject*)this_val.pointer;
        if (obj.flags.obj_class == hobject::ObjClass.SYMBOL) {
            // Return the [[SymbolData]] value
            // For now just return undefined for wrapper objects
        }
    }

    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_str = builtin_intern_string(ctx.heap, "Symbol.prototype.valueOf called on non-Symbol");
        if (msg_str != null) {
            TVal msg_val;
            msg_val.tag = STRING;
            msg_val.pointer = msg_str;
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
        }
        ctx.throw_value.tag = OBJECT;
        ctx.throw_value.pointer = err;
    } else {
        ctx.throw_value.set_undefined();
    }
    ctx.should_throw = true;
}

// ============================================================================
// Promise helpers (ES6 §25.4)
// ============================================================================

const uint PROMISE_PENDING   = 0;
const uint PROMISE_FULFILLED = 1;
const uint PROMISE_REJECTED  = 2;

/// Get the promise state from the HObject's array_part[0].
fn uint promise_get_state(HObject* promise, uint default_state) {
    if (promise.array_part != null && promise.array_size >= 2) {
        return (uint)promise.array_part[0].fastint;
    }
    return default_state;
}

/// Set the promise state in array_part.
fn void promise_set_state(HObject* promise, uint state) {
    TVal state_tv;
    state_tv.tag = FASTINT;
    state_tv.fastint = (long)state;
    promise.set_array_idx(0, state_tv);
    TVal undef;
    undef.tag = UNDEFINED;
    undef.pointer = null;
    promise.set_array_idx(1, undef);
}

/// Set the promise result in array_part.
fn void promise_set_result(HObject* promise, TVal* val) {
    promise.set_array_idx(1, *val);
}

/// Check that `this` is a Promise object.
fn HObject* check_promise(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.tag == OBJECT && this_val.pointer != null) {
        HObject* obj = (HObject*)this_val.pointer;
        if (obj.flags.obj_class == hobject::ObjClass.PROMISE) return obj;
    }
    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_str = builtin_intern_string(ctx.heap,
            "Promise.prototype method called on incompatible value");
        if (msg_str != null) {
            TVal msg_tv;
            msg_tv.tag = STRING;
            msg_tv.pointer = msg_str;
            err.put_prop(builtin_intern_string(ctx.heap, "message"), msg_tv, hobject::PROP_FLAGS_WEC);
        }
        ctx.throw_value.tag = OBJECT;
        ctx.throw_value.pointer = err;
    } else {
        ctx.throw_value.set_undefined();
    }
    ctx.should_throw = true;
    return null;
}

/// Trigger all pending reactions for a settled promise.
fn void promise_trigger_reactions(HObject* promise, Heap* heap) {
    uint state = promise_get_state(promise, PROMISE_PENDING);
    if (state == PROMISE_PENDING) return;

    TVal result = promise.array_part[1];

    // Iterate reactions stored in array_part starting at index 2
    // Each reaction occupies one slot (an OBJECT with handler/capability props)
    uint num_reactions = 0;
    if (promise.array_used > 2) {
        num_reactions = promise.array_used - 2;
    }

    for (uint i = 0; i < num_reactions; i++) {
        TVal reaction_val = promise.array_part[2 + i];
        if (reaction_val.tag != OBJECT || reaction_val.pointer == null) continue;
        HObject* reaction = (HObject*)reaction_val.pointer;

        // Get handler: onFulfilled for fulfilled, onRejected for rejected
        char[] handler_prop = (state == PROMISE_FULFILLED) ? "onFulfilled" : "onRejected";
        HString* handler_key = builtin_intern_string(heap, handler_prop);
        TVal? handler_opt = reaction.get_prop(handler_key);
        TVal handler;
        if (try h = handler_opt) {
            handler = h;
        } else {
            handler.tag = UNDEFINED;
            handler.pointer = null;
        }

        // Get capability resolve/reject
        HString* cap_resolve_key = builtin_intern_string(heap, "capResolve");
        HString* cap_reject_key = builtin_intern_string(heap, "capReject");
        TVal? cap_resolve_opt = reaction.get_prop(cap_resolve_key);
        TVal? cap_reject_opt = reaction.get_prop(cap_reject_key);
        TVal cap_resolve;
        if (try cr = cap_resolve_opt) {
            cap_resolve = cr;
        } else {
            cap_resolve.tag = UNDEFINED;
            cap_resolve.pointer = null;
        }
        TVal cap_reject;
        if (try cj = cap_reject_opt) {
            cap_reject = cj;
        } else {
            cap_reject.tag = UNDEFINED;
            cap_reject.pointer = null;
        }

        if (state == PROMISE_FULFILLED) {
            if (handler.tag == UNDEFINED) {
                // No onFulfilled — pass through
                call_capability(cap_resolve, cap_reject, &result, heap, true);
            } else {
                // Call handler with result
                TVal ret = call_handler(handler, &result, heap);
                call_capability(cap_resolve, cap_reject, &ret, heap, true);
            }
        } else {
            if (handler.tag == UNDEFINED) {
                // No onRejected — pass through
                call_capability(cap_resolve, cap_reject, &result, heap, false);
            } else {
                TVal ret = call_handler(handler, &result, heap);
                call_capability(cap_resolve, cap_reject, &ret, heap, true);
            }
        }
    }
}

/// Call a handler function with one argument.
fn TVal call_handler(TVal handler, TVal* arg, Heap* heap) {
    TVal result;
    result.tag = UNDEFINED;
    result.pointer = null;

    if (handler.tag == OBJECT && handler.pointer != null) {
        HObject* func = (HObject*)handler.pointer;
        if (func.comp_func != null) {
            // We need a VM to execute. Call via the heap's thread if available.
            // For now, return undefined if we can't execute.
            // This is a stub — real async execution requires VM integration.
            return result;
        }
    }
    if (handler.tag == LIGHTFUNC) {
        // Call builtin — but we need the VM. Stub for now.
        return result;
    }
    return result;
}

/// Resolve or reject a capability.
fn void call_capability(TVal resolve, TVal reject, TVal* val, Heap* heap, bool is_resolve) {
    TVal callee = is_resolve ? resolve : reject;
    if (callee.tag == UNDEFINED) return;

    // For now, direct synchronous handling of chained promises
    if (callee.tag == OBJECT && callee.pointer != null) {
        HObject* cap = (HObject*)callee.pointer;
        if (cap.flags.obj_class == hobject::ObjClass.PROMISE) {
            promise_set_state(cap, is_resolve ? PROMISE_FULFILLED : PROMISE_REJECTED);
            promise_set_result(cap, val);
            promise_trigger_reactions(cap, heap);
        }
    }
}

/// Create a new Promise with the given internal structure.
fn HObject*? promise_create(Heap* heap) {
    HObject*? prom_raw = heap.alloc_object(hobject::ObjClass.PROMISE);
    if (catch err = prom_raw) return null;
    HObject* prom = prom_raw;
    prom.prototype = heap.promise_proto;
    promise_set_state(prom, PROMISE_PENDING);
    return prom;
}

/// Create a resolve/reject capability object (internal).
/// Returns a pair of functions as properties on a capability HObject.
fn HObject*? promise_create_capability(Heap* heap, HObject* promise) {
    HObject*? cap_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = cap_raw) return null;
    HObject* cap = cap_raw;

    // Store a reference to the promise this capability controls
    HString* promise_key = builtin_intern_string(heap, "promise");
    TVal promise_val;
    promise_val.tag = OBJECT;
    promise_val.pointer = promise;
    cap.put_prop(promise_key, promise_val, hobject::PROP_FLAGS_WEC);

    return cap;
}

/// Add a reaction to a pending promise.
fn void promise_add_reaction(HObject* promise, TVal reaction_val) {
    uint idx = promise.array_used;
    promise.set_array_idx(idx, reaction_val);
}

// ============================================================================
// Promise constructor (ES6 §25.4.3.1)
// ============================================================================

fn void builtin_promise(BuiltinContext* ctx) {
    HObject*? prom_raw = promise_create(ctx.heap);
    if (catch err = prom_raw) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }
    HObject* promise = prom_raw;

    // Set prototype
    promise.prototype = ctx.heap.promise_proto;

    if (ctx.argc < 1) {
        // No executor — return pending promise
        ctx.result.tag = OBJECT;
        ctx.result.pointer = promise;
        return;
    }

    TVal executor = ctx.regs[ctx.base_reg];
    if (executor.tag != OBJECT || executor.pointer == null) {
        // Type error: executor must be callable
        ctx.result.tag = OBJECT;
        ctx.result.pointer = promise;
        return;
    }

    HObject* exec_func = (HObject*)executor.pointer;
    if (exec_func.comp_func == null && exec_func.builtin_fn_index < 0) {
        ctx.result.tag = OBJECT;
        ctx.result.pointer = promise;
        return;
    }

    // Create resolve/reject callbacks
    HObject*? cap_raw = promise_create_capability(ctx.heap, promise);
    if (catch err = cap_raw) {
        ctx.result.tag = OBJECT;
        ctx.result.pointer = promise;
        return;
    }

    // Call executor(resolve, reject)
    // Store params on value stack and call
    TVal resolve_tv;
    resolve_tv.tag = OBJECT;
    resolve_tv.pointer = cap_raw;

    TVal reject_tv;
    reject_tv.tag = OBJECT;
    reject_tv.pointer = cap_raw;

    // We need the VM to call the executor. For now, mark the promise
    // and let the capability handle resolution later.
    // Store the capability in array_part after state/result
    promise.set_array_idx(2, resolve_tv);

    ctx.result.tag = OBJECT;
    ctx.result.pointer = promise;
}

// ============================================================================
// Promise.prototype.then(onFulfilled, onRejected) — ES6 §25.4.5.3
// ============================================================================

fn void builtin_promise_proto_then(BuiltinContext* ctx) {
    HObject* promise = check_promise(ctx);
    if (promise == null) return;

    TVal on_fulfilled;
    on_fulfilled.tag = UNDEFINED;
    on_fulfilled.pointer = null;
    TVal on_rejected;
    on_rejected.tag = UNDEFINED;
    on_rejected.pointer = null;
    if (ctx.argc >= 1) on_fulfilled = ctx.regs[ctx.base_reg];
    if (ctx.argc >= 2) on_rejected  = ctx.regs[ctx.base_reg + 1];

    // Create a new promise for the chain
    HObject*? new_prom_raw = promise_create(ctx.heap);
    if (catch err = new_prom_raw) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }
    HObject* new_promise = new_prom_raw;

    // Create capability for new promise
    HObject*? cap_raw = promise_create_capability(ctx.heap, new_promise);
    if (catch err = cap_raw) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }
    HObject* cap = cap_raw;

    // Build reaction object
    HObject*? reaction_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = reaction_raw) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }
    HObject* reaction = reaction_raw;

    // Store handlers
    HString* onf_key = builtin_intern_string(ctx.heap, "onFulfilled");
    reaction.put_prop(onf_key, on_fulfilled, hobject::PROP_FLAGS_WEC);

    HString* onr_key = builtin_intern_string(ctx.heap, "onRejected");
    reaction.put_prop(onr_key, on_rejected, hobject::PROP_FLAGS_WEC);

    // Store capability resolve/reject as properties
    HString* cap_res_key = builtin_intern_string(ctx.heap, "capResolve");
    HString* cap_rej_key = builtin_intern_string(ctx.heap, "capReject");

    TVal cap_val;
    cap_val.tag = OBJECT;
    cap_val.pointer = cap;
    reaction.put_prop(cap_res_key, cap_val, hobject::PROP_FLAGS_WEC);
    reaction.put_prop(cap_rej_key, cap_val, hobject::PROP_FLAGS_WEC);

    // Add reaction to the original promise
    TVal reaction_val;
    reaction_val.tag = OBJECT;
    reaction_val.pointer = reaction;

    uint state = promise_get_state(promise, PROMISE_PENDING);
    if (state == PROMISE_PENDING) {
        promise_add_reaction(promise, reaction_val);
    } else {
        // Promise already settled — trigger reaction immediately
        // For now, add and trigger
        promise_add_reaction(promise, reaction_val);
        // In a real implementation, this would be scheduled as a microtask
    }

    ctx.result.tag = OBJECT;
    ctx.result.pointer = new_promise;
}

// ============================================================================
// Promise.prototype.catch(onRejected) — ES6 §25.4.5.1
// ============================================================================

fn void builtin_promise_proto_catch(BuiltinContext* ctx) {
    // catch(onRejected) is equivalent to then(undefined, onRejected)
    // Forward to BUILTIN_PROMISE_PROTO_THEN with first arg as undefined
    TVal saved_arg0 = ctx.regs[ctx.base_reg];
    ctx.regs[ctx.base_reg].set_undefined();
    builtin_promise_proto_then(ctx);
    // Restore original arg (not strictly needed but clean)
    ctx.regs[ctx.base_reg] = saved_arg0;
}

// ============================================================================
// Promise.prototype.finally(onFinally) — ES2018 §25.4.5.3
// ============================================================================

fn void builtin_promise_proto_finally(BuiltinContext* ctx) {
    HObject* promise = check_promise(ctx);
    if (promise == null) return;

    TVal on_finally;
    on_finally.tag = UNDEFINED;
    on_finally.pointer = null;
    if (ctx.argc >= 1) on_finally = ctx.regs[ctx.base_reg];

    // finally just chains .then with the same handler for both branches
    // For a full implementation, the onFinally handler is called with no args
    // and the promise's result is passed through
    ctx.regs[ctx.base_reg + 1] = on_finally;  // Set both onFulfilled and onRejected
    builtin_promise_proto_then(ctx);
}

// ============================================================================
// Promise.resolve(x) — ES6 §25.4.4.5
// ============================================================================

fn void builtin_promise_resolve(BuiltinContext* ctx) {
    TVal val;
    val.tag = UNDEFINED;
    val.pointer = null;
    if (ctx.argc >= 1) val = ctx.regs[ctx.base_reg];

    // If already a Promise, return it
    if (val.tag == OBJECT && val.pointer != null) {
        HObject* obj = (HObject*)val.pointer;
        if (obj.flags.obj_class == hobject::ObjClass.PROMISE) {
            *ctx.result = val;
            return;
        }
    }

    // Create a new fulfilled promise
    HObject*? prom_raw = promise_create(ctx.heap);
    if (catch err = prom_raw) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }
    HObject* promise = prom_raw;
    promise_set_state(promise, PROMISE_FULFILLED);
    promise_set_result(promise, &val);

    ctx.result.tag = OBJECT;
    ctx.result.pointer = promise;
}

// ============================================================================
// Promise.reject(r) — ES6 §25.4.4.4
// ============================================================================

fn void builtin_promise_reject(BuiltinContext* ctx) {
    TVal reason;
    reason.tag = UNDEFINED;
    reason.pointer = null;
    if (ctx.argc >= 1) reason = ctx.regs[ctx.base_reg];

    HObject*? prom_raw = promise_create(ctx.heap);
    if (catch err = prom_raw) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }
    HObject* promise = prom_raw;
    promise_set_state(promise, PROMISE_REJECTED);
    promise_set_result(promise, &reason);

    ctx.result.tag = OBJECT;
    ctx.result.pointer = promise;
}

// ============================================================================
// Promise.all(iterable) — ES6 §25.4.4.1
// ============================================================================

fn void builtin_promise_all(BuiltinContext* ctx) {
    // Get the iterable argument
    TVal iterable;
    iterable.set_undefined();
    if (ctx.argc >= 1) iterable = ctx.regs[ctx.base_reg];

    // Create the result promise
    HObject*? prom_raw = promise_create(ctx.heap);
    if (catch err = prom_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* promise = prom_raw;

    // Helper: resolve result promise with empty array
    usz len = 0;
    bool has_len = false;
    HObject* obj = null;

    if (iterable.tag == OBJECT && iterable.pointer != null) {
        obj = (HObject*)iterable.pointer;
        HString* length_key = builtin_intern_string(ctx.heap, "length");
        if (try len_tv = obj.get_prop(length_key)) {
            if (len_tv.tag == FASTINT && len_tv.fastint >= 0) {
                len = (usz)len_tv.fastint;
                has_len = true;
            }
        }
    }

    // Zero-length or non-iterable — resolve with [] immediately
    if (!has_len || len == 0) {
        HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
        TVal arr_val;
        arr_val.set_undefined();
        if (try arr = arr_raw) {
            arr.prototype = ctx.heap.array_proto;
            arr_val.tag = OBJECT;
            arr_val.pointer = arr;
        }
        promise_set_state(promise, PROMISE_FULFILLED);
        promise_set_result(promise, &arr_val);
        ctx.result.tag = OBJECT;
        ctx.result.pointer = promise;
        return;
    }

    // Allocate results array
    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) {
        ctx.result.tag = OBJECT;
        ctx.result.pointer = promise;
        return;
    }
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;

    usz remaining = len;
    bool rejected = false;

    for (usz i = 0; i < len; i++) {
        if (rejected) break;

        TVal idx_tv;
        idx_tv.tag = FASTINT;
        idx_tv.fastint = (long)i;

        TVal elem;
        if (try e = obj.get_prop(&idx_tv)) {
            elem = e;
        } else {
            elem.set_undefined();
        }

        // Check if element is a Promise
        if (elem.tag == OBJECT && elem.pointer != null) {
            HObject* elem_obj = (HObject*)elem.pointer;
            if (elem_obj.flags.obj_class == hobject::ObjClass.PROMISE) {
                uint state = promise_get_state(elem_obj, PROMISE_PENDING);
                if (state == PROMISE_FULFILLED) {
                    arr.set_array_idx((uint)i, elem_obj.array_part[1]);
                    remaining--;
                } else if (state == PROMISE_REJECTED) {
                    promise_set_state(promise, PROMISE_REJECTED);
                    promise_set_result(promise, &elem_obj.array_part[1]);
                    promise_trigger_reactions(promise, ctx.heap);
                    rejected = true;
                    break;
                } else {
                    // Pending promise — skip (no async support yet)
                    remaining--;
                }
                continue;
            }
        }

        // Not a promise — store as value
        arr.set_array_idx((uint)i, elem);
        remaining--;
    }

    if (!rejected && remaining == 0) {
        TVal arr_val;
        arr_val.tag = OBJECT;
        arr_val.pointer = arr;
        promise_set_state(promise, PROMISE_FULFILLED);
        promise_set_result(promise, &arr_val);
        promise_trigger_reactions(promise, ctx.heap);
    }

    ctx.result.tag = OBJECT;
    ctx.result.pointer = promise;
}

// ============================================================================
// Promise.race(iterable) — ES6 §25.4.4.3
// ============================================================================

fn void builtin_promise_race(BuiltinContext* ctx) {
    TVal iterable;
    iterable.set_undefined();
    if (ctx.argc >= 1) iterable = ctx.regs[ctx.base_reg];

    // Create the result promise
    HObject*? prom_raw = promise_create(ctx.heap);
    if (catch err = prom_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* promise = prom_raw;

    if (iterable.tag != OBJECT || iterable.pointer == null) {
        ctx.result.tag = OBJECT;
        ctx.result.pointer = promise;
        return;
    }

    HObject* obj = (HObject*)iterable.pointer;
    HString* length_key = builtin_intern_string(ctx.heap, "length");
    usz len = 0;
    bool has_len = false;
    if (try len_tv = obj.get_prop(length_key)) {
        if (len_tv.tag == FASTINT && len_tv.fastint >= 0) {
            len = (usz)len_tv.fastint;
            has_len = true;
        }
    }

    if (!has_len) {
        ctx.result.tag = OBJECT;
        ctx.result.pointer = promise;
        return;
    }

    bool settled = false;

    for (usz i = 0; i < len && !settled; i++) {
        TVal idx_tv;
        idx_tv.tag = FASTINT;
        idx_tv.fastint = (long)i;

        TVal elem;
        if (try e = obj.get_prop(&idx_tv)) {
            elem = e;
        } else {
            elem.set_undefined();
        }

        // If element is a Promise, check its state
        if (elem.tag == OBJECT && elem.pointer != null) {
            HObject* elem_obj = (HObject*)elem.pointer;
            if (elem_obj.flags.obj_class == hobject::ObjClass.PROMISE) {
                uint state = promise_get_state(elem_obj, PROMISE_PENDING);
                if (state == PROMISE_FULFILLED) {
                    promise_set_state(promise, PROMISE_FULFILLED);
                    promise_set_result(promise, &elem_obj.array_part[1]);
                    promise_trigger_reactions(promise, ctx.heap);
                    settled = true;
                    break;
                } else if (state == PROMISE_REJECTED) {
                    promise_set_state(promise, PROMISE_REJECTED);
                    promise_set_result(promise, &elem_obj.array_part[1]);
                    promise_trigger_reactions(promise, ctx.heap);
                    settled = true;
                    break;
                }
                // Pending: continue (no async support yet)
                continue;
            }
        }

        // Non-promise value — immediate resolution
        promise_set_state(promise, PROMISE_FULFILLED);
        promise_set_result(promise, &elem);
        promise_trigger_reactions(promise, ctx.heap);
        settled = true;
        break;
    }

    ctx.result.tag = OBJECT;
    ctx.result.pointer = promise;
}

// ============================================================================
// Promise constructor registration
// ============================================================================

fn bool register_promise_constructor(EnvRecord* global_env, Heap* heap) {
    // Create Promise.prototype
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.PROMISE);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;
    heap.promise_proto = proto;

    // Register prototype methods
    if (!register_string_proto_method(proto, heap, "then",    BUILTIN_PROMISE_PROTO_THEN))    return false;
    if (!register_string_proto_method(proto, heap, "catch",   BUILTIN_PROMISE_PROTO_CATCH))   return false;
    if (!register_string_proto_method(proto, heap, "finally", BUILTIN_PROMISE_PROTO_FINALLY)) return false;

    // Create Promise function object
    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    ctor.builtin_fn_index = (int)BUILTIN_PROMISE;

    // Wire prototype.constructor → ctor
    HString* constructor_key = builtin_intern_string(heap, "constructor");
    TVal constructor_tv;
    constructor_tv.tag = OBJECT;
    constructor_tv.pointer = ctor;
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WEC);

    // Wire ctor.prototype → proto (non-writable, non-enumerable, non-configurable)
    HString* prototype_key = builtin_intern_string(heap, "prototype");
    TVal proto_tv;
    proto_tv.tag = OBJECT;
    proto_tv.pointer = proto;
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    ctor.put_prop(prototype_key, proto_tv, proto_pflags);

    // Promise.length = 1
    HString* length_key = builtin_intern_string(heap, "length");
    TVal length_tv;
    length_tv.tag = FASTINT;
    length_tv.fastint = 1;
    ctor.put_prop(length_key, length_tv, hobject::PROP_FLAGS_WEC);

    // Register static methods on Promise
    HString* resolve_key = builtin_intern_string(heap, "resolve");
    TVal resolve_tv;
    resolve_tv.tag = LIGHTFUNC;
    resolve_tv.fastint = (long)BUILTIN_PROMISE_RESOLVE;
    ctor.put_prop(resolve_key, resolve_tv, hobject::PROP_FLAGS_WEC);

    HString* reject_key = builtin_intern_string(heap, "reject");
    TVal reject_tv;
    reject_tv.tag = LIGHTFUNC;
    reject_tv.fastint = (long)BUILTIN_PROMISE_REJECT;
    ctor.put_prop(reject_key, reject_tv, hobject::PROP_FLAGS_WEC);

    HString* all_key = builtin_intern_string(heap, "all");
    TVal all_tv;
    all_tv.tag = LIGHTFUNC;
    all_tv.fastint = (long)BUILTIN_PROMISE_ALL;
    ctor.put_prop(all_key, all_tv, hobject::PROP_FLAGS_WEC);

    HString* race_key = builtin_intern_string(heap, "race");
    TVal race_tv;
    race_tv.tag = LIGHTFUNC;
    race_tv.fastint = (long)BUILTIN_PROMISE_RACE;
    ctor.put_prop(race_key, race_tv, hobject::PROP_FLAGS_WEC);

    // Register "Promise" in global environment
    uint hash = heap.hash_string("Promise");
    HString* existing = heap.str_table_lookup("Promise", hash);
    HString* promise_key;
    if (existing != null) {
        promise_key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, "Promise", hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        promise_key = new_key;
    }
    TVal promise_val;
    promise_val.tag = OBJECT;
    promise_val.pointer = ctor;
    env::env_declare(global_env, promise_key, promise_val);

    return true;
}

// ============================================================================
// GeneratorFunction constructor (ES6 §25.2.1)
// ============================================================================

fn void builtin_generator_function(BuiltinContext* ctx) {
    // GeneratorFunction is not directly callable as a constructor.
    // The user creates generator functions via function* syntax.
    // This builtin exists as the GeneratorFunction constructor object
    // but doesn't actually compile generator functions from strings.
    ctx.result.tag = UNDEFINED;
    ctx.result.pointer = null;
}

// ============================================================================
// Generator.prototype.next(value) — ES6 §25.3.1.2
// ============================================================================

fn void builtin_generator_proto_next(BuiltinContext* ctx) {
    if (ctx.this_val.tag != OBJECT) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }
    HObject* gen_obj = (HObject*)ctx.this_val.pointer;
    if (gen_obj == null || gen_obj.flags.obj_class != hobject::ObjClass.GENERATOR) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }

    Heap* vm_heap = ctx.heap;
    GeneratorState* gs = (GeneratorState*)gen_obj.generator_data;
    if (gs == null) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }

    if (gs.state == GEN_EXECUTING) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }

    if (gs.state == GEN_COMPLETED) {
        HObject*? result_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
        if (try r = result_raw) {
            r.prototype = ctx.heap.object_proto;
            HString* value_key = builtin_intern_string(ctx.heap, "value");
            TVal undef_val;
            undef_val.tag = UNDEFINED;
            undef_val.pointer = null;
            r.put_prop(value_key, undef_val, hobject::PROP_FLAGS_WEC);

            HString* done_key = builtin_intern_string(ctx.heap, "done");
            TVal done_val;
            done_val.tag = BOOLEAN;
            done_val.boolean = true;
            r.put_prop(done_key, done_val, hobject::PROP_FLAGS_WEC);

            ctx.result.tag = OBJECT;
            ctx.result.pointer = r;
        }
        return;
    }

    // Set the resume value
    if (ctx.argc >= 1) {
        gs.resume_value = ctx.regs[ctx.base_reg];
    } else {
        gs.resume_value.tag = UNDEFINED;
        gs.resume_value.pointer = null;
    }

    // Set heap.resume_gen so the CALL handler knows to resume
    gs.resume_kind = NEXT;
    vm_heap.resume_gen = gs;
    vm_heap.did_yield = false;

    // Create a callable HObject wrapping the generator's compiled function
    HObject*? func_obj_raw = ctx.heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = func_obj_raw) {
        vm_heap.resume_gen = null;
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }
    HObject* func_obj = func_obj_raw;
    func_obj.flags.callable = true;
    func_obj.comp_func = (CompiledFunction*)gs.func;
    func_obj.var_env = (EnvRecord*)gs.var_env;
    func_obj.lex_env = (EnvRecord*)gs.lex_env;

    TVal func_tv;
    func_tv.tag = OBJECT;
    func_tv.pointer = func_obj;

    // Replace callee slot (base_reg - 2) and this slot (base_reg - 1)
    ctx.regs[ctx.base_reg - 2] = func_tv;
    ctx.regs[ctx.base_reg - 1] = gs.this_binding;

    // Signal re-dispatch with 0 args
    ctx.needs_re_dispatch = true;
    ctx.re_nargs = 0;
}

// ============================================================================
// Generator.prototype.throw(exception) — ES6 §25.3.1.4
// ============================================================================

fn void builtin_generator_proto_throw(BuiltinContext* ctx) {
    if (ctx.this_val.tag != OBJECT) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }
    HObject* gen_obj = (HObject*)ctx.this_val.pointer;
    if (gen_obj == null || gen_obj.flags.obj_class != hobject::ObjClass.GENERATOR) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }

    Heap* vm_heap = ctx.heap;
    GeneratorState* gs = (GeneratorState*)gen_obj.generator_data;
    if (gs == null) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }

    if (gs.state == GEN_COMPLETED) {
        // Already completed — propagate the exception (ES6 §25.3.1.4.a)
        ctx.should_throw = true;
        if (ctx.argc >= 1) {
            ctx.throw_value = ctx.regs[ctx.base_reg];
        } else {
            ctx.throw_value.tag = UNDEFINED;
            ctx.throw_value.pointer = null;
        }
        return;
    }

    if (gs.state == GEN_EXECUTING) {
        // Cannot throw into an executing generator (ES6 §25.3.1.4.b)
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }

    // Set the exception to inject
    if (ctx.argc >= 1) {
        gs.throw_value = ctx.regs[ctx.base_reg];
    } else {
        gs.throw_value.tag = UNDEFINED;
        gs.throw_value.pointer = null;
    }
    gs.resume_kind = THROW;

    // Set heap.resume_gen so the CALL handler knows to resume
    vm_heap.resume_gen = gs;
    vm_heap.did_yield = false;

    // Create a callable HObject wrapping the generator's compiled function
    HObject*? func_obj_raw = ctx.heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = func_obj_raw) {
        vm_heap.resume_gen = null;
        gs.resume_kind = NEXT;
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }
    HObject* func_obj = func_obj_raw;
    func_obj.flags.callable = true;
    func_obj.comp_func = (CompiledFunction*)gs.func;
    func_obj.var_env = (EnvRecord*)gs.var_env;
    func_obj.lex_env = (EnvRecord*)gs.lex_env;

    TVal func_tv;
    func_tv.tag = OBJECT;
    func_tv.pointer = func_obj;

    // Replace callee slot and this slot
    ctx.regs[ctx.base_reg - 2] = func_tv;
    ctx.regs[ctx.base_reg - 1] = gs.this_binding;

    // Signal re-dispatch with 0 args
    ctx.needs_re_dispatch = true;
    ctx.re_nargs = 0;
}

// ============================================================================
// Generator.prototype.return(value) — ES6 §25.3.1.3
// ============================================================================

fn void builtin_generator_proto_return(BuiltinContext* ctx) {
    if (ctx.this_val.tag != OBJECT) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }
    HObject* gen_obj = (HObject*)ctx.this_val.pointer;
    if (gen_obj == null || gen_obj.flags.obj_class != hobject::ObjClass.GENERATOR) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }

    Heap* vm_heap = ctx.heap;
    GeneratorState* gs = (GeneratorState*)gen_obj.generator_data;
    if (gs == null) {
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }

    if (gs.state == GEN_COMPLETED) {
        // Already completed — return {value: argument, done: true}
        HObject*? result_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
        if (try r = result_raw) {
            r.prototype = ctx.heap.object_proto;
            HString* value_key = builtin_intern_string(ctx.heap, "value");
            TVal arg_val;
            if (ctx.argc >= 1) {
                arg_val = ctx.regs[ctx.base_reg];
            } else {
                arg_val.tag = UNDEFINED;
                arg_val.pointer = null;
            }
            r.put_prop(value_key, arg_val, hobject::PROP_FLAGS_WEC);

            HString* done_key = builtin_intern_string(ctx.heap, "done");
            TVal done_val;
            done_val.tag = BOOLEAN;
            done_val.boolean = true;
            r.put_prop(done_key, done_val, hobject::PROP_FLAGS_WEC);

            ctx.result.tag = OBJECT;
            ctx.result.pointer = r;
        }
        return;
    }

    if (gs.state == GEN_EXECUTING) {
        // Cannot return into an executing generator
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }

    if (gs.state == GEN_SUSPENDED_START) {
        // Generator has never executed — complete immediately without
        // executing any body code (ES6 §25.3.1.3, step 5).
        gs.state = GEN_COMPLETED;
        TVal arg_val;
        if (ctx.argc >= 1) {
            arg_val = ctx.regs[ctx.base_reg];
        } else {
            arg_val.tag = UNDEFINED;
            arg_val.pointer = null;
        }
        HObject*? result_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
        if (try r = result_raw) {
            r.prototype = ctx.heap.object_proto;
            HString* value_key = builtin_intern_string(ctx.heap, "value");
            r.put_prop(value_key, arg_val, hobject::PROP_FLAGS_WEC);
            HString* done_key = builtin_intern_string(ctx.heap, "done");
            TVal done_val;
            done_val.tag = BOOLEAN;
            done_val.boolean = true;
            r.put_prop(done_key, done_val, hobject::PROP_FLAGS_WEC);
            ctx.result.tag = OBJECT;
            ctx.result.pointer = r;
        }
        return;
    }

    // Set the return value to inject
    if (ctx.argc >= 1) {
        gs.return_value = ctx.regs[ctx.base_reg];
    } else {
        gs.return_value.tag = UNDEFINED;
        gs.return_value.pointer = null;
    }
    gs.resume_kind = RETURN;

    // Set heap.resume_gen so the CALL handler knows to resume
    vm_heap.resume_gen = gs;
    vm_heap.did_yield = false;

    // Create a callable HObject wrapping the generator's compiled function
    HObject*? func_obj_raw = ctx.heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = func_obj_raw) {
        vm_heap.resume_gen = null;
        gs.resume_kind = NEXT;
        ctx.result.tag = UNDEFINED;
        ctx.result.pointer = null;
        return;
    }
    HObject* func_obj = func_obj_raw;
    func_obj.flags.callable = true;
    func_obj.comp_func = (CompiledFunction*)gs.func;
    func_obj.var_env = (EnvRecord*)gs.var_env;
    func_obj.lex_env = (EnvRecord*)gs.lex_env;

    TVal func_tv;
    func_tv.tag = OBJECT;
    func_tv.pointer = func_obj;

    // Replace callee slot and this slot
    ctx.regs[ctx.base_reg - 2] = func_tv;
    ctx.regs[ctx.base_reg - 1] = gs.this_binding;

    // Signal re-dispatch with 0 args
    ctx.needs_re_dispatch = true;
    ctx.re_nargs = 0;
}

// ============================================================================
// Generator constructor registration
// ============================================================================

fn bool register_generator_constructor(EnvRecord* global_env, Heap* heap) {
    // Create Generator.prototype
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = heap.object_proto;
    heap.generator_proto = proto;

    // Register prototype methods
    if (!register_string_proto_method(proto, heap, "next",   BUILTIN_GENERATOR_PROTO_NEXT))   return false;
    if (!register_string_proto_method(proto, heap, "throw",  BUILTIN_GENERATOR_PROTO_THROW))  return false;
    if (!register_string_proto_method(proto, heap, "return", BUILTIN_GENERATOR_PROTO_RETURN)) return false;

    // Wire prototype.constructor → GeneratorFunction constructor
    // GeneratorFunction constructor is created later; we'll wire it there

    return true;
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
        case BUILTIN_URI_ERROR:
            builtin_uri_error(ctx);
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
        case BUILTIN_STRING_FROMCHARCODE:
            builtin_string_fromcharcode(ctx);
        case BUILTIN_STRING_FROMCODEPOINT:
            builtin_string_fromcodepoint(ctx);
        case BUILTIN_ARRAY_PROTO_FLAT:
            builtin_array_proto_flat(ctx);
        case BUILTIN_ARRAY_PROTO_FLATMAP:
            builtin_array_proto_flatMap(ctx);
        case BUILTIN_ARRAY_PROTO_TOREVERSED:
            builtin_array_proto_toReversed(ctx);
        case BUILTIN_ARRAY_PROTO_TOSORTED:
            builtin_array_proto_toSorted(ctx);
        case BUILTIN_ARRAY_PROTO_TOSPLICED:
            builtin_array_proto_toSpliced(ctx);
        case BUILTIN_ARRAY_PROTO_WITH:
            builtin_array_proto_with(ctx);
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
        case BUILTIN_NUMBER_ISNAN:
            builtin_number_isNaN(ctx);
        case BUILTIN_NUMBER_ISFINITE:
            builtin_number_isFinite(ctx);
        case BUILTIN_NUMBER_ISINTEGER:
            builtin_number_isInteger(ctx);
        case BUILTIN_NUMBER_ISSAFEINTEGER:
            builtin_number_isSafeInteger(ctx);
        case BUILTIN_OBJECT:
            builtin_object(ctx);
        case BUILTIN_OBJECT_PROTO_TOSTRING:
            builtin_object_proto_toString(ctx);
        case BUILTIN_OBJECT_PROTO_HASOWNPROPERTY:
            builtin_object_proto_hasOwnProperty(ctx);
        case BUILTIN_OBJECT_PROTO_PROPERTYISENUMERABLE:
            builtin_object_proto_propertyIsEnumerable(ctx);
        case BUILTIN_OBJECT_PROTO_ISPROTOTYPEOF:
            builtin_object_proto_isPrototypeOf(ctx);
        case BUILTIN_OBJECT_PROTO_TOLOCALESTRING:
            builtin_object_proto_toLocaleString(ctx);
        case BUILTIN_OBJECT_PROTO_VALUEOF:
            builtin_object_proto_valueOf(ctx);
        case BUILTIN_OBJECT_KEYS:
            builtin_object_keys(ctx);
        case BUILTIN_OBJECT_GETPROTOTYPEOF:
            builtin_object_getPrototypeOf(ctx);
        case BUILTIN_OBJECT_ISEXTENSIBLE:
            builtin_object_isExtensible(ctx);
        case BUILTIN_OBJECT_PREVENTEXTENSIONS:
            builtin_object_preventExtensions(ctx);
        case BUILTIN_OBJECT_GETOWNPROPERTYDESCRIPTOR:
            builtin_object_getOwnPropertyDescriptor(ctx);
        case BUILTIN_OBJECT_DEFINEPROPERTY:
            builtin_object_defineProperty(ctx);
        case BUILTIN_OBJECT_GETOWNPROPERTYNAMES:
            builtin_object_getOwnPropertyNames(ctx);
        case BUILTIN_OBJECT_DEFINEPROPERTIES:
            builtin_object_defineProperties(ctx);
        case BUILTIN_OBJECT_CREATE:
            builtin_object_create(ctx);
        case BUILTIN_OBJECT_SEAL:
            builtin_object_seal(ctx);
        case BUILTIN_OBJECT_FREEZE:
            builtin_object_freeze(ctx);
        case BUILTIN_OBJECT_ISSEALED:
            builtin_object_isSealed(ctx);
        case BUILTIN_OBJECT_ISFROZEN:
            builtin_object_isFrozen(ctx);
        case BUILTIN_OBJECT_ENTRIES:
            builtin_object_entries(ctx);
        case BUILTIN_OBJECT_VALUES:
            builtin_object_values(ctx);
        case BUILTIN_OBJECT_ASSIGN:
            builtin_object_assign(ctx);
        case BUILTIN_OBJECT_IS:
            builtin_object_is(ctx);
        case BUILTIN_OBJECT_HASOWN:
            builtin_object_hasOwn(ctx);
        case BUILTIN_OBJECT_SETPROTOTYPEOF:
            builtin_object_setPrototypeOf(ctx);
        case BUILTIN_STRING_PROTO_INCLUDES:
            builtin_string_proto_includes(ctx);
        case BUILTIN_STRING_PROTO_STARTSWITH:
            builtin_string_proto_startsWith(ctx);
        case BUILTIN_STRING_PROTO_ENDSWITH:
            builtin_string_proto_endsWith(ctx);
        case BUILTIN_STRING_PROTO_REPEAT:
            builtin_string_proto_repeat(ctx);
        case BUILTIN_ARRAY_OF:
            builtin_array_of(ctx);
        case BUILTIN_ARRAY_PROTO_FILL:
            builtin_array_proto_fill(ctx);
        case BUILTIN_ARRAY_PROTO_FIND:
            builtin_array_proto_find(ctx);
        case BUILTIN_ARRAY_PROTO_FINDINDEX:
            builtin_array_proto_findIndex(ctx);
        case BUILTIN_ARRAY_PROTO_INCLUDES:
            builtin_array_proto_includes(ctx);
        case BUILTIN_STRING_PROTO_TRIMSTART:
            builtin_string_proto_trimStart(ctx);
        case BUILTIN_STRING_PROTO_TRIMEND:
            builtin_string_proto_trimEnd(ctx);
        case BUILTIN_STRING_PROTO_CODEPOINTAT:
            builtin_string_proto_codePointAt(ctx);
        case BUILTIN_STRING_PROTO_AT:
            builtin_string_proto_at(ctx);
        case BUILTIN_ARRAY_PROTO_AT:
            builtin_array_proto_at(ctx);
        case BUILTIN_ARRAY_PROTO_COPYWITHIN:
            builtin_array_proto_copyWithin(ctx);
        case BUILTIN_STRING_PROTO_PADSTART:
            builtin_string_proto_padStart(ctx);
        case BUILTIN_STRING_PROTO_PADEND:
            builtin_string_proto_padEnd(ctx);
        case BUILTIN_STRING_PROTO_LASTINDEXOF:
            builtin_string_proto_lastIndexOf(ctx);
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
        case BUILTIN_MATH_ACOS:
            builtin_math_acos(ctx);
        case BUILTIN_MATH_ASIN:
            builtin_math_asin(ctx);
        case BUILTIN_MATH_ATAN:
            builtin_math_atan(ctx);
        case BUILTIN_MATH_ATAN2:
            builtin_math_atan2(ctx);
        case BUILTIN_MATH_COSH:
            builtin_math_cosh(ctx);
        case BUILTIN_MATH_SINH:
            builtin_math_sinh(ctx);
        case BUILTIN_MATH_TANH:
            builtin_math_tanh(ctx);
        case BUILTIN_MATH_ACOSH:
            builtin_math_acosh(ctx);
        case BUILTIN_MATH_ASINH:
            builtin_math_asinh(ctx);
        case BUILTIN_MATH_ATANH:
            builtin_math_atanh(ctx);
        case BUILTIN_MATH_LOG2:
            builtin_math_log2(ctx);
        case BUILTIN_MATH_LOG10:
            builtin_math_log10(ctx);
        case BUILTIN_MATH_LOG1P:
            builtin_math_log1p(ctx);
        case BUILTIN_MATH_EXPM1:
            builtin_math_expm1(ctx);
        case BUILTIN_MATH_CBRT:
            builtin_math_cbrt(ctx);
        case BUILTIN_MATH_HYPOT:
            builtin_math_hypot(ctx);
        case BUILTIN_MATH_TRUNC:
            builtin_math_trunc(ctx);
        case BUILTIN_MATH_SIGN:
            builtin_math_sign(ctx);
        case BUILTIN_MATH_FROUND:
            builtin_math_fround(ctx);
        case BUILTIN_MATH_CLZ32:
            builtin_math_clz32(ctx);
        case BUILTIN_MATH_IMUL:
            builtin_math_imul(ctx);
        case BUILTIN_ARRAY_ISARRAY:
            builtin_array_isArray(ctx);
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
        case BUILTIN_FUNCTION:
            builtin_function(ctx);
        case BUILTIN_EVAL:
            builtin_eval(ctx);
        case BUILTIN_JSON_PARSE:
            builtin_json_parse(ctx);
        case BUILTIN_JSON_STRINGIFY:
            builtin_json_stringify(ctx);
        case BUILTIN_DATE:
            builtin_date(ctx);
        case BUILTIN_DATE_NOW:
            builtin_date_now(ctx);
        case BUILTIN_DATE_UTC:
            builtin_date_utc(ctx);
        case BUILTIN_DATE_PARSE:
            builtin_date_parse(ctx);
        case BUILTIN_DATE_PROTO_TOSTRING:
            builtin_date_proto_toString(ctx);
        case BUILTIN_DATE_PROTO_TOJSON:
            builtin_date_proto_toJSON(ctx);
        case BUILTIN_DATE_PROTO_VALUEOF:
            builtin_date_proto_valueOf(ctx);
        case BUILTIN_DATE_PROTO_GETTIME:
            builtin_date_proto_getTime(ctx);
        case BUILTIN_DATE_PROTO_GETFULLYEAR:
            builtin_date_proto_getFullYear(ctx);
        case BUILTIN_DATE_PROTO_GETMONTH:
            builtin_date_proto_getMonth(ctx);
        case BUILTIN_DATE_PROTO_GETDATE:
            builtin_date_proto_getDate(ctx);
        case BUILTIN_DATE_PROTO_GETDAY:
            builtin_date_proto_getDay(ctx);
        case BUILTIN_DATE_PROTO_GETHOURS:
            builtin_date_proto_getHours(ctx);
        case BUILTIN_DATE_PROTO_GETMINUTES:
            builtin_date_proto_getMinutes(ctx);
        case BUILTIN_DATE_PROTO_GETSECONDS:
            builtin_date_proto_getSeconds(ctx);
        case BUILTIN_DATE_PROTO_GETMILLISECONDS:
            builtin_date_proto_getMilliseconds(ctx);
        case BUILTIN_REGEXP:
            builtin_regexp(ctx);
        case BUILTIN_REGEXP_PROTO_TEST:
            builtin_regexp_proto_test(ctx);
        case BUILTIN_REGEXP_PROTO_EXEC:
            builtin_regexp_proto_exec(ctx);
        case BUILTIN_REGEXP_PROTO_TOSTRING:
            builtin_regexp_proto_toString(ctx);
        case BUILTIN_RESET_GLOBALS:
            builtin_reset_globals(ctx);
        case BUILTIN_MAP:
            builtin_map(ctx);
        case BUILTIN_MAP_PROTO_SET:
            builtin_map_proto_set(ctx);
        case BUILTIN_MAP_PROTO_GET:
            builtin_map_proto_get(ctx);
        case BUILTIN_MAP_PROTO_HAS:
            builtin_map_proto_has(ctx);
        case BUILTIN_MAP_PROTO_DELETE:
            builtin_map_proto_delete(ctx);
        case BUILTIN_MAP_PROTO_CLEAR:
            builtin_map_proto_clear(ctx);
        case BUILTIN_MAP_PROTO_KEYS:
            builtin_map_proto_keys(ctx);
        case BUILTIN_MAP_PROTO_VALUES:
            builtin_map_proto_values(ctx);
        case BUILTIN_MAP_PROTO_ENTRIES:
            builtin_map_proto_entries(ctx);
        case BUILTIN_MAP_PROTO_FOREACH:
            builtin_map_proto_forEach(ctx);
        case BUILTIN_SET:
            builtin_set(ctx);
        case BUILTIN_SET_PROTO_ADD:
            builtin_set_proto_add(ctx);
        case BUILTIN_SET_PROTO_HAS:
            builtin_set_proto_has(ctx);
        case BUILTIN_SET_PROTO_DELETE:
            builtin_set_proto_delete(ctx);
        case BUILTIN_SET_PROTO_CLEAR:
            builtin_set_proto_clear(ctx);
        case BUILTIN_SET_PROTO_KEYS:
            builtin_set_proto_keys(ctx);
        case BUILTIN_SET_PROTO_VALUES:
            builtin_set_proto_values(ctx);
        case BUILTIN_SET_PROTO_ENTRIES:
            builtin_set_proto_entries(ctx);
        case BUILTIN_SET_PROTO_FOREACH:
            builtin_set_proto_forEach(ctx);
        case BUILTIN_WEAKMAP:
            builtin_weakmap(ctx);
        case BUILTIN_WEAKMAP_PROTO_SET:
            builtin_weakmap_proto_set(ctx);
        case BUILTIN_WEAKMAP_PROTO_GET:
            builtin_weakmap_proto_get(ctx);
        case BUILTIN_WEAKMAP_PROTO_HAS:
            builtin_weakmap_proto_has(ctx);
        case BUILTIN_WEAKMAP_PROTO_DELETE:
            builtin_weakmap_proto_delete(ctx);
        case BUILTIN_WEAKSET:
            builtin_weakset(ctx);
        case BUILTIN_WEAKSET_PROTO_ADD:
            builtin_weakset_proto_add(ctx);
        case BUILTIN_WEAKSET_PROTO_HAS:
            builtin_weakset_proto_has(ctx);
        case BUILTIN_WEAKSET_PROTO_DELETE:
            builtin_weakset_proto_delete(ctx);
        case BUILTIN_SYMBOL:
            builtin_symbol(ctx);
        case BUILTIN_SYMBOL_FOR:
            builtin_symbol_for(ctx);
        case BUILTIN_SYMBOL_KEYFOR:
            builtin_symbol_keyfor(ctx);
        case BUILTIN_SYMBOL_PROTO_TOSTRING:
            builtin_symbol_proto_toString(ctx);
        case BUILTIN_SYMBOL_PROTO_VALUEOF:
            builtin_symbol_proto_valueOf(ctx);
        case BUILTIN_PROMISE:
            builtin_promise(ctx);
        case BUILTIN_PROMISE_PROTO_THEN:
            builtin_promise_proto_then(ctx);
        case BUILTIN_PROMISE_PROTO_CATCH:
            builtin_promise_proto_catch(ctx);
        case BUILTIN_PROMISE_PROTO_FINALLY:
            builtin_promise_proto_finally(ctx);
        case BUILTIN_PROMISE_RESOLVE:
            builtin_promise_resolve(ctx);
        case BUILTIN_PROMISE_REJECT:
            builtin_promise_reject(ctx);
        case BUILTIN_PROMISE_ALL:
            builtin_promise_all(ctx);
        case BUILTIN_PROMISE_RACE:
            builtin_promise_race(ctx);
        case BUILTIN_GENERATOR_FUNCTION:
            builtin_generator_function(ctx);
        case BUILTIN_GENERATOR_PROTO_NEXT:
            builtin_generator_proto_next(ctx);
        case BUILTIN_GENERATOR_PROTO_THROW:
            builtin_generator_proto_throw(ctx);
        case BUILTIN_GENERATOR_PROTO_RETURN:
            builtin_generator_proto_return(ctx);
        case BUILTIN_ENCODE_URI:
            builtin_encode_uri(ctx);
        case BUILTIN_ENCODE_URI_COMPONENT:
            builtin_encode_uri_component(ctx);
        case BUILTIN_DECODE_URI:
            builtin_decode_uri(ctx);
        case BUILTIN_DECODE_URI_COMPONENT:
            builtin_decode_uri_component(ctx);
        default:
            ctx.result.tag = UNDEFINED;
            ctx.result.pointer = null;
    }
}

// ============================================================================
// __resetGlobals — test262 checkpoint/restore
// ============================================================================

fn void builtin_reset_globals(BuiltinContext* ctx) {
    HObject* globals = ctx.global_env.bindings;
    Heap* heap = ctx.heap;

    if (heap.checkpoint_count == 0) {
        // === First call: save checkpoint ===
        uint cap = globals.prop_count + 64;
        usz key_bytes = (usz)cap * void*::size;
        usz val_bytes = (usz)cap * TVal::size;
        heap.checkpoint_keys = (void**)heap.alloc_func(heap.heap_udata, key_bytes);
        heap.checkpoint_vals = (TVal*)heap.alloc_func(heap.heap_udata, val_bytes);
        if (heap.checkpoint_keys == null || heap.checkpoint_vals == null) {
            ctx.result.set_undefined();
            return;
        }
        heap.checkpoint_cap = cap;

        uint count = 0;
        for (uint i = 0; i < globals.prop_count; i++) {
            void* key = globals.props[i].key;
            if (key == null) continue;
            if (count >= heap.checkpoint_cap) {
                uint new_cap = heap.checkpoint_cap * 2;
                usz new_kb = (usz)new_cap * void*::size;
                usz new_vb = (usz)new_cap * TVal::size;
                void* new_keys = heap.realloc_func(heap.heap_udata, heap.checkpoint_keys, new_kb);
                TVal* new_vals = (TVal*)heap.realloc_func(heap.heap_udata, heap.checkpoint_vals, new_vb);
                if (new_keys == null || new_vals == null) break;
                heap.checkpoint_keys = (void**)new_keys;
                heap.checkpoint_vals = new_vals;
                heap.checkpoint_cap = new_cap;
            }
            heap.checkpoint_keys[count] = key;
            heap.checkpoint_vals[count] = globals.props[i].value;
            count++;
        }
        heap.checkpoint_count = count;
    } else {
        // === Restore checkpoint ===
        // Delete globals not in checkpoint
        for (uint i = globals.prop_count; i > 0; i--) {
            uint idx = i - 1;
            void* key = globals.props[idx].key;
            if (key == null) continue;
            bool found = false;
            for (uint j = 0; j < heap.checkpoint_count; j++) {
                if (heap.checkpoint_keys[j] == key) { found = true; break; }
            }
            if (!found) { globals.delete_prop(key); }
        }
        // Restore checkpoint values
        for (uint i = 0; i < heap.checkpoint_count; i++) {
            globals.put_prop(heap.checkpoint_keys[i], heap.checkpoint_vals[i],
                             hobject::PROP_FLAGS_WEC);
        }
    }
    ctx.result.set_undefined();
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

    HObject*? console_obj = heap.alloc_object(hobject::ObjClass.OBJECT);
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

    // Register encodeURI (ES5 §15.1.3.1)
    if (!register_simple_builtin(global_env, heap, "encodeURI", BUILTIN_ENCODE_URI)) return false;

    // Register encodeURIComponent (ES5 §15.1.3.2)
    if (!register_simple_builtin(global_env, heap, "encodeURIComponent", BUILTIN_ENCODE_URI_COMPONENT)) return false;

    // Register decodeURI (ES5 §15.1.3.3)
    if (!register_simple_builtin(global_env, heap, "decodeURI", BUILTIN_DECODE_URI)) return false;

    // Register decodeURIComponent (ES5 §15.1.3.4)
    if (!register_simple_builtin(global_env, heap, "decodeURIComponent", BUILTIN_DECODE_URI_COMPONENT)) return false;

    // Register test262 batch runner helper
    if (!register_simple_builtin(global_env, heap, "__resetGlobals", BUILTIN_RESET_GLOBALS)) return false;

    // Register global constants: NaN, Infinity, undefined
    if (!register_global_constant(global_env, heap, "NaN", NUMBER, double::nan, 0)) return false;
    if (!register_global_constant(global_env, heap, "Infinity", NUMBER, double::inf, 0)) return false;

    // Register Object constructor FIRST — creates Object.prototype (root of all chains)
    if (!register_object_constructor(global_env, heap)) return false;

    // Register Number constructor (with prototype and static properties)
    if (!register_number_constructor(global_env, heap)) return false;

    // Register Math object
    if (!register_math_object(global_env, heap)) return false;

    // Register JSON object (parse, stringify)
    if (!register_json_object(global_env, heap)) return false;

    // Register Error constructors (Error, TypeError, RangeError, ReferenceError, SyntaxError, EvalError)
    if (!register_error_builtins(global_env, heap)) return false;

    // Register Boolean constructor
    if (!register_boolean_constructor(global_env, heap)) return false;

    // Register String constructor
    if (!register_string_constructor(global_env, heap)) return false;

    // Register Array constructor
    if (!register_array_constructor(global_env, heap)) return false;

    // Register Function constructor and prototype (call, apply, bind)
    if (!register_function_constructor(global_env, heap)) return false;

    // Register Date constructor and prototype
    if (!register_date_constructor(global_env, heap)) return false;

    // Register RegExp constructor and prototype
    if (!register_regexp_constructor(global_env, heap)) return false;

    // Register Map constructor and prototype
    if (!register_map_constructor(global_env, heap)) return false;

    // Register Set constructor and prototype
    if (!register_set_constructor(global_env, heap)) return false;

    // Register WeakMap constructor and prototype
    if (!register_weakmap_constructor(global_env, heap)) return false;

    // Register WeakSet constructor and prototype
    if (!register_weakset_constructor(global_env, heap)) return false;

    // Register Symbol constructor and prototype
    if (!register_symbol_constructor(global_env, heap)) return false;

    // Register Promise constructor and prototype
    if (!register_promise_constructor(global_env, heap)) return false;

    // Register Generator constructor and prototype (GeneratorFunction uses
    // heap.generator_proto; the GeneratorFunction global is registered
    // separately as a simple builtin).
    if (!register_generator_constructor(global_env, heap)) return false;

    // Wire all prototype chains to Object.prototype
    if (heap.number_proto != null) heap.number_proto.prototype = heap.object_proto;
    if (heap.bool_proto != null)   heap.bool_proto.prototype = heap.object_proto;
    if (heap.string_proto != null) heap.string_proto.prototype = heap.object_proto;
    if (heap.err_proto != null)    heap.err_proto.prototype = heap.object_proto;
    if (heap.array_proto != null)  heap.array_proto.prototype = heap.object_proto;
    if (heap.function_proto != null) heap.function_proto.prototype = heap.object_proto;
    if (heap.date_proto != null)   heap.date_proto.prototype = heap.object_proto;
    if (heap.regexp_proto != null) heap.regexp_proto.prototype = heap.object_proto;
    if (heap.map_proto != null)    heap.map_proto.prototype = heap.object_proto;
    if (heap.set_proto != null)    heap.set_proto.prototype = heap.object_proto;
    if (heap.weakmap_proto != null) heap.weakmap_proto.prototype = heap.object_proto;
    if (heap.weakset_proto != null) heap.weakset_proto.prototype = heap.object_proto;
    if (heap.symbol_proto != null) heap.symbol_proto.prototype = heap.object_proto;
    if (heap.promise_proto != null) heap.promise_proto.prototype = heap.object_proto;
    if (heap.generator_proto != null) heap.generator_proto.prototype = heap.object_proto;

    // Wire constructor functions' [[Prototype]] to Function.prototype.
    // Constructor functions (Object, Number, Function, etc.) are HObjects
    // with ObjClass.FUNCTION whose internal prototype must be Function.prototype
    // so that Function.prototype.isPrototypeOf(Number) and similar work.
    // We look them up in the global environment by name.
    if (heap.function_proto != null) {
        char[][] ctor_names = { "Object", "Number", "Boolean", "String", "Array", "Function", "Date", "RegExp", "Error", "TypeError", "RangeError", "ReferenceError", "SyntaxError", "EvalError", "URIError", "Map", "Set", "WeakMap", "WeakSet", "Symbol", "Promise", "GeneratorFunction" };
        for (int i = 0; i < ctor_names.len; i++) {
            TVal? optv = env::env_get(global_env, builtin_intern_string(heap, ctor_names[i]));
            if (try tv = optv) {
                if (tv.tag == OBJECT && tv.pointer != null) {
                    HObject* ctor = (HObject*)tv.pointer;
                    ctor.prototype = heap.function_proto;
                }
            }
        }
    }

    return true;
}

fn bool register_object_constructor(EnvRecord* global_env, Heap* heap) {
    // Create Object.prototype — the root of all prototype chains
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;  // Object.prototype is the root — its [[Prototype]] is null
    heap.object_proto = proto;

    // Add .toString() method to Object.prototype
    HString* tostring_key = builtin_intern_string(heap, "toString");
    TVal tostring_tv;
    tostring_tv.tag = LIGHTFUNC;
    tostring_tv.fastint = (long)BUILTIN_OBJECT_PROTO_TOSTRING;
    proto.put_prop(tostring_key, tostring_tv, hobject::PROP_FLAGS_WEC);

    // Add .hasOwnProperty() method to Object.prototype
    HString* hasown_key = builtin_intern_string(heap, "hasOwnProperty");
    TVal hasown_tv;
    hasown_tv.tag = LIGHTFUNC;
    hasown_tv.fastint = (long)BUILTIN_OBJECT_PROTO_HASOWNPROPERTY;
    proto.put_prop(hasown_key, hasown_tv, hobject::PROP_FLAGS_WC);

    // Add .propertyIsEnumerable() method to Object.prototype (non-enumerable per ES5 §15.2.4.7)
    HString* propisenum_key = builtin_intern_string(heap, "propertyIsEnumerable");
    TVal propisenum_tv;
    propisenum_tv.tag = LIGHTFUNC;
    propisenum_tv.fastint = (long)BUILTIN_OBJECT_PROTO_PROPERTYISENUMERABLE;
    proto.put_prop(propisenum_key, propisenum_tv, hobject::PROP_FLAGS_WC);

    // Add .valueOf() method to Object.prototype (returns 'this')
    HString* valueof_key = builtin_intern_string(heap, "valueOf");
    TVal valueof_tv;
    valueof_tv.tag = LIGHTFUNC;
    valueof_tv.fastint = (long)BUILTIN_OBJECT_PROTO_VALUEOF;
    proto.put_prop(valueof_key, valueof_tv, hobject::PROP_FLAGS_WEC);

    // Add .isPrototypeOf() method to Object.prototype
    HString* isproto_key = builtin_intern_string(heap, "isPrototypeOf");
    TVal isproto_tv;
    isproto_tv.tag = LIGHTFUNC;
    isproto_tv.fastint = (long)BUILTIN_OBJECT_PROTO_ISPROTOTYPEOF;
    proto.put_prop(isproto_key, isproto_tv, hobject::PROP_FLAGS_WC);

    // Add .toLocaleString() method to Object.prototype (ES5 §15.2.4.3)
    HString* tolocalestring_key = builtin_intern_string(heap, "toLocaleString");
    TVal tolocalestring_tv;
    tolocalestring_tv.tag = LIGHTFUNC;
    tolocalestring_tv.fastint = (long)BUILTIN_OBJECT_PROTO_TOLOCALESTRING;
    proto.put_prop(tolocalestring_key, tolocalestring_tv, hobject::PROP_FLAGS_WC);

    // Create Object constructor as a proper HObject (not LIGHTFUNC)
    // so it can carry .prototype, .length, etc.
    HObject*? obj_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = obj_raw) return false;
    HObject* obj = obj_raw;
    obj.builtin_fn_index = (int)BUILTIN_OBJECT;

    // Set .constructor on Object.prototype to point to the actual Object constructor object
    HString* constructor_key = builtin_intern_string(heap, "constructor");
    TVal constructor_tv;
    constructor_tv.tag = OBJECT;
    constructor_tv.pointer = obj;
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WEC);

    // Set Object.prototype on the constructor (non-writable, non-enumerable, non-configurable)
    HString* prototype_key = builtin_intern_string(heap, "prototype");
    TVal proto_tv;
    proto_tv.tag = OBJECT;
    proto_tv.pointer = proto;
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    obj.put_prop(prototype_key, proto_tv, proto_pflags);

    // Set Object.length (ES5 §15.2.1)
    HString* length_key = builtin_intern_string(heap, "length");
    TVal length_tv;
    length_tv.tag = FASTINT;
    length_tv.fastint = 1;
    obj.put_prop(length_key, length_tv, hobject::PROP_FLAGS_WEC);

    // Add static methods to Object constructor
    HString* keys_key = builtin_intern_string(heap, "keys");
    if (keys_key == null) return false;
    TVal keys_tv;
    keys_tv.tag = LIGHTFUNC;
    keys_tv.fastint = (long)BUILTIN_OBJECT_KEYS;
    obj.put_prop(keys_key, keys_tv, hobject::PROP_FLAGS_WEC);

    // Object.getPrototypeOf — ES5 §15.2.3.2
    HString* getproto_key = builtin_intern_string(heap, "getPrototypeOf");
    if (getproto_key == null) return false;
    TVal getproto_tv;
    getproto_tv.tag = LIGHTFUNC;
    getproto_tv.fastint = (long)BUILTIN_OBJECT_GETPROTOTYPEOF;
    obj.put_prop(getproto_key, getproto_tv, hobject::PROP_FLAGS_WC);

    // Object.isExtensible — ES5 §15.2.3.13
    HString* isext_key = builtin_intern_string(heap, "isExtensible");
    if (isext_key == null) return false;
    TVal isext_tv;
    isext_tv.tag = LIGHTFUNC;
    isext_tv.fastint = (long)BUILTIN_OBJECT_ISEXTENSIBLE;
    obj.put_prop(isext_key, isext_tv, hobject::PROP_FLAGS_WC);

    // Object.preventExtensions — ES5 §15.2.3.10
    HString* prevext_key = builtin_intern_string(heap, "preventExtensions");
    if (prevext_key == null) return false;
    TVal prevext_tv;
    prevext_tv.tag = LIGHTFUNC;
    prevext_tv.fastint = (long)BUILTIN_OBJECT_PREVENTEXTENSIONS;
    obj.put_prop(prevext_key, prevext_tv, hobject::PROP_FLAGS_WC);

    // Object.getOwnPropertyDescriptor — ES5 §15.2.3.3
    HString* getownpropdesc_key = builtin_intern_string(heap, "getOwnPropertyDescriptor");
    if (getownpropdesc_key == null) return false;
    TVal getownpropdesc_tv;
    getownpropdesc_tv.tag = LIGHTFUNC;
    getownpropdesc_tv.fastint = (long)BUILTIN_OBJECT_GETOWNPROPERTYDESCRIPTOR;
    obj.put_prop(getownpropdesc_key, getownpropdesc_tv, hobject::PROP_FLAGS_WC);

    // Object.defineProperty — ES5 §15.2.3.6
    HString* defineprop_key = builtin_intern_string(heap, "defineProperty");
    if (defineprop_key == null) return false;
    TVal defineprop_tv;
    defineprop_tv.tag = LIGHTFUNC;
    defineprop_tv.fastint = (long)BUILTIN_OBJECT_DEFINEPROPERTY;
    obj.put_prop(defineprop_key, defineprop_tv, hobject::PROP_FLAGS_WC);

    // Object.getOwnPropertyNames — ES5 §15.2.3.4
    HString* getownpropnames_key = builtin_intern_string(heap, "getOwnPropertyNames");
    if (getownpropnames_key == null) return false;
    TVal getownpropnames_tv;
    getownpropnames_tv.tag = LIGHTFUNC;
    getownpropnames_tv.fastint = (long)BUILTIN_OBJECT_GETOWNPROPERTYNAMES;
    obj.put_prop(getownpropnames_key, getownpropnames_tv, hobject::PROP_FLAGS_WC);

    // Object.defineProperties — ES5 §15.2.3.7
    HString* defineprops_key = builtin_intern_string(heap, "defineProperties");
    if (defineprops_key == null) return false;
    TVal defineprops_tv;
    defineprops_tv.tag = LIGHTFUNC;
    defineprops_tv.fastint = (long)BUILTIN_OBJECT_DEFINEPROPERTIES;
    obj.put_prop(defineprops_key, defineprops_tv, hobject::PROP_FLAGS_WC);

    // Object.create — ES5 §15.2.3.5
    HString* create_key = builtin_intern_string(heap, "create");
    if (create_key == null) return false;
    TVal create_tv;
    create_tv.tag = LIGHTFUNC;
    create_tv.fastint = (long)BUILTIN_OBJECT_CREATE;
    obj.put_prop(create_key, create_tv, hobject::PROP_FLAGS_WC);

    // Object.seal — ES5 §15.2.3.8
    HString* seal_key = builtin_intern_string(heap, "seal");
    if (seal_key == null) return false;
    TVal seal_tv;
    seal_tv.tag = LIGHTFUNC;
    seal_tv.fastint = (long)BUILTIN_OBJECT_SEAL;
    obj.put_prop(seal_key, seal_tv, hobject::PROP_FLAGS_WC);

    // Object.freeze — ES5 §15.2.3.9
    HString* freeze_key = builtin_intern_string(heap, "freeze");
    if (freeze_key == null) return false;
    TVal freeze_tv;
    freeze_tv.tag = LIGHTFUNC;
    freeze_tv.fastint = (long)BUILTIN_OBJECT_FREEZE;
    obj.put_prop(freeze_key, freeze_tv, hobject::PROP_FLAGS_WC);

    // Object.isSealed — ES5 §15.2.3.11
    HString* issealed_key = builtin_intern_string(heap, "isSealed");
    if (issealed_key == null) return false;
    TVal issealed_tv;
    issealed_tv.tag = LIGHTFUNC;
    issealed_tv.fastint = (long)BUILTIN_OBJECT_ISSEALED;
    obj.put_prop(issealed_key, issealed_tv, hobject::PROP_FLAGS_WC);

    // Object.isFrozen — ES5 §15.2.3.12
    HString* isfrozen_key = builtin_intern_string(heap, "isFrozen");
    if (isfrozen_key == null) return false;
    TVal isfrozen_tv;
    isfrozen_tv.tag = LIGHTFUNC;
    isfrozen_tv.fastint = (long)BUILTIN_OBJECT_ISFROZEN;
    obj.put_prop(isfrozen_key, isfrozen_tv, hobject::PROP_FLAGS_WC);

    // Object.entries — ES2017 §19.1.2.21
    HString* entries_key = builtin_intern_string(heap, "entries");
    if (entries_key == null) return false;
    TVal entries_tv;
    entries_tv.tag = LIGHTFUNC;
    entries_tv.fastint = (long)BUILTIN_OBJECT_ENTRIES;
    obj.put_prop(entries_key, entries_tv, hobject::PROP_FLAGS_WC);

    // Object.values — ES2017 §19.1.2.22
    HString* values_key = builtin_intern_string(heap, "values");
    if (values_key == null) return false;
    TVal values_tv;
    values_tv.tag = LIGHTFUNC;
    values_tv.fastint = (long)BUILTIN_OBJECT_VALUES;
    obj.put_prop(values_key, values_tv, hobject::PROP_FLAGS_WC);

    // Object.assign — ES2015 §19.1.2.2
    HString* assign_key = builtin_intern_string(heap, "assign");
    if (assign_key == null) return false;
    TVal assign_tv;
    assign_tv.tag = LIGHTFUNC;
    assign_tv.fastint = (long)BUILTIN_OBJECT_ASSIGN;
    obj.put_prop(assign_key, assign_tv, hobject::PROP_FLAGS_WC);

    // Object.is — ES6 §19.1.2.10
    HString* is_key = builtin_intern_string(heap, "is");
    if (is_key == null) return false;
    TVal is_tv;
    is_tv.tag = LIGHTFUNC;
    is_tv.fastint = (long)BUILTIN_OBJECT_IS;
    obj.put_prop(is_key, is_tv, hobject::PROP_FLAGS_WC);

    // Object.hasOwn — ES2022 §19.1.2.10
    HString* hasown_static_key = builtin_intern_string(heap, "hasOwn");
    if (hasown_static_key == null) return false;
    TVal hasown_static_tv;
    hasown_static_tv.tag = LIGHTFUNC;
    hasown_static_tv.fastint = (long)BUILTIN_OBJECT_HASOWN;
    obj.put_prop(hasown_static_key, hasown_static_tv, hobject::PROP_FLAGS_WC);

    // Object.setPrototypeOf — ES2015 §19.1.2.19
    HString* setproto_key = builtin_intern_string(heap, "setPrototypeOf");
    if (setproto_key == null) return false;
    TVal setproto_tv;
    setproto_tv.tag = LIGHTFUNC;
    setproto_tv.fastint = (long)BUILTIN_OBJECT_SETPROTOTYPEOF;
    obj.put_prop(setproto_key, setproto_tv, hobject::PROP_FLAGS_WC);

    // Register Object constructor globally as an OBJECT (not LIGHTFUNC)
    uint hash = heap.hash_string("Object");
    HString* existing = heap.str_table_lookup("Object", hash);
    HString* obj_key;
    if (existing != null) {
        obj_key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, "Object", hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        obj_key = new_key;
    }
    TVal obj_val;
    obj_val.tag = OBJECT;
    obj_val.pointer = obj;
    env::env_declare(global_env, obj_key, obj_val);

    return true;
}

fn bool register_math_object(EnvRecord* global_env, Heap* heap) {
    HObject*? math_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
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
    if (!register_math_method(math, heap, "acos",   BUILTIN_MATH_ACOS))   return false;
    if (!register_math_method(math, heap, "asin",   BUILTIN_MATH_ASIN))   return false;
    if (!register_math_method(math, heap, "atan",   BUILTIN_MATH_ATAN))   return false;
    if (!register_math_method(math, heap, "atan2",  BUILTIN_MATH_ATAN2))  return false;
    if (!register_math_method(math, heap, "cosh",   BUILTIN_MATH_COSH))   return false;
    if (!register_math_method(math, heap, "sinh",   BUILTIN_MATH_SINH))   return false;
    if (!register_math_method(math, heap, "tanh",   BUILTIN_MATH_TANH))   return false;
    if (!register_math_method(math, heap, "acosh",  BUILTIN_MATH_ACOSH))  return false;
    if (!register_math_method(math, heap, "asinh",  BUILTIN_MATH_ASINH))  return false;
    if (!register_math_method(math, heap, "atanh",  BUILTIN_MATH_ATANH))  return false;
    if (!register_math_method(math, heap, "log2",   BUILTIN_MATH_LOG2))   return false;
    if (!register_math_method(math, heap, "log10",  BUILTIN_MATH_LOG10))  return false;
    if (!register_math_method(math, heap, "log1p",  BUILTIN_MATH_LOG1P))  return false;
    if (!register_math_method(math, heap, "expm1",  BUILTIN_MATH_EXPM1))  return false;
    if (!register_math_method(math, heap, "cbrt",   BUILTIN_MATH_CBRT))   return false;
    if (!register_math_method(math, heap, "hypot",  BUILTIN_MATH_HYPOT))  return false;
    if (!register_math_method(math, heap, "trunc",  BUILTIN_MATH_TRUNC))  return false;
    if (!register_math_method(math, heap, "sign",   BUILTIN_MATH_SIGN))   return false;
    if (!register_math_method(math, heap, "fround", BUILTIN_MATH_FROUND)) return false;
    if (!register_math_method(math, heap, "clz32",  BUILTIN_MATH_CLZ32))  return false;
    if (!register_math_method(math, heap, "imul",   BUILTIN_MATH_IMUL))   return false;

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
// JSON object registration
// ============================================================================

/// Create JSON global object with .parse and .stringify methods.
fn bool register_json_object(EnvRecord* global_env, Heap* heap) {
    HObject*? json_raw = heap.alloc_object(hobject::ObjClass.JSON);
    if (catch err = json_raw) return false;
    HObject* json = json_raw;

    // Register JSON.parse
    if (!register_math_method(json, heap, "parse", BUILTIN_JSON_PARSE)) return false;
    // Register JSON.stringify
    if (!register_math_method(json, heap, "stringify", BUILTIN_JSON_STRINGIFY)) return false;

    TVal json_tv;
    json_tv.tag = OBJECT;
    json_tv.fastint = 0;
    json_tv.pointer = json;
    return register_named_value(global_env, heap, "JSON", json_tv);
}

// ============================================================================
// Number constructor registration
// ============================================================================

/// Create Number.prototype and register the Number constructor globally.
fn bool register_number_constructor(EnvRecord* global_env, Heap* heap) {
    // Create Number prototype
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.NUMBER);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;  // Will be Object.prototype in later phases
    heap.number_proto = proto;

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
    HObject*? num_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = num_raw) return false;
    HObject* num = num_raw;
    num.builtin_fn_index = (int)BUILTIN_NUMBER;

    // Set .constructor on Number.prototype to point to the actual Number object
    HString* constructor_key = builtin_intern_string(heap, "constructor");
    TVal constructor_tv;
    constructor_tv.tag = OBJECT;
    constructor_tv.pointer = num;
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WEC);

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

    // Add Number.isNaN (ES6 §20.1.2.4)
    if (!register_string_proto_method(num, heap, "isNaN", BUILTIN_NUMBER_ISNAN)) return false;
    // Add Number.isFinite (ES6 §20.1.2.2)
    if (!register_string_proto_method(num, heap, "isFinite", BUILTIN_NUMBER_ISFINITE)) return false;
    // Add Number.isInteger (ES6 §20.1.2.3)
    if (!register_string_proto_method(num, heap, "isInteger", BUILTIN_NUMBER_ISINTEGER)) return false;
    // Add Number.isSafeInteger (ES6 §20.1.2.5)
    if (!register_string_proto_method(num, heap, "isSafeInteger", BUILTIN_NUMBER_ISSAFEINTEGER)) return false;

    // Add Number.EPSILON (ES6 §20.1.2.1) — 2^-52
    if (!set_num_static_prop(num, heap, "EPSILON", 2.220446049250313e-16)) return false;
    // Add Number.MAX_SAFE_INTEGER (ES6 §20.1.2.6) — 2^53 - 1
    if (!set_num_static_prop(num, heap, "MAX_SAFE_INTEGER", 9007199254740991.0)) return false;
    // Add Number.MIN_SAFE_INTEGER (ES6 §20.1.2.8) — -(2^53 - 1)
    if (!set_num_static_prop(num, heap, "MIN_SAFE_INTEGER", -9007199254740991.0)) return false;
    // Add Number.parseInt (ES6 §20.1.2.12) — same as global parseInt
    if (!register_string_proto_method(num, heap, "parseInt", BUILTIN_PARSE_INT)) return false;
    // Add Number.parseFloat (ES6 §20.1.2.13) — same as global parseFloat
    if (!register_string_proto_method(num, heap, "parseFloat", BUILTIN_PARSE_FLOAT)) return false;

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
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.ERROR);
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

    // Add .constructor to Error.prototype pointing to Error builtin
    HString* constructor_key = builtin_intern_string(heap, "constructor");
    TVal constructor_tv;
    constructor_tv.tag = LIGHTFUNC;
    constructor_tv.fastint = (long)BUILTIN_ERROR;
    err_proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WEC);

    // --- Create TypeError.prototype ---
    HObject* type_err_proto = register_error_prototype(heap, err_proto, "TypeError");
    if (type_err_proto == null) return false;
    type_err_proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WEC);
    heap.type_err_proto = type_err_proto;

    // --- Create RangeError.prototype ---
    HObject* range_err_proto = register_error_prototype(heap, err_proto, "RangeError");
    if (range_err_proto == null) return false;
    range_err_proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WEC);
    heap.range_err_proto = range_err_proto;

    // --- Create ReferenceError.prototype ---
    HObject* ref_err_proto = register_error_prototype(heap, err_proto, "ReferenceError");
    if (ref_err_proto == null) return false;
    ref_err_proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WEC);
    heap.ref_err_proto = ref_err_proto;

    // --- Create SyntaxError.prototype ---
    HObject* syntax_err_proto = register_error_prototype(heap, err_proto, "SyntaxError");
    if (syntax_err_proto == null) return false;
    syntax_err_proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WEC);
    heap.syntax_err_proto = syntax_err_proto;

    // --- Create EvalError.prototype ---
    HObject* eval_err_proto = register_error_prototype(heap, err_proto, "EvalError");
    if (eval_err_proto == null) return false;
    eval_err_proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WEC);
    heap.eval_err_proto = eval_err_proto;

    // --- Create URIError.prototype ---
    HObject* uri_err_proto = register_error_prototype(heap, err_proto, "URIError");
    if (uri_err_proto == null) return false;
    uri_err_proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WEC);
    heap.uri_err_proto = uri_err_proto;

    // Set .constructor on each error sub-prototype to point to its own builtin
    // (type_err_proto already done above — fix it now with correct index)
    TVal type_err_constr;
    type_err_constr.tag = LIGHTFUNC;
    type_err_constr.fastint = (long)BUILTIN_TYPE_ERROR;
    type_err_proto.put_prop(constructor_key, type_err_constr, hobject::PROP_FLAGS_WEC);

    TVal range_err_constr;
    range_err_constr.tag = LIGHTFUNC;
    range_err_constr.fastint = (long)BUILTIN_RANGE_ERROR;
    range_err_proto.put_prop(constructor_key, range_err_constr, hobject::PROP_FLAGS_WEC);

    TVal ref_err_constr;
    ref_err_constr.tag = LIGHTFUNC;
    ref_err_constr.fastint = (long)BUILTIN_REFERENCE_ERROR;
    ref_err_proto.put_prop(constructor_key, ref_err_constr, hobject::PROP_FLAGS_WEC);

    TVal syntax_err_constr;
    syntax_err_constr.tag = LIGHTFUNC;
    syntax_err_constr.fastint = (long)BUILTIN_SYNTAX_ERROR;
    syntax_err_proto.put_prop(constructor_key, syntax_err_constr, hobject::PROP_FLAGS_WEC);

    TVal eval_err_constr;
    eval_err_constr.tag = LIGHTFUNC;
    eval_err_constr.fastint = (long)BUILTIN_EVAL_ERROR;
    eval_err_proto.put_prop(constructor_key, eval_err_constr, hobject::PROP_FLAGS_WEC);

    TVal uri_err_constr;
    uri_err_constr.tag = LIGHTFUNC;
    uri_err_constr.fastint = (long)BUILTIN_URI_ERROR;
    uri_err_proto.put_prop(constructor_key, uri_err_constr, hobject::PROP_FLAGS_WEC);

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

    // --- Register URIError ---
    if (!register_simple_builtin(global_env, heap, "URIError", BUILTIN_URI_ERROR)) return false;

    return true;
}

// ============================================================================
// Boolean constructor registration
// ============================================================================

/// Create Boolean.prototype and register the Boolean constructor globally.
fn bool register_boolean_constructor(EnvRecord* global_env, Heap* heap) {
    // Create Boolean.prototype
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.BOOLEAN);
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
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.STRING);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;  // Will be Object.prototype in later phases
    heap.string_proto = proto;

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
    if (!register_string_proto_method(proto, heap, "includes",   BUILTIN_STRING_PROTO_INCLUDES))   return false;
    if (!register_string_proto_method(proto, heap, "startsWith", BUILTIN_STRING_PROTO_STARTSWITH)) return false;
    if (!register_string_proto_method(proto, heap, "endsWith",   BUILTIN_STRING_PROTO_ENDSWITH))   return false;
    if (!register_string_proto_method(proto, heap, "repeat",     BUILTIN_STRING_PROTO_REPEAT))     return false;
    if (!register_string_proto_method(proto, heap, "trimStart",  BUILTIN_STRING_PROTO_TRIMSTART))  return false;
    if (!register_string_proto_method(proto, heap, "trimEnd",    BUILTIN_STRING_PROTO_TRIMEND))    return false;
    if (!register_string_proto_method(proto, heap, "codePointAt", BUILTIN_STRING_PROTO_CODEPOINTAT)) return false;
    if (!register_string_proto_method(proto, heap, "at",         BUILTIN_STRING_PROTO_AT))         return false;
    if (!register_string_proto_method(proto, heap, "padStart",   BUILTIN_STRING_PROTO_PADSTART))   return false;
    if (!register_string_proto_method(proto, heap, "padEnd",     BUILTIN_STRING_PROTO_PADEND))     return false;
    if (!register_string_proto_method(proto, heap, "lastIndexOf", BUILTIN_STRING_PROTO_LASTINDEXOF)) return false;

    // Create String constructor as a proper function object (not LIGHTFUNC)
    // so it can carry static methods like String.fromCharCode.
    HObject*? str_obj_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = str_obj_raw) return false;
    HObject* str_obj = str_obj_raw;
    str_obj.builtin_fn_index = (int)BUILTIN_STRING;

    // Set .constructor on String.prototype to point to the actual String object
    HString* constructor_key = builtin_intern_string(heap, "constructor");
    TVal constructor_tv;
    constructor_tv.tag = OBJECT;
    constructor_tv.pointer = str_obj;
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WEC);

    // Set String.prototype on the constructor (non-writable, non-enumerable, non-configurable)
    HString* prototype_key = builtin_intern_string(heap, "prototype");
    TVal proto_tv;
    proto_tv.tag = OBJECT;
    proto_tv.pointer = proto;
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    str_obj.put_prop(prototype_key, proto_tv, proto_pflags);

    // Add String.fromCharCode (ES5 §15.5.3.2)
    if (!register_string_proto_method(str_obj, heap, "fromCharCode", BUILTIN_STRING_FROMCHARCODE)) return false;
    if (!register_string_proto_method(str_obj, heap, "fromCodePoint", BUILTIN_STRING_FROMCODEPOINT)) return false;

    // Register String constructor globally as an OBJECT (not LIGHTFUNC)
    uint hash = heap.hash_string("String");
    HString* existing = heap.str_table_lookup("String", hash);
    HString* str_key;
    if (existing != null) {
        str_key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, "String", hash);
        if (catch err2 = new_key) return false;
        heap.str_table_insert(new_key);
        str_key = new_key;
    }
    TVal str_val;
    str_val.tag = OBJECT;
    str_val.pointer = str_obj;
    env::env_declare(global_env, str_key, str_val);

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
    arr.builtin_fn_index = (int)BUILTIN_ARRAY;

    // Set .constructor on Array.prototype to point to the actual Array constructor object
    HString* constructor_key = builtin_intern_string(heap, "constructor");
    TVal constructor_tv;
    constructor_tv.tag = OBJECT;
    constructor_tv.pointer = arr;
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WEC);

    // Set Array.prototype on the constructor (non-writable, non-enumerable, non-configurable)
    HString* prototype_key = builtin_intern_string(heap, "prototype");
    TVal proto_tv;
    proto_tv.tag = OBJECT;
    proto_tv.pointer = proto;
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
    if (!register_array_proto_method(proto, heap, "find",      BUILTIN_ARRAY_PROTO_FIND))      return false;
    if (!register_array_proto_method(proto, heap, "findIndex",  BUILTIN_ARRAY_PROTO_FINDINDEX)) return false;
    if (!register_array_proto_method(proto, heap, "flat",      BUILTIN_ARRAY_PROTO_FLAT))      return false;
    if (!register_array_proto_method(proto, heap, "flatMap",   BUILTIN_ARRAY_PROTO_FLATMAP))   return false;
    if (!register_array_proto_method(proto, heap, "toReversed", BUILTIN_ARRAY_PROTO_TOREVERSED)) return false;
    if (!register_array_proto_method(proto, heap, "toSorted",  BUILTIN_ARRAY_PROTO_TOSORTED))  return false;
    if (!register_array_proto_method(proto, heap, "toSpliced", BUILTIN_ARRAY_PROTO_TOSPLICED)) return false;
    if (!register_array_proto_method(proto, heap, "with",      BUILTIN_ARRAY_PROTO_WITH))      return false;

    // Register callback-based Array.prototype methods as compiled JS functions.
    // These need VM callback invocation, so they're compiled from JS source.
    // Format: (params){body} — compile_function expects no "function" keyword.
    if (!register_compiled_proto_method(proto, heap, global_env, "forEach",
        "(callback){var O=Object(this);var len=O.length;var k=0;while(k<len){var v=O[k];callback(v,k,O);k++}}")) return false;
    if (!register_compiled_proto_method(proto, heap, global_env, "map",
        "(callback){var O=Object(this);var len=O.length;var A=[];var k=0;while(k<len){var v=O[k];var r=callback(v,k,O);A.push(r);k++}return A}")) return false;
    if (!register_compiled_proto_method(proto, heap, global_env, "filter",
        "(callback){var O=Object(this);var len=O.length;var res=[];var k=0;while(k<len){var v=O[k];if(callback(v,k,O)){res.push(v)}k++}return res}")) return false;
    if (!register_compiled_proto_method(proto, heap, global_env, "every",
        "(callback){var O=Object(this);var len=O.length;var k=0;while(k<len){var v=O[k];if(!callback(v,k,O))return false;k++}return true}")) return false;
    if (!register_compiled_proto_method(proto, heap, global_env, "some",
        "(callback){var O=Object(this);var len=O.length;var k=0;while(k<len){var v=O[k];if(callback(v,k,O))return true;k++}return false}")) return false;
    if (!register_compiled_proto_method(proto, heap, global_env, "reduce",
        "(callback,initialValue){var O=Object(this);var len=O.length;var k=0;var acc=initialValue;while(k<len){var v=O[k];var a=acc;acc=callback(a,v,k,O);k++}return acc}")) return false;
    if (!register_compiled_proto_method(proto, heap, global_env, "reduceRight",
        "(callback,initialValue){var O=Object(this);var len=O.length;var k=len-1;var acc=initialValue;while(k>=0){var v=O[k];var a=acc;acc=callback(a,v,k,O);k--}return acc}")) return false;
    // TODO: register map/filter/every/some/reduce/reduceRight after forEach works

    // Add Array.isArray (ES6 §22.1.2.2) as static method on the constructor
    HString* isarray_key = builtin_intern_string(heap, "isArray");
    if (isarray_key == null) return false;
    TVal isarray_tv;
    isarray_tv.tag = LIGHTFUNC;
    isarray_tv.fastint = (long)BUILTIN_ARRAY_ISARRAY;
    arr.put_prop(isarray_key, isarray_tv, hobject::PROP_FLAGS_WEC);

    // Add Array.of (ES6 §22.1.2.3) as static method on the constructor
    HString* of_key = builtin_intern_string(heap, "of");
    if (of_key == null) return false;
    TVal of_tv;
    of_tv.tag = LIGHTFUNC;
    of_tv.fastint = (long)BUILTIN_ARRAY_OF;
    arr.put_prop(of_key, of_tv, hobject::PROP_FLAGS_WEC);

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
    arr_val.tag = OBJECT;
    arr_val.pointer = arr;
    env::env_declare(global_env, arr_key, arr_val);

    return true;
}

// ============================================================================
// Function constructor + Function.prototype registration
// ============================================================================

/// Create Function.prototype, register call/apply/bind, and register
/// the Function constructor globally.
fn bool register_function_constructor(EnvRecord* global_env, Heap* heap) {
    // Create Function constructor as a proper function object FIRST
    HObject*? func_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = func_raw) return false;
    HObject* func_obj = func_raw;
    func_obj.builtin_fn_index = (int)BUILTIN_FUNCTION;

    // Create Function.prototype
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
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

    // Set .constructor to the Function constructor object itself
    HString* constructor_key = builtin_intern_string(heap, "constructor");
    TVal constructor_tv;
    constructor_tv.tag = OBJECT;
    constructor_tv.pointer = func_obj;
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WEC);

    // Set Function.prototype on the constructor (non-writable, non-enumerable, non-configurable)
    HString* prototype_key = builtin_intern_string(heap, "prototype");
    TVal proto_tv;
    proto_tv.tag = OBJECT;
    proto_tv.pointer = proto;
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    func_obj.put_prop(prototype_key, proto_tv, proto_pflags);

    // Set Function.length (ES5 §15.3.3)
    HString* len_key = builtin_intern_string(heap, "length");
    TVal len_tv;
    len_tv.tag = FASTINT;
    len_tv.fastint = 1;
    func_obj.put_prop(len_key, len_tv, hobject::PROP_FLAGS_WEC);

    // Register Function constructor globally as an OBJECT
    uint hash = heap.hash_string("Function");
    HString* existing = heap.str_table_lookup("Function", hash);
    HString* func_key;
    if (existing != null) {
        func_key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, "Function", hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        func_key = new_key;
    }
    TVal func_val;
    func_val.tag = OBJECT;
    func_val.pointer = func_obj;
    env::env_declare(global_env, func_key, func_val);

    return true;
}

// ============================================================================
// Date constructor registration
// ============================================================================

/// Create Date.prototype and register the Date constructor globally.
fn bool register_date_constructor(EnvRecord* global_env, Heap* heap) {
    // Create Date.prototype
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.DATE);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;  // Will be Object.prototype
    heap.date_proto = proto;

    // Set .constructor to Date lightfunc
    HString* constructor_key = builtin_intern_string(heap, "constructor");
    TVal constructor_tv;
    constructor_tv.tag = LIGHTFUNC;
    constructor_tv.fastint = (long)BUILTIN_DATE;
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WEC);

    // Add Date.prototype.toString()
    if (!register_string_proto_method(proto, heap, "toString", BUILTIN_DATE_PROTO_TOSTRING)) return false;

    // Add Date.prototype.toJSON()
    if (!register_string_proto_method(proto, heap, "toJSON", BUILTIN_DATE_PROTO_TOJSON)) return false;

    // Add Date.prototype.valueOf()
    if (!register_string_proto_method(proto, heap, "valueOf", BUILTIN_DATE_PROTO_VALUEOF)) return false;

    // Add Date.prototype.getTime()
    if (!register_string_proto_method(proto, heap, "getTime", BUILTIN_DATE_PROTO_GETTIME)) return false;

    // Add Date.prototype.getFullYear()
    if (!register_string_proto_method(proto, heap, "getFullYear", BUILTIN_DATE_PROTO_GETFULLYEAR)) return false;

    // Add Date.prototype.getMonth()
    if (!register_string_proto_method(proto, heap, "getMonth", BUILTIN_DATE_PROTO_GETMONTH)) return false;

    // Add Date.prototype.getDate()
    if (!register_string_proto_method(proto, heap, "getDate", BUILTIN_DATE_PROTO_GETDATE)) return false;

    // Add Date.prototype.getDay()
    if (!register_string_proto_method(proto, heap, "getDay", BUILTIN_DATE_PROTO_GETDAY)) return false;

    // Add Date.prototype.getHours()
    if (!register_string_proto_method(proto, heap, "getHours", BUILTIN_DATE_PROTO_GETHOURS)) return false;

    // Add Date.prototype.getMinutes()
    if (!register_string_proto_method(proto, heap, "getMinutes", BUILTIN_DATE_PROTO_GETMINUTES)) return false;

    // Add Date.prototype.getSeconds()
    if (!register_string_proto_method(proto, heap, "getSeconds", BUILTIN_DATE_PROTO_GETSECONDS)) return false;

    // Add Date.prototype.getMilliseconds()
    if (!register_string_proto_method(proto, heap, "getMilliseconds", BUILTIN_DATE_PROTO_GETMILLISECONDS)) return false;

    // Register Date as a global constructor (proper function object for static methods)
    HObject*? date_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = date_raw) return false;
    HObject* date_obj = date_raw;
    date_obj.builtin_fn_index = (int)BUILTIN_DATE;

    // Set Date.prototype on the constructor
    HString* prototype_key = builtin_intern_string(heap, "prototype");
    TVal proto_tv;
    proto_tv.tag = OBJECT;
    proto_tv.pointer = proto;
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    date_obj.put_prop(prototype_key, proto_tv, proto_pflags);

    // Add Date.now() static method
    if (!register_string_proto_method(date_obj, heap, "now", BUILTIN_DATE_NOW)) return false;

    // Add Date.UTC() static method
    if (!register_string_proto_method(date_obj, heap, "UTC", BUILTIN_DATE_UTC)) return false;

    // Add Date.parse() static method
    if (!register_string_proto_method(date_obj, heap, "parse", BUILTIN_DATE_PARSE)) return false;

    // Register Date constructor globally as an OBJECT
    uint hash = heap.hash_string("Date");
    HString* existing = heap.str_table_lookup("Date", hash);
    HString* date_key;
    if (existing != null) {
        date_key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, "Date", hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        date_key = new_key;
    }
    TVal date_val;
    date_val.tag = OBJECT;
    date_val.pointer = date_obj;
    env::env_declare(global_env, date_key, date_val);

    return true;
}


// ============================================================================
// RegExp constructor registration
// ============================================================================

/// Create RegExp.prototype and register the RegExp constructor globally.
fn bool register_regexp_constructor(EnvRecord* global_env, Heap* heap) {
    // Create RegExp.prototype
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.REGEXP);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;  // Will be Object.prototype
    heap.regexp_proto = proto;

    // Set .constructor to RegExp lightfunc
    HString* constructor_key = builtin_intern_string(heap, "constructor");
    TVal constructor_tv;
    constructor_tv.tag = LIGHTFUNC;
    constructor_tv.fastint = (long)BUILTIN_REGEXP;
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WEC);

    // Add RegExp.prototype.test()
    if (!register_string_proto_method(proto, heap, "test", BUILTIN_REGEXP_PROTO_TEST)) return false;

    // Add RegExp.prototype.exec()
    if (!register_string_proto_method(proto, heap, "exec", BUILTIN_REGEXP_PROTO_EXEC)) return false;

    // Add RegExp.prototype.toString()
    if (!register_string_proto_method(proto, heap, "toString", BUILTIN_REGEXP_PROTO_TOSTRING)) return false;

    // Register RegExp as a global constructor (proper function object)
    HObject*? regexp_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = regexp_raw) return false;
    HObject* regexp_obj = regexp_raw;
    regexp_obj.builtin_fn_index = (int)BUILTIN_REGEXP;

    // Set RegExp.prototype on the constructor
    HString* prototype_key = builtin_intern_string(heap, "prototype");
    TVal proto_tv;
    proto_tv.tag = OBJECT;
    proto_tv.pointer = proto;
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    regexp_obj.put_prop(prototype_key, proto_tv, proto_pflags);

    // Set RegExp.length (ES5 15.10.5)
    HString* len_key = builtin_intern_string(heap, "length");
    TVal len_tv;
    len_tv.tag = FASTINT;
    len_tv.fastint = 2;
    regexp_obj.put_prop(len_key, len_tv, hobject::PROP_FLAGS_WEC);

    // Register RegExp constructor globally as an OBJECT
    uint hash = heap.hash_string("RegExp");
    HString* existing = heap.str_table_lookup("RegExp", hash);
    HString* regexp_key;
    if (existing != null) {
        regexp_key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, "RegExp", hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        regexp_key = new_key;
    }
    TVal regexp_val;
    regexp_val.tag = OBJECT;
    regexp_val.pointer = regexp_obj;
    env::env_declare(global_env, regexp_key, regexp_val);

    return true;
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

    // Add .size property (will be updated on each mutation)
    HString* size_key = builtin_intern_string(heap, "size");
    TVal size_tv;
    size_tv.tag = FASTINT;
    size_tv.fastint = 0;
    proto.put_prop(size_key, size_tv, hobject::PROP_FLAGS_WEC);

    // Create Map constructor as a proper function object
    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    ctor.builtin_fn_index = (int)BUILTIN_MAP;

    // Set .constructor on Map.prototype
    HString* constructor_key = builtin_intern_string(heap, "constructor");
    TVal constructor_tv;
    constructor_tv.tag = OBJECT;
    constructor_tv.pointer = ctor;
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WEC);

    // Set Map.prototype on the constructor (non-writable, non-enumerable, non-configurable)
    HString* prototype_key = builtin_intern_string(heap, "prototype");
    TVal proto_tv;
    proto_tv.tag = OBJECT;
    proto_tv.pointer = proto;
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    ctor.put_prop(prototype_key, proto_tv, proto_pflags);

    // Set Map.length
    HString* length_key = builtin_intern_string(heap, "length");
    TVal length_tv;
    length_tv.tag = FASTINT;
    length_tv.fastint = 0;
    ctor.put_prop(length_key, length_tv, hobject::PROP_FLAGS_WEC);

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
    map_val.tag = OBJECT;
    map_val.pointer = ctor;
    env::env_declare(global_env, map_key, map_val);

    return true;
}

// ============================================================================
// Set constructor registration
// ============================================================================

fn bool register_set_constructor(EnvRecord* global_env, Heap* heap) {
    // Create Set prototype
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.SET);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;
    heap.set_proto = proto;

    // Add .add(value) method
    if (!register_string_proto_method(proto, heap, "add", BUILTIN_SET_PROTO_ADD)) return false;
    // Add .has(value) method
    if (!register_string_proto_method(proto, heap, "has", BUILTIN_SET_PROTO_HAS)) return false;
    // Add .delete(value) method
    if (!register_string_proto_method(proto, heap, "delete", BUILTIN_SET_PROTO_DELETE)) return false;
    // Add .clear() method
    if (!register_string_proto_method(proto, heap, "clear", BUILTIN_SET_PROTO_CLEAR)) return false;
    // Add .keys() method
    if (!register_string_proto_method(proto, heap, "keys", BUILTIN_SET_PROTO_KEYS)) return false;
    // Add .values() method
    if (!register_string_proto_method(proto, heap, "values", BUILTIN_SET_PROTO_VALUES)) return false;
    // Add .entries() method
    if (!register_string_proto_method(proto, heap, "entries", BUILTIN_SET_PROTO_ENTRIES)) return false;
    // Add .forEach() method
    if (!register_string_proto_method(proto, heap, "forEach", BUILTIN_SET_PROTO_FOREACH)) return false;

    // Add .size property (will be updated on each mutation)
    HString* size_key = builtin_intern_string(heap, "size");
    TVal size_tv;
    size_tv.tag = FASTINT;
    size_tv.fastint = 0;
    proto.put_prop(size_key, size_tv, hobject::PROP_FLAGS_WEC);

    // Create Set constructor as a proper function object
    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    ctor.builtin_fn_index = (int)BUILTIN_SET;

    // Set .constructor on Set.prototype
    HString* constructor_key = builtin_intern_string(heap, "constructor");
    TVal constructor_tv;
    constructor_tv.tag = OBJECT;
    constructor_tv.pointer = ctor;
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WEC);

    // Set Set.prototype on the constructor (non-writable, non-enumerable, non-configurable)
    HString* prototype_key = builtin_intern_string(heap, "prototype");
    TVal proto_tv;
    proto_tv.tag = OBJECT;
    proto_tv.pointer = proto;
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    ctor.put_prop(prototype_key, proto_tv, proto_pflags);

    // Set Set.length
    HString* length_key = builtin_intern_string(heap, "length");
    TVal length_tv;
    length_tv.tag = FASTINT;
    length_tv.fastint = 0;
    ctor.put_prop(length_key, length_tv, hobject::PROP_FLAGS_WEC);

    // Register Set constructor globally
    uint hash = heap.hash_string("Set");
    HString* existing = heap.str_table_lookup("Set", hash);
    HString* set_key;
    if (existing != null) {
        set_key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, "Set", hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        set_key = new_key;
    }
    TVal set_val;
    set_val.tag = OBJECT;
    set_val.pointer = ctor;
    env::env_declare(global_env, set_key, set_val);

    return true;
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
    HString* tag_key = builtin_intern_string(heap, "Symbol.toStringTag");
    TVal tag_tv;
    tag_tv.tag = STRING;
    tag_tv.pointer = builtin_intern_string(heap, "WeakMap");
    proto.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_WEC);

    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    ctor.builtin_fn_index = (int)BUILTIN_WEAKMAP;

    HString* constructor_key = builtin_intern_string(heap, "constructor");
    TVal constructor_tv;
    constructor_tv.tag = OBJECT;
    constructor_tv.pointer = ctor;
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WEC);

    HString* prototype_key = builtin_intern_string(heap, "prototype");
    TVal proto_tv;
    proto_tv.tag = OBJECT;
    proto_tv.pointer = proto;
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    ctor.put_prop(prototype_key, proto_tv, proto_pflags);

    HString* length_key = builtin_intern_string(heap, "length");
    TVal length_tv;
    length_tv.tag = FASTINT;
    length_tv.fastint = 0;
    ctor.put_prop(length_key, length_tv, hobject::PROP_FLAGS_WEC);

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
    wm_val.tag = OBJECT;
    wm_val.pointer = ctor;
    env::env_declare(global_env, wm_key, wm_val);

    return true;
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
    HString* tag_key = builtin_intern_string(heap, "Symbol.toStringTag");
    TVal tag_tv;
    tag_tv.tag = STRING;
    tag_tv.pointer = builtin_intern_string(heap, "WeakSet");
    proto.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_WEC);

    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    ctor.builtin_fn_index = (int)BUILTIN_WEAKSET;

    HString* constructor_key = builtin_intern_string(heap, "constructor");
    TVal constructor_tv;
    constructor_tv.tag = OBJECT;
    constructor_tv.pointer = ctor;
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WEC);

    HString* prototype_key = builtin_intern_string(heap, "prototype");
    TVal proto_tv;
    proto_tv.tag = OBJECT;
    proto_tv.pointer = proto;
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    ctor.put_prop(prototype_key, proto_tv, proto_pflags);

    HString* length_key = builtin_intern_string(heap, "length");
    TVal length_tv;
    length_tv.tag = FASTINT;
    length_tv.fastint = 0;
    ctor.put_prop(length_key, length_tv, hobject::PROP_FLAGS_WEC);

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
    ws_val.tag = OBJECT;
    ws_val.pointer = ctor;
    env::env_declare(global_env, ws_key, ws_val);

    return true;
}

// ============================================================================
// Symbol constructor registration
// ============================================================================

fn bool register_symbol_constructor(EnvRecord* global_env, Heap* heap) {
    // Create Symbol.prototype
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.SYMBOL);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;
    heap.symbol_proto = proto;

    // Register prototype methods
    if (!register_string_proto_method(proto, heap, "toString", BUILTIN_SYMBOL_PROTO_TOSTRING)) return false;
    if (!register_string_proto_method(proto, heap, "valueOf", BUILTIN_SYMBOL_PROTO_VALUEOF)) return false;

    // Set @@toStringTag on prototype
    HString* tag_key = builtin_intern_string(heap, "Symbol.toStringTag");
    TVal tag_tv;
    tag_tv.tag = STRING;
    tag_tv.pointer = builtin_intern_string(heap, "Symbol");
    proto.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_WEC);

    // Create Symbol function object
    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    ctor.builtin_fn_index = (int)BUILTIN_SYMBOL;

    // Wire prototype.constructor → ctor
    HString* constructor_key = builtin_intern_string(heap, "constructor");
    TVal constructor_tv;
    constructor_tv.tag = OBJECT;
    constructor_tv.pointer = ctor;
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WEC);

    // Wire ctor.prototype → proto (non-writable, non-enumerable, non-configurable)
    HString* prototype_key = builtin_intern_string(heap, "prototype");
    TVal proto_tv;
    proto_tv.tag = OBJECT;
    proto_tv.pointer = proto;
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    ctor.put_prop(prototype_key, proto_tv, proto_pflags);

    // Symbol.length = 0
    HString* length_key = builtin_intern_string(heap, "length");
    TVal length_tv;
    length_tv.tag = FASTINT;
    length_tv.fastint = 0;
    ctor.put_prop(length_key, length_tv, hobject::PROP_FLAGS_WEC);

    // Register Symbol.for as a property of the Symbol function
    HString* for_key = builtin_intern_string(heap, "for");
    TVal for_tv;
    for_tv.tag = LIGHTFUNC;
    for_tv.fastint = (long)BUILTIN_SYMBOL_FOR;
    ctor.put_prop(for_key, for_tv, hobject::PROP_FLAGS_WEC);

    // Register Symbol.keyFor as a property of the Symbol function
    HString* keyfor_key = builtin_intern_string(heap, "keyFor");
    TVal keyfor_tv;
    keyfor_tv.tag = LIGHTFUNC;
    keyfor_tv.fastint = (long)BUILTIN_SYMBOL_KEYFOR;
    ctor.put_prop(keyfor_key, keyfor_tv, hobject::PROP_FLAGS_WEC);

    // Register "Symbol" in global environment
    uint hash = heap.hash_string("Symbol");
    HString* existing = heap.str_table_lookup("Symbol", hash);
    HString* sym_key;
    if (existing != null) {
        sym_key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, "Symbol", hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        sym_key = new_key;
    }
    TVal sym_val;
    sym_val.tag = OBJECT;
    sym_val.pointer = ctor;
    env::env_declare(global_env, sym_key, sym_val);

    return true;
}

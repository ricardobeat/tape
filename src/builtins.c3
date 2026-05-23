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
const uint BUILTIN_COUNT       = 6;

struct BuiltinContext {
    void* vm;
    TVal* regs;
    ushort base_reg;
    ushort argc;
    TVal* result;
    Heap* heap;
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

    return true;
}

fn bool register_global_constant(EnvRecord* global_env, Heap* heap, char[] name,
                                  TValTag tag, double number_val, long fastint_val) {
    uint hash = heap.hash_string(name);
    HString*? key = hstring::hstring_alloc(heap, name, hash);
    if (catch err = key) {
        return false;
    }
    heap.str_table_insert(key);
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
    HString*? key = hstring::hstring_alloc(heap, name, hash);
    if (catch err = key) {
        return false;
    }
    heap.str_table_insert(key);

    TVal val;
    val.tag = LIGHTFUNC;
    val.fastint = (long)fn_index;
    env::env_declare(global_env, key, val);
    return true;
}

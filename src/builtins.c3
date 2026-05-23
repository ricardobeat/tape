/// Built-in function registry for the Duktape C3 port.
module duktape::builtins;

import duktape::types;
import duktape::hstring;
import duktape::hobject;
import duktape::heap;
import duktape::env;
import std::io;
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
            long iv = (long)v;
            if ((double)iv == v && iv >= -9007199254740991 && iv <= 9007199254740991) {
                io::printf("%d", iv);
            } else {
                io::printf("%f", v);
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

fn void dispatch_builtin(uint fn_index, BuiltinContext* ctx) {
    switch (fn_index) {
        case BUILTIN_PRINT:
            builtin_print(ctx);
        case BUILTIN_CONSOLE_LOG:
            builtin_console_log(ctx);
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

    return true;
}

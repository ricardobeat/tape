/// Duktape C3 port — CLI runner with debug and compile-only flags.
///
/// Usage:
///   ./out/duktape_c3 <js_file>             # normal execution
///   ./out/duktape_c3 --debug <js_file>     # print each stage
///   ./out/duktape_c3 --compile-only <file>  # disassemble bytecode, no exec
///   ./out/duktape_c3 --help                 # show usage
module duktape_c3;

import duktape::compiler;
import duktape::vm;
import duktape::heap;
import duktape::lexer;
import duktape::bytecode;
import duktape::types;
import std::io;
import std::time;
import libc;

fn void print_usage(String argv0) {
    io::eprintfn("Usage:");
    io::eprintfn("  %s <js_file>                          Run JS file", argv0);
    io::eprintfn("  %s --debug <js_file>                   Print each stage with timing", argv0);
    io::eprintfn("  %s --compile-only <js_file>             Disassemble bytecode, no execution", argv0);
    io::eprintfn("  %s --help                               Show this message", argv0);
}

fn int main(String[] args) {
    if (args.len < 2) {
        print_usage(args.len > 0 ? args[0] : "duktape_c3");
        return 1;
    }

    bool debug = false;
    bool compile_only = false;
    String? path_opt;

    for (uint i = 1; i < (uint)args.len; i++) {
        if (args[i] == "--help") {
            print_usage(args[0]);
            return 0;
        } else if (args[i] == "--debug") {
            debug = true;
        } else if (args[i] == "--compile-only") {
            compile_only = true;
        } else if (args[i].len > 0 && args[i].ptr[0] != '-') {
            path_opt = args[i];
        } else {
            io::eprintfn("Unknown option: %s", args[i]);
            return 1;
        }
    }

    String path;
    if (try p = path_opt) {
        path = p;
    } else {
        io::eprintfn("No JS file specified\n");
        print_usage(args[0]);
        return 1;
    }

    time::Time t0 = debug ? time::now() : (time::Time)0;
    char[]? source_opt = file::load_temp(path);
    if (catch err = source_opt) {
        io::eprintfn("Failed to read: %s", path);
        return 1;
    }
    char[] source = source_opt;
    if (debug) io::printfn("  load source: %d us", (int)(time::now() - t0));

    time::Time t1 = debug ? time::now() : (time::Time)0;
    Heap*? hp = heap::create(null, null, null, null, null);
    if (catch err = hp) {
        io::eprintfn("heap::create failed");
        return 1;
    }
    defer hp.destroy();
    if (debug) io::printfn("  heap create: %d us", (int)(time::now() - t1));

    time::Time t2 = debug ? time::now() : (time::Time)0;
    Vm*? v = vm::vm_create(hp);
    if (catch err = v) {
        io::eprintfn("vm::create failed");
        return 1;
    }
    defer vm::vm_destroy(v);
    if (debug) io::printfn("  vm create:   %d us", (int)(time::now() - t2));

    time::Time t3 = debug ? time::now() : (time::Time)0;
    Lexer lx = lexer::lexer_init(source, hp);
    CompiledFunction*? func = compiler::compile(&lx, hp);
    if (catch err = func) {
        io::eprintfn("compile failed");
        return 1;
    }
    if (debug) io::printfn("  compile:     %d us", (int)(time::now() - t3));

    if (compile_only) {
        io::printn("--- Bytecode ---");

        // Dump top-level function
        dump_function(*func, 0);

        // Dump inner functions
        for (uint i = 0; i < func.inner_count; i++) {
            bytecode::CompiledFunction* inner = func.inner_funcs[i];
            if (inner != null) {
                io::printfn("\n--- Inner function %d ---", i);
                dump_function(*inner, 0);
            }
        }

        io::printn("--- End bytecode ---");
        return 0;
    }

    time::Time t4 = debug ? time::now() : (time::Time)0;
    TVal? res = v.execute(func);
    if (catch err = res) {
        io::eprintfn("execute failed: %s", err);
        return 1;
    }
    if (debug) io::printfn("  execute:     %d us", (int)(time::now() - t4));

    return 0;
}

/// Print a human-readable disassembly of a CompiledFunction.
fn void dump_function(bytecode::CompiledFunction f, uint indent) {
    char[200] line_buf;

    for (uint i = 0; i < f.code_count; i++) {
        usz written = f.code[i].disassemble(line_buf[..]);
        uint end = written < (usz)line_buf.len ? (uint)written : line_buf.len;
        String instr = (String)line_buf[0:end];
        if (indent > 0) {
            io::print("  ");
        }
        io::printfn("[%3d] %s", i, instr);
    }
}

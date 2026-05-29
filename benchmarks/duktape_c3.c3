/// Duktape C3 port — minimal CLI runner.
///
/// Usage: ./out/duktape_c3 <js_file>
///
/// Loads a JS file, compiles, executes, and exits. Designed to be invoked
/// multiple times by the benchmark shell script (same as duktape_orig / qjs).
module duktape_c3;

import duktape::compiler;
import duktape::vm;
import duktape::heap;
import duktape::lexer;
import duktape::bytecode;
import duktape::types;
import std::io;
import libc;

fn int main(String[] args) {
    if (args.len < 2) {
        io::eprintfn("Usage: %s <js_file>", args.len > 0 ? args[0] : "duktape_c3");
        return 1;
    }

    String path = args[1];

    char[]? source_opt = file::load_temp(path);
    if (catch err = source_opt) {
        io::eprintfn("Failed to read: %s", path);
        return 1;
    }
    char[] source = source_opt;

    Heap*? hp = heap::create(null, null, null, null, null);
    if (catch err = hp) {
        io::eprintfn("heap::create failed");
        return 1;
    }
    defer hp.destroy();

    Vm*? v = vm::vm_create(hp);
    if (catch err = v) {
        io::eprintfn("vm::create failed");
        return 1;
    }
    defer vm::vm_destroy(v);

    Lexer lx = lexer::lexer_init(source, hp);
    CompiledFunction*? func = compiler::compile(&lx, hp);
    if (catch err = func) {
        io::eprintfn("compile failed");
        return 1;
    }

    TVal? res = v.execute(func);
    if (catch err = res) {
        io::eprintfn("execute failed: %s", err);
        return 1;
    }

    return 0;
}

module test_vm;

import duktape::compiler;
import duktape::vm;
import duktape::heap;
import duktape::env;
import duktape::lexer;
import duktape::types;
import duktape::bytecode;
import std::io;
import libc;

fn int main(String[] args) {
    String path = args.len > 1 ? args[1] : "test/simple.js";
    char[]? source = file::load_temp(path);
    if (catch err = source) { io::eprintfn("Failed to read"); return 1; }

    Heap*? hp = heap::create(null, null, null, null, null);
    if (catch h = hp) { io::eprintfn("Failed heap"); return 1; }
    defer hp.destroy();

    Vm*? v = vm::vm_create(hp);
    if (catch err = v) { io::eprintfn("VM failed"); return 1; }
    defer vm::vm_destroy(v);

    Lexer lex = lexer::lexer_init(source, hp);
    CompiledFunction*? func = compiler::compile(&lex, hp);
    CompiledFunction* f;
    if (try ff = func) { f = ff; } else { io::eprintfn("Compile failed"); return 1; }

    TVal? result = v.execute(f);
    if (catch err = result) { io::eprintfn("VM error: %s (at execute)", err); return 1; }
    return 0;
}

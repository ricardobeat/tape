module test_vm;

import duktape::compiler;
import duktape::vm;
import duktape::heap;
import duktape::env;
import duktape::lexer;
import duktape::types;
import duktape::bytecode;
import duktape::hstring;
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

    // Dump bytecode
    io::printfn("=== OUTER FUNCTION (%d insns, %d regs, %d consts, %d inner) ===", f.code_count, f.num_regs, f.const_count, f.inner_count);
    for (uint i = 0; i < f.code_count; i++) {
        char[128] buf;
        buf[0] = 0;
        usz len = f.code[i].disassemble(&buf);
        buf[len] = 0;
        for (usz j = 0; j < len; j++) { io::putchar(buf[j]); }
        io::putchar('\n');
    }

    // Dump inner functions
    for (uint i = 0; i < f.inner_count; i++) {
        CompiledFunction* inner = f.inner_funcs[i];
        io::printfn("=== INNER[%d] (%d insns, %d regs, %d consts) ===", i, inner.code_count, inner.num_regs, inner.const_count);
        for (uint j = 0; j < inner.code_count; j++) {
            char[128] buf2;
            buf2[0] = 0;
            usz len2 = inner.code[j].disassemble(&buf2);
            buf2[len2] = 0;
            for (usz k = 0; k < len2; k++) { io::putchar(buf2[k]); }
            io::putchar('\n');
        }
    }

    io::printfn("=== EXECUTING ===");

    TVal? result = v.execute(f);
    if (catch err = result) { io::eprintfn("VM error"); return 1; }
    return 0;
}

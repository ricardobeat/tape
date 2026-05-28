/// Benchmark runner for Duktape C3 port.
///
/// Usage: ./out/bench_run <js_file> [iterations]
///
/// Loads the JS file, runs a warmup iteration, then runs the specified
/// number of timed iterations (default 5), reporting per-iteration
/// wall-clock time (compile + execute) and summary statistics.
///
/// Each iteration gets a fresh heap + VM for clean state isolation.
module bench_run;

import duktape::compiler;
import duktape::vm;
import duktape::heap;
import duktape::env;
import duktape::lexer;
import duktape::types;
import duktape::bytecode;
import duktape::hstring;
import std::io;
import std::time;
import std::time::clock;
import libc;

/// Run one iteration: create heap+VM, compile, execute, return elapsed ns.
fn long run_one(char[] source) {
    Clock t0 = clock::now();

    Heap*? hp = heap::create(null, null, null, null, null);
    if (catch err = hp) { io::eprintfn("heap::create failed"); return -1; }
    defer hp.destroy();

    Vm*? v = vm::vm_create(hp);
    if (catch err = v) { io::eprintfn("vm::create failed"); return -1; }
    defer vm::vm_destroy(v);

    Lexer lx = lexer::lexer_init(source, hp);
    CompiledFunction*? func = compiler::compile(&lx, hp);
    if (catch err = func) { io::eprintfn("compile failed"); return -1; }
    CompiledFunction* f = func;

    TVal? res = v.execute(f);
    if (catch err = res) { io::eprintfn("execute failed: %s", err); return -1; }

    Clock t1 = clock::now();
    return (long)(t1 - t0);
}

fn int main(String[] args) {
    if (args.len < 2) {
        io::eprintfn("Usage: %s <js_file> [iterations]", args.len > 0 ? args[0] : "bench_run");
        return 1;
    }

    String path = args[1];
    uint iterations = args.len >= 3 ? (uint)atoi(args[2]) : 5u;

    // Load source
    char[]? source_opt = file::load_temp(path);
    if (catch err = source_opt) {
        io::eprintfn("Failed to read: %s", path);
        return 1;
    }
    char[] source = source_opt;

    // Warmup (results discarded)
    long warmup = run_one(source);
    if (warmup < 0) {
        io::eprintfn("Warmup failed for %s", path);
        return 1;
    }

    // Timed iterations
    long[256] times;
    uint count = iterations < 256 ? iterations : 256;
    for (uint i = 0; i < count; i++) {
        long elapsed = run_one(source);
        if (elapsed < 0) {
            io::eprintfn("Iteration %d failed for %s", i, path);
            return 1;
        }
        times[i] = elapsed;
    }

    // Compute statistics
    long total = 0;
    long min_val = times[0];
    long max_val = times[0];
    for (uint i = 0; i < count; i++) {
        total += times[i];
        if (times[i] < min_val) { min_val = times[i]; }
        if (times[i] > max_val) { max_val = times[i]; }
    }
    long avg = total / (long)count;
    double avg_ms = (double)avg / 1_000_000.0;
    double min_ms = (double)min_val / 1_000_000.0;
    double max_ms = (double)max_val / 1_000_000.0;
    double total_s = (double)total / 1_000_000_000.0;

    // Summary line (one line, machine-parseable)
    // BENCH_RESULT <path> <count> <avg_ms> <min_ms> <max_ms> <total_s>
    io::printfn("BENCH_RESULT %s %d %.3f %.3f %.3f %.3f",
                path, count, avg_ms, min_ms, max_ms, total_s);
    return 0;
}

/// Minimal atoi for C3
fn int atoi(String s) {
    int r = 0;
    for (uint i = 0; i < (uint)s.len; i++) {
        char c = s[i];
        if (c < '0' || c > '9') break;
        r = r * 10 + (int)(c - '0');
    }
    return r;
}

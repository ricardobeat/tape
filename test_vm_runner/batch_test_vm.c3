/// Batch test262 runner — uses __resetGlobals() to restore global state
/// between tests, all in one process.  No fork, no serialization.
///
/// Usage: ./out/batch_test_vm <manifest_file>
module batch_test_vm;

import duktape::compiler;
import duktape::vm;
import duktape::heap;
import duktape::env;
import duktape::lexer;
import duktape::types;
import duktape::bytecode;
import duktape::hstring;
import duktape::builtins;
import std::io;
import libc;

// ============================================================================
// Test manifest reader
// ============================================================================

struct TestEntry {
    char[4096] path;
    uint       len;
}

fn int read_manifest(char[] mpath, TestEntry* entries, uint max_entries) {
    char[]? content = file::load_temp((String)mpath);
    if (catch err = content) { return -1; }
    char[] data = content;
    uint count = 0;
    usz pos = 0;
    while (pos < data.len && count < max_entries) {
        usz start = pos;
        while (pos < data.len && data[pos] != '\n' && data[pos] != '\r') { pos++; }
        usz line_len = pos - start;
        while (pos < data.len && (data[pos] == '\n' || data[pos] == '\r')) { pos++; }
        if (line_len > 0) {
            usz copy = line_len < 4096 ? line_len : 4095;
            libc::memcpy(&entries[count].path[0], &data[start], copy);
            entries[count].path[copy] = 0;
            entries[count].len = (uint)copy;
            count++;
        }
    }
    return (int)count;
}

// ============================================================================
// Run one test with a fresh heap+VM (gold-standard isolation)
// ============================================================================

fn int run_test_fresh(char[] test_path) {
    Heap*? hp = heap::create(null, null, null, null, null);
    if (catch h = hp) { return 1; }
    defer hp.destroy();

    Vm*? v = vm::vm_create(hp);
    if (catch err = v) { return 1; }
    defer vm::vm_destroy(v);

    // Load and execute test source directly
    char[]? source = file::load_temp((String)test_path);
    if (catch err = source) { return 1; }
    char[] src = source;

    // First, compile+execute the test262 harness setup
    char[] harness = "var __test262_fail=0;function Test262Error(msg){__test262_fail++;}Test262Error.thrower=function(m){throw new Test262Error(m);}Test262Error.prototype.toString=function(){return'Test262Error';}function $DONOTEVALUATE(){}function $ERROR(msg){__test262_fail++;}function $FAIL(msg){__test262_fail++;}";
    {
        Lexer lx = lexer::lexer_init(harness, hp);
        CompiledFunction*? f = compiler::compile(&lx, hp);
        if (catch err = f) return 1;
        if (catch err = v.execute(f)) return 1;
    }

    // Now compile+execute the test
    Lexer lx2 = lexer::lexer_init(src, hp);
    CompiledFunction*? f2 = compiler::compile(&lx2, hp);
    if (catch err = f2) return 1;
    if (catch err = v.execute(f2)) return 1;

    // Check __test262_fail via the string table lookup
    char[] kn = "__test262_fail";
    uint hh = hp.hash_string(kn);
    HString*? ks = hp.str_table_lookup(kn, hh);
    if (try k = ks) {
        TVal? tv = env::env_get(v.global_env, k);
        if (try val = tv) {
            return (val.fastint == 0) ? 0 : 1;
        }
    }
    return 1;
}

// ============================================================================
// Main
// ============================================================================

fn int main(String[] args) {
    if (args.len < 2) {
        io::eprintfn("Usage: batch_test_vm <manifest_file>");
        return 1;
    }

    const uint MAX_TESTS = 100000;
    usz eb = TestEntry::size * MAX_TESTS;
    TestEntry* entries = (TestEntry*)libc::malloc(eb);
    if (entries == null) { io::eprintfn("OOM"); return 1; }
    defer libc::free(entries);

    int num = read_manifest(args[1], entries, MAX_TESTS);
    if (num < 0) { io::eprintfn("Failed to read: %s", args[1]); return 1; }
    if (num == 0) { io::printfn("No tests."); return 0; }

    io::printfn("=== Batch test262 runner ===");
    int pass = 0;
    int fail = 0;

    for (int i = 0; i < num; i++) {
        char[] tp = entries[i].path[:entries[i].len];
        bool report = (num <= 20) || (i % 100 == 0) || (i == num - 1);

        int rc = run_test_fresh(tp);
        if (rc == 0) { pass++; } else { fail++; }

        if (report) {
            io::printfn("%s  %s", rc == 0 ? "PASS" : "FAIL", (String)tp);
        }
        if ((i + 1) % 500 == 0 || i == num - 1) {
            io::eprintfn("[%d/%d] pass=%d fail=%d", i + 1, num, pass, fail);
        }
    }

    io::printfn("---");
    io::printfn("Total: %d  Pass: %d  Fail: %d", pass + fail, pass, fail);
    return 0;
}

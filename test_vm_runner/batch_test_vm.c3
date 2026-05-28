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
// Helper: compile+execute JS source in a VM
// ============================================================================

fn int exec_js(Vm* vm, Heap* hp, char[] src) {
    Lexer lx = lexer::lexer_init(src, hp);
    CompiledFunction*? f = compiler::compile(&lx, hp);
    if (catch err = f) { return 1; }
    if (catch err = vm.execute(f)) { return 1; }
    return 0;
}

// ============================================================================
// Run one test with a fresh heap+VM (gold-standard isolation)
// ============================================================================

fn int run_test_fresh_with_harness(char[] test_path, char[] assert_src) {
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
    char[] min_harness = "var __test262_fail=0;function Test262Error(msg){this.message=msg||'';}Test262Error.prototype.toString=function(){return'Test262Error: '+this.message;};Test262Error.thrower=function(m){throw new Test262Error(m);};function $DONOTEVALUATE(){throw'Test262: This statement should not be evaluated.';}function $ERROR(msg){__test262_fail++;}function $FAIL(msg){__test262_fail++;}function isNegativeZero(v){return v===0&&1/v===-Infinity;}function isPrimitive(v){return!v||(typeof v!=='object'&&typeof v!=='function');}function formatIdentityFreeValue(v){switch(v===null?'null':typeof v){case'string':return typeof JSON!=='undefined'?JSON.stringify(v):'\"'+v+'\"';case'bigint':return String(v)+'n';case'number':if(isNegativeZero(v))return'-0';case'boolean':case'undefined':case'null':return String(v);}return'';}function formatSimpleValue(v){var b=formatIdentityFreeValue(v);if(b)return b;try{return String(v);}catch(e){if(e.name==='TypeError')return Object.prototype.toString.call(v);throw e;}}function assert(m,b){if(m===true)return;if(b===undefined)b='Expected true but got '+assert._toString(m);throw new Test262Error(b);}assert._isSameValue=function(a,b){if(a===b)return a!==0||1/a===1/b;return a!==a&&b!==b;};assert.sameValue=function(a,e,m){try{if(assert._isSameValue(a,e))return;}catch(e){throw new Test262Error(m+'(_isSameValue threw)'+e);}if(m===undefined)m='';else m+=' ';m+='Expected SameValue(«'+assert._toString(a)+'», «'+assert._toString(e)+'») to be true';throw new Test262Error(m);};assert.notSameValue=function(a,u,m){if(!assert._isSameValue(a,u))return;if(m===undefined)m='';else m+=' ';m+='Expected SameValue(«'+assert._toString(a)+'», «'+assert._toString(u)+'») to be false';throw new Test262Error(m);};assert.throws=function(e,f,m){if(typeof f!=='function')throw new Test262Error('assert.throws requires two arguments');if(m===undefined)m='';else m+=' ';try{f();}catch(t){if(typeof t!=='object'||t===null){m+='Thrown value was not an object!';throw new Test262Error(m);}else if(t.constructor!==e){var en=e.name,an=t.constructor.name;if(en===an)m+='Expected a '+en+' but got a different error constructor with the same name';else m+='Expected a '+en+' but got a '+an;throw new Test262Error(m);}return;}m+='Expected a '+e.name+' to be thrown but no exception was thrown at all';throw new Test262Error(m);};assert.compareArray=function(a,e,m){m=m===undefined?'':m;if(typeof m==='symbol')m=m.toString();if(isPrimitive(a))assert(false,'Actual argument should not be primitive. '+String(m));else if(isPrimitive(e))assert(false,'Expected argument should not be primitive. '+String(m));var r=compareArray(a,e);if(r)return;var f=compareArray.format;assert(false,'Actual '+f(a)+' and expected '+f(e)+' should have the same contents. '+String(m));};function compareArray(a,b){if(b.length!==a.length)return false;for(var i=0;i<a.length;i++){if(!assert._isSameValue(b[i],a[i]))return false;}return true;};compareArray.format=function(a){return'['+Array.prototype.map.call(a,String).join(', ')+']';};assert._formatIdentityFreeValue=formatIdentityFreeValue;assert._toString=formatSimpleValue;";
    if (exec_js(v, hp, (char[])min_harness) != 0) return 1;

    // assert.js: use pre-loaded buffer if provided, otherwise try disk
    {
        if (assert_src.len > 0) {
            exec_js(v, hp, assert_src);
        } else {
            char[]? asrc_disk = file::load_temp((String)"test262/harness/assert.js");
            if (try a = asrc_disk) {
                exec_js(v, hp, a);
            }
        }
    }

    // Now compile+execute the test
    if (exec_js(v, hp, src) != 0) return 1;

    // Check __test262_fail via the string table lookup
    char[] kn = "__test262_fail";
    uint hh = hp.hash_string(kn);
    HString*? ks = hp.str_table_lookup(kn, hh);
    if (try k = ks) {
        TVal? tv = env::env_get(v.global_env, k);
        if (try val = tv) {
            return (val.get_fastint() == 0) ? 0 : 1;
        }
    }
    return 1;
}

fn int run_test_fresh(char[] test_path) {
    return run_test_fresh_with_harness(test_path, (char[]){});
}

// ============================================================================
// Worker mode: read test paths from stdin, run each in fresh heap
// ============================================================================

fn int run_worker_loop() {
    // Pre-load assert.js once (avoid per-test disk reads)
    char[]? assert_src_opt = file::load_temp((String)"test262/harness/assert.js");
    char[] assert_src;
    if (try a = assert_src_opt) { assert_src = a; }

    // Read test paths from stdin line by line
    char[4096] buf;
    while (libc::fgets(&buf[0], 4096, libc::stdin()) != null) {
        @pool() {
            // Strip trailing newline
            usz len = libc::strlen((ZString)&buf[0]);
            while (len > 0 && (buf[len - 1] == '\n' || buf[len - 1] == '\r')) { len--; }
            buf[len] = 0;
            if (len == 0) { continue; }

            char[] path = buf[:len];
            int rc = run_test_fresh_with_harness(path, assert_src);

            if (rc == 0) {
                io::printfn("PASS %s", (String)path);
            } else {
                io::printfn("FAIL %s", (String)path);
            }
            libc::fflush(libc::stdout());
        };
    }
    return 0;
}

// ============================================================================
// Main
// ============================================================================

fn int main(String[] args) {
    if (args.len >= 2 && libc::strcmp((ZString)args[1].ptr, "--worker") == 0) {
        return run_worker_loop();
    }
    if (args.len < 2) {
        io::eprintfn("Usage: batch_test_vm <manifest_file>");
        io::eprintfn("       batch_test_vm --worker  (stdin-driven worker mode)");
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
        @pool() {
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
        };
    }

    io::printfn("---");
    io::printfn("Total: %d  Pass: %d  Fail: %d", pass + fail, pass, fail);
    return 0;
}

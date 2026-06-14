/// Batch test262 runner — reuses a single heap+VM across tests, resetting
/// state between runs to avoid per-test malloc/free churn that causes RSS bloat.
///
/// Usage: ./out/batch_test_vm <manifest_file>
///        ./out/batch_test_vm --worker   (stdin-driven worker mode)
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
// Manifest mode: read test paths from a file, run tests
// ============================================================================

fn int run_manifest_loop(char[] mpath) {
    char[]? assert_src_opt = file::load_temp((String)"test262/harness/assert.js");
    char[] assert_src;
    if (try a = assert_src_opt) { assert_src = a; }

    char[]? ph_src_opt = file::load_temp((String)"test262/harness/propertyHelper.js");
    char[] ph_src;
    if (try p = ph_src_opt) { ph_src = p; }

    libc::CFile fp = libc::fopen((ZString)mpath.ptr, "r");
    if (fp == null) { io::eprintfn("Failed to open: %s", mpath); return 1; }
    defer libc::fclose(fp);

    // Allocate the long-lived heap and VM once
    Heap*? hp_opt = heap::create(null, null, null, null, null);
    if (catch h = hp_opt) { return 1; }
    Heap* hp = hp_opt;
    defer hp.destroy();

    Vm*? v_opt = vm::vm_create(hp);
    if (catch err = v_opt) { return 1; }
    Vm* v = v_opt;

    io::printfn("=== Batch test262 runner ===");
    int pass = 0;
    int fail = 0;
    int total = 0;
    char[4096] buf;

    while (libc::fgets(&buf[0], 4096, fp) != null) {
        @pool() {
            usz len = libc::strlen((ZString)&buf[0]);
            while (len > 0 && (buf[len - 1] == '\n' || buf[len - 1] == '\r')) { len--; }
            buf[len] = 0;
            if (len == 0) { continue; }

            bool report = (total % 100 == 0);

            // Reset heap+VM — destroy+recreate VM to avoid stale-reference bugs
            hp.reset();
            vm::vm_destroy(v);
            Vm*? v2 = vm::vm_create(hp);
            if (catch err = v2) {
                fail++;
                total++;
                continue;
            }
            v = v2;

            char[] path = buf[:len];
            int rc = run_one_test(v, hp, path, assert_src, ph_src);
            if (rc == 0) { pass++; } else { fail++; }
            total++;

            if (report) {
                io::printfn("%s  %s", rc == 0 ? "PASS" : "FAIL", (String)path);
            }
            if (total % 500 == 0) {
                io::eprintfn("[%d] pass=%d fail=%d", total, pass, fail);
            }
        };
    }

    vm::vm_destroy(v);
    io::printfn("---");
    io::printfn("Total: %d  Pass: %d  Fail: %d", total, pass, fail);
    return 0;
}

// ============================================================================
// Helper: compile+execute JS source in a VM
// ============================================================================

fn int exec_js(Vm* v, Heap* hp, char[] src) {
    Lexer lx = lexer::lexer_init(src, hp);
    CompiledFunction*? f = compiler::compile(&lx, hp);
    if (catch err = f) {
        return 1;
    }
    if (catch err = v.execute(f)) {
        return 1;
    }
    return 0;
}

// ============================================================================
// Run one test, reusing an already-reset heap+VM
// ============================================================================

const char[] MIN_HARNESS = "var __test262_fail=0;function Test262Error(msg){this.message=msg||'';}Test262Error.prototype.toString=function(){return'Test262Error: '+this.message;};Test262Error.thrower=function(m){throw new Test262Error(m);};function $DONOTEVALUATE(){throw'Test262: This statement should not be evaluated.';}function $ERROR(msg){__test262_fail++;}function $FAIL(msg){__test262_fail++;}function isNegativeZero(v){return v===0&&1/v===-Infinity;}function isPrimitive(v){return!v||(typeof v!=='object'&&typeof v!=='function');}function formatIdentityFreeValue(v){switch(v===null?'null':typeof v){case'string':return typeof JSON!=='undefined'?JSON.stringify(v):'\"'+v+'\"';case'bigint':return String(v)+'n';case'number':if(isNegativeZero(v))return'-0';case'boolean':case'undefined':case'null':return String(v);}return'';}function formatSimpleValue(v){var b=formatIdentityFreeValue(v);if(b)return b;try{return String(v);}catch(e){if(e.name==='TypeError')return Object.prototype.toString.call(v);throw e;}}function assert(m,b){if(m===true)return;if(b===undefined)b='Expected true but got '+assert._toString(m);throw new Test262Error(b);}assert._isSameValue=function(a,b){if(a===b)return a!==0||1/a===1/b;return a!==a&&b!==b;};assert.sameValue=function(a,e,m){try{if(assert._isSameValue(a,e))return;}catch(e){throw new Test262Error(m+'(_isSameValue threw)'+e);}if(m===undefined)m='';else m+=' ';m+='Expected SameValue(«'+assert._toString(a)+'», «'+assert._toString(e)+'») to be true';throw new Test262Error(m);};assert.notSameValue=function(a,u,m){if(!assert._isSameValue(a,u))return;if(m===undefined)m='';else m+=' ';m+='Expected SameValue(«'+assert._toString(a)+'», «'+assert._toString(u)+'») to be false';throw new Test262Error(m);};assert.throws=function(e,f,m){if(typeof f!=='function')throw new Test262Error('assert.throws requires two arguments');if(m===undefined)m='';else m+=' ';try{f();}catch(t){if(typeof t!=='object'||t===null){m+='Thrown value was not an object!';throw new Test262Error(m);}else if(t.constructor!==e){var en=e.name,an=t.constructor.name;if(en===an)m+='Expected a '+en+' but got a different error constructor with the same name';else m+='Expected a '+en+' but got a '+an;throw new Test262Error(m);}return;}m+='Expected a '+e.name+' to be thrown but no exception was thrown at all';throw new Test262Error(m);};assert.compareArray=function(a,e,m){m=m===undefined?'':m;if(typeof m==='symbol')m=m.toString();if(isPrimitive(a))assert(false,'Actual argument should not be primitive. '+String(m));else if(isPrimitive(e))assert(false,'Expected argument should not be primitive. '+String(m));var r=compareArray(a,e);if(r)return;var f=compareArray.format;assert(false,'Actual '+f(a)+' and expected '+f(e)+' should have the same contents. '+String(m));};function compareArray(a,b){if(b.length!==a.length)return false;for(var i=0;i<a.length;i++){if(!assert._isSameValue(b[i],a[i]))return false;}return true;};compareArray.format=function(a){return'['+Array.prototype.map.call(a,String).join(', ')+']';};assert._formatIdentityFreeValue=formatIdentityFreeValue;assert._toString=formatSimpleValue;";

fn int run_one_test(Vm* v, Heap* hp, char[] test_path, char[] assert_src, char[] property_helper_src) {
    char[]? source = file::load_temp((String)test_path);
    if (catch err = source) { return 1; }
    char[] src = source;

    if (exec_js(v, hp, MIN_HARNESS) != 0) { return 1; }

    if (assert_src.len > 0) {
        exec_js(v, hp, assert_src);
    } else {
        char[]? asrc_disk = file::load_temp((String)"test262/harness/assert.js");
        if (try a = asrc_disk) { exec_js(v, hp, a); }
    }

    if (property_helper_src.len > 0) {
        exec_js(v, hp, property_helper_src);
    }

    if (exec_js(v, hp, src) != 0) { return 1; }

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

// ============================================================================
// Worker mode: read test paths from stdin
// ============================================================================

fn int run_worker_loop() {
    char[]? assert_src_opt = file::load_temp((String)"test262/harness/assert.js");
    char[] assert_src;
    if (try a = assert_src_opt) { assert_src = a; }

    char[]? ph_src_opt = file::load_temp((String)"test262/harness/propertyHelper.js");
    char[] ph_src;
    if (try p = ph_src_opt) { ph_src = p; }

    // Allocate the long-lived heap and VM once
    Heap*? hp_opt = heap::create(null, null, null, null, null);
    if (catch h = hp_opt) { return 1; }
    Heap* hp = hp_opt;
    defer hp.destroy();

    Vm*? v_opt = vm::vm_create(hp);
    if (catch err = v_opt) { return 1; }
    Vm* v = v_opt;

    char[4096] buf;
    while (libc::fgets(&buf[0], 4096, libc::stdin()) != null) {
        @pool() {
            usz len = libc::strlen((ZString)&buf[0]);
            while (len > 0 && (buf[len - 1] == '\n' || buf[len - 1] == '\r')) { len--; }
            buf[len] = 0;
            if (len == 0) { continue; }

            // Reset heap+VM — destroy+recreate VM to avoid stale-reference bugs
            hp.reset();
            vm::vm_destroy(v);
            Vm*? v2 = vm::vm_create(hp);
            if (catch err = v2) {
                io::printfn("FAIL %s", (String)buf[:len]);
                libc::fflush(libc::stdout());
                continue;
            }
            v = v2;

            char[] path = buf[:len];
            int rc = run_one_test(v, hp, path, assert_src, ph_src);

            if (rc == 0) {
                io::printfn("PASS %s", (String)path);
            } else {
                io::printfn("FAIL %s", (String)path);
            }
            libc::fflush(libc::stdout());
        };
    }
    vm::vm_destroy(v);
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
    return run_manifest_loop(args[1]);
}

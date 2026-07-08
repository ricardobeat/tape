// Oracle for plan 045: locals referenced by nested callables (or direct eval)
// must be env-resident so closure/eval reads and writes stay coherent with
// the outer function's view.
var p = 0, f = 0;
function ck(n, got, want) { if (got === want) p++; else { f++; print("FAIL " + n + ": " + got + " != " + want); } }

// closure writes, outer reads
function m1() { var x = 1; function g() { x = 2; } g(); return x; }
ck("closure-write-var", m1(), 2);
function m2() { let y = 1; function g() { y = 2; } g(); return y; }
ck("closure-write-let", m2(), 2);

// outer writes after closure creation, closure reads
function m3() { let x = 1; const g = function() { return x; }; x = 2; return g(); }
ck("outer-write-closure-read", m3(), 2);

// read-modify-write ping-pong
function m4() {
    var n = 0;
    function inc() { n++; }
    inc(); n += 10; inc();
    return n;
}
ck("rmw-pingpong", m4(), 12);

// captured accumulator via native callback
function m5() { let s = 0; [1, 2, 3].forEach(function(v) { s += v; }); return s; }
ck("callback-accumulate", m5(), 6);

// arrow capturing and mutating
function m6() { let c = 0; const bump = () => { c += 5; }; bump(); bump(); return c; }
ck("arrow-mutate", m6(), 10);

// expression-bodied arrow capturing a param
function m7(a) { const dbl = () => a * 2; a = 21; return dbl(); }
ck("arrow-expr-param", m7(1), 42);

// captured param mutated by closure
function m8(v) { function set9() { v = 9; } set9(); return v; }
ck("closure-write-param", m8(1), 9);

// eval writes to caller local
function m9() { var w = 7; eval("w = 9;"); return w; }
ck("eval-write", m9(), 9);

// eval reads updated value after outer write
function m10() { let z = 1; z = 3; return eval("z"); }
ck("eval-read-after-write", m10(), 3);

// mutation before the closure is defined, inside a loop (pre-position read)
function m11() {
    let x = 0, log = "";
    for (var i = 0; i < 2; i++) {
        log += x;
        const g = function() { x = 5; };
        g();
    }
    return log;
}
ck("loop-pre-position-read", m11(), "05");

// shadowing: inner function declares its OWN x — outer x stays register-eligible
// (false-positive capture is allowed, but the VALUE must still be right)
function m12() { var x = 1; function g() { var x = 99; return x; } g(); return x; }
ck("shadowed-name", m12(), 1);

// two closures sharing one binding
function m13() {
    let n = 0;
    const a = () => { n += 1; };
    const b = () => n;
    a(); a();
    return b();
}
ck("shared-binding", m13(), 2);

// method shorthand in object literal capturing a local
function m14() { let t = 1; const o = { bump() { t = 8; } }; o.bump(); return t; }
ck("method-shorthand", m14(), 8);

// getter capturing and reading a mutated local
function m15() {
    let v = 1;
    const o = { get val() { return v; } };
    v = 6;
    return o.val;
}
ck("getter-after-write", m15(), 6);

// class method capturing a local (degrades to capture_all)
function m16() { let k = 1; class K { get() { return k; } } k = 4; return new K().get(); }
ck("class-method-capture", m16(), 4);

// destructured local captured by closure
function m17() { const [a, b] = [1, 2]; let sum = 0; const add = () => { sum = a + b; }; add(); return sum; }
ck("destructured-capture", m17(), 3);

print(p + " passed, " + f + " failed");
if (f > 0) { throw new Error(f + " capture-analysis failures"); }

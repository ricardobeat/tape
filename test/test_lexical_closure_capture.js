// Oracle for the env-elision gate fix: functions whose only locals are
// let/const must keep their PUTLEX/PUTLEX_C/INITTZ stores (and a runtime env)
// when a nested closure reads them through the environment chain — including
// closures invoked through native callbacks, getters/setters, and constructors.
var p = 0, f = 0;
function ck(n, got, want) { if (got === want) p++; else { f++; print("FAIL " + n + ": " + got + " != " + want); } }

function c1() { const x = 1, y = 2; return function() { return x + y; }; }
ck("const-closure", c1()(), 3);

function c2() { let x = 3; return function() { return x; }; }
ck("let-closure", c2()(), 3);

function c3() { const [a, b] = [1, 2]; return function() { return a + b; }; }
ck("destr-const-closure", c3()(), 3);

function c5() { const o = { n: 5 }; return () => o.n; }
ck("arrow-const-obj", c5()(), 5);

// closure invoked through a native callback (vm_call_fn_impl path)
function c7() { const base = 10; return [1, 2, 3].map(function(v) { return v + base; }); }
ck("native-callback-read", c7().join(","), "11,12,13");

// closure used as a getter (invoke_getter path)
function c8() {
    const secret = 42;
    var o = {};
    Object.defineProperty(o, "s", { get: function() { return secret; } });
    return o.s;
}
ck("getter-capture", c8(), 42);

// closure used as a setter (vm_property path)
function c9() {
    const factor = 3;
    var store = [];
    var o = {};
    Object.defineProperty(o, "v", { set: function(x) { store.push(x * factor); } });
    o.v = 5;
    return store[0];
}
ck("setter-capture", c9(), 15);

// closure used as a constructor (construct path)
function c10() {
    const tag = "T";
    function K() { this.t = tag; }
    return new K().t;
}
ck("ctor-capture", c10(), "T");

// named function expression in a block still binds its own name
function c11() {
    const dec = 1;
    var r = (function rec(n) { return n <= 0 ? 0 : n + rec(n - dec); })(3);
    return r;
}
ck("named-fnexpr-block", c11(), 6);

// block-scoped (not body-level) lexical captured by closure
function c12() { if (true) { const z = 7; return () => z; } }
ck("block-const-closure", c12()(), 7);

print(p + " passed, " + f + " failed");
if (f > 0) { throw new Error(f + " lexical-capture failures"); }

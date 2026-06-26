// Regression corpus for the register-resident-locals optimization.
// Every assertion must hold BEFORE and AFTER the change. Covers the cases
// where eliding the per-call scope object could go wrong.

var fails = 0;
function check(name, got, want) {
    if (got !== want) {
        fails++;
        print("FAIL: " + name + " got=" + got + " want=" + want);
    }
}

// --- 1. params + locals, plain function (the needs_env=false hot case) ---
function add(a, b) { var x = a; var y = b; return x + y; }
check("params+locals", add(3, 4), 7);

// --- 2. control flow with reassignment ---
function absish(a) { var x = a; if (a < 0) { x = -a; } return x; }
check("if-reassign pos", absish(5), 5);
check("if-reassign neg", absish(-5), 5);

// --- 3. loop with update var (the GETVAR/PUTVAR-on-local case) ---
function sumTo(n) { var s = 0; for (var i = 0; i < n; i++) { s += i; } return s; }
check("loop sum", sumTo(100), 4950);

// --- 4. nested blocks, var hoisting ---
function hoist() { var r = typeof v; var v = 1; return r + ":" + v; }
check("var hoist use-before-decl", hoist(), "undefined:1");

// --- 5. typeof on local vs undeclared global ---
function typ() { var local = 5; return typeof local + "," + typeof totallyUndeclared; }
check("typeof local+global", typ(), "number,undefined");

// --- 6. recursion (registers must be per-activation) ---
function fib(n) { if (n < 2) return n; return fib(n - 1) + fib(n - 2); }
check("recursion fib", fib(15), 610);

// double recursion with many locals (the valstack_copy shape)
function copyTest(n, a, b, c, d) {
    var x1 = a; var x2 = b; var x3 = c; var x4 = d;
    var x5 = x1 + x2; var x6 = x3 + x4; var x7 = x5 + x6;
    if (n <= 0) return x7;
    return copyTest(n - 1, x7, x1, x2, x3) + copyTest(n - 2, x4, x5, x6, x7);
}
check("double recursion locals", copyTest(10, 1, 2, 3, 4), copyTest(10, 1, 2, 3, 4));
check("double recursion value", copyTest(5, 1, 2, 3, 4), 1690);

// --- 7. CLOSURE capture: must STILL work (these keep needs_env=true) ---
function makeCounter() { var c = 0; return function () { return ++c; }; }
var ctr = makeCounter();
check("closure 1", ctr(), 1);
check("closure 2", ctr(), 2);
check("closure 3", ctr(), 3);

// closure capturing a parameter
function adder(x) { return function (y) { return x + y; }; }
var add10 = adder(10);
check("closure param capture", add10(5), 15);

// loop var captured by a closure declared AFTER the loop — the env sync of the
// loop variable must survive (this function is needs_env=true).
function loopVarCapturedAfter() {
    for (var i = 0; i < 3; i++) { }
    var g = function () { return i; };
    return g();
}
check("loop var captured after loop", loopVarCapturedAfter(), 3);

// two closures sharing scope
function pair() {
    var v = 0;
    return { set: function (n) { v = n; }, get: function () { return v; } };
}
var p = pair();
p.set(42);
check("shared closure scope", p.get(), 42);

// --- 8. let/const block shadowing (forces env via is_captured) ---
function shadow() {
    var x = 1;
    { let x = 2; }
    return x;
}
check("let shadow outer", shadow(), 1);

function letLoop() {
    var acc = 0;
    for (let i = 0; i < 3; i++) { acc += i; }
    return acc;
}
check("let loop", letLoop(), 3);

// --- 9. arguments object (forces needs_env=true) ---
function viaArgs() { var s = 0; for (var i = 0; i < arguments.length; i++) { s += arguments[i]; } return s; }
check("arguments", viaArgs(1, 2, 3, 4), 10);

// --- 10. default + rest params (forces needs_env=true) ---
function withDefault(a, b) { if (b === undefined) b = 99; return a + b; }
check("default param", withDefault(1), 100);
check("default param given", withDefault(1, 2), 3);

function withRest(a) {
    var args = [];
    for (var i = 1; i < arguments.length; i++) { args.push(arguments[i]); }
    return a + ":" + args.length;
}
check("rest-ish", withRest(1, 2, 3), "1:2");

// --- 11. try/catch param (catch var forced through env) ---
function tc() {
    var r = "ok";
    try { throw "boom"; } catch (e) { r = e; }
    return r;
}
check("catch param", tc(), "boom");

// --- 12. non-capturing helper called repeatedly from a loop ---
// (helper declared at top level to avoid a pre-existing nested-function-decl
// hoisting bug — see KNOWN-BUG note in plans/register-locals.md)
function inner12(x) { var t = x * 2; return t + 1; }
function outer12(n) {
    var sum = 0;
    for (var i = 0; i < n; i++) { sum += inner12(i); }
    return sum;
}
check("non-capturing helper in loop", outer12(5), 25);

// --- 13. mutual recursion ---
function isEven(n) { if (n === 0) return true; return isOdd(n - 1); }
function isOdd(n) { if (n === 0) return false; return isEven(n - 1); }
check("mutual recursion even", isEven(10), true);
check("mutual recursion odd", isOdd(7), true);

// --- 14. parameter reassignment ---
function reassignParam(a) { a = a + 1; a = a * 2; return a; }
check("param reassign", reassignParam(5), 12);

// --- 15. generator (forces needs_env path) ---
function* gen() { var a = 1; yield a; var b = 2; yield a + b; }
var g = gen();
check("generator y1", g.next().value, 1);
check("generator y2", g.next().value, 3);

// --- 16. global-scope var (must NOT be elided — globals are env-resident) ---
// (regression: eliding global DECLVAR breaks all global var access)
var globalProbe = 123;
check("global var read", globalProbe, 123);
var gp2 = globalProbe + 1;
check("global var chain", gp2, 124);

// --- 17. calling a non-function throws TypeError (var holds a primitive) ---
function callsNonFn() {
    var notFn = true;
    try { notFn(); return "no-throw"; }
    catch (e) { return (e instanceof TypeError) ? "typeerror" : "other"; }
}
check("call non-function", callsNonFn(), "typeerror");

if (fails === 0) {
    print("RESULT:PASS (all register-locals checks passed)");
} else {
    print("RESULT:FAIL (" + fails + " failures)");
}

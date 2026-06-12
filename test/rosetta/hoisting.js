// Rosetta Code: Variable hoisting
// https://rosettacode.org/wiki/Variable_hoisting
// Tests var hoisting, function hoisting, scope edge cases.

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

// var is hoisted to function scope
function hoistTest() {
    assert(x === undefined, "var x is hoisted (undefined before init)");
    var x = 10;
    assert(x === 10, "var x initialized");
}
hoistTest();

// var inside block is still function-scoped
function blockScope() {
    var result = "before";
    if (true) {
        var result = "inside";
    }
    assert(result === "inside", "var inside block is function-scoped");
}
blockScope();

// Function hoisting
assert(typeof namedFunc === "function", "function declaration is hoisted");
function namedFunc() { return 42; }
assert(namedFunc() === 42, "hoisted function works");

// Function expression is NOT hoisted (only var)
function exprTest() {
    assert(typeof fnExpr === "undefined", "function expr var is hoisted but undefined");
    var fnExpr = function() { return 99; };
    assert(fnExpr() === 99, "function expr works after assignment");
}
exprTest();

// Hoisting in loop
function loopHoist() {
    var fns = [];
    for (var i = 0; i < 3; i++) {
        fns.push(function() { return i; });
    }
    // All closures share the same 'i', which is 3 after loop
    assert(fns[0]() === 3, "closure captures var i = 3");
    assert(fns[2]() === 3, "all share same i");
}
loopHoist();

// IIFE to capture loop variable (classic pattern)
function loopIIFE() {
    var fns = [];
    for (var i = 0; i < 3; i++) {
        (function(captured) {
            fns.push(function() { return captured; });
        })(i);
    }
    assert(fns[0]() === 0, "IIFE captures 0");
    assert(fns[1]() === 1, "IIFE captures 1");
    assert(fns[2]() === 2, "IIFE captures 2");
}
loopIIFE();

// Multiple var declarations
function multiVar() {
    var a = 1;
    var a = 2; // re-declaration is fine
    assert(a === 2, "re-declared var takes last value");
}
multiVar();

// var in catch block
function catchScope() {
    var e = "outer";
    try {
        throw "inner";
    } catch (e) {
        // e is "inner" here (catch has its own scope for the parameter)
        assert(e === "inner", "catch param shadows outer var");
    }
    // In ES3/ES5 sloppy: the catch-scoped 'e' is gone, outer 'e' returns
    assert(e === "outer", "outer var restored after catch");
}
catchScope();

print("rosetta/hoisting: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");

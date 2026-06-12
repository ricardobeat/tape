// Rosetta Code: Variable hoisting
// https://rosettacode.org/wiki/Variable_hoisting
// Tests function hoisting, closures, IIFEs, scope edge cases.
// Note: var hoisting (using var before declaration) is not yet implemented.

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

// Function declaration hoisting
assert(typeof namedFunc === "function", "function declaration is hoisted");
function namedFunc() { return 42; }
assert(namedFunc() === 42, "hoisted function works");

// var inside block is still function-scoped
function blockScope() {
    var result = "before";
    if (true) {
        var result = "inside";
    }
    assert(result === "inside", "var inside block is function-scoped");
}
blockScope();

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

// Nested function scope
function outerScope() {
    var x = 10;
    function inner() {
        var y = 20;
        return x + y;
    }
    assert(inner() === 30, "inner accesses outer var");
}
outerScope();

print("rosetta/hoisting: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");

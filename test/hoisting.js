// Rosetta Code: Variable hoisting
// https://rosettacode.org/wiki/Variable_hoisting
// Tests function hoisting, var hoisting, closures, IIFEs, scope edge cases.

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

// Function declaration hoisting
assert(typeof namedFunc === "function", "function declaration is hoisted");
function namedFunc() { return 42; }
assert(namedFunc() === 42, "hoisted function works");

// var hoisting: use before declaration in function scope
function varHoisting() {
    // 'a' is hoisted to the top of the function, so it exists as 'undefined'
    assert(a === undefined, "hoisted var is undefined before declaration");
    var a = 5;
    assert(a === 5, "hoisted var is assigned after declaration");
}
varHoisting();

// var hoisting with multiple declarations and ordering
function varHoistingOrder() {
    var result = [];
    result.push(typeof b);
    result.push(b);
    var b = 1;
    result.push(typeof b);
    result.push(b);
    return result;
}
var r = varHoistingOrder();
assert(r[0] === "undefined", "typeof hoisted var before declaration is 'undefined'");
assert(r[1] === undefined, "hoisted var value is undefined before assignment");
assert(r[2] === "number", "typeof hoisted var after declaration is 'number'");
assert(r[3] === 1, "hoisted var value is 1 after assignment");

// var hoisting with conditional - demonstrates all declarations are hoisted
function conditionalVarHoisting(flag) {
    if (flag) {
        var x = 10;
    }
    // x is hoisted, accessible outside the block
    return x;
}
assert(conditionalVarHoisting(true) === 10, "var declared inside if-block is accessible outside");
assert(conditionalVarHoisting(false) === undefined, "var declared inside if-block is hoisted but undefined when branch not taken");

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

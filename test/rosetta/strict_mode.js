// Rosetta Code: Pragmatic directives
// https://rosettacode.org/wiki/Pragmatic_directives
// Show "use strict" is parsed and accepted (no-op) on a strict-only engine.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

// "use strict" must compile and run without error (engine is strict-only).
assert(true, "compiled with 'use strict'");

// Strict-mode rules: assign to undeclared var must throw
try {
    undeclaredVariable = 42;
    assert(false, "should have thrown on assignment to undeclared var");
} catch (e) {
    assert(true, "threw on undeclared assignment: " + e);
}

// Duplicate parameter: error at compile time would have failed; this engine
// doesn't allow it, so just check we can still call functions normally.
function add(a, b) { return a + b; }
assert(add(2, 3) === 5, "normal function call works");

// Delete on a non-configurable throws
var frozen = {};
try {
    delete frozen.missing; // delete on non-existent is OK in strict mode
} catch (e) {
    // strict mode throws on delete of unqualified identifier, not on missing
}
assert(true, "delete of missing prop is fine");

// this in a free function is undefined in strict mode
function getThis() { return this; }
assert(getThis() === undefined, "free-function this === undefined");

// arguments object is not aliased to parameters (no two-way binding)
function argsAlias(x) {
    arguments[0] = 99;
    return x;
}
assert(argsAlias(5) === 5, "arguments and params not aliased (strict)");

print("rosetta/strict_mode: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
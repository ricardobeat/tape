// TDZ enforcement at block entry tests
// Verifies that accessing let/const before declaration throws ReferenceError

var pass_count = 0;
var fail_count = 0;

function assert_throws(fn, desc) {
    try { fn(); print("FAIL: " + desc + " (no throw)"); fail_count++; }
    catch(e) { print("PASS: " + desc); pass_count++; }
}

function assert_equals(actual, expected, desc) {
    if (actual === expected) { print("PASS: " + desc); pass_count++; }
    else { print("FAIL: " + desc + " (got " + actual + ")"); fail_count++; }
}

// Test 1: let before declaration should throw ReferenceError (TDZ)
function test1() {
    { var _a = x; let x = 1; }
}
assert_throws(test1, "TDZ: let before declaration throws");

// Test 2: const before declaration should throw (TDZ)
function test2() {
    { var _b = y; const y = 2; }
}
assert_throws(test2, "TDZ: const before declaration throws");

// Test 3: TDZ should NOT find outer var binding
function test3() {
    var z = 'outer';
    { var _c = z; let z = 'inner'; }
}
assert_throws(test3, "TDZ: let shadows var, access before decl throws");

// Test 4: After declaration, let works normally
function test4() {
    var result = 'bad';
    { let a = 5; result = a; }
    return result;
}
assert_equals(test4(), 5, "let after declaration works");

// Test 5: After declaration, const works normally
function test5() {
    var result = 'bad';
    { const b = 10; result = b; }
    return result;
}
assert_equals(test5(), 10, "const after declaration works");

// Test 6: Multiple declarations in one let statement
function test6() {
    { var _d = p; let p = 1, q = 2; }
}
assert_throws(test6, "TDZ: first of multiple let decls before decl throws");

// Test 7: Second of multiple declarations also in TDZ
function test7() {
    { var _e = q; let p = 1, q = 2; }
}
assert_throws(test7, "TDZ: second of multiple let decls before decl throws");

// Test 8: typeof on TDZ variable throws (ES6)
function test8() {
    { var _f = typeof tdzVar; let tdzVar = 1; }
}
assert_throws(test8, "TDZ: typeof before let declaration throws");

// Test 9: Let in if-block
function test9() {
    var outer = 'outer';
    if (true) { var _g = blockLet; let blockLet = 'inner'; }
}
assert_throws(test9, "TDZ: let in if-block");

// Test 10: Nested blocks, inner let shadows outer let
function test10() {
    { let outer = 'outer';
      { var _h = inner; let inner = 'inner'; } }
}
assert_throws(test10, "TDZ: nested block let before decl throws");

print("=== Results: " + pass_count + " pass, " + fail_count + " fail ===");

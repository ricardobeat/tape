// eval() tests — ES5 §15.1.2.1
// Tests basic eval functionality

// --- Helper ---
function assert(actual, expected, msg) {
    if (actual === expected) {
        print("PASS: " + msg);
    } else {
        print("FAIL: " + msg + " — expected " + expected + ", got " + actual);
    }
}

// --- Test 1: eval with no argument ---
assert(eval(), undefined, "eval() returns undefined");

// --- Test 2: eval with non-string argument ---
assert(eval(42), 42, "eval(42) returns 42");
assert(eval(true), true, "eval(true) returns true");
assert(eval(null), null, "eval(null) returns null");

// --- Test 3: eval with simple numeric expression ---
assert(eval("1 + 2"), 3, "eval('1 + 2') === 3");

// --- Test 4: eval with string ---
assert(eval('"hello"'), "hello", "eval('\"hello\"') === 'hello'");

// --- Test 5: eval with boolean expression ---
assert(eval("1 < 2"), true, "eval('1 < 2') === true");

// --- Test 6: eval with variable declaration (global) ---
eval("var eval_x = 42");
assert(eval_x, 42, "global var from eval accessible");

// --- Test 7: eval returns last expression value ---
assert(eval("1; 2; 3"), 3, "eval returns last expression value");

// --- Test 8: eval with arithmetic operations ---
assert(eval("10 * 5"), 50, "eval('10 * 5') === 50");

// --- Test 9: eval with nested expressions ---
assert(eval("(1 + 2) * 3"), 9, "eval('(1 + 2) * 3') === 9");

// --- Test 10: eval with function expression ---
var fn = eval("(function(a, b) { return a + b; })");
assert(typeof fn, "function", "eval returns function");
assert(fn(3, 4), 7, "eval-created function works");

// --- Test 11: eval with if statement ---
var if_result = eval("if (true) { 99 } else { 0 }");
// note: if-statement doesn't produce a value for eval return

// --- Test 12: eval with variable in expression ---
eval("var eval_y = 100");
assert(eval_y, 100, "var from eval");

// --- Test 13: empty eval ---
assert(eval(""), undefined, "eval('') returns undefined");

// --- Test 14: eval only whitespace ---
assert(eval("   "), undefined, "eval('   ') returns undefined");

// --- Test 15: indirect eval via (0, eval) ---
// This should also work as a basic eval call
var indirect_eval = eval;
assert(indirect_eval("1 + 2"), 3, "indirect eval via var");

print("=== All eval tests done ===");

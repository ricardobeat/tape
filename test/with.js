// Test: with statement (ES5 §12.10)
//
// Tests basic with-object scope, property shadowing, assignment,
// nested with, and interaction with regular variable declarations.
//
// Run: ./out/test_vm test/with.js
// Expect: all assertions pass (no output = success)

// ============================================================================
// Helper
// ============================================================================
function assert(condition, msg) {
    if (!condition) {
        print("FAIL: " + (msg || "assertion failed"));
    }
}

// ============================================================================
// Basic with: object properties become variables
// ============================================================================
var obj = { x: 10, y: 20 };
var result = 0;
with (obj) {
    result = x + y;  // reads obj.x and obj.y
}
assert(result === 30, "basic with: property access");

// ============================================================================
// Assignment inside with updates the object
// ============================================================================
var obj2 = { a: 1 };
with (obj2) {
    a = 42;
}
assert(obj2.a === 42, "with: assignment updates object property");

// ============================================================================
// Shadowing: with shadows outer variable
// ============================================================================
var name = "outer";
var obj3 = { name: "inner" };
var captured = "";
with (obj3) {
    captured = name;
}
assert(captured === "inner", "with: shadows outer variable");

// ============================================================================
// Outer variable access when not shadowed
// ============================================================================
var greeting = "hello";
var obj4 = { x: 1 };
var out = "";
with (obj4) {
    out = greeting;  // not on obj4 → resolved from outer scope
}
assert(out === "hello", "with: outer scope fallback");

// ============================================================================
// Nested with
// ============================================================================
var outer_obj = { a: 1, b: 2 };
var inner_obj = { b: 3 };
var sum = 0;
with (outer_obj) {
    with (inner_obj) {
        sum = a + b;  // a from outer_obj, b from inner_obj
    }
}
assert(sum === 4, "nested with: a=1 from outer, b=3 from inner");

// ============================================================================
// Variable declaration inside with (var goes to function scope, not with-obj)
// ============================================================================
var obj5 = { z: 99 };
var z2 = -1;
with (obj5) {
    var inside = "visible";
    z2 = z;  // reads from obj5.z
}
assert(z2 === 99, "with: reads property via with-object");
assert(inside === "visible", "with: var declaration inside with block is visible outside");

// ============================================================================
// with on string primitive (ToObject wraps it) — static access only
// ============================================================================
with ("hello") {
    // Accessing a prototype method as a value (not calling it with this)
    var fn = charAt;
}
assert(typeof fn === "function", "with on string: can access String.prototype methods");

// ============================================================================
// with on number primitive — prototype access
// ============================================================================
with (42) {
    var fn2 = toString;
}
assert(typeof fn2 === "function", "with on number: can access Number.prototype methods");

// ============================================================================
// Modifying a property on the with-object via assignment
// ============================================================================
var obj6 = { counter: 0 };
with (obj6) {
    counter = counter + 1;
}
assert(obj6.counter === 1, "with: increment property via assignment");

// ============================================================================
// Multiple assignments inside with
// ============================================================================
var obj7 = { p: 10, q: 20, r: 30 };
with (obj7) {
    p = p * 2;
    q = q + 5;
    r = r - 10;
}
assert(obj7.p === 20, "with: p *= 2");
assert(obj7.q === 25, "with: q += 5");
assert(obj7.r === 20, "with: r -= 10");

// ============================================================================
// Function scope variables are accessible inside with
// ============================================================================
var outsideVar = "from outside";
var obj8 = { insideVar: "from inside" };
var combined = "";
with (obj8) {
    combined = outsideVar + " and " + insideVar;
}
assert(combined === "from outside and from inside",
       "with: mixes outer var and with-object property");

// ============================================================================
// Nested function inside with accesses with-scope
// ============================================================================
var obj9 = { multiplier: 3 };
var outer_val = 7;
var fn_result = 0;
with (obj9) {
    function mult(n) {
        return n * multiplier;  // multiplier comes from with-scope
    }
    fn_result = mult(outer_val);
}
assert(fn_result === 21, "with: nested function accessing with-scope variable");

print("ALL PASS");

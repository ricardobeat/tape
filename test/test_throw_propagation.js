// Test: valueOf/toString throw propagation in operators
var pass = 0;
var fail = 0;

function test(name, fn) {
    try {
        fn();
        pass++;
    } catch(e) {
        fail++;
        print("FAIL " + name + ": " + e);
    }
}

function assert_eq(a, b, msg) {
    if (a !== b) { fail++; print("FAIL " + msg + ": " + a + " !== " + b); }
}

// 1. valueOf throws in arithmetic (+)
test("ADD valueOf throw", function() {
    var obj = { valueOf: function() { throw new TypeError("valueOf error"); } };
    try { obj + 1; } catch(e) { assert_eq(e.constructor.name, "TypeError", "ADD valueOf TypeError"); return; }
    fail++; print("FAIL ADD valueOf: no throw");
});

// 2. toString throws in string concat
test("ADD toString throw", function() {
    var obj = { toString: function() { throw new TypeError("toString error"); } };
    try { obj + "hello"; } catch(e) { assert_eq(e.constructor.name, "TypeError", "ADD toString TypeError"); return; }
    fail++; print("FAIL ADD toString: no throw");
});

// 3. valueOf throws in subtraction
test("SUB valueOf throw", function() {
    var obj = { valueOf: function() { throw new TypeError("valueOf error"); } };
    try { obj - 1; } catch(e) { assert_eq(e.constructor.name, "TypeError", "SUB valueOf TypeError"); return; }
    fail++; print("FAIL SUB valueOf: no throw");
});

// 4. valueOf throws in multiplication
test("MUL valueOf throw", function() {
    var obj = { valueOf: function() { throw new TypeError("valueOf error"); } };
    try { obj * 2; } catch(e) { assert_eq(e.constructor.name, "TypeError", "MUL valueOf TypeError"); return; }
    fail++; print("FAIL MUL valueOf: no throw");
});

// 5. valueOf throws in equality
test("EQ valueOf throw", function() {
    var obj = { valueOf: function() { throw new TypeError("valueOf error"); } };
    try { obj == 1; } catch(e) { assert_eq(e.constructor.name, "TypeError", "EQ valueOf TypeError"); return; }
    fail++; print("FAIL EQ valueOf: no throw");
});

// 6. valueOf throws in inequality
test("NEQ valueOf throw", function() {
    var obj = { valueOf: function() { throw new TypeError("valueOf error"); } };
    try { obj != 1; } catch(e) { assert_eq(e.constructor.name, "TypeError", "NEQ valueOf TypeError"); return; }
    fail++; print("FAIL NEQ valueOf: no throw");
});

// 7. valueOf throws in comparison
test("LT valueOf throw", function() {
    var obj = { valueOf: function() { throw new TypeError("valueOf error"); } };
    try { obj < 1; } catch(e) { assert_eq(e.constructor.name, "TypeError", "LT valueOf TypeError"); return; }
    fail++; print("FAIL LT valueOf: no throw");
});

// 8. Both valueOf and toString return non-primitive -> TypeError
test("valueOf+toString non-primitive", function() {
    var obj = { valueOf: function() { return {}; }, toString: function() { return {}; } };
    try { obj + 1; } catch(e) { assert_eq(e.constructor.name, "TypeError", "non-primitive TypeError"); return; }
    fail++; print("FAIL non-primitive: no throw");
});

// 9. valueOf throws, no catch -> ReferenceError should NOT be swallowed
test("valueOf throw in expression", function() {
    var a = { valueOf: function() { throw "custom error"; } };
    try { var x = a + 1; } catch(e) { assert_eq(e, "custom error", "custom error value"); return; }
    fail++; print("FAIL custom error: no throw");
});

// 10. ++ on object with throwing valueOf
test("INC valueOf throw", function() {
    var obj = { valueOf: function() { throw new TypeError("inc error"); } };
    try { ++obj; } catch(e) { assert_eq(e.constructor.name, "TypeError", "INC valueOf TypeError"); return; }
    fail++; print("FAIL INC valueOf: no throw");
});

print("Results: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("Test failed");

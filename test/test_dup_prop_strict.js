// Test duplicate data property names in strict mode (ES5 §11.1.5)
// Our engine is strict-only, so all code runs in strict mode.

// Test 1: Duplicate data property name should be SyntaxError
try {
    eval("({a: 1, a: 2})");
    print("FAIL: test1 - duplicate data property should throw SyntaxError");
} catch (e) {
    if (e instanceof SyntaxError) {
        print("PASS: test1 - duplicate data property throws SyntaxError");
    } else {
        print("FAIL: test1 - expected SyntaxError, got " + typeof e);
    }
}

// Test 2: Duplicate numeric property names should be SyntaxError
try {
    eval("({0: 1, 0: 2})");
    print("FAIL: test2 - duplicate numeric property should throw SyntaxError");
} catch (e) {
    if (e instanceof SyntaxError) {
        print("PASS: test2 - duplicate numeric property throws SyntaxError");
    } else {
        print("FAIL: test2 - expected SyntaxError, got " + typeof e);
    }
}

// Test 3: Numeric and string equivalent keys should be duplicate
try {
    eval("({0: 1, '0': 2})");
    print("FAIL: test3 - numeric and string '0' should be duplicate");
} catch (e) {
    if (e instanceof SyntaxError) {
        print("PASS: test3 - numeric '0' and string '0' are duplicate");
    } else {
        print("FAIL: test3 - expected SyntaxError, got " + typeof e);
    }
}

// Test 4: Non-duplicate property names should not throw
try {
    var o = {a: 1, b: 2};
    if (o.a === 1 && o.b === 2) {
        print("PASS: test4 - non-duplicate properties work");
    } else {
        print("FAIL: test4 - wrong values");
    }
} catch (e) {
    print("FAIL: test4 - unexpected error: " + e.message);
}

// Test 5: Computed property keys should not trigger duplicate check
try {
    var k = "a";
    var o = {a: 1, [k]: 2};
    if (o.a === 2) {
        print("PASS: test5 - computed property overwrites statically");
    } else {
        print("FAIL: test5 - wrong value for o.a: " + o.a);
    }
} catch (e) {
    print("FAIL: test5 - unexpected error: " + e.message);
}

// Test 6: Method shorthand should not trigger duplicate check with data property
try {
    var o = {a: 1, b() { return 2; }};
    if (o.a === 1 && o.b() === 2) {
        print("PASS: test6 - data + method with different names work");
    } else {
        print("FAIL: test6 - wrong values");
    }
} catch (e) {
    print("FAIL: test6 - unexpected error: " + e.message);
}

// Test 7: Single property no duplicate
try {
    var o = {a: 1};
    if (o.a === 1) {
        print("PASS: test7 - single property works");
    } else {
        print("FAIL: test7 - wrong value");
    }
} catch (e) {
    print("FAIL: test7 - unexpected error: " + e.message);
}

// Test 8: Empty object
try {
    var o = {};
    if (typeof o === "object") {
        print("PASS: test8 - empty object works");
    } else {
        print("FAIL: test8 - wrong type");
    }
} catch (e) {
    print("FAIL: test8 - unexpected error: " + e.message);
}

print("Done - duplicate property tests");

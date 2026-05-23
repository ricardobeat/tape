// Test TypeError on primitive value access
var pass = 0, fail = 0;

function test(desc, fn) {
    try {
        fn();
        print("FAIL: " + desc + " (no error thrown)");
        fail++;
    } catch (e) {
        if (e instanceof TypeError) {
            pass++;
        } else {
            print("FAIL: " + desc + " (wrong error: " + typeof e + ")");
            fail++;
        }
    }
}

// 1. GETPROP on null
test("null.foo", function() { null.foo; });

// 2. GETPROP on undefined
test("undefined.foo", function() { undefined.foo; });

// 3. PUTPROP on null
test("null.foo = 1", function() { null.foo = 1; });

// 4. PUTPROP on undefined
test("undefined.foo = 1", function() { undefined.foo = 1; });

// 5. CALL on non-function (number)
test("1()", function() { 1(); });

// 6. CALL on non-function (string)
test("'str'()", function() { "str"(); });

// 7. CALL on non-function (boolean)
test("true()", function() { true(); });

// 8. CALL on non-function (object that's not callable)
test("({})()", function() { ({})(1); });

// 9. new on non-callable
test("new 1", function() { new 1(); });

// Verify normal operations still work
var obj = { x: 1 };
if (obj.x === 1) { pass++; } else { fail++; print("FAIL: obj.x"); }

var arr = [42];
if (arr[0] === 42) { pass++; } else { fail++; print("FAIL: arr[0]"); }

function fn() { return 1; }
if (fn() === 1) { pass++; } else { fail++; print("FAIL: fn()"); }

print("pass: " + pass + " fail: " + fail);

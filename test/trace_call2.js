// Closer to failing scenario - with actual if/else logic
var __pass = 0;
var __fail = 0;

function add(a, b) { return a + b; }

function assert_sameValue(actual, expected, message) {
    if (actual === expected) {
        __pass = __pass + 1;
        return;
    }
    __fail = __fail + 1;
    print("FAIL: " + (message || "") + " — expected " + expected + " got " + actual);
}

print("Before call");
assert_sameValue(add(1, 1), 2, "test");
print("After call");
print("pass:", __pass, "fail:", __fail);
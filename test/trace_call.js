// Trace what happens step by step in assert_sameValue
var __fail = 0;

function add(a, b) { return a + b; }

function assert_sameValue(actual, expected, message) {
    print("In assert_sameValue:");
    print("  actual:", actual);
    print("  expected:", expected);
    print("  actual === expected:", actual === expected);
}

print("Before call");
assert_sameValue(add(1, 1), 2, "test");
print("After call");
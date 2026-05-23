// Debug to trace what values are actually compared
function traceAssert(actual, expected, message) {
    print("actual:", actual, "expected:", expected);
    print("actual === expected:", actual === expected);
    print("actual typeof:", typeof actual);
    print("expected typeof:", typeof expected);
}

function test() {
    traceAssert(1 + 1, 2, "test");
}
test();
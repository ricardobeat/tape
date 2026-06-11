// Test: Array.prototype.sort should propagate comparator errors
// Regression test for comparator exceptions being swallowed.

var arr = [3, 1, 2];
var threw = false;
var caughtErr = null;

try {
    arr.sort(function(a, b) {
        throw new Error("comparator error");
    });
} catch (e) {
    threw = true;
    caughtErr = e;
}

if (!threw) {
    throw new Error("Expected sort to propagate comparator error, but it did not throw");
}

if (!(caughtErr instanceof Error)) {
    throw new Error("Expected caught error to be an Error instance");
}

if (caughtErr.message !== "comparator error") {
    throw new Error("Expected error message 'comparator error', got: " + caughtErr.message);
}

// Also verify that a TypeError comparator check still works
var threw2 = false;
try {
    arr.sort(42);
} catch (e2) {
    threw2 = true;
}

if (!threw2) {
    throw new Error("Expected sort(non-function) to throw TypeError");
}

print("PASS");

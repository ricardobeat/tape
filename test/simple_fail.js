// Simpler test - just the failing case
function add(a, b) { return a + b; }
if (add(1, 1) === 2) {
    print("PASS");
} else {
    print("FAIL");
}
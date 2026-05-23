// Test: inline comparison vs function-return comparison
function add(a, b) { return a + b; }

// Test 1: inline
var inline = 1 + 1;
print("inline:", inline, "inline === 2:", inline === 2);

// Test 2: via function
var via_func = add(1, 1);
print("via_func:", via_func, "via_func === 2:", via_func === 2);

// Test 3: direct function return comparison
print("add(1,1) === 2:", add(1, 1) === 2);

// Test 4: inline comparison with function call result
if (add(1, 1) === 2) {
    print("PASS: direct comparison");
} else {
    print("FAIL: direct comparison");
}
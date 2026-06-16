// Regression test: JSON.parse array .push()
// Bug: JSON.parse was creating arrays without setting Array.prototype on them,
// so .push() would fail.
// See plan 026 #1.

var pass = 0, fail = 0;
var assert = function(cond, msg) {
    if (cond) { pass++; }
    else { fail++; print("FAIL: " + msg); }
};

// --- Test 1: Basic JSON.parse with array, then .push() ---
var arr = JSON.parse("[1, 2, 3]");
arr.push(4);
assert(arr.length === 4, "length after push");
assert(arr[3] === 4, "pushed value");

// --- Test 2: Nested arrays still work ---
var nested = JSON.parse("[[1], [2]]");
nested.push([3]);
assert(nested.length === 3, "nested push length");
assert(nested[2][0] === 3, "nested pushed value");

// --- Test 3: JSON.parse with reviver that modifies array ---
var result = JSON.parse('[1, 2]', function(k, v) {
    if (Array.isArray(v)) { v.push(3); return v; }
    return v;
});
assert(result.length === 3, "reviver push length");
assert(result[2] === 3, "reviver pushed value");

// --- Test 4: Empty array push ---
var empty = JSON.parse("[]");
empty.push(42);
assert(empty.length === 1, "empty array push length");
assert(empty[0] === 42, "empty array pushed value");

// --- Test 5: Array methods other than push ---
var data = JSON.parse("[3, 1, 2]");
data.sort();
assert(data[0] === 1, "sort works on parsed array");
assert(data[1] === 2, "sort works on parsed array");
assert(data[2] === 3, "sort works on parsed array");

var popped = data.pop();
assert(popped === 3, "pop returns correct value");
assert(data.length === 2, "pop reduces length");

// --- Summary ---
print("json_parse_push: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");

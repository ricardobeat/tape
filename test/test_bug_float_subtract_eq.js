// Repro for a rosetta/accumulator.js failure: subtracting 1 from a float
// whose integer part is 8 produces a value that doesn't === the literal 7.3.
function assert(cond, msg) { if (!cond) throw new Error("FAIL: " + msg); }

var x = 8.3 - 1;
assert(x === 7.3, "8.3 - 1 expected === 7.3, got " + x + " (diff=" + (x - 7.3) + ")");

print("PASS");

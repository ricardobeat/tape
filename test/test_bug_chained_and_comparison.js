// Repro for a rosetta/run_length.js failure: a chained `a >= b && a <= c`
// comparison inside a function does not short-circuit correctly on a false
// left operand and returns undefined instead of false.
function assert(cond, msg) { if (!cond) throw new Error("FAIL: " + msg); }

function isDigitCode(c) {
    return c >= 48 && c <= 57;
}

var r1 = isDigitCode(32); // space, code 32 -- should be false (32 < 48)
assert(r1 === false, "isDigitCode(32) expected false, got " + r1);

var r2 = isDigitCode(53); // '5', code 53 -- should be true
assert(r2 === true, "isDigitCode(53) expected true, got " + r2);

var r3 = isDigitCode(65); // 'A', code 65 -- should be false (65 > 57)
assert(r3 === false, "isDigitCode(65) expected false, got " + r3);

print("PASS");

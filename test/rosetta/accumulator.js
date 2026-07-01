// Rosetta Code: Accumulator factory
// https://rosettacode.org/wiki/Accumulator_factory
// Function that returns a function which adds to a captured sum.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

function accumulator(sum) {
    return function (n) {
        sum += n;
        return sum;
    };
}

var x = accumulator(1);
assert(x(5) === 6, "1+5=6");
assert(x(2.3) === 8.3, "6+2.3=8.3 (BROKEN: float subtraction / equality with 8.3)");
assert(x(-1) === 7.3, "8.3-1=7.3 (BROKEN: 8.3 - 1 != 7.3 in this engine)");

// Multiple independent accumulators
var a = accumulator(0);
var b = accumulator(100);
a(10); a(20); a(30);
b(1); b(2);
assert(a(0) === 60, "a total = 60");
assert(b(0) === 103, "b total = 103");

// Multiplicative
function multiplier(factor) {
    return function (n) {
        return factor *= n;
    };
}
var m = multiplier(2);
assert(m(3) === 6, "2*3=6");
assert(m(4) === 24, "6*4=24");
assert(m(0.5) === 12, "24*0.5=12");

print("rosetta/accumulator: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
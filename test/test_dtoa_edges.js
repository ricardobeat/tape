// Edge-case coverage for the QuickJS dtoa parser.
// We don't want subtle regressions like dropping subnormals or mishandling
// the exponent on very small/large inputs.
var failures = 0;
function assertEq(actual, expected, msg) {
    if (actual !== expected) {
        print("FAIL: " + msg + " — expected " + expected + ", got " + actual);
        failures++;
    }
}

// Subnormals.
assertEq(5e-324, 5e-324, "5e-324 subnormal");
assertEq(1e-323 / 2, 5e-324, "1e-323 / 2 === 5e-324");

// Zero.
assertEq(0.0, 0, "0.0 === 0");
assertEq(-0.0, 0, "-0.0 === 0 (SameValue: false)");
assertEq(1 / -0, -Infinity, "1 / -0 === -Infinity");
assertEq(1 / 0, Infinity, "1 / 0 === Infinity");

// Exponent edge cases.
assertEq(1e308, 1e308, "1e308");
assertEq(1e-308, 1e-308, "1e-308");
assertEq(1e308 * 10, Infinity, "overflow to Infinity");
// 1e-308 / 10 = 1e-309 (still a representable subnormal, not yet 0).
assertEq(1e-308 / 10, 1e-309, "1e-308 / 10 === 1e-309 (subnormal)");
// 1e-323 * 0.1 = 1e-324 (smallest positive normal); further underflow → 0.
assertEq(1e-324 * 0.1, 0, "1e-324 * 0.1 underflows to 0");

// Scientific notation with sign and zero exponent.
assertEq(1e0, 1, "1e0 === 1");
assertEq(1e+1, 10, "1e+1 === 10");
assertEq(1e-1, 0.1, "1e-1 === 0.1");

// Trailing dot (ES5 §7.8.3 — "1." is a valid numeric literal).
assertEq(1., 1, "1. === 1");
assertEq(1.e2, 100, "1.e2 === 100");

// Leading dot (ES5 §7.8.3 — ".5" is a valid numeric literal).
assertEq(.5, 0.5, ".5 === 0.5");
assertEq(.5e1, 5, ".5e1 === 5");

// Numeric separator still works (stripped before js_atod, per lexer).
assertEq(1_000, 1000, "1_000 === 1000");
assertEq(1_000.5, 1000.5, "1_000.5 === 1000.5");
assertEq(1.5e1_0, 1.5e10, "1.5e1_0 === 1.5e10");

// Hex literal (handled by lexer's hex parser, not js_atod).
assertEq(0x10, 16, "0x10 === 16");
assertEq(0xff, 255, "0xff === 255");

// Binary literal.
assertEq(0b101, 5, "0b101 === 5");

// Octal literal.
assertEq(0o17, 15, "0o17 === 15");

// All hex digits.
assertEq(0xdeadbeef, 3735928559, "0xdeadbeef");

if (failures > 0) {
    print("dtoa edge cases: " + failures + " assertion(s) failed");
    throw new Error("FAIL");
}
print("dtoa edge cases: all assertions passed");
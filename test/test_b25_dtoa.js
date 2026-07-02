// B25: literal / parseFloat parity for decimal numbers.
//
// js_atod is a David-Gay-style parser; for the test inputs below it agrees
// with libc::strtod on the closest-double-to-decimal rule, so the literal
// `7.3` and `parseFloat("7.3")` produce the same IEEE 754 double as every
// other JS engine (V8, SpiderMonkey, JSC, QuickJS).  Note that this means
// `8.3 - 1 !== 7.3` — the operands and result sit on opposite sides of the
// closest-double boundary, so the IEEE 754 subtraction lands one ULP above
// the literal. That's a property of the standard, not of our parser.

var failures = 0;
function assertEq(actual, expected, msg) {
    if (actual !== expected) {
        print("FAIL: " + msg + " — expected " + expected + ", got " + actual);
        failures++;
    }
}

// Literal and parseFloat round-trip to the same double.
assertEq(parseFloat("7.3"), 7.3, "parseFloat('7.3') === 7.3");
assertEq(parseFloat("8.3"), 8.3, "parseFloat('8.3') === 8.3");
assertEq(parseFloat("0.1"), 0.1, "parseFloat('0.1') === 0.1");
assertEq(parseFloat("3.14"), 3.14, "parseFloat('3.14') === 3.14");

// Decimal arithmetic matches V8 (where 6 + 2.3 happens to land on the same
// double as the literal 8.3, but 8.3 - 1 lands one ULP above 7.3).
assertEq(6 + 2.3, 8.3, "6 + 2.3 === 8.3");
assertEq(8.3 - 1, 7.3 + 8.881784197001252e-16,
         "8.3 - 1 is one ULP above 7.3 (IEEE 754 boundary)");

// Integer / power-of-2 sanity — unaffected by the parser.
assertEq(1.5 + 2.5, 4, "1.5 + 2.5 === 4");
assertEq(0.5 + 0.25, 0.75, "0.5 + 0.25 === 0.75");
assertEq(Math.pow(2, 53), 9007199254740992, "Math.pow(2, 53) integer");

// Range edges.
assertEq(1e308 * 2, Infinity, "1e308 * 2 === Infinity");
assertEq(1e-324 * 0.5, 0, "1e-324 * 0.5 === 0");

// Leading whitespace handling.
assertEq(parseInt("  42"), 42, "parseInt('  42') === 42");
assertEq(parseFloat("  3.14"), 3.14, "parseFloat('  3.14') === 3.14");

if (failures > 0) {
    print("B25 regression: " + failures + " assertion(s) failed");
    throw new Error("FAIL");
}
print("B25 regression: all assertions passed");
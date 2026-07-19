"use strict";
// Plan 056 — BigInt Phase 1 + 2 acceptance tests.

var passed = 0;
var failed = 0;
function ok(cond, label) {
    if (cond) { passed++; }
    else { failed++; console.log("FAIL: " + label); }
}
function throws(fn, ctor, label) {
    try { fn(); failed++; console.log("FAIL (no throw): " + label); }
    catch (e) {
        if (ctor && e.constructor.name !== ctor) {
            failed++; console.log("FAIL (wrong error " + e.constructor.name + "): " + label);
        } else { passed++; }
    }
}

// --- literals & typeof ---
ok(typeof 0n === "bigint", "typeof 0n");
ok(typeof 9007199254740993n === "bigint", "typeof big literal");
ok(0xFFn === 255n, "hex literal");
ok(0b1010n === 10n, "binary literal");
ok(0o77n === 63n, "octal literal");
ok(1_000n === 1000n, "separator literal");

// --- arithmetic ---
ok(10n + 20n === 30n, "add");
ok(100n * 3n === 300n, "mul");
ok(7n / 2n === 3n, "div trunc");
ok(7n % 2n === 1n, "rem");
ok(2n ** 10n === 1024n, "pow");
ok(-5n === (0n - 5n), "unary minus");
ok(~5n === -6n, "bitwise not");
ok((5n & 3n) === 1n, "bit and");
ok((5n | 2n) === 7n, "bit or");
ok((5n ^ 1n) === 4n, "bit xor");
ok((1n << 10n) === 1024n, "left shift");
ok((1024n >> 2n) === 256n, "right shift");

// --- inc/dec ---
var xi = 5n; xi++; ok(xi === 6n, "postfix ++");
var xj = 5n; ++xj; ok(xj === 6n, "prefix ++");
var xk = 5n; xk--; ok(xk === 4n, "postfix --");
var sumLoop = 0n;
for (var li = 0n; li < 5n; li++) { sumLoop += li; }
ok(sumLoop === 10n, "for loop over bigint");

// --- comparisons ---
ok(1n == 1, "1n == 1");
ok(!(1n === 1), "1n !== 1");
ok(1n < 2, "1n < 2 (number)");
ok(2n > 1n, "2n > 1n");
ok(1n <= 1n, "1n <= 1n");
ok(3n >= 2, "3n >= 2 (number)");
ok(2n == "2", "2n == '2'");
ok(!(2n === "2"), "2n !== '2'");

// --- mixed-type errors ---
throws(function () { return 1n + 1; }, "TypeError", "1n + 1 throws");
throws(function () { return 1n - 1; }, "TypeError", "1n - 1 throws");
throws(function () { return +5n; }, "TypeError", "unary +5n throws");
throws(function () { return 1n >>> 1n; }, "TypeError", "unsigned shift throws");

// --- div/mod by zero + overflow ---
throws(function () { return 1n / 0n; }, "RangeError", "1n / 0n throws");
throws(function () { return 1n % 0n; }, "RangeError", "1n % 0n throws");

// --- constructor ---
ok(BigInt(42) === 42n, "BigInt(42)");
ok(BigInt("0x10") === 16n, "BigInt('0x10')");
ok(BigInt("100") === 100n, "BigInt('100')");
ok(BigInt(true) === 1n, "BigInt(true)");
ok(BigInt(false) === 0n, "BigInt(false)");
throws(function () { return BigInt(1.5); }, "RangeError", "BigInt(1.5) throws");
throws(function () { return BigInt("xyz"); }, "SyntaxError", "BigInt('xyz') throws");
throws(function () { return new BigInt(1); }, "TypeError", "new BigInt throws");

// --- asIntN / asUintN ---
ok(BigInt.asIntN(8, 257n) === 1n, "asIntN(8,257n)");
ok(BigInt.asUintN(8, -1n) === 255n, "asUintN(8,-1n)");
ok(BigInt.asIntN(8, 128n) === -128n, "asIntN(8,128n)");
ok(BigInt.asUintN(4, 17n) === 1n, "asUintN(4,17n)");
ok(BigInt.asIntN(0, 5n) === 0n, "asIntN(0,x)");

// --- toString / valueOf ---
ok((255n).toString(16) === "ff", "toString(16)");
ok((255n).toString() === "255", "toString()");
ok((10n).toString(2) === "1010", "toString(2)");
ok((-255n).toString(16) === "-ff", "negative toString(16)");
ok((5n).valueOf() === 5n, "valueOf");

// --- ToString / interpolation ---
ok(`${42n}` === "42", "template interpolation");
ok(String(255n) === "255", "String(bigint)");
ok("v=" + 10n === "v=10", "string concat");
ok(Object.prototype.toString.call(5n) === "[object BigInt]", "toStringTag");

console.log("passed=" + passed + " failed=" + failed);

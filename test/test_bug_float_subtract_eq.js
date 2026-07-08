// IEEE 754 semantics: 8.3 - 1 must NOT equal the literal 7.3
// (double(8.3) - 1 is exact and differs from double(7.3) by 1 ulp —
// V8/JSC/SpiderMonkey all agree), and ToString must produce the
// shortest round-trip form per ES2015 §7.1.12.1.
function assert(cond, msg) { if (!cond) throw new Error("FAIL: " + msg); }

var x = 8.3 - 1;
assert(x !== 7.3, "8.3 - 1 must differ from 7.3 by 1 ulp");
assert(String(x) === "7.300000000000001", "shortest ToString, got " + x);
assert(String(0.1 + 0.2) === "0.30000000000000004", "0.1+0.2 shortest form, got " + (0.1 + 0.2));
assert(String(1e21) === "1e+21", "exponential form for 1e21, got " + 1e21);
assert(String(0.0000001) === "1e-7", "exponential form for 1e-7, got " + 0.0000001);
assert(String(123.456) === "123.456", "plain decimal round-trip");

print("PASS");

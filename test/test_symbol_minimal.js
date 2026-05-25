var s1 = Symbol("test");
var s2 = Symbol("test");
print("s1 !== s2: " + (s1 !== s2 ? "PASS" : "FAIL"));

var s3 = Symbol();
var s4 = Symbol();
print("s3 !== s4: " + (s3 !== s4 ? "PASS" : "FAIL"));

var g1 = Symbol.for("global");
var g2 = Symbol.for("global");
print("Symbol.for same: " + (g1 === g2 ? "PASS" : "FAIL"));

var k1 = Symbol.keyFor(g1);
print("Symbol.keyFor: " + (k1 === "global" ? "PASS" : "FAIL"));

var k2 = Symbol.keyFor(s1);
print("Symbol.keyFor non-global: " + (typeof k2 === "undefined" ? "PASS" : "FAIL"));

var str = s1.toString();
print("toString: " + (str === "Symbol(test)" ? "PASS" : "FAIL"));

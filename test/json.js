// JSON tests
var __failed = false;

function assert(cond, msg) {
    if (!cond) { print("FAIL: " + msg); __failed = true; }
}

// --- JSON.parse ---
assert(JSON.parse("null") === null, "parse null");
assert(JSON.parse("true") === true, "parse true");
assert(JSON.parse("false") === false, "parse false");
assert(JSON.parse("42") === 42, "parse integer");
assert(JSON.parse(" 42 ") === 42, "parse integer with whitespace");
assert(JSON.parse("-42") === -42, "parse negative integer");
assert(JSON.parse("3.14") === 3.14, "parse float");
assert(JSON.parse("\"hello\"") === "hello", "parse string");
assert(JSON.parse("\"hello\\nworld\"") === "hello\nworld", "parse string escape");
assert(JSON.parse("\"\\\"quoted\\\"\"") === "\"quoted\"", "parse string quote escape");
assert(JSON.parse("[1,2,3]").length === 3, "parse array length");
var a = JSON.parse("[1,2,3]");
assert(a[0] === 1 && a[1] === 2 && a[2] === 3, "parse array elements");
assert(JSON.parse("[]").length === 0, "parse empty array");
assert(JSON.parse("{}") !== null, "parse empty object");
var o = JSON.parse('{"a":1,"b":"two"}');
assert(o.a === 1, "parse object key a");
assert(o.b === "two", "parse object key b");
assert(JSON.parse("[1,2,3,4,5]").length === 5, "parse array length 5");
assert(JSON.parse("{\"nested\":{\"x\":10}}").nested.x === 10, "parse nested object");
assert(JSON.parse("[[1],[2]]")[0][0] === 1, "parse nested array");
assert(JSON.parse("[1,2,3,4,5,6,7,8,9,10]").length === 10, "parse longer array");

// --- JSON.stringify ---
assert(JSON.stringify(null) === "null", "stringify null");
assert(JSON.stringify(true) === "true", "stringify true");
assert(JSON.stringify(false) === "false", "stringify false");
assert(JSON.stringify(42) === "42", "stringify integer");
assert(JSON.stringify(3.14) !== "", "stringify float");
assert(JSON.stringify("hello") === '"hello"', "stringify string");
assert(JSON.stringify("he\nllo") === '"he\\nllo"', "stringify string with newline");
assert(JSON.stringify([]) === "[]", "stringify empty array");
assert(JSON.stringify([1,2,3]) === "[1,2,3]", "stringify array");
assert(JSON.stringify({}) === "{}", "stringify empty object");
assert(JSON.stringify({"a":1}) === '{"a":1}', "stringify simple object");
assert(JSON.stringify({"a":"hello","b":42}) !== "", "stringify object with multiple keys");

// --- Round trip ---
var obj = {"name":"test","value":42,"items":[1,2,3]};
var str = JSON.stringify(obj);
var parsed = JSON.parse(str);
assert(parsed.name === "test", "round trip name");
assert(parsed.value === 42, "round trip value");
assert(parsed.items.length === 3, "round trip items length");

// --- Error handling ---
var caught = false;
try { JSON.parse("{"); } catch(e) { caught = true; }
assert(caught, "parse invalid object throws");

var caught2 = false;
try { JSON.parse("[1,2,]"); } catch(e) { caught2 = true; }
assert(caught2, "parse trailing comma throws");

var caught3 = false;
try { JSON.parse("undefined"); } catch(e) { caught3 = true; }
assert(caught3, "parse undefined throws");

var caught4 = false;
try { JSON.parse("{bad}"); } catch(e) { caught4 = true; }
assert(caught4, "parse invalid syntax throws");

print(__failed ? "SOME TESTS FAILED" : "ALL JSON TESTS PASSED");

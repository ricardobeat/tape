// Test 'in' operator - flat structure, no ++
var pass = 0, fail = 0;

// 1. Basic property existence
var obj = { a: 1, b: 2, c: 3 };
if ("a" in obj) { pass = pass + 1; } else { print("FAIL: 'a' in obj"); fail = fail + 1; }
if ("b" in obj) { pass = pass + 1; } else { print("FAIL: 'b' in obj"); fail = fail + 1; }
if (!("d" in obj)) { pass = pass + 1; } else { print("FAIL: 'd' not in obj"); fail = fail + 1; }
if (!("toString" in obj)) { print("FAIL: 'toString' should be in obj via prototype"); fail = fail + 1; } else { pass = pass + 1; }

// 2. Array indices
var arr = [10, 20, 30];
if ("0" in arr) { pass = pass + 1; } else { print("FAIL: '0' in arr"); fail = fail + 1; }
if ("1" in arr) { pass = pass + 1; } else { print("FAIL: '1' in arr"); fail = fail + 1; }
if ("2" in arr) { pass = pass + 1; } else { print("FAIL: '2' in arr"); fail = fail + 1; }
if (!("3" in arr)) { pass = pass + 1; } else { print("FAIL: '3' not in arr"); fail = fail + 1; }
if ("length" in arr) { pass = pass + 1; } else { print("FAIL: 'length' in arr"); fail = fail + 1; }

// 3. Number indices work too
if (0 in arr) { pass = pass + 1; } else { print("FAIL: 0 in arr (numeric)"); fail = fail + 1; }
if (!(5 in arr)) { pass = pass + 1; } else { print("FAIL: 5 not in arr (numeric)"); fail = fail + 1; }

// 4. TypeError on non-object right side
var typeErr = false;
try {
    var x = "prop" in null;
} catch (e) {
    if (e instanceof TypeError) { typeErr = true; }
}
if (typeErr) { pass = pass + 1; } else { print("FAIL: 'prop' in null should throw TypeError"); fail = fail + 1; }

var typeErr2 = false;
try {
    var x = "prop" in undefined;
} catch (e) {
    if (e instanceof TypeError) { typeErr2 = true; }
}
if (typeErr2) { pass = pass + 1; } else { print("FAIL: 'prop' in undefined should throw TypeError"); fail = fail + 1; }

var typeErr3 = false;
try {
    var x = "prop" in 42;
} catch (e) {
    if (e instanceof TypeError) { typeErr3 = true; }
}
if (typeErr3) { pass = pass + 1; } else { print("FAIL: 'prop' in number should throw TypeError"); fail = fail + 1; }

// 5. Prototype chain properties
function Foo() {}
Foo.prototype.protoProp = 42;
var foo = new Foo();
if ("protoProp" in foo) { pass = pass + 1; } else { print("FAIL: 'protoProp' in foo (prototype)"); fail = fail + 1; }
if (!("nonexistent" in foo)) { pass = pass + 1; } else { print("FAIL: 'nonexistent' not in foo"); fail = fail + 1; }

// 6. String literals as property names
var person = { name: "Alice", age: 30 };
var p = "name";
if (p in person) { pass = pass + 1; } else { print("FAIL: p='name' in person"); fail = fail + 1; }
var q = "age";
if (q in person) { pass = pass + 1; } else { print("FAIL: q='age' in person"); fail = fail + 1; }
var r = "foo";
if (!(r in person)) { pass = pass + 1; } else { print("FAIL: r='foo' not in person"); fail = fail + 1; }

// 7. Empty object
var empty = {};
if (!("anything" in empty)) { pass = pass + 1; } else { print("FAIL: 'anything' not in empty"); fail = fail + 1; }
if ("toString" in empty) { pass = pass + 1; } else { print("FAIL: 'toString' in empty (Object.prototype)"); fail = fail + 1; }

// 8. String primitive - TypeError
var typeErr4 = false;
try {
    var x = "length" in "hello";
} catch (e) {
    if (e instanceof TypeError) { typeErr4 = true; }
}
if (typeErr4) { pass = pass + 1; } else { print("FAIL: 'prop' in string should throw TypeError"); fail = fail + 1; }

// 9. Boolean primitive - TypeError
var typeErr5 = false;
try {
    var x = "prop" in true;
} catch (e) {
    if (e instanceof TypeError) { typeErr5 = true; }
}
if (typeErr5) { pass = pass + 1; } else { print("FAIL: 'prop' in boolean should throw TypeError"); fail = fail + 1; }

print("pass: " + pass + " fail: " + fail);

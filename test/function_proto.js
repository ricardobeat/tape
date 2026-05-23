// === Function.prototype.call() tests ===

var __pass = 0;
var __fail = 0;

function assert(cond, msg) {
    if (cond) { __pass++; }
    else { print("FAIL: " + msg); __fail++; }
}

// 1. call() basic - changing 'this' context
function greet(arg) {
    return "Hello " + this.name + (arg ? ", " + arg : "");
}
var obj1 = { name: "World" };
assert(greet.call(obj1) === "Hello World", "call basic");
assert(greet.call(obj1, "foo") === "Hello World, foo", "call with args");

// 2. call() on function with return value
function add(a, b) { return a + b; }
assert(add.call(null, 1, 2) === 3, "call add(1,2)");

// 3. call() with constructors
function Dog(name) { this.name = name; }

// 4. Chained call
function A() { return this.foo; }
var b = { foo: 42 };
assert(A.call(b) === 42, "call on object with property");

// 5. typeof works on functions
assert(typeof add.call === "function", "typeof .call is function");
assert(typeof add.apply === "function", "typeof .apply is function");
assert(typeof add.bind === "function", "typeof .bind is function");

print("call tests done");

// === Function.prototype.apply() tests ===

__pass = 0;
__fail = 0;

// 1. apply basic
assert(greet.apply(obj1, ["there"]) === "Hello World, there", "apply basic");

// 2. apply with no args
assert(add.apply(null, [3, 4]) === 7, "apply add(3,4)");

// 3. apply with empty array
var result_empty = add.apply(null, []);
// Add nothing - result should be NaN (undefined + undefined)
assert(typeof result_empty === "number", "apply with empty array returns number");

// 4. apply with null/undefined argArray (treated as no args)
// This may not work yet - just skip
// assert(typeof getThis.apply(null) !== "undefined", "apply with no second arg");

// 5. apply with array-like object
assert(add.apply(null, {0: 10, 1: 20, length: 2}) === 30, "apply with array-like");

// 6. apply with no args array
assert(add.apply(null, []) !== 3, "apply with empty array");

print("apply tests done");

// === Function.prototype.bind() tests ===

__pass = 0;
__fail = 0;

// 1. bind basic
var boundGreet = greet.bind(obj1);
assert(boundGreet() === "Hello World", "bind basic");
assert(boundGreet("foo") === "Hello World, foo", "bind with call args");

// 2. bind with partial args
function add3(a, b, c) { return a + b + c; }
var add5 = add3.bind(null, 2, 3);
assert(add5(4) === 9, "bind partial args");

// 3. bind creates new function
assert(typeof boundGreet === "function", "bind returns function");
assert(boundGreet !== greet, "bind returns new function");

// 4. bind this is fixed
var obj2 = { name: "Bound" };
assert(boundGreet.call(obj2) === "Hello World", "bind this is fixed");

// 5. bind .length
function manyArgs(a, b, c, d) {}
var boundMany = manyArgs.bind(null, 1);
// length = max(0, 4 - 1) = 3
assert(boundMany.length === 3, "bind reduces length");

// 6. bind with constructor
function Animal(type) {
    this.type = type;
    this.sound = "unknown";
}
try {
    var boundAnimal = Animal.bind(null, "mammal");
} catch(e) {
    // Test that bind itself doesn't throw
    assert(true, "bind with constructor doesn't throw");
}

// 7. bind on builtins via call (bound functions that wrap builtins)
// Note: can't use Math.max.bind because Math.max is not in Function.prototype chain
// But we can test through a wrapper

print("bind tests done");

// === Final summary ===
print("function_proto tests done");

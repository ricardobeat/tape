// Object destructuring tests

var pass = 0;
var fail = 0;

function assert(cond, msg) {
    if (cond) { pass++; } else { fail++; print('FAIL: ' + msg); }
}

// Test 1: Shorthand object destructuring
var {a, b} = {a: 1, b: 2};
assert(a === 1, 'a should be 1');
assert(b === 2, 'b should be 2');

// Test 2: Single property
var {x} = {x: 42};
assert(x === 42, 'x should be 42');

// Test 3: Three properties
var {p, q, r} = {p: 10, q: 20, r: 30};
assert(p === 10, 'p should be 10');
assert(q === 20, 'q should be 20');
assert(r === 30, 'r should be 30');

// Test 4: Keyed destructuring (different binding name)
var {a: alpha, b: beta} = {a: 100, b: 200};
assert(alpha === 100, 'alpha should be 100');
assert(beta === 200, 'beta should be 200');

// Test 5: Extra properties in RHS (ignored)
var {name} = {name: 'John', age: 30};
assert(name === 'John', 'name should be John');

// Test 6: Missing property (undefined)
var {missing} = {other: 1};
assert(missing === undefined, 'missing should be undefined');

// Test 7: String values
var {greeting, target} = {greeting: 'hello', target: 'world'};
assert(greeting === 'hello', 'greeting');
assert(target === 'world', 'target');

// Test 8: Destructuring from function result
function getObj() { return {key: 'value', num: 123}; }
var {key, num} = getObj();
assert(key === 'value', 'key should be value');
assert(num === 123, 'num should be 123');

// Test 9: Mixed shorthand and keyed
var {a: one, b} = {a: 1, b: 2};
assert(one === 1, 'one should be 1');
assert(b === 2, 'b should be 2');

// Test 10: Object with expression RHS
var {c, d} = {c: 10 + 5, d: 3 * 7};
assert(c === 15, 'c should be 15');
assert(d === 21, 'd should be 21');

print('PASS: ' + pass + ' / ' + (pass + fail));

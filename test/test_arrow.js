// Arrow function tests

var pass = 0;
var fail = 0;

function assert(cond, msg) {
    if (cond) { pass++; /* print('PASS: ' + msg); */ } else { fail++; print('FAIL: ' + msg); }
}

// Test 1: single param, no parens, expression body
var add1 = x => x + 1;
assert(add1(5) === 6, 'single param arrow x => x + 1');

// Test 2: no params, expression body
var two = () => 2;
assert(two() === 2, 'no-param arrow () => 2');

// Test 3: multiple params, expression body
var sum = (a, b) => a + b;
assert(sum(3, 4) === 7, 'multi-param arrow (a, b) => a + b');

// Test 4: block body
var greet = (name) => { return 'Hello, ' + name; };
assert(greet('World') === 'Hello, World', 'block body arrow');

// Test 5: nested arrow functions
var add = a => b => a + b;
var add5 = add(5);
assert(add5(3) === 8, 'nested arrow');
assert(add(2)(3) === 5, 'nested arrow direct call');

// Test 6: arrow with no params and block body
var noop = () => {};
assert(noop() === undefined, 'empty block body returns undefined');

// Test 7: arrow with single param and parens
var ident = (x) => x;
assert(ident(42) === 42, 'single param with parens');

// Test 8: no .prototype property
assert(two.prototype === undefined, 'arrow has no prototype');

// Test 9: typeof arrow is function
assert(typeof two === 'function', 'typeof arrow is function');

print('pass: ' + pass + ' fail: ' + fail);

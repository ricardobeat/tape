// Template literal tests

var pass = 0;
var fail = 0;

function assert(cond, msg) {
    if (cond) { pass++; } else { fail++; print('FAIL: ' + msg); }
}

// Test 1: simple template with no substitutions
var t1 = `hello`;
assert(t1 === 'hello', 'simple no-substitution template');

// Test 2: empty template
var t2 = ``;
assert(t2 === '', 'empty template');

// Test 3: template with single expression
var name = 'World';
var t3 = `Hello ${name}`;
assert(t3 === 'Hello World', 'template with single expression');

// Test 4: template with number expression
var age = 25;
var t4 = `I am ${age} years old`;
assert(t4 === 'I am 25 years old', 'template with number expression');

// Test 5: template with boolean expression
var isAdmin = true;
var t5 = `admin: ${isAdmin}`;
assert(t5 === 'admin: true', 'template with boolean');

// Test 6: template with undefined expression
var u;
var t6 = `value: ${u}`;
assert(t6 === 'value: undefined', 'template with undefined');

// Test 7: template with null expression
var n = null;
var t7 = `value: ${n}`;
assert(t7 === 'value: null', 'template with null');

// Test 8: template with multiple expressions
var a = 10;
var b = 20;
var t8 = `${a} + ${b} = ${a + b}`;
assert(t8 === '10 + 20 = 30', 'template with multiple expressions');

// Test 9: template with arithmetic expression
var t9 = `2 + 3 = ${2 + 3}`;
assert(t9 === '2 + 3 = 5', 'template with arithmetic inside expression');

// Test 10: template with string concatenation inside expression
var first = 'John';
var last = 'Doe';
var t10 = `Name: ${first + ' ' + last}`;
assert(t10 === 'Name: John Doe', 'template with string concat inside expression');

// Test 11: template with function call in expression
function greet(name) { return 'Hi ' + name; }
var t11 = `${greet('Alice')}!`;
assert(t11 === 'Hi Alice!', 'template with function call in expression');

// Test 12: template with expression that has object literal
// NOTE: this requires brace tracking to work correctly
var t12 = `${ {x: 1}.x }`;
assert(t12 === '1', 'template with object literal in expression');

// Test 13: template spanning multiple lines (actual newlines)
var t13 = `line1
line2`;
assert(t13 === 'line1\nline2', 'multi-line template');

// Test 14: template with escape sequences
var t14 = `tab:\t end`;
assert(t14 === 'tab:\t end', 'template with tab escape');

// Test 15: template with escaped backtick
var t15 = `back\`tick`;
assert(t15 === 'back`tick', 'template with escaped backtick');

// Test 16: template with escaped dollar (not expression start)
var t16 = `price: \${100}`;
assert(t16 === 'price: ${100}', 'template with escaped dollar sign');

// Test 17: template inside a function
function makeGreeting(name) {
    return `Hello, ${name}!`;
}
assert(makeGreeting('Alice') === 'Hello, Alice!', 'template inside function');

// Test 18: template with computed expression
var x = 5;
var y = 10;
var t18 = `sum: ${x + y}, product: ${x * y}`;
assert(t18 === 'sum: 15, product: 50', 'template with multiple computed expressions');

// Test 19: template with zero
var t19 = `zero: ${0}`;
assert(t19 === 'zero: 0', 'template with zero value');

// Test 20: template as part of larger expression
var t20 = 'prefix' + ` middle ${1+2} ` + 'suffix';
assert(t20 === 'prefix middle 3 suffix', 'template in larger expression');

// Test 21: nested template — inner with expression
var t21 = `outer ${ `inner ${1+2} tail` } end`;
assert(t21 === 'outer inner 3 tail end', 'nested template — inner with expression');

// Test 22: nested simple template (no substitutions)
var t22 = `a${ `simple` }b`;
assert(t22 === 'asimpleb', 'nested simple template');

// Test 23: triple-nested template
var t23 = `L1 ${ `L2 ${ `L3 ${42} end3` } end2` } end1`;
assert(t23 === 'L1 L2 L3 42 end3 end2 end1', 'triple-nested template');

// Test 24: nested template with object literal in expression
var t24 = `a${ `b${ {x:1}.x }c` }d`;
assert(t24 === 'ab1cd', 'nested template with object literal');

// Test 25: nested template with arithmetic expression
var t25 = `price: ${ `$${100 + 50} total` }`;
assert(t25 === 'price: $150 total', 'nested template with arithmetic');

// Test 26: nested template with function call
function double(x) { return x * 2; }
var t26 = `result: ${ `2*3=${double(3)}` } done`;
assert(t26 === 'result: 2*3=6 done', 'nested template with function call');

// Test 27: nested template with variable from outer scope
var name27 = 'World';
var t27 = `Hello ${ `dear ${name27}` }!`;
assert(t27 === 'Hello dear World!', 'nested template accessing outer variable');

print('pass: ' + pass + ' fail: ' + fail);

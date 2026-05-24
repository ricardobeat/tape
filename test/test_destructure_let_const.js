// let/const destructuring tests

var pass = 0;
var fail = 0;

function assert(cond, msg) {
    if (cond) { pass++; } else { fail++; print('FAIL: ' + msg); }
}

// Test 1: let with array destructuring
let [a, b] = [5, 10];
assert(a === 5, 'let: a should be 5');
assert(b === 10, 'let: b should be 10');

// Test 2: const with array destructuring
const [c, d] = [15, 20];
assert(c === 15, 'const: c should be 15');
assert(d === 20, 'const: d should be 20');

// Test 3: let with object destructuring
let {x, y} = {x: 7, y: 14};
assert(x === 7, 'let: x should be 7');
assert(y === 14, 'let: y should be 14');

// Test 4: const with object destructuring
const {p, q} = {p: 21, q: 28};
assert(p === 21, 'const: p should be 21');
assert(q === 28, 'const: q should be 28');

// Test 5: let block-scoped
{
    let [m] = [100];
    assert(m === 100, 'let block-scoped: m should be 100');
}

// Test 6: const block-scoped
{
    const {n} = {n: 200};
    assert(n === 200, 'const block-scoped: n should be 200');
}

// Test 7: let with elision
let [first, , third] = [1, 2, 3];
assert(first === 1, 'let elision: first should be 1');
assert(third === 3, 'let elision: third should be 3');

// Test 8: const with keyed destructuring
const {a: alpha} = {a: 42};
assert(alpha === 42, 'const keyed: alpha should be 42');

// Test 9: let in for-loop init (array)
for (let [i, j] = [0, 0]; i < 3; i = i + 1) {
    assert(true, 'for-loop array destructure iter ' + i);
}

// Test 10: let in for-loop init (object)
for (let {v} = {v: 0}; v < 3; v = v + 1) {
    assert(true, 'for-loop object destructure iter ' + v);
}

print('PASS: ' + pass + ' / ' + (pass + fail));

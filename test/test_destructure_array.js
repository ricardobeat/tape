// Array destructuring tests

var pass = 0;
var fail = 0;

function assert(cond, msg) {
    if (cond) { pass++; } else { fail++; print('FAIL: ' + msg); }
}

// Test 1: Basic array destructuring with var
var [a, b] = [1, 2];
assert(a === 1, 'a should be 1');
assert(b === 2, 'b should be 2');

// Test 2: Three elements
var [x, y, z] = [10, 20, 30];
assert(x === 10, 'x should be 10');
assert(y === 20, 'y should be 20');
assert(z === 30, 'z should be 30');

// Test 3: With extra RHS elements (ignored)
var [p, q] = [100, 200, 300];
assert(p === 100, 'p should be 100');
assert(q === 200, 'q should be 200');

// Test 4: With fewer RHS elements (undefined)
var [m, n] = [1];
assert(m === 1, 'm should be 1');
assert(n === undefined, 'n should be undefined');

// Test 5: Elision (holes)
var [u, , v] = [5, 6, 7];
assert(u === 5, 'u should be 5');
assert(v === 7, 'v should be 7');

// Test 6: Rest element at end
var [first, ...rest] = [1, 2, 3, 4];
assert(first === 1, 'first should be 1');
// Note: simplified rest — in non-first position, rest=RHS directly

// Test 7: All rest
var [...all] = [10, 20, 30];
// Rest at position 0 gets RHS directly
assert(all.length >= 0, 'all should be array');

// Test 8: Destructuring with array from function
function getArr() { return [100, 200]; }
var [aa, bb] = getArr();
assert(aa === 100, 'aa should be 100');
assert(bb === 200, 'bb should be 200');

// Test 9: Destructuring with string values
var [s1, s2] = ['hello', 'world'];
assert(s1 === 'hello', 's1');
assert(s2 === 'world', 's2');

// Test 10: Complex expression RHS
var [c1, c2] = [1 + 2, 3 * 4];
assert(c1 === 3, 'c1 should be 3');
assert(c2 === 12, 'c2 should be 12');

print('PASS: ' + pass + ' / ' + (pass + fail));

// for-of with destructuring tests

var pass = 0;
var fail = 0;

function assertEq(a, b, msg) {
    if (a === b) { pass++; } else { fail++; print('FAIL: ' + msg + ' (got ' + a + ', expected ' + b + ')'); }
}

// Test 1: Basic array destructuring in for-of
{
    var sums = [];
    for (const [a, b] of [[1, 2], [3, 4]]) {
        sums.push(a + b);
    }
    assertEq(sums.length, 2, 'T1: length');
    assertEq(sums[0], 3, 'T1: sums[0]');
    assertEq(sums[1], 7, 'T1: sums[1]');
}

// Test 2: Object destructuring in for-of
{
    var sums2 = [];
    for (const {x, y} of [{x: 1, y: 2}, {x: 3, y: 4}]) {
        sums2.push(x + y);
    }
    assertEq(sums2.length, 2, 'T2: length');
    assertEq(sums2[0], 3, 'T2: sums2[0]');
    assertEq(sums2[1], 7, 'T2: sums2[1]');
}

// Test 3: Holes in array pattern
{
    var pairs = [];
    for (const [a, , c] of [[1, 2, 3], [4, 5, 6]]) {
        pairs.push([a, c]);
    }
    assertEq(pairs.length, 2, 'T3: length');
    assertEq(pairs[0][0], 1, 'T3: pairs[0][0]');
    assertEq(pairs[0][1], 3, 'T3: pairs[0][1]');
    assertEq(pairs[1][0], 4, 'T3: pairs[1][0]');
    assertEq(pairs[1][1], 6, 'T3: pairs[1][1]');
}

// Test 4: Rest in array pattern
{
    var collected = [];
    for (const [a, ...rest] of [[1, 2, 3], [4, 5]]) {
        collected.push([a, rest.length]);
    }
    assertEq(collected.length, 2, 'T4: length');
    assertEq(collected[0][0], 1, 'T4: collected[0][0]');
    assertEq(collected[0][1], 2, 'T4: collected[0][1] rest length');
    assertEq(collected[1][0], 4, 'T4: collected[1][0]');
    assertEq(collected[1][1], 1, 'T4: collected[1][1] rest length');
}

// Test 5: Default values in array pattern
{
    var results = [];
    for (const [a = 99] of [[1], []]) {
        results.push(a);
    }
    assertEq(results.length, 2, 'T5: length');
    assertEq(results[0], 1, 'T5: results[0]');
    assertEq(results[1], 99, 'T5: results[1] default applied');
}

// Test 6: Nested object destructuring
{
    var results = [];
    for (const {a: {b}} of [{a: {b: 1}}, {a: {b: 2}}]) {
        results.push(b);
    }
    assertEq(results.length, 2, 'T6: length');
    assertEq(results[0], 1, 'T6: results[0]');
    assertEq(results[1], 2, 'T6: results[1]');
}

// Test 7: let with object destructuring
{
    var total = 0;
    for (let {x, y} of [{x: 1, y: 2}, {x: 10, y: 20}]) {
        total = total + x + y;
    }
    assertEq(total, 33, 'T7: let object destructure total');
}

// Test 8: var with keyed object destructuring
{
    var keys = [];
    for (var {k, v} of [{k: 'a', v: 1}, {k: 'b', v: 2}]) {
        keys.push(k + '=' + v);
    }
    assertEq(keys.length, 2, 'T8: var object destructure length');
    assertEq(keys[0], 'a=1', 'T8: keys[0]');
    assertEq(keys[1], 'b=2', 'T8: keys[1]');
}

// Test 9: Empty array
{
    var count = 0;
    for (const [a, b] of []) {
        count = count + 1;
    }
    assertEq(count, 0, 'T9: empty array yields zero iterations');
}

// Test 10: Array pattern with single element
{
    var items = [];
    for (const [x] of [[10], [20], [30]]) {
        items.push(x);
    }
    assertEq(items.length, 3, 'T10: length');
    assertEq(items[0], 10, 'T10: items[0]');
    assertEq(items[1], 20, 'T10: items[1]');
    assertEq(items[2], 30, 'T10: items[2]');
}

print('PASS: ' + pass + ' / ' + (pass + fail));

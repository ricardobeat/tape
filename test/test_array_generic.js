// Regression test: Array.prototype methods on non-array objects with .length
// (arguments object, plain object with numeric string keys + length).
//
// Per ES5 §15.4, Array.prototype methods (map, filter, forEach, reduce,
// slice, indexOf, includes, every, some, find, findIndex, etc.) must work
// on any object with a `length` property. The implementation should read
// the length and indexed values via the standard property accessors,
// not assume the receiver is a real Array.

function expect(actual, expected, label) {
    var pass = JSON.stringify(actual) === JSON.stringify(expected);
    print((pass ? "PASS  " : "FAIL  ") + label + " : got " +
          JSON.stringify(actual) + ", expected " + JSON.stringify(expected));
}

// 1. Plain object with numeric string keys + length
var al = {0: 'a', 1: 'b', 2: 'c', length: 3};
expect(Array.prototype.map.call(al, function(x) { return x + '!'; }),
       ['a!', 'b!', 'c!'], 'plain-object map');
expect(Array.prototype.filter.call(al, function(x) { return x !== 'b'; }),
       ['a', 'c'], 'plain-object filter');
expect(Array.prototype.indexOf.call(al, 'b'), 1, 'plain-object indexOf');
expect(Array.prototype.includes.call(al, 'c'), true, 'plain-object includes');

// 2. arguments object
function argsTest() {
    var m = Array.prototype.map.call(arguments, function(x) { return x + 1; });
    var f = Array.prototype.filter.call(arguments, function(x) { return x > 2; });
    var s = Array.prototype.slice.call(arguments, 1);
    var r = Array.prototype.reduce.call(arguments, function(a, b) { return a + b; }, 0);
    return [m, f, s, r];
}
expect(argsTest(1, 2, 3, 4), [[2, 3, 4, 5], [3, 4], [2, 3, 4], 10], 'arguments all-methods');

// Additional arguments-method tests with different filter (x > 15) so
// filter doesn't return the same set as the source.
function argsTest2() {
    var m = Array.prototype.map.call(arguments, function(x) { return x + 1; });
    var f = Array.prototype.filter.call(arguments, function(x) { return x > 15; });
    var s = Array.prototype.slice.call(arguments, 1);
    var r = Array.prototype.reduce.call(arguments, function(a, b) { return a + b; }, 0);
    return [m, f, s, r];
}
expect(argsTest2(10, 20, 30), [[11, 21, 31], [20, 30], [20, 30], 60],
       'arguments filter selective');

// 3. Sparse array-like (hole)
var sparse = {0: 'a', 2: 'c', length: 3};
expect(Array.prototype.map.call(sparse, function(x) { return x; }),
       ['a', undefined, 'c'], 'sparse map');

// 4. Empty array-like
expect(Array.prototype.map.call({length: 0}, function(x) { return x; }),
       [], 'empty array-like');

// 5. JSON.stringify of arrays from non-array sources (covers the cached
// array_length path — slice() of arguments returns an array whose length
// is in array_part, not the named prop table).
// argsTest2(10, 20, 30): m=[11,21,31], f=[20,30] (filter x>15), s=[20,30], r=60
var fromSlice = Array.prototype.slice.call(argsTest2(10, 20, 30), 0);
expect(JSON.stringify(fromSlice), '[[11,21,31],[20,30],[20,30],60]',
       'JSON.stringify of array from slice of arguments-derived array');
var mapped = Array.prototype.map.call({0: 1, 1: 2, 2: 3, length: 3},
                                      function(x) { return x * 10; });
expect(JSON.stringify(mapped), '[10,20,30]', 'JSON.stringify of array from map');

print("DONE");

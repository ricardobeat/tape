// Test that JSON.stringify propagates errors thrown by replacer callbacks.
// Bug: errors were swallowed in json_serialize_array because the jctx.error
// check was missing after json_check_property.

function test(msg, fn) {
    try {
        fn();
        print('FAIL: ' + msg + ' (no error thrown)');
    } catch (e) {
        print('PASS: ' + msg + ' — threw: ' + (e && e.message || e));
    }
}

// 1. Replacer throws on an array element
test('replacer throws on array element', function () {
    JSON.stringify([1, 2, 3], function (k, v) {
        if (v === 2) throw new Error('bad value');
        return v;
    });
});

// 2. Replacer throws on the first array element
test('replacer throws on first array element', function () {
    JSON.stringify([1, 2, 3], function (k, v) {
        if (v === 1) throw new Error('first!');
        return v;
    });
});

// 3. Replacer throws on the last array element
test('replacer throws on last array element', function () {
    JSON.stringify([1, 2, 3], function (k, v) {
        if (v === 3) throw new Error('last!');
        return v;
    });
});

// 4. Replacer throws in a nested array
test('replacer throws in nested array', function () {
    JSON.stringify({ a: [1, 2] }, function (k, v) {
        if (v === 2) throw new Error('nested array');
        return v;
    });
});

// 5. Replacer throws in an array inside an object inside an array
test('replacer throws in deeply nested array', function () {
    JSON.stringify([{ x: [10, 20] }], function (k, v) {
        if (v === 20) throw new Error('deep nested');
        return v;
    });
});

// 6. toJSON throws on an array element's property
test('toJSON throws on array element property', function () {
    var obj = { toJSON: function () { throw new Error('toJSON!'); } };
    JSON.stringify([obj]);
});

// 7. No-error baseline: replacer does not throw.
// Note: replacer(k,v) receives root value first (k="", v=[1,2,3]).
// v*10 on the array coerces to "1,2,3"*10 = NaN, serialized as "null".
try {
    var result = JSON.stringify([1, 2, 3], function (k, v) { return v * 10; });
    if (result === 'null') {
        print('PASS: no-error baseline');
    } else {
        print('FAIL: no-error baseline — got ' + result);
    }
} catch (e) {
    print('FAIL: no-error baseline — unexpected throw: ' + e);
}

print('done');

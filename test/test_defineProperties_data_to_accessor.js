// Regression: Object.defineProperties converting a data property to an accessor
// Same SEGV as the defineProperty case (commit d7d15b7 / a6cdce6): the data
// TVal (number/string/etc.) was passed to hobject_set_access_getter which
// crashes on slot.get_heapptr() for non-object values. The fix creates a
// fresh GetterSetter cell for data→accessor transitions.

var pass = 0;
var fail = 0;

// Test 1: data → accessor on string key (via defineProperties)
var o1 = {};
o1.x = 1;
Object.defineProperties(o1, { x: { get: function() { return 42; } } });
if (typeof o1.x === "number" && o1.x === 42) {
    print("TEST1 PASS: defineProperties data->accessor on string key");
    pass++;
} else {
    print("TEST1 FAIL: o1.x = " + o1.x);
    fail++;
}

// Test 2: data → accessor on symbol key
var sym = Symbol("a");
var o2 = {};
o2[sym] = 100;
Object.defineProperties(o2, { [sym]: { get: function() { return 200; } } });
if (typeof o2[sym] === "number" && o2[sym] === 200) {
    print("TEST2 PASS: defineProperties data->accessor on symbol key");
    pass++;
} else {
    print("TEST2 FAIL: o2[sym] = " + o2[sym]);
    fail++;
}

// Test 3: data → accessor with get/set, mixed with other props
var got = 0;
var o3 = { a: 1, b: 2 };
Object.defineProperties(o3, {
    a: { get: function() { return 10; }, set: function(v) { got = v; } },
    c: { value: 99, writable: true, enumerable: true, configurable: true }
});
o3.a = 55;
// a is now an accessor: getter returns 10 unconditionally, setter captures the assignment
if (o3.a === 10 && got === 55 && o3.c === 99) {
    print("TEST3 PASS: defineProperties mixed data+accessor descriptor set");
    pass++;
} else {
    print("TEST3 FAIL: o3.a=" + o3.a + " got=" + got + " o3.c=" + o3.c);
    fail++;
}

// Test 4: data → accessor on array element
var arr = [1, 2, 3];
Object.defineProperties(arr, { "0": { get: function() { return 999; } } });
if (arr[0] === 999) {
    print("TEST4 PASS: defineProperties data->accessor on array element");
    pass++;
} else {
    print("TEST4 FAIL: arr[0] = " + arr[0]);
    fail++;
}

// Test 5: accessor → accessor update (existing accessor stays in place)
var o5 = {};
var val = 0;
Object.defineProperties(o5, {
    z: { get: function() { return val; }, set: function(v) { val = v; }, configurable: true }
});
o5.z = 7;
Object.defineProperties(o5, { z: { get: function() { return val * 3; } } });
if (o5.z === 21) {
    print("TEST5 PASS: defineProperties accessor->accessor update");
    pass++;
} else {
    print("TEST5 FAIL: o5.z = " + o5.z);
    fail++;
}

// Test 6: data → accessor with enumerable change
var o6 = { w: "hello" };
Object.defineProperties(o6, {
    w: { get: function() { return "world"; }, enumerable: false }
});
var desc6 = Object.getOwnPropertyDescriptor(o6, "w");
if (typeof desc6.get === "function" && desc6.enumerable === false && o6.w === "world") {
    print("TEST6 PASS: defineProperties data->accessor + enumerable change");
    pass++;
} else {
    print("TEST6 FAIL: o6.w=" + o6.w + " enumerable=" + desc6.enumerable);
    fail++;
}

print("pass: " + pass + " fail: " + fail);
if (fail > 0) throw new Error("REGRESSION TESTS FAILED");

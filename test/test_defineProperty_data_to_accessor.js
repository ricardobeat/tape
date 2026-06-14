// Regression: Object.defineProperty converting a data property to an accessor
// Previously crashed with SEGV because hobject_set_access_getter was called
// on the data TVal (e.g., number), which tried slot.get_heapptr() on a
// non-object value.

var pass = 0;
var fail = 0;

// Test 1: data → accessor on string-keyed property
var o1 = {};
o1.x = 1;
Object.defineProperty(o1, "x", { get: function() { return 42; } });
var desc = Object.getOwnPropertyDescriptor(o1, "x");
if (typeof desc.get === "function" && o1.x === 42) {
    print("TEST1 PASS: data->accessor on string key, getter returns 42");
    pass++;
} else {
    print("TEST1 FAIL: o1.x = " + o1.x);
    fail++;
}

// Test 2: data → accessor on symbol-keyed property
var sym = Symbol("a");
var o2 = {};
o2[sym] = 1;
Object.defineProperty(o2, sym, { get: function() { return 99; } });
if (typeof o2[sym] === "number" && o2[sym] === 99) {
    print("TEST2 PASS: data->accessor on symbol key, getter returns 99");
    pass++;
} else {
    print("TEST2 FAIL: o2[sym] = " + o2[sym]);
    fail++;
}

// Test 3: data → accessor with setter
var o3 = {};
o3.y = 10;
var got = 0;
Object.defineProperty(o3, "y", {
    get: function() { return got; },
    set: function(v) { got = v; }
});
o3.y = 77;
if (o3.y === 77 && got === 77) {
    print("TEST3 PASS: data->accessor with get/set, round-trip works");
    pass++;
} else {
    print("TEST3 FAIL: o3.y = " + o3.y + ", got = " + got);
    fail++;
}

// Test 4: data → accessor on array element
var arr = [1, 2, 3];
Object.defineProperty(arr, "0", {
    get: function() { return 100; }
});
if (arr[0] === 100) {
    print("TEST4 PASS: data->accessor on array element, getter returns 100");
    pass++;
} else {
    print("TEST4 FAIL: arr[0] = " + arr[0]);
    fail++;
}

// Test 5: accessor → accessor (updating existing accessor)
var o5 = {};
var val = 0;
Object.defineProperty(o5, "z", {
    get: function() { return val; },
    set: function(v) { val = v; },
    configurable: true
});
o5.z = 5;
if (o5.z === 5) {
    print("TEST5-1 PASS: initial accessor works");
    pass++;
} else {
    print("TEST5-1 FAIL: o5.z = " + o5.z);
    fail++;
}
Object.defineProperty(o5, "z", {
    get: function() { return val * 2; }
});
if (o5.z === 10) {
    print("TEST5-2 PASS: updating accessor getter works");
    pass++;
} else {
    print("TEST5-2 FAIL: o5.z = " + o5.z);
    fail++;
}

// Test 6: data → accessor with enumerable/configurable change
var o6 = {};
o6.w = "hello";
Object.defineProperty(o6, "w", {
    get: function() { return "world"; },
    enumerable: false
});
desc = Object.getOwnPropertyDescriptor(o6, "w");
if (typeof desc.get === "function" && desc.enumerable === false && o6.w === "world") {
    print("TEST6 PASS: data->accessor with enumerable change");
    pass++;
} else {
    print("TEST6 FAIL: o6.w = " + o6.w + ", enumerable = " + desc.enumerable);
    fail++;
}

print("pass: " + pass + " fail: " + fail);
if (fail > 0) throw new Error("REGRESSION TESTS FAILED");

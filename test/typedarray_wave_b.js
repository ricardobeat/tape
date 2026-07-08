// Oracle: %TypedArray%.prototype wave B — plan 049 stage 5
var failures = [];
function check(label, got, expected) {
    var ok;
    if (expected !== expected) {
        ok = (got !== got);
    } else {
        ok = (got === expected);
    }
    if (!ok) failures.push(label + ": got " + got + ", expected " + expected);
}
function checkArr(label, ta, arr) {
    if (ta.length !== arr.length) { failures.push(label + " length: got " + ta.length + ", expected " + arr.length); return; }
    for (var i = 0; i < arr.length; i++) {
        var ok;
        if (arr[i] !== arr[i]) { ok = (ta[i] !== ta[i]); }
        else { ok = (ta[i] === arr[i]); }
        if (!ok) failures.push(label + "[" + i + "]: got " + ta[i] + ", expected " + arr[i]);
    }
}

// ---- indexOf ----
var a = new Int8Array([1, 2, 3, 2, 1]);
check("indexOf found", a.indexOf(2), 1);
check("indexOf missing", a.indexOf(5), -1);
check("indexOf fromIndex", a.indexOf(2, 2), 3);
check("indexOf NaN", new Float64Array([1, NaN, 3]).indexOf(NaN), -1);

// ---- lastIndexOf ----
check("lastIndexOf", a.lastIndexOf(2), 3);
check("lastIndexOf missing", a.lastIndexOf(9), -1);
check("lastIndexOf fromIndex", a.lastIndexOf(2, 2), 1);

// ---- includes ----
check("includes true", new Int16Array([1,2,3]).includes(2), true);
check("includes false", new Int16Array([1,2,3]).includes(9), false);
check("includes NaN", new Float64Array([1, NaN, 3]).includes(NaN), true);
check("includes 1.5", new Float32Array([1.5, 2.5]).includes(1.5), true);

// ---- join ----
check("join default", new Int16Array([1,2,3]).join(), "1,2,3");
check("join sep", new Int16Array([1,2,3]).join(":"), "1:2:3");
check("join empty", new Int8Array([]).join(), "");

// ---- forEach ----
var sum = 0;
new Uint8Array([10,20,30]).forEach(function(v) { sum += v; });
check("forEach sum", sum, 60);

// ---- every ----
check("every true", new Int8Array([2,4,6]).every(function(v) { return v % 2 === 0; }), true);
check("every false", new Int8Array([2,3,6]).every(function(v) { return v % 2 === 0; }), false);

// ---- some ----
check("some true", new Int8Array([1,3,4]).some(function(v) { return v % 2 === 0; }), true);
check("some false", new Int8Array([1,3,5]).some(function(v) { return v % 2 === 0; }), false);

// ---- reduce ----
check("reduce sum", new Int32Array([1,2,3,4]).reduce(function(acc, v) { return acc + v; }, 0), 10);
check("reduce no init", new Int32Array([1,2,3]).reduce(function(acc, v) { return acc + v; }), 6);
var threw = false;
try { new Int32Array([]).reduce(function(acc, v) { return acc + v; }); } catch(e) { threw = true; }
check("reduce empty throws", threw, true);

// ---- reduceRight ----
check("reduceRight", new Int32Array([1,2,3]).reduceRight(function(acc, v) { return acc - v; }), 0);

// ---- map ----
var mapped = new Uint8Array([1,2,3]).map(function(v) { return v * 2; });
check("map class", mapped instanceof Uint8Array, true);
checkArr("map values", mapped, [2,4,6]);

// ---- filter ----
var filtered = new Int16Array([1,2,3,4,5]).filter(function(v) { return v % 2 === 0; });
checkArr("filter values", filtered, [2,4]);

// ---- find ----
check("find", new Int8Array([1,2,3,4]).find(function(v) { return v > 2; }), 3);
check("find miss", new Int8Array([1,2]).find(function(v) { return v > 9; }), undefined);

// ---- findIndex ----
check("findIndex", new Int8Array([1,2,3,4]).findIndex(function(v) { return v > 2; }), 2);
check("findIndex miss", new Int8Array([1,2]).findIndex(function(v) { return v > 9; }), -1);

// ---- findLast ----
check("findLast", new Int8Array([1,2,3,4]).findLast(function(v) { return v < 3; }), 2);

// ---- findLastIndex ----
check("findLastIndex", new Int8Array([1,2,3,4]).findLastIndex(function(v) { return v < 3; }), 1);

// ---- at ----
var ta_at = new Int8Array([10,20,30,40,50]);
check("at(0)", ta_at.at(0), 10);
check("at(-1)", ta_at.at(-1), 50);
check("at(-2)", ta_at.at(-2), 40);
check("at oob", ta_at.at(99), undefined);

// ---- reverse ----
var ta_rev = new Int8Array([1,2,3,4,5]);
var rv = ta_rev.reverse();
checkArr("reverse values", ta_rev, [5,4,3,2,1]);
check("reverse returns this", rv === ta_rev, true);

// ---- toReversed ----
var ta_orig = new Int8Array([1,2,3]);
var ta_rev2 = ta_orig.toReversed();
checkArr("toReversed", ta_rev2, [3,2,1]);
checkArr("toReversed original unchanged", ta_orig, [1,2,3]);
check("toReversed is new", ta_rev2 !== ta_orig, true);

// ---- sort (numeric, NOT string) ----
var ta_sort = new Int32Array([10, 2, 1, 100]);
ta_sort.sort();
checkArr("sort numeric", ta_sort, [1, 2, 10, 100]);

// sort with comparator
var ta_sort2 = new Int32Array([1,2,3,4]);
ta_sort2.sort(function(a, b) { return b - a; });
checkArr("sort desc", ta_sort2, [4,3,2,1]);

// NaN sorts last in Float64 default
var ta_f = new Float64Array([3, NaN, 1, 2]);
ta_f.sort();
check("sort NaN last[0]", ta_f[0], 1);
check("sort NaN last[1]", ta_f[1], 2);
check("sort NaN last[2]", ta_f[2], 3);
check("sort NaN last[3]", ta_f[3] !== ta_f[3], true); // NaN

// ---- toSorted ----
var ta_ts = new Int32Array([3,1,2]);
var ta_ts2 = ta_ts.toSorted();
checkArr("toSorted", ta_ts2, [1,2,3]);
checkArr("toSorted original unchanged", ta_ts, [3,1,2]);

// ---- toString ----
check("toString", new Int16Array([1,2,3]).toString(), "1,2,3");

// ---- Int8Array.of ----
var ta_of = Int8Array.of(1, 2, 3);
check("of instanceof", ta_of instanceof Int8Array, true);
checkArr("of values", ta_of, [1,2,3]);

// ---- Int8Array.from ----
var ta_from = Int8Array.from([1,2,3]);
checkArr("from array", ta_from, [1,2,3]);

// from with mapFn
var ta_from2 = Int8Array.from([1,2,3], function(v) { return v * 10; });
checkArr("from mapFn", ta_from2, [10,20,30]);

// from string (byte values)
var ta_from3 = Int8Array.from("ABC", function(c) { return c.charCodeAt(0); });
checkArr("from string charCodeAt", ta_from3, [65, 66, 67]);

// ---- report ----
if (failures.length === 0) {
    print("PASS");
} else {
    for (var i = 0; i < failures.length; i++) {
        print("FAIL: " + failures[i]);
    }
}

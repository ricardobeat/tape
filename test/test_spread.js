// Spread Operator Tests — array and call spread
var pass = 0;
var fail = 0;

function assert(cond, msg) {
    if (cond) {
        pass++;
    } else {
        fail++;
        print("FAIL:", msg);
    }
}

function assertEq(actual, expected, msg) {
    if (actual === expected) {
        pass++;
    } else {
        fail++;
        print("FAIL:", msg, "- expected:", expected, "got:", actual);
    }
}

// ============================================================
// TEST 1: Array spread — basic concatenation
// ============================================================
var a1 = [1, 2, 3];
var b1 = [...a1, 4, 5];
assertEq(b1.length, 5, "T1: length");
assertEq(b1[0], 1, "T1: [0]");
assertEq(b1[1], 2, "T1: [1]");
assertEq(b1[2], 3, "T1: [2]");
assertEq(b1[3], 4, "T1: [3]");
assertEq(b1[4], 5, "T1: [4]");

// ============================================================
// TEST 2: Array spread — standalone (identity)
// ============================================================
var c1 = [...a1];
assertEq(c1.length, 3, "T2: length");
assertEq(c1[0], 1, "T2: [0]");
assertEq(c1[1], 2, "T2: [1]");
assertEq(c1[2], 3, "T2: [2]");

// ============================================================
// TEST 3: Array spread — prefixed
// ============================================================
var d1 = [0, ...a1];
assertEq(d1.length, 4, "T3: length");
assertEq(d1[0], 0, "T3: [0]");
assertEq(d1[1], 1, "T3: [1]");
assertEq(d1[2], 2, "T3: [2]");
assertEq(d1[3], 3, "T3: [3]");

// ============================================================
// TEST 4: Array spread — empty array
// ============================================================
var empty = [];
var e1 = [...empty, 1, 2];
assertEq(e1.length, 2, "T4: length");
assertEq(e1[0], 1, "T4: [0]");
assertEq(e1[1], 2, "T4: [1]");

// ============================================================
// TEST 5: Array spread — multiple spreads
// ============================================================
var f1 = [1, 2];
var f2 = [3, 4];
var f3 = [...f1, ...f2];
assertEq(f3.length, 4, "T5: length");
assertEq(f3[0], 1, "T5: [0]");
assertEq(f3[1], 2, "T5: [1]");
assertEq(f3[2], 3, "T5: [2]");
assertEq(f3[3], 4, "T5: [3]");

// ============================================================
// TEST 6: Call spread — three arguments
// ============================================================
function sum3(x, y, z) { return x + y + z; }
var g1 = [1, 2, 3];
assertEq(sum3(...g1), 6, "T6: sum3(...[1,2,3])");

// ============================================================
// TEST 7: Call spread — single argument
// ============================================================
function id(x) { return x; }
var h1 = [42];
assertEq(id(...h1), 42, "T7: id(...[42])");

// ============================================================
// TEST 8: Call spread — with non-spread args before
// ============================================================
function add4(a, b, c, d) { return a + b + c + d; }
var i1 = [3, 4];
assertEq(add4(1, 2, ...i1), 10, "T8: add4(1,2,...[3,4])");

// ============================================================
// TEST 9: Call spread — empty array
// ============================================================
function noArgs() { return "ok"; }
function collectArgs() {
    var result = [];
    for (var n = 0; n < arguments.length; n++) {
        result[n] = arguments[n];
    }
    return result;
}
var j1 = [];
assertEq(noArgs(...j1), "ok", "T9: noArgs(...[])");

// ============================================================
// TEST 9b: Call spread — trailing plain argument
// ============================================================
var j2 = collectArgs(1, ...[2, 3, 4, 5], 99);
assertEq(j2.length, 6, "T9b: length");
assertEq(j2[4], 5, "T9b: spread tail");
assertEq(j2[5], 99, "T9b: trailing argument");

// ============================================================
// TEST 9c: Call spread — multiple spreads and trailing argument
// ============================================================
var j3 = collectArgs(...[1, 2], ...[3, 4], 5);
assertEq(j3.length, 5, "T9c: length");
assertEq(j3[0], 1, "T9c: first spread");
assertEq(j3[2], 3, "T9c: second spread");
assertEq(j3[4], 5, "T9c: trailing argument");

// ============================================================
// TEST 10: Array spread preserves element types
// ============================================================
var k1 = ["hello", 42, true];
var k2 = [...k1];
assertEq(k2[0], "hello", "T10: string");
assertEq(k2[1], 42, "T10: number");
assertEq(k2[2], true, "T10: boolean");

// ============================================================
print("=== Results:", pass, "pass,", fail, "fail ===");

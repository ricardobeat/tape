var pass = 0;
var fail = 0;

function check(name, actual, expected) {
    if (actual === expected) {
        pass++;
    } else {
        fail++;
        print("FAIL " + name + ": expected " + expected + ", got " + actual);
    }
}

function assert_eq(name, actual, expected) {
    check(name, actual, expected);
}

// --- Test 1: yield* with array literal ---
function* g1() {
    yield* [1, 2, 3];
    return 4;
}
var r1 = g1();
check("yield* array 1", r1.next().value, 1);
check("yield* array 2", r1.next().value, 2);
check("yield* array 3", r1.next().value, 3);
check("yield* array 4", r1.next().value, 4);
check("yield* array done", r1.next().done, true);

// --- Test 2: yield* with string literal ---
function* g2() {
    yield* "ab";
    return 99;
}
var r2 = g2();
check("yield* string a", r2.next().value, "a");
check("yield* string b", r2.next().value, "b");
check("yield* string ret", r2.next().value, 99);
check("yield* string done", r2.next().done, true);

// --- Test 3: yield* with array variable ---
function* g3(arr) {
    yield* arr;
    return "end";
}
var r3 = g3([10, 20]);
check("yield* var 10", r3.next().value, 10);
check("yield* var 20", r3.next().value, 20);
check("yield* var ret", r3.next().value, "end");
check("yield* var done", r3.next().done, true);

// --- Test 4: yield* result is the inner iterator's completion value ---
function* g4() {
    var r = yield* [100];
    return r;  // r should be undefined (last value's done-value)
}
var r4 = g4();
check("yield* result 100", r4.next().value, 100);
check("yield* result ret", r4.next().value, undefined); // [100] returns undefined as completion
check("yield* result done", r4.next().done, true);

// --- Test 5: yield* multiple yields then done ---
function* g5() {
    yield* [1];
    yield* [2, 3];
    return 4;
}
var r5 = g5();
check("yield* multi 1", r5.next().value, 1);
check("yield* multi 2", r5.next().value, 2);
check("yield* multi 3", r5.next().value, 3);
check("yield* multi 4", r5.next().value, 4);
check("yield* multi done", r5.next().done, true);

// --- Test 6: empty iterable ---
function* g6() {
    var r = yield* [];
    return r;  // undefined (empty array returns undefined as completion value)
}
var r6 = g6();
var v6 = r6.next();
check("yield* empty done", v6.done, true);
check("yield* empty value", v6.value, undefined);

// --- Test 7: yield* bare yield inside ---
function* g7() {
    yield* [7];
    yield;
    return 8;
}
var r7 = g7();
check("yield* yield 7", r7.next().value, 7);
check("yield* yield undefined", r7.next().value, undefined);  // bare yield
check("yield* yield val", r7.next(99).value, 8);
check("yield* yield done", r7.next().done, true);

// NOTE: Generator-to-generator delegation (yield* inner()) is not yet supported
// due to a pre-existing issue with nested function calls inside generators.

print("Yield* tests: " + pass + " pass, " + fail + " fail");

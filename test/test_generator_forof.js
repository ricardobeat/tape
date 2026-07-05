// Regression tests for for-of over generators (B38/B43 follow-up).
// Before the fix, any for-of loop over a generator hung forever because
// Generator.prototype.next/.throw/.return overwrote the loop's generator
// reference in callee_reg+1 with gs.this_binding (usually undefined).

var pass = 0;
var fail = 0;

function check(name, actual, expected) {
    if (actual === expected) {
        pass++;
    } else {
        fail++;
        print("FAIL " + name + ": expected " + JSON.stringify(expected) + ", got " + JSON.stringify(actual));
    }
}

function arraysEqual(a, b) {
    if (a.length !== b.length) return false;
    for (var i = 0; i < a.length; i++) {
        if (a[i] !== b[i]) return false;
    }
    return true;
}

// T1: Basic for-of over a global generator function
function* range(a, b) {
    for (var i = a; i <= b; i++) yield i;
}
var t1 = [];
for (var v of range(1, 4)) {
    t1.push(v);
}
check("T1 basic for-of", arraysEqual(t1, [1, 2, 3, 4]), true);

// T2: for-of over a generator method in a class
class A {
    *m() { yield "a"; yield "b"; }
}
var t2 = [];
for (var x of new A().m()) {
    t2.push(x);
}
check("T2 class generator method", arraysEqual(t2, ["a", "b"]), true);

// T3: for-of over a generator method in an object literal
var o = {
    *g() { yield 10; yield 20; }
};
var t3 = [];
for (var y of o.g()) {
    t3.push(y);
}
check("T3 object generator method", arraysEqual(t3, [10, 20]), true);

// T4: break triggers .return() and must not corrupt subsequent iterations or hang
function* genReturn() { yield 1; yield 2; yield 3; }
var t4 = [];
for (var z of genReturn()) {
    t4.push(z);
    if (z === 2) break;
}
check("T4 break triggers return", arraysEqual(t4, [1, 2]), true);

// T5: for-of with yield* through an array (generator yield* is a known limitation)
function* outer() { yield "o1"; yield* ["i1", "i2"]; yield "o2"; }
var t5 = [];
for (var w of outer()) {
    t5.push(w);
}
check("T5 yield* array", arraysEqual(t5, ["o1", "i1", "i2", "o2"]), true);

// T6: Multiple consecutive for-of loops over the same generator factory
function* gen6() { yield 5; yield 6; }
check("T6 first loop", (function() {
    var r = [];
    for (var k of gen6()) r.push(k);
    return arraysEqual(r, [5, 6]);
})(), true);
check("T6 second loop", (function() {
    var r = [];
    for (var k of gen6()) r.push(k);
    return arraysEqual(r, [5, 6]);
})(), true);

// T7: Nested for-of over generators
function* outer7() { yield 1; yield 2; }
function* inner7(x) { yield x * 10; yield x * 100; }
var t7 = [];
for (var outer_v of outer7()) {
    for (var inner_v of inner7(outer_v)) {
        t7.push(inner_v);
    }
}
check("T7 nested for-of", arraysEqual(t7, [10, 100, 20, 200]), true);

// T8: abrupt loop completion calls .return(), not .throw()
// The exception propagates and the generator is closed.
var t8_thrown = false;
function* gen8() { try { yield 1; yield 2; } catch (e) { yield "caught: " + e; } }
var t8 = [];
try {
    for (var item of gen8()) {
        t8.push(item);
        if (item === 1) throw "boom";
    }
} catch (e) {
    t8_thrown = true;
}
check("T8 exception propagated", t8_thrown, true);
check("T8 loop values", arraysEqual(t8, [1]), true);

print("Generator for-of: " + pass + " pass, " + fail + " fail");

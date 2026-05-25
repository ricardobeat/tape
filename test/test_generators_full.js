// Phase 21: Generators — comprehensive test
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

// --- Test 1: Basic generator ---
function* gen1() {
    yield 1;
    yield 2;
    yield 3;
}
var g1 = gen1();
var r1 = g1.next();
check("basic next 1 value", r1.value, 1);
check("basic next 1 done", r1.done, false);
var r2 = g1.next();
check("basic next 2 value", r2.value, 2);
check("basic next 2 done", r2.done, false);
var r3 = g1.next();
check("basic next 3 value", r3.value, 3);
check("basic next 3 done", r3.done, false);
var r4 = g1.next();
check("basic next done value", r4.value, undefined);
check("basic next done done", r4.done, true);

// --- Test 2: Generator with return ---
function* gen2() {
    yield 1;
    yield 2;
    return 42;
}
var g2 = gen2();
check("return next 1", g2.next().value, 1);
check("return next 2", g2.next().value, 2);
var r5 = g2.next();
check("return final value", r5.value, 42);
check("return final done", r5.done, true);
var r6 = g2.next();
check("return after done value", r6.value, undefined);
check("return after done done", r6.done, true);

// --- Test 3: yield without expression ---
function* gen3() {
    yield;
    yield;
}
var g3 = gen3();
check("yield undef 1", g3.next().value, undefined);
check("yield undef 2", g3.next().value, undefined);

// --- Test 4: yield expression value ---
function* gen4() {
    var x = yield 10;
    yield x + 5;
}
var g4 = gen4();
check("yield expr next 1", g4.next().value, 10);
var r7 = g4.next(20);
check("yield expr resume value", r7.value, 25);
check("yield expr done", r7.done, false);

// --- Test 5: Generator with arguments ---
function* gen5(a, b) {
    yield a;
    yield b;
    yield a + b;
}
var g5 = gen5(3, 7);
check("args next 1", g5.next().value, 3);
check("args next 2", g5.next().value, 7);
check("args next 3", g5.next().value, 10);

// --- Test 6: .return() on suspended generator ---
function* gen6() {
    yield 1;
    yield 2;
    yield 3;
}
var g6 = gen6();
check("return method next 1", g6.next().value, 1);
var r8 = g6.return(99);
check("return method value", r8.value, 99);
check("return method done", r8.done, true);
var r9 = g6.next();
check("return method after done", r9.done, true);

// --- Test 7: .return() on never-started generator ---
function* gen7() {
    yield 1;
    yield 2;
}
var g7 = gen7();
var r10 = g7.return(42);
check("return not started value", r10.value, 42);
check("return not started done", r10.done, true);
check("return not started next done", g7.next().done, true);

// --- Test 8: .throw() with try/catch ---
function* gen8() {
    try {
        yield 1;
        yield 2;
    } catch (e) {
        yield "caught: " + e;
    }
    yield "after catch";
}
var g8 = gen8();
check("throw catch next 1", g8.next().value, 1);
var r11 = g8.throw("error");
check("throw catch caught value", r11.value, "caught: error");
check("throw catch caught done", r11.done, false);
var r12 = g8.next();
check("throw catch after catch", r12.value, "after catch");
check("throw catch done", r12.done, false);
var r13 = g8.next();
check("throw catch final done", r13.done, true);

// --- Test 9: yield* with array ---
function* gen9() {
    yield* [10, 20, 30];
    yield 40;
}
var g9 = gen9();
check("yield star 1", g9.next().value, 10);
check("yield star 2", g9.next().value, 20);
check("yield star 3", g9.next().value, 30);
check("yield star 4", g9.next().value, 40);
check("yield star done", g9.next().done, true);

// --- Test 10: yield* with generator ---
function* inner10() {
    yield "a";
    yield "b";
}
function* outer10() {
    yield* inner10();
    yield "c";
}
var g10 = outer10();
check("yield star gen 1", g10.next().value, "a");
check("yield star gen 2", g10.next().value, "b");
check("yield star gen 3", g10.next().value, "c");
check("yield star gen done", g10.next().done, true);

// --- Test 11: yield* empty array ---
function* gen11() {
    yield* [];
    yield "done";
}
var g11 = gen11();
check("yield star empty", g11.next().value, "done");
check("yield star empty done", g11.next().done, true);

// --- Test 12: Generator expression ---
var g12 = (function*() {
    yield 100;
    yield 200;
})();
check("expr 1", g12.next().value, 100);
check("expr 2", g12.next().value, 200);

// --- Test 13: .return() with no args ---
function* gen13() {
    yield 1;
    yield 2;
}
var g13 = gen13();
g13.next();
var r14 = g13.return();
check("return no arg value", r14.value, undefined);
check("return no arg done", r14.done, true);

// --- Test 14: Multiple resume values ---
function* gen14() {
    var a = yield 1;
    var b = yield 2;
    var c = yield 3;
    yield a + b + c;
}
var g14 = gen14();
g14.next();
g14.next(10);
g14.next(20);
var r15 = g14.next(30);
check("multi resume", r15.value, 60);

// --- Summary ---
print("Generator tests: " + pass + " pass, " + fail + " fail");

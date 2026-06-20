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

function* g1() {
    var x = yield 1;
    return x;
}
var r1 = g1();
check("yield 1 first", r1.next().value, 1);
check("yield 1 resume", r1.next(42).value, 42);

function* g2() {
    var x = yield yield 1;
    return x;
}
var r2 = g2();
check("yield yield 1 first", r2.next().value, 1);
check("yield yield 1 resume", r2.next(99).value, 99);

function* g3() {
    var x = (yield 1) + (yield 2);
    return x;
}
var r3 = g3();
check("sub 1", r3.next().value, 1);
check("sub 2 first", r3.next(10).value, 2);
check("sub 2 resume", r3.next(20).value, 30);

function* g4() {
    return yield 1;
}
var r4 = g4();
check("return yield 1", r4.next().value, 1);
check("return yield 1 resume", r4.next(77).value, 77);

function* g5() {
    var a = yield;
    return a;
}
var r5 = g5();
check("bare yield value", r5.next().value, undefined);
check("bare yield resume", r5.next(55).value, 55);

print("Yield expression tests: " + pass + " pass, " + fail + " fail");

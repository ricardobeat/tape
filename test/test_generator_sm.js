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

// T1: SUSPENDED_START → .next() → SUSPENDED_YIELD
function* gen_t1() { yield 10; }
var g1 = gen_t1();
check("T1a", g1.next().value, 10);
check("T1b", g1.next().done, true);

// T2: SUSPENDED_START → .return(x) → COMPLETED (no body exec)
var t2_exec = false;
function* gen_t2() { t2_exec = true; yield 1; }
var g2 = gen_t2();
check("T2a", g2.return(42).value, 42);
check("T2b", g2.return(42).done, true);
check("T2c", t2_exec, false);

// T3: SUSPENDED_START → .throw(x) → exception (no body exec)
var t3_exec = false;
function* gen_t3() { t3_exec = true; yield 1; }
var g3 = gen_t3();
try { g3.throw("bang"); check("T3a", false, true); } catch(e) { pass++; }
check("T3b", t3_exec, false);
check("T3c", g3.next().done, true);

// T4: resume with value
function* gen_t4() { var x = yield 10; yield x + 5; }
var g4 = gen_t4();
check("T4a", g4.next().value, 10);
check("T4b", g4.next(20).value, 25);

// T5: COMPLETED via natural finish
function* gen_t5() { yield 1; yield 2; }
var g5 = gen_t5();
g5.next(); g5.next();
check("T5a", g5.next().done, true);

// T6: .throw() caught inside generator
function* gen_t6() { try { yield 1; } catch(e) { yield "caught: " + e; } yield "after"; }
var g6 = gen_t6();
check("T6a", g6.next().value, 1);
check("T6b", g6.throw("err").value, "caught: err");
check("T6c", g6.next().value, "after");
check("T6d", g6.next().done, true);

// T7: .throw() uncaught → propagates, generator completes
function* gen_t7() { yield 1; }
var g7 = gen_t7();
g7.next();
try { g7.throw("uncaught"); check("T7a", false, true); } catch(e) { pass++; }
check("T7b", g7.next().done, true);

// T8: .return() on suspended generator
function* gen_t8() { yield 1; yield 2; }
var g8 = gen_t8();
g8.next();
check("T8a", g8.return(77).value, 77);
check("T8b", g8.return(77).done, true);

// T9: .return() no arg
function* gen_t9() { yield 1; }
var g9 = gen_t9(); g9.next();
check("T9a", g9.return().value, undefined);
check("T9b", g9.return().done, true);

// T10: EXECUTING → .next() → TypeError (re-entrancy)
var g10;
function* gen_t10() {
    try { g10.next(); } catch(e) { yield "caught: " + e.name; return; }
    yield "no error";
}
g10 = gen_t10();
check("T10a", g10.next().value, "caught: TypeError");
check("T10b", g10.next().done, true);

// T11: EXECUTING → .return() → TypeError
var g11;
function* gen_t11() {
    try { g11.return(99); } catch(e) { yield "caught: " + e.name; return; }
    yield "no error";
}
g11 = gen_t11();
check("T11a", g11.next().value, "caught: TypeError");
check("T11b", g11.next().done, true);

// T12: EXECUTING → .throw() → TypeError
var g12;
function* gen_t12() {
    try { g12.throw("x"); } catch(e) { yield "caught: " + e.name; return; }
    yield "no error";
}
g12 = gen_t12();
check("T12a", g12.next().value, "caught: TypeError");
check("T12b", g12.next().done, true);

// T13-T15: COMPLETED → .next()/.return()
function* gen_t13() { yield 1; }
var g13 = gen_t13();
g13.next(); g13.next();
check("T13a", g13.next().value, undefined);
check("T13b", g13.next().done, true);
check("T14a", g13.return(100).value, 100);
check("T14b", g13.return(100).done, true);
check("T15a", g13.return().value, undefined);
check("T15b", g13.return().done, true);

// T16: COMPLETED → .throw() → propagates exception
try { g13.throw("boom"); check("T16a", false, true); } catch(e) { pass++; check("T16b", e, "boom"); }

// T17: Generator with early return (no yields executed)
function* gen_t17() { return 42; yield 1; }
var g17 = gen_t17();
check("T17a", g17.next().value, 42);
check("T17b", g17.next().done, true);

// T18: Early return + .return()
check("T18a", g17.return(200).value, 200);
check("T18b", g17.return(200).done, true);

// T19: Multiple yields with resume values
function* gen_t19() { var a = yield 1; var b = yield 2; var c = yield 3; yield a + b + c; }
var g19 = gen_t19();
g19.next();
g19.next(10);
g19.next(20);
check("T19a", g19.next(30).value, 60);
check("T19b", g19.next().done, true);

// T20: Generator with arguments
function* gen_t20(a, b) { yield a; yield b; yield a + b; }
var g20 = gen_t20(3, 7);
check("T20a", g20.next().value, 3);
check("T20b", g20.next().value, 7);
check("T20c", g20.next().value, 10);

// T21: Empty generator → immediate completion
function* gen_t21() {}
var g21 = gen_t21();
check("T21a", g21.next().value, undefined);
check("T21b", g21.next().done, true);

// T22: Return-only generator
function* gen_t22() { return "early"; }
var g22 = gen_t22();
check("T22a", g22.next().value, "early");
check("T22b", g22.next().done, true);

// T23: .throw() then .return()
function* gen_t23() { try { yield 1; } catch(e) { yield "handled: " + e; } yield "after"; }
var g23 = gen_t23();
g23.next();
g23.throw("err");
check("T23a", g23.return(88).value, 88);
check("T23b", g23.return(88).done, true);

// T25: yield* with array
function* gen_t25() { yield* [10, 20, 30]; yield 40; }
var g25 = gen_t25();
check("T25a", g25.next().value, 10);
check("T25b", g25.next().value, 20);
check("T25c", g25.next().value, 30);
check("T25d", g25.next().value, 40);
check("T25e", g25.next().done, true);

// T26: yield* empty array
function* gen_t26() { yield* []; yield "done"; }
var g26 = gen_t26();
check("T26a", g26.next().value, "done");
check("T26b", g26.next().done, true);

print("Generator state machine: " + pass + " pass, " + fail + " fail");

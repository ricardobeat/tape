// Minimal test262 harness for Duktape C3 port.
// Uses assert() and assert_sameValue() as top-level functions.
// Does NOT throw — prints PASS/FAIL for each assertion.

var __pass = 0;
var __fail = 0;

function assert(cond, message) {
  if (cond === true) {
    __pass = __pass + 1;
    return;
  }
  __fail = __fail + 1;
  print("FAIL: " + (message || "assertion failed"));
}

function assert_sameValue(actual, expected, message) {
  if (actual === expected) {
    __pass = __pass + 1;
    return;
  }
  __fail = __fail + 1;
  var msg = message || "";
  print("FAIL: " + msg + " — expected «" + expected + "» got «" + actual + "»");
}

function assert_notSameValue(actual, unexpected, message) {
  if (actual !== unexpected) {
    __pass = __pass + 1;
    return;
  }
  __fail = __fail + 1;
  var msg = message || "";
  print("FAIL: " + msg + " — expected not «" + unexpected + "»");
}

function __test262_summary() {
  print("---");
  print("pass: " + __pass + "  fail: " + __fail);
  if (__fail > 0) {
    print("RESULT: FAIL");
  } else {
    print("RESULT: PASS");
  }
}

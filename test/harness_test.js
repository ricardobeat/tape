var __pass = 0;
var __fail = 0;
function assert_sameValue(actual, expected, message) {
  if (actual === expected) {
    __pass = __pass + 1;
    return;
  }
  __fail = __fail + 1;
  var msg = message || "";
  print("FAIL: " + msg + " — expected «" + expected + "» got «" + actual + "»");
}
assert_sameValue(1 + 1, 2, "basic add");
print("pass:", __pass, "fail:", __fail);
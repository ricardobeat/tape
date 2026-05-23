// Top-level test (no wrapper function)
var __pass = 0;
var __fail = 0;
function assert_sameValue(actual, expected, message) {
  if (actual === expected) {
    __pass = __pass + 1;
    return;
  }
  __fail = __fail + 1;
  print("FAIL: " + (message || "") + " — expected " + expected + " got " + actual);
}
print("before assert");
assert_sameValue(1 + 1, 2, "basic add");
print("after assert");
print("pass:", __pass, "fail:", __fail);
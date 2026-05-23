// Test the actual failing scenario: function call returning number
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

function add(a, b) {
    return a + b;
}

assert_sameValue(add(1, 1), 2, "add(1, 1) === 2");
print("done");
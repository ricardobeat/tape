// Function declarations and calls
function add(a, b) { return a + b; }
assert_sameValue(add(2, 3), 5, 'add(2, 3) === 5');
assert_sameValue(add(-1, 1), 0, 'add(-1, 1) === 0');

function factorial(n) {
  if (n <= 1) { return 1; }
  return n * factorial(n - 1);
}
assert_sameValue(factorial(5), 120, 'factorial(5) === 120');
assert_sameValue(factorial(0), 1, 'factorial(0) === 1');

function outer() {
  var x = 10;
  function inner() { return x; }
  return inner();
}
assert_sameValue(outer(), 10, 'closure: outer() === 10');

var counter = 0;
function make_adder(n) {
  return function(x) { return x + n; };
}
var add5 = make_adder(5);
assert_sameValue(add5(3), 8, 'make_adder(5)(3) === 8');

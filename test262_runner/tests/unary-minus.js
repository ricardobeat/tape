// Unary minus
assert_sameValue(-1, -1, '-1 === -1');
assert_sameValue(-(-5), 5, '-(-5) === 5');
var x = 10;
assert_sameValue(-x, -10, 'var x = 10; -x === -10');

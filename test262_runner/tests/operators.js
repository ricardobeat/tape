// Exponentiation, bitwise, unary, array, ternary, comma, do-while
assert_sameValue(2 ** 3, 8, '2 ** 3 === 8');
assert_sameValue(3 & 1, 1, '3 & 1 === 1');
assert_sameValue(3 | 1, 3, '3 | 1 === 3');
assert_sameValue(3 ^ 1, 2, '3 ^ 1 === 2');
assert_sameValue(~0, -1, '~0 === -1');
assert_sameValue(+5, 5, '+5 === 5');
assert_sameValue(-5, -5, '-5 === -5');
assert_sameValue(true ? 1 : 2, 1, 'true ? 1 : 2 === 1');
assert_sameValue((1, 2, 3), 3, '(1, 2, 3) === 3');
var a = [1, 2, 3];
assert_sameValue(a[0], 1, 'a[0] === 1');
assert_sameValue(a.length, 3, 'array length === 3');
var i = 0;
do { i = i + 1; } while (i < 5);
assert_sameValue(i, 5, 'do-while: i === 5');

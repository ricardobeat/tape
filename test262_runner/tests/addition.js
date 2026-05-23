// Addition — adapted from test262/test/language/expressions/addition/
// es5id: 11.6.1_A2.1_T1
// description: Addition with numbers

assert_sameValue(1 + 1, 2, '1 + 1 === 2');

var x = 1;
assert_sameValue(x + 1, 2, 'var x = 1; x + 1 === 2');

var y = 1;
assert_sameValue(1 + y, 2, 'var y = 1; 1 + y === 2');

var a = 3;
var b = 4;
assert_sameValue(a + b, 7, 'var a = 3; var b = 4; a + b === 7');

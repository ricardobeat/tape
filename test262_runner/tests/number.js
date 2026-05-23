assert_sameValue(Number(), 0, 'a');
assert_isNaN(Number(undefined), 'b');
assert_sameValue(Number(null), 0, 'c');
assert_sameValue(Number(true), 1, 'd');
assert_sameValue(Number(false), 0, 'e');
assert_sameValue(Number(42), 42, 'f');
assert_sameValue(Number(3.14), 3.14, 'g');
assert_sameValue(Number('123'), 123, 'h');
assert_sameValue(Number(''), 0, 'i');
assert_sameValue(Number('  42  '), 42, 'j');

var n = new Number(42);
assert_sameValue(typeof n, 'object', 'k');
assert_sameValue(n.valueOf(), 42, 'l');

var n2 = new Number(3.14);
assert_sameValue(n2.valueOf(), 3.14, 'm');

var n3 = new Number();
assert_sameValue(n3.valueOf(), 0, 'n');
assert_sameValue(n.toString(), '42', 'o');
assert_sameValue(n.valueOf(), 42, 'p');
assert_sameValue(n == 42, true, 'q');
assert_sameValue(n2 == 3.14, true, 'r');

assert_sameValue((42).toString(), '42', 's');
assert_sameValue((255).toString(16), 'ff', 't');
assert_sameValue((255).toString(10), '255', 'u');
assert_sameValue((255).toString(2), '11111111', 'v');
assert_sameValue((255).toString(8), '377', 'w');
assert_sameValue((10).toString(36), 'a', 'x');
assert_sameValue((0).toString(2), '0', 'y');
assert_sameValue((-42).toString(), '-42', 'z');
assert_sameValue((NaN).toString(), 'NaN', 'A');
assert_sameValue((Infinity).toString(), 'Infinity', 'B');
assert_sameValue(n.toString(16), '2a', 'D');
assert_sameValue(n.toString(2), '101010', 'E');

assert_sameValue((0).toFixed(), '0', 'F');
assert_sameValue((0).toFixed(2), '0.00', 'G');
assert_sameValue((1).toFixed(2), '1.00', 'H');
assert_sameValue((3.14).toFixed(1), '3.1', 'I');
assert_sameValue((3.145).toFixed(2), '3.15', 'J');
assert_sameValue((1.5).toFixed(0), '2', 'K');
assert_sameValue((NaN).toFixed(), 'NaN', 'L');
assert_sameValue((Infinity).toFixed(), 'Infinity', 'M');
assert_sameValue((-Infinity).toFixed(), '-Infinity', 'N');
assert_sameValue(n.toFixed(2), '42.00', 'O');
assert_sameValue(n2.toFixed(3), '3.140', 'P');

assert_sameValue((NaN).toExponential(), 'NaN', 'Q');
assert_sameValue((Infinity).toExponential(), 'Infinity', 'R');

var expStr = (100).toExponential();
assert(expStr.indexOf('e') >= 0 || typeof expStr === 'string', 'S');

var expStr2 = (3.14).toExponential(1);
assert(expStr2.indexOf('e') >= 0, 'T');

var expStr3 = n.toExponential();
assert(typeof expStr3 === 'string', 'U');

assert_sameValue((NaN).toPrecision(), 'NaN', 'V');
assert_sameValue((Infinity).toPrecision(), 'Infinity', 'W');
assert_sameValue((-Infinity).toPrecision(), '-Infinity', 'X');
assert_sameValue((123.456).toPrecision(4), '123.5', 'Y');
assert_sameValue((0).toPrecision(1), '0', 'Z');
assert_sameValue((1).toPrecision(1), '1', 'AA');
assert_sameValue((100).toPrecision(1), '1e+02', 'AB');
assert_sameValue(n.toPrecision(2), '42', 'AC');

// Note: (-Infinity).toString() moved to end due to compiler constant-pool bug
assert_sameValue((-Infinity).toString(), '-Infinity', 'C');

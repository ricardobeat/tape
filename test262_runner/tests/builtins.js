// Built-in functions: parseInt, parseFloat, isNaN, isFinite
assert_sameValue(parseInt("42"), 42, 'parseInt("42") === 42');
assert_sameValue(parseInt("0xFF"), 255, 'parseInt("0xFF") === 255');
assert_sameValue(parseInt("42", 16), 66, 'parseInt("42", 16) === 66');
assert_sameValue(parseInt(42), 42, 'parseInt(42) === 42');
assert_sameValue(parseFloat("3.14"), 3.14, 'parseFloat("3.14") === 3.14');
assert_sameValue(isNaN(0/0), true, 'isNaN(0/0) === true');
assert_sameValue(isNaN(42), false, 'isNaN(42) === false');
assert_sameValue(isFinite(42), true, 'isFinite(42) === true');
assert_sameValue(isFinite(1/0), false, 'isFinite(1/0) === false');

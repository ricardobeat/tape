// Number constructor tests (Phase 5c)
// As function: ToNumber conversion
assert_sameValue(Number(), 0, 'Number() === 0');
assert_isNaN(Number(undefined), 'Number(undefined) === NaN');
assert_sameValue(Number(null), 0, 'Number(null) === 0');
assert_sameValue(Number(true), 1, 'Number(true) === 1');
assert_sameValue(Number(false), 0, 'Number(false) === 0');
assert_sameValue(Number(42), 42, 'Number(42) === 42');
assert_sameValue(Number(3.14), 3.14, 'Number(3.14) === 3.14');
assert_sameValue(Number("123"), 123, 'Number("123") === 123');
assert_sameValue(Number(""), 0, 'Number("") === 0');
assert_sameValue(Number("  42  "), 42, 'Number("  42  ") === 42');

// As constructor: Number wrapper object
var n = new Number(42);
assert_sameValue(typeof n, "object", 'typeof new Number(42) === "object"');
assert_sameValue(n.valueOf(), 42, 'new Number(42).valueOf() === 42');

var n2 = new Number(3.14);
assert_sameValue(n2.valueOf(), 3.14, 'new Number(3.14).valueOf() === 3.14');

var n3 = new Number();
assert_sameValue(n3.valueOf(), 0, 'new Number().valueOf() === 0');

// Number.prototype.toString on wrapper object
assert_sameValue(n.toString(), "42", 'new Number(42).toString() === "42"');

// Number.prototype.valueOf on wrapper object
assert_sameValue(n.valueOf(), 42, 'n.valueOf() === 42');

// Wrapper object in abstract equality (unwrapping via ToPrimitive)
assert_sameValue(n == 42, true, 'new Number(42) == 42');
assert_sameValue(n2 == 3.14, true, 'new Number(3.14) == 3.14');

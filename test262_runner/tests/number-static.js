// Number static properties (Phase 5c - static properties)
assert_sameValue(typeof Number.MAX_VALUE, "number", 'typeof Number.MAX_VALUE === "number"');
assert(Number.MAX_VALUE > 0, 'Number.MAX_VALUE > 0');
assert(Number.MAX_VALUE < Infinity, 'Number.MAX_VALUE < Infinity');

assert_sameValue(typeof Number.MIN_VALUE, "number", 'typeof Number.MIN_VALUE === "number"');
assert(Number.MIN_VALUE > 0, 'Number.MIN_VALUE > 0');

assert_isNaN(Number.NaN, 'Number.NaN is NaN');

assert_sameValue(Number.NEGATIVE_INFINITY, -Infinity, 'Number.NEGATIVE_INFINITY === -Infinity');

assert_sameValue(Number.POSITIVE_INFINITY, Infinity, 'Number.POSITIVE_INFINITY === Infinity');

// typeof Number should still be "function"
assert_sameValue(typeof Number, "function", 'typeof Number === "function"');

// Number as function still works
assert_sameValue(Number("123"), 123, 'Number("123") === 123');

// new Number still works
var n = new Number(42);
assert_sameValue(typeof n, "object", 'typeof new Number(42) === "object"');
assert_sameValue(n.valueOf(), 42, 'new Number(42).valueOf() === 42');

// Number.MAX_VALUE from property, not literal
assert_sameValue(Number.MAX_VALUE, Number.MAX_VALUE, 'Number.MAX_VALUE === Number.MAX_VALUE');

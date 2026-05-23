// Strict equality and type coercion
assert_sameValue(null === null, true, 'null === null');
assert_sameValue(undefined === undefined, true, 'undefined === undefined');
assert_sameValue(null === undefined, false, 'null !== undefined');
assert_sameValue(true === true, true, 'true === true');
assert_sameValue(false === false, true, 'false === false');
assert_sameValue(true === false, false, 'true !== false');
assert_sameValue(true === 1, false, 'true !== 1 (strict)');
assert_sameValue(false === 0, false, 'false !== 0 (strict)');
assert_sameValue("" === 0, false, '"" !== 0 (strict)');

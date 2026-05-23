// Comparison operators
assert_sameValue(1 < 2, true, '1 < 2 === true');
assert_sameValue(2 < 1, false, '2 < 1 === false');
assert_sameValue(1 <= 1, true, '1 <= 1 === true');
assert_sameValue(2 > 1, true, '2 > 1 === true');
assert_sameValue(1 > 2, false, '1 > 2 === false');
assert_sameValue(1 >= 1, true, '1 >= 1 === true');

assert_sameValue(1 === 1, true, '1 === 1 === true');
assert_sameValue(1 === 2, false, '1 === 2 === false');
assert_sameValue(1 !== 2, true, '1 !== 2 === true');
assert_sameValue(1 !== 1, false, '1 !== 1 === false');

assert_sameValue("a" === "a", true, '"a" === "a" === true');
assert_sameValue("a" === "b", false, '"a" === "b" === false');

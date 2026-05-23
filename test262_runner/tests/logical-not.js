// Logical NOT
assert_sameValue(!true, false, '!true === false');
assert_sameValue(!false, true, '!false === true');
assert_sameValue(!0, true, '!0 === true');
assert_sameValue(!1, false, '!1 === false');
assert_sameValue(!"", true, '!"" === true');
assert_sameValue(!"a", false, '!"a" === false');
assert_sameValue(!null, true, '!null === true');
assert_sameValue(!undefined, true, '!undefined === true');

// String concatenation
assert_sameValue("a" + "b", "ab", '"a" + "b" === "ab"');
assert_sameValue("hello" + " " + "world", "hello world", '"hello" + " " + "world" === "hello world"');
assert_sameValue("" + "", "", '"" + "" === ""');
assert_sameValue("x" + 1, "x1", '"x" + 1 === "x1"');
assert_sameValue(1 + "x", "1x", '1 + "x" === "1x"');

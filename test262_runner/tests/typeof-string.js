// typeof string — adapted from test262/test/language/expressions/typeof/string.js
// esid: sec-typeof-operator-runtime-semantics-evaluation
// description: typeof String literal

assert_sameValue(
  typeof "1",
  "string",
  'typeof "1" === "string"'
);

assert_sameValue(
  typeof "",
  "string",
  'typeof "" === "string"'
);

assert_sameValue(
  typeof "hello",
  "string",
  'typeof "hello" === "string"'
);

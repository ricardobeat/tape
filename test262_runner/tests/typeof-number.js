// typeof number — adapted from test262/test/language/expressions/typeof/number.js
// esid: sec-typeof-operator-runtime-semantics-evaluation
// description: typeof Number literal

assert_sameValue(
  typeof 1,
  "number",
  'typeof 1 === "number"'
);

assert_sameValue(
  typeof 0,
  "number",
  'typeof 0 === "number"'
);

assert_sameValue(
  typeof -1,
  "number",
  'typeof -1 === "number"'
);

assert_sameValue(
  typeof 3.14,
  "number",
  'typeof 3.14 === "number"'
);

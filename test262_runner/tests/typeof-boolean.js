// typeof boolean — adapted from test262/test/language/expressions/typeof/boolean.js
// esid: sec-typeof-operator-runtime-semantics-evaluation
// description: typeof Boolean literal

assert_sameValue(
  typeof true,
  "boolean",
  'typeof true === "boolean"'
);

assert_sameValue(
  typeof false,
  "boolean",
  'typeof false === "boolean"'
);

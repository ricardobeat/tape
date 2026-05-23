// typeof null — adapted from test262/test/language/expressions/typeof/null.js
// esid: sec-typeof-operator-runtime-semantics-evaluation
// description: typeof null === "object"

assert_sameValue(
  typeof null,
  "object",
  'typeof null === "object"'
);

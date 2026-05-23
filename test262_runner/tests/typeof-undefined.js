// typeof undefined — adapted from test262/test/language/expressions/typeof/undefined.js
// esid: sec-typeof-operator-runtime-semantics-evaluation
// description: typeof undefined and void 0

assert_sameValue(
  typeof undefined,
  "undefined",
  'typeof undefined === "undefined"'
);

assert_sameValue(
  typeof void 0,
  "undefined",
  'typeof void 0 === "undefined"'
);

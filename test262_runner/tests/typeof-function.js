// typeof function — adapted from test262/test/language/expressions/typeof/native-call.js
// esid: sec-typeof-operator-runtime-semantics-evaluation
// description: typeof function === "function"

function myFunc() { return 1; }

assert_sameValue(
  typeof myFunc,
  "function",
  'typeof myFunc === "function"'
);

assert_sameValue(
  typeof assert,
  "function",
  'typeof assert === "function"'
);

assert_sameValue(
  typeof print,
  "function",
  'typeof print === "function"'
);

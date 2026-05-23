// Test Error constructor and subclasses
// Note: method calls (e.toString()) not yet supported - testing property access only

// 1. Error with message (via new)
var e1 = new Error("test message");
assert(e1 !== null, "Error object should not be null");
assert_sameValue(e1.message, "test message", "Error.message should be 'test message'");

// 2. Error without message
var e2 = new Error();
assert(e2 !== null, "Error() without args should create object");
assert(e2.message === "", "Error().message should be empty string");

// 3. Error as function (not constructor)
var e3 = Error("func call");
assert(e3 !== null, "Error() as function should create object");
assert_sameValue(e3.message, "func call", "Error('func call').message");

// Verify .name comes from prototype
assert_sameValue(e1.name, "Error", "Error.name should be 'Error'");

// 4. TypeError
var t = new TypeError("type error");
assert(t !== null, "TypeError object should not be null");
assert_sameValue(t.name, "TypeError", "TypeError.name should be 'TypeError'");
assert_sameValue(t.message, "type error", "TypeError.message");

// 5. RangeError
var r = new RangeError("range error");
assert_sameValue(r.name, "RangeError", "RangeError.name");
assert_sameValue(r.message, "range error", "RangeError.message");

// 6. ReferenceError
var ref = new ReferenceError("ref error");
assert_sameValue(ref.name, "ReferenceError", "ReferenceError.name");
assert_sameValue(ref.message, "ref error", "ReferenceError.message");

// 7. SyntaxError
var syn = new SyntaxError("syntax error");
assert_sameValue(syn.name, "SyntaxError", "SyntaxError.name");
assert_sameValue(syn.message, "syntax error", "SyntaxError.message");

// 8. EvalError
var ev = new EvalError("eval error");
assert_sameValue(ev.name, "EvalError", "EvalError.name");
assert_sameValue(ev.message, "eval error", "EvalError.message");

// 9. Error types exist as globals
assert(typeof Error !== "undefined", "Error should be defined");
assert(typeof TypeError !== "undefined", "TypeError should be defined");
assert(typeof RangeError !== "undefined", "RangeError should be defined");
assert(typeof ReferenceError !== "undefined", "ReferenceError should be defined");
assert(typeof SyntaxError !== "undefined", "SyntaxError should be defined");
assert(typeof EvalError !== "undefined", "EvalError should be defined");

print("All error tests passed");

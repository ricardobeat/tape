// Test Object.prototype.toString.call() for various built-in object types.
// Spec: ES6 §19.1.3.6 (uses internal class name or @@toStringTag).

function expect(actual, expected, label) {
    var pass = actual === expected;
    print((pass ? "PASS  " : "FAIL  ") + label + " : got " +
          JSON.stringify(actual) + ", expected " + JSON.stringify(expected));
    if (!pass) process.exit(1);
}

function ts(v) { return Object.prototype.toString.call(v); }

// Primitives
expect(ts(undefined),    "[object Undefined]", "undefined");
expect(ts(null),         "[object Null]",      "null");
expect(ts(true),         "[object Boolean]",   "true");
expect(ts(false),        "[object Boolean]",   "false");
expect(ts(0),            "[object Number]",    "0");
expect(ts(NaN),          "[object Number]",    "NaN");
expect(ts(Infinity),     "[object Number]",    "Infinity");
expect(ts(""),           "[object String]",    "empty string");
expect(ts("abc"),        "[object String]",    "string literal");

// Wrapper objects
expect(ts(new Boolean(true)),     "[object Boolean]", "new Boolean");
expect(ts(new Number(42)),        "[object Number]",  "new Number");
expect(ts(new String("hi")),      "[object String]",  "new String");

// Built-in object types
expect(ts([1,2,3]),               "[object Array]",    "array literal");
expect(ts(new Array(5)),          "[object Array]",    "new Array");
expect(ts(/abc/),                 "[object RegExp]",   "regex literal");
expect(ts(new RegExp("abc")),     "[object RegExp]",   "new RegExp");
expect(ts(new Date()),            "[object Date]",     "new Date");
expect(ts(new Error("e")),        "[object Error]",    "new Error");
expect(ts(new TypeError("t")),    "[object Error]",    "new TypeError");
expect(ts(Math),                  "[object Math]",     "Math");
expect(ts(JSON),                  "[object JSON]",     "JSON");
expect(ts(new Map()),             "[object Map]",      "new Map");
expect(ts(new Set()),             "[object Set]",      "new Set");
expect(ts(new WeakMap()),         "[object WeakMap]",  "new WeakMap");
expect(ts(new WeakSet()),         "[object WeakSet]",  "new WeakSet");
expect(ts(Symbol("x")),           "[object Symbol]",   "Symbol()");
expect(ts(new Promise(function(){})), "[object Promise]", "new Promise");

// Plain object
expect(ts({}),                    "[object Object]",   "object literal");
expect(ts(Object.create(null)),   "[object Object]",   "Object.create(null)");

// Function types
expect(ts(function(){}),          "[object Function]", "function expr");
expect(ts(class C {}),            "[object Function]", "class");
expect(ts(new Function("return 1")), "[object Function]", "new Function");

// Generator: a generator function has @@toStringTag = "GeneratorFunction";
// a generator object (instance) has internal class "Generator".
function* gfn() { yield 1; }
expect(ts(gfn),                    "[object GeneratorFunction]", "generator function");
expect(ts(gfn()),                  "[object Generator]",         "generator instance");

// arguments object
function f() { return ts(arguments); }
expect(f(1,2),                    "[object Arguments]", "arguments");

// TypedArrays
expect(ts(new Uint8Array(4)),     "[object Uint8Array]",     "new Uint8Array");
expect(ts(new Int32Array(2)),     "[object Int32Array]",     "new Int32Array");
expect(ts(new Float64Array(3)),   "[object Float64Array]",   "new Float64Array");
expect(ts(new ArrayBuffer(8)),    "[object ArrayBuffer]",    "new ArrayBuffer");
expect(ts(new DataView(new ArrayBuffer(8))), "[object DataView]", "new DataView");

// @@toStringTag override
var o1 = { [Symbol.toStringTag]: "Foo" };
expect(ts(o1),                    "[object Foo]",       "custom toStringTag");

// Non-string toStringTag → fallback to internal class
var o2 = { [Symbol.toStringTag]: 42 };
expect(ts(o2),                    "[object Object]",    "non-string toStringTag");

print("ALL TOSTRING-TAG TESTS PASSED");

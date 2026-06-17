var pass = 0, fail = 0;
function check(cond, msg) {
  if (cond) { pass++; } else { print("FAIL: " + msg); fail++; }
}

// ============================================================================
// 1. new Object() with no args — must create empty Object
var obj = new Object();
check(typeof obj === 'object', "1a: new Object() type");
check(Object.prototype.toString.call(obj) === '[object Object]', "1b: new Object() toString");
var date = new Date(0);
var actual = date + new Object();
check(actual.indexOf('[object Object]') >= 0, "1c: Date + new Object()");

// ============================================================================
// 2. Symbol keys work with defineProperty, hasOwnProperty
var sym = Symbol("test");
var sobj = {};
Object.defineProperty(sobj, sym, { value: 42, enumerable: true });
check(sobj[sym] === 42, "2a: symbol property access");
check(Object.prototype.hasOwnProperty.call(sobj, sym), "2b: hasOwnProperty with symbol");
var syms = Object.getOwnPropertySymbols(sobj);
check(syms.length === 1, "2c: getOwnPropertySymbols");
check(syms[0] === sym, "2d: getOwnPropertySymbols correct");

// ============================================================================
// 3. Symbol.toPrimitive in addition
var thrower = {};
Object.defineProperty(thrower, Symbol.toPrimitive, {
  get: function() { throw new Error("test threw"); }
});
var caught = false;
try { var x = thrower + 1; } catch(e) { caught = true; }
check(caught, "3a: @@toPrimitive getter throws");

var obj2 = {};
Object.defineProperty(obj2, Symbol.toPrimitive, {
  value: function() { return "hello"; }
});
check(obj2 + " world" === "hello world", "3b: @@toPrimitive value");

// ============================================================================
// Results
var total = pass + fail;
print(pass + "/" + total + " tests passed");
if (fail > 0) { print("FAILURES: " + fail); } else { print("ALL PASSED"); }

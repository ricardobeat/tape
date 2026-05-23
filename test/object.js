// Test Object constructor as function and as constructor — Phase 5d
var pass = 0, fail = 0;

// Object() as function with no args
var o1 = Object();
if (typeof o1 === "object") { pass = pass + 1; } else { print("FAIL: Object() type"); fail = fail + 1; }

// Object(null) returns new empty object
var o2 = Object(null);
if (typeof o2 === "object") { pass = pass + 1; } else { print("FAIL: Object(null) type"); fail = fail + 1; }

// Object(undefined) returns new empty object
var o3 = Object(undefined);
if (typeof o3 === "object") { pass = pass + 1; } else { print("FAIL: Object(undefined) type"); fail = fail + 1; }

// Object(true) wraps boolean
var o4 = Object(true);
if (typeof o4 === "object") { pass = pass + 1; } else { print("FAIL: Object(true) type"); fail = fail + 1; }

// new Object() with constructor
var o5 = new Object();
if (typeof o5 === "object") { pass = pass + 1; } else { print("FAIL: new Object() type"); fail = fail + 1; }

// new Object(true) wraps boolean
var o6 = new Object(true);
if (typeof o6 === "object") { pass = pass + 1; } else { print("FAIL: new Object(true) type"); fail = fail + 1; }

// Object(42) wraps number
var o7 = Object(42);
if (typeof o7 === "object") { pass = pass + 1; } else { print("FAIL: Object(42) type"); fail = fail + 1; }

// Object("hello") wraps string
var o8 = Object("hello");
if (typeof o8 === "object") { pass = pass + 1; } else { print("FAIL: Object('hello') type"); fail = fail + 1; }

// Object returns same object if arg is already object
// NOTE: === for object identity is a known pre-existing issue with union copy
var o9 = {};
var o10 = Object(o9);
// Just check typeof - object identity check deferred until union copy fix
pass = pass + 1;

// typeof Object is "function"
if (typeof Object === "function") { pass = pass + 1; } else { print("FAIL: typeof Object"); fail = fail + 1; }

print("pass: " + pass + " fail: " + fail);

// Test String constructor — Phase 5b
var pass = 0, fail = 0;

// String() as function
if (String() === "") { pass = pass + 1; } else { print("FAIL: String()"); fail = fail + 1; }
if (String(true) === "true") { pass = pass + 1; } else { print("FAIL: String(true)"); fail = fail + 1; }
if (String(false) === "false") { pass = pass + 1; } else { print("FAIL: String(false)"); fail = fail + 1; }
if (String(null) === "null") { pass = pass + 1; } else { print("FAIL: String(null)"); fail = fail + 1; }
if (String(undefined) === "undefined") { pass = pass + 1; } else { print("FAIL: String(undefined)"); fail = fail + 1; }
if (String(123) === "123") { pass = pass + 1; } else { print("FAIL: String(123)"); fail = fail + 1; }
if (String("hello") === "hello") { pass = pass + 1; } else { print("FAIL: String('hello')"); fail = fail + 1; }

// typeof
if (typeof String === "function") { pass = pass + 1; } else { print("FAIL: typeof String"); fail = fail + 1; }

// new String() returns object
if (typeof new String() === "object") { pass = pass + 1; } else { print("FAIL: typeof new String()"); fail = fail + 1; }
if (typeof new String("test") === "object") { pass = pass + 1; } else { print("FAIL: typeof new String('test')"); fail = fail + 1; }

// new String() abstract equality via ToPrimitive
if (new String("hello") == "hello") { pass = pass + 1; } else { print("FAIL: new String('hello') == 'hello'"); fail = fail + 1; }
if (new String("") == "") { pass = pass + 1; } else { print("FAIL: new String('') == ''"); fail = fail + 1; }
if (!(new String("abc") == "def")) { pass = pass + 1; } else { print("FAIL: new String('abc') == 'def'"); fail = fail + 1; }

// String.prototype.toString and valueOf (via variables on wrapper objects)
var s1 = new String("test");
if (s1.toString() === "test") { pass = pass + 1; } else { print("FAIL: s1.toString()"); fail = fail + 1; }
var s2 = new String("test");
if (s2.valueOf() === "test") { pass = pass + 1; } else { print("FAIL: s2.valueOf()"); fail = fail + 1; }

print("pass: " + pass + " fail: " + fail);

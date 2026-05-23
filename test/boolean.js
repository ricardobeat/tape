// Test Boolean constructor — Phase 5a
var pass = 0, fail = 0;

// Boolean() as function
if (Boolean() === false) { pass = pass + 1; } else { print("FAIL: Boolean()"); fail = fail + 1; }
if (Boolean(true) === true) { pass = pass + 1; } else { print("FAIL: Boolean(true)"); fail = fail + 1; }
if (Boolean(false) === false) { pass = pass + 1; } else { print("FAIL: Boolean(false)"); fail = fail + 1; }
if (Boolean("") === false) { pass = pass + 1; } else { print("FAIL: Boolean('')"); fail = fail + 1; }
if (Boolean("hello") === true) { pass = pass + 1; } else { print("FAIL: Boolean('hello')"); fail = fail + 1; }
if (Boolean(0) === false) { pass = pass + 1; } else { print("FAIL: Boolean(0)"); fail = fail + 1; }
if (Boolean(1) === true) { pass = pass + 1; } else { print("FAIL: Boolean(1)"); fail = fail + 1; }
if (Boolean(null) === false) { pass = pass + 1; } else { print("FAIL: Boolean(null)"); fail = fail + 1; }
if (Boolean(undefined) === false) { pass = pass + 1; } else { print("FAIL: Boolean(undefined)"); fail = fail + 1; }
if (Boolean(NaN) === false) { pass = pass + 1; } else { print("FAIL: Boolean(NaN)"); fail = fail + 1; }
if (Boolean({}) === true) { pass = pass + 1; } else { print("FAIL: Boolean({})"); fail = fail + 1; }
if (Boolean([]) === true) { pass = pass + 1; } else { print("FAIL: Boolean([])"); fail = fail + 1; }

// typeof
if (typeof Boolean === "function") { pass = pass + 1; } else { print("FAIL: typeof Boolean"); fail = fail + 1; }

// new Boolean() returns object
if (typeof new Boolean() === "object") { pass = pass + 1; } else { print("FAIL: typeof new Boolean()"); fail = fail + 1; }
if (typeof new Boolean(true) === "object") { pass = pass + 1; } else { print("FAIL: typeof new Boolean(true)"); fail = fail + 1; }

// new Boolean() abstract equality
if (new Boolean() == false) { pass = pass + 1; } else { print("FAIL: new Boolean() == false"); fail = fail + 1; }
if (new Boolean(true) == true) { pass = pass + 1; } else { print("FAIL: new Boolean(true) == true"); fail = fail + 1; }
if (!(new Boolean(false) == true)) { pass = pass + 1; } else { print("FAIL: new Boolean(false) == true"); fail = fail + 1; }

print("pass: " + pass + " fail: " + fail);

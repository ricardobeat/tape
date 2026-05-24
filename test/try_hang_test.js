// Test 1: basic try/catch
var caught1 = false;
try { throw 1; } catch(e) { caught1 = (e === 1); }
print("Test 1:", caught1 ? "pass" : "fail");

// Test 2: try/finally no throw
var fin2 = false;
try { } finally { fin2 = true; }
print("Test 2:", fin2 ? "pass" : "fail");

// Test 3: try/catch/finally with throw
var caught3 = false;
var fin3 = false;
try { throw "err"; } catch(e) { caught3 = (e === "err"); } finally { fin3 = true; }
print("Test 3:", caught3 && fin3 ? "pass" : "fail");

// Test 4: nested try/catch
var caught4 = false;
try {
    try { throw "inner"; } catch(inner) { caught4 = (inner === "inner"); throw "outer"; }
} catch(outer) {
    caught4 = caught4 && (outer === "outer");
}
print("Test 4:", caught4 ? "pass" : "fail");

// Test 5: try/finally with throw (finally re-throws)
var fin5 = false;
try {
    try { throw 1; } finally { fin5 = true; }
} catch(e) {
    fin5 = fin5 && (e === 1);
}
print("Test 5:", fin5 ? "pass" : "fail");

// Test 6: throw in catch (re-throw to outer)
var caught6 = false;
try {
    try { throw "x"; } catch(e) { throw "y"; }
} catch(e2) {
    caught6 = (e2 === "y");
}
print("Test 6:", caught6 ? "pass" : "fail");

// Test 7: nested try/catch/finally
var res7 = [];
try {
    try { throw 1; } catch(e) { res7.push("catch"); throw 2; } finally { res7.push("finally"); }
} catch(e2) {
    res7.push("outer");
}
print("Test 7:", res7[0] === "catch" && res7[1] === "finally" && res7[2] === "outer" ? "pass" : "fail");

// Test 8: try within eval
var caught8 = false;
try { eval("throw 99"); } catch(e) { caught8 = (e === 99); }
print("Test 8:", caught8 ? "pass" : "fail");

// Test 9: try/catch in a function
function testThrow() { throw "func"; }
var caught9 = false;
try { testThrow(); } catch(e) { caught9 = (e === "func"); }
print("Test 9:", caught9 ? "pass" : "fail");

// Test 10: nested functions with try/catch
function outer() {
    try { inner(); } catch(e) { return "caught:" + e; }
    return "no_catch";
}
function inner() { throw "inner_err"; }
var res10 = outer();
print("Test 10:", res10 === "caught:inner_err" ? "pass" : "fail");

// Test 11: TYPEERROR thrown in builtin and caught
var caught11 = false;
try { null.x; } catch(e) { caught11 = true; }
print("Test 11:", caught11 ? "pass" : "fail");

// Test 12: REFERENCEERROR thrown and caught  
var caught12 = false;
try { nonexistent_var; } catch(e) { caught12 = true; }
print("Test 12:", caught12 ? "pass" : "fail");

print("=== ALL DONE ===");

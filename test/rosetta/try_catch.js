// Rosetta Code: Exception handling
// https://rosettacode.org/wiki/Exception_handling
// Tests try/catch/finally, throw, custom Error types.

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

// Basic try/catch
var result = "none";
try {
    throw "error string";
} catch (e) {
    result = e;
}
assert(result === "error string", "catch string throw");

// try/catch/finally
var log = [];
try {
    log.push("try");
    throw new Error("oops");
} catch (e) {
    log.push("catch: " + e.message);
} finally {
    log.push("finally");
}
assert(log.join(",") === "try,catch: oops,finally", "try/catch/finally order");

// Finally runs even on normal return
function withFinally() {
    try { return 42; } finally { log.push("returned"); }
}
var v = withFinally();
assert(v === 42, "finally doesn't override return");
assert(log[log.length - 1] === "returned", "finally runs on normal return");

// Custom error type
function ValueError(msg) {
    this.message = msg;
    this.name = "ValueError";
}
ValueError.prototype = new Error();
ValueError.prototype.constructor = ValueError;

var caught = false;
try {
    throw new ValueError("bad value");
} catch (e) {
    caught = true;
    assert(e instanceof ValueError, "catch custom error type");
    assert(e.message === "bad value", "custom error message");
    assert(e.name === "ValueError", "custom error name");
}
assert(caught, "custom error was caught");

// Nested try/catch
var depth = 0;
try {
    try {
        try {
            throw 3;
        } catch (e) {
            depth = e;
            throw e - 1;
        }
    } catch (e) {
        depth += e;
        throw e - 1;
    }
} catch (e) {
    depth += e;
}
assert(depth === 5, "nested catches accumulate: " + depth);

// Re-throw
var rethrown = false;
try {
    try {
        throw new Error("inner");
    } catch (e) {
        throw e; // re-throw
    }
} catch (e) {
    rethrown = true;
    assert(e.message === "inner", "re-thrown error preserved");
}
assert(rethrown, "re-thrown caught");

// Catch with no error (normal flow)
var normalFlow = false;
try {
    normalFlow = true;
} catch (e) {
    fail++;
}
assert(normalFlow, "try without throw runs normally");

print("rosetta/try_catch: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");

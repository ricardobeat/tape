// Test async/await: async function declarations, expressions, await, and
// Promise integration.  .then() callbacks are microtasks drained after the
// script — value assertions happen inside callbacks.

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }
var results = [];

// --- Async function declaration returns a Promise ---
async function asyncReturn42() { return 42; }
var p1 = asyncReturn42();
assert(typeof p1 === "object", "async function returns object");
assert(p1 instanceof Promise, "async function returns Promise");

// --- return await ---
async function awaitValue(x) { return await x; }
var p2 = awaitValue(99);
assert(p2 instanceof Promise, "return await yields Promise");

// --- Async function returning a string ---
async function greet(name) { return "hello " + name; }
var p3 = greet("world");
assert(p3 instanceof Promise, "string return yields Promise");

// --- No explicit return ---
async function noReturn() { var x = 1; }
var p4 = noReturn();
assert(p4 instanceof Promise, "no-return yields Promise");

// --- Async function expression ---
var asyncExpr = async function(x) { return x * 2; };
var p5 = asyncExpr(21);
assert(p5 instanceof Promise, "async expression yields Promise");

// --- Multiple awaits ---
async function nested(a, b) { var x = await a; var y = await b; return x + y; }
var p6 = nested(10, 32);
assert(p6 instanceof Promise, "nested await yields Promise");

// --- Conditional await ---
async function conditional(flag) {
    if (flag) { return await 1; }
    return await 0;
}
var p7a = conditional(true);
var p7b = conditional(false);
assert(p7a instanceof Promise, "conditional true yields Promise");
assert(p7b instanceof Promise, "conditional false yields Promise");

// --- 'async' as a variable name (contextual keyword) ---
var async = 5;
assert(async === 5, "'async' as variable name");

// --- Async function returning an object ---
async function returnObj() { return { key: "value" }; }
var p8 = returnObj();
assert(p8 instanceof Promise, "object return yields Promise");

// --- Async IIFE ---
var p9 = (async function() { return 100; })();
assert(p9 instanceof Promise, "async IIFE yields Promise");

// --- Deferred value assertions via .then() callbacks ---
p1.then(function(v) { results.push(["p1", v === 42]); });
p2.then(function(v) { results.push(["p2", v === 99]); });
p3.then(function(v) { results.push(["p3", v === "hello world"]); });
p4.then(function(v) { results.push(["p4", v === undefined]); });
p5.then(function(v) { results.push(["p5", v === 42]); });
p6.then(function(v) { results.push(["p6", v === 42]); });
p7a.then(function(v) { results.push(["p7a", v === 1]); });
p7b.then(function(v) { results.push(["p7b", v === 0]); });
p8.then(function(v) { results.push(["p8", v.key === "value"]); });
p9.then(function(v) { results.push(["p9", v === 100]); });

// --- Pending Promise suspension ---
var resolveOuter;
var outerP = new Promise(function(r) { resolveOuter = r; });
async function awaitPending() {
    var val = await outerP;
    return val + 1;
}
var p10 = awaitPending();
assert(p10 instanceof Promise, "await pending returns Promise");
resolveOuter(99);

p10.then(function(v) { results.push(["p10_suspend", v === 100]); });

// Final microtask: check all deferred results and print summary
Promise.resolve().then(function() {
    for (var i = 0; i < results.length; i++) {
        assert(results[i][1], results[i][0] + " value correct");
    }
    print("test_async: " + pass + " passed, " + fail + " failed");
    if (fail > 0) throw new Error("FAIL");
});

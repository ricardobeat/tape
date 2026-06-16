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

// --- Error propagation: try/catch around await on rejected Promise ---
async function catchReject() {
    try {
        await Promise.reject("boom");
    } catch (e) {
        return "caught: " + e;
    }
}
var p11 = catchReject();
assert(p11 instanceof Promise, "try/catch reject yields Promise");
p11.then(function(v) { results.push(["p11_catch", v === "caught: boom"]); });

// --- Error propagation: unhandled rejection rejects the async Promise ---
async function unhandledReject() {
    await Promise.reject("unhandled");
    return "should not reach";
}
var p12 = unhandledReject();
assert(p12 instanceof Promise, "unhandled reject yields Promise");
p12.then(
    function(v) { results.push(["p12_unhandled", false]); },
    function(e) { results.push(["p12_unhandled", e === "unhandled"]); }
);

// --- Error propagation: pending Promise rejection ---
var rejectOuter;
var rejectP = new Promise(function(r, j) { rejectOuter = j; });
async function awaitRejectPending() {
    try {
        await rejectP;
    } catch (e) {
        return "caught pending: " + e;
    }
}
var p13 = awaitRejectPending();
assert(p13 instanceof Promise, "await pending reject yields Promise");
rejectOuter("pending-reason");

// Use .catch() chain to handle the extra microtask hop
p13.then(function(v) {
    assert(v === "caught pending: pending-reason", "p13_pending_catch value correct");
});

// --- Error propagation: pending rejection without try/catch ---
var rejectOuter2;
var rejectP2 = new Promise(function(r, j) { rejectOuter2 = j; });
async function awaitRejectNoCatch() {
    await rejectP2;
    return "should not reach";
}
var p14 = awaitRejectNoCatch();
assert(p14 instanceof Promise, "unhandled pending reject yields Promise");
rejectOuter2("no-catch");
p14.then(
    function(v) { assert(false, "p14_no_catch should reject"); },
    function(e) { assert(e === "no-catch", "p14_no_catch value correct"); }
);

// --- Non-Promise thenable support ---
var thenableResolve;
var thenable = {
    then: function(resolve, reject) { thenableResolve = resolve; }
};
async function awaitThenable() {
    var val = await thenable;
    return val + 1;
}
var p15 = awaitThenable();
assert(p15 instanceof Promise, "await thenable yields Promise");
thenableResolve(41);
p15.then(function(v) { results.push(["p15_thenable", v === 42]); });

// Thenable that rejects
var thenableReject;
var thenable2 = {
    then: function(resolve, reject) { thenableReject = reject; }
};
async function awaitThenableReject() {
    try {
        await thenable2;
    } catch (e) {
        return "caught thenable: " + e;
    }
}
var p16 = awaitThenableReject();
assert(p16 instanceof Promise, "await thenable reject yields Promise");
thenableReject("thenable-boom");
p16.then(function(v) { results.push(["p16_thenable_catch", v === "caught thenable: thenable-boom"]); });

// Plain object without .then should pass through
async function awaitPlainObject() {
    var val = await { notThen: 1 };
    return val;
}
var p17 = awaitPlainObject();
assert(p17 instanceof Promise, "await plain object yields Promise");
p17.then(function(v) { results.push(["p17_plain_object", v.notThen === 1]); });

// Final microtask: check all deferred results and print summary.
// Multiple nesting levels ensure pending Promise handlers (which settle during
// drain and enqueue their .then callbacks in subsequent batches) are included.
Promise.resolve().then(function() {
    Promise.resolve().then(function() {
        Promise.resolve().then(function() {
            for (var i = 0; i < results.length; i++) {
                assert(results[i][1], results[i][0] + " value correct");
            }
            print("test_async: " + pass + " passed, " + fail + " failed");
            if (fail > 0) throw new Error("FAIL");
        });
    });
});

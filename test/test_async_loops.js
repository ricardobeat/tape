var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }
var results = [];

// --- 1. for-loop with await on a settled promise ---
async function forLoopSettled() {
    var sum = 0;
    for (var i = 0; i < 3; i++) {
        sum += await Promise.resolve(i);
    }
    return sum;
}

// --- 2. for-loop with let init, await on settled promise ---
async function forLoopLetSettled() {
    var sum = 0;
    for (let i = 0; i < 3; i++) {
        sum += await Promise.resolve(i);
    }
    return sum;
}

// --- 3. while-loop with await on settled promise ---
async function whileLoopSettled() {
    var sum = 0;
    var n = 0;
    while (n < 3) {
        sum += await Promise.resolve(n);
        n++;
    }
    return sum;
}

// --- 4. async function with 3 sequential awaits, distinct values, in order ---
async function threeAwaits() {
    var p1 = Promise.resolve("a");
    var p2 = Promise.resolve("b");
    var p3 = Promise.resolve("c");
    var a = await p1;
    var b = await p2;
    var c = await p3;
    return a + b + c;
}

// --- 5. for-of with await on settled promise ---
async function forOfAwait() {
    var sum = 0;
    for (var x of [Promise.resolve(1), Promise.resolve(2)]) {
        sum += await x;
    }
    return sum;
}

// --- 6. for-let-of with await on settled promise ---
async function forLetOfAwait() {
    var sum = 0;
    for (const x of [Promise.resolve(1), Promise.resolve(2)]) {
        sum += await x;
    }
    return sum;
}

// --- 7. async function with rejected promise inside try/catch ---
async function catchReject() {
    var caught = null;
    try {
        await Promise.reject(new Error("x"));
    } catch (e) {
        caught = e.message;
    }
    return caught;
}

// --- 8. for-loop with PENDING promises (real suspend/resume) ---
var pendingResolvers = [];
function makePending(v) {
    return new Promise(function(r) { pendingResolvers.push(function() { r(v); }); });
}
async function forLoopPending() {
    var sum = 0;
    for (var i = 0; i < 3; i++) {
        sum += await makePending(i);
    }
    return sum;
}

// --- 9. for-let-loop with PENDING promises (real suspend/resume) ---
async function forLetLoopPending() {
    var sum = 0;
    for (let i = 0; i < 3; i++) {
        sum += await makePending(i);
    }
    return sum;
}

// --- 10. async function with 3 sequential awaits on PENDING promises, order check ---
var pendingResolvers2 = [];
function makePendingV(v) {
    return new Promise(function(r) { pendingResolvers2.push(function() { r(v); }); });
}
async function threePendingAwaits() {
    var a = await makePendingV("a");
    var b = await makePendingV("b");
    var c = await makePendingV("c");
    return a + b + c;
}

// --- 11. for-of with PENDING promises ---
var pendingResolvers3 = [];
function makePendingX() {
    return new Promise(function(r) { pendingResolvers3.push(function() { r(10); }); });
}
async function forOfPending() {
    var sum = 0;
    for (var x of [makePendingX(), makePendingX()]) {
        sum += await x;
    }
    return sum;
}

// --- 12. error in for-let-loop with await of rejected promise ---
async function loopWithReject() {
    var lastSeen = null;
    for (let i = 0; i < 3; i++) {
        try {
            if (i === 1) {
                await Promise.reject(new Error("mid"));
            } else {
                await Promise.resolve(i);
            }
        } catch (e) {
            lastSeen = e.message + "@" + i;
        }
    }
    return lastSeen;
}

// --- Fire all tests and check results in a deep microtask drain ---
var p1 = forLoopSettled();
var p2 = forLoopLetSettled();
var p3 = whileLoopSettled();
var p4 = threeAwaits();
var p5 = forOfAwait();
var p6 = forLetOfAwait();
var p7 = catchReject();
var p8 = forLoopPending();
var p9 = forLetLoopPending();
var p10 = threePendingAwaits();
var p11 = forOfPending();
var p12 = loopWithReject();

// Resolve pending ones (synchronously enqueued, but consumed by microtasks)
function flushPending() {
    while (pendingResolvers.length > 0) {
        var r = pendingResolvers.shift();
        r();
    }
    while (pendingResolvers2.length > 0) {
        var r = pendingResolvers2.shift();
        r();
    }
    while (pendingResolvers3.length > 0) {
        var r = pendingResolvers3.shift();
        r();
    }
}

p1.then(function(v)  { results.push(["forLoopSettled", v === 3]); });
p2.then(function(v)  { results.push(["forLoopLetSettled", v === 3]); });
p3.then(function(v)  { results.push(["whileLoopSettled", v === 3]); });
p4.then(function(v)  { results.push(["threeAwaits", v === "abc"]); });
p5.then(function(v)  { results.push(["forOfAwait", v === 3]); });
p6.then(function(v)  { results.push(["forLetOfAwait", v === 3]); });
p7.then(function(v)  { results.push(["catchReject", v === "x"]); });
p8.then(function(v)  { results.push(["forLoopPending", v === 3]); });
p9.then(function(v)  { results.push(["forLetLoopPending", v === 3]); });
p10.then(function(v) { results.push(["threePendingAwaits", v === "abc"]); });
p11.then(function(v) { results.push(["forOfPending", v === 20]); });
p12.then(function(v) { results.push(["loopWithReject", v === "mid@1"]); });

Promise.resolve().then(function() {
    flushPending();
    Promise.resolve().then(function() {
        flushPending();
        Promise.resolve().then(function() {
            flushPending();
            Promise.resolve().then(function() {
                flushPending();
                Promise.resolve().then(function() {
                    for (var i = 0; i < results.length; i++) {
                        assert(results[i][1], results[i][0] + " value correct");
                    }
                    print("test_async_loops: " + pass + " passed, " + fail + " failed");
                    if (fail > 0) throw new Error("FAIL");
                });
            });
        });
    });
});

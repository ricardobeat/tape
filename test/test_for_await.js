// Tests for `for await` / async iteration (ES2018, plan 057).
var pass = 0, fail = 0;
function check(name, actual, expected) {
    if (actual === expected) { pass++; }
    else { fail++; print("FAIL " + name + ": expected " + JSON.stringify(expected) + ", got " + JSON.stringify(actual)); }
}
function arrEq(a, b) {
    if (a.length !== b.length) return false;
    for (var i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
    return true;
}

// A hand-written async iterable: .next() returns a Promise of {value, done}.
function makeAsyncIterable(values) {
    var i = 0;
    return {
        [Symbol.asyncIterator]() { return this; },
        next() {
            if (i < values.length) {
                return Promise.resolve({ value: values[i++], done: false });
            }
            return Promise.resolve({ value: undefined, done: true });
        }
    };
}

var results = [];

async function t1_asyncIterable() {
    var out = [];
    for await (const v of makeAsyncIterable([1, 2, 3])) { out.push(v); }
    check("t1 async iterable", arrEq(out, [1, 2, 3]), true);
}

async function t2_syncArrayFallback() {
    // for await over a plain array (sync iterable → AsyncFromSync adapter).
    var out = [];
    for await (const v of [10, 20, 30]) { out.push(v); }
    check("t2 sync array fallback", arrEq(out, [10, 20, 30]), true);
}

async function t3_awaitedValues() {
    // Sync iterable whose values are promises: for-await resolves each.
    var out = [];
    for await (const v of [Promise.resolve("a"), Promise.resolve("b")]) { out.push(v); }
    check("t3 awaited values", arrEq(out, ["a", "b"]), true);
}

async function t4_break() {
    var out = [];
    for await (const v of makeAsyncIterable([1, 2, 3, 4])) {
        out.push(v);
        if (v === 2) break;
    }
    check("t4 break", arrEq(out, [1, 2]), true);
}

async function t5_destructure() {
    var out = [];
    for await (const [a, b] of makeAsyncIterable([[1, 2], [3, 4]])) { out.push(a + b); }
    check("t5 destructure", arrEq(out, [3, 7]), true);
}

async function t6_returnClosesIterator() {
    var closed = false;
    var it = {
        [Symbol.asyncIterator]() { return this; },
        next() { return Promise.resolve({ value: 1, done: false }); },
        return() { closed = true; return Promise.resolve({ value: undefined, done: true }); }
    };
    async function run() {
        for await (const v of it) { return "early"; }
    }
    var r = await run();
    check("t6 return closes iterator", closed && r === "early", true);
}

async function t7_ordering() {
    // Interleave awaits to confirm suspension/resume works across iterations.
    var log = [];
    for await (const v of makeAsyncIterable([1, 2])) {
        log.push("before" + v);
        await Promise.resolve();
        log.push("after" + v);
    }
    check("t7 ordering", log.join(","), "before1,after1,before2,after2");
}

// Run all sequentially in one async driver, then report.
async function main() {
    await t1_asyncIterable();
    await t2_syncArrayFallback();
    await t3_awaitedValues();
    await t4_break();
    await t5_destructure();
    await t6_returnClosesIterator();
    await t7_ordering();
    print("for-await: " + pass + " pass, " + fail + " fail");
}
main();

// B40 — huge-length array-likes (ToLength to 2^53-1), integer-limit
// TypeErrors, and the two engine bugs found alongside (delete_prop key
// scramble, hidden dense-part writes on plain array-likes).
// Every case here must run in milliseconds — a hang means a 2^53 loop is back.
var pass = 0, fail = 0;

function ok(cond, name) {
    if (cond) { pass = pass + 1; } else { print("FAIL: " + name); fail = fail + 1; }
}
function throwsTypeError(fn, name) {
    try { fn(); print("FAIL: " + name + " (no throw)"); fail = fail + 1; }
    catch (e) { ok(e instanceof TypeError, name + " (TypeError, got " + e + ")"); }
}

var MAX = 9007199254740991; // 2^53 - 1

// ============================================================================
// ToLength clamping and end-iteration (the original MEMKILL repro)
// ============================================================================

// findLast: one predicate call at index 2^53-2, no iteration from 2^32
var calls = 0, seenIdx = null;
var r = Array.prototype.findLast.call({length: Number.MAX_VALUE}, function (v, i) {
    calls = calls + 1; seenIdx = i; return true;
});
ok(calls === 1, "findLast calls predicate once");
ok(seenIdx === MAX - 1, "findLast index is 2^53-2");
ok(r === undefined, "findLast returns hole value undefined");

// findLastIndex: same, returns the index (beyond fastint range → double)
var r2 = Array.prototype.findLastIndex.call({length: MAX}, function () { return true; });
ok(r2 === MAX - 1, "findLastIndex returns 2^53-2");

// lastIndexOf: starts from the true end, finds a sentinel near the limit
var lio = {length: MAX - 1};
lio[MAX - 2] = "match";
ok(Array.prototype.lastIndexOf.call(lio, "match") === MAX - 2,
   "lastIndexOf finds sentinel at 2^53-3");

// indexOf with fromIndex near the limit
var io = {length: MAX};
io[MAX - 1] = "x";
ok(Array.prototype.indexOf.call(io, "x", MAX - 3) === MAX - 1,
   "indexOf with huge fromIndex");

// length values beyond 2^53-1 clamp (Infinity, 2^53+2)
var clamped = {length: Infinity};
Array.prototype.splice.call(clamped);
ok(clamped.length === MAX, "splice() clamps Infinity length to 2^53-1");
var clamped2 = {length: MAX + 3}; // 2^53+2
Array.prototype.splice.call(clamped2);
ok(clamped2.length === MAX, "splice() clamps 2^53+2 length to 2^53-1");

// ============================================================================
// Integer-limit TypeErrors thrown BEFORE mutation
// ============================================================================

throwsTypeError(function () {
    Array.prototype.push.call({length: MAX}, 1);
}, "push past 2^53-1 throws");

var pushTarget = {length: MAX};
try { Array.prototype.push.call(pushTarget, 1, 2); } catch (e) {}
ok(!(MAX in pushTarget), "push throws before writing any element");

throwsTypeError(function () {
    Array.prototype.unshift.call({length: MAX}, 1);
}, "unshift past 2^53-1 throws");

throwsTypeError(function () {
    var spread = {length: MAX};
    spread[Symbol.isConcatSpreadable] = true;
    [1].concat(spread);
}, "concat past 2^53-1 throws");

// unshift with no args: no shift loop, just re-clamps length
var un = {length: MAX + 3};
ok(Array.prototype.unshift.call(un) === MAX, "unshift() returns clamped length");
ok(un.length === MAX, "unshift() clamps length");

// push return value beyond fastint range survives as an exact double
var pr = Array.prototype.push.call({length: MAX - 2}, "a");
ok(pr === MAX - 1, "push returns exact length above 2^47");

// ============================================================================
// Methods near the limit operate on the right indices
// ============================================================================

// pop: reads/deletes at 2^53-2, leaves neighbours alone
var popObj = {length: MAX};
popObj[MAX - 2] = "v-2";
popObj[MAX - 1] = "v-1";
ok(Array.prototype.pop.call(popObj) === "v-1", "pop returns element at 2^53-2");
ok(!((MAX - 1) in popObj), "pop deletes the popped property");
ok(popObj[MAX - 2] === "v-2", "pop leaves the neighbour");
ok(popObj.length === MAX - 1, "pop decrements huge length");

// slice: negative and absolute indices near the limit
var sl = {length: MAX + 3};
sl[MAX - 2] = "A";
sl[MAX - 1] = "B";
var slr = Array.prototype.slice.call(sl, -2);
ok(slr.length === 2 && slr[0] === "A" && slr[1] === "B", "slice(-2) near the limit");

// splice: delete 2 at the end
var sp = {length: MAX + 3};
sp[MAX - 2] = "A";
sp[MAX - 1] = "B";
var spr = Array.prototype.splice.call(sp, MAX - 2);
ok(spr.length === 2 && spr[0] === "A" && spr[1] === "B", "splice removes tail pair");
ok(sp.length === MAX - 2, "splice shrinks huge length");

// fill: a 3-element window near the limit
var fl = {length: MAX};
Array.prototype.fill.call(fl, "F", MAX - 3, MAX - 1);
ok(fl[MAX - 3] === "F" && fl[MAX - 2] === "F" && !((MAX - 1) in fl),
   "fill writes [start,end) near the limit");

// copyWithin: copy from the top of the range to the bottom, holes delete
var cw = {0: 0, 1: 1, 2: 2, length: MAX};
cw[MAX - 3] = -3;
cw[MAX - 1] = -1;
Array.prototype.copyWithin.call(cw, 0, MAX - 3, MAX);
ok(cw[0] === -3, "copyWithin copies from huge source index");
ok(!(1 in cw), "copyWithin deletes target when source is a hole");
ok(cw[2] === -1, "copyWithin copies the third element");

// reduceRight: skips holes between huge indices, exact index arg
var rr = {length: MAX};
rr[MAX - 1] = 1;
rr[MAX - 3] = 3;
var seen = [];
try {
    Array.prototype.reduceRight.call(rr, function (acc, el, index) {
        seen.push([el, index]);
        if (el === 3) { throw acc; }
        return acc;
    }, []);
    ok(false, "reduceRight should have thrown the accumulator");
} catch (acc) {
    ok(seen.length === 2, "reduceRight visited exactly 2 elements");
    ok(seen[0][0] === 1 && seen[0][1] === MAX - 1, "reduceRight first visit at 2^53-2");
    ok(seen[1][0] === 3 && seen[1][1] === MAX - 3, "reduceRight second visit at 2^53-4");
}

// find on holes: predicate sees undefined instead of being skipped
var fCalls = 0;
Array.prototype.find.call({length: 3}, function () { fCalls = fCalls + 1; return false; });
ok(fCalls === 3, "find calls predicate on holes");

// ============================================================================
// Getter errors propagate out of the huge loops (no silent skip-and-spin)
// ============================================================================

function Poison() {}
// length is 2^53-2 so unshift(1 item) passes the integer-limit check and
// reaches the shift loop, whose first read (index 2^53-3) is poisoned.
var poisoned = {length: MAX - 1};
Object.defineProperty(poisoned, MAX - 2, {
    get: function () { throw new Poison(); },
    enumerable: true, configurable: true
});
try {
    Array.prototype.unshift.call(poisoned, null);
    ok(false, "unshift should propagate poisoned getter");
} catch (e) {
    ok(e instanceof Poison, "unshift propagates poisoned getter");
}
ok(poisoned.length === MAX - 1, "unshift leaves length on throw");

// at the limit exactly, the TypeError wins before any element is read
var atLimit = {length: MAX};
Object.defineProperty(atLimit, MAX - 1, {
    get: function () { throw new Poison(); },
    enumerable: true, configurable: true
});
throwsTypeError(function () {
    Array.prototype.unshift.call(atLimit, null);
}, "unshift at limit throws TypeError before reading elements");

var poisonSpread = {length: MAX};
poisonSpread[Symbol.isConcatSpreadable] = true;
Object.defineProperty(poisonSpread, 0, {
    get: function () { throw new Poison(); },
    enumerable: true, configurable: true
});
try {
    [].concat(poisonSpread);
    ok(false, "concat should propagate poisoned getter");
} catch (e) {
    ok(e instanceof Poison, "concat propagates poisoned getter");
}

// ============================================================================
// Engine bug 1: delete_prop must keep surviving key→value pairs aligned
// ============================================================================

var d1 = {a: 1, b: 2, c: 3, d: 4};
delete d1.b;
ok(d1.a === 1 && d1.c === 3 && d1.d === 4, "delete middle prop keeps mapping");
ok(!("b" in d1), "deleted prop is gone");

var d2 = {p: "P", q: "Q", r: "R", s: "S", t: "T"};
delete d2.p;
delete d2.s;
ok(d2.q === "Q" && d2.r === "R" && d2.t === "T", "two deletes keep mapping");

var d3 = {"9007199254740989": "A", "9007199254740990": "B", "9007199254740991": "C", length: 42};
delete d3["9007199254740990"];
ok(d3["9007199254740989"] === "A" && d3["9007199254740991"] === "C" && d3.length === 42,
   "delete huge numeric key keeps mapping");

// ============================================================================
// Engine bug 2: builtin writes to plain array-likes must hit named props
// ============================================================================

// copyWithin onto an object whose small indices are named props: the write
// must replace the named prop, not vanish into a hidden dense slot.
var hp = {0: "old0", 1: "old1", 2: "old2", length: 3};
Array.prototype.copyWithin.call(hp, 0, 2, 3);
ok(hp[0] === "old2", "copyWithin write visible over named prop");

var hp2 = {0: "a", 1: "b", length: 2};
Array.prototype.reverse.call(hp2);
ok(hp2[0] === "b" && hp2[1] === "a", "reverse swaps named props on plain object");

var hp3 = {0: "x", length: 1};
Array.prototype.fill.call(hp3, "y");
ok(hp3[0] === "y", "fill write visible over named prop");

var hp4 = {0: "first", 1: "second", length: 2};
Array.prototype.unshift.call(hp4, "zero");
ok(hp4[0] === "zero" && hp4[1] === "first" && hp4[2] === "second" && hp4.length === 3,
   "unshift shifts named props on plain object");

// ============================================================================
// Regression guards for real (dense) arrays
// ============================================================================

var real = [1, 2, 3];
real.push(4);
ok(real.length === 4 && real[3] === 4, "push on real array");
ok(real.pop() === 4 && real.length === 3, "pop on real array");
real.unshift(0);
ok(real[0] === 0 && real.length === 4, "unshift on real array");
ok(real.splice(1, 2).length === 2 && real.length === 2, "splice on real array");
var rev = [1, 2, 3].reverse();
ok(rev[0] === 3 && rev[2] === 1, "reverse on real array");
ok([1, 2, 3].slice(1).join(",") === "2,3", "slice on real array");
ok([, 1].findIndex(function (v) { return v === undefined; }) === 0,
   "findIndex sees hole as undefined");
var ch = [].concat([, 1]);
ok(ch.length === 2 && !(0 in ch) && ch[1] === 1, "concat preserves holes");

print("pass: " + pass + " fail: " + fail);

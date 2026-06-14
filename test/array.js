// Test Array constructor + Array.prototype methods — Phase 6c
var pass = 0, fail = 0;

// ============================================================================
// Array constructor tests (existing)
// ============================================================================

// Array() with no args
var a1 = Array();
if (typeof a1 === "object") { pass = pass + 1; } else { print("FAIL: Array() type"); fail = fail + 1; }

// new Array() with no args
var a2 = new Array();
if (typeof a2 === "object") { pass = pass + 1; } else { print("FAIL: new Array() type"); fail = fail + 1; }

// Array(3) with one numeric arg
var a3 = Array(3);
if (a3.length === 3) { pass = pass + 1; } else { print("FAIL: Array(3).length"); fail = fail + 1; }

// new Array(3) with one numeric arg
var a4 = new Array(3);
if (a4.length === 3) { pass = pass + 1; } else { print("FAIL: new Array(3).length"); fail = fail + 1; }

// Array(1, 2, 3) with multiple args
var a5 = Array(1, 2, 3);
if (a5.length === 3 && a5[0] === 1 && a5[1] === 2 && a5[2] === 3) {
    pass = pass + 1;
} else {
    print("FAIL: Array(1,2,3)"); fail = fail + 1;
}

// new Array(1, 2, 3) with multiple args
var a6 = new Array(1, 2, 3);
if (a6.length === 3 && a6[0] === 1 && a6[1] === 2 && a6[2] === 3) {
    pass = pass + 1;
} else {
    print("FAIL: new Array(1,2,3)"); fail = fail + 1;
}

// Array("hello") with single non-numeric arg
var a7 = Array("hello");
if (a7.length === 1 && a7[0] === "hello") {
    pass = pass + 1;
} else {
    print("FAIL: Array('hello')"); fail = fail + 1;
}

// typeof Array is "function"
if (typeof Array === "function") { pass = pass + 1; } else { print("FAIL: typeof Array"); fail = fail + 1; }

// Array(0) with length 0
var a8 = Array(0);
if (a8.length === 0) { pass = pass + 1; } else { print("FAIL: Array(0).length"); fail = fail + 1; }

// Array(true) with non-numeric arg (boolean)
var a9 = Array(true);
if (a9.length === 1 && a9[0] === true) {
    pass = pass + 1;
} else {
    print("FAIL: Array(true)"); fail = fail + 1;
}

// ============================================================================
// Array.prototype.push
// ============================================================================
var arr_push = [];
var len_push = arr_push.push(10);
if (len_push === 1 && arr_push.length === 1 && arr_push[0] === 10) {
    pass = pass + 1;
} else { print("FAIL: push single"); fail = fail + 1; }

len_push = arr_push.push(20, 30);
if (len_push === 3 && arr_push.length === 3 && arr_push[1] === 20 && arr_push[2] === 30) {
    pass = pass + 1;
} else { print("FAIL: push multiple"); fail = fail + 1; }

// Push returns the new length
var arr_push2 = [];
var r = arr_push2.push();
if (r === 0) { pass = pass + 1; } else { print("FAIL: push empty"); fail = fail + 1; }

// ============================================================================
// Array.prototype.pop
// ============================================================================
var arr_pop = [1, 2, 3];
var popped = arr_pop.pop();
if (popped === 3 && arr_pop.length === 2) {
    pass = pass + 1;
} else { print("FAIL: pop basic"); fail = fail + 1; }

popped = arr_pop.pop();
if (popped === 2 && arr_pop.length === 1) {
    pass = pass + 1;
} else { print("FAIL: pop second"); fail = fail + 1; }

popped = arr_pop.pop();
if (popped === 1 && arr_pop.length === 0) {
    pass = pass + 1;
} else { print("FAIL: pop third"); fail = fail + 1; }

// Pop from empty array returns undefined
popped = arr_pop.pop();
if (popped === undefined && arr_pop.length === 0) {
    pass = pass + 1;
} else { print("FAIL: pop empty"); fail = fail + 1; }

// ============================================================================
// Array.prototype.shift
// ============================================================================
var arr_shift = [1, 2, 3];
var shifted = arr_shift.shift();
if (shifted === 1 && arr_shift.length === 2 && arr_shift[0] === 2) {
    pass = pass + 1;
} else { print("FAIL: shift basic"); fail = fail + 1; }

shifted = arr_shift.shift();
if (shifted === 2 && arr_shift.length === 1 && arr_shift[0] === 3) {
    pass = pass + 1;
} else { print("FAIL: shift second"); fail = fail + 1; }

shifted = arr_shift.shift();
if (shifted === 3 && arr_shift.length === 0) {
    pass = pass + 1;
} else { print("FAIL: shift third"); fail = fail + 1; }

// Shift from empty array returns undefined
shifted = arr_shift.shift();
if (shifted === undefined && arr_shift.length === 0) {
    pass = pass + 1;
} else { print("FAIL: shift empty"); fail = fail + 1; }

// ============================================================================
// Array.prototype.unshift
// ============================================================================
var arr_unshift = [];
var len_unshift = arr_unshift.unshift(1, 2);
if (len_unshift === 2 && arr_unshift.length === 2 && arr_unshift[0] === 1 && arr_unshift[1] === 2) {
    pass = pass + 1;
} else { print("FAIL: unshift basic"); fail = fail + 1; }

len_unshift = arr_unshift.unshift(0);
if (len_unshift === 3 && arr_unshift.length === 3 && arr_unshift[0] === 0 && arr_unshift[1] === 1 && arr_unshift[2] === 2) {
    pass = pass + 1;
} else { print("FAIL: unshift prepend"); fail = fail + 1; }

// Unshift returns new length
var arr_unshift2 = [1];
if (arr_unshift2.unshift() === 1) { pass = pass + 1; } else { print("FAIL: unshift no args"); fail = fail + 1; }

// ============================================================================
// Array.prototype.indexOf
// ============================================================================
var arr_idx = [1, 2, 3, 2, 1];
if (arr_idx.indexOf(2) === 1) { pass = pass + 1; } else { print("FAIL: indexOf basic"); fail = fail + 1; }
if (arr_idx.indexOf(4) === -1) { pass = pass + 1; } else { print("FAIL: indexOf not found"); fail = fail + 1; }
if (arr_idx.indexOf(2, 2) === 3) { pass = pass + 1; } else { print("FAIL: indexOf fromIndex"); fail = fail + 1; }
if (arr_idx.indexOf(1, -2) === 4) { pass = pass + 1; } else { print("FAIL: indexOf negative fromIndex"); fail = fail + 1; }
if (arr_idx.indexOf("1") === -1) { pass = pass + 1; } else { print("FAIL: indexOf type strict"); fail = fail + 1; }
if ([].indexOf(1) === -1) { pass = pass + 1; } else { print("FAIL: indexOf empty"); fail = fail + 1; }

// ============================================================================
// Array.prototype.lastIndexOf
// ============================================================================
var arr_lidx = [1, 2, 3, 2, 1];
if (arr_lidx.lastIndexOf(2) === 3) { pass = pass + 1; } else { print("FAIL: lastIndexOf basic"); fail = fail + 1; }
if (arr_lidx.lastIndexOf(4) === -1) { pass = pass + 1; } else { print("FAIL: lastIndexOf not found"); fail = fail + 1; }
if (arr_lidx.lastIndexOf(2, 2) === 1) { pass = pass + 1; } else { print("FAIL: lastIndexOf fromIndex"); fail = fail + 1; }
if (arr_lidx.lastIndexOf(1, -3) === 0) { pass = pass + 1; } else { print("FAIL: lastIndexOf negative"); fail = fail + 1; }
if ([].lastIndexOf(1) === -1) { pass = pass + 1; } else { print("FAIL: lastIndexOf empty"); fail = fail + 1; }

// ============================================================================
// Array.prototype.join
// ============================================================================
var arr_join = [1, 2, 3];
if (arr_join.join() === "1,2,3") { pass = pass + 1; } else { print("FAIL: join default sep"); fail = fail + 1; }
if (arr_join.join("") === "123") { pass = pass + 1; } else { print("FAIL: join empty sep"); fail = fail + 1; }
if (arr_join.join("-") === "1-2-3") { pass = pass + 1; } else { print("FAIL: join custom sep"); fail = fail + 1; }
if ([].join() === "") { pass = pass + 1; } else { print("FAIL: join empty array"); fail = fail + 1; }
if ([1].join(",") === "1") { pass = pass + 1; } else { print("FAIL: join single"); fail = fail + 1; }

// join with undefined/null elements (treated as empty)
var arr_mixed = [1, undefined, 3];
if (arr_mixed.join(",") === "1,,3") { pass = pass + 1; } else { print("FAIL: join with undefined"); fail = fail + 1; }

// ============================================================================
// Array.prototype.toString
// ============================================================================
var arr_ts = [1, 2, 3];
if (arr_ts.toString() === "1,2,3") { pass = pass + 1; } else { print("FAIL: toString basic"); fail = fail + 1; }
if ([].toString() === "") { pass = pass + 1; } else { print("FAIL: toString empty"); fail = fail + 1; }
if ([1].toString() === "1") { pass = pass + 1; } else { print("FAIL: toString single"); fail = fail + 1; }
var arr_ts2 = ["a", "b", "c"];
if (arr_ts2.toString() === "a,b,c") { pass = pass + 1; } else { print("FAIL: toString strings"); fail = fail + 1; }

// ============================================================================
// Array.prototype.slice
// ============================================================================
var arr_slice = [1, 2, 3, 4, 5];
var sl = arr_slice.slice();
if (sl.length === 5 && sl[0] === 1 && sl[4] === 5) { pass = pass + 1; } else { print("FAIL: slice no args"); fail = fail + 1; }

var sl2 = arr_slice.slice(1, 3);
if (sl2.length === 2 && sl2[0] === 2 && sl2[1] === 3) { pass = pass + 1; } else { print("FAIL: slice range"); fail = fail + 1; }

var sl3 = arr_slice.slice(2);
if (sl3.length === 3 && sl3[0] === 3 && sl3[2] === 5) { pass = pass + 1; } else { print("FAIL: slice from start"); fail = fail + 1; }

var sl4 = arr_slice.slice(-2);
if (sl4.length === 2 && sl4[0] === 4 && sl4[1] === 5) { pass = pass + 1; } else { print("FAIL: slice negative start"); fail = fail + 1; }

var sl5 = arr_slice.slice(0, -1);
if (sl5.length === 4 && sl5[0] === 1 && sl5[3] === 4) { pass = pass + 1; } else { print("FAIL: slice negative end"); fail = fail + 1; }

if ([].slice().length === 0) { pass = pass + 1; } else { print("FAIL: slice empty"); fail = fail + 1; }

// ============================================================================
// Array.prototype.concat
// ============================================================================
var arr_concat1 = [1, 2];
var concat_result = arr_concat1.concat([3, 4]);
if (concat_result.length === 4 && concat_result[0] === 1 && concat_result[3] === 4) {
    pass = pass + 1;
} else { print("FAIL: concat arrays"); fail = fail + 1; }

concat_result = arr_concat1.concat(3, 4);
if (concat_result.length === 4 && concat_result[0] === 1 && concat_result[3] === 4) {
    pass = pass + 1;
} else { print("FAIL: concat values"); fail = fail + 1; }

concat_result = [].concat([1], [2]);
if (concat_result.length === 2 && concat_result[0] === 1 && concat_result[1] === 2) {
    pass = pass + 1;
} else { print("FAIL: concat empty with arrays"); fail = fail + 1; }

concat_result = [].concat(1, 2, 3);
if (concat_result.length === 3 && concat_result[0] === 1 && concat_result[2] === 3) {
    pass = pass + 1;
} else { print("FAIL: concat values only"); fail = fail + 1; }

// Original array unchanged
if (arr_concat1.length === 2) { pass = pass + 1; } else { print("FAIL: concat original unchanged"); fail = fail + 1; }

// ============================================================================
// Array.prototype.reverse
// ============================================================================
var arr_rev = [1, 2, 3, 4];
arr_rev.reverse();
if (arr_rev.length === 4 && arr_rev[0] === 4 && arr_rev[3] === 1) {
    pass = pass + 1;
} else { print("FAIL: reverse elements"); fail = fail + 1; }

var arr_rev2 = [1];
arr_rev2.reverse();
if (arr_rev2[0] === 1) { pass = pass + 1; } else { print("FAIL: reverse single"); fail = fail + 1; }

[].reverse();
pass = pass + 1;  // reverse on empty array shouldn't throw

// ============================================================================
// Array.prototype.sort (default compare)
// ============================================================================
var arr_sort = [3, 1, 4, 1, 5, 9, 2, 6];
arr_sort.sort();
if (arr_sort[0] === 1 && arr_sort[1] === 1 && arr_sort[7] === 9) {
    pass = pass + 1;
} else { print("FAIL: sort numbers"); fail = fail + 1; }

// Sort strings
var arr_str = ["banana", "apple", "cherry"];
arr_str.sort();
if (arr_str[0] === "apple" && arr_str[1] === "banana" && arr_str[2] === "cherry") {
    pass = pass + 1;
} else { print("FAIL: sort strings"); fail = fail + 1; }

// Sort single element
var arr_single = [42];
arr_single.sort();
if (arr_single[0] === 42) { pass = pass + 1; } else { print("FAIL: sort single"); fail = fail + 1; }

// Sort empty
[].sort();
pass = pass + 1;

// ============================================================================
// Array.prototype.splice
// ============================================================================
var arr_spl = [1, 2, 3, 4, 5];
var removed = arr_spl.splice(2, 1);
if (removed.length === 1 && removed[0] === 3 && arr_spl.length === 4 && arr_spl[2] === 4) {
    pass = pass + 1;
} else { print("FAIL: splice remove one"); fail = fail + 1; }

var arr_spl2 = [1, 2, 3, 4, 5];
removed = arr_spl2.splice(1, 2, 10, 20);
if (removed.length === 2 && removed[0] === 2 && removed[1] === 3 && arr_spl2.length === 5 && arr_spl2[0] === 1 && arr_spl2[1] === 10 && arr_spl2[2] === 20 && arr_spl2[3] === 4 && arr_spl2[4] === 5) {
    pass = pass + 1;
} else { print("FAIL: splice remove and insert"); fail = fail + 1; }

var arr_spl3 = [1, 2, 3];
removed = arr_spl3.splice(0, 0, "a", "b");
if (removed.length === 0 && arr_spl3.length === 5 && arr_spl3[0] === "a" && arr_spl3[1] === "b" && arr_spl3[2] === 1 && arr_spl3[3] === 2 && arr_spl3[4] === 3) {
    pass = pass + 1;
} else { print("FAIL: splice insert only"); fail = fail + 1; }

var arr_spl4 = [1, 2, 3, 4, 5];
removed = arr_spl4.splice(2);
if (removed.length === 3 && removed[0] === 3 && removed[2] === 5 && arr_spl4.length === 2) {
    pass = pass + 1;
} else { print("FAIL: splice from index to end"); fail = fail + 1; }

var arr_spl5 = [1, 2, 3, 4, 5];
removed = arr_spl5.splice(-2, 1);
if (removed.length === 1 && removed[0] === 4 && arr_spl5.length === 4) {
    pass = pass + 1;
} else { print("FAIL: splice negative start"); fail = fail + 1; }

// ============================================================================
// Chained usage
// ============================================================================
var arr_chain = [];
arr_chain.push(1, 2, 3);
arr_chain.push(4, 5);
var chained_pop = arr_chain.pop();
if (chained_pop === 5 && arr_chain.length === 4 && arr_chain.join(",") === "1,2,3,4") {
    pass = pass + 1;
} else { print("FAIL: chain push+pop+join"); fail = fail + 1; }

// ============================================================================
// Edge cases
// ============================================================================
// concat preserves elements (undefined for missing)
var arr_holey = [1, , 3];
var concat_holey = arr_holey.concat([4]);
if (concat_holey.length === 4 && concat_holey[0] === 1 && concat_holey[2] === 3 && concat_holey[3] === 4) {
    pass = pass + 1;
} else { print("FAIL: concat holey array"); fail = fail + 1; }

// pop after push
var arr_pp = [];
arr_pp.push("a");
arr_pp.push("b");
var p = arr_pp.pop();
if (p === "b" && arr_pp.length === 1 && arr_pp[0] === "a") { pass = pass + 1; } else { print("FAIL: pop after push"); fail = fail + 1; }

// shift after push
var arr_sp = [];
arr_sp.push("a");
arr_sp.push("b");
var s = arr_sp.shift();
if (s === "a" && arr_sp.length === 1 && arr_sp[0] === "b") { pass = pass + 1; } else { print("FAIL: shift after push"); fail = fail + 1; }

// unshift into non-empty, then toString
var arr_uts = [2, 3];
arr_uts.unshift(0, 1);
if (arr_uts.toString() === "0,1,2,3") { pass = pass + 1; } else { print("FAIL: unshift then toString"); fail = fail + 1; }

// push on array from Array constructor
var arr_ac = new Array();
arr_ac.push(99);
if (arr_ac.length === 1 && arr_ac[0] === 99) { pass = pass + 1; } else { print("FAIL: push on Array()"); fail = fail + 1; }

var arr_ac2 = new Array(3);
arr_ac2.push(42);
if (arr_ac2.length === 4 && arr_ac2[3] === 42) { pass = pass + 1; } else { print("FAIL: push on Array(3)"); fail = fail + 1; }

// ============================================================================
// Array length validation per ES5 §15.4.5.1 (ArraySetLength)
// ============================================================================

// [].length = 4294967296 (overflow) → RangeError
try { var aov = []; aov.length = 4294967296; print("FAIL: [].length = 4294967296 did not throw"); fail = fail + 1; }
catch (e) { if (e instanceof RangeError) { pass = pass + 1; } else { print("FAIL: overflow threw wrong error: " + e); fail = fail + 1; } }

// [].length = -1 → RangeError (no-op for the assignment semantics)
try { var an = []; an.length = -1; print("FAIL: [].length = -1 did not throw"); fail = fail + 1; }
catch (e) { if (e instanceof RangeError) { pass = pass + 1; } else { print("FAIL: -1 threw wrong error: " + e); fail = fail + 1; } }

// [].length = 1.5 → RangeError
try { var af = []; af.length = 1.5; print("FAIL: [].length = 1.5 did not throw"); fail = fail + 1; }
catch (e) { if (e instanceof RangeError) { pass = pass + 1; } else { print("FAIL: 1.5 threw wrong error: " + e); fail = fail + 1; } }

// [].length = NaN → RangeError
try { var an2 = []; an2.length = NaN; print("FAIL: [].length = NaN did not throw"); fail = fail + 1; }
catch (e) { if (e instanceof RangeError) { pass = pass + 1; } else { print("FAIL: NaN threw wrong error: " + e); fail = fail + 1; } }

// [].length = Infinity → RangeError
try { var ai = []; ai.length = Infinity; print("FAIL: [].length = Infinity did not throw"); fail = fail + 1; }
catch (e) { if (e instanceof RangeError) { pass = pass + 1; } else { print("FAIL: Infinity threw wrong error: " + e); fail = fail + 1; } }

// Object.defineProperty([], 'length', { value: -1 }) → RangeError
try { Object.defineProperty([], 'length', { value: -1, configurable: true }); print("FAIL: defineProperty -1 did not throw"); fail = fail + 1; }
catch (e) { if (e instanceof RangeError) { pass = pass + 1; } else { print("FAIL: defineProperty -1 threw wrong error: " + e); fail = fail + 1; } }

// Object.defineProperty([], 'length', { value: 1.5 }) → RangeError
try { Object.defineProperty([], 'length', { value: 1.5, configurable: true }); print("FAIL: defineProperty 1.5 did not throw"); fail = fail + 1; }
catch (e) { if (e instanceof RangeError) { pass = pass + 1; } else { print("FAIL: defineProperty 1.5 threw wrong error: " + e); fail = fail + 1; } }

// Object.defineProperty([], 'length', { value: 4294967296 }) → RangeError
try { Object.defineProperty([], 'length', { value: 4294967296, configurable: true }); print("FAIL: defineProperty 4294967296 did not throw"); fail = fail + 1; }
catch (e) { if (e instanceof RangeError) { pass = pass + 1; } else { print("FAIL: defineProperty 4294967296 threw wrong error: " + e); fail = fail + 1; } }

// Valid lengths still work
var av = [1, 2, 3, 4, 5];
av.length = 3;
if (av.length === 3) { pass = pass + 1; } else { print("FAIL: av.length = 3"); fail = fail + 1; }

av.length = 100;
if (av.length === 100) { pass = pass + 1; } else { print("FAIL: av.length = 100"); fail = fail + 1; }

av.length = 0;
if (av.length === 0) { pass = pass + 1; } else { print("FAIL: av.length = 0"); fail = fail + 1; }

print("pass: " + pass + " fail: " + fail);

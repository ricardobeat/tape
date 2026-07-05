// Plan 041 oracle — remaining array-like gaps NOT fixed by B40 (commit 73c8b53).
// These cases FAIL today by design; plan 041 (array_set_elem retirement +
// remaining ToUint32→ToLength migrations) is done when this prints "fail: 0".
// Run: ./out/test_vm test/test_041_array_like_gaps.js
var pass = 0, fail = 0;

function ok(cond, name) {
    if (cond) { pass = pass + 1; } else { print("FAIL: " + name); fail = fail + 1; }
}

var MAX = 9007199254740991; // 2^53 - 1

// ============================================================================
// shift — still uses array_get_elem/array_set_elem (hidden dense writes,
// no named-prop delete) and ToUint32 length
// ============================================================================

var sh = {0: "a", 1: "b", length: 2};
var shr = Array.prototype.shift.call(sh);
ok(shr === "a", "shift returns first element");
ok(sh[0] === "b", "shift moves named prop down"); // FAILS: hidden dense write
ok(!(1 in sh), "shift deletes vacated slot");     // FAILS: no named delete
ok(sh.length === 1, "shift decrements length");

// shift near the limit: reads/writes at huge indices, deletes the top slot
var shBig = {length: 3};
shBig[0] = "x";
shBig[1] = "y";
shBig[2] = "z";
Object.defineProperty(shBig, 0, {value: "x", writable: true, enumerable: true, configurable: true});
var shBigR = Array.prototype.shift.call(shBig);
ok(shBigR === "x" && shBig[0] === "y" && shBig[1] === "z" && !(2 in shBig),
   "shift shifts all named props and deletes the tail");

// ============================================================================
// sort — sorts into a hidden dense part on plain array-likes
// ============================================================================

var so = {0: "b", 1: "a", length: 2};
Array.prototype.sort.call(so);
ok(so[0] === "a" && so[1] === "b", "sort orders named props on plain object");

var soNum = {0: 3, 1: 1, 2: 2, length: 3};
Array.prototype.sort.call(soNum, function (x, y) { return x - y; });
ok(soNum[0] === 1 && soNum[1] === 2 && soNum[2] === 3,
   "sort with comparator on plain object");

// ============================================================================
// at / includes — still ToUint32 length
// ============================================================================

var atO = {length: MAX};
atO[MAX - 1] = "last";
ok(Array.prototype.at.call(atO, -1) === "last", "at(-1) near 2^53-1");

var inc = {length: MAX};
inc[MAX - 1] = "x";
ok(Array.prototype.includes.call(inc, "x", MAX - 2) === true,
   "includes with fromIndex near 2^53-1");

// ============================================================================
// set_array_idx visibility rule — a builtin write through the dense part
// must never be shadowed by an existing named numeric property. These pin
// the general contract the plan-041 fix must establish for ANY writer, not
// just the methods patched in B40.
// ============================================================================

// reverse round-trips through both a named prop and a dense-capable index
var rv = {0: "n0", 1: "n1", 2: "n2", length: 3};
Array.prototype.reverse.call(rv);
Array.prototype.reverse.call(rv);
ok(rv[0] === "n0" && rv[1] === "n1" && rv[2] === "n2",
   "double reverse is identity on named props");

// after a builtin writes index 0, a subsequent delete must actually clear it
var dv = {0: "old", length: 1};
Array.prototype.fill.call(dv, "new");
delete dv[0];
ok(!(0 in dv) && dv[0] === undefined, "delete clears builtin-written slot");

// Object.keys must see builtin-written indices (named props, not hidden dense)
var kv = {length: 2};
Array.prototype.fill.call(kv, "k");
var keys = Object.keys(kv).sort().join(",");
ok(keys === "0,1,length", "builtin writes are enumerable own props, got: " + keys);

print("pass: " + pass + " fail: " + fail);

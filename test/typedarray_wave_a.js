// Plan 049 stage 4 oracle: %TypedArray%.prototype wave A methods.
var failures = 0;
function check(cond, msg) {
    if (!cond) {
        failures++;
        print("FAIL: " + msg);
    }
}

// ---- Iteration: values / keys / entries / [Symbol.iterator] ----

// for-of via values (implicit @@iterator)
var vals = [];
for (var v of new Int8Array([1, 2, 3])) {
    vals.push(v);
}
check(vals.join(',') === '1,2,3', 'for-of Int8Array');

// Spread via @@iterator
var spread = [].concat(Array.from(new Int16Array([10, 20])));
check(spread[0] === 10 && spread[1] === 20, 'spread Int16Array');

// .keys()
var keys = [];
var kit = new Uint8Array([5, 6, 7]).keys();
var r;
while (!(r = kit.next()).done) keys.push(r.value);
check(keys.join(',') === '0,1,2', 'keys() Int8Array');

// .entries()
var ents = [];
var eit = new Int8Array([1, 2, 3]).entries();
while (!(r = eit.next()).done) ents.push(r.value[0] + ':' + r.value[1]);
check(ents.join(',') === '0:1,1:2,2:3', 'entries() Int8Array');

// ---- set ----

// Array-like source with offset
var a = new Int8Array(5);
a.set([1, 2, 3], 1);
check(Array.from(a).join(',') === '0,1,2,3,0', 'set array-like with offset');

// Same-buffer overlap via subarray (memmove semantics)
var b = new Int8Array([1, 2, 3, 4, 5]);
b.set(b.subarray(0, 3), 1);
check(Array.from(b).join(',') === '1,1,2,3,5', 'set same-buffer overlap');

// Cross-class: Int16Array -> Uint8Array
var u = new Uint8Array(3);
u.set(new Int16Array([1, 2, 3]));
check(Array.from(u).join(',') === '1,2,3', 'set cross-class');

// OOB source should RangeError
var threw = false;
try { new Int8Array(2).set([1, 2, 3]); } catch (e) { threw = true; }
check(threw, 'set OOB throws RangeError');

// ---- subarray ----

var src = new Int16Array([10, 20, 30, 40]);
var sub = src.subarray(1, 3);
check(Array.from(sub).join(',') === '20,30', 'subarray values');
check(sub.buffer === src.buffer, 'subarray shares buffer');
sub[0] = 99;
check(src[1] === 99, 'subarray mutation reflected in original');
check(sub.length === 2, 'subarray length');

// ---- fill ----

check(Array.from(new Uint8Array(4).fill(7)).join(',') === '7,7,7,7', 'fill all');
check(Array.from(new Uint8Array(4).fill(9, 1, 3)).join(',') === '0,9,9,0', 'fill range');
// Uint8ClampedArray: 300 -> 255
check(Array.from(new Uint8ClampedArray(4).fill(300)).join(',') === '255,255,255,255',
      'fill Uint8ClampedArray clamp');

// ---- copyWithin ----

var c = new Int8Array([1, 2, 3, 4, 5]);
c.copyWithin(0, 3);
check(Array.from(c).join(',') === '4,5,3,4,5', 'copyWithin(0,3)');

// ---- slice ----

var src2 = new Int16Array([1, 2, 3, 4, 5]);
var s = src2.slice(1, 4);
check(Array.from(s).join(',') === '2,3,4', 'slice values');
check(s.buffer !== src2.buffer, 'slice fresh buffer');
check(s.length === 3, 'slice length');

if (failures === 0) {
    print("PASS");
} else {
    print("FAIL: " + failures + " test(s) failed");
}

// Regression test for B21: get_prop_proto(...)!! force-unwrap UB.
//
// Per ES2015 §23.3.1 / §23.4.1, WeakMap and WeakSet constructors MUST
// throw a TypeError when the argument is not iterable. A pre-fix engine
// silently skipped the throw in some cases (stale stack bytes from a
// prior successful construction were misread as a callable @@iterator).

function expectThrow(name, fn) {
    try {
        fn();
        print("FAIL " + name + ": no throw");
        return false;
    } catch (e) {
        if (e instanceof TypeError) {
            print("PASS " + name + ": TypeError thrown");
            return true;
        }
        print("FAIL " + name + ": got " + e.constructor.name + ", expected TypeError");
        return false;
    }
}

// Warm up: a successful iterator-protocol construction that leaves
// stack residue in the slot later used to read @@iterator.
var s = new Set([1, 2, 3]);
print("set has 3:", s.size);

// Now feed a non-iterable to a WeakMap — must throw, not silently succeed.
expectThrow("WeakMap(non-iterable)", function () { new WeakMap(42); });
expectThrow("WeakSet(non-iterable)", function () { new WeakSet(42); });
expectThrow("WeakMap(plain obj)",   function () { new WeakMap({});   });
expectThrow("WeakSet(plain obj)",   function () { new WeakSet({});   });

// Sanity: legitimate iterables still work.
var ws = new WeakSet([{}, {}]);
print("WeakSet iterable ok");

// Map/Set with non-iterable: per spec, fall back to array-like iteration,
// so Map(42) throws and Set(42) throws.
expectThrow("Map(42)", function () { new Map(42); });
expectThrow("Set(42)", function () { new Set(42); });

// Empty argument is fine.
var m0 = new Map();
var s0 = new Set();
print("empty Map/Set ok");

// Iterable whose .next throws — the throw propagates as-is per spec
// (not wrapped to TypeError; the iterator protocol says any throw from
// the iterator should surface to the caller).
function expectThrowAny(name, fn) {
    try {
        fn();
        print("FAIL " + name + ": no throw");
    } catch (e) {
        print("PASS " + name + ": " + e.constructor.name + " thrown");
    }
}
var bad = { [Symbol.iterator]: function () { return { next: function () { throw new Error("stop"); } }; } };
expectThrowAny("Map(bad iter)", function () { new Map(bad); });
expectThrowAny("Set(bad iter)", function () { new Set(bad); });
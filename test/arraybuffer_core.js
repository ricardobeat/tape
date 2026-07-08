// Oracle for plan 049 stage 1 — ArrayBuffer core.
var failures = 0;
function check(cond, msg) {
    if (!cond) {
        failures++;
        print("FAIL: " + msg);
    }
}

// Basic construction + zero fill
var ab = new ArrayBuffer(16);
check(ab.byteLength === 16, "byteLength should be 16");
check(ab.detached === false, "should not be detached initially");

var view = new Uint8Array === undefined ? null : null; // Int8Array stub, skip element checks

// slice()
var s = ab.slice(0, 8);
check(s.byteLength === 8, "slice(0,8).byteLength should be 8");
check(s !== ab, "slice should return a new ArrayBuffer");

// slice with negative indices
var s2 = ab.slice(-4);
check(s2.byteLength === 4, "slice(-4).byteLength should be 4");

var s3 = ab.slice(-8, -2);
check(s3.byteLength === 6, "slice(-8,-2).byteLength should be 6");

// isView
check(ArrayBuffer.isView(ab) === false, "ArrayBuffer.isView(ab) should be false");
try {
    var ta = new Int8Array();
    // Int8Array is currently a stub facade; isView may or may not recognize it.
    // Not asserted strictly per instructions — just don't crash.
    ArrayBuffer.isView(ta);
} catch (e) {
    // ignore
}

// detach
check(typeof __detachArrayBuffer === "function", "__detachArrayBuffer should be defined");
__detachArrayBuffer(ab);
check(ab.byteLength === 0, "byteLength should be 0 after detach");
check(ab.detached === true, "detached should be true after detach");

// RangeError on negative length
try {
    new ArrayBuffer(-1);
    failures++;
    print("FAIL: new ArrayBuffer(-1) should throw");
} catch (e) {
    check(e instanceof RangeError, "new ArrayBuffer(-1) should throw RangeError, got " + e);
}

// TypeError when called without new
try {
    ArrayBuffer(16);
    failures++;
    print("FAIL: ArrayBuffer(16) without new should throw");
} catch (e) {
    check(e instanceof TypeError, "ArrayBuffer(16) without new should throw TypeError, got " + e);
}

// GC stress: allocate many buffers and let them go
for (var i = 0; i < 2000; i++) {
    var tmp = new ArrayBuffer(64);
}

if (failures === 0) {
    print("PASS");
} else {
    print("FAILURES: " + failures);
}

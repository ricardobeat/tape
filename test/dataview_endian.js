// DataView oracle test (plan 049 stage 3).
var failures = [];
function check(cond, msg) {
    if (!cond) failures.push(msg);
}

// Basic construction
var buf16 = new ArrayBuffer(16);
var dv0 = new DataView(buf16);
check(dv0.byteLength === 16, "dv0.byteLength");
check(dv0.byteOffset === 0, "dv0.byteOffset");
check(dv0.buffer instanceof ArrayBuffer, "dv0.buffer instanceof ArrayBuffer");
check(dv0.buffer === buf16, "dv0.buffer === buf16");

var dv1 = new DataView(buf16, 4, 8);
check(dv1.byteOffset === 4, "dv1.byteOffset");
check(dv1.byteLength === 8, "dv1.byteLength");

// Round-trip all 8 setter/getter pairs, LE and BE.
function roundtrip(name, setName, getName, value, size) {
    var b = new ArrayBuffer(size);
    var dv = new DataView(b);
    dv[setName](0, value, true);
    var got = dv[getName](0, true);
    check(got === value, name + " LE roundtrip: " + got + " !== " + value);
    dv[setName](0, value, false);
    got = dv[getName](0, false);
    check(got === value, name + " BE roundtrip: " + got + " !== " + value);
}

roundtrip("Int8", "setInt8", "getInt8", -100, 1);
roundtrip("Uint8", "setUint8", "getUint8", 200, 1);
roundtrip("Int16", "setInt16", "getInt16", -30000, 2);
roundtrip("Uint16", "setUint16", "getUint16", 60000, 2);
roundtrip("Int32", "setInt32", "getInt32", -2000000000, 4);
roundtrip("Uint32", "setUint32", "getUint32", 4000000000, 4);
roundtrip("Float64", "setFloat64", "getFloat64", Math.PI, 8);

// Float32 roundtrip: use an exactly-representable value (1.5).
{
    var b = new ArrayBuffer(4);
    var dv = new DataView(b);
    dv.setFloat32(0, 1.5, true);
    check(dv.getFloat32(0, true) === 1.5, "Float32 LE roundtrip");
    dv.setFloat32(0, 1.5, false);
    check(dv.getFloat32(0, false) === 1.5, "Float32 BE roundtrip");
}

// Explicit byte layout check via Uint8Array on same buffer.
{
    var b = new ArrayBuffer(4);
    var dv = new DataView(b);
    var u8 = new Uint8Array(b);
    dv.setUint32(0, 0x11223344, false);
    check(u8[0] === 0x11 && u8[1] === 0x22 && u8[2] === 0x33 && u8[3] === 0x44,
        "BE byte layout: " + u8[0] + "," + u8[1] + "," + u8[2] + "," + u8[3]);
    dv.setUint32(0, 0x11223344, true);
    check(u8[0] === 0x44 && u8[1] === 0x33 && u8[2] === 0x22 && u8[3] === 0x11,
        "LE byte layout: " + u8[0] + "," + u8[1] + "," + u8[2] + "," + u8[3]);
}

// setFloat32/getFloat32 default (no littleEndian arg) is big-endian and
// self-consistent.
{
    var b = new ArrayBuffer(4);
    var dv = new DataView(b);
    dv.setFloat32(0, 1.5);
    check(dv.getFloat32(0) === 1.5, "Float32 default (BE) roundtrip");
}

// Signed overflow.
{
    var b = new ArrayBuffer(1);
    var dv = new DataView(b);
    dv.setInt8(0, 200);
    check(dv.getInt8(0) === -56, "setInt8(200) -> getInt8 === -56, got " + dv.getInt8(0));
}

// Float64 exact roundtrip.
{
    var b = new ArrayBuffer(8);
    var dv = new DataView(b);
    dv.setFloat64(0, Math.PI);
    check(dv.getFloat64(0) === Math.PI, "Float64 exact roundtrip");
}

// OOB throws RangeError.
{
    var b = new ArrayBuffer(16);
    var dv = new DataView(b);
    var threw = false;
    try { dv.getInt32(13); } catch (e) {
        threw = e instanceof RangeError;
    }
    check(threw, "OOB getInt32(13) should throw RangeError");
}

// Wrong receiver throws TypeError.
{
    var threw = false;
    try { DataView.prototype.getInt8.call({}); } catch (e) {
        threw = e instanceof TypeError;
    }
    check(threw, "wrong receiver should throw TypeError");
}

// Detached buffer throws TypeError on getter.
{
    var b = new ArrayBuffer(8);
    var dv = new DataView(b);
    __detachArrayBuffer(b);
    var threw = false;
    try { dv.getInt8(0); } catch (e) {
        threw = e instanceof TypeError;
    }
    check(threw, "detached buffer getInt8 should throw TypeError");
}

// @@toStringTag
{
    var tag = Object.prototype.toString.call(new DataView(new ArrayBuffer(4)));
    check(tag === "[object DataView]", "toStringTag: " + tag);
}

if (failures.length === 0) {
    print("PASS");
} else {
    for (var i = 0; i < failures.length; i++) print("FAIL: " + failures[i]);
}

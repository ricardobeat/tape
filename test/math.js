// Math methods test
function assert_sameValue(a, b, msg) { if (a !== b) throw new Error("FAIL: " + msg + " — got " + a + ", expected " + b); }
function assert_isNaN(v, msg) { if (typeof v !== 'number' || !isNaN(v)) throw new Error("FAIL: " + msg + " — got " + v); }
assert_sameValue(Math.abs(-5), 5, 'Math.abs(-5) === 5');
assert_sameValue(Math.abs(0), 0, 'Math.abs(0) === 0');
assert_isNaN(Math.abs(NaN), 'Math.abs(NaN) is NaN');

assert_sameValue(Math.floor(3.9), 3, 'Math.floor(3.9) === 3');
assert_sameValue(Math.floor(-3.1), -4, 'Math.floor(-3.1) === -4');

assert_sameValue(Math.ceil(3.1), 4, 'Math.ceil(3.1) === 4');
assert_sameValue(Math.ceil(-3.9), -3, 'Math.ceil(-3.9) === -3');

assert_sameValue(Math.round(3.4), 3, 'Math.round(3.4) === 3');
assert_sameValue(Math.round(3.5), 4, 'Math.round(3.5) === 4');
assert_sameValue(Math.round(-3.5), -3, 'Math.round(-3.5) === -3');
assert_sameValue(Math.round(-3.6), -4, 'Math.round(-3.6) === -4');

assert_sameValue(Math.max(1, 2, 3), 3, 'Math.max(1,2,3) === 3');
assert_sameValue(Math.max(-1, -5), -1, 'Math.max(-1,-5) === -1');
assert_sameValue(Math.min(1, 2, 3), 1, 'Math.min(1,2,3) === 1');
assert_sameValue(Math.min(-1, -5), -5, 'Math.min(-1,-5) === -5');

assert_sameValue(Math.pow(2, 3), 8, 'Math.pow(2,3) === 8');
assert_sameValue(Math.pow(2, -1), 0.5, 'Math.pow(2,-1) === 0.5');
assert_sameValue(Math.sqrt(9), 3, 'Math.sqrt(9) === 3');

assert_sameValue(Math.exp(0), 1, 'Math.exp(0) === 1');
assert_sameValue(Math.log(1), 0, 'Math.log(1) === 0');

assert_sameValue(Math.sin(0), 0, 'Math.sin(0) === 0');
assert_sameValue(Math.cos(0), 1, 'Math.cos(0) === 1');
assert_sameValue(Math.tan(0), 0, 'Math.tan(0) === 0');

// Math.random() returns [0, 1)
var r = Math.random();
assert_sameValue(r >= 0 && r < 1, true, 'Math.random() in [0,1)');

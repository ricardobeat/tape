// B24 deep minimal repro

function check(name, actual, expected) {
    var s = JSON.stringify(actual);
    var e = JSON.stringify(expected);
    print(name + ": " + (s === e ? "PASS" : "FAIL (got " + s + " expected " + e + ")"));
}

// Basic += to 2D element
var a = [[0]];
a[0][0] += 5;
check("1d into 2d", a[0][0], 5);

// Compare: regular 2d assign
var b = [[0]];
b[0][0] = b[0][0] + 5;
check("explicit 2d assign", b[0][0], 5);

// Compare: += to 1d
var c = [0];
c[0] += 5;
check("+= to 1d", c[0], 5);

// 2D read-then-write
var d = [[10]];
d[0][0] = d[0][0] + 5;
check("explicit 2d read+write", d[0][0], 15);

// 2D with previous value via property
var e = [[10]];
e[0][0] += 5;
check("+= to 2d from 10", e[0][0], 15);

// Inside loop
var f = [[0, 0]];
for (var i = 0; i < 2; i++) {
    f[0][i] += 1;
}
check("loop += to 2d row", f[0], [1, 1]);

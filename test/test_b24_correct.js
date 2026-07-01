// B24 - compound-assign into nested array element
// Note: avoid JSON.stringify in the test (has a separate bug with dense arrays)

function arr_eq(actual, expected) {
    if (actual.length !== expected.length) return false;
    for (var i = 0; i < actual.length; i++) {
        if (Array.isArray(expected[i])) {
            if (!arr_eq(actual[i], expected[i])) return false;
        } else if (actual[i] !== expected[i]) {
            return false;
        }
    }
    return true;
}

function check(name, actual, expected) {
    if (arr_eq(actual, expected)) {
        print("PASS", name);
    } else {
        print("FAIL", name, "got", actual, "expected", expected);
    }
}

// 1. simple += to 1D
var c = [0];
c[0] += 5;
check("1D += scalar", c, [5]);

// 2. += to 2D
var d = [[0, 0], [0, 0]];
for (var i = 0; i < 2; i++) {
    for (var j = 0; j < 2; j++) {
        d[i][j] += 1;
    }
}
check("2D += double loop", d, [[1, 1], [1, 1]]);

// 3. += in triple loop
var e = [];
for (var i = 0; i < 2; i++) {
    e[i] = [0, 0];
    for (var j = 0; j < 2; j++) {
        for (var k = 0; k < 2; k++) {
            e[i][j] += 1;
        }
    }
}
check("triple loop", e, [[2, 2], [2, 2]]);

// 4. matrix multiply
var a = [[1, 2], [3, 4]];
var b = [[5, 6], [7, 8]];
var out = [[0, 0], [0, 0]];
for (var i = 0; i < 2; i++) {
    for (var j = 0; j < 2; j++) {
        for (var x = 0; x < 2; x++) {
            out[i][j] += a[i][x] * b[x][j];
        }
    }
}
check("matmul", out, [[19, 22], [43, 50]]);

// 5. compound with non-ADD ops
var f = [[10, 20]];
f[0][0] -= 3;
f[0][1] *= 2;
f[0][0] /= 2;
check("compound mix", f, [[3.5, 40]]);

// 6. += to global (env-resolved) member
var g = [100];
g[0] += 1;
check("global += 1D", g, [101]);

// 7. += to nested object member (not array)
var h = {a: {b: 5}};
h.a.b += 10;
check("nested object", h, {a: {b: 15}});

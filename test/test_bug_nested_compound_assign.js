// Repro for a rosetta/matrix_ops.js failure: compound-assign into a
// 2D array element inside a triple-nested for loop returns all zeros
// instead of the accumulated matrix product.
function assert(cond, msg) { if (!cond) throw new Error("FAIL: " + msg); }

function matmul(a, b) {
    var n = a.length, m = b[0].length, k = b.length;
    var out = [];
    for (var i = 0; i < n; i++) {
        out[i] = [];
        for (var j = 0; j < m; j++) {
            out[i][j] = 0;
        }
    }
    for (var i = 0; i < n; i++) {
        for (var j = 0; j < m; j++) {
            for (var x = 0; x < k; x++) {
                out[i][j] += a[i][x] * b[x][j];
            }
        }
    }
    return out;
}

var a = [[1, 2], [3, 4]];
var b = [[5, 6], [7, 8]];
var result = matmul(a, b);

// Expected: [[19, 22], [43, 50]]
assert(result[0][0] === 19, "result[0][0] expected 19, got " + result[0][0]);
assert(result[0][1] === 22, "result[0][1] expected 22, got " + result[0][1]);
assert(result[1][0] === 43, "result[1][0] expected 43, got " + result[1][0]);
assert(result[1][1] === 50, "result[1][1] expected 50, got " + result[1][1]);

print("PASS");

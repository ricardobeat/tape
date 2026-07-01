// Minimal repro: compound-assign to nested array element
// Hypothesis: stale value from previous iteration

// Case 1: simplest case - works?
var out = [[0]];
out[0][0] += 5;
print("Case 1 (single +=):", out[0][0], "expected 5");

// Case 2: in a loop
var out2 = [[0, 0], [0, 0]];
for (var i = 0; i < 2; i++) {
    for (var j = 0; j < 2; j++) {
        out2[i][j] += 1;
    }
}
print("Case 2 (double loop):", JSON.stringify(out2), "expected [[1,1],[1,1]]");

// Case 3: in a triple loop
var out3 = [];
for (var i = 0; i < 2; i++) {
    out3[i] = [0, 0];
    for (var j = 0; j < 2; j++) {
        for (var k = 0; k < 2; k++) {
            out3[i][j] += 1;
        }
    }
}
print("Case 3 (triple loop):", JSON.stringify(out3), "expected [[2,2],[2,2]]");

// Case 4: matrix multiply pattern
var a = [[1, 2], [3, 4]];
var b = [[5, 6], [7, 8]];
var out4 = [[0, 0], [0, 0]];
for (var i = 0; i < 2; i++) {
    for (var j = 0; j < 2; j++) {
        for (var x = 0; x < 2; x++) {
            out4[i][j] += a[i][x] * b[x][j];
        }
    }
}
print("Case 4 (matmul):", JSON.stringify(out4), "expected [[19,22],[43,50]]");

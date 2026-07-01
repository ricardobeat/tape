// Investigate case 3
var out = [];
for (var i = 0; i < 2; i++) {
    out[i] = [0, 0];
    print("after out[i]=[0,0]:", JSON.stringify(out));
    for (var j = 0; j < 2; j++) {
        for (var k = 0; k < 2; k++) {
            out[i][j] += 1;
        }
    }
    print("after += loop:", JSON.stringify(out));
}
print("final:", JSON.stringify(out));

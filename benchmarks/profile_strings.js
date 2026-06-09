// Test A: Just string concatenation (no property writes)
var N = 10000;
for (var i = 0; i < N; i++) {
    var x = "key_" + i;
}

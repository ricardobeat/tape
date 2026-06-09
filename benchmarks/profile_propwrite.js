// Test B: Property writes with pre-created keys
var N = 10000;
var keys = [];
for (var i = 0; i < N; i++) {
    keys[i] = "key_" + i;
}
var map = {};
for (var i = 0; i < N; i++) {
    map[keys[i]] = i;
}

// Minimal test: measure memory impact of N unique properties on one object
var map = {};
var N = 10000;
print("Adding " + N + " unique properties...");
for (var i = 0; i < N; i++) {
    map["key_" + i] = i;
}
print("Done. Access check: map.key_0=" + map["key_0"] + " map.key_" + (N-1) + "=" + map["key_" + (N-1)]);

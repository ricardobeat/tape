// Profile shape operations: isolate string creation vs property insertion
// Test 1: Just string creation (no property writes)
var N = 10000;
var keys = [];
for (var i = 0; i < N; i++) {
    keys[i] = "key_" + i;
}

// Test 2: Property writes with pre-created keys
var map = {};
for (var i = 0; i < N; i++) {
    map[keys[i]] = i;
}

// Test 3: Combined (original benchmark)
var map2 = {};
for (var i = 0; i < N; i++) {
    map2["key_" + i] = i;
}

// Memory test: 10k unique properties on one object (no function calls)
var map = {};
for (var i = 0; i < 10000; i++) {
    map["key_" + i] = i;
}
// Force materialization
var sum = 0;
sum += map["key_0"];
sum += map["key_9999"];

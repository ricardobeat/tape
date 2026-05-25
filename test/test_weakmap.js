var wm = new WeakMap();
print("WeakMap created:", typeof wm);

var key1 = {};
var key2 = {};
var key3 = {};

wm.set(key1, "value1");
wm.set(key2, 42);
wm.set(key3, true);

print("has key1:", wm.has(key1));
print("get key1:", wm.get(key1));
print("has key2:", wm.has(key2));
print("get key2:", wm.get(key2));
print("has key3:", wm.has(key3));
print("get key3:", wm.get(key3));

wm.set(key1, "new-value1");
print("overwritten get key1:", wm.get(key1));

print("delete key1:", wm["delete"](key1));
print("has key1 after delete:", wm.has(key1));
print("get key1 after delete:", wm.get(key1));
print("delete missing:", wm["delete"]({}));

var wm2 = new WeakMap([[key1, "a"], [key2, "b"]]);
print("wm2 get key1:", wm2.get(key1));
print("wm2 get key2:", wm2.get(key2));

print("wm.size:", wm.size);
var clearVal = wm.clear;
print("typeof wm.clear:", typeof clearVal);

print("ALL WEAKMAP TESTS PASSED");

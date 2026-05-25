// Test Map and Set built-ins

print("=== Map tests ===");

var m = new Map();
print("Empty map size:", m.size);

m.set("a", 1);
print("After set('a', 1):", m.size);
print("get('a'):", m.get("a"));
print("has('a'):", m.has("a"));
print("has('b'):", m.has("b"));

m.set("b", 2);
print("After set('b', 2):", m.size);
print("get('b'):", m.get("b"));

m.set("a", 10);
print("After overwrite set('a', 10):", m.get("a"));

print("delete('a'):", m.delete("a"));
print("has('a') after delete:", m.has("a"));
print("size after delete:", m.size);

print("delete('x'):", m.delete("x"));

// Test iteration
var keys = m.keys();
print("keys count:", keys.length);
var vals = m.values();
print("vals count:", vals.length);
var entries = m.entries();
print("entries count:", entries.length);

m.clear();
print("After clear:", m.size);

// Test constructor with iterable
var m2 = new Map([["x", 1], ["y", 2]]);
print("m2 size:", m2.size);
print("m2 get('x'):", m2.get("x"));
print("m2 get('y'):", m2.get("y"));

print("=== Set tests ===");

var s = new Set();
print("Empty set size:", s.size);

s.add(1);
print("After add(1):", s.size);
print("has(1):", s.has(1));
print("has(2):", s.has(2));

s.add(2);
s.add(1);  // Duplicate
print("After add(2), add(1) dup:", s.size);

print("delete(1):", s.delete(1));
print("has(1):", s.has(1));

// NaN handling
s.add(NaN);
print("has(NaN) after add(NaN):", s.has(NaN));

var s2 = new Set([1, 2, 3]);
print("s2 from array size:", s2.size);

s.clear();
print("After clear:", s.size);

print("=== All tests complete ===");

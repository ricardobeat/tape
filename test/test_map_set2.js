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

var deleted = m["delete"]("a");
print("delete('a'):", deleted);
print("has('a') after delete:", m.has("a"));
print("size after delete:", m.size);

var deleted2 = m["delete"]("x");
print("delete('x'):", deleted2);

var keys = m.keys();
print("keys count:", keys.length);

m.clear();
print("After clear:", m.size);

print("=== Set tests ===");

var s = new Set();
print("Empty set size:", s.size);

s.add(1);
print("After add(1):", s.size);
print("has(1):", s.has(1));
print("has(2):", s.has(2));

s.add(2);
s.add(1);
print("After add(2), add(1) dup:", s.size);

var deleted3 = s["delete"](1);
print("delete(1):", deleted3);
print("has(1):", s.has(1));

s.clear();
print("After clear:", s.size);

print("=== All tests complete ===");

var m = new Map();
m.set("a", 1);
m.set("b", 2);
print("size:", m.size);

// Test overwrite
m.set("a", 10);
print("get a:", m.get("a"));

// Test delete
print("delete a:", m.delete("a"));
print("has a:", m.has("a"));
print("size:", m.size);

// Test clear
m.clear();
print("after clear:", m.size);

// Test iteration
m.set("x", 100);
m.set("y", 200);
var keys = m.keys();
print("keys:", keys.length, keys[0], keys[1]);

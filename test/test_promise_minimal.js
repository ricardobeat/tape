// Minimal Promise test
print("=== Test 1: Promise exists ===");
print(typeof Promise);

print("=== Test 2: Promise.resolve ===");
var p = Promise.resolve(42);
print(typeof p);
print(p instanceof Promise);

print("=== Test 3: Promise.prototype.then exists ===");
print(typeof Promise.prototype.then);

print("=== Test 4: Promise.prototype.catch exists ===");
print(typeof Promise.prototype.catch);

print("=== Test 5: Promise.length ===");
print(Promise.length);

print("=== DONE ===");

// Test: for-of with arrays
print("=== for-of arrays ===");
var arr = [10, 20, 30];
for (var x of arr) {
  print("x:", x);
}

// Test: for-of with let
print("=== for-of let ===");
for (let y of [1, 2, 3]) {
  print("y:", y);
}

// Test: for-of with const
print("=== for-of const ===");
for (const z of [100, 200]) {
  print("z:", z);
}

// Test: for-of with empty array
print("=== for-of empty ===");
var count = 0;
for (var e of []) {
  count++;
}
print("count (should be 0):", count);

// Test: for-of with bare variable
print("=== for-of bare ===");
var w;
var bare_arr = ["a", "b"];
for (w of bare_arr) {
  print("w:", w);
}

// Test: for-of with break
print("=== for-of break ===");
for (var bv of [1, 2, 3, 4, 5]) {
  if (bv === 3) break;
  print("bv:", bv);
}

// Test: for-of with continue
print("=== for-of continue ===");
for (var cv of [1, 2, 3, 4, 5]) {
  if (cv === 3) continue;
  print("cv:", cv);
}

print("done");

// Targeted smoke test for defineProperty on sealed/frozen arrays
function assert(cond, msg) {
  if (!cond) throw new Error("FAIL: " + msg);
}

// Sealed array: elements are writable, enumerable, non-configurable
// So value change should succeed
function test_defineProp_value_on_sealed() {
  var arr = [1, 2, 3];
  Object.seal(arr);
  Object.defineProperty(arr, "0", {value: 99});
  assert(arr[0] === 99, "sealed: value should be 99");
  print("PASS: test_defineProp_value_on_sealed");
}

// Frozen array: elements are non-writable, non-configurable
// So value change should throw TypeError
function test_defineProp_value_on_frozen() {
  var arr = [1, 2, 3];
  Object.freeze(arr);
  var threw = false;
  try { Object.defineProperty(arr, "0", {value: 99}); } catch(e) { threw = true; }
  assert(threw, "frozen: should throw TypeError");
  assert(arr[0] === 1, "frozen: value unchanged");
  print("PASS: test_defineProp_value_on_frozen");
}

// Sealed array: can't change writable false→true on non-configurable
function test_defineProp_writable_on_sealed() {
  var obj = {a: 1};
  Object.defineProperty(obj, "a", {writable: false, configurable: false});
  var threw = false;
  try { Object.defineProperty(obj, "a", {writable: true}); } catch(e) { threw = true; }
  assert(threw, "non-config non-writable: can't make writable");
  print("PASS: test_defineProp_writable_on_sealed");
}

// Sealed object: value change should succeed if writable
function test_defineProp_value_on_sealed_obj() {
  var obj = {a: 1};
  Object.seal(obj);
  Object.defineProperty(obj, "a", {value: 42});
  assert(obj.a === 42, "sealed obj: value should be 42");
  print("PASS: test_defineProp_value_on_sealed_obj");
}

// defineProperty on non-existent key of sealed object should throw
function test_defineProp_new_on_sealed() {
  var obj = {a: 1};
  Object.seal(obj);
  var threw = false;
  try { Object.defineProperty(obj, "b", {value: 2}); } catch(e) { threw = true; }
  assert(threw, "sealed obj: can't add new property");
  print("PASS: test_defineProp_new_on_sealed");
}

// defineProperty with same value on frozen non-configurable non-writable - should succeed (no change)
function test_defineProp_same_value_on_frozen() {
  var arr = [1];
  Object.freeze(arr);
  Object.defineProperty(arr, "0", {value: 1});
  assert(arr[0] === 1, "frozen: same value ok");
  print("PASS: test_defineProp_same_value_on_frozen");
}

// defineProperty empty descriptor on sealed - should be no-op
function test_defineProp_empty_on_sealed() {
  var arr = [1];
  Object.seal(arr);
  Object.defineProperty(arr, "0", {});
  assert(arr[0] === 1, "sealed: empty desc ok");
  print("PASS: test_defineProp_empty_on_sealed");
}

test_defineProp_value_on_sealed();
test_defineProp_value_on_frozen();
test_defineProp_writable_on_sealed();
test_defineProp_value_on_sealed_obj();
test_defineProp_new_on_sealed();
test_defineProp_same_value_on_frozen();
test_defineProp_empty_on_sealed();
print("ALL PASSED");

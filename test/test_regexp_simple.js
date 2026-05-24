var r = new RegExp("World");
print("r:", r);
var result = r.exec("Hello World!");
print("result:", result);
if (result) {
  print("result[0]:", result[0]);
  print("result.index:", result.index);
  print("result.input:", result.input);
}

// test
var t = r.test("Hello World!");
print("test result:", t);

// toString
print("toString:", r.toString());

// Simple literal test
print("/foo/.test('foo'):", /foo/.test("foo"));

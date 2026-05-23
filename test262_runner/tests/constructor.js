// `new` operator and property access
function MyClass(v) { this.x = v; }
var o = new MyClass(42);
assert_sameValue(o.x, 42, 'new + this.x = v');

function RetObj() { return { a: 1 }; }
var o2 = new RetObj();
assert_sameValue(o2.a, 1, 'new returning object');

function RetPrim() { this.b = 7; return 99; }
var o3 = new RetPrim();
assert_sameValue(o3.b, 7, 'new returning primitive uses this');

var obj = {};
obj.x = 10;
assert_sameValue(obj.x, 10, 'obj.x = 10');

var arr = [1, 2, 3];
assert_sameValue(arr.length, 3, 'arr.length === 3');
assert_sameValue(arr[0], 1, 'arr[0] === 1');
assert_sameValue(arr[arr.length - 1], 3, 'arr[last] === 3');

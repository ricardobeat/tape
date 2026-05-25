var ws = new WeakSet();
print("WeakSet created:", typeof ws);

var obj1 = {};
var obj2 = {};
var obj3 = {};

ws.add(obj1);
ws.add(obj2);
ws.add(obj3);

print("has obj1:", ws.has(obj1));
print("has obj2:", ws.has(obj2));
print("has obj3:", ws.has(obj3));
print("has missing:", ws.has({}));

print("delete obj1:", ws["delete"](obj1));
print("has obj1 after delete:", ws.has(obj1));
print("delete missing:", ws["delete"]({}));

var ws2 = new WeakSet([obj1, obj2]);
print("ws2 has obj1:", ws2.has(obj1));
print("ws2 has obj2:", ws2.has(obj2));

print("ws.size:", ws.size);
var clearVal = ws.clear;
print("typeof ws.clear:", typeof clearVal);

print("ALL WEAKSET TESTS PASSED");

var p = Promise.resolve(42);
var tag = Object.prototype.toString.call(p);
print(tag);
print("done");

// Simple getter test
var obj = {
  _x: 10,
  get x() { return this._x; }
};
print(obj.x);

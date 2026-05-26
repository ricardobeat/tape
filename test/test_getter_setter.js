class A {
  constructor() { this._v = 1; }
  get x() { return this._v; }
}
var a = new A();
print(a.x);

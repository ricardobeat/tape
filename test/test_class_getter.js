// Test class getter
class Counter {
  constructor() {
    this._n = 0;
  }
  get count() {
    return this._n;
  }
  set count(v) {
    this._n = v;
  }
}

var c = new Counter();
print(c.count);
c.count = 7;
print(c.count);

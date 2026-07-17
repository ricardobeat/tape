// P2: PrivateFieldAdd bypasses [[Extensible]] — a derived class whose base
// constructor returns a non-extensible plain object still gets its private
// fields installed on that object (private fields are not regular
// [[DefineOwnProperty]] calls).
class Base {
    constructor() {
        return Object.preventExtensions({});
    }
}

var captured;
class Derived extends Base {
    #x = 5;
    constructor() {
        super();
        captured = this;
    }
    static getX(o) { return o.#x; }
}

var d = new Derived();
if (d !== captured) throw new Error("sanity check failed");
if (Object.isExtensible(d)) throw new Error("expected the returned object to remain non-extensible");
if (Derived.getX(d) !== 5) throw new Error("expected private field to be installed regardless of extensibility");

print("PASS");

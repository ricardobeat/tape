// ES6 computed property keys in class methods
// Per ES6 §14.5, the key expression in `class { [expr]() {} }` is evaluated
// once at class-definition time. The method is installed on the prototype
// using the returned value as the key. The expression must NOT re-run on
// each instance, and the resulting method must be on the prototype (not
// per-instance).

var pass = 0;
var fail = 0;

function assert(cond, msg) {
    if (cond) { pass++; } else { fail++; print("FAIL: " + msg); }
}

// --- 1. String computed key ---
class A {
    ["foo"]() { return "from foo"; }
    ["bar baz"]() { return "from bar"; }
}
var a = new A();
assert(a.foo() === "from foo", "string literal computed key");
assert(a["bar baz"]() === "from bar", "string with space computed key");
assert(A.prototype.foo === a.foo, "computed method on prototype (string)");
assert(Object.getPrototypeOf(a).foo === A.prototype.foo, "shared on prototype");

// --- 2. Numeric computed key ---
class B {
    [42]() { return "the answer"; }
    [0]() { return "zero"; }
}
var b = new B();
assert(b[42]() === "the answer", "numeric computed key 42");
assert(b[0]() === "zero", "numeric computed key 0");
assert(B.prototype[42] === b[42], "numeric method on prototype");

// --- 3. Expression with side effect — key fn called exactly once per method ---
// Track via pushing into a global array (not a captured local — captured
// locals interact badly with the unrelated `++` peephole optimization).
var sideEffectLog = [];
function makeKey(label) {
    sideEffectLog.push(label);
    return "method_" + label;
}
class C {
    [makeKey("alpha")]() { return 1; }
    [makeKey("beta")]() { return 2; }
}
assert(sideEffectLog.length === 2, "key fn called once per method at class init (got " + sideEffectLog.length + " calls)");
assert(sideEffectLog[0] === "alpha" && sideEffectLog[1] === "beta",
       "key fn called with the expected arg values in order");
var c1 = new C();
assert(sideEffectLog.length === 2, "key fn NOT called on instance creation (still " + sideEffectLog.length + " calls)");
c1.method_alpha();
c1.method_beta();
assert(sideEffectLog.length === 2, "key fn NOT called on method invocation (still " + sideEffectLog.length + " calls)");
assert(c1.method_alpha() === 1, "method with computed key works on instance 1");
var c2 = new C();
assert(c2.method_beta() === 2, "method with computed key works on instance 2");
assert(C.prototype["method_alpha"] === c1.method_alpha, "computed method shared via prototype");

// --- 4. Computed key on static method ---
var staticKey = "create";
class D {
    static [staticKey](x) { return x * 2; }
    static ["another"]() { return "ok"; }
}
assert(D.create(21) === 42, "static method with computed key from variable");
assert(D.another() === "ok", "static method with computed string literal");
assert(D.create === D["create"], "static computed method accessible by key");

// --- 5. Computed getter ---
var getKey = "value";
class E {
    constructor() { this._v = 100; }
    get [getKey]() { return this._v; }
}
var e = new E();
assert(e.value === 100, "computed getter returns backing field");
assert(typeof Object.getOwnPropertyDescriptor(E.prototype, "value").get === "function",
       "computed getter installed on prototype as accessor");

// --- 6. Computed setter ---
var setKey = "value";
class F {
    constructor() { this._v = 0; }
    get [setKey]() { return this._v; }
    set [setKey](v) { this._v = v * 10; }
}
var f = new F();
f.value = 5;
assert(f._v === 50, "computed setter ran with side effect");
assert(f.value === 50, "computed getter reflects setter side effect");
assert(typeof Object.getOwnPropertyDescriptor(F.prototype, "value").set === "function",
       "computed setter installed on prototype as accessor");

// --- 7. Class expression with computed key ---
var Greeter = class {
    constructor(n) { this.n = n; }
    ["greet"]() { return "Hi " + this.n; }
    [1 + 2]() { return "three"; }
};
var g = new Greeter("Z");
assert(g.greet() === "Hi Z", "class expression with computed string key");
assert(g[3]() === "three", "class expression with computed arithmetic key");

print("Computed class keys: " + pass + " pass, " + fail + " fail");

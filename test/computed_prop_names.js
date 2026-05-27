// Computed property names — ES6

var pass = 0;
var fail = 0;

function assert(cond, msg) {
    if (cond) { pass++; } else { fail++; print("FAIL: " + msg); }
}

// --- Object literal computed data properties ---
var key = "b";
var obj = { a: 1, [key]: 2, ["c"]: 3 };
assert(obj.a === 1, "obj.a");
assert(obj.b === 2, "obj.b (computed via variable)");
assert(obj.c === 3, "obj.c (computed via string literal)");

// Numeric computed key
var obj2 = { [0]: "zero", [1]: "one" };
assert(obj2[0] === "zero", "obj2[0]");
assert(obj2[1] === "one", "obj2[1]");

// Expression as computed key
var obj3 = { ["x" + "y"]: 42 };
assert(obj3.xy === 42, "obj3.xy (string concat)");

// --- Computed method shorthand ---
var key2 = "m";
var obj4 = { [key2]() { return 99; } };
assert(obj4.m() === 99, "computed method shorthand");

// --- Computed getter/setter in object literal ---
var gkey = "prop";
var obj5 = {
    _val: 10,
    get [gkey]() { return this._val; },
    set [gkey](v) { this._val = v; }
};
assert(obj5.prop === 10, "computed getter");
obj5.prop = 20;
assert(obj5.prop === 20, "computed setter");
assert(obj5._val === 20, "computed setter side effect");

// --- Class with computed method ---
var mk = "hello";
class MyClass {
    [mk]() { return "world"; }
    [42]() { return "the answer"; }
}
var inst = new MyClass();
assert(inst.hello() === "world", "class computed method (string)");
assert(inst[42]() === "the answer", "class computed method (number)");

// --- Class with computed getter/setter ---
var gk = "val";
class MyClass2 {
    constructor() { this._x = 0; }
    get [gk]() { return this._x; }
    set [gk](v) { this._x = v; }
}
var inst2 = new MyClass2();
assert(inst2.val === 0, "class computed getter");
inst2.val = 7;
assert(inst2.val === 7, "class computed setter");

// --- Static computed method ---
var sk = "staticMethod";
class MyClass3 {
    static [sk]() { return 123; }
}
assert(MyClass3.staticMethod() === 123, "static computed method");

// --- Side effect in key expression ---
var callCount = 0;
function getKey() { callCount++; return "dynamic"; }
var obj6 = { [getKey()]: "works" };
assert(obj6.dynamic === "works", "side effect key expression");
assert(callCount === 1, "key expression evaluated once");

print("Computed property names: " + pass + " pass, " + fail + " fail");

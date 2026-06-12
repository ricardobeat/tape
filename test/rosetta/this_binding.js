// Rosetta Code: This binding
// https://rosettacode.org/wiki/This
// Tests 'this' in methods, constructors, call/apply, and loose mode.

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

// Method this
var obj = {
    value: 10,
    getValue: function() { return this.value; }
};
assert(obj.getValue() === 10, "method this");

// Constructor this
function Point(x, y) {
    this.x = x;
    this.y = y;
}
Point.prototype.toString = function() {
    return "(" + this.x + "," + this.y + ")";
};
var p = new Point(3, 4);
assert(p.x === 3 && p.y === 4, "constructor this");
assert(p.toString() === "(3,4)", "prototype method this");

// call with explicit this
function getX() { return this.x; }
assert(getX.call(p) === 3, "call binds this");

// apply with args
function add(a, b) { return this.base + a + b; }
var ctx = { base: 100 };
assert(add.apply(ctx, [10, 20]) === 130, "apply binds this + args");
assert(add.call(ctx, 10, 20) === 130, "call binds this + args");

// Stored method reference (this lost in sloppy mode)
var obj2 = { val: 42, getVal: function() { return this.val; } };
var fn = obj2.getVal;
// In non-strict mode, this === global object, this.val is undefined
var result = fn();
assert(result === undefined || result === null, "detached method: this is global/undefined");

// Nested function: this doesn't propagate
var outer = {
    val: 7,
    method: function() {
        var self = this;
        function inner() {
            return self.val; // closure captures self, not this
        }
        return inner();
    }
};
assert(outer.method() === 7, "self-closure pattern");

// call with null/undefined (sloppy mode: this becomes global)
function getGlobalThis() { return typeof this; }
assert(getGlobalThis.call(null) === "object" || getGlobalThis.call(undefined) === "object",
       "call(null) gives global in sloppy");

// Constructor without new (sloppy mode: this is global, returns object with fields)
function Color(r, g, b) {
    this.r = r; this.g = g; this.b = b;
}
var c = new Color(255, 128, 0);
assert(c.r === 255 && c.g === 128 && c.b === 0, "constructor assigns");

print("rosetta/this_binding: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");

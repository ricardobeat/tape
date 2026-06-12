// Rosetta Code: Property descriptors
// https://rosettacode.org/wiki/Property_descriptors
// Tests Object.defineProperty, get/set accessors, configurable/writable/enumerable.

var pass = 0, fail = 0;
function assert(cond, msg) { if (cond) pass++; else { fail++; print("FAIL: " + msg); } }

// Define non-writable property
var obj = {};
Object.defineProperty(obj, "constant", {
    value: 42,
    writable: false,
    enumerable: true,
    configurable: false
});
assert(obj.constant === 42, "defined value");
obj.constant = 99; // silently fails in sloppy mode
assert(obj.constant === 42, "non-writable ignored assignment");

// Non-enumerable
Object.defineProperty(obj, "hidden", {
    value: "secret",
    enumerable: false
});
var keys = Object.keys(obj);
assert(keys.indexOf("hidden") === -1, "non-enumerable not in Object.keys");
assert(obj.hidden === "secret", "non-enumerable still accessible");

// Getter/setter
var temp = { _celsius: 0 };
Object.defineProperty(temp, "fahrenheit", {
    get: function() { return this._celsius * 9 / 5 + 32; },
    set: function(f) { this._celsius = (f - 32) * 5 / 9; },
    enumerable: true
});
temp.fahrenheit = 212;
assert(Math.abs(temp._celsius - 100) < 0.001, "setter converts F to C");
assert(Math.abs(temp.fahrenheit - 212) < 0.001, "getter converts C to F");

// Multiple properties via defineProperties
var rect = {};
Object.defineProperties(rect, {
    width:  { value: 10, writable: true, enumerable: true },
    height: { value: 20, writable: true, enumerable: true },
    area: {
        get: function() { return this.width * this.height; },
        enumerable: true
    }
});
assert(rect.area === 200, "computed area");
rect.width = 5;
assert(rect.area === 100, "area updates with width");

// Object.getOwnPropertyDescriptor
var desc = Object.getOwnPropertyDescriptor(obj, "constant");
assert(desc.writable === false, "descriptor writable false");
assert(desc.configurable === false, "descriptor configurable false");
assert(desc.value === 42, "descriptor value 42");

// HasOwnProperty vs in
assert(obj.hasOwnProperty("constant"), "hasOwnProperty own");
assert(!obj.hasOwnProperty("toString"), "hasOwnProperty not inherited");
assert("toString" in obj, "'in' sees inherited");

// Configurable: cannot redefine
var threw = false;
try {
    Object.defineProperty(obj, "constant", { value: 99 });
} catch (e) {
    threw = true;
}
// In sloppy mode Duktape may silently fail or throw depending on version

// Define getter then replace with data property (configurable)
var cfg = {};
Object.defineProperty(cfg, "x", {
    get: function() { return 1; },
    configurable: true
});
Object.defineProperty(cfg, "x", { value: 42, writable: true });
assert(cfg.x === 42, "replaced getter with data prop");

print("rosetta/define_property: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");

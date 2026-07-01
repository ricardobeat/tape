// Regression test for B22: String.prototype.repeat with negative/infinite
// count must throw RangeError per ES6 §21.1.3.14 step 4.

function expectThrow(name, fn, expectedName) {
    try {
        var r = fn();
        print("FAIL " + name + ": no throw, got", String(r));
        return false;
    } catch (e) {
        if (e.constructor.name === expectedName) {
            print("PASS " + name + ":", e.constructor.name, "thrown");
            return true;
        }
        print("FAIL " + name + ": got " + e.constructor.name + ", expected " + expectedName);
        return false;
    }
}

expectThrow("repeat(-1)",  function () { return "a".repeat(-1);  }, "RangeError");
expectThrow("repeat(-0.5)", function () { return "a".repeat(-0.5); }, "RangeError");
expectThrow("repeat(NaN)", function () { return "a".repeat(NaN); }, "RangeError");
expectThrow("repeat(Infinity)", function () { return "a".repeat(Infinity); }, "RangeError");
expectThrow("repeat(-Infinity)", function () { return "a".repeat(-Infinity); }, "RangeError");

// Sanity: legitimate calls still work.
print("repeat(0):", JSON.stringify("a".repeat(0)));
print("repeat(3):", JSON.stringify("a".repeat(3)));
print("repeat(2):", JSON.stringify("xy".repeat(2)));
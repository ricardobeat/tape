// Minimal test: valueOf throw in addition
var obj = { valueOf: function() { throw new TypeError("valueOf"); } };
try {
    var x = obj + 1;
    print("FAIL: no throw, result=" + x);
} catch(e) {
    print("PASS: caught " + e.constructor.name + ": " + e.message);
}

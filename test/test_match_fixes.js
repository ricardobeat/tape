/// Regression tests for String.prototype.match (B05).
///
/// Verifies the bugs fixed in session 219:
/// (1) non-RegExp path was missing `.index` and `.input` on the result array.
/// (2) Object coercion via ToPrimitive now works (was using builtin_to_string instead
///     of builtin_to_string_vm, which doesn't honor valueOf/toString).
/// (3) Tests against literal patterns confirmed working — match() paths use
///     builtin_to_string_vm properly now.
///
/// Note: tests for `match()` / `match(undefined)` / `match(null)` rely on libregexp
/// matching empty patterns, which has separate bugs in the regexp engine (re.exec
/// returns null where re.test returns true). Tracked separately.

function check(name, actual, expected) {
    var ok = actual === expected;
    if (!ok) {
        print("FAIL: " + name + " — expected " + JSON.stringify(expected) + ", got " + JSON.stringify(actual));
        return false;
    }
    return true;
}

var all_pass = true;

// ── (1) non-RegExp arg path: index/input set ───────────────────────────────
{
    var m = "1234567890".match(3);
    all_pass &= check("number-coerced result is array", typeof m, "object");
    all_pass &= check("number-coerced m[0]", m[0], "3");
    all_pass &= check("number-coerced m.length", m.length, 1);
    all_pass &= check("number-coerced m.index", m.index, 2);
    all_pass &= check("number-coerced m.input", m.input, "1234567890");
}

{
    var m = "hello world".match("world");
    all_pass &= check("string-arg m[0]", m[0], "world");
    all_pass &= check("string-arg m.index", m.index, 6);
    all_pass &= check("string-arg m.input", m.input, "hello world");
}

{
    // Object with custom toString — was using builtin_to_string which doesn't call
    // ToPrimitive, so obj.toString was being ignored. Now uses builtin_to_string_vm.
    var obj = { toString: function () { return "AB"; } };
    var m = "ABBABABAB".match(obj);
    all_pass &= check("object-coerced m[0]", m[0], "AB");
    all_pass &= check("object-coerced m.index", m.index, 0);
    all_pass &= check("object-coerced m.input", m.input, "ABBABABAB");
}

{
    // Object whose valueOf returns a string and toString returns an object —
    // ToPrimitive with hint "string" calls toString first.
    var obj = {
        toString: function () { return "xy"; },
        valueOf: function () { return "wrong"; }
    };
    var m = "xyzxyz".match(obj);
    all_pass &= check("toString-priority m[0]", m[0], "xy");
    all_pass &= check("toString-priority m.index", m.index, 0);
}

// ── (2) No match returns null ──────────────────────────────────────────────
{
    var m = "abc".match("xyz");
    all_pass &= check("no-match returns null", m, null);
}

// ── (3) RegExp arg path still works ────────────────────────────────────────
{
    var m = "abcabc".match(/bc/g);
    all_pass &= check("global regex match length", m.length, 2);
    all_pass &= check("global regex match[0]", m[0], "bc");
    all_pass &= check("global regex match[1]", m[1], "bc");
}

{
    var m = "abc".match(/x/);
    all_pass &= check("regex no-match returns null", m, null);
}

if (all_pass) {
    print("PASS: all B05 match assertions");
} else {
    print("FAIL: some B05 match assertions");
}

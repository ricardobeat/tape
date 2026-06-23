// Regression test: assignment to local var slot must not allow register reuse
// to clobber the variable.
//
// Bug: in `var ok = false; if (...) { ok = true; } if (x.hasOwnProperty(...)) {...}`,
// the `ok = true` assignment's expression result was the LHS register (the
// `ok` slot). expression_statement then freed that register via free_reg,
// decrementing next_reg past the var slot. The next alloc_reg returned the
// freed var slot, and the subsequent `x.hasOwnProperty(...)` lookup wrote the
// property name into that slot, corrupting `ok`. The user-visible symptom:
// `c._ok` came back as the string "hasOwnProperty" instead of `true`.
//
// This is the minimal reduction of the tinycolor.js bug.

function testRegAlloc() {
    var ok = false;
    // Force `ok = true` to be assigned via the buggy code path.
    ok = true;
    // Touch a method lookup on a fresh object — this is what writes
    // "hasOwnProperty" into the corrupted `ok` slot in the buggy build.
    if ({}.hasOwnProperty("a")) {
        return "didnt-fix";
    }
    // The bug: if the allocator clobbered `ok`'s slot with "hasOwnProperty"
    // (the property name passed to hasOwnProperty above), the typeof check
    // below returns "string" instead of "boolean".
    if (typeof ok !== "boolean") {
        return "clobbered:" + typeof ok + ":" + String(ok);
    }
    if (ok !== true) {
        return "wrong-value:" + String(ok);
    }
    return "ok";
}

var result = testRegAlloc();
if (result !== "ok") {
    throw "REGRESSION: testRegAlloc returned " + JSON.stringify(result);
}

// Nested-call variant — also exercises the same code path through Math.min,
// Math.max, parseFloat with assignment to a parameter.
function nested(n, max) {
    n = Math.min(max, Math.max(0, parseFloat(n)));
    return n;
}
var v = nested("100%", 100);
if (typeof v !== "number" || v !== 100) {
    throw "REGRESSION: nested returned " + JSON.stringify(v) + " (" + typeof v + ")";
}

console.log("PASS: regalloc-no-clobber");

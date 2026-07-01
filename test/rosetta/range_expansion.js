// Rosetta Code: Range expansion
// https://rosettacode.org/wiki/Range_expansion
// "1,3,5-9,12" -> [1,3,5,6,7,8,9,12]
//
// KNOWN ISSUE: `compressRange` hangs (rc 124, infinite loop) on this
// engine — the nested `while (i+1 < nums.length && nums[i+1] === end + 1)`
// body that re-reads `nums[i+1]` after `i++` triggers a real engine bug.
// Calling the buggy function here would hang this whole test file rather
// than failing it, which would block the suite run. The bug itself has a
// dedicated, timeout-bounded minimal repro instead:
// test/test_bug_nested_while_index_reread.js. See test/rosetta/FAILURES.md.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

function expandRange(s) {
    var out = [];
    if (s === "") return out;
    var parts = s.split(",");
    for (var i = 0; i < parts.length; i++) {
        var p = parts[i];
        var dash = p.indexOf("-");
        if (dash === -1) {
            out.push(parseInt(p, 10));
        } else {
            var lo = parseInt(p.substring(0, dash), 10);
            var hi = parseInt(p.substring(dash + 1), 10);
            for (var n = lo; n <= hi; n++) out.push(n);
        }
    }
    return out;
}

function arrayEq(a, b) {
    if (a.length !== b.length) return false;
    for (var i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
    return true;
}

assert(arrayEq(expandRange("1,3,5-9,12"), [1, 3, 5, 6, 7, 8, 9, 12]), "1,3,5-9,12");
assert(arrayEq(expandRange("0-5"), [0, 1, 2, 3, 4, 5]), "0-5");
assert(arrayEq(expandRange("7"), [7]), "single 7");
assert(arrayEq(expandRange("3-3"), [3]), "single 3-3");
assert(arrayEq(expandRange(""), []), "empty -> empty");

print("rosetta/range_expansion: compressRange skipped — known engine hang, see test/test_bug_nested_while_index_reread.js");
print("rosetta/range_expansion: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
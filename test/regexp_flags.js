// Regression test for RegExp.prototype.flags alphabetical order
// Per ES2015 §21.2.5.7 / §22.2.3.7 the flags string is in alphabetical order.
// Bug: bit 8 (dotAll) was outputting 'd' instead of 's'.

var pass = 0, fail = 0;
function assertEq(actual, expected, msg) {
    if (actual === expected) { pass++; }
    else {
        fail++;
        print("FAIL: " + msg + " — expected " + JSON.stringify(expected) + ", got " + JSON.stringify(actual));
    }
}

// Single flags
assertEq(/a/g.flags,  "g",  "g flag");
assertEq(/a/i.flags,  "i",  "i flag");
assertEq(/a/m.flags,  "m",  "m flag");
assertEq(/a/s.flags,  "s",  "s flag (dotAll) — was outputting 'd'");
assertEq(/a/u.flags,  "u",  "u flag");
assertEq(/a/y.flags,  "y",  "y flag");

// Combinations in alphabetical order
assertEq(/a/gim.flags,   "gim",   "gim");
assertEq(/a/gims.flags,  "gims",  "gims");
assertEq(/a/gimsy.flags, "gimsy", "gimsy — was 'gdimy'");
assertEq(/a/gimuy.flags, "gimuy", "gimuy");
assertEq(/a/gimsuy.flags,"gimsuy","gimsuy — was 'gdimuy'");

// String constructor form
assertEq(new RegExp("a", "s").flags, "s", "new RegExp('a', 's').flags");
assertEq(new RegExp("a", "gimsuy").flags, "gimsuy", "new RegExp('a', 'gimsuy').flags");

print("regression/regexp_flags: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");

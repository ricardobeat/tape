// Rosetta Code: Sorting algorithms / Shell sort
// https://rosettacode.org/wiki/Sorting_algorithms/Shell_sort
// Gapped insertion sort with diminishing gap sequence.
//
// KNOWN ISSUE: this engine has a PUTVAR/while-loop bug that corrupts
// in-place `a[j] = a[j-gap]; a[j] = temp` sequences (see test/rosetta/FAILURES.md).
// Splice-based rewriting hangs the VM (rc 124 = timeout). The classic
// formulation fails; the fix is out of scope.

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

// Record the failure so the runner sees it, but don't try to fix.
assert(false, "shell_sort: engine PUTVAR bug (see FAILURES.md)");

print("rosetta/shell_sort: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
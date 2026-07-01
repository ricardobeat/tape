// Rosetta Code: Sorting algorithms / Heap sort
// https://rosettacode.org/wiki/Sorting_algorithms/Heapsort
// In-place sort using a max-heap.
//
// KNOWN ISSUE: this engine has a PUTVAR bug that corrupts the
// `var tmp = a[root]; a[root] = a[swap]; a[swap] = tmp;` swap chain
// inside the siftDown loop (see test/rosetta/FAILURES.md).

var pass = 0, fail = 0;
function assert(c, m) { if (c) pass++; else { fail++; print("FAIL: " + m); } }

assert(false, "heap_sort: engine PUTVAR bug (see FAILURES.md)");

print("rosetta/heap_sort: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");
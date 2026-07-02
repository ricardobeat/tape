// Regression test for B28: array mutation bugs in sort algorithms.
//
// Root cause was the fused-compare peephole in src/compiler/context.c3.
// The bridge-pattern fix (added for B23/B26) blindly extends fused_off by
// bridge_sbx whenever the IF_FALSE's target is itself an IF_FALSE/IF_TRUE.
// For a `while (cond1 && cond2)` loop, the IF_FALSE short-circuit for cond1
// jumps to the LDREG that precedes the IF_TRUE back edge — and that IF_TRUE
// is a backward loop edge, not an "and-continuation" bridge. Extending
// fused_off by the IF_TRUE's negative offset flipped the fused JMP_Nxx into
// a backward jump, so once the loop counter underflowed past the condition
// threshold the loop spun forever.
//
// Fix: only treat as a bridge if bridge_sbx > 0 (forward continuation).

let failures = 0;
function assertEq(actual, expected, msg) {
    if (JSON.stringify(actual) !== JSON.stringify(expected)) {
        print("FAIL: " + msg + " — expected " + JSON.stringify(expected) + ", got " + JSON.stringify(actual));
        failures++;
    }
}

// Heap sort (had a three-statement swap chain that corrupted the array).
function siftDown(a, start, end) {
    var root = start;
    while (root * 2 + 1 <= end) {
        var child = root * 2 + 1;
        var swap = root;
        if (a[swap] < a[child]) swap = child;
        if (child + 1 <= end && a[swap] < a[child + 1]) swap = child + 1;
        if (swap === root) {
            return;
        } else {
            var tmp = a[root];
            a[root] = a[swap];
            a[swap] = tmp;
            root = swap;
        }
    }
}
function heapSort(arr) {
    var a = arr.slice();
    var n = a.length;
    var start = Math.floor((n - 2) / 2);
    while (start >= 0) {
        siftDown(a, start, n - 1);
        start--;
    }
    var end = n - 1;
    while (end > 0) {
        var tmp = a[end];
        a[end] = a[0];
        a[0] = tmp;
        end--;
        siftDown(a, 0, end);
    }
    return a;
}
assertEq(heapSort([5, 3, 8, 1, 9, 2]), [1, 2, 3, 5, 8, 9], "heapSort");

// Shell sort (had a hanging `a[j] = a[j-gap]; j -= gap` inner loop).
function shellSort(arr) {
    var a = arr.slice();
    var n = a.length;
    var gap = Math.floor(n / 2);
    while (gap > 0) {
        for (var i = gap; i < n; i++) {
            var temp = a[i];
            var j = i;
            while (j >= gap && a[j - gap] > temp) {
                a[j] = a[j - gap];
                j -= gap;
            }
            a[j] = temp;
        }
        gap = Math.floor(gap / 2);
    }
    return a;
}
assertEq(shellSort([5, 3, 8, 1, 9, 2]), [1, 2, 3, 5, 8, 9], "shellSort");

// compressRange (had a hanging `while (i + 1 < nums.length && nums[i+1] === end + 1)`).
function compressRange(nums) {
    var out = [];
    var i = 0;
    while (i < nums.length) {
        var start = nums[i];
        var end = nums[i];
        while (i + 1 < nums.length && nums[i + 1] === end + 1) {
            i++;
            end = nums[i];
        }
        if (start === end) {
            out.push(String(start));
        } else {
            out.push(start + "-" + end);
        }
        i++;
    }
    return out;
}
assertEq(compressRange([1, 3, 5, 6, 7, 8, 9, 12]), ["1", "3", "5-9", "12"], "compressRange");

// Minimal repros that exercise the same fused-compare peephole.

// 1. While loop with simple condition (j >= gap) — exercises the back-edge path.
function countDown(n) {
    var total = 0;
    while (n >= 0) {
        total++;
        n--;
    }
    return total;
}
assertEq(countDown(0), 1, "countDown(0)");
assertEq(countDown(5), 6, "countDown(5)");
assertEq(countDown(-3), 0, "countDown(-3)");

// 2. While loop with `&&` short-circuit — both conds must be true to continue.
// Walks an array of `target` pairs and returns the position where the walk
// stopped (i.e. either the array ended or the next element isn't `target`).
function findPairEnd(arr, target) {
    var i = 0;
    while (i + 1 < arr.length && arr[i] === target) {
        i += 2;
    }
    return i;
}
assertEq(findPairEnd([0, 0, 0, 0, 3, 1], 0), 4, "findPairEnd (two pairs)");
assertEq(findPairEnd([0, 0, 1, 2, 3, 4], 0), 2, "findPairEnd (one pair, then mismatch)");
assertEq(findPairEnd([0, 0], 0), 2, "findPairEnd (one pair, end of array)");
assertEq(findPairEnd([1, 2, 3, 4], 0), 0, "findPairEnd (no matching pairs)");

// 3. While loop with `||` short-circuit.
function firstPositiveOrLong(arr) {
    var i = 0;
    while (i < arr.length && (arr[i] <= 0 || arr.length < 5)) {
        i++;
    }
    return i < arr.length ? arr[i] : -1;
}
assertEq(firstPositiveOrLong([-1, -2, -3, 1, 2]), 1, "firstPositiveOrLong");

// 4. Do-while with condition — exercises the loop header path too.
function untilTen(start) {
    var i = start;
    do {
        i++;
    } while (i < 10);
    return i;
}
assertEq(untilTen(0), 10, "untilTen(0)");
assertEq(untilTen(10), 11, "untilTen(10)");

if (failures > 0) {
    print("B28 regression: " + failures + " assertion(s) failed");
    throw new Error("FAIL");
}
print("B28 regression: all assertions passed");
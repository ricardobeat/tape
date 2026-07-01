// Repro for rosetta/range_expansion.js and rosetta/merge_sort.js failures:
// a nested `while (i + 1 < arr.length && arr[i + 1] === expected)` loop body
// that increments `i` and re-reads `arr[i + 1]` on the next iteration hangs
// (infinite loop) instead of terminating.
function assert(cond, msg) { if (!cond) throw new Error("FAIL: " + msg); }

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

var result = compressRange([1, 3, 5, 6, 7, 8, 9, 12]);
var expected = ["1", "3", "5-9", "12"];

assert(JSON.stringify(result) === JSON.stringify(expected),
    "expected " + JSON.stringify(expected) + ", got " + JSON.stringify(result));

print("PASS");

// Oracle for plan 044: statement-level array destructuring must use the
// iterator protocol (Symbol.iterator -> .next()), not index/.slice() access,
// so it works for any iterable (generators, custom iterables), not just Arrays.

var passed = 0, failed = 0;
function check(name, got, want) {
    var g = JSON.stringify(got), w = JSON.stringify(want);
    if (g === w) { passed++; }
    else { failed++; print("FAIL " + name + ": got " + g + " want " + w); }
}

function gen() { return (function*(){ yield 1; yield 2; yield 3; yield 4; yield 5; })(); }

// A custom (non-generator) iterable, single-use cursor.
function custom(vals) {
    var i = 0;
    return {
        [Symbol.iterator]() { return this; },
        next() {
            if (i < vals.length) return { value: vals[i++], done: false };
            return { value: undefined, done: true };
        }
    };
}

// --- flat elements from a generator ---
var [a, b] = gen();
check("flat-gen", [a, b], [1, 2]);

// --- flat from custom iterable ---
var [c, d, e] = custom([7, 8, 9]);
check("flat-custom", [c, d, e], [7, 8, 9]);

// --- rest from a generator (was: .slice throws) ---
var [h, ...t] = gen();
check("rest-gen-head", h, 1);
check("rest-gen-tail", t, [2, 3, 4, 5]);

// --- rest from custom iterable ---
var [ch, ...ct] = custom([10, 20, 30]);
check("rest-custom", [ch, ct], [10, [20, 30]]);

// --- holes must consume the cursor (advance past skipped elements) ---
var [, x, , y] = gen();
check("holes-gen", [x, y], [2, 4]);

// --- hole then rest ---
var [, ...r2] = custom([100, 200, 300]);
check("hole-then-rest", r2, [200, 300]);

// --- defaults: missing element uses default ---
var [p = 99, q = 88] = custom([5]);
check("default-gen", [p, q], [5, 88]);

// --- nested array pattern from iterables at both levels ---
var [[n1, n2], n3] = custom([custom([1, 2]), 3]);
check("nested-array", [n1, n2, n3], [1, 2, 3]);

// --- nested rest inside nested array ---
var [[m1, ...mrest]] = custom([gen()]);
check("nested-rest", [m1, mrest], [1, [2, 3, 4, 5]]);

// --- nested object inside array from iterable ---
var [{ k }, kk] = custom([{ k: "v" }, "w"]);
check("nested-object", [k, kk], ["v", "w"]);

// --- array RHS still works (fast path regression) ---
var [aa, bb, ...cc] = [1, 2, 3, 4];
check("array-rhs", [aa, bb, cc], [1, 2, [3, 4]]);

// --- assignment form (no declaration): [a, ...b] = iterable ---
var g1, g2rest;
[g1, ...g2rest] = custom([9, 8, 7]);
check("assign-rest", [g1, g2rest], [9, [8, 7]]);

print(passed + " passed, " + failed + " failed");
if (failed > 0) { throw new Error(failed + " statement-destructure failures"); }

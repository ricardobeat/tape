// Minimal repro: destructuring from a generator should use iterator protocol,
// not the Array fast-path. Currently prints undefined undefined.

function f([a, b]) {
    print(a, b);
}

// Should print 1 2
f((function*(){ yield 1; yield 2; })());

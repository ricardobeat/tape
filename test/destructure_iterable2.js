// Verify array vs iterable destructuring
// All three should print "1 2" but only the array one does.

function f([a, b]) {
    print(a, b);
}

print("--- Array ---");
f([1, 2]);

print("--- Generator ---");
f((function*(){ yield 1; yield 2; })());

print("--- Custom iterable ---");
var iterable = {};
iterable[Symbol.iterator] = function*(){ yield 1; yield 2; };
f(iterable);

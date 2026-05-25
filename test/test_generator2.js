// Test generator next() calls
function* gen() {
    yield 1;
    yield 2;
    return 3;
}

var g = gen();
print(typeof g);  // should be "object"

var r1 = g.next();
print(r1);

var r2 = g.next();
print(r2);

var r3 = g.next();
print(r3);

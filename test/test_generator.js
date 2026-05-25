// Test basic generator
function* simple() {
    yield 1;
    yield 2;
    return 3;
}

var g = simple();
print(typeof g);

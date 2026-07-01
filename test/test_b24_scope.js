// Compare: global obj vs function-scoped obj
var x = [0];
print("x[0] before:", x[0]);
x[0] = 5;
print("x[0] after assign:", x[0]);
x[0] += 10;
print("x[0] after +=:", x[0]);

print();

function test() {
    var y = [0];
    print("y[0] before:", y[0]);
    y[0] = 5;
    print("y[0] after assign:", y[0]);
    y[0] += 10;
    print("y[0] after +=:", y[0]);
}
test();

print();

// Try nested
var z = [[0]];
print("z[0][0] before:", z[0][0]);
z[0][0] = 5;
print("z[0][0] after assign:", z[0][0]);
z[0][0] += 10;
print("z[0][0] after +=:", z[0][0]);

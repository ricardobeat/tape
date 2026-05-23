print("hello");
var x = 1 + 2;
print(x);
print("result:", x * 10);
print("str concat: " + "works");
print("mixed: " + (1 + 2));
print(typeof x);
print(typeof "hello");
print(typeof true);
print(typeof null);
print(typeof undefined);

function add(a, b) {
    return a + b;
}
print(add(1, 2));
print("func result:", add(10, 20));

var x2 = 5;
function get_x() {
    return x2;
}
print("get_x:", get_x());

// Simplify: just the if/else if/else
function f(c) {
    if (c >= 65 && c <= 90) {
        return "U";
    } else if (c >= 97 && c <= 122) {
        return "L";
    } else {
        return "X";
    }
}

for (var i = 65; i < 75; i++) {
    print(i, "->", f(i));
}
print();
for (var i = 32; i < 50; i++) {
    print(i, "->", f(i));
}

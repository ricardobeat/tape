// Test the JMP_NGE behavior in isolation with c
function f(c) {
    if (c >= 65 && c <= 90) {
        return "upper";
    } else if (c >= 97 && c <= 122) {
        return "lower";
    } else {
        return "other";
    }
}

// Test with char codes
for (var i = 30; i < 130; i++) {
    var result = f(i);
    if (i < 60 || i > 100) {
        print(i, "->", result);
    }
}
print("---");
print("comma:", f(44));
print("space:", f(32));
print("excl:", f(33));
print("H:", f(72));
print("a:", f(97));

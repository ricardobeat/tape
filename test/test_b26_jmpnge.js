// Isolate the JMP_NGE bug
function f(c) {
    if (c >= 65 && c <= 90) {
        return "upper";
    } else if (c >= 97 && c <= 122) {
        return "lower";
    } else {
        return "other";
    }
}

print(f(44));  // comma, should be "other"
print(f(72));  // H, should be "upper"
print(f(32));  // space, should be "other"
print(f(33));  // !, should be "other"

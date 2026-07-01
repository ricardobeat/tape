function f(c) {
    if (c >= 65 && c <= 90) {
        return "upper";
    } else if (c >= 97 && c <= 122) {
        return "lower";
    } else {
        return "other";
    }
}

print(f(97));   // 'a', should be "lower"
print(f(44));   // ',', should be "other"

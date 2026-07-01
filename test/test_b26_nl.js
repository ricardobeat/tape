// Test if/else if/else with fromCharCode (no loop)
function f(c) {
    if (c >= 65 && c <= 90) {
        return String.fromCharCode(((c - 65 + 3) % 26) + 65);
    } else if (c >= 97 && c <= 122) {
        return String.fromCharCode(((c - 97 + 3) % 26) + 97);
    } else {
        return String.fromCharCode(c);
    }
}
print(f(44));  // should be ','
print(f(72));  // should be 'K'
print(f(32));  // should be ' '
print(f(33));  // should be '!'

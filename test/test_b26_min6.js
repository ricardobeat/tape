// Mimic the buggy test exactly but simpler
function f(c, shift) {
    if (c >= 65 && c <= 90) {
        return ((c - 65 + shift) % 26) + 65;
    } else if (c >= 97 && c <= 122) {
        return ((c - 97 + shift) % 26) + 97;
    } else {
        return c;
    }
}
print("44:", f(44, 3));   // should be 44
print("72:", f(72, 3));   // should be 75 (K)
print("97:", f(97, 3));   // should be 100 (d)

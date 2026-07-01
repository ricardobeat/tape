// Loop with fromCharCode but no charCodeAt
function f() {
    var out = "";
    for (var i = 0; i < 4; i++) {
        var c = [72, 44, 32, 33][i];
        if (c >= 65 && c <= 90) {
            out += String.fromCharCode(((c - 65 + 3) % 26) + 65);
        } else if (c >= 97 && c <= 122) {
            out += String.fromCharCode(((c - 97 + 3) % 26) + 97);
        } else {
            out += String.fromCharCode(c);
        }
    }
    return out;
}
print(f());

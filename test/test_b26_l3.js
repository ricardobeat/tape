// Loop with array indexing, no fromCharCode
function f() {
    var out = "";
    for (var i = 0; i < 4; i++) {
        var c = [72, 44, 32, 33][i];
        if (c >= 65 && c <= 90) {
            out += "U";
        } else if (c >= 97 && c <= 122) {
            out += "L";
        } else {
            out += "X";
        }
    }
    return out;
}
print(f());

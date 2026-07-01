// Loop with array indexing, no if/else
function f() {
    var out = "";
    for (var i = 0; i < 4; i++) {
        var c = [72, 44, 32, 33][i];
        out += c;
    }
    return out;
}
print(f());

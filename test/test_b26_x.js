// Test without text[i] in else
function f(text) {
    var out = "";
    for (var i = 0; i < text.length; i++) {
        var c = text.charCodeAt(i);
        if (c >= 65 && c <= 90) {
            out += String.fromCharCode(((c - 65 + 3) % 26) + 65);
        } else if (c >= 97 && c <= 122) {
            out += String.fromCharCode(((c - 97 + 3) % 26) + 97);
        } else {
            out += "X";
        }
    }
    return out;
}
print(f("Hello, World!"));

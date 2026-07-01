// Use a separate variable to hold text[i]
function f(text) {
    var out = "";
    for (var i = 0; i < text.length; i++) {
        var c = text.charCodeAt(i);
        if (c >= 65 && c <= 90) {
            out += String.fromCharCode(((c - 65 + 3) % 26) + 65);
        } else if (c >= 97 && c <= 122) {
            out += String.fromCharCode(((c - 97 + 3) % 26) + 97);
        } else {
            var ch = text[i];
            out += ch;
        }
    }
    return out;
}
print(f("Hello, World!"));

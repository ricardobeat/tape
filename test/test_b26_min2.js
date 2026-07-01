// Even more minimal: just the else branch
function f(text) {
    var out = "";
    for (var i = 0; i < text.length; i++) {
        var c = text.charCodeAt(i);
        if (c >= 65 && c <= 90) {
            out += String.fromCharCode(c);
        } else {
            out += text[i];
        }
    }
    return out;
}
print(f("Hello, World!"));
print(f("abc,def!"));

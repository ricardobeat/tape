// Minimal B26 repro without the text[i] issue
function f(text) {
    var out = "";
    for (var i = 0; i < text.length; i++) {
        var c = text.charCodeAt(i);
        if (c >= 65 && c <= 90) {
            out += String.fromCharCode(c);
        } else if (c >= 97 && c <= 122) {
            out += String.fromCharCode(c);
        } else {
            out += "X";
        }
    }
    return out;
}
print(f("Hello, World!"));
print(f("abc,def!"));
print(f("ABC123"));

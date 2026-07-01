// Loop with if/else if/else, no fromCharCode
function f(text) {
    var out = "";
    for (var i = 0; i < text.length; i++) {
        var c = text.charCodeAt(i);
        if (c >= 65 && c <= 90) {
            out += "U";
        } else if (c >= 97 && c <= 122) {
            out += "L";
        } else {
            out += text[i];
        }
    }
    return out;
}
print(f("Hello, World!"));

// Simplest test of the bug
function f(text) {
    for (var i = 0; i < text.length; i++) {
        var c = text.charCodeAt(i);
        if (c >= 65) {
            print("upper", c);
        }
    }
}
f("a");

// Repro for a rosetta/caesar.js failure: calling String.fromCharCode with a
// computed value inside a loop corrupts the next indexed read of the source
// string for non-letter characters (',' becomes 'K', ' ' becomes 'Y', etc).
function assert(cond, msg) { if (!cond) throw new Error("FAIL: " + msg); }

function shiftLetters(text, shift) {
    var out = "";
    for (var i = 0; i < text.length; i++) {
        var c = text.charCodeAt(i);
        if (c >= 65 && c <= 90) {
            out += String.fromCharCode(((c - 65 + shift) % 26) + 65);
        } else if (c >= 97 && c <= 122) {
            out += String.fromCharCode(((c - 97 + shift) % 26) + 97);
        } else {
            out += text[i];
        }
    }
    return out;
}

var input = "Hello, World!";
var result = shiftLetters(input, 3);
var expected = "Khoor, Zruog!";
assert(result === expected, "expected '" + expected + "', got '" + result + "'");

print("PASS");

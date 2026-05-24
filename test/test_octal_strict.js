// Octal literal SyntaxError tests for strict mode
"use strict";

var pass = 0;
var fail = 0;

function assert(cond, msg) {
    if (cond) { pass = pass + 1; }
    else { print("FAIL: " + msg); fail = fail + 1; }
}

function assertThrowsSyntaxError(code, label) {
    try {
        eval(code);
        print("FAIL: " + label + " should have thrown SyntaxError");
        fail = fail + 1;
    } catch (e) {
        if (e instanceof SyntaxError) {
            pass = pass + 1;
        } else {
            print("FAIL: " + label + " threw " + e.name + " instead of SyntaxError");
            fail = fail + 1;
        }
    }
}

// --- Numeric octal literals in strict mode ---
// Legacy octal integer literals (0 followed by 0-7) must throw SyntaxError
assertThrowsSyntaxError("0777", "0777 should throw SyntaxError");
assertThrowsSyntaxError("01", "01 should throw SyntaxError");
assertThrowsSyntaxError("07", "07 should throw SyntaxError");
assertThrowsSyntaxError("00", "00 should throw SyntaxError");
assertThrowsSyntaxError("012345670", "012345670 should throw SyntaxError");

// But 0.5 is fine (not octal)
assert(0.5 === 0.5, "0.5 is valid");

// 0o777 is fine (explicit octal prefix)
assert(0o777 === 511, "0o777 explicit octal is valid");

// 0 followed by 8 or 9 is not an octal literal
assert(08 === 8, "08 is decimal 8");
assert(09 === 9, "09 is decimal 9");

// --- String octal escapes in strict mode ---
// \0 followed by a digit should throw
assertThrowsSyntaxError("'\\07'", "\\07 should throw SyntaxError");
assertThrowsSyntaxError("'\\00'", "\\00 should throw SyntaxError");
assertThrowsSyntaxError("'\\01'", "\\01 should throw SyntaxError");

// \1 through \7 should throw
assertThrowsSyntaxError("'\\1'", "\\1 should throw SyntaxError");
assertThrowsSyntaxError("'\\5'", "\\5 should throw SyntaxError");
assertThrowsSyntaxError("'\\7'", "\\7 should throw SyntaxError");

// \0 alone is fine (NUL byte)
assert(eval("'\\0'") === '\0', "\\0 alone is valid (NUL byte)");
assert(eval("'\\0' + 'a'") === '\0' + 'a', "\\0 followed by non-digit is valid");

// --- Normal escape sequences still work ---
assert(eval("'\\n'") === '\n', "\\n is valid");
assert(eval("'\\t'") === '\t', "\\t is valid");
assert(eval("'\\\\'") === '\\', "\\\\ is valid");

print("PASS: " + pass + " / " + (pass + fail) + " assertions");
if (fail > 0) { print("SOME TESTS FAILED"); }

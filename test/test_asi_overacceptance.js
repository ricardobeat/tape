function syntaxError(source) {
    try {
        eval(source);
        return false;
    } catch (e) {
        return e instanceof SyntaxError;
    }
}

var pass = 0;
var fail = 0;
function assert(cond, msg) {
    if (cond) {
        pass++;
    } else {
        fail++;
        print("FAIL:", msg);
    }
}

assert(syntaxError("class A { accessor\nx = 1 }"), "line break after accessor");
assert(syntaxError("using\nx = null"), "line break after using");
assert(!syntaxError("class A { accessor; }"), "ordinary accessor field");
assert(!syntaxError("class B { accessor = 1; }"), "initialized accessor field");
print("=== Results:", pass, "pass,", fail, "fail ===");

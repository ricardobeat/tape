// Simple try/catch test
var caught = false;
try {
    throw "error";
} catch (e) {
    if (e === "error") {
        caught = true;
    }
}
if (caught) {
    print("PASS: basic try/catch works");
} else {
    print("FAIL: try/catch didn't catch");
}

// Test with TypeError from null access
var caught2 = false;
try {
    var x = null.foo;
} catch (e) {
    caught2 = true;
}
if (caught2) {
    print("PASS: TypeError on null.foo caught");
} else {
    print("FAIL: TypeError on null.foo not caught");
}

// Test with ReferenceError
var caught3 = false;
try {
    var y = undefinedVar;
} catch (e) {
    caught3 = true;
}
if (caught3) {
    print("PASS: ReferenceError caught");
} else {
    print("FAIL: ReferenceError not caught");
}

print("done");

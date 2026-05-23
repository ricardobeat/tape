// Test Array constructor — Phase 5e
var pass = 0, fail = 0;

// Array() with no args
var a1 = Array();
if (typeof a1 === "object") { pass = pass + 1; } else { print("FAIL: Array() type"); fail = fail + 1; }

// new Array() with no args
var a2 = new Array();
if (typeof a2 === "object") { pass = pass + 1; } else { print("FAIL: new Array() type"); fail = fail + 1; }

// Array(3) with one numeric arg
var a3 = Array(3);
if (a3.length === 3) { pass = pass + 1; } else { print("FAIL: Array(3).length"); fail = fail + 1; }

// new Array(3) with one numeric arg
var a4 = new Array(3);
if (a4.length === 3) { pass = pass + 1; } else { print("FAIL: new Array(3).length"); fail = fail + 1; }

// Array(1, 2, 3) with multiple args
var a5 = Array(1, 2, 3);
if (a5.length === 3 && a5[0] === 1 && a5[1] === 2 && a5[2] === 3) {
    pass = pass + 1;
} else {
    print("FAIL: Array(1,2,3)"); fail = fail + 1;
}

// new Array(1, 2, 3) with multiple args
var a6 = new Array(1, 2, 3);
if (a6.length === 3 && a6[0] === 1 && a6[1] === 2 && a6[2] === 3) {
    pass = pass + 1;
} else {
    print("FAIL: new Array(1,2,3)"); fail = fail + 1;
}

// Array("hello") with single non-numeric arg
var a7 = Array("hello");
if (a7.length === 1 && a7[0] === "hello") {
    pass = pass + 1;
} else {
    print("FAIL: Array('hello')"); fail = fail + 1;
}

// typeof Array is "function"
if (typeof Array === "function") { pass = pass + 1; } else { print("FAIL: typeof Array"); fail = fail + 1; }

// Array(0) with length 0
var a8 = Array(0);
if (a8.length === 0) { pass = pass + 1; } else { print("FAIL: Array(0).length"); fail = fail + 1; }

// Array(true) with non-numeric arg (boolean)
var a9 = Array(true);
if (a9.length === 1 && a9[0] === true) {
    pass = pass + 1;
} else {
    print("FAIL: Array(true)"); fail = fail + 1;
}

print("pass: " + pass + " fail: " + fail);

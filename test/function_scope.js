// Test: function-scoped var declarations must not bleed into outer scope
var pass = 0, fail = 0;

// Basic: inner var with same name as outer var
var x = 99;
function f1() { var x = 0; x = 42; }
f1();
if (x === 99) { pass = pass + 1; } else { print("FAIL: inner var x bleeds to outer"); fail = fail + 1; }

// Multiple reassignments inside function
var y = 10;
function f2() { var y = 5; y = y + 3; }
f2();
if (y === 10) { pass = pass + 1; } else { print("FAIL: inner var y bleeds to outer"); fail = fail + 1; }

// Multiple variables
var a = 1;
var b = 2;
function f3() { var a = 100; var b = 200; a = a + b; }
f3();
if (a === 1) { pass = pass + 1; } else { print("FAIL: inner var a bleeds to outer"); fail = fail + 1; }
if (b === 2) { pass = pass + 1; } else { print("FAIL: inner var b bleeds to outer"); fail = fail + 1; }

// Nested functions
var z = 7;
function f4() {
    var z = 14;
    function inner() { var z = 28; }
    inner();
    if (z === 14) { pass = pass + 1; } else { print("FAIL: inner var z bleeds to f4 scope"); fail = fail + 1; }
}
f4();
if (z === 7) { pass = pass + 1; } else { print("FAIL: inner var z bleeds to outer"); fail = fail + 1; }

// Loop variable in function doesn't bleed
var i = 99;
function f5() {
    var i = 0;
    while (i < 3) { i = i + 1; }
}
f5();
if (i === 99) { pass = pass + 1; } else { print("FAIL: loop var i bleeds to outer"); fail = fail + 1; }

// Outer var readable from inside (but write stays local)
var counter = 10;
function f6() {
    var counter = counter + 1;
    counter = counter + 5;
}
f6();
if (counter === 10) { pass = pass + 1; } else { print("FAIL: inner counter write bleeds to outer"); fail = fail + 1; }

// Called multiple times — fresh scope each time
var n = 0;
function f7() { var n = 1; n = n + 10; }
f7();
f7();
f7();
if (n === 0) { pass = pass + 1; } else { print("FAIL: repeated calls bleed n"); fail = fail + 1; }

print("pass: " + pass + " fail: " + fail);

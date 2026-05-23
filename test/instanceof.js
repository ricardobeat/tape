// Test instanceof operator - flat structure, no ++
var pass = 0, fail = 0;

// 1. Basic instanceof with custom constructors
function Foo() {}
function Bar() {}
var foo = new Foo();
if (foo instanceof Foo) { pass = pass + 1; } else { print("FAIL: foo instanceof Foo"); fail = fail + 1; }
if (!(foo instanceof Bar)) { pass = pass + 1; } else { print("FAIL: foo not instanceof Bar"); fail = fail + 1; }
if (foo instanceof Object) { pass = pass + 1; } else { print("FAIL: foo instanceof Object"); fail = fail + 1; }

// 2. Prototype chain (inheritance)
Bar.prototype = new Foo();
var bar = new Bar();
if (bar instanceof Bar) { pass = pass + 1; } else { print("FAIL: bar instanceof Bar"); fail = fail + 1; }
if (bar instanceof Foo) { pass = pass + 1; } else { print("FAIL: bar instanceof Foo (inherits)"); fail = fail + 1; }
if (bar instanceof Object) { pass = pass + 1; } else { print("FAIL: bar instanceof Object"); fail = fail + 1; }

// 3. Primitives are not objects
if (!(123 instanceof Object)) { pass = pass + 1; } else { print("FAIL: number not instanceof Object"); fail = fail + 1; }
if (!("hello" instanceof Object)) { pass = pass + 1; } else { print("FAIL: string not instanceof Object"); fail = fail + 1; }
if (!(true instanceof Object)) { pass = pass + 1; } else { print("FAIL: boolean not instanceof Object"); fail = fail + 1; }
if (!(null instanceof Object)) { pass = pass + 1; } else { print("FAIL: null not instanceof Object"); fail = fail + 1; }
if (!(undefined instanceof Object)) { pass = pass + 1; } else { print("FAIL: undefined not instanceof Object"); fail = fail + 1; }

// 4. instanceof with built-in constructors
var arr = [1, 2, 3];
if (arr instanceof Array) { pass = pass + 1; } else { print("FAIL: arr instanceof Array"); fail = fail + 1; }
if (arr instanceof Object) { pass = pass + 1; } else { print("FAIL: arr instanceof Object"); fail = fail + 1; }

var obj = {};
if (obj instanceof Object) { pass = pass + 1; } else { print("FAIL: {} instanceof Object"); fail = fail + 1; }
if (!(obj instanceof Array)) { pass = pass + 1; } else { print("FAIL: {} not instanceof Array"); fail = fail + 1; }

// 5. Error types
try {
    null.foo;
} catch (e) {
    if (e instanceof TypeError) { pass = pass + 1; } else { print("FAIL: e instanceof TypeError"); fail = fail + 1; }
    if (e instanceof Error) { pass = pass + 1; } else { print("FAIL: e instanceof Error"); fail = fail + 1; }
    if (e instanceof Object) { pass = pass + 1; } else { print("FAIL: e instanceof Object"); fail = fail + 1; }
    if (!(e instanceof RangeError)) { pass = pass + 1; } else { print("FAIL: e not instanceof RangeError"); fail = fail + 1; }
}

// 6. function instance
function TestFunc() {}
var tf = new TestFunc();
if (tf instanceof TestFunc) { pass = pass + 1; } else { print("FAIL: tf instanceof TestFunc"); fail = fail + 1; }

// Reset prototype chain
TestFunc.prototype = {};
if (!(tf instanceof TestFunc)) { pass = pass + 1; } else { print("FAIL: tf not instanceof after change"); fail = fail + 1; }

function TestFunc2() {}
var tf2 = new TestFunc2();
if (tf2 instanceof TestFunc2) { pass = pass + 1; } else { print("FAIL: tf2 instanceof TestFunc2"); fail = fail + 1; }

print("pass: " + pass + " fail: " + fail);

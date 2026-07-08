// Comprehensive destructuring tests with iterables
var pass = 0, fail = 0;

function test(name, fn) {
    try {
        fn();
        pass++;
    } catch (e) {
        print("FAIL: " + name + " — " + e);
        fail++;
    }
}

// === Simple array destructuring with Arrays ===
test("array simple", function() {
    function f([a, b]) { return a + b; }
    if (f([1, 2]) !== 3) throw "expected 3";
});

// === Simple array destructuring with generator ===
test("generator simple", function() {
    function f([a, b]) { return a + b; }
    var r = f((function*(){ yield 1; yield 2; })());
    if (r !== 3) throw "expected 3, got " + r;
});

// === Array destructuring with defaults ===
test("array defaults with iterable", function() {
    function f([a = 10, b = 20]) { return a + b; }
    var r = f((function*(){ yield 5; })());
    if (r !== 25) throw "expected 25 (5+20), got " + r;
});

// === Nested array destructuring ===
test("nested array with iterable", function() {
    function f([a, [b, c]]) { return a + b + c; }
    var r = f((function*(){ yield 1; yield (function*(){ yield 2; yield 3; })(); })());
    if (r !== 6) throw "expected 6, got " + r;
});

// === Mixed array/object destructuring ===
test("mixed array+object with iterable", function() {
    function f([a, {x, y}]) { return a + x + y; }
    var r = f((function*(){ yield 1; yield {x: 2, y: 3}; })());
    if (r !== 6) throw "expected 6, got " + r;
});

// === Arrow function with array destructuring ===
test("arrow with iterable", function() {
    var f = ([a, b]) => a + b;
    var r = f((function*(){ yield 10; yield 20; })());
    if (r !== 30) throw "expected 30, got " + r;
});

// === Simple rest with array ===
test("simple rest with array", function() {
    function f([a, ...rest]) { return rest.length; }
    if (f([1, 2, 3]) !== 2) throw "expected 2, got " + f([1, 2, 3]);
});

// === Rest only with array ===
test("rest only with array", function() {
    function f([...rest]) { return rest.length; }
    if (f([1, 2, 3, 4]) !== 4) throw "expected 4";
});

// === Rest with generator ===
test("rest with generator", function() {
    function f([...rest]) { return rest.join(","); }
    var r = f((function*(){ yield "a"; yield "b"; yield "c"; })());
    if (r !== "a,b,c") throw "expected a,b,c, got " + r;
});

// === Rest with custom iterable ===
test("rest with custom iterable", function() {
    var obj = {
        [Symbol.iterator]: function() {
            var i = 0;
            return { next: function() { return i < 3 ? {value: i++, done: false} : {done: true}; } };
        }
    };
    function f([...rest]) { return rest.length; }
    if (f(obj) !== 3) throw "expected 3, got " + f(obj);
});

// === Rest after elements with generator ===
test("rest after elements with generator", function() {
    function f([a, b, ...rest]) { return rest.join(","); }
    var r = f((function*(){ yield 1; yield 2; yield 3; yield 4; })());
    if (r !== "3,4") throw "expected 3,4, got " + r;
});

// === Elision (holes) with rest ===
test("elision with rest", function() {
    function f([, , ...rest]) { return rest.length; }
    if (f([1, 2, 3, 4, 5]) !== 3) throw "expected 3, got " + f([1,2,3,4,5]);
});

// === Nested rest ===
test("nested rest", function() {
    function f([...[...rest]]) { return rest.join(","); }
    var r = f([1, 2, 3]);
    if (r !== "1,2,3") throw "expected 1,2,3, got " + r;
});

print(pass + " passed, " + fail + " failed");
if (fail > 0) throw "SOME TESTS FAILED";

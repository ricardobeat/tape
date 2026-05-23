// Test two-argument calls from inner functions
function outer() {
    var a = 1;
    var b = 1;
    
    function check(x, y) {
        print("a=" + a + " b=" + b);
        print("x=" + x + " y=" + y);
        print("x===y:", x === y);
        if (x === y) {
            print("PASS: x === y");
        } else {
            print("FAIL: x !== y");
        }
    }
    
    check(a, b);
}

outer();
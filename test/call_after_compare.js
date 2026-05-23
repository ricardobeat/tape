// Test: inner function calls print() then compares its own args
function test() {
    var a = 1;
    var b = 1;
    
    function check(x, y) {
        print("before call: x=" + x + " y=" + y);
        print(x === y);
        if (x === y) {
            print("same");
        } else {
            print("different");
        }
    }
    
    check(a, b);
}

test();
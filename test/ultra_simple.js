// Ultra-simple: just check what assert_sameValue receives
function add(a, b) { return a + b; }
function test() {
    var result = add(1, 1);
    print("result:", result);
    print("typeof result:", typeof result);
    print("2 typeof:", typeof 2);
    print("result === 2:", result === 2);
}
test();
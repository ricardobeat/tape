// Minimal debug: just add and compare
function test() {
    var result = 1 + 1;
    print("result:", result, "typeof:", typeof result);
    print("2 typeof:", typeof 2);
    if (result === 2) {
        print("PASS");
    } else {
        print("FAIL");
    }
}
test();
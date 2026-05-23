// Binary search - which operation fails
function test1() {
    var result = 1 + 1;
    print("after addition");
    return result;
}
var r1 = test1();

function test2() {
    print("r1:", r1);
}
test2();

print("done");
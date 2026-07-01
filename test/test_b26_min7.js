// Minimal JMP_NGE test
function f() {
    var r3 = 44;
    var r5 = 65;
    if (r3 >= 65) {
        return "should-not-jump";
    } else {
        return "should-jump";
    }
}
print(f());

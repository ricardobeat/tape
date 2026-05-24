// Arrow function: new should throw TypeError
var Arrow = () => {};
var threw = false;
try {
    var obj = new Arrow();
} catch (e) {
    threw = true;
}
if (threw) {
    print('PASS: new Arrow throws TypeError');
} else {
    print('FAIL: new Arrow did not throw');
}

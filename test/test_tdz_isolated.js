function test3() {
    var z = 'outer';
    { var _c = z; let z = 'inner'; }
}
try {
    test3();
    print("no throw");
} catch(e) {
    print("threw: " + e);
}

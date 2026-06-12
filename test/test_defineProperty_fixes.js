// Test BUG 1: empty descriptor should create property
var pass = 0;
var fail = 0;

var o = {};
Object.defineProperty(o, "p", {});
if (o.hasOwnProperty("p")) {
    print("TEST1 PASS: empty descriptor creates property");
    pass++;
} else {
    print("TEST1 FAIL: empty descriptor did not create property");
    fail++;
}

// Test BUG 2a: non-configurable + configurable:true in generic descriptor -> TypeError
var o2 = {};
Object.defineProperty(o2, "p", { value: 1 });
var threw = false;
try {
    Object.defineProperty(o2, "p", { configurable: true });
} catch(e) {
    threw = true;
}
if (threw) {
    print("TEST2 PASS: throws on configurable:true for non-configurable property");
    pass++;
} else {
    print("TEST2 FAIL: should have thrown TypeError");
    fail++;
}

// Test BUG 2b: generic descriptor must not clobber value
var o3 = {};
Object.defineProperty(o3, "p", { value: 1, configurable: true });
Object.defineProperty(o3, "p", { enumerable: true });
if (o3.p === 1) {
    print("TEST3 PASS: generic descriptor does not clobber value");
    pass++;
} else {
    print("TEST3 FAIL: value was clobbered, got " + o3.p);
    fail++;
}

print("pass: " + pass + " fail: " + fail);

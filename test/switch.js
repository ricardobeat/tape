// Test switch/case statement - ES5 §12.11
var pass = 0, fail = 0;

// 1. Basic switch with break
function testBasic() {
    var x = 1;
    var result = "";
    switch (x) {
        case 1:
            result = "one";
            break;
        case 2:
            result = "two";
            break;
        default:
            result = "other";
    }
    if (result === "one") { pass = pass + 1; } else { print("FAIL: basic switch case 1"); fail = fail + 1; }
}
testBasic();

// 2. Fall-through between cases
function testFallthrough() {
    var x = 1;
    var result = "";
    switch (x) {
        case 1:
            result = result + "a";
        case 2:
            result = result + "b";
            break;
        case 3:
            result = result + "c";
    }
    if (result === "ab") { pass = pass + 1; } else { print("FAIL: fallthrough 1->2 got '" + result + "'"); fail = fail + 1; }
}
testFallthrough();

// 3. Multi-level fall-through
function testMultiFallthrough() {
    var x = 1;
    var result = "";
    switch (x) {
        case 1:
            result = result + "a";
        case 2:
            result = result + "b";
        case 3:
            result = result + "c";
            break;
        default:
            result = "x";
    }
    if (result === "abc") { pass = pass + 1; } else { print("FAIL: multi fallthrough 1->3 got '" + result + "'"); fail = fail + 1; }
}
testMultiFallthrough();

// 4. Default case
function testDefault() {
    var x = 99;
    var result = "";
    switch (x) {
        case 1:
            result = "one";
            break;
        default:
            result = "default";
            break;
        case 2:
            result = "two";
            break;
    }
    if (result === "default") { pass = pass + 1; } else { print("FAIL: default case got '" + result + "'"); fail = fail + 1; }
}
testDefault();

// 5. Default with fall-through from case
function testDefaultFallthrough() {
    var x = 2;
    var result = "";
    switch (x) {
        case 1:
            result = "one";
            break;
        case 2:
            result = "two";
        default:
            result = result + "-default";
            break;
    }
    if (result === "two-default") { pass = pass + 1; } else { print("FAIL: default fallthrough got '" + result + "'"); fail = fail + 1; }
}
testDefaultFallthrough();

// 6. Multiple cases sharing same body (empty cases)
function testEmptyCases() {
    var x = 1;
    var result = "";
    switch (x) {
        case 1:
        case 2:
            result = "one-or-two";
            break;
        case 3:
            result = "three";
            break;
    }
    if (result === "one-or-two") { pass = pass + 1; } else { print("FAIL: empty case 1 got '" + result + "'"); fail = fail + 1; }

    x = 2;
    result = "";
    switch (x) {
        case 1:
        case 2:
            result = "one-or-two";
            break;
        case 3:
            result = "three";
            break;
    }
    if (result === "one-or-two") { pass = pass + 1; } else { print("FAIL: empty case 2 got '" + result + "'"); fail = fail + 1; }
}
testEmptyCases();

// 7. No match and no default
function testNoMatchNoDefault() {
    var x = 99;
    var result = "unchanged";
    switch (x) {
        case 1:
            result = "one";
            break;
        case 2:
            result = "two";
            break;
    }
    if (result === "unchanged") { pass = pass + 1; } else { print("FAIL: no match no default got '" + result + "'"); fail = fail + 1; }
}
testNoMatchNoDefault();

// 8. Switch with string cases
function testStringCases() {
    var x = "hello";
    var result = "";
    switch (x) {
        case "world":
            result = "world";
            break;
        case "hello":
            result = "hello";
            break;
        default:
            result = "other";
    }
    if (result === "hello") { pass = pass + 1; } else { print("FAIL: string case got '" + result + "'"); fail = fail + 1; }
}
testStringCases();

// 9. Switch with boolean cases
function testBoolCases() {
    var x = true;
    var result = "";
    switch (x) {
        case false:
            result = "false";
            break;
        case true:
            result = "true";
            break;
    }
    if (result === "true") { pass = pass + 1; } else { print("FAIL: bool case got '" + result + "'"); fail = fail + 1; }
}
testBoolCases();

// 10. Switch inside a loop with break
function testSwitchInLoop() {
    var sum = 0;
    for (var i = 1; i <= 3; i = i + 1) {
        switch (i) {
            case 1:
                sum = sum + 10;
                break;
            case 2:
                sum = sum + 20;
                break;
            case 3:
                sum = sum + 30;
                break;
        }
    }
    if (sum === 60) { pass = pass + 1; } else { print("FAIL: switch in loop sum=" + sum); fail = fail + 1; }
}
testSwitchInLoop();

// 11. Nested switch
function testNestedSwitch() {
    var x = 1, y = 2;
    var result = "";
    switch (x) {
        case 1:
            switch (y) {
                case 2:
                    result = "1-2";
                    break;
                default:
                    result = "1-?";
            }
            break;
        case 2:
            result = "2";
            break;
    }
    if (result === "1-2") { pass = pass + 1; } else { print("FAIL: nested switch got '" + result + "'"); fail = fail + 1; }
}
testNestedSwitch();

// 12. Switch with conditional fall-through
function testConditionalFallthrough() {
    var x = 1;
    var flag = false;
    var result = "";
    switch (x) {
        case 1:
            if (flag) {
                break;
            }
            result = "from1";
        case 2:
            result = result + "-from2";
            break;
    }
    if (result === "from1-from2") { pass = pass + 1; } else { print("FAIL: conditional fallthrough got '" + result + "'"); fail = fail + 1; }
}
testConditionalFallthrough();

// 13. Switch with var declaration in body
function testVarInBody() {
    var x = 1;
    var result = "";
    switch (x) {
        case 1:
            var y = "hello";
            result = y;
            break;
        case 2:
            result = "two";
            break;
    }
    if (result === "hello") { pass = pass + 1; } else { print("FAIL: var in body got '" + result + "'"); fail = fail + 1; }
}
testVarInBody();

// 14. Expression as switch discriminant
function testExpressionDisc() {
    var a = 5, b = 3;
    var result = "";
    switch (a - b) {
        case 1:
            result = "one";
            break;
        case 2:
            result = "two";
            break;
    }
    if (result === "two") { pass = pass + 1; } else { print("FAIL: expr discriminant got '" + result + "'"); fail = fail + 1; }
}
testExpressionDisc();

// 15. Strict equality in case comparison (no coercion)
function testStrictEquality() {
    var result = "";
    switch ("1") {
        case 1:
            result = "number";
            break;
        case "1":
            result = "string";
            break;
    }
    if (result === "string") { pass = pass + 1; } else { print("FAIL: strict equality got '" + result + "'"); fail = fail + 1; }
}
testStrictEquality();

print("pass: " + pass + " fail: " + fail);

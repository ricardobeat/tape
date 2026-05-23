// Test labeled break/continue statements - ES5 §12.12
var pass = 0;
var fail = 0;

function assert(cond, msg) {
    if (cond) { pass = pass + 1; }
    else { print("FAIL: " + msg); fail = fail + 1; }
}

// 1. Labeled break from outer loop
function testLabeledBreakOuter() {
    var result = "";
    outer: for (var i = 0; i < 3; i = i + 1) {
        for (var j = 0; j < 3; j = j + 1) {
            if (i === 1 && j === 1) {
                break outer;
            }
            result = result + i + "," + j + ";";
        }
    }
    assert(result === "0,0;0,1;0,2;1,0;", "labeled break outer: '" + result + "'");
}
testLabeledBreakOuter();

// 2. Labeled continue to outer loop
function testLabeledContinueOuter() {
    var result = "";
    outer: for (var i = 0; i < 3; i = i + 1) {
        for (var j = 0; j < 3; j = j + 1) {
            if (j === 1) {
                continue outer;
            }
            result = result + i + "," + j + ";";
        }
    }
    assert(result === "0,0;1,0;2,0;", "labeled continue outer: '" + result + "'");
}
testLabeledContinueOuter();

// 3. Unlabeled break still works (inner loop)
function testUnlabeledBreak() {
    var result = "";
    for (var i = 0; i < 3; i = i + 1) {
        for (var j = 0; j < 3; j = j + 1) {
            if (j === 1) {
                break;
            }
            result = result + i + "," + j + ";";
        }
    }
    assert(result === "0,0;1,0;2,0;", "unlabeled break inner: '" + result + "'");
}
testUnlabeledBreak();

// 4. Unlabeled continue still works
function testUnlabeledContinue() {
    var result = "";
    for (var i = 0; i < 3; i = i + 1) {
        if (i === 1) {
            continue;
        }
        result = result + i + ";";
    }
    assert(result === "0;2;", "unlabeled continue: '" + result + "'");
}
testUnlabeledContinue();

// 5. Labeled break from a block (non-loop label)
function testLabeledBreakBlock() {
    var result = "start-";
    block: {
        result = result + "a-";
        if (true) {
            break block;
        }
        result = result + "b-";
    }
    result = result + "end";
    assert(result === "start-a-end", "labeled break block: '" + result + "'");
}
testLabeledBreakBlock();

// 6. Labeled break from while loop
function testLabeledBreakWhile() {
    var result = "";
    outer: while (true) {
        result = result + "a;";
        var i = 0;
        while (i < 5) {
            if (i === 2) {
                break outer;
            }
            i = i + 1;
        }
        result = result + "b;";
    }
    result = result + "done";
    assert(result === "a;done", "labeled break while: '" + result + "'");
}
testLabeledBreakWhile();

// 7. Labeled continue skips the rest of outer while body
function testLabeledContinueWhile() {
    var result = "";
    var count = 0;
    outer: while (count < 5) {
        count = count + 1;
        var i = 0;
        while (i < 3) {
            i = i + 1;
            if (i === 2 && count === 3) {
                continue outer;
            }
        }
        result = result + count + ";";
    }
    assert(result === "1;2;4;5;", "labeled continue while: '" + result + "'");
}
testLabeledContinueWhile();

// 8. Labeled break on inner loop (break b)
function testNestedLabels() {
    var result = "";
    a: for (var i = 0; i < 2; i = i + 1) {
        b: for (var j = 0; j < 2; j = j + 1) {
            if (j === 1) {
                break b;
            }
            result = result + i + "," + j + ";";
        }
    }
    assert(result === "0,0;1,0;", "nested labels: '" + result + "'");
}
testNestedLabels();

// 9. Label on do-while loop
function testLabeledDoWhile() {
    var result = "";
    var i = 0;
    outer: do {
        var j = 0;
        inner: do {
            j = j + 1;
            if (i === 1 && j === 2) {
                break outer;
            }
            result = result + i + "," + j + ";";
        } while (j < 3);
        i = i + 1;
    } while (i < 3);
    assert(result === "0,1;0,2;0,3;1,1;", "labeled do-while: '" + result + "'");
}
testLabeledDoWhile();

// 10. Break to named label from deeply nested (using length check to avoid string interning issues)
function testDeeplyNestedBreak() {
    var result = "";
    top: {
        for (var i = 0; i < 3; i = i + 1) {
            for (var j = 0; j < 3; j = j + 1) {
                if (true) {
                    if (i === 1 && j === 1) {
                        break top;
                    }
                }
            }
        }
        result = "nope";
    }
    // Verify break skipped the "nope" assignment
    if (result === "") { pass = pass + 1; }
    else { print("FAIL: deeply nested break: got '" + result + "'"); fail = fail + 1; }
}
testDeeplyNestedBreak();

// 11. Simple label on for loop
function testSimpleLabel() {
    var result = "";
    mylabel: for (var i = 0; i < 5; i = i + 1) {
        if (i === 2) {
            break mylabel;
        }
        result = result + i + ";";
    }
    assert(result === "0;1;", "simple label: '" + result + "'");
}
testSimpleLabel();

// 12. Labeled break with switch inside loop
function testLabeledBreakSwitchInLoop() {
    var result = "";
    outer: for (var i = 0; i < 3; i = i + 1) {
        switch (i) {
            case 0:
                result = result + "a;";
                break;
            case 1:
                result = result + "b;";
                break outer;
            case 2:
                result = result + "c;";
                break;
        }
    }
    assert(result === "a;b;", "labeled break switch in loop: '" + result + "'");
}
testLabeledBreakSwitchInLoop();

// 13. Labeled continue with for-in loop
function testLabeledContinueForIn() {
    var obj = { x: 1, y: 2, z: 3 };
    var result = "";
    outer: for (var k in obj) {
        var inner = { a: 10, b: 20 };
        for (var j in inner) {
            if (k === "y" && j === "a") {
                continue outer;
            }
            result = result + k + ":" + j + ";";
        }
    }
    // y continues before appending, so "y:a" never appears, only "y:b"
    // y's inner loop skips entirely on y:a due to continue outer, so y:b also absent
    assert(result.indexOf("y:a") < 0 && result.indexOf("y:b") < 0,
           "labeled continue for-in: result=" + result);
}
testLabeledContinueForIn();

print("PASS: " + pass + " / " + (pass + fail) + " assertions");
if (fail > 0) { print("SOME TESTS FAILED"); }

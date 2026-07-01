// Minimal repro for B04: duplicate parameter names via Function constructor
// should throw SyntaxError, not VM_ERROR.

function runTest() {
    try {
        var fn = new Function("a", "a", "return;");
        print("FAIL: no throw, got fn =", String(fn));
        return false;
    } catch (e) {
        if (e instanceof SyntaxError) {
            print("PASS: SyntaxError thrown:", e.constructor.name);
            return true;
        } else {
            print("FAIL: expected SyntaxError, got:", e.constructor.name, String(e));
            return false;
        }
    }
}

if (!runTest()) process.exit(1);
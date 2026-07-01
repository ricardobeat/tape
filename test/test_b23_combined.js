function check(name, actual, expected) {
    if (actual === expected) {
        print("PASS " + name + ":", JSON.stringify(actual));
    } else {
        print("FAIL " + name + ": got", JSON.stringify(actual), "expected", JSON.stringify(expected));
    }
}

try { check("1 obj-mem", `${ {x: 1}.x }`, "1"); } catch (e) { print("ERR 1:", e.constructor.name, String(e)); }
try { check("2 nested-obj", `${ {a: {b: 2}}.a.b }`, "2"); } catch (e) { print("ERR 2:", e.constructor.name, String(e)); }
try { check("3 parens", `${ ({x: 1}.x) }`, "1"); } catch (e) { print("ERR 3:", e.constructor.name, String(e)); }
try { check("4 parens-direct", `${ ({x: 1}) }`, "[object Object]"); } catch (e) { print("ERR 4:", e.constructor.name, String(e)); }
try { check("5 arr", `${ [1, 2][1] }`, "2"); } catch (e) { print("ERR 5:", e.constructor.name, String(e)); }
try { check("6 fn", `${ ({x: function(){return 1}}).x() }`, "1"); } catch (e) { print("ERR 6:", e.constructor.name, String(e)); }

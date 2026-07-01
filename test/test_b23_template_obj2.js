// Simpler repros for B23 template+object literal
function check(name, actual, expected) {
    if (actual === expected) {
        print("PASS " + name + ":", JSON.stringify(actual));
    } else {
        print("FAIL " + name + ": got", JSON.stringify(actual), "expected", JSON.stringify(expected));
    }
}

// 1. object literal in template
try { check("obj-in-tmpl", `${ {x: 1}.x }`, "1"); }
catch (e) { print("ERR obj-in-tmpl:", e.constructor.name, String(e)); }

// 2. nested object
try { check("nested-obj", `${ {a: {b: 2}}.a.b }`, "2"); }
catch (e) { print("ERR nested-obj:", e.constructor.name, String(e)); }

// 3. object in template with member
try { check("obj-mem", `${ ({x: 1}.x) }`, "1"); }
catch (e) { print("ERR obj-mem:", e.constructor.name, String(e)); }

// 4. object in template (no member)
try { check("obj-direct", `${ ({x: 1}) }`, "[object Object]"); }
catch (e) { print("ERR obj-direct:", e.constructor.name, String(e)); }

// 5. array in template
try { check("arr-in-tmpl", `${ [1, 2][1] }`, "2"); }
catch (e) { print("ERR arr-in-tmpl:", e.constructor.name, String(e)); }

// 6. function call in template
try { check("fn-in-tmpl", `${ ({x: function(){return 1}}).x() }`, "1"); }
catch (e) { print("ERR fn-in-tmpl:", e.constructor.name, String(e)); }

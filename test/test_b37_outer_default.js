// B37 — destructured parameters with outer `= default` initializer.
// Before the fix, the parser rejected `function f([x] = []) {...}` and
// `function g({x} = {}) {...}` because the destructured-param branches in
// compile_inner_function() did not check for the trailing `=` after the
// closing `]` / `}` — they unconditionally emitted REQUIRE_OBJ and
// returned, leaving the `=` token to trip the outer `,)` check.
//
// Root cause: collect_*_param_binds() consumes the pattern, then the
// outer default's `=` lives AFTER the closing bracket, not before. The
// fix reorders the destructured-param branch to call the new
// emit_param_default_handler() *after* the pattern collect, then emit
// REQUIRE_OBJ only when no default was consumed. With a default, the
// REQUIRE_OBJ check is conditional on whether the argument was undefined.

var __pass = 0, __fail = 0;
function assert(cond, msg) {
    if (cond === true) { __pass++; return; }
    __fail++; print("FAIL: " + (msg || ""));
}
function assert_isNaN(actual, msg) {
    if (Number.isNaN(actual)) { __pass++; return; }
    __fail++; print("FAIL: " + (msg || "") + " — expected NaN, got " + actual);
}

// Helper: returns default when arg === undefined, otherwise the arg.
function getArr([x] = [42]) { return x; }
assert( getArr()      === 42, "outer array default, no arg");
assert( getArr([7])   === 7,  "outer array default, arg supplied");

// Conditional REQUIRE_OBJ: with default, undefined arg uses default.
// With non-undefined arg (incl. null), REQUIRE_OBJ still throws.
try {
    getArr(null);
    assert(false, "null arg with outer default should still REQUIRE_OBJ");
} catch (e) {
    assert(e instanceof TypeError, "getArr(null) throws TypeError");
}

// Object destructured with outer default.
function getObj({a, b} = {a: 10, b: 20}) { return a + b; }
assert( getObj()                    === 30, "outer object default");
assert( getObj({a: 1, b: 2})        === 3,  "supplied object");
assert_isNaN( getObj({a: 5}),      "missing keys are undefined");

// Inner per-binding default combined with outer default. The spec: outer
// kicks in when arg is undefined; inner per-element default kicks in
// when the destructured slot is undefined.
function combo([x = 1, y = 2] = [10, 20]) { return [x, y]; }
assert( JSON.stringify(combo())         === "[10,20]", "outer default uses default array");
assert( JSON.stringify(combo([99]))     === "[99,2]",  "outer arg, inner y default kicks in");
try {
    var r = combo([, 88]);
    assert( JSON.stringify(r) === "[1,88]",  "outer arg, inner x default kicks in");
} catch (e) { assert(false, "inner x default: " + e.message); }

// Mixed positional + destructured params in the same signature. The
// multi-default semantics (mixed(1, [3], {c: 100}) → 104) still has a
// separate bug tracked separately from B37 — the basic B37 fix here
// covers single-param destructured-with-outer-default. Verify just the
// simple cases to avoid masking regressions in later work.
function mixed(a, [b] = [7]) { return a + b; }
assert( mixed(1)            === 8, "positional + array default");
try {
    assert( mixed(1, [3])   === 4, "positional + supplied array");
} catch (e) { assert(false, "mixed: " + e.message); }

// Object default can also include inner per-binding defaults.
function objCombo({a = 100, b = 200} = {}) { return a + b; }
assert( objCombo()                    === 300, "outer obj default + inner per-key defaults");
try {
    assert( objCombo({a: 1})          === 201, "inner b default kicks in");
    assert( objCombo({b: 5})          === 105, "inner a default kicks in");
} catch (e) { assert(false, "objCombo: " + e.message); }

// Class methods get the same machinery (compile_inner_function is shared).
class C {
    m([a, b] = [9, 8]) { return a * b; }
}
var c = new C();
assert( c.m()    === 72, "class method outer array default");

// Existing no-default destructured param still throws on null/undefined.
function strict([x]) { return x; }
try {
    strict(null);
    assert(false, "no-default destructure should still REQUIRE_OBJ");
} catch (e) {
    assert(e instanceof TypeError, "strict(null) throws");
}

print("B37 outer-default destructured params: " + __pass + " passed, " + __fail + " failed");
if (__fail > 0) { /* exit not available here */ }


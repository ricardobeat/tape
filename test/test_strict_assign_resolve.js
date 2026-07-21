// Strict plain assignment to an identifier: resolvability is captured
// BEFORE the RHS runs (ES2022 §13.15.2 step 1 + §6.2.5.6 PutValue step 5).
// Exercises RESOLVEVAR (with its VarIC) + THROW_UNRESOLVED.
"use strict";

var pass = 0, fail = 0;
function t(name, ok) {
  if (ok) { pass++; } else { fail++; print("FAIL: " + name); }
}

// Pre-RHS unresolvable throws even when the RHS creates the global,
// and the error names the identifier.
var t1 = false;
try { undeclared_a = (this.undeclared_a = 5); }
catch (e) { t1 = e instanceof ReferenceError && /undeclared_a/.test(e.message); }
t("unresolvable-pre-RHS throws ReferenceError", t1);

// Resolvable global (builtin) assignment works.
parseInt = 7;
t("assign to existing global", parseInt === 7);

// Hot loop over a strict global assignment (VarIC fast path).
this.g1 = 0;
var s = 0;
for (var i = 0; i < 100000; i++) { g1 = i; s += g1; }
t("hot-loop global assign", g1 === 99999);

// Binding deleted during the RHS: SetMutableBinding's stillExists check
// (§9.1.1.2.5 step 3) throws in strict mode.
this.z1 = 1;
var t4 = false;
try { eval('z1 = (delete this.z1, 2)'); }
catch (e) { t4 = e instanceof ReferenceError; }
t("deleted-during-RHS throws", t4);

// Deleted then re-created during the RHS: stillExists is true again at
// PutValue time, so the write lands.
this.z2 = 1;
z2 = (delete this.z2, this.z2 = 9, 3);
t("deleted-then-recreated writes", z2 === 3);

// Chained assignment to undeclared throws.
var t5 = false;
try { eval('chain_aa = chain_bb = 1;'); }
catch (e) { t5 = e instanceof ReferenceError; }
t("chained undeclared throws", t5);

// const reassignment still TypeError (not swallowed by the resolve path).
const c1 = 1;
var t6 = false;
try { eval('c1 = 2;'); }
catch (e) { t6 = e instanceof TypeError; }
t("const reassign TypeError", t6);

// Closure-captured var writes through PUTVAR_ASSIGN's IC.
function mk() {
  var v = 0;
  return { set: function (n) { v = n; }, get: function () { return v; } };
}
var h = mk();
for (var j = 0; j < 20000; j++) { h.set(j); }
t("closure-captured assign", h.get() === 19999);

print(fail === 0 ? "PASS " + pass + "/" + (pass + fail)
                 : "FAILED " + fail + "/" + (pass + fail));

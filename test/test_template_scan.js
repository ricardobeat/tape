// Template-aware scanner regression battery (TemplateScan, template_scan.c3).
// Every case puts a template with tricky braces where a token-level scanner
// (skip_function_body / skip_braced_block / skip_expression / hoist_decls /
// hoist_global_fn_decls / captures / private_names / skip_class_body /
// skip_destructure_pattern / param-list skip) walks raw tokens.
var pass = 0, fail = 0;
function t(name, ok) {
  if (ok) { pass++; } else { fail++; print("FAIL: " + name); }
}

// Braced arrow in substitution (the 254d665 case).
function f1() {
  return `${ (() => { return 9; })() }`;
}
t("braced arrow in substitution", f1() === "9");

// Nested template AFTER a JS brace inside a substitution (per-level counts).
function f2() {
  function inner() { return `${ (() => { return `${1}` + "x"; })() }`; }
  var after = 42;
  return inner() + ":" + after;
}
t("nested template after brace", f2() === "1x:42");

// Object literal inside a substitution.
function f3() {
  return `${ {a: 1}.a }:${ {b: {c: 2}}.b.c }`;
}
t("object literals in substitutions", f3() === "1:2");

// Two-level nesting with braces at both levels.
function f4() {
  return `${ (() => { return `${ (() => { return 5; })() }`; })() }`;
}
t("two-level nested braced arrows", f4() === "5");

// Captures scan: arrow inside a substitution capturing a local declared
// after the template (nested function forces the captures prescan).
function f5() {
  var seen = [];
  function grab() { seen.push(`${ (() => { return `${4}`; })() }`); }
  var tail = "t";
  grab();
  return seen[0] + ":" + tail;
}
t("captures scan with nested template", f5() === "4:t");

// Class body scans (private_names prescan) with templates in members.
class C6 {
  #p = 1;
  m() { return `${ (() => { let q = 2; return q; })() }`; }
  n() { return this.#p; }
}
t("class private prescan", new C6().m() === "2" && new C6().n() === 1);

// Class field initializer with nested template + braces, followed by
// another member (element-boundary state machine).
class C7 {
  f = `${ (() => { return `${7}`; })() }`;
  g() { return "g"; }
}
t("class field template init", new C7().f === "7" && new C7().g() === "g");

// skip_class_body: template inside the extends expression.
function mix(s) { return class { tag() { return "m" + s; } }; }
function f8() {
  class D extends mix(`${ {k: 8}.k }`) { }
  var after = "a";
  return new D().tag() + ":" + after;
}
t("template in extends expression", f8() === "m8:a");

// Parameter default containing a template with substitution braces.
function f9(a = `${ {v: 9}.v }`) { return a; }
t("template in param default", f9() === "9");

// Destructured parameter default with a template.
function f10({ x = `${ {v: 10}.v }` } = {}) { return x; }
t("template in destructured param default", f10() === "10");

// Destructured arrow param default with a template (scan_destruct_param_to_arrow).
var f11 = ({ y = `${ {v: 11}.v }` } = {}) => y;
t("template in destructured arrow param", f11() === "11");

// var declaration with destructuring default template (skip_destructure_pattern).
function f12() {
  var { z = `${ {v: 12}.v }` } = {};
  var post = "p";
  return z + ":" + post;
}
t("template in var destructure default", f12() === "12:p");

// Multiple substitutions with braces in each (TEMPLATE_MIDDLE path).
function f13() {
  return `${ {a: 1}.a }-${ (() => { return 2; })() }-${ `${3}` }`;
}
t("middle parts with braces", f13() === "1-2-3");

// Code following the template-bearing function must survive (the original
// truncation symptom).
t("code after templates still runs", true);

print(fail === 0 ? "PASS " + pass + "/" + (pass + fail)
                 : "FAILED " + fail + "/" + (pass + fail));

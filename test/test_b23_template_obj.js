// Minimal repro for B23 test_template.js:66 — object literal in template
var t12 = `${ {x: 1}.x }`;
print(t12);
// Test 1: simple template
var t1 = `hello`;
print(t1);

// Test 2: template with simple expression
var t2 = `${1+2}`;
print(t2);

// Test 3: object literal in template (no spaces)
var t3 = `${{a:1}}`;
print(t3);

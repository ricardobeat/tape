// Test: What does the lexer produce for regexp literals?
var r = /foo/;
// Print the source property
print("source:", r.source);
print("global:", r.global);
print("ignoreCase:", r.ignoreCase);
print("multiline:", r.multiline);
print("lastIndex:", r.lastIndex);
print("test:", r.test("foo"));

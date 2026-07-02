// B30 — Array.prototype.pop use-after-free on interned strings
// From test/rosetta/FAILURES.md: "while (!st.isEmpty()) out += st.pop() returns
// a partial/garbled string when the loop body is a single += on a method call."
//
// Root cause (B30): Array.prototype.pop's TVal result pointed at an interned
// HString whose last reference was the array slot being cleared. After
// `array_delete_elem` decref'd the slot, refcount hit 0 and the HString was
// removed from the string table and freed — the TVal then pointed to memory
// the allocator was free to reuse (e.g. for the next allocation triggered by
// the `out += ...` concat). The reuse could overwrite the HString's data so
// the popped char read back as "" or a different char.
//
// Triggers when:
//   1. The source string has duplicate characters (e.g. "hello" has 2 'l's).
//   2. The loop is a while loop (or for loop with the same structure).
//   3. The user-defined pop method internally calls Array.prototype.pop on
//      this.items (so there are two nested method calls in the chain).
//
// Adding a print inside the loop body changes register allocation and avoids
// the failure path; the test below only uses minimal code to exercise the
// exact failing pattern. Fix: builtin_array_proto_pop now increfs the popped
// HString before the slot is cleared, transferring ownership to the caller.

function Stack() { this.items = []; }
Stack.prototype.pop = function () { return this.items.pop(); };

var pass = 0, fail = 0;
function assertEq(actual, expected, msg) {
    if (actual === expected) { pass++; }
    else { fail++; print("FAIL: " + msg + " — expected " + JSON.stringify(expected) + ", got " + JSON.stringify(actual)); }
}

function reverse(str) {
    var st = new Stack();
    for (var i = 0; i < str.length; i++) st.items.push(str[i]);
    var out = "";
    while (st.items.length > 0) {
        out += (st.pop());
    }
    return out;
}

// Strings without duplicates: pass.
assertEq(reverse(""),        "",        "reverse(\"\")");
assertEq(reverse("a"),       "a",       "reverse(\"a\")");
assertEq(reverse("ab"),      "ba",      "reverse(\"ab\")");
assertEq(reverse("abc"),     "cba",     "reverse(\"abc\")");
assertEq(reverse("abcd"),    "dcba",    "reverse(\"abcd\")");
assertEq(reverse("abcde"),   "edcba",   "reverse(\"abcde\")");
assertEq(reverse("abcdef"),  "fedcba",  "reverse(\"abcdef\")");
assertEq(reverse("world"),   "dlrow",   "reverse(\"world\")");

// Strings with duplicates: all should pass after the B30 fix.
assertEq(reverse("hello"),   "olleh",   "reverse(\"hello\")");
assertEq(reverse("helli"),   "illeh",   "reverse(\"helli\")");
assertEq(reverse("abac"),    "caba",    "reverse(\"abac\")");
assertEq(reverse("abcab"),   "bacba",   "reverse(\"abcab\")");
assertEq(reverse("abcabc"),  "cbacba",  "reverse(\"abcabc\")");
assertEq(reverse("abccba"),  "abccba",  "reverse(\"abccba\")");
assertEq(reverse("aabbccdd"),"ddccbbaa","reverse(\"aabbccdd\")");

// Also exercise the for-loop variant and explicit `+` to make sure the fix
// isn't a coincidence of the while-loop body shape.
function reverseFor(str) {
    var st = new Stack();
    for (var i = 0; i < str.length; i++) st.items.push(str[i]);
    var out = "";
    for (var j = 0; j < str.length; j++) {
        out = out + st.pop();
    }
    return out;
}
assertEq(reverseFor("hello"),   "olleh",   "reverseFor(\"hello\")");
assertEq(reverseFor("abac"),    "caba",    "reverseFor(\"abac\")");

// Direct Array.prototype.pop on a duplicate-bearing array (no wrapper):
// should work; if it ever regresses, the bug is in pop itself, not the wrapper.
function reverseDirect(str) {
    var items = [];
    for (var i = 0; i < str.length; i++) items.push(str[i]);
    var out = "";
    while (items.length > 0) out += items.pop();
    return out;
}
assertEq(reverseDirect("hello"), "olleh",   "reverseDirect(\"hello\")");
assertEq(reverseDirect("abac"),  "caba",    "reverseDirect(\"abac\")");

print("B30 stack while-pop: " + pass + " passed, " + fail + " failed");
if (fail > 0) throw new Error("FAIL");

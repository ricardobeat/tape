// B38 — multi-parameter destructured defaults and related structural bugs.
//
// The B37 outer-default fix left three latent bugs, all triggered only when
// a destructured parameter is NOT the last parameter (single-param cases
// happened to work by accident):
//
// 1. Register-allocation hazard in the outer-default check itself: scratch
//    registers for one destructured param's default check could clobber a
//    later parameter's live argument (mixed(a, [b]=[7], {c}={c:11}) used to
//    return 15 instead of 104). Fixed by deferring outer-default emission
//    until every parameter's arg slot is known (parse_destruct_param_default
//    / emit_destruct_param_defaults), instead of emitting immediately.
//
// 2. A more fundamental bug, independent of defaults: compile_inner_function
//    never reserved the destructured param's own arg-slot register
//    (alloc_reg() was dropped when B37 restructured this branch), so any
//    later declare_var/alloc_reg call — even a plain parameter with no
//    default — could reuse that register and silently corrupt the argument.
//
// 3. An off-by-one in the destructured-bind name slice: `name_buf[0..len]`
//    in C3 is an inclusive range (len+1 bytes), not `name_buf[:len]` (len
//    bytes), so bind names carried one trailing garbage byte and failed to
//    match on resolve_var lookups whenever the DECLVAR write wasn't
//    otherwise papered over by a var_env-based read.
//
// 4. The arrow-function parenthesized-param lookahead scan only recognized
//    all-identifier (or single rest) parameter lists; a leading identifier
//    followed by a destructured param, e.g. (x, [b]) => ..., fell through to
//    "not an arrow" and silently mis-parsed as a grouping expression.

var __pass = 0, __fail = 0;
function assert(cond, msg) {
    if (cond === true) { __pass++; return; }
    __fail++; print("FAIL: " + (msg || ""));
}

// --- Bug 1: register clobber across multiple destructured defaults ---
function mixed(a, [b] = [7], {c} = {c: 11}) { return a + b + c; }
assert(mixed(1, [3], {c: 100}) === 104, "mixed: all args passed");
assert(mixed(1) === 1 + 7 + 11, "mixed: defaults used");
assert(mixed(1, [3]) === 1 + 3 + 11, "mixed: partial defaults");

// --- Bug 2: arg-slot register reservation (no defaults involved at all) ---
function destructThenPlain([b], c) { return c; }
assert(destructThenPlain([3], 100) === 100, "destructured-then-plain: reads plain param");

function destructThenDestruct([b], [d]) { return b + d; }
assert(destructThenDestruct([3], [5]) === 8, "destructured-then-destructured: both resolve");

function plainThenDestructDefault(x, [b] = [7]) { return x + b; }
assert(plainThenDestructDefault(1, [3]) === 4, "plain-then-destructured-default: passed");
assert(plainThenDestructDefault(1) === 1 + 7, "plain-then-destructured-default: omitted");

// --- Bug 3: destructured-bind name resolution without any default present ---
function noDefaultAtAll([x]) { return x; }
assert(noDefaultAtAll([7]) === 7, "destructured param with no default resolves by name");

function objNoDefault({y}) { return y; }
assert(objNoDefault({y: 9}) === 9, "object-destructured param with no default resolves");

// --- Bug 4: arrow function mixed identifier + destructured params ---
var arrowDestructThenPlain = ([b], c) => c;
assert(arrowDestructThenPlain([3], 100) === 100, "arrow: destructured-then-plain");

var arrowPlainThenDestruct = (x, [b]) => x + b;
assert(arrowPlainThenDestruct(1, [3]) === 4, "arrow: plain-then-destructured (no default)");

var arrowMixedDefaults = (x, [b] = [7], {c} = {c: 11}) => x + b + c;
assert(arrowMixedDefaults(1, [3], {c: 100}) === 104, "arrow: triple mixed, all passed");
assert(arrowMixedDefaults(1) === 1 + 7 + 11, "arrow: triple mixed, defaults used");

print("B38 multi-destruct-default: " + __pass + " passed, " + __fail + " failed");

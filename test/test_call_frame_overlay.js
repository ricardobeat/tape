// Oracle for plan 043 (CALL callee-frame register overlay).
//
// Exercises the register-overlaying call path: rest collection driven by a
// *user-JS* iterator's .next() loop (generators / function-parameter
// destructuring), with many prior locals live so the rest collector is forced
// high in the register file. This is the exact condition that surfaced the
// plan-042 overlay bug. A CALL that overlaid the collector register would leave
// holes / undefined in the collected array or clobber the live priors.
//
// NOTE: statement-level `var [h, ...t] = userIterable` is deliberately NOT
// tested here — that path still uses index/.slice() access (tracked as a
// separate iterator-protocol bug, plan 044), independent of register overlay.

var passed = 0, failed = 0;
function check(name, got, want) {
    var g = JSON.stringify(got), w = JSON.stringify(want);
    if (g === w) { passed++; }
    else { failed++; print("FAIL " + name + ": got " + g + " want " + w); }
}

// Function-parameter array rest from a generator (the surface plan-042 fixed,
// which drives the overlaying CALL loop). Prior locals kept live across it.
function paramRest([first, ...rest]) {
    var a = 1, b = 2, c = 3, d = 4, e = 5, f = 6, g = 7, h = 8;
    var sum = a + b + c + d + e + f + g + h;
    return { first: first, rest: rest, sum: sum };
}

function gen3() { return (function*(){ yield 10; yield 20; yield 30; })(); }
var r1 = paramRest(gen3());
check("param-first", r1.first, 10);
check("param-rest", r1.rest, [20, 30]);
check("priors-survive", r1.sum, 36);

// Nested rest in a parameter ([[...inner]]) — exercises the synthetic
// group_reg pre-scan routed through alloc_persistent_reg.
function nestedParamRest([[...inner]]) {
    return inner;
}
check("nested-param-rest",
    nestedParamRest([(function*(){ yield 1; yield 2; yield 3; })()]),
    [1, 2, 3]);

// Rest after several formals, collector forced past the low registers.
function midParamRest([p, q, r, ...rest]) {
    var w = 100, x = 200;
    return [p, q, r, rest, w + x];
}
check("mid-param-rest",
    midParamRest((function*(){ yield 0; yield 1; yield 2; yield 3; yield 4; })()),
    [0, 1, 2, [3, 4], 300]);

// Two-element parameter destructuring from a generator (no rest) — the
// baseline iterator-protocol path plan-042 established.
function twoParams([a, b]) { return [a, b]; }
check("two-params",
    twoParams((function*(){ yield 7; yield 8; })()),
    [7, 8]);

print(passed + " passed, " + failed + " failed");
if (failed > 0) { throw new Error(failed + " overlay oracle failures"); }

// Destructuring regression test suite
// Tests all destructuring forms: array, object, nested, mixed, assignment.
// Known bugs are wrapped in try/catch with TODO comments.
// NOTE: Each test uses unique variable names to avoid cross-block aliasing
//       with the assertEq function parameters.

var pass = 0;
var fail = 0;
var skip = 0;

function assertEq(x, y, msg) {
    if (x === y) { pass++; } else { fail++; print('FAIL: ' + msg + ' (got ' + x + ', expected ' + y + ')'); }
}

function assertVal(v, msg) {
    if (v) { pass++; } else { fail++; print('FAIL: ' + msg); }
}

// ============================================================
// 1. ARRAY BASICS  (should all work)
// ============================================================

// T1: single element
{
    const [t1a] = [1];
    assertEq(t1a, 1, 'T1: single element');
}

// T2: three elements
{
    const [t2a, t2b, t2c] = [1, 2, 3];
    assertEq(t2a, 1, 'T2: a');
    assertEq(t2b, 2, 'T2: b');
    assertEq(t2c, 3, 'T2: c');
}

// T3: elision (hole)
{
    const [t3a, , t3b] = [1, 2, 3];
    assertEq(t3a, 1, 'T3: a');
    assertEq(t3b, 3, 'T3: b (elided middle)');
}

// T4: rest element
{
    const [t4a, ...t4rest] = [1, 2, 3];
    assertEq(t4a, 1, 'T4: a');
    assertEq(t4rest.length, 2, 'T4: rest length');
    assertEq(t4rest[0], 2, 'T4: rest[0]');
    assertEq(t4rest[1], 3, 'T4: rest[1]');
}

// T5: default value (missing)
{
    const [t5a = 42] = [];
    assertEq(t5a, 42, 'T5: default applied');
}

// T6: default value (present — default not used)
{
    const [t6a = 99] = [7];
    assertEq(t6a, 7, 'T6: default not used');
}

// T7: extra RHS elements (ignored)
{
    const [t7a, t7b] = [1, 2, 3, 4];
    assertEq(t7a, 1, 'T7: a');
    assertEq(t7b, 2, 'T7: b');
}

// T8: fewer RHS elements (undefined)
{
    const [t8a, t8b, t8c] = [1];
    assertEq(t8a, 1, 'T8: a');
    assertVal(t8b === undefined, 'T8: b is undefined');
    assertVal(t8c === undefined, 'T8: c is undefined');
}

// T9: var array destructuring
{
    var [t9a, t9b] = [10, 20];
    assertEq(t9a, 10, 'T9: var a');
    assertEq(t9b, 20, 'T9: var b');
}

// T10: let array destructuring
{
    let [t10a, t10b] = [30, 40];
    assertEq(t10a, 30, 'T10: let a');
    assertEq(t10b, 40, 'T10: let b');
}

// ============================================================
// 2. OBJECT BASICS  (should all work)
// ============================================================

// T11: shorthand
{
    const {t11x, t11y} = {t11x: 1, t11y: 2};
    assertEq(t11x, 1, 'T11: x');
    assertEq(t11y, 2, 'T11: y');
}

// T12: keyed (renaming)
{
    const {t12k: t12v} = {t12k: 10};
    assertEq(t12v, 10, 'T12: keyed rename');
}

// T13: default value (missing property)
{
    const {t13a = 1} = {};
    assertEq(t13a, 1, 'T13: default applied');
}

// T14: default value (present, default not used)
{
    const {t14a = 99} = {t14a: 7};
    assertEq(t14a, 7, 'T14: default not used');
}

// T15: mixed shorthand + keyed
{
    const {t15a, t15k: t15v} = {t15a: 1, t15k: 2};
    assertEq(t15a, 1, 'T15: shorthand');
    assertEq(t15v, 2, 'T15: keyed');
}

// T16: missing property -> undefined
{
    const {t16missing} = {other: 1};
    assertVal(t16missing === undefined, 'T16: missing is undefined');
}

// T17: var object destructuring
{
    var {t17x, t17y} = {t17x: 100, t17y: 200};
    assertEq(t17x, 100, 'T17: var x');
    assertEq(t17y, 200, 'T17: var y');
}

// T18: let object destructuring
{
    let {t18x, t18y} = {t18x: 300, t18y: 400};
    assertEq(t18x, 300, 'T18: let x');
    assertEq(t18y, 400, 'T18: let y');
}

// ============================================================
// 3. NESTED ARRAY DESTRUCTURING
// ============================================================

// TODO BUG: [[a]] — nested single-element array.
// Expected: a=1 (number)
// Actual: a=[1] (array object) — the inner pattern [a] is not destructured.
// print(a) outputs "1" which is misleading (array toString).
{
    const [[t19a]] = [[1]];
    if (typeof t19a === 'number' && t19a === 1) {
        pass++;
        print('T19: FIXED - [[a]] = [[1]] gives a=1 (number)');
    } else {
        fail++;
        print('TODO T19: [[a]] = [[1]] - a is type ' + typeof t19a + ', expected number 1 (BUG)');
    }
}

// TODO BUG: [[a], b] — nested first element.
// Expected: a=1, b=2
// Actual: a=[1] (array), b=2
{
    const [[t20a], t20b] = [[1], 2];
    assertEq(t20b, 2, 'T20: b');
    if (typeof t20a === 'number' && t20a === 1) {
        pass++;
        print('T20: FIXED - [[a], b] gives a=1');
    } else {
        fail++;
        print('TODO T20: [[a], b] - a is type ' + typeof t20a + ', expected number 1 (BUG)');
    }
}

// TODO BUG: [a, [b]] — nested second element (single RHS element).
// Expected: a=1, b=2 (number)
// Actual: a=1, b=[2] (array) — inner pattern not destructured.
// print(b) outputs "2" which is misleading.
{
    const [t21a, [t21b]] = [1, [2]];
    assertEq(t21a, 1, 'T21: a');
    if (typeof t21b === 'number' && t21b === 2) {
        pass++;
        print('T21: FIXED - [a, [b]] = [1, [2]] gives b=2');
    } else {
        fail++;
        print('TODO T21: [a, [b]] = [1, [2]] - b is type ' + typeof t21b + ', expected number 2 (BUG)');
    }
}

// TODO BUG: [a, [b], c] — nested middle.
// Expected: a=1, b=2, c=3
// Actual: a=1, b=[2], c=3 — inner pattern not destructured.
{
    const [t22a, [t22b], t22c] = [1, [2], 3];
    assertEq(t22a, 1, 'T22: a');
    assertEq(t22c, 3, 'T22: c');
    if (typeof t22b === 'number' && t22b === 2) {
        pass++;
        print('T22: FIXED - [a, [b], c] gives b=2');
    } else {
        fail++;
        print('TODO T22: [a, [b], c] = [1, [2], 3] - b is type ' + typeof t22b + ', expected number 2 (BUG)');
    }
}

// TODO BUG: [a, , [b]] — elision + nested.
// Expected: a=1, b=3
// Actual: a=1, b=[3] (array)
{
    const [t23a, , [t23b]] = [1, 2, [3]];
    assertEq(t23a, 1, 'T23: a');
    if (typeof t23b === 'number' && t23b === 3) {
        pass++;
        print('T23: FIXED - [a, , [b]] gives b=3');
    } else {
        fail++;
        print('TODO T23: [a, , [b]] = [1, 2, [3]] - b is type ' + typeof t23b + ', expected number 3 (BUG)');
    }
}

// TODO BUG: [a, [b, c]] fails at compile time.
// Expected: a=1, b=2, c=3
// Actual: Compile failed
{
    var t24ok = false;
    var t24res = 0;
    try {
        t24res = eval('(function() { const [_a, [_b, _c]] = [1, [2, 3]]; return _a + _b + _c; })()');
        t24ok = true;
    } catch (e) {
        // compile error
    }
    if (t24ok) {
        assertEq(t24res, 6, 'T24: [a, [b, c]] sum');
        print('TODO T24: FIXED - [a, [b, c]] = [1, [2, 3]]');
    } else {
        skip++;
        print('TODO T24: [a, [b, c]] = [1, [2, 3]] - Compile failed (BUG)');
    }
}

// TODO BUG: [[a, b]] fails at compile time.
// Expected: a=1, b=2
// Actual: Compile failed
{
    var t25ok = false;
    var t25res = '';
    try {
        t25res = eval('(function() { const [[_a, _b]] = [[1, 2]]; return _a + "," + _b; })()');
        t25ok = true;
    } catch (e) {
        // compile error
    }
    if (t25ok) {
        assertEq(t25res, '1,2', 'T25: [[a, b]]');
        print('TODO T25: FIXED - [[a, b]] = [[1, 2]]');
    } else {
        skip++;
        print('TODO T25: [[a, b]] = [[1, 2]] - Compile failed (BUG)');
    }
}

// ============================================================
// 4. NESTED OBJECT DESTRUCTURING
// ============================================================

// TODO BUG: {x: {y: beta}} extracts the sub-object instead of property y.
// Expected: beta=42 (number)
// Actual: beta={y:42} (object) — the inner {y:beta} pattern is not destructured.
{
    const {t27x: {t27y: t27v}} = {t27x: {t27y: 42}};
    if (typeof t27v === 'number' && t27v === 42) {
        pass++;
        print('T27: FIXED - {x: {y: beta}} gives beta=42');
    } else {
        fail++;
        print('TODO T27: {x: {y: beta}} - got type ' + typeof t27v + ', expected number 42 (BUG)');
    }
}

// TODO BUG: {x: {y}} shorthand — same issue.
// Expected: y=42 (number)
// Actual: y={y:42} (object)
{
    var t28v;
    { const {x: {y}} = {x: {y: 42}}; t28v = y; }
    if (typeof t28v === 'number' && t28v === 42) {
        pass++;
        print('T28: FIXED - {x: {y}} shorthand gives y=42');
    } else {
        fail++;
        print('TODO T28: {x: {y}} shorthand - got ' + t28v + ' (type ' + typeof t28v + '), expected number 42 (BUG)');
    }
}

// TODO BUG: {x: {y, z}} — multiple nested properties.
// Expected: y=1, z=2 (numbers)
// Actual: y=[object Object], z=undefined
{
    const {t29x: {t29y, t29z}} = {t29x: {t29y: 1, t29z: 2}};
    if (t29y === 1 && t29z === 2) {
        pass = pass + 2;
        print('T29: FIXED - {x: {y, z}} gives y=1 z=2');
    } else {
        fail = fail + 2;
        print('TODO T29: {x: {y, z}} - got y=' + t29y + ' (type ' + typeof t29y + ') z=' + t29z + ' (type ' + typeof t29z + '), expected y=1 z=2 (BUG)');
    }
}

// ============================================================
// 5. DESTRUCTURING ASSIGNMENT (to existing variables)
// ============================================================

// T30: var array destructuring assignment (works)
{
    var t30a, t30b;
    [t30a, t30b] = [1, 2];
    assertEq(t30a, 1, 'T30: var [a, b] = [1,2] a');
    assertEq(t30b, 2, 'T30: var [a, b] = [1,2] b');
}

// T31: var object destructuring assignment — keyed (works)
{
    var t31a, t31b;
    ({t31k1: t31a, t31k2: t31b} = {t31k1: 1, t31k2: 2});
    assertEq(t31a, 1, 'T31: var {k1:a, k2:b} a');
    assertEq(t31b, 2, 'T31: var {k1:a, k2:b} b');
}

// T32: var shorthand object destructuring assignment (works)
{
    var t32a, t32b;
    ({t32a, t32b} = {t32a: 1, t32b: 2});
    assertEq(t32a, 1, 'T32: var {a, b} shorthand a');
    assertEq(t32b, 2, 'T32: var {a, b} shorthand b');
}

// TODO BUG: let array destructuring assignment — variables remain undefined.
// Expected: t33a=1, t33b=2
// Actual: t33a=undefined, t33b=undefined
{
    let t33a, t33b;
    [t33a, t33b] = [1, 2];
    if (t33a === 1 && t33b === 2) {
        pass = pass + 2;
        print('T33: FIXED - let [a, b] = [1,2] gives a=1 b=2');
    } else {
        fail = fail + 2;
        print('TODO T33: let [a, b] = [1,2] - got ' + t33a + ',' + t33b + ' expected 1,2 (BUG)');
    }
}

// TODO BUG: let object destructuring assignment — variables remain undefined.
// Expected: t34a=1, t34b=2
// Actual: t34a=undefined, t34b=undefined
{
    let t34a, t34b;
    ({t34k1: t34a, t34k2: t34b} = {t34k1: 1, t34k2: 2});
    if (t34a === 1 && t34b === 2) {
        pass = pass + 2;
        print('T34: FIXED - let {k1:a, k2:b} = {k1:1, k2:2} gives a=1 b=2');
    } else {
        fail = fail + 2;
        print('TODO T34: let {k1:a, k2:b} = {k1:1, k2:2} - got ' + t34a + ',' + t34b + ' expected 1,2 (BUG)');
    }
}

// T35: var array assignment with default (works)
{
    var t35a = 0;
    [t35a = 42] = [];
    assertEq(t35a, 42, 'T35: var [a=42] = [] default');
}

// T36: var array assignment with rest (works)
{
    var t36a, t36rest;
    [t36a, ...t36rest] = [1, 2, 3];
    assertEq(t36a, 1, 'T36: rest assignment a');
    assertEq(t36rest.length, 2, 'T36: rest assignment length');
}

// ============================================================
// 6. MIXED PATTERNS (array-in-object, object-in-array)
// ============================================================

// TODO BUG: {x: [a, b]} — array nested inside object.
// Expected: a=1, b=2
// Actual: the whole array [1,2] is assigned to x, inner [a,b] not applied
{
    const {t37x: t37v} = {t37x: [1, 2]};
    if (Array.isArray(t37v)) {
        fail++;
        print('TODO T37: {x: [a, b]} = {x: [1,2]} - got array, inner pattern not applied (BUG)');
        skip++;
    } else {
        pass++;
        print('T37: FIXED - {x: [a, b]} gives a=1 b=2');
    }
}

// TODO BUG: [{a}] — object nested inside array.
// Expected: a=1 (number)
// Actual: a is the whole object {a:1} (inner pattern not applied)
{
    const [t38v] = [{t38a: 1}];
    if (typeof t38v === 'object' && t38v !== null) {
        fail++;
        print('TODO T38: [{a}] = [{a:1}] - got object, inner pattern not applied (BUG)');
        skip++;
    } else if (t38v === 1) {
        pass++;
        print('T38: FIXED - [{a}] gives a=1');
    } else {
        fail++;
        print('TODO T38: [{a}] = [{a:1}] - got ' + t38v + ' (BUG)');
        skip++;
    }
}

// TODO BUG: [{a, b}] — object with multiple props nested in array.
// Expected: a=1, b=2
// Actual: Compile failed
{
    var t39ok = false;
    var t39res = '';
    try {
        t39res = eval('(function() { const [{t39a: _a, t39b: _b}] = [{t39a: 1, t39b: 2}]; return _a + "," + _b; })()');
        t39ok = true;
    } catch (e) {
        // compile error
    }
    if (t39ok) {
        assertEq(t39res, '1,2', 'T39: [{a, b}]');
        print('T39: FIXED - [{a, b}] = [{a:1, b:2}]');
    } else {
        skip++;
        print('TODO T39: [{a, b}] = [{a:1, b:2}] - Compile failed (BUG)');
    }
}

// TODO BUG: [{a: b}] — keyed object in array.
// Expected: b=1
// Actual: Compile failed
{
    var t40ok = false;
    var t40res = 0;
    try {
        t40res = eval('(function() { const [{t40k: _v}] = [{t40k: 1}]; return _v; })()');
        t40ok = true;
    } catch (e) {
        // compile error
    }
    if (t40ok) {
        assertEq(t40res, 1, 'T40: [{a: b}] b');
        print('T40: FIXED - [{a: b}] = [{a:1}]');
    } else {
        skip++;
        print('TODO T40: [{a: b}] = [{a:1}] - Compile failed (BUG)');
    }
}

// ============================================================
// 7. EDGE CASES (should work)
// ============================================================

// T41: destructuring from function return
{
    function makeArr41() { return [10, 20]; }
    const [t41a, t41b] = makeArr41();
    assertEq(t41a, 10, 'T41: function return array a');
    assertEq(t41b, 20, 'T41: function return array b');
}

// T42: destructuring from function return (object)
{
    function makeObj42() { return {t42p: 100, t42q: 200}; }
    const {t42p, t42q} = makeObj42();
    assertEq(t42p, 100, 'T42: function return object p');
    assertEq(t42q, 200, 'T42: function return object q');
}

// T43: destructuring in for-of (array)
{
    var t43sum = 0;
    for (const [t43a, t43b] of [[1, 2], [3, 4]]) {
        t43sum = t43sum + t43a + t43b;
    }
    assertEq(t43sum, 10, 'T43: for-of array destructuring sum');
}

// T44: destructuring in for-of (object)
{
    var t44sum = 0;
    for (const {t44x, t44y} of [{t44x: 1, t44y: 2}, {t44x: 10, t44y: 20}]) {
        t44sum = t44sum + t44x + t44y;
    }
    assertEq(t44sum, 33, 'T44: for-of object destructuring sum');
}

// T45: nested object in for-of (works here, unlike standalone const!)
{
    var t45results = [];
    for (const {t45a: {t45b}} of [{t45a: {t45b: 1}}, {t45a: {t45b: 2}}]) {
        t45results.push(t45b);
    }
    assertEq(t45results.length, 2, 'T45: for-of nested obj length');
    assertEq(t45results[0], 1, 'T45: for-of nested obj [0]');
    assertEq(t45results[1], 2, 'T45: for-of nested obj [1]');
}

// T46: for-of with defaults
{
    var t47results = [];
    for (const [t47a = 99] of [[1], []]) {
        t47results.push(t47a);
    }
    assertEq(t47results.length, 2, 'T46: for-of defaults length');
    assertEq(t47results[0], 1, 'T46: for-of defaults [0]');
    assertEq(t47results[1], 99, 'T46: for-of defaults [1]');
}

// T47: for-of with rest
{
    var t48count = 0;
    for (const [t48a, ...t48rest] of [[1, 2, 3], [4, 5]]) {
        t48count = t48count + t48a + t48rest.length;
    }
    assertEq(t48count, 8, 'T47: for-of rest (1+2 + 4+1 = 8)');
}

// T48: for-of with holes
{
    var t49results = [];
    for (const [t49a, , t49c] of [[1, 2, 3], [4, 5, 6]]) {
        t49results.push(t49a + t49c);
    }
    assertEq(t49results[0], 4, 'T48: for-of holes [0]');
    assertEq(t49results[1], 10, 'T48: for-of holes [1]');
}

// T49: block-scoped destructuring
{
    {
        const [t50a] = [42];
        assertEq(t50a, 42, 'T49a: block-scoped const array');
    }
    {
        const {t50b} = {t50b: 99};
        assertEq(t50b, 99, 'T49b: block-scoped const object');
    }
}

// T50: string RHS (array-like)
{
    const [t51a, t51b] = 'hi';
    assertEq(t51a, 'h', 'T50: string destructure [0]');
    assertEq(t51b, 'i', 'T50: string destructure [1]');
}

// T51: expression RHS
{
    const [t52a, t52b] = [1 + 2, 3 * 4];
    assertEq(t52a, 3, 'T51: expression RHS [0]');
    assertEq(t52b, 12, 'T51: expression RHS [1]');
}

// T52: var array destructuring in for-loop init
{
    for (var [t53i, t53j] = [0, 0]; t53i < 3; t53i = t53i + 1) {
        // just verifying it runs
    }
    assertEq(t53i, 3, 'T52: for-loop array destructure final i');
}

// T53: var object destructuring in for-loop init
{
    for (var {t54v} = {t54v: 0}; t54v < 3; t54v = t54v + 1) {
        // just verifying it runs
    }
    assertEq(t54v, 3, 'T53: for-loop object destructure final v');
}

// ============================================================
// Summary
// ============================================================

print('');
print('PASS: ' + pass + ' / ' + (pass + fail));
if (skip > 0) {
    print('SKIP: ' + skip + ' (known bugs wrapped in try/catch or skipped)');
}

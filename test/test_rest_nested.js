var pass = 0, fail = 0;
function assert(c, m) { if(c) pass++; else { fail++; print("FAIL: " + m); } }

const [a, [b, ...rest]] = [1, [2, 3, 4]];
assert(a === 1, "a=1");
assert(b === 2, "b=2");
assert(rest[0] === 3, "rest[0]=3");
assert(rest[1] === 4, "rest[1]=4");
assert(rest.length === 2, "rest.length=2");

let x, y; let restArr;
[x, [y, ...restArr]] = [10, [20, 30, 40]];
assert(x === 10, "x=10");
assert(y === 20, "y=20");
assert(restArr[0] === 30, "restArr[0]=30");
assert(restArr.length === 2, "restArr.length=2");

print("pass=" + pass + " fail=" + fail);

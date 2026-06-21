var pass = 0, fail = 0;
function assert(c, m) { if(c) pass++; else { fail++; print("FAIL: " + m); } }

// for(let x; x<N;) at global scope — simple_cond fast path was using stale register
var count = 0;
for (let x = 0; x < 5;) { x++; count++; }
assert(count === 5, "for-let no-update no-continue: count=5");

count = 0;
for (let x = 0; x < 5;) { x++; count++; continue; }
assert(count === 5, "for-let no-update with-continue: count=5");

count = 0;
for (let i = 0; i < 10; i++) { count++; }
assert(count === 10, "for-let with-update: count=10");

count = 0;
for (let i = 0; i < 10; i++) { if (i % 2 === 0) continue; count++; }
assert(count === 5, "for-let with-update and continue: count=5");

// while at global scope
count = 0;
var w = 0;
while (w < 5) { w++; count++; }
assert(count === 5, "while global: count=5");

// for(var ...) not affected
count = 0;
for (var j = 0; j < 5;) { j++; count++; continue; }
assert(count === 5, "for-var no-update with-continue: count=5");

// inside function — must still work
function testInner() {
  var c = 0;
  for (let x = 0; x < 5;) { x++; c++; continue; }
  return c;
}
assert(testInner() === 5, "for-let in function: count=5");

print("pass=" + pass + " fail=" + fail);

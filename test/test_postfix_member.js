var pass = 0, fail = 0;
function assert(c, m) { if(c) pass++; else { fail++; print("FAIL: " + m); } }

// Postfix ++ on property
var obj = {x: 1};
obj.x++;
assert(obj.x === 2, "obj.x++ gives 2");

// Postfix -- on property
var obj2 = {y: 5};
obj2.y--;
assert(obj2.y === 4, "obj2.y-- gives 4");

// Postfix ++ on array index
var arr = [10, 20, 30];
arr[0]++;
assert(arr[0] === 11, "arr[0]++ gives 11");

// Postfix -- on array index
arr[1]--;
assert(arr[1] === 19, "arr[1]-- gives 19");

// Return value of postfix is original
var obj3 = {z: 7};
var v = obj3.z++;
assert(v === 7, "postfix returns original 7");
assert(obj3.z === 8, "obj3.z is now 8");

// Prefix ++ on property (should already work)
var obj4 = {n: 3};
++obj4.n;
assert(obj4.n === 4, "prefix ++obj4.n gives 4");

print("pass=" + pass + " fail=" + fail);

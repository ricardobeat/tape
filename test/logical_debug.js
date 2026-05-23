// Debug logical operators
var pass = 0;
var fail = 0;

// Test 1: 0 && 1 -> false branch
if (0 && 1) { 
    print("T1: FAIL - 0&&1 should be falsy"); 
    fail = fail + 1; 
} else { 
    print("T1: PASS"); 
    pass = pass + 1; 
}
print("After T1 - pass:", pass, "fail:", fail);

var r1 = 0 && 42;
print("r1:", r1, "r1===0:", r1 === 0);
if (r1 === 0) { pass = pass + 1; print("T2: PASS"); } else { fail = fail + 1; print("T2: FAIL"); }
print("After T2 - pass:", pass, "fail:", fail);

var r2 = 2 && 3;
print("r2:", r2, "r2===3:", r2 === 3);
if (r2 === 3) { pass = pass + 1; print("T3: PASS"); } else { fail = fail + 1; print("T3: FAIL"); }
print("After T3 - pass:", pass, "fail:", fail);

if (0 || 1) { pass = pass + 1; print("T4: PASS"); } else { fail = fail + 1; print("T4: FAIL"); }
print("After T4 - pass:", pass, "fail:", fail);

if (0 || 0) { fail = fail + 1; print("T5: FAIL"); } else { pass = pass + 1; print("T5: PASS"); }
print("After T5 - pass:", pass, "fail:", fail);

var r3 = 0 || 42;
print("r3:", r3, "r3===42:", r3 === 42);
if (r3 === 42) { pass = pass + 1; print("T6: PASS"); } else { fail = fail + 1; print("T6: FAIL"); }
print("After T6 - pass:", pass, "fail:", fail);

var r4 = 2 || 3;
print("r4:", r4, "r4===2:", r4 === 2);
if (r4 === 2) { pass = pass + 1; print("T7: PASS"); } else { fail = fail + 1; print("T7: FAIL"); }
print("After T7 - pass:", pass, "fail:", fail);

// Nullish coalescing
var r5 = null ?? 42;
print("r5:", r5, "r5===42:", r5 === 42);
if (r5 === 42) { pass = pass + 1; print("T8: PASS"); } else { fail = fail + 1; print("T8: FAIL"); }
print("After T8 - pass:", pass, "fail:", fail);

var r6 = 0 ?? 99;
print("r6:", r6, "r6===0:", r6 === 0);
if (r6 === 0) { pass = pass + 1; print("T9: PASS"); } else { fail = fail + 1; print("T9: FAIL"); }
print("After T9 - pass:", pass, "fail:", fail);

print("Final - pass:", pass, "fail:", fail);

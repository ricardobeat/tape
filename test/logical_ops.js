// Test logical operators &&, ||, ??
var pass = 0;
var fail = 0;

// Test &&
if (0 && 1) { fail = fail + 1; } else { pass = pass + 1; }
if (1 && 2) { pass = pass + 1; } else { fail = fail + 1; }
var r1 = 0 && 42;
if (r1 === 0) { pass = pass + 1; } else { fail = fail + 1; }
var r2 = 2 && 3;
if (r2 === 3) { pass = pass + 1; } else { fail = fail + 1; }

// Test ||
if (0 || 1) { pass = pass + 1; } else { fail = fail + 1; }
if (0 || 0) { fail = fail + 1; } else { pass = pass + 1; }
var r3 = 0 || 42;
if (r3 === 42) { pass = pass + 1; } else { fail = fail + 1; }
var r4 = 2 || 3;
if (r4 === 2) { pass = pass + 1; } else { fail = fail + 1; }

// Test ?? (nullish coalescing)
var r5 = null ?? 42;
if (r5 === 42) { pass = pass + 1; } else { fail = fail + 1; }
var r6 = 0 ?? 99;
if (r6 === 0) { pass = pass + 1; } else { fail = fail + 1; }
var r7 = false ?? true;
if (r7 === false) { pass = pass + 1; } else { fail = fail + 1; }
var r8 = undefined ?? 123;
if (r8 === 123) { pass = pass + 1; } else { fail = fail + 1; }

print("pass:", pass, "fail:", fail);

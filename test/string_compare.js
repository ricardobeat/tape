// String comparison test
var pass = 0;
var fail = 0;

// Test < with strings
if ("a" < "b") { pass = pass + 1; } else { fail = fail + 1; }
if ("b" < "a") { fail = fail + 1; } else { pass = pass + 1; }
if ("a" < "a") { fail = fail + 1; } else { pass = pass + 1; }

// Test <= with strings
if ("a" <= "b") { pass = pass + 1; } else { fail = fail + 1; }
if ("a" <= "a") { pass = pass + 1; } else { fail = fail + 1; }
if ("b" <= "a") { fail = fail + 1; } else { pass = pass + 1; }

// Test > with strings
if ("b" > "a") { pass = pass + 1; } else { fail = fail + 1; }
if ("a" > "b") { fail = fail + 1; } else { pass = pass + 1; }
if ("a" > "a") { fail = fail + 1; } else { pass = pass + 1; }

// Test >= with strings
if ("b" >= "a") { pass = pass + 1; } else { fail = fail + 1; }
if ("a" >= "a") { pass = pass + 1; } else { fail = fail + 1; }
if ("a" >= "b") { fail = fail + 1; } else { pass = pass + 1; }

// Test longer strings
if ("ab" < "ac") { pass = pass + 1; } else { fail = fail + 1; }
if ("ab" < "abc") { pass = pass + 1; } else { fail = fail + 1; }
if ("abc" < "ab") { fail = fail + 1; } else { pass = pass + 1; }
if ("hello" < "world") { pass = pass + 1; } else { fail = fail + 1; }

// Test numeric comparison still works
if (1 < 2) { pass = pass + 1; } else { fail = fail + 1; }
if (5 > 3) { pass = pass + 1; } else { fail = fail + 1; }
if (10 <= 10) { pass = pass + 1; } else { fail = fail + 1; }
if (10 >= 10) { pass = pass + 1; } else { fail = fail + 1; }

print("pass:", pass, "fail:", fail);

// Abstract equality (==) type coercion tests
var pass = 0;
var fail = 0;

// Same type — same as strict
if (1 == 1) { pass = pass + 1; } else { fail = fail + 1; }
if ("a" == "a") { pass = pass + 1; } else { fail = fail + 1; }
if (true == true) { pass = pass + 1; } else { fail = fail + 1; }
if (null == null) { pass = pass + 1; } else { fail = fail + 1; }
if (undefined == undefined) { pass = pass + 1; } else { fail = fail + 1; }

// Different type — false
if (1 == "a") { fail = fail + 1; } else { pass = pass + 1; }

// null == undefined
if (null == undefined) { pass = pass + 1; } else { fail = fail + 1; }
if (undefined == null) { pass = pass + 1; } else { fail = fail + 1; }

// String + Number
if ("5" == 5) { pass = pass + 1; } else { fail = fail + 1; }
if (5 == "5") { pass = pass + 1; } else { fail = fail + 1; }
if ("0" == 0) { pass = pass + 1; } else { fail = fail + 1; }
if ("  " == 0) { pass = pass + 1; } else { fail = fail + 1; }
if ("hello" == 5) { fail = fail + 1; } else { pass = pass + 1; }

// Boolean + Number
if (true == 1) { pass = pass + 1; } else { fail = fail + 1; }
if (false == 0) { pass = pass + 1; } else { fail = fail + 1; }
if (1 == true) { pass = pass + 1; } else { fail = fail + 1; }
if (0 == false) { pass = pass + 1; } else { fail = fail + 1; }
if (true == 2) { fail = fail + 1; } else { pass = pass + 1; }

// Boolean + String
if (true == "1") { pass = pass + 1; } else { fail = fail + 1; }
if (false == "0") { pass = pass + 1; } else { fail = fail + 1; }
if (true == "true") { fail = fail + 1; } else { pass = pass + 1; }

// Number with hex string
if (255 == "0xFF") { pass = pass + 1; } else { fail = fail + 1; }

// Negative tests
if (null == 0) { fail = fail + 1; } else { pass = pass + 1; }
if (undefined == "") { fail = fail + 1; } else { pass = pass + 1; }

// NEQ tests
if (1 != "1") { fail = fail + 1; } else { pass = pass + 1; }
if (1 != 2) { pass = pass + 1; } else { fail = fail + 1; }
if (null != undefined) { fail = fail + 1; } else { pass = pass + 1; }

print("pass:", pass, "fail:", fail);

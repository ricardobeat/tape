var pass = 0;
var fail = 0;

// 1-2: basic match
var re = new RegExp("hello");
if (re.test("hello world")) { pass = pass + 1; } else { print("FAIL 1"); fail = fail + 1; }
if (!re.test("goodbye")) { pass = pass + 1; } else { print("FAIL 2"); fail = fail + 1; }

// 3-5: exec
var m = re.exec("say hello world");
if (m != null) { pass = pass + 1; } else { print("FAIL 3"); fail = fail + 1; }
if (m[0] == "hello") { pass = pass + 1; } else { print("FAIL 4"); fail = fail + 1; }
if (m.index == 4) { pass = pass + 1; } else { print("FAIL 5"); fail = fail + 1; }

// 6-8: case insensitive
var re2 = new RegExp("hello", "i");
if (re2.test("HELLO")) { pass = pass + 1; } else { print("FAIL 6"); fail = fail + 1; }
if (re2.test("hello")) { pass = pass + 1; } else { print("FAIL 7"); fail = fail + 1; }
if (!re2.test("world")) { pass = pass + 1; } else { print("FAIL 8"); fail = fail + 1; }

// 9-10: start anchor
var re9 = new RegExp("^start");
if (re9.test("start here")) { pass = pass + 1; } else { print("FAIL 9"); fail = fail + 1; }
if (!re9.test("not start")) { pass = pass + 1; } else { print("FAIL 10"); fail = fail + 1; }

// 11-12: end anchor
var re11 = new RegExp("end$");
if (re11.test("this is the end")) { pass = pass + 1; } else { print("FAIL 11"); fail = fail + 1; }
if (!re11.test("endless")) { pass = pass + 1; } else { print("FAIL 12"); fail = fail + 1; }

// 13: alternation
var re13 = new RegExp("foo|bar");
if (re13.test("bar")) { pass = pass + 1; } else { print("FAIL 13"); fail = fail + 1; }

// 14: capture groups
var re14 = new RegExp("foo(bar)baz");
var m14 = re14.exec("xfoobarbazy");
if (m14[1] == "bar") { pass = pass + 1; } else { print("FAIL 14"); fail = fail + 1; }

// 15: no match null
var re15 = new RegExp("xyz");
var m15 = re15.exec("abc");
if (m15 == null) { pass = pass + 1; } else { print("FAIL 15"); fail = fail + 1; }

print("pass: " + pass + " fail: " + fail);

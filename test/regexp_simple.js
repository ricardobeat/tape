var pass = 0;
var fail = 0;
var s = "hello world";
print("len = " + s.length);
var re = new RegExp("world");
var m = re.exec(s);
if (m != null) { pass = pass + 1; } else { print("FAIL 1"); fail = fail + 1; }
print("m[0] = '" + m[0] + "' index=" + m.index);
print("pass: " + pass + " fail: " + fail);

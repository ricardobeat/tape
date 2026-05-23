// Test String constructor and String.prototype methods
var pass = 0, fail = 0;

// =====================================================
// String() as function
// =====================================================
if (String() === "") { pass = pass + 1; } else { print("FAIL: String()"); fail = fail + 1; }
if (String(true) === "true") { pass = pass + 1; } else { print("FAIL: String(true)"); fail = fail + 1; }
if (String(false) === "false") { pass = pass + 1; } else { print("FAIL: String(false)"); fail = fail + 1; }
if (String(null) === "null") { pass = pass + 1; } else { print("FAIL: String(null)"); fail = fail + 1; }
if (String(undefined) === "undefined") { pass = pass + 1; } else { print("FAIL: String(undefined)"); fail = fail + 1; }
if (String(123) === "123") { pass = pass + 1; } else { print("FAIL: String(123)"); fail = fail + 1; }
if (String("hello") === "hello") { pass = pass + 1; } else { print("FAIL: String('hello')"); fail = fail + 1; }

// typeof
if (typeof String === "function") { pass = pass + 1; } else { print("FAIL: typeof String"); fail = fail + 1; }

// new String() returns object
if (typeof new String() === "object") { pass = pass + 1; } else { print("FAIL: typeof new String()"); fail = fail + 1; }
if (typeof new String("test") === "object") { pass = pass + 1; } else { print("FAIL: typeof new String('test')"); fail = fail + 1; }

// new String() abstract equality via ToPrimitive
if (new String("hello") == "hello") { pass = pass + 1; } else { print("FAIL: new String('hello') == 'hello'"); fail = fail + 1; }
if (new String("") == "") { pass = pass + 1; } else { print("FAIL: new String('') == ''"); fail = fail + 1; }
if (!(new String("abc") == "def")) { pass = pass + 1; } else { print("FAIL: new String('abc') == 'def'"); fail = fail + 1; }

// String.prototype.toString and valueOf (via variables on wrapper objects)
var s1 = new String("test");
if (s1.toString() === "test") { pass = pass + 1; } else { print("FAIL: s1.toString()"); fail = fail + 1; }
var s2 = new String("test");
if (s2.valueOf() === "test") { pass = pass + 1; } else { print("FAIL: s2.valueOf()"); fail = fail + 1; }

// =====================================================
// String.prototype.charAt
// =====================================================
if ("hello".charAt(0) === "h") { pass = pass + 1; } else { print("FAIL: charAt(0)"); fail = fail + 1; }
if ("hello".charAt(4) === "o") { pass = pass + 1; } else { print("FAIL: charAt(4)"); fail = fail + 1; }
if ("hello".charAt(5) === "") { pass = pass + 1; } else { print("FAIL: charAt(5) out of range"); fail = fail + 1; }
if ("hello".charAt(-1) === "") { pass = pass + 1; } else { print("FAIL: charAt(-1)"); fail = fail + 1; }
if ("hello".charAt() === "h") { pass = pass + 1; } else { print("FAIL: charAt() default"); fail = fail + 1; }
if ("abc".charAt(1) === "b") { pass = pass + 1; } else { print("FAIL: charAt(1) abc"); fail = fail + 1; }
if ("".charAt(0) === "") { pass = pass + 1; } else { print("FAIL: charAt(0) on empty"); fail = fail + 1; }
if ("".charAt() === "") { pass = pass + 1; } else { print("FAIL: charAt() on empty"); fail = fail + 1; }

// =====================================================
// String.prototype.charCodeAt
// =====================================================
if ("hello".charCodeAt(0) === 104) { pass = pass + 1; } else { print("FAIL: charCodeAt(0) h=104"); fail = fail + 1; }
if ("hello".charCodeAt(4) === 111) { pass = pass + 1; } else { print("FAIL: charCodeAt(4) o=111"); fail = fail + 1; }
if ("ABC".charCodeAt(0) === 65) { pass = pass + 1; } else { print("FAIL: charCodeAt(0) A=65"); fail = fail + 1; }

// Out of range returns NaN — test separately to avoid && regression
var nanCheck = "hello".charCodeAt(10);
if (typeof nanCheck === "number") { pass = pass + 1; } else { print("FAIL: charCodeAt type NaN"); fail = fail + 1; }
if (isNaN(nanCheck)) { pass = pass + 1; } else { print("FAIL: charCodeAt isNaN"); fail = fail + 1; }

var nanCheck2 = "hello".charCodeAt(-1);
if (typeof nanCheck2 === "number") { pass = pass + 1; } else { print("FAIL: charCodeAt(-1) type"); fail = fail + 1; }
if (isNaN(nanCheck2)) { pass = pass + 1; } else { print("FAIL: charCodeAt(-1) isNaN"); fail = fail + 1; }

// =====================================================
// String.prototype.indexOf
// =====================================================
if ("hello".indexOf("l") === 2) { pass = pass + 1; } else { print("FAIL: indexOf l"); fail = fail + 1; }
if ("hello".indexOf("ll") === 2) { pass = pass + 1; } else { print("FAIL: indexOf ll"); fail = fail + 1; }
if ("hello".indexOf("x") === -1) { pass = pass + 1; } else { print("FAIL: indexOf x not found"); fail = fail + 1; }
if ("hello".indexOf("") === 0) { pass = pass + 1; } else { print("FAIL: indexOf empty"); fail = fail + 1; }
if ("hello".indexOf("l", 3) === 3) { pass = pass + 1; } else { print("FAIL: indexOf l from 3"); fail = fail + 1; }
if ("hello".indexOf("l", 4) === -1) { pass = pass + 1; } else { print("FAIL: indexOf l from 4"); fail = fail + 1; }
if ("hello".indexOf("l", -1) === 2) { pass = pass + 1; } else { print("FAIL: indexOf with neg pos"); fail = fail + 1; }
if ("hello".indexOf("l", 10) === -1) { pass = pass + 1; } else { print("FAIL: indexOf with large pos"); fail = fail + 1; }
if ("aaaa".indexOf("aa") === 0) { pass = pass + 1; } else { print("FAIL: indexOf overlapping"); fail = fail + 1; }
if ("".indexOf("") === 0) { pass = pass + 1; } else { print("FAIL: indexOf empty on empty"); fail = fail + 1; }
if ("".indexOf("a") === -1) { pass = pass + 1; } else { print("FAIL: indexOf a on empty"); fail = fail + 1; }

// =====================================================
// String.prototype.slice
// =====================================================
if ("hello".slice(0, 2) === "he") { pass = pass + 1; } else { print("FAIL: slice(0,2)"); fail = fail + 1; }
if ("hello".slice(1, 4) === "ell") { pass = pass + 1; } else { print("FAIL: slice(1,4)"); fail = fail + 1; }
if ("hello".slice(2) === "llo") { pass = pass + 1; } else { print("FAIL: slice(2)"); fail = fail + 1; }
if ("hello".slice(-3, -1) === "ll") { pass = pass + 1; } else { print("FAIL: slice(-3,-1)"); fail = fail + 1; }
if ("hello".slice(-2) === "lo") { pass = pass + 1; } else { print("FAIL: slice(-2)"); fail = fail + 1; }
if ("hello".slice(4, 2) === "") { pass = pass + 1; } else { print("FAIL: slice(4,2) empty"); fail = fail + 1; }
if ("hello".slice(0, 0) === "") { pass = pass + 1; } else { print("FAIL: slice(0,0)"); fail = fail + 1; }
if ("hello".slice() === "hello") { pass = pass + 1; } else { print("FAIL: slice() default"); fail = fail + 1; }
if ("".slice(0, 0) === "") { pass = pass + 1; } else { print("FAIL: slice on empty"); fail = fail + 1; }

// =====================================================
// String.prototype.substring
// =====================================================
if ("hello".substring(1, 4) === "ell") { pass = pass + 1; } else { print("FAIL: substring(1,4)"); fail = fail + 1; }
if ("hello".substring(4, 1) === "ell") { pass = pass + 1; } else { print("FAIL: substring(4,1) swapped"); fail = fail + 1; }
if ("hello".substring(2) === "llo") { pass = pass + 1; } else { print("FAIL: substring(2)"); fail = fail + 1; }
if ("hello".substring(0, 0) === "") { pass = pass + 1; } else { print("FAIL: substring(0,0)"); fail = fail + 1; }
if ("hello".substring(-1, 2) === "he") { pass = pass + 1; } else { print("FAIL: substring(-1,2) clamped"); fail = fail + 1; }
if ("hello".substring(2, 10) === "llo") { pass = pass + 1; } else { print("FAIL: substring(2,10) clamped"); fail = fail + 1; }
if ("".substring(0, 0) === "") { pass = pass + 1; } else { print("FAIL: substring on empty"); fail = fail + 1; }

// =====================================================
// String.prototype.substr
// =====================================================
if ("hello".substr(1, 3) === "ell") { pass = pass + 1; } else { print("FAIL: substr(1,3)"); fail = fail + 1; }
if ("hello".substr(2) === "llo") { pass = pass + 1; } else { print("FAIL: substr(2)"); fail = fail + 1; }
if ("hello".substr(-3, 2) === "ll") { pass = pass + 1; } else { print("FAIL: substr(-3,2)"); fail = fail + 1; }
if ("hello".substr(1, 0) === "") { pass = pass + 1; } else { print("FAIL: substr(1,0) empty"); fail = fail + 1; }
if ("hello".substr(10, 2) === "") { pass = pass + 1; } else { print("FAIL: substr(10,2) out of range"); fail = fail + 1; }
if ("".substr(0, 1) === "") { pass = pass + 1; } else { print("FAIL: substr on empty"); fail = fail + 1; }

// =====================================================
// String.prototype.toLowerCase
// =====================================================
if ("HELLO".toLowerCase() === "hello") { pass = pass + 1; } else { print("FAIL: toLowerCase HELLO"); fail = fail + 1; }
if ("Hello World".toLowerCase() === "hello world") { pass = pass + 1; } else { print("FAIL: toLowerCase Hello World"); fail = fail + 1; }
if ("ABC123".toLowerCase() === "abc123") { pass = pass + 1; } else { print("FAIL: toLowerCase ABC123"); fail = fail + 1; }
if ("".toLowerCase() === "") { pass = pass + 1; } else { print("FAIL: toLowerCase empty"); fail = fail + 1; }
if ("already lower".toLowerCase() === "already lower") { pass = pass + 1; } else { print("FAIL: toLowerCase already"); fail = fail + 1; }

// =====================================================
// String.prototype.toUpperCase
// =====================================================
if ("hello".toUpperCase() === "HELLO") { pass = pass + 1; } else { print("FAIL: toUpperCase hello"); fail = fail + 1; }
if ("Hello World".toUpperCase() === "HELLO WORLD") { pass = pass + 1; } else { print("FAIL: toUpperCase Hello World"); fail = fail + 1; }
if ("abc123".toUpperCase() === "ABC123") { pass = pass + 1; } else { print("FAIL: toUpperCase abc123"); fail = fail + 1; }
if ("".toUpperCase() === "") { pass = pass + 1; } else { print("FAIL: toUpperCase empty"); fail = fail + 1; }
if ("ALREADY UPPER".toUpperCase() === "ALREADY UPPER") { pass = pass + 1; } else { print("FAIL: toUpperCase already"); fail = fail + 1; }

// =====================================================
// String.prototype.trim
// =====================================================
if ("  hello  ".trim() === "hello") { pass = pass + 1; } else { print("FAIL: trim spaces"); fail = fail + 1; }
if ("hello".trim() === "hello") { pass = pass + 1; } else { print("FAIL: trim no spaces"); fail = fail + 1; }
if ("   ".trim() === "") { pass = pass + 1; } else { print("FAIL: trim all spaces"); fail = fail + 1; }
if ("".trim() === "") { pass = pass + 1; } else { print("FAIL: trim empty"); fail = fail + 1; }
if ("  a  b  ".trim() === "a  b") { pass = pass + 1; } else { print("FAIL: trim middle spaces"); fail = fail + 1; }

// =====================================================
// String.prototype.split
// =====================================================
var split1 = "a,b,c".split(",");
if (split1.length === 3) { pass = pass + 1; } else { print("FAIL: split length 3"); fail = fail + 1; }
if (split1[0] === "a") { pass = pass + 1; } else { print("FAIL: split[0]"); fail = fail + 1; }
if (split1[1] === "b") { pass = pass + 1; } else { print("FAIL: split[1]"); fail = fail + 1; }
if (split1[2] === "c") { pass = pass + 1; } else { print("FAIL: split[2]"); fail = fail + 1; }

var split2 = "hello".split("");
if (split2.length === 5) { pass = pass + 1; } else { print("FAIL: split empty sep length"); fail = fail + 1; }
if (split2[0] === "h") { pass = pass + 1; } else { print("FAIL: split empty[0]"); fail = fail + 1; }
if (split2[4] === "o") { pass = pass + 1; } else { print("FAIL: split empty[4]"); fail = fail + 1; }

var split3 = "a,b,c".split(",", 2);
if (split3.length === 2) { pass = pass + 1; } else { print("FAIL: split limit length"); fail = fail + 1; }
if (split3[0] === "a") { pass = pass + 1; } else { print("FAIL: split limit[0]"); fail = fail + 1; }
if (split3[1] === "b") { pass = pass + 1; } else { print("FAIL: split limit[1]"); fail = fail + 1; }

var split4 = "hello".split();
if (split4.length === 1) { pass = pass + 1; } else { print("FAIL: split no sep length"); fail = fail + 1; }
if (split4[0] === "hello") { pass = pass + 1; } else { print("FAIL: split no sep value"); fail = fail + 1; }

// =====================================================
// String.prototype.concat
// =====================================================
if ("hello".concat(" world") === "hello world") { pass = pass + 1; } else { print("FAIL: concat one"); fail = fail + 1; }
if ("hello".concat(" ", "world", "!") === "hello world!") { pass = pass + 1; } else { print("FAIL: concat multiple"); fail = fail + 1; }
if ("".concat("a", "b") === "ab") { pass = pass + 1; } else { print("FAIL: concat from empty"); fail = fail + 1; }
if ("hello".concat() === "hello") { pass = pass + 1; } else { print("FAIL: concat no args"); fail = fail + 1; }
if ("".concat() === "") { pass = pass + 1; } else { print("FAIL: concat empty no args"); fail = fail + 1; }

// =====================================================
// String.prototype.replace (string-only)
// =====================================================
if ("hello".replace("l", "x") === "hexlo") { pass = pass + 1; } else { print("FAIL: replace first l"); fail = fail + 1; }
if ("hello".replace("x", "y") === "hello") { pass = pass + 1; } else { print("FAIL: replace not found"); fail = fail + 1; }
if ("hello".replace("hello", "hi") === "hi") { pass = pass + 1; } else { print("FAIL: replace whole string"); fail = fail + 1; }
if ("".replace("", "") === "") { pass = pass + 1; } else { print("FAIL: replace on empty"); fail = fail + 1; }

// =====================================================
// Method chaining
// =====================================================
if ("  Hello World  ".trim().toUpperCase() === "HELLO WORLD") { pass = pass + 1; } else { print("FAIL: chain trim+upper"); fail = fail + 1; }
if ("HELLO".toLowerCase().charAt(0) === "h") { pass = pass + 1; } else { print("FAIL: chain lower+charAt"); fail = fail + 1; }

// =====================================================
// Methods on String wrapper objects
// =====================================================
var sw = new String("test value");
if (sw.charAt(0) === "t") { pass = pass + 1; } else { print("FAIL: wrapper charAt"); fail = fail + 1; }
if (sw.indexOf("value") === 5) { pass = pass + 1; } else { print("FAIL: wrapper indexOf"); fail = fail + 1; }
if (sw.toUpperCase() === "TEST VALUE") { pass = pass + 1; } else { print("FAIL: wrapper toUpperCase"); fail = fail + 1; }
if (sw.toLowerCase() === "test value") { pass = pass + 1; } else { print("FAIL: wrapper toLowerCase"); fail = fail + 1; }
if (sw.trim() === "test value") { pass = pass + 1; } else { print("FAIL: wrapper trim"); fail = fail + 1; }
if (sw.slice(0, 4) === "test") { pass = pass + 1; } else { print("FAIL: wrapper slice"); fail = fail + 1; }

// =====================================================
// Summary
// =====================================================
print("pass: " + pass + " fail: " + fail);

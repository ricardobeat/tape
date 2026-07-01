// Comprehensive B06 tests covering ES5 §15.5.4.13/§15.5.4.15 edge cases.

function check(name, actual, expected) {
    if (actual === expected) {
        print("PASS " + name + ":", JSON.stringify(actual));
    } else {
        print("FAIL " + name + ": got", JSON.stringify(actual), "expected", JSON.stringify(expected));
    }
}

var end;

// === slice on Boolean wrapper ===
check("B-slice(1)",        String.prototype.slice.call(new Boolean(true), 1),                "rue");
check("B-slice(0,3)",      String.prototype.slice.call(new Boolean(true), 0, 3),            "tru");
check("B-slice(1,undef)",  String.prototype.slice.call(new Boolean(true), 1, undefined),    "rue");
check("B-slice(1,end)",    String.prototype.slice.call(new Boolean(true), 1, end),          "rue");
check("B-slice(-2)",       String.prototype.slice.call(new Boolean(true), -2),               "ue");
check("B-slice(99)",       String.prototype.slice.call(new Boolean(true), 99),               "");

// === slice on Number wrapper ===
check("N-slice(1)",        String.prototype.slice.call(new Number(42), 1),                    "2");
check("N-slice(0,1)",      String.prototype.slice.call(new Number(42), 0, 1),                "4");
check("N-slice(1,undef)",  String.prototype.slice.call(new Number(42), 1, undefined),        "2");
check("N-slice(1,end)",    String.prototype.slice.call(new Number(42), 1, end),              "2");

// === slice on String object ===
check("S-slice(1)",        String.prototype.slice.call(new String("hello"), 1),              "ello");
check("S-slice(1,undef)",  String.prototype.slice.call(new String("hello"), 1, undefined),   "ello");
check("S-slice(1,end)",    String.prototype.slice.call(new String("hello"), 1, end),         "ello");

// === substring on Boolean wrapper ===
check("B-substring(1)",     String.prototype.substring.call(new Boolean(true), 1),           "rue");
check("B-substring(0,3)",   String.prototype.substring.call(new Boolean(true), 0, 3),       "tru");
check("B-substring(1,undef)", String.prototype.substring.call(new Boolean(true), 1, undefined), "rue");
check("B-substring(1,end)", String.prototype.substring.call(new Boolean(true), 1, end),     "rue");

// === substring on Number wrapper ===
check("N-substring(1)",     String.prototype.substring.call(new Number(42), 1),               "2");
check("N-substring(1,end)", String.prototype.substring.call(new Number(42), 1, end),         "2");

// === negative end (slice: negative = from-end; substring: swapped) ===
check("B-slice(1,-1)",      String.prototype.slice.call(new Boolean(true), 1, -1),           "ru");
// substring(1,-1) per ES5 §15.5.4.15 swaps args to substring(-1,1) → substring(0,1) = "t"
check("B-substring(1,-1)",  String.prototype.substring.call(new Boolean(true), 1, -1),       "t");

// === NaN coercion (ToInteger of NaN is 0 per ES5 §9.4) ===
check("B-slice(NaN)",       String.prototype.slice.call(new Boolean(true), NaN),              "true");
check("B-slice(1,NaN)",     String.prototype.slice.call(new Boolean(true), 1, NaN),          "");

// === string primitives (should still work) ===
check("p-slice(1,undef)",   "hello".slice(1, undefined),                                     "ello");
check("p-substring(1,undef)", "hello".substring(1, undefined),                               "ello");
check("p-slice(1,end)",     "hello".slice(1, end),                                           "ello");
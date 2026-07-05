// Minimal smoke tests for generator-method shorthand
// (class bodies and object literals per ES2015 sections 14.3, 14.5)

var pass = 0;
var fail = 0;
function check(name, actual, expected) {
    if (actual === expected) {
        pass++;
    } else {
        fail++;
        print("FAIL " + name + ": expected " + JSON.stringify(expected) + ", got " + JSON.stringify(actual));
    }
}

// 1. Class instance generator method
class A {
    *m() { yield 1; yield 2; }
}
var a = new A();
var ag = a.m();
check("A.m is function", typeof A.prototype.m, "function");
check("A.m name", A.prototype.m.name, "m");
check("A.a", ag.next().value, 1);
check("A.b", ag.next().value, 2);
check("A.c", ag.next().done, true);

// 2. Object-literal generator method
var o = {
    *g() { yield 10; yield 20; }
};
check("o.g is function", typeof o.g, "function");
check("o.g name", o.g.name, "g");
var og = o.g();
check("o.a", og.next().value, 10);
check("o.b", og.next().value, 20);
check("o.c", og.next().done, true);

// 3. Static generator method
class B {
    static *s() { yield "x"; yield "y"; }
}
var bs = B.s();
check("B.s is function", typeof B.s, "function");
check("B.s name", B.s.name, "s");
check("B.a", bs.next().value, "x");
check("B.b", bs.next().value, "y");
check("B.c", bs.next().done, true);

// 4. String-key generator method
class C {
    *"key"() { yield 42; }
}
var ck = new C().key();
check("C.a", ck.next().value, 42);
check("C.b", ck.next().done, true);

// 5. Numeric-key generator method
class D {
    *7() { yield 99; }
}
var d_inst = new D();
var d7 = d_inst[7]();
check("D.a", d7.next().value, 99);

// 6. Object literal computed-key generator method
var K = "ck";
var o2 = {
    *[K]() { yield "v"; }
};
var ok = o2[K]();
check("o2.a", ok.next().value, "v");
check("o2.b", ok.next().done, true);

// 7. Object literal numeric-key generator method
var o3 = {
    *3() { yield "n"; }
};
var on3 = o3[3]();
check("o3.a", on3.next().value, "n");

// 8. Generator method with parameters
class E {
    *gen(x) { yield x; yield x + 1; }
}
var eg = new E().gen(10);
check("E.a", eg.next().value, 10);
check("E.b", eg.next().value, 11);
check("E.c", eg.next().done, true);

// 9. Generator method returning a value
class F {
    *g() { yield 1; return "fin"; }
}
var fg = new F().g();
fg.next();
check("F.a", fg.next().value, "fin");
check("F.b", fg.next().done, true);

// 10. Object literal generator method alongside data property
var o4 = {
    a: 1,
    *gen() { yield 2; yield 3; },
    b: 4,
};
check("o4.a", o4.a, 1);
check("o4.b", o4.b, 4);
var o4g = o4.gen();
check("o4.c", o4g.next().value, 2);
check("o4.d", o4g.next().value, 3);
check("o4.e", o4g.next().done, true);

print("Generator methods: " + pass + " pass, " + fail + " fail");

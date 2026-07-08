// Smoke tests for async-method shorthand (ES2017 section 14.6)
// in class bodies and object literals.

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

// ── Synchronous shape checks ────────────────────────────────────────────────

// 1. Class instance async method
class A {
    async m() { return 1; }
}
check("A.m is function", typeof A.prototype.m, "function");
check("A.m name", A.prototype.m.name, "m");
var am = new A().m();
check("A.m() returns Promise", am instanceof Promise, true);

// 2. Static async method
class B {
    static async s() { return 2; }
}
check("B.s is function", typeof B.s, "function");
check("B.s name", B.s.name, "s");
check("B.s() returns Promise", B.s() instanceof Promise, true);

// 3. Computed-name async method
class C {
    async ["computed"]() { return 4; }
}
check("C.computed is function", typeof C.prototype.computed, "function");
check("C.computed() returns Promise", new C().computed() instanceof Promise, true);

// 4. Object-literal async method
var o = { async om() { return 3; } };
check("o.om is function", typeof o.om, "function");
check("o.om name", o.om.name, "om");
check("o.om() returns Promise", o.om() instanceof Promise, true);

// ── Non-modifier uses of `async` must keep working ──────────────────────────

// 5. `async` as a plain property key
var p1 = { async: 1 };
check("{async: 1}", p1.async, 1);

// 6. Method literally named `async` in an object literal
var p2 = { async() { return 5; } };
check("{async(){}} type", typeof p2.async, "function");
check("{async(){}} call", p2.async(), 5);
check("{async(){}} not a Promise", p2.async() instanceof Promise, false);

// 7. Method literally named `async` in a class body
class D {
    async() { return 6; }
    static async() { return 7; }
}
check("class async() call", new D().async(), 6);
check("class static async() call", D.async(), 7);

// 8. `async` as a plain identifier variable
var async = 8;
check("var async", async, 8);
var p3 = { async };
check("{async} shorthand", p3.async, 8);

// 9. Plain method defined inside an async body must NOT become async,
//    and accessors inside generator/async bodies stay plain too.
async function wrapper() {
    var inner = { plain() { return 9; }, get gv() { return 10; } };
    check("plain method inside async body", inner.plain(), 9);
    check("getter inside async body", inner.gv, 10);
    return 0;
}
wrapper();

// 10. Async methods mixed with other member kinds parse cleanly
class E {
    constructor() { this.base = 100; }
    async plusBase(x) { return this.base + x; }
    static async twice(x) { return x * 2; }
    *gen() { yield 11; }
    get val() { return 12; }
}
check("E.gen still generator", new E().gen().next().value, 11);
check("E.val getter", new E().val, 12);

// ── Async behaviour: resolved values + await inside each form ───────────────
// Await each method sequentially inside one async driver: registering many
// independent top-level .then handlers overruns the engine's microtask queue
// (pre-existing limitation, unrelated to method shorthand).

class F {
    async m() { return 1; }
    static async s() { return 2; }
    async ["computed"]() { return 4; }
    async withAwait() {
        var a = await Promise.resolve(20);
        var b = await 22;
        return a + b;
    }
    static async staticAwait() {
        return (await Promise.resolve(30)) + 1;
    }
    async ["computedAwait"]() {
        return (await Promise.resolve(40)) + 2;
    }
}

var obj = {
    async om() { return 3; },
    async withAwait() {
        return (await Promise.resolve(50)) + 5;
    },
    async "strKey"() { return (await 60) + 6; },
    async 7() { return await 77; },
    async ["objComputed"]() { return (await 80) + 8; }
};

// Awaited rejection is catchable inside the async method.
// (Direct `throw` escaping an async function as a rejection is a
// pre-existing engine limitation for ALL async functions — not tested here.)
class G {
    async boom() {
        try {
            await Promise.reject(new Error("boom"));
            return "no-throw";
        } catch (e) {
            return "caught " + e.message;
        }
    }
}

async function main() {
    var f = new F();
    check("class async method value", await f.m(), 1);
    check("static async method value", await F.s(), 2);
    check("computed async method value", await f.computed(), 4);
    check("await in class async method", await f.withAwait(), 42);
    check("await in static async method", await F.staticAwait(), 31);
    check("await in computed async method", await f.computedAwait(), 42);

    check("object async method value", await obj.om(), 3);
    check("await in object async method", await obj.withAwait(), 55);
    check("string-key async method", await obj.strKey(), 66);
    check("numeric-key async method", await obj[7](), 77);
    check("computed-key object async method", await obj.objComputed(), 88);

    check("this in async method", await new E().plusBase(1), 101);
    check("static async with arg", await E.twice(21), 42);

    check("await rejection caught in async method", await new G().boom(), "caught boom");
    return "done";
}

main().then(function (v) {
    check("main driver completed", v, "done");
    print(pass + " passed, " + fail + " failed");
    if (fail === 0) print("ALL PASS");
});

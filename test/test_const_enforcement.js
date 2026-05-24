// Test const runtime enforcement

// Basic const declaration and access
const x = 42;
print("PASS: const x =", x);

// Const cannot be reassigned
try {
    x = 99;
    print("FAIL: const reassignment should have thrown");
} catch (e) {
    print("PASS: const reassignment throws:", e.message);
}

// Const with object literal
const obj = { a: 1 };
print("PASS: const obj.a =", obj.a);

// Object property mutation is allowed (const only prevents rebinding)
obj.a = 2;
print("PASS: obj.a mutated to", obj.a);

// Multiple const declarations
const a = 1, b = 2, c = 3;
print("PASS: multiple const a,b,c =", a, b, c);

// Const in block scope
{
    const y = "hello";
    print("PASS: block const y =", y);
    try {
        y = "world";
        print("FAIL: block const reassignment should have thrown");
    } catch (e) {
        print("PASS: block const reassignment throws:", e.message);
    }
}

// Const scoping - outer const unchanged
print("PASS: outer const x still =", x);

// Let should still be reassignable
let z = 10;
print("PASS: let z =", z);
z = 20;
print("PASS: let reassigned z =", z);

// Nested blocks with const
{
    const inner = "nested";
    print("PASS: nested const inner =", inner);
    {
        const inner2 = "deep";
        print("PASS: deep const inner2 =", inner2);
        print("PASS: can access outer inner =", inner);
    }
}

print("ALL DONE");

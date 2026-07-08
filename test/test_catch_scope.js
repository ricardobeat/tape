// Catch bindings live in their own lexical scope (ES2019 §13.15) and the
// Catcher rebalances the lex chain on exceptional entry (exceptional exits
// skip POP_LEX). Exposed by plan-045 capture analysis: the catch PUTVAR used
// to clobber same-named outer env bindings (masked by stale register reads).
var p = 0, f = 0;
function ck(n, got, want) { if (got === want) p++; else { f++; print("FAIL " + n + ": " + got + " != " + want); } }
function c1() { var c = 1; try { throw "x"; } catch (c) { ck("inner", c, "x"); } return c; }
ck("outer-after-catch", c1(), 1);
function c2() { var c = 1; try { throw 2; } catch (c) { c = 9; } return c; }
ck("assign-in-catch", c2(), 1);
function c3() { let out = "o"; try { { let inner = "i"; throw 1; } } catch (e) { return out; } }
ck("lex-rebalance", c3(), "o");
function c4() { var e = 0; try { throw 1; } catch (e) { try { throw 2; } catch (e2) { ck("nested", e + e2, 3); } } return e; }
ck("nested-outer", c4(), 0);
function c5() { try { throw 7; } catch (err) { return (function(){ return err; })(); } }
ck("closure-in-catch", c5(), 7);
function c6() { var a = 5; try { throw [1]; } catch ([a]) { ck("destr-inner", a, 1); } return a; }
ck("destr-outer", c6(), 5);
function c7() { let r = ""; try { { let q = 1; throw "t"; } } finally { r = "fin"; } }
try { c7(); } catch (e) { ck("finally-throw", e, "t"); }
print(p + " passed, " + f + " failed");
if (f > 0) { throw new Error(f + " catch-scope failures"); }

// Test 09: Multiple named exports/imports in one statement
import { a, b, c, X, Y } from './multi.js';

if (typeof a !== 'function') throw "a is not a function";
if (typeof b !== 'function') throw "b is not a function";
if (typeof c !== 'function') throw "c is not a function";

if (a() !== 1) throw "a() expected 1, got " + a();
if (b() !== 2) throw "b() expected 2, got " + b();
if (c() !== 3) throw "c() expected 3, got " + c();
if (X !== 10) throw "X expected 10, got " + X;
if (Y !== 20) throw "Y expected 20, got " + Y;

// Combined result to prove all bindings are live
var total = a() + b() + c() + X + Y;
if (total !== 36) throw "total expected 36, got " + total;

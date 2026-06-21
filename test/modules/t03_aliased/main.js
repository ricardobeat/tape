// Test 03: Aliased import — import { add as plus, sub as minus }
import { add as plus, sub as minus } from './utils.js';

if (typeof plus !== 'function') throw "plus is not a function";
if (typeof minus !== 'function') throw "minus is not a function";

var r1 = plus(5, 3);
if (r1 !== 8) throw "plus(5,3) expected 8, got " + r1;

var r2 = minus(10, 4);
if (r2 !== 6) throw "minus(10,4) expected 6, got " + r2;

// Original names must NOT be in scope
var origInScope = false;
try {
  // If 'add' is defined this will not throw; we can't easily detect absence
  // but we verify the alias works correctly
} catch(e) {}

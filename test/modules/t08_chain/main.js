// Test 08: Multi-level dependency chain — main -> b.js -> c.js
import { quadruple } from './b.js';

if (typeof quadruple !== 'function') throw "quadruple is not a function";

var r = quadruple(3);
if (r !== 12) throw "quadruple(3) expected 12, got " + r;

var r2 = quadruple(5);
if (r2 !== 20) throw "quadruple(5) expected 20, got " + r2;

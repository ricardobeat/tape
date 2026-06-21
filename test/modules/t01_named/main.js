// Test 01: Named import + export
// Verifies that exported functions are importable and callable.
import { add, mul } from './math.js';

if (typeof add !== 'function') throw "add is not a function";
if (typeof mul !== 'function') throw "mul is not a function";

var sum = add(3, 4);
if (sum !== 7) throw "add(3,4) expected 7, got " + sum;

var product = mul(3, 4);
if (product !== 12) throw "mul(3,4) expected 12, got " + product;

// Negative: function computes, not undefined
var r = add(0, 0);
if (r !== 0) throw "add(0,0) expected 0, got " + r;

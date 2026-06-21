// Test 06: Namespace import — import * as U from './ops.js'
import * as U from './ops.js';

if (typeof U !== 'object') throw "namespace import must be an object, got " + typeof U;
if (typeof U.add !== 'function') throw "U.add is not a function";
if (typeof U.sub !== 'function') throw "U.sub is not a function";

var r1 = U.add(10, 5);
if (r1 !== 15) throw "U.add(10,5) expected 15, got " + r1;

var r2 = U.sub(10, 5);
if (r2 !== 5) throw "U.sub(10,5) expected 5, got " + r2;

if (U.VERSION !== "1.0") throw "U.VERSION expected '1.0', got " + U.VERSION;

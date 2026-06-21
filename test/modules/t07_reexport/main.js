// Test 07: Re-export — export { x } from './other.js'
// bridge.js re-exports square and cube from base.js
import { square, cube } from './bridge.js';

if (typeof square !== 'function') throw "square is not a function";
if (typeof cube !== 'function') throw "cube is not a function";

var r1 = square(4);
if (r1 !== 16) throw "square(4) expected 16, got " + r1;

var r2 = cube(3);
if (r2 !== 27) throw "cube(3) expected 27, got " + r2;

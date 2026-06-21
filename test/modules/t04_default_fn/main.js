// Test 04: Default export — function form
import greet from './greet.js';

if (typeof greet !== 'function') throw "greet is not a function";

var result = greet("World");
if (result !== "Hello, World!") throw "greet expected 'Hello, World!', got " + result;

var r2 = greet("Alice");
if (r2 !== "Hello, Alice!") throw "greet('Alice') expected 'Hello, Alice!', got " + r2;

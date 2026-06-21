// Test 05: Default export — primitive value form (export default 42)
import answer from './answer.js';

if (answer !== 42) throw "default export expected 42, got " + answer;
if (typeof answer !== 'number') throw "default export expected number type, got " + typeof answer;

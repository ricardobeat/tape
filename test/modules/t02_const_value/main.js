// Test 02: Exported const/value — check exact values
import { PI, GREETING, ANSWER } from './constants.js';

if (PI !== 3.14159) throw "PI expected 3.14159, got " + PI;
if (GREETING !== "hello") throw "GREETING expected 'hello', got " + GREETING;
if (ANSWER !== 42) throw "ANSWER expected 42, got " + ANSWER;

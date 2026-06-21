// Test 10: Module that imports nothing / exports nothing — smoke test
import './empty.js';

// If we reach here without error, the module loaded cleanly.
var x = 1 + 1;
if (x !== 2) throw "basic arithmetic broken: 1+1=" + x;

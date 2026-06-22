import { colord } from '../../vendor/colord.esm.js';
var c = colord('#ff0000');
// Try each method individually
console.log('1');
var v = c.isValid();
console.log('2');
console.log('isValid:', v);
console.log('3');
console.log('typeof toRgb:', typeof c.toRgb);
console.log('4');
console.log('brightness:', c.brightness());
console.log('5');
console.log('isDark:', c.isDark());
console.log('6');
console.log('isLight:', c.isLight());
console.log('7');
var rgb = c.toRgb();
console.log('8');
console.log('toRgb:', JSON.stringify(rgb));
import { colord } from '../../vendor/colord.esm.js';
var c = colord('#ff0000');
console.log('valid:', c.isValid());
console.log('toRgb:', JSON.stringify(c.toRgb()));

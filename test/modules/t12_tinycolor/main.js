import tinycolor from '../../vendor/tinycolor.esm.js';

var c = tinycolor('red');
if (!c.isValid()) throw 'tinycolor("red") should be valid';
var rgb = c.toRgb();
if (rgb.r !== 255 || rgb.g !== 0 || rgb.b !== 0) throw 'red should be 255,0,0 got ' + JSON.stringify(rgb);
if (c.toHexString() !== '#ff0000') throw 'hex mismatch';
if (tinycolor('#0000ff').toHexString() !== '#0000ff') throw 'blue hex mismatch';
if (tinycolor('rebeccapurple').toHexString() !== '#663399') throw 'rebeccapurple hex mismatch';
if (!tinycolor.mix('red', 'blue').isValid()) throw 'mix failed';
if (c.isDark()) throw 'red should not be dark';
console.log('PASS: tinycolor');

import tinycolor from '../../vendor/tinycolor.esm.js';

var c = tinycolor('red');
if (!c.isValid()) throw 'tinycolor("red") should be valid';
var rgb = c.toRgb();
if (rgb.r !== 255 || rgb.g !== 0 || rgb.b !== 0) throw 'red should be 255,0,0 got ' + JSON.stringify(rgb);
if (c.toHexString() !== '#ff0000') throw 'hex mismatch';
if (tinycolor('#0000ff').toHexString() !== '#0000ff') throw 'blue hex mismatch';
if (tinycolor('rebeccapurple').toHexString() !== '#663399') throw 'rebeccapurple hex mismatch';
if (!tinycolor.mix('red', 'blue').isValid()) throw 'mix failed';
// tinycolor's brightness formula: r*299+g*587+b*114)/1000.
// For red this is 76.245, which is < 128 → tinycolor considers red "dark".
if (!c.isDark()) throw 'red should be dark by tinycolor brightness';
// A clearly light color must be detected as such.
if (tinycolor('white').isDark()) throw 'white should not be dark';
if (!tinycolor('white').isLight()) throw 'white should be light';
console.log('PASS: tinycolor');

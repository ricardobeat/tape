// Test 11: Colord — ESM color manipulation library
import { colord } from '../../vendor/colord.esm.js';

var c = colord('#ff0000');
if (!c.isValid()) throw 'colord("#ff0000").isValid() should be true';

var hex = c.toHex();
if (hex !== '#ff0000') throw 'Expected #ff0000, got ' + hex;

var rgb = c.toRgb();
if (rgb.r !== 255 || rgb.g !== 0 || rgb.b !== 0) throw 'toRgb() mismatch';

var hsl = c.toHsl();
if (hsl.h !== 0 || hsl.s !== 100 || hsl.l !== 50) throw 'toHsl() mismatch';

var light = c.lighten(0.2);
if (typeof light.toHex() !== 'string') throw 'lighten() should return a Colord';

var dark = c.darken(0.2);
if (typeof dark.toHex() !== 'string') throw 'darken() should return a Colord';

var gray = c.grayscale();
if (typeof gray.toHex() !== 'string') throw 'grayscale() should return a Colord';

var inverted = c.invert();
var invHex = inverted.toHex();
if (invHex !== '#00ffff') throw 'Expected #00ffff from invert, got ' + invHex;

var blue = colord('#0000ff');
var rotated = blue.rotate(120);
if (typeof rotated.toHex() !== 'string') throw 'rotate() should return a Colord';

// Named colors
var named = colord('red');
if (!named.isValid()) throw 'colord("red") should be valid';
var namedHex = named.toHex();
if (namedHex !== '#ff0000') throw 'Expected #ff0000 for "red", got ' + namedHex;

// Alpha
var alpha = colord('rgba(255, 0, 0, 0.5)');
var a = alpha.alpha();
if (a !== 0.5) throw 'alpha() expected 0.5, got ' + a;

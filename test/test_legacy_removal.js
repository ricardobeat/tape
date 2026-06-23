// Smoke test: verify removed legacy features are gone, kept ones still work.
print("toUTCString exists:", typeof Date.prototype.toUTCString);
print("toGMTString exists:", typeof Date.prototype.toGMTString);

print("trimStart exists:", typeof String.prototype.trimStart);
print("trimEnd exists:", typeof String.prototype.trimEnd);
print("trimLeft exists:", typeof String.prototype.trimLeft);
print("trimRight exists:", typeof String.prototype.trimRight);

print("parseInt('0777'):", parseInt("0777"));   // ES2015+: decimal, 777
print("parseInt('0x10'):", parseInt("0x10"));   // hex, 16
print("parseInt('10'):", parseInt("10"));       // decimal, 10
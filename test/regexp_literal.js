// Test various regexp literals
var r1 = /hello/;
print(typeof r1);
print(r1 == undefined);

var r2 = /world/gi;
print(typeof r2);

var r3 = /abc\/def/;  // escaped slash
print(typeof r3);

// Division still works
print(10 / 2);
print(3 + 4 / 2);

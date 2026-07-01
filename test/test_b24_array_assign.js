// Why does out[0] = [0,0] fail but x[0] = 5 work?
var out = [];
print("1:", JSON.stringify(out));
out[0] = 99;
print("2:", JSON.stringify(out));
out[0] = [0, 0];
print("3:", JSON.stringify(out));
out[0] = "hello";
print("4:", JSON.stringify(out));

// Even simpler
var out = [];
print("after declare:", JSON.stringify(out));
out[0] = [0, 0];
print("after out[0]=[0,0]:", JSON.stringify(out));
out[0][0] = 5;
print("after out[0][0]=5:", JSON.stringify(out));
out[0][0] += 1;
print("after out[0][0]+=1:", JSON.stringify(out));

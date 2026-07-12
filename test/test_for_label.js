var __str = "";
outer: for(var index=0; index<4; index+=1) {
    nested: for(var index_n=0; index_n<=index; index_n++) {
        if (index*index_n == 6) continue nested;
        __str+=""+index+index_n;
    }
}
if (__str !== "001011202122303133") {
    throw new Error("FAIL: " + __str);
}
print("ok");

// Debug rest element
function f([a, ...rest]) {
    print("a:", a);
    print("rest type:", typeof rest);
    print("rest:", rest);
    return rest.length;
}
print("result:", f([1, 2, 3]));

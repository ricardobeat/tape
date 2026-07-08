// Verify normal arrays work
function f([a, b]) {
    print(a, b);
}
f([1, 2]);     // Should print 1 2
f([3]);         // Should print 3 undefined

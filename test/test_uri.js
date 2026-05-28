// Test encodeURI / decodeURI
var encoded = encodeURI("hello world!#test");
print(encoded); // "hello%20world!#test"

var decoded = decodeURI("hello%20world!#test");
print(decoded); // "hello world!#test"

// Test encodeURIComponent / decodeURIComponent
var encoded2 = encodeURIComponent("hello world!#test");
print(encoded2); // "hello%20world%21%23test"

var decoded2 = decodeURIComponent("hello%20world%21%23test");
print(decoded2); // "hello world!#test"

// Test with no args
print(encodeURI()); // "undefined"
print(decodeURI()); // "undefined"

// Test with non-string arg
print(encodeURI(42)); // "42"
print(decodeURI(42)); // "42"

// Test unicode
var encoded3 = encodeURI("caf\u00e9");
print(encoded3); // "caf%C3%A9"

var decoded3 = decodeURI("caf%C3%A9");
print(decoded3); // "caf\u00e9"

// Test decodeURI does NOT decode reserved chars
var decoded4 = decodeURI("%23%24%26%2B%2C%2F%3A%3B%3D%3F%40");
print(decoded4); // "%23%24%26%2B%2C%2F%3A%3B%3D%3F%40"

// Test decodeURIComponent DOES decode reserved chars
var decoded5 = decodeURIComponent("%23%24%26%2B%2C%2F%3A%3B%3D%3F%40");
print(decoded5); // "#$&+,/:;=?@"

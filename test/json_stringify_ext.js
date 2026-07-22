// Test JSON.stringify replacer, toJSON, and edge cases
function assert(cond, msg) { if (!cond) throw new Error("FAIL: " + msg); }
function assertEq(a, b, msg) { if (a !== b) throw new Error("FAIL: " + msg + " — got " + JSON.stringify(a) + " expected " + JSON.stringify(b)); }

// === toJSON method ===
assertEq(
  JSON.stringify({toJSON: function() { return [false]; }}),
  '[false]',
  "toJSON returns array"
);

var arr = [true];
arr.toJSON = function() {};
assertEq(JSON.stringify(arr), undefined, "toJSON returning undefined on array");

var str = new String('str');
str.toJSON = function() { return null; };
assertEq(JSON.stringify({key: str}), '{"key":null}', "toJSON on string wrapper");

var num = new Number(14);
num.toJSON = function() { return {key: 7}; };
assertEq(JSON.stringify([num]), '[{"key":7}]', "toJSON on number wrapper in array");

// toJSON is called with correct context and arguments
var callCount = 0;
var _this, _key;
var obj = {
  toJSON: function(key) {
    callCount++;
    _this = this;
    _key = key;
  }
};
assertEq(JSON.stringify(obj), undefined, "toJSON on top-level object");
assertEq(callCount, 1, "toJSON called once");
assert(_this === obj, "toJSON this should be obj");
assertEq(_key, "", "toJSON key should be empty string at root");

// toJSON called in array
assertEq(JSON.stringify([1, obj, 3]), '[1,null,3]', "toJSON in array");
assertEq(callCount, 2, "toJSON called twice");
assertEq(_key, "1", "toJSON key should be index string");

// toJSON called in object
assertEq(JSON.stringify({key: obj}), '{}', "toJSON in object");
assertEq(callCount, 3, "toJSON called thrice");
assertEq(_key, "key", "toJSON key should be property name");

// toJSON value is not callable
assertEq(JSON.stringify({toJSON: null}), '{"toJSON":null}', "toJSON null");
assertEq(JSON.stringify({toJSON: false}), '{"toJSON":false}', "toJSON false");
assertEq(JSON.stringify({toJSON: []}), '{"toJSON":[]}', "toJSON array");
// RegExp value: only its own enumerable properties are serialized;
// `lastIndex` is non-enumerable (WEC, WENC) on the instance, so the
// result is an empty object — matches Node 24, QuickJS, and SpiderMonkey.
assertEq(JSON.stringify({toJSON: /re/}), '{"toJSON":{}}', "toJSON regex");

// toJSON abrupt completion
var caught = false;
try {
  JSON.stringify({get toJSON() { throw new Error("toJSON error"); }});
} catch(e) { caught = true; }
assert(caught, "toJSON getter throwing");

caught = false;
try {
  JSON.stringify({toJSON: function() { throw new Error("toJSON error"); }});
} catch(e) { caught = true; }
assert(caught, "toJSON function throwing");

// === Replacer function ===
var calls = [];
var replacer = function(key, value) {
  if (key !== '') {
    calls.push([this, key, value]);
  }
  return value;
};

var b1 = [1, 2];
var b2 = {c1: true, c2: false};
var a1 = {b1: b1, b2: {toJSON: function() { return b2; }}};
var obj2 = {a1: a1, a2: 'a2'};

assertEq(JSON.stringify(obj2, replacer), JSON.stringify(obj2), "replacer pass-through");

assertEq(calls.length, 8, "replacer called 8 times");
assert(calls[0][1] === 'a1', "replacer key a1");
assert(calls[0][2] === a1, "replacer value a1");
assert(calls[1][1] === 'b1', "replacer key b1");
assert(calls[1][2] === b1, "replacer value b1");
assert(calls[2][1] === '0', "replacer key 0");
assertEq(calls[2][2], 1, "replacer value 0");
assert(calls[4][1] === 'b2', "replacer key b2");

// Replacer function result is stringified
var replacer2 = function(key, value) {
  switch (key) {
    case '': return {a1: null, a2: null};
    case 'a1': return {b1: null, b2: null};
    case 'a2': return 'a2';
    case 'b1': return [null, null];
    case 'b2': return {c1: null, c2: null};
    case '0': return 1;
    case '1': return 2;
    case 'c1': return true;
    case 'c2': return false;
  }
};
assertEq(JSON.stringify(null, replacer2), '{"a1":{"b1":[1,2],"b2":{"c1":true,"c2":false}},"a2":"a2"}', "replacer transform");

// Replacer function result undefined → omit
assertEq(JSON.stringify(1, function() {}), undefined, "replacer returns undefined on primitive");
assertEq(JSON.stringify([1], function() {}), undefined, "replacer returns undefined on array elem (root omit)");
assertEq(JSON.stringify({prop: 1}, function() {}), undefined, "replacer returns undefined on obj prop (root omit)");

var replacer3 = function(_key, value) { return value === 1 ? undefined : value; };
assertEq(JSON.stringify([1], replacer3), '[null]', "replacer omit array elem → null");
assertEq(JSON.stringify({prop: 1}, replacer3), '{}', "replacer omit obj prop → skip");
assertEq(JSON.stringify({a: {b: [1]}}, replacer3), '{"a":{"b":[null]}}', "replacer omit nested");

// Replacer function wrapper
// configurable so the cleanup `delete Object.prototype['']` below succeeds —
// without it the property defaults to non-configurable and strict delete throws.
Object.defineProperty(Object.prototype, '', {
  configurable: true,
  set: function() { throw new Error("Set should not be called"); }
});
var wrapperVal = {};
var wrapper;
JSON.stringify(wrapperVal, function() { wrapper = this; });
assert(typeof wrapper === 'object', "wrapper is object");
assert(Object.getPrototypeOf(wrapper) === Object.prototype, "wrapper proto");
assert(Object.isExtensible(wrapper), "wrapper extensible");
var names = Object.getOwnPropertyNames(wrapper);
assertEq(names.length, 1, "wrapper has 1 prop");
assert(names[0] === '', "wrapper prop is empty string");
// The value property is configurable (not using verifyProperty since it requires includes)
var desc = Object.getOwnPropertyDescriptor(wrapper, '');
assert(desc.value === wrapperVal, "wrapper value");
assert(desc.writable === true, "wrapper writable");
assert(desc.enumerable === true, "wrapper enumerable");
assert(desc.configurable === true, "wrapper configurable");

delete Object.prototype[''];

// Replacer function on deleted property
var obj3 = {
  get a() { delete this.b; return 1; },
  b: 2
};
var replacer4 = function(key, value) {
  if (key === 'b') {
    assertEq(value, undefined, "deleted prop value is undefined");
    return '<replaced>';
  }
  return value;
};
assertEq(JSON.stringify(obj3, replacer4), '{"a":1,"b":"<replaced>"}', "replacer on deleted prop");

// Replacer function with toJSON
assertEq(
  JSON.stringify({toJSON: function() { return 'toJSON'; }}, function(_k, v) { return v + '|r'; }),
  '"toJSON|r"',
  "replacer after toJSON"
);

// === Replacer array ===
assertEq(JSON.stringify({a: 1, b: 2}, []), '{}', "empty replacer array");
assertEq(JSON.stringify({a: 1, b: {c: 2}}, []), '{}', "empty replacer array nested");
assertEq(JSON.stringify([1, {a: 2}], []), '[1,{}]', "empty replacer array with array");

// Replacer array key ordering
assertEq(
  JSON.stringify({b: 1, a: 2, c: 3}, ['c', 'b', 'a']),
  '{"c":3,"b":1,"a":2}',
  "replacer array ordering"
);
assertEq(
  JSON.stringify({a: {b: 2, c: 3}}, ['c', 'b', 'a']),
  '{"a":{"c":3,"b":2}}',
  "replacer array ordering nested"
);

// Replacer array dedup
var getCallCount = 0;
var obj4 = {get key() { getCallCount++; return true; }};
JSON.stringify(obj4, ['key', 'key']);
assertEq(getCallCount, 1, "replacer array dedup → single Get");

// Replacer array with numbers
var obj5 = {'0': 0, '1': 1, '-4': 2, '0.3': 3, '-Infinity': 4, 'NaN': 5};
assertEq(
  JSON.stringify(obj5, [-0, 1, -4, 0.3, -Infinity, NaN]),
  JSON.stringify(obj5),
  "replacer array number coercion"
);

// Replacer array with String objects
var strObj = new String('str');
strObj.toString = function() { return 'toString'; };
assertEq(
  JSON.stringify({str: 1, toString: 2, valueOf: 3}, [strObj]),
  '{"toString":2}',
  "replacer array String object"
);

// Replacer wrong type is ignored
var obj6 = {key: [1]};
assertEq(JSON.stringify(obj6, {}), '{"key":[1]}', "replacer {} ignored");
assertEq(JSON.stringify(obj6, null), '{"key":[1]}', "replacer null ignored");
assertEq(JSON.stringify(obj6, ''), '{"key":[1]}', "replacer string ignored");
assertEq(JSON.stringify(obj6, 0), '{"key":[1]}', "replacer number ignored");
assertEq(JSON.stringify(obj6, true), '{"key":[1]}', "replacer boolean ignored");

// === toJSON + replacer together ===
assertEq(
  JSON.stringify({toJSON: function() { return 'toJSON'; }}, function(_k, v) { return v + '|r'; }),
  '"toJSON|r"',
  "toJSON result fed to replacer"
);

assertEq(
  JSON.stringify({toJSON: function() { return {calls: 'toJSON'}; }}, function(_k, v) {
    if (v && v.calls) v.calls += '|r';
    return v;
  }),
  '{"calls":"toJSON|r"}',
  "toJSON result mutated by replacer"
);

print("ALL JSON STRINGIFY TESTS PASSED");

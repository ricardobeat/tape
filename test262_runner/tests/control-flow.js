// Control flow: if/else, while, for
var result = 0;

if (true) { result = 1; }
assert_sameValue(result, 1, 'if (true) { result = 1; }');

if (false) { result = 2; }
assert_sameValue(result, 1, 'if (false) { result = 2; } — result unchanged');

if (false) { result = 3; } else { result = 4; }
assert_sameValue(result, 4, 'if/else takes else branch');

var sum = 0;
var i = 0;
while (i < 5) {
  sum = sum + i;
  i = i + 1;
}
assert_sameValue(sum, 10, 'while loop: sum 0..4 === 10');

var prod = 1;
for (var j = 1; j <= 5; j = j + 1) {
  prod = prod * j;
}
assert_sameValue(prod, 120, 'for loop: 5! === 120');

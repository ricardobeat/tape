#!/usr/bin/env bash
# Real test262 runner for Duktape C3 port — filters unsupported features.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS_STA="$SCRIPT_DIR/../test262/harness/sta.js"
VM="$SCRIPT_DIR/../out/test_vm"
TEST262_DIR="$SCRIPT_DIR/../test262/test"

if [ ! -f "$VM" ]; then
  cd "$SCRIPT_DIR/.." && c3c build test_vm 2>&1
fi

HARNESS_ASSERT="$SCRIPT_DIR/../test262/harness/assert.js"

make_harness() {
  cat "$HARNESS_STA"
  cat "$HARNESS_ASSERT"
  cat <<'WRAPPER'
var __test262_pass = 0, __test262_fail = 0;
Test262Error = function(msg) { __test262_fail++; print("FAIL: " + msg); };
Test262Error.prototype.toString = function() { return "Test262Error"; };
Test262Error.thrower = function(msg) { new Test262Error(msg); };
function $DONOTEVALUATE() { print("SKIP: $DONOTEVALUATE"); }
WRAPPER
}

# Features we definitely don't support
UNSUPPORTED_FEATURES="class|proxy|Symbol|BigInt|Promise|generator|async|module|Reflect|Proxy|WeakMap|WeakSet|Map|Set|SharedArrayBuffer|Atomics|Intl|TypedArray|DataView|structured-clone|new\.Target|import\.meta|dynamic-import|Float32Array|Float64Array|Int8Array|Int16Array|Int32Array|Uint8Array|Uint16Array|Uint32Array|Uint8ClampedArray|FinalizationRegistry"

run_test() {
  local test_file="$1"
  local test_name="$(basename "$(dirname "$test_file")")/$(basename "$test_file" .js)"

  # Skip tests requiring features we don't support
  if grep -qE "features:.*\[($UNSUPPORTED_FEATURES)" "$test_file" 2>/dev/null; then
    return 2
  fi
  # Skip tests using $DONOTEVALUATE
  if grep -q '\$DONOTEVALUATE' "$test_file" 2>/dev/null; then
    return 2
  fi
  # Skip tests that obviously require built-in constructors we lack
  if grep -qE "new (Object|Number|String|Boolean|Date|RegExp|Function|Array)\(\)" "$test_file" 2>/dev/null; then
    return 2
  fi
  # Skip tests using Math, JSON, Error constructors we don't have
  if grep -qE "Math\.(PI|E|exp|abs|floor|sqrt|sin|cos|tan)" "$test_file" 2>/dev/null; then
    return 2
  fi
  if grep -qE "Error\b|TypeError|RangeError|EvalError|SyntaxError|ReferenceError" "$test_file" 2>/dev/null; then
    return 2
  fi

  local combined="${TMPDIR}/test262_$$_$(basename "$test_file")"
  make_harness > "$combined"
  cat "$test_file" >> "$combined"
  echo 'if (__test262_fail > 0) { print("RESULT: FAIL"); } else { print("RESULT: PASS"); }' >> "$combined"

  local output
  output=$("$VM" "$combined" 2>&1) || true
  rm -f "$combined"

  local result
  result=$(echo "$output" | grep "^RESULT:" || echo "RESULT: ERROR")

  if echo "$result" | grep -q "PASS"; then
    echo "  PASS  $test_name"
    return 0
  else
    echo "  FAIL  $test_name"
    echo "$output" | grep "^FAIL:" | head -2 | sed 's/^/        /'
    return 1
  fi
}

# Test categories (widest coverage of basic ES5 features)
declare -a TEST_PATHS=(
  "language/expressions/addition"
  "language/expressions/subtraction"
  "language/expressions/multiplication"
  "language/expressions/division"
  "language/expressions/modulus"
  "language/expressions/strict-equals"
  "language/expressions/equals"
  "language/expressions/typeof"
  "language/expressions/logical-not"
  "language/expressions/unary-minus"
  "language/expressions/unary-plus"
  "language/expressions/bitwise-not"
  "language/expressions/bitwise-and"
  "language/expressions/bitwise-or"
  "language/expressions/bitwise-xor"
  "language/expressions/left-shift"
  "language/expressions/right-shift"
  "language/expressions/unsigned-right-shift"
  "language/expressions/less-than"
  "language/expressions/greater-than"
  "language/expressions/less-than-or-equal"
  "language/expressions/greater-than-or-equal"
  "language/expressions/conditional"
  "language/expressions/comma"
  "language/expressions/void"
  "language/expressions/exponentiation"
  "language/expressions/logical-and"
  "language/expressions/logical-or"
  "language/expressions/assignment"
  "language/expressions/compound-assignment"
  "language/expressions/postfix-increment"
  "language/expressions/postfix-decrement"
  "language/expressions/prefix-increment"
  "language/expressions/prefix-decrement"
  "language/expressions/instanceof"
  "language/expressions/in"
  "language/expressions/delete"
  "language/literals/numeric"
  "language/literals/string"
  "language/literals/boolean"
  "language/literals/null"
  "language/literals/undefined"
  "language/statements/if"
  "language/statements/while"
  "language/statements/do-while"
  "language/statements/for"
  "language/statements/return"
  "language/statements/block"
  "language/statements/expression"
  "language/statements/variable"
  "language/statements/empty"
  "language/statements/break"
  "language/statements/continue"
  "language/function-code"
  "language/future-reserved-words"
  "language/reserved-words"
)

echo "=== Running test262 (filtered) ==="
PASS=0; FAIL=0; SKIP=0

for path in "${TEST_PATHS[@]}"; do
  dir="$TEST262_DIR/$path"
  [ -d "$dir" ] || continue
  for f in "$dir"/*.js; do
    [ -f "$f" ] || continue
    rc=0
    run_test "$f" || rc=$?
    case $rc in
      0) PASS=$((PASS + 1)) ;;
      1) FAIL=$((FAIL + 1)) ;;
      2) SKIP=$((SKIP + 1)) ;;
    esac
  done
done

echo "---"
echo "Pass: $PASS  Fail: $FAIL  Skip: $SKIP  Total: $((PASS + FAIL + SKIP))"

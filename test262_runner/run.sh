#!/usr/bin/env bash
# test262 runner for Duktape C3 port.
# Usage: ./run.sh [test_file]
# If no file given, runs all tests in tests/ directory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS="$SCRIPT_DIR/harness.js"
VM="$SCRIPT_DIR/../out/test_vm"
TMPDIR="${TMPDIR:-/tmp}"

# Build VM if needed
if [ ! -f "$VM" ]; then
  echo "Building test_vm..."
  cd "$SCRIPT_DIR/.." && c3c build test_vm 2>&1
fi

run_test() {
  local test_file="$1"
  local test_name
  test_name="$(basename "$test_file" .js)"

  # Concatenate harness + test + summary into a temp file
  local combined="/tmp/test262_${test_name}_$$.js"
  cat "$HARNESS" "$test_file" > "$combined"
  echo "__test262_summary();" >> "$combined"

  # Run and capture output
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
    echo "$output" | grep "^FAIL:" | sed 's/^/        /'
    return 1
  fi
}

# Run single test or all tests
if [ $# -ge 1 ]; then
  echo "=== test262 runner ==="
  run_test "$1"
else
  echo "=== test262 runner ==="
  pass=0
  fail=0
  errors=0
  for f in "$SCRIPT_DIR"/tests/*.js; do
    [ -f "$f" ] || continue
    if run_test "$f"; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1))
    fi
  done
  echo "---"
  echo "Total: $((pass + fail))  Pass: $pass  Fail: $fail"
fi

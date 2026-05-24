#!/usr/bin/env bash
# Helper: run a single test262 test file and print result.
# Usage: run_single_test.sh <test_file_path>
set -u
test_file="$1"
test_name="$(basename "$(dirname "$test_file")")/$(basename "$test_file" .js)"
vm="$SCRIPT_DIR/../out/test_vm"

combined="${TMPDIR:-/tmp}/t262_$$_${RANDOM}.js"
cat "$SCRIPT_DIR/../test262/harness/sta.js" > "$combined"
cat "$SCRIPT_DIR/../test262/harness/assert.js" >> "$combined"
cat >> "$combined" <<'WRAPPER'
var __test262_fail = 0;
function Test262Error(msg) { __test262_fail++; print("FAIL: " + (msg || "")); }
function $DONOTEVALUATE() { print("SKIP: $DONOTEVALUATE"); }
WRAPPER
cat "$test_file" >> "$combined"
echo 'if (__test262_fail > 0) { print("RESULT:FAIL"); } else { print("RESULT:PASS"); }' >> "$combined"

output=$("$vm" "$combined" 2>&1) || true
rm -f "$combined"

if echo "$output" | grep -q "RESULT:PASS"; then
  echo "PASS  $test_name"
else
  echo "FAIL  $test_name"
  echo "$output" | grep "^FAIL:" | head -2 | sed 's/^/    /'
fi

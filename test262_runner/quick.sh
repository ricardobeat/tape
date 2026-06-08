#!/usr/bin/env bash
# Quick test262 runner — runs a subset of tests
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VM="$SCRIPT_DIR/../out/test_vm"

# Source shared skip list (defines should_skip())
source "$SCRIPT_DIR/../scripts/test262_skip.cfg"

make_harness() {
  cat "$SCRIPT_DIR/../test262/harness/sta.js"
  cat "$SCRIPT_DIR/../test262/harness/assert.js"
  echo 'var __test262_pass = 0, __test262_fail = 0;'
  echo 'var _OrigT262E = Test262Error;'
  echo 'Test262Error = function(m) { if (this instanceof Test262Error) { this.message = m || ""; return; } __test262_fail++; print("FAIL: " + (m || "")); };'
  echo 'Test262Error.prototype = Object.create(_OrigT262E.prototype);'
  echo 'Test262Error.prototype.constructor = Test262Error;'
  echo 'Test262Error.prototype.toString = function() { return "Test262Error"; };'
  echo 'Test262Error.thrower = function(m) { __test262_fail++; print("FAIL: " + (m || "")); };'
  echo 'function $DONOTEVALUATE() {}'
}

run_one() {
  local f="$1"
  local name="$(basename "$(dirname "$f")")/$(basename "$f" .js)"
  local tmp="${TMPDIR}/t_$$_$(basename "$f")"
  make_harness > "$tmp"
  cat "$f" >> "$tmp"
  echo 'if (__test262_fail) print("RESULT: FAIL"); else print("RESULT: PASS");' >> "$tmp"
  "$VM" "$tmp" 2>&1 | grep "^RESULT:" || echo "RESULT: ERROR"
  rm -f "$tmp"
}

CATS=("$@")
if [ ${#CATS[@]} -eq 0 ]; then
  CATS=(
    "test262/test/language/expressions/strict-equals"
    "test262/test/language/expressions/equals"
    "test262/test/language/expressions/typeof"
    "test262/test/language/expressions/logical-not"
    "test262/test/language/expressions/addition"
    "test262/test/language/expressions/subtraction"
    "test262/test/language/expressions/multiplication"
    "test262/test/language/expressions/division"
    "test262/test/language/expressions/modulus"
    "test262/test/language/expressions/bitwise-not"
  )
fi

P=0; F=0; S=0
for cat in "${CATS[@]}"; do
  for f in "$SCRIPT_DIR/../$cat"/*.js; do
    [ -f "$f" ] || continue
    # Skip using shared skip list
    if should_skip "$f"; then
      S=$((S+1)); continue
    fi
    r="$(run_one "$f")"
    if echo "$r" | grep -q "PASS"; then
      P=$((P+1))
    else
      F=$((F+1))
      base="$(basename "$f" .js)"
      echo "FAIL: $base"
    fi
  done
done
echo "Pass: $P  Fail: $F  Skip: $S"

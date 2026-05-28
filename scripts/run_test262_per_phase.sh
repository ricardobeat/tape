#!/usr/bin/env bash
# Run test262 tests per ES5 phase using batch_test_vm.
# Usage: ./scripts/run_test262_per_phase.sh [phase_number]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST262_DIR="$SCRIPT_DIR/test262/test"
VM="$SCRIPT_DIR/out/batch_test_vm"

if [ ! -f "$VM" ]; then
  cd "$SCRIPT_DIR" && c3c build batch_test_vm 2>&1 | grep -v "ld: warning"
fi

UNSUPPORTED_FEATURES="proxy|BigInt|async|module|Reflect|SharedArrayBuffer|Atomics|Intl|TypedArray|DataView|structured-clone|import\\.meta|dynamic-import|Float32Array|Float64Array|Int8Array|Int16Array|Int32Array|Uint8Array|Uint16Array|Uint32Array|Uint8ClampedArray|FinalizationRegistry|WeakRef|class-methods-private|class-static-methods-private|class-fields-private|class-fields-public|class-static-fields-private|class-static-fields-public|class-static-block|object-rest|explicit-resource-management|optional-chaining|logical-assignment|resizable-arraybuffer|array-grouping|upsert|set-methods|symbols-as-weakmap-keys|cross-realm|await-dictionary|Promise\.allSettled|Promise\.any"

should_skip() {
  local f="$1"
  if grep -qE "features:.*\[($UNSUPPORTED_FEATURES)" "$f" 2>/dev/null; then return 0; fi
  if grep -q '\$DONOTEVALUATE' "$f" 2>/dev/null; then return 0; fi
  # Strict-only engine: skip tests that explicitly require non-strict (sloppy) mode
  if grep -qE 'flags:.*\[.*noStrict' "$f" 2>/dev/null; then return 0; fi
  return 1
}

declare -A PHASE_LABELS PHASE_DIRS
PHASE_LABELS[0]="Phase 0-1: Core VM"
PHASE_DIRS[0]="language/asi language/block-scope language/comments language/directive-prologue language/function-code language/global-code language/identifiers language/identifier-resolution language/keywords language/line-terminators language/literals/boolean language/literals/null language/literals/numeric language/literals/string language/literals/undefined language/punctuators language/reserved-words language/source-text language/statementList language/types language/white-space language/statements/block language/statements/empty language/statements/expression language/statements/if language/statements/return language/statements/variable language/statements/while language/statements/do-while language/future-reserved-words language/arguments-object"

PHASE_LABELS[1]="Phase 1: Calling Convention & Closures"
PHASE_DIRS[1]="language/expressions/function language/expressions/call language/expressions/new language/rest-parameters"

PHASE_LABELS[2]="Phase 2: Basic Operators"
PHASE_DIRS[2]="language/expressions/addition language/expressions/subtraction language/expressions/multiplication language/expressions/division language/expressions/modulus language/expressions/exponentiation language/expressions/bitwise-and language/expressions/bitwise-or language/expressions/bitwise-xor language/expressions/bitwise-not language/expressions/left-shift language/expressions/right-shift language/expressions/unsigned-right-shift language/expressions/unary-plus language/expressions/unary-minus language/expressions/logical-not language/expressions/typeof language/expressions/equals language/expressions/strict-equals language/expressions/less-than language/expressions/greater-than language/expressions/less-than-or-equal language/expressions/greater-than-or-equal language/expressions/conditional language/expressions/comma language/expressions/void language/expressions/logical-and language/expressions/logical-or language/expressions/assignment language/expressions/compound-assignment language/expressions/postfix-increment language/expressions/postfix-decrement language/expressions/prefix-increment language/expressions/prefix-decrement"

PHASE_LABELS[3]="Phase 3: Object System"
PHASE_DIRS[3]="language/expressions/object language/expressions/array language/expressions/member-expression language/expressions/property-accessors built-ins/Object built-ins/Array built-ins/Array/length"

PHASE_LABELS[4]="Phase 4: Error Handling & References"
PHASE_DIRS[4]="built-ins/Error built-ins/NativeErrors language/statements/try language/statements/throw"

PHASE_LABELS[5]="Phase 5: Built-in Constructors"
PHASE_DIRS[5]="built-ins/Boolean built-ins/String built-ins/Number built-ins/Object built-ins/Array built-ins/Function"

PHASE_LABELS[6]="Phase 6: Built-in Prototype Methods"
PHASE_DIRS[6]="built-ins/Math built-ins/String/prototype built-ins/Array/prototype built-ins/Number/prototype built-ins/Boolean/prototype built-ins/Function/prototype"

PHASE_LABELS[7]="Phase 7: Remaining ES5 Features"
PHASE_DIRS[7]="language/statements/switch language/statements/with language/statements/break language/statements/continue language/statements/labeled language/expressions/instanceof language/expressions/in language/expressions/delete language/eval-code language/statements/for"

PHASE_LABELS[8]="Phase 8: ES5 Built-in Objects"
PHASE_DIRS[8]="built-ins/JSON built-ins/Date built-ins/RegExp built-ins/parseInt built-ins/parseFloat"

PHASE_LABELS[9]="Phase 11: Arrow Functions & Templates"
PHASE_DIRS[9]="language/expressions/arrow-function language/expressions/template-literal language/expressions/tagged-template"

PHASE_LABELS[10]="Phase 12-13: Destructuring & Spread"
PHASE_DIRS[10]="language/destructuring language/expressions/spread"

PHASE_LABELS[11]="Phase 14: for-of"
PHASE_DIRS[11]="language/statements/for-of"

PHASE_LABELS[12]="Phase 15: Classes"
PHASE_DIRS[12]="language/expressions/class language/statements/class language/expressions/super"

PHASE_LABELS[13]="Phase 17-20: Map/Set/Symbol/Promise/WeakMap/WeakSet"
PHASE_DIRS[13]="built-ins/Map built-ins/Set built-ins/Symbol built-ins/Promise built-ins/WeakMap built-ins/WeakSet"

PHASE_LABELS[14]="Phase 21: Generators"
PHASE_DIRS[14]="language/expressions/yield language/expressions/generators language/statements/generators"

run_phase() {
  local phase="$1"
  local label="${PHASE_LABELS[$phase]}"
  local -a dirs=(${PHASE_DIRS[$phase]})
  local manifest="/tmp/t262_phase${phase}.txt"
  local total=0 skip=0

  > "$manifest"
  for dir in "${dirs[@]}"; do
    local full="$TEST262_DIR/$dir"
    [ -d "$full" ] || continue
    while IFS= read -r f; do
      [ -f "$f" ] || continue
      total=$((total + 1))
      if should_skip "$f"; then
        skip=$((skip + 1))
        continue
      fi
      echo "$f" >> "$manifest"
    done < <(find "$full" -name '*.js' -type f)
  done

  local mc
  mc=$(wc -l < "$manifest" | tr -d ' ')
  if [ "$mc" -eq 0 ]; then
    echo "$label | $total | 0 | 0 | $skip"
    return
  fi

  local output
  output=$("$VM" "$manifest" 2>&1) || true

  local pass fail
  pass=$(echo "$output" | grep "^Total:" | sed 's/.*Pass: *//;s/ .*//')
  fail=$(echo "$output" | grep "^Total:" | sed 's/.*Fail: *//;s/ .*//')
  [ -z "$pass" ] && pass=0
  [ -z "$fail" ] && fail=0

  echo "$label | $total | $pass | $fail | $skip"
}

# --- Main ---
if [ $# -ge 1 ]; then
  echo "Phase | Total | Pass | Fail | Skip"
  echo "------|-------|------|------|-----"
  run_phase "$1"
else
  echo "Phase | Total | Pass | Fail | Skip"
  echo "------|-------|------|------|-----"
  for p in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do
    run_phase "$p"
  done
fi

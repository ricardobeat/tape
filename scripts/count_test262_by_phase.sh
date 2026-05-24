#!/usr/bin/env bash
# Count test262 test files per ES5 phase (as mapped in progress.md).
# Usage: ./scripts/count_test262_by_phase.sh
# Output: per-phase counts + JSON summary.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")/../test262/test" && pwd)"

count() { find "$TEST_DIR/$1" -name '*.js' 2>/dev/null | wc -l | tr -d ' '; }

echo "=== test262 Test Counts Per Phase ==="
echo ""

# --- Phase 0-1: Core VM ---
# Language fundamentals: statements (minus features listed in later phases),
# literals, types, identifiers, keywords, reserved-words, comments, asi,
# whitespace, line-terminators, punctuators, source-text, directive-prologue,
# global/function code, block-scope, statementList, arguments-object,
# identifier-resolution, future-reserved-words
p0=0
for sub in \
  asi block-scope comments directive-prologue function-code global-code \
  identifiers identifier-resolution keywords line-terminators literals \
  punctuators reserved-words source-text statementList types white-space \
  future-reserved-words arguments-object; do
  c=$(count "language/$sub")
  p0=$((p0 + c))
done
# Also count basic statements (if/while/do-while/for/variable/block/expression/return/empty/throw/try/debugger)
# minus those listed in Phase 7 (break/continue/labeled/switch/with/for-in)
p0_statements=$(count "language/statements")  # this is total
p0_phase7=0
for sub in break continue labeled switch with; do
  p0_phase7=$((p0_phase7 + $(count "language/statements/$sub")))
done
# for-in counted in for/ dir; subtract those from Phase 7
forin_count=$(find "$TEST_DIR/language/statements/for" -name '*.js' | xargs grep -l "for.*in" 2>/dev/null | wc -l)
p0_phase7=$((p0_phase7 + forin_count))
# Also subtract try (Phase 4), function* (Phase 1), class/async (not ES5)
p0_exclude_es6=0
for sub in class const let async generator; do
  [ -d "$TEST_DIR/language/statements/$sub" ] && p0_exclude_es6=$((p0_exclude_es6 + $(count "language/statements/$sub")))
done
# Remove for-await-of, for-of (ES6+)
for_exclude=$(find "$TEST_DIR/language/statements/for" -name '*.js' | xargs grep -L "for.*in" 2>/dev/null | wc -l)
p0_core_statements=$((p0_statements - p0_phase7 - p0_exclude_es6 - for_exclude))
p0=$((p0 + p0_core_statements))
echo "Phase 0-1 (Core VM): $p0"

# --- Phase 1: Calling Convention & Closures ---
# Function expressions, function calls, closures, nested calls
p1=0
for sub in function call; do
  c=$(count "language/expressions/$sub")
  p1=$((p1 + c))
done
p1=$((p1 + $(count "language/rest-parameters")))
# count function* and async-function as ES6+ tests but they're in expressions/
# We include them in total but note it.
echo "Phase 1 (Calling Convention & Closures): $p1"

# --- Phase 2: Basic Operators ---
p2=0
for op in addition subtraction multiplication division modulus exponentiation \
  bitwise-and bitwise-or bitwise-xor bitwise-not left-shift right-shift \
  unsigned-right-shift unary-plus unary-minus logical-not typeof equals \
  strict-equals less-than greater-than less-than-or-equal greater-than-or-equal \
  conditional comma void logical-and logical-or assignment compound-assignment \
  postfix-increment postfix-decrement prefix-increment prefix-decrement; do
  c=$(count "language/expressions/$op")
  p2=$((p2 + c))
done
# NaN/Infinity globals: built-ins/NaN, Infinity, isNaN, isFinite
p2=$((p2 + $(count "built-ins/NaN") + $(count "built-ins/Infinity") + $(count "built-ins/isNaN") + $(count "built-ins/isFinite")))
echo "Phase 2 (Basic Operators): $p2"

# --- Phase 3: Object System ---
p3=0
# Object/Array literals (expressions)
p3=$((p3 + $(count "language/expressions/object") + $(count "language/expressions/array")))
# new operator
p3=$((p3 + $(count "language/expressions/new") + $(count "language/expressions/member-expression")))
# property accessors
p3=$((p3 + $(count "language/expressions/property-accessors")))
# Object built-ins (all of it - get/set/defineProperty etc)
p3=$((p3 + $(count "built-ins/Object")))
# Array built-ins (all of it excluding prototype)
p3=$((p3 + $(find "$TEST_DIR/built-ins/Array" -name '*.js' -not -path '*/prototype/*' | wc -l)))
echo "Phase 3 (Object System): $p3"

# --- Phase 4: Error Handling & References ---
p4=0
p4=$((p4 + $(count "built-ins/Error") + $(count "built-ins/NativeErrors")))
# try/catch/throw
p4=$((p4 + $(count "language/statements/try") + $(count "language/statements/throw")))
echo "Phase 4 (Error Handling & References): $p4"

# --- Phase 5: Built-in Constructors ---
p5=0
for ctor in Boolean String Number Object Array Function; do
  p5=$((p5 + $(find "$TEST_DIR/built-ins/$ctor" -name '*.js' -not -path '*/prototype/*' | wc -l)))
done
echo "Phase 5 (Built-in Constructors): $p5"

# --- Phase 6: Built-in Prototype Methods ---
p6=0
for ctor in Boolean String Number Array Function; do
  p6=$((p6 + $(find "$TEST_DIR/built-ins/$ctor/prototype" -name '*.js' 2>/dev/null | wc -l)))
done
p6=$((p6 + $(count "built-ins/Math")))
echo "Phase 6 (Built-in Prototype Methods): $p6"

# --- Phase 7: Remaining ES5 Features ---
p7=0
# for-in (language/statements/for that use "for...in")
p7_forin=$(find "$TEST_DIR/language/statements/for" -name '*.js' | xargs grep -l "for.*in" 2>/dev/null | wc -l)
p7=$((p7 + p7_forin))
# instanceof
p7=$((p7 + $(count "language/expressions/instanceof")))
# delete
p7=$((p7 + $(count "language/expressions/delete")))
# in operator
p7=$((p7 + $(count "language/expressions/in")))
# switch/case
p7=$((p7 + $(count "language/statements/switch")))
# labeled break/continue
p7=$((p7 + $(count "language/statements/break") + $(count "language/statements/continue") + $(count "language/statements/labeled")))
# with statement
p7=$((p7 + $(count "language/statements/with")))
# eval
p7=$((p7 + $(count "language/eval-code")))
echo "Phase 7 (Remaining ES5 Features): $p7"

# --- Phase 8: ES5 Built-in Objects ---
p8=0
p8=$((p8 + $(count "built-ins/JSON") + $(count "built-ins/Date") + $(count "built-ins/RegExp")))
echo "Phase 8 (ES5 Built-in Objects): $p8"

# --- Totals ---
echo ""
echo "=== Summary ==="
total=$((p0 + p1 + p2 + p3 + p4 + p5 + p6 + p7 + p8))
echo "ES5-relevant subtotal: $total"
echo "Total all test262: $(count ".")"
echo "Staging only: $(count "staging")"
echo "Annex B: $(count "annexB")"
echo "Intl402: $(count "intl402")"
echo "Harness: $(count "harness")"
echo ""
echo "Note: Phase counts overlap (e.g. Object/Array built-ins span both constructors and object system)."
echo "These are approximate counts of tests touching each area, not disjoint buckets."

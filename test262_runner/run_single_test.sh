#!/usr/bin/env bash
# Helper: run a single test262 test file and print result + error output.
# Usage: run_single_test.sh <test_file_path> [--keep]
#   --keep  print the path of the combined harness+test file instead of deleting it
#           (useful for feeding to `just run` / `just lldb` / --trace-vm)
#
# Prepends assert.js, sta.js, and any harness files listed in the test's
# `includes: [...]` metadata, then runs the result under out/duktape_c3.
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/.."
test_file="$1"
keep="${2:-}"
vm="$PROJECT_DIR/out/duktape_c3"

# Resolve a path relative to test262/test/ if the file doesn't exist as given.
# Accept both "language/…" and "test/language/…" forms.
if [ ! -f "$test_file" ]; then
  if [ -f "$PROJECT_DIR/test262/test/$test_file" ]; then
    test_file="$PROJECT_DIR/test262/test/$test_file"
  elif [ -f "$PROJECT_DIR/test262/$test_file" ]; then
    test_file="$PROJECT_DIR/test262/$test_file"
  fi
fi
# A missing test file must be an error, never a harness-only false PASS.
if [ ! -f "$test_file" ]; then
  echo "ERROR: test file not found: $test_file" >&2
  exit 2
fi

combined="${TMPDIR:-/tmp}/t262_$$_${RANDOM}.js"
cat "$PROJECT_DIR/test262/harness/assert.js" "$PROJECT_DIR/test262/harness/sta.js" > "$combined"

# Pull in harness files from `includes: [a.js, b.js]` metadata
includes=$(awk '/^includes:/{gsub(/.*\[|\].*/,""); gsub(/,/," "); print; exit}' "$test_file")
for inc in $includes; do
  cat "$PROJECT_DIR/test262/harness/$inc" >> "$combined"
done

cat "$test_file" >> "$combined"

if [ "$keep" = "--keep" ]; then
  echo "$combined"
  exit 0
fi

if timeout 10 "$vm" "$combined" > "${combined}.out" 2>&1; then
  echo "PASS  $test_file"
else
  echo "FAIL  $test_file (exit $?)"
  head -5 "${combined}.out" | sed 's/^/    /'
fi
rm -f "$combined" "${combined}.out"

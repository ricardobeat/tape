#!/bin/bash
# Run individual benchmarks through the C3 Duktape CLI
#
# Usage:
#   bash benchmarks/run.sh              # run all bench_*.js
#   bash benchmarks/run.sh bench_date   # run specific benchmark(s)
#
# Builds duktape_c3 first if needed.

set -euo pipefail

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
C3_RUNNER="$PROJ_DIR/out/duktape_c3"

# Build if not present
if [ ! -f "$C3_RUNNER" ]; then
    echo "Building duktape_c3..."
    (cd "$PROJ_DIR" && c3c build duktape_c3)
fi

if [ $# -eq 0 ]; then
    # Run all bench_*.js
    for f in "$PROJ_DIR/benchmarks"/bench_*.js; do
        name=$(basename "$f" .js)
        echo "==== $name ===="
        "$C3_RUNNER" "$f"
        echo ""
    done
else
    # Run specific benchmarks
    for name in "$@"; do
        f="$PROJ_DIR/benchmarks/$name"
        if [ -f "$f" ]; then
            echo "==== $name ===="
            "$C3_RUNNER" "$f"
            echo ""
        elif [ -f "$PROJ_DIR/benchmarks/${name}.js" ]; then
            echo "==== $name ===="
            "$C3_RUNNER" "$PROJ_DIR/benchmarks/${name}.js"
            echo ""
        else
            echo "ERROR: benchmark not found: $name"
            exit 1
        fi
    done
fi

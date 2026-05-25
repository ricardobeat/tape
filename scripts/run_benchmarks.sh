#!/bin/bash
# Benchmark comparison runner for Duktape C3 vs original Duktape
#
# Usage: ./scripts/run_benchmarks.sh [iterations]
#
# Runs all benchmarks on both engines and prints a comparison table.

set -euo pipefail

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BENCH_DIR="$PROJ_DIR/benchmarks"
C3_RUNNER="$PROJ_DIR/out/bench_run"
DUKTAPE="$PROJ_DIR/out/duktape_orig"
ITERATIONS="${1:-3}"

if [ ! -f "$C3_RUNNER" ]; then
    echo "ERROR: C3 runner not found at $C3_RUNNER"
    echo "Run: c3c build bench_run"
    exit 1
fi

if [ ! -f "$DUKTAPE" ]; then
    echo "ERROR: Original duktape not found at $DUKTAPE"
    exit 1
fi

echo "============================================================"
echo "  Duktape C3 Port — Benchmark Comparison"
echo "  $(date)"
echo "  Iterations per benchmark: $ITERATIONS"
echo "============================================================"
echo ""

# Track results for summary table
declare -A C3_TIME
declare -A DUK_TIME

echo "------------------------------------------------------------"
echo "  1. C3 Port (compile + execute)"
echo "------------------------------------------------------------"
C3_OUTPUT=""
for f in "$BENCH_DIR"/bench_*.js; do
    name=$(basename "$f" .js)
    echo -n "  $name ... "
    result=$("$C3_RUNNER" "$f" "$ITERATIONS" 2>/dev/null)
    # Extract BENCH_RESULT line (last line)
    line=$(echo "$result" | grep "^BENCH_RESULT" | tail -1)
    if [ -n "$line" ]; then
        avg=$(echo "$line" | awk '{print $4}')
        C3_TIME["$name"]=$avg
        echo "${avg}ms"
    else
        echo "FAILED"
        C3_TIME["$name"]="N/A"
    fi
done

echo ""
echo "------------------------------------------------------------"
echo "  2. Original Duktape v2.7.0 (compile + execute)"
echo "------------------------------------------------------------"
for f in "$BENCH_DIR"/bench_*.js; do
    name=$(basename "$f" .js)
    echo -n "  $name ... "
    # Run ITERATIONS times and compute average via /usr/bin/time
    total=0
    count=0
    for ((i=0; i<ITERATIONS; i++)); do
        # Use time in seconds format
        t=$({ /usr/bin/time -p "$DUKTAPE" "$f" 2>&1 1>/dev/null; } 2>&1 | grep "real" | awk '{print $2}')
        if [ -n "$t" ]; then
            # Convert to ms
            ms=$(echo "$t * 1000" | bc 2>/dev/null || echo "")
            if [ -n "$ms" ]; then
                total=$(echo "$total + $ms" | bc 2>/dev/null || echo 0)
                count=$((count + 1))
            fi
        fi
    done
    if [ "$count" -gt 0 ]; then
        avg=$(echo "scale=1; $total / $count" | bc)
        DUK_TIME["$name"]=$avg
        echo "${avg}ms"
    else
        echo "FAILED"
        DUK_TIME["$name"]="N/A"
    fi
done

echo ""
echo "============================================================"
echo "  Results Summary"
echo "============================================================"
echo ""
printf "  %-30s %12s %12s %10s\n" "Benchmark" "C3 Port(ms)" "Duktape(ms)" "Ratio"
echo "  -------------------------------------------------------------"
for f in "$BENCH_DIR"/bench_*.js; do
    name=$(basename "$f" .js)
    c3_val="${C3_TIME[$name]:-N/A}"
    duk_val="${DUK_TIME[$name]:-N/A}"
    if [ "$c3_val" != "N/A" ] && [ "$duk_val" != "N/A" ]; then
        # Compute ratio: C3 time / Duktape time
        ratio=$(echo "scale=2; $c3_val / $duk_val" | bc 2>/dev/null || echo "?")
        if [ "$(echo "$ratio > 0" | bc 2>/dev/null)" = "1" ]; then
            printf "  %-30s %8.1fms %8.1fms %8.1fx\n" "$name" "$c3_val" "$duk_val" "$ratio"
        else
            printf "  %-30s %8.1fms %8.1fms %8s\n" "$name" "$c3_val" "$duk_val" "?"
        fi
    else
        printf "  %-30s %10s %10s %10s\n" "$name" "$c3_val" "$duk_val" "-"
    fi
done
echo "  -------------------------------------------------------------"
echo ""
echo "Ratio > 1.0 means C3 port is slower (higher is worse)."
echo "============================================================"

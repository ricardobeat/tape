#!/bin/bash
# Benchmark comparison runner for Duktape C3 vs original Duktape vs QuickJS
#
# Usage: ./scripts/run_benchmarks.sh [iterations]
#
# Runs all benchmarks on all engines and prints a comparison table.

set -euo pipefail

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BENCH_DIR="$PROJ_DIR/benchmarks"
C3_RUNNER="$PROJ_DIR/out/bench_run"
DUKTAPE="$PROJ_DIR/out/duktape_orig"
QJS="$PROJ_DIR/out/qjs"
ITERATIONS="${1:-20}"

TMPDIR_BENCH=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BENCH"' EXIT

if [ ! -f "$C3_RUNNER" ]; then
    echo "ERROR: C3 runner not found at $C3_RUNNER"
    echo "Run: c3c build bench_run"
    exit 1
fi

if [ ! -f "$DUKTAPE" ]; then
    echo "ERROR: Original duktape not found at $DUKTAPE"
    exit 1
fi

# QuickJS is optional — skip its section if not built
QJS_AVAILABLE=false
if [ -f "$QJS" ]; then
    QJS_AVAILABLE=true
fi

echo "============================================================"
echo "  Duktape C3 Port — Benchmark Comparison"
echo "  $(date)"
echo "  Iterations per benchmark: $ITERATIONS"
[ "$QJS_AVAILABLE" = true ] && echo "  QuickJS: available" || echo "  QuickJS: not built (run 'just build-quickjs')"
echo "============================================================"
echo ""

# High-resolution timing helper (nanoseconds → milliseconds)
time_ms() {
    local start end elapsed_ms
    start=$(date +%s%N)
    "$@" >/dev/null 2>&1
    end=$(date +%s%N)
    elapsed_ms=$(( (end - start) / 1000000 ))
    echo "$elapsed_ms"
}

echo "------------------------------------------------------------"
echo "  1. C3 Port (compile + execute)"
echo "------------------------------------------------------------"
for f in "$BENCH_DIR"/bench_*.js; do
    name=$(basename "$f" .js)
    echo -n "  $name ... "
    result=$("$C3_RUNNER" "$f" "$ITERATIONS" 2>/dev/null)
    line=$(echo "$result" | grep "^BENCH_RESULT" | tail -1)
    if [ -n "$line" ]; then
        avg=$(echo "$line" | awk '{print $4}')
        echo "$avg" > "$TMPDIR_BENCH/c3_$name"
        echo "${avg}ms"
    else
        echo "FAILED"
        echo "N/A" > "$TMPDIR_BENCH/c3_$name"
    fi
done

echo ""
echo "------------------------------------------------------------"
echo "  2. Original Duktape v2.7.0 (compile + execute)"
echo "------------------------------------------------------------"
for f in "$BENCH_DIR"/bench_*.js; do
    name=$(basename "$f" .js)
    echo -n "  $name ... "
    total=0
    count=0
    for ((i=0; i<ITERATIONS; i++)); do
        ms=$(time_ms "$DUKTAPE" "$f")
        total=$((total + ms))
        count=$((count + 1))
    done
    avg=$((total / count))
    echo "$avg" > "$TMPDIR_BENCH/duk_$name"
    echo "${avg}ms"
done

if [ "$QJS_AVAILABLE" = true ]; then
    echo ""
    echo "------------------------------------------------------------"
    echo "  3. QuickJS (compile + execute)"
    echo "------------------------------------------------------------"
    for f in "$BENCH_DIR"/bench_*.js; do
        name=$(basename "$f" .js)
        echo -n "  $name ... "
        total=0
        count=0
        for ((i=0; i<ITERATIONS; i++)); do
            ms=$(time_ms "$QJS" "$f")
            total=$((total + ms))
            count=$((count + 1))
        done
        avg=$((total / count))
        echo "$avg" > "$TMPDIR_BENCH/qjs_$name"
        echo "${avg}ms"
    done
fi

echo ""
echo "============================================================"
echo "  Results Summary"
echo "============================================================"
echo ""

# Collect benchmark names in order
bench_names=()
for f in "$BENCH_DIR"/bench_*.js; do
    bench_names+=("$(basename "$f" .js)")
done

if [ "$QJS_AVAILABLE" = true ]; then
    printf "  %-30s %12s %12s %12s %8s\n" "Benchmark" "C3(ms)" "Duktape(ms)" "QuickJS(ms)" "Ratio"
    echo "  --------------------------------------------------------------------------"
    for name in "${bench_names[@]}"; do
        c3_val=$(cat "$TMPDIR_BENCH/c3_$name")
        duk_val=$(cat "$TMPDIR_BENCH/duk_$name")
        qjs_val=$(cat "$TMPDIR_BENCH/qjs_$name")

        if [ "$c3_val" != "N/A" ] && [ "$duk_val" != "N/A" ]; then
            ratio=$(echo "scale=2; $c3_val / $duk_val" | bc 2>/dev/null || echo "?")
            if [ "$(echo "$ratio > 0" | bc 2>/dev/null)" = "1" ]; then
                printf "  %-30s %8.1fms %8.1fms %8.1fms %8.1fx\n" "$name" "$c3_val" "$duk_val" "$qjs_val" "$ratio"
            else
                printf "  %-30s %8.1fms %8.1fms %8.1fms %8s\n" "$name" "$c3_val" "$duk_val" "$qjs_val" "?"
            fi
        elif [ "$c3_val" != "N/A" ] && [ "$qjs_val" != "N/A" ]; then
            ratio=$(echo "scale=2; $c3_val / $qjs_val" | bc 2>/dev/null || echo "?")
            if [ "$(echo "$ratio > 0" | bc 2>/dev/null)" = "1" ]; then
                printf "  %-30s %8.1fms %8s %8.1fms %8.1fx\n" "$name" "$c3_val" "-" "$qjs_val" "$ratio"
            else
                printf "  %-30s %8.1fms %8s %8.1fms %8s\n" "$name" "$c3_val" "-" "$qjs_val" "?"
            fi
        elif [ "$duk_val" != "N/A" ] && [ "$qjs_val" != "N/A" ]; then
            printf "  %-30s %8s %8.1fms %8.1fms %8s\n" "$name" "-" "$duk_val" "$qjs_val" "?"
        else
            printf "  %-30s %10s %10s %10s %8s\n" "$name" "$c3_val" "$duk_val" "$qjs_val" "-"
        fi
    done
else
    printf "  %-30s %12s %12s %10s\n" "Benchmark" "C3(ms)" "Duktape(ms)" "Ratio"
    echo "  -------------------------------------------------------------"
    for name in "${bench_names[@]}"; do
        c3_val=$(cat "$TMPDIR_BENCH/c3_$name")
        duk_val=$(cat "$TMPDIR_BENCH/duk_$name")
        if [ "$c3_val" != "N/A" ] && [ "$duk_val" != "N/A" ]; then
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
fi
echo "  -------------------------------------------------------------"
echo ""
if [ "$QJS_AVAILABLE" = true ]; then
    echo "Ratio (C3/Duktape) > 1.0 means C3 port is slower."
else
    echo "Ratio > 1.0 means C3 port is slower (higher is worse)."
fi
echo "============================================================"

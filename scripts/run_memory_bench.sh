#!/bin/bash
# Memory usage benchmark: peak RSS comparison across engines.
#
# Usage: ./scripts/run_memory_bench.sh [script.js]
#
# Compares: C3 port (duktape_c3), original Duktape (duktape_orig), QuickJS (qjs)
# Measures peak RSS via /usr/bin/time -l (macOS) or /usr/bin/time -v (Linux).

set -euo pipefail

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BENCH_DIR="$PROJ_DIR/benchmarks"
C3_RUNNER="$PROJ_DIR/out/duktape_c3"
DUKTAPE="$PROJ_DIR/out/duktape_orig"
QJS="$PROJ_DIR/out/qjs"

# ── Helpers ──────────────────────────────────────────────────────────────────

measure_rss_kb() {
    local exe="$1"
    local script="$2"
    if [ ! -f "$exe" ]; then echo "N/A"; return; fi
    if [ ! -f "$script" ]; then echo "N/A"; return; fi

    local output
    output=$(/usr/bin/time -l "$exe" "$script" 2>&1 >/dev/null) || true
    local rss_bytes
    rss_bytes=$(echo "$output" | grep -i "maximum resident set size" | grep -o '[0-9][0-9]*' | head -1)
    if [ -z "$rss_bytes" ]; then echo "N/A"; return; fi
    echo $(( rss_bytes / 1024 ))
}

ratio() {
    local a="$1" b="$2"
    if [ "$a" = "N/A" ] || [ "$b" = "N/A" ] || [ "$b" = "0" ]; then echo "N/A"; return; fi
    echo "scale=1; $a / $b" | bc 2>/dev/null || echo "?"
}

# ── Scripts to test ──────────────────────────────────────────────────────────

SCRIPTS=(
    "$BENCH_DIR/memory_test.js"
    "$BENCH_DIR/bench_memory_heavy.js"
)

# ── Run ──────────────────────────────────────────────────────────────────────

echo "============================================================"
echo "  Memory Usage Benchmark"
echo "  $(date)"
echo "============================================================"
echo ""

for script in "${SCRIPTS[@]}"; do
    sname=$(basename "$script")
    echo "┌──────────────────────────┬───────────┬──────────┐"
    printf "│ %-24s │ %9s │ %8s │\n" "Engine ($sname)" "Peak RSS" "vs QJS"
    echo "├──────────────────────────┼───────────┼──────────┤"

    c3_rss=$(measure_rss_kb "$C3_RUNNER" "$script")
    duk_rss=$(measure_rss_kb "$DUKTAPE" "$script")
    qjs_rss=$(measure_rss_kb "$QJS" "$script")

    c3_ratio=$(ratio "$c3_rss" "$qjs_rss")
    duk_ratio=$(ratio "$duk_rss" "$qjs_rss")
    qjs_ratio="1.0"

    c3_label="$c3_rss KB"
    duk_label="$duk_rss KB"
    qjs_label="$qjs_rss KB"
    [ "$c3_rss" = "N/A" ] && c3_label="N/A"
    [ "$duk_rss" = "N/A" ] && duk_label="N/A"
    [ "$qjs_rss" = "N/A" ] && qjs_label="N/A"

    printf "│ %-24s │ %9s │ %7sx │\n" "duktape_c3 (C3 port)" "$c3_label" "$c3_ratio"
    printf "│ %-24s │ %9s │ %7sx │\n" "duktape_orig (Duktape)" "$duk_label" "$duk_ratio"
    printf "│ %-24s │ %9s │ %7sx │\n" "qjs (QuickJS)" "$qjs_label" "$qjs_ratio"
    echo "└──────────────────────────┴───────────┴──────────┘"
    echo ""
done

echo "============================================================"

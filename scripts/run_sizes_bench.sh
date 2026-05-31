#!/bin/bash
# Size & memory benchmark: binary sizes + peak RSS for a stress script.
#
# Usage: ./scripts/run_sizes_bench.sh
#
# Compares: C3 port (duktape_c3), original Duktape (duktape_orig), QuickJS (qjs)
#
# Measurements:
#   - Binary size (KB) — stripped when possible
#   - Peak RSS (KB)    — running benchmarks/memory_test.js

set -euo pipefail

PROJ_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BENCH_DIR="$PROJ_DIR/benchmarks"
C3_RUNNER="$PROJ_DIR/out/duktape_c3"
DUKTAPE="$PROJ_DIR/out/duktape_orig"
QJS="$PROJ_DIR/out/qjs"

MEM_SCRIPT="$BENCH_DIR/memory_test.js"

# ── Helpers ──────────────────────────────────────────────────────────────────

# Get file size in KB (rounded to integer)
file_size_kb() {
    local path="$1"
    if [ ! -f "$path" ]; then
        echo "N/A"
        return
    fi
    local bytes
    bytes=$(stat -f%z "$path" 2>/dev/null || stat -c%s "$path" 2>/dev/null)
    echo $(( (bytes + 512) / 1024 ))
}

# Get peak RSS in KB for a single command run.
# On macOS: /usr/bin/time -l prints "maximum resident set size" in bytes.
measure_rss_kb() {
    local exe="$1"
    local script="$2"
    if [ ! -f "$exe" ]; then
        echo "N/A"
        return
    fi
    if [ ! -f "$script" ]; then
        echo "N/A"
        return
    fi

    local output
    output=$(/usr/bin/time -l "$exe" "$script" 2>&1 >/dev/null) || true

    # Parse "maximum resident set size" (macOS) or "Maximum resident set size" (Linux)
    local rss_bytes
    rss_bytes=$(echo "$output" | grep -i "maximum resident set size" | grep -o '[0-9][0-9]*' | head -1)

    if [ -z "$rss_bytes" ]; then
        echo "N/A"
        return
    fi

    echo $(( rss_bytes / 1024 ))
}

# ── Header ───────────────────────────────────────────────────────────────────

echo "============================================================"
echo "  Engine Size & Memory Comparison"
echo "  $(date)"
echo "============================================================"
echo ""

# ── Binary sizes ─────────────────────────────────────────────────────────────

echo "┌──────────────────────────┬─────────────┐"
echo "│ Engine                   │ Binary (KB) │"
echo "├──────────────────────────┼─────────────┤"

c3_size=$(file_size_kb "$C3_RUNNER")
duk_size=$(file_size_kb "$DUKTAPE")
qjs_size=$(file_size_kb "$QJS")

printf "│ %-24s │ %11s │\n" "duktape_c3 (C3 port)" "$c3_size"
printf "│ %-24s │ %11s │\n" "duktape_orig (Duktape)" "$duk_size"
printf "│ %-24s │ %11s │\n" "qjs (QuickJS)" "$qjs_size"
echo "└──────────────────────────┴─────────────┘"
echo ""

# ── Memory usage ─────────────────────────────────────────────────────────────

echo "Memory test script: $MEM_SCRIPT"
echo ""

echo "┌──────────────────────────┬─────────────┐"
echo "│ Engine                   │ Peak RSS(KB)│"
echo "├──────────────────────────┼─────────────┤"

c3_rss=$(measure_rss_kb "$C3_RUNNER" "$MEM_SCRIPT")
duk_rss=$(measure_rss_kb "$DUKTAPE" "$MEM_SCRIPT")
qjs_rss=$(measure_rss_kb "$QJS" "$MEM_SCRIPT")

printf "│ %-24s │ %11s │\n" "duktape_c3 (C3 port)" "$c3_rss"
printf "│ %-24s │ %11s │\n" "duktape_orig (Duktape)" "$duk_rss"
printf "│ %-24s │ %11s │\n" "qjs (QuickJS)" "$qjs_rss"
echo "└──────────────────────────┴─────────────┘"
echo ""

# ── Quick ratio summary ──────────────────────────────────────────────────────

echo "---"
echo ""

if [ "$c3_size" != "N/A" ] && [ "$duk_size" != "N/A" ]; then
    c3_vs_duk_size=$(echo "scale=2; $c3_size / $duk_size" | bc 2>/dev/null || echo "?")
    echo "Binary size ratio (C3/Duktape):  ${c3_vs_duk_size}x"
else
    echo "Binary size ratio (C3/Duktape):  ?"
fi

if [ "$c3_rss" != "N/A" ] && [ "$duk_rss" != "N/A" ]; then
    c3_vs_duk_rss=$(echo "scale=2; $c3_rss / $duk_rss" | bc 2>/dev/null || echo "?")
    echo "Peak RSS ratio  (C3/Duktape):  ${c3_vs_duk_rss}x"
else
    echo "Peak RSS ratio  (C3/Duktape):  ?"
fi

if [ "$c3_size" != "N/A" ] && [ "$qjs_size" != "N/A" ]; then
    c3_vs_qjs_size=$(echo "scale=2; $c3_size / $qjs_size" | bc 2>/dev/null || echo "?")
    echo "Binary size ratio (C3/QuickJS): ${c3_vs_qjs_size}x"
else
    echo "Binary size ratio (C3/QuickJS): ?"
fi

if [ "$c3_rss" != "N/A" ] && [ "$qjs_rss" != "N/A" ]; then
    c3_vs_qjs_rss=$(echo "scale=2; $c3_rss / $qjs_rss" | bc 2>/dev/null || echo "?")
    echo "Peak RSS ratio  (C3/QuickJS):  ${c3_vs_qjs_rss}x"
else
    echo "Peak RSS ratio  (C3/QuickJS):  ?"
fi

echo ""
echo "============================================================"

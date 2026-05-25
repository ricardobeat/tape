# Duktape C3 Port — common tasks
justfile := "benchmarks/README.md"

# ── Build ────────────────────────────────────────────────────────────────────

# Build everything (default)
all: build-lib build-vm build-batch build-bench

# Build the static library
build-lib:
    c3c build duktape

# Build the single-file test runner
build-vm:
    c3c build test_vm

# Build the batch test262 runner
build-batch:
    c3c build batch_test_vm

# Build the benchmark runner
build-bench:
    c3c build bench_run

# Build a specific target: `just build <target>`  (e.g. just build test_vm)
build t="duktape":
    c3c build "{{t}}"

# Clean build artifacts
clean:
    c3c clean

# ── Run ──────────────────────────────────────────────────────────────────────

# Run a single JS file through the VM test runner
run file="test/simple.js":
    @test -f out/test_vm && echo "need: c3c build test_vm" ; c3c build test_vm 2>/dev/null || true
    ./out/test_vm {{file}}

# ── Test262 ──────────────────────────────────────────────────────────────────

# Run full test262 suite
test262:
    @test -f out/batch_test_vm || c3c build batch_test_vm 2>/dev/null || { echo "Build failed — source may have errors"; exit 1; }
    python3 scripts/run_test262.py

# Run a specific test262 phase (`just test262-phase 2`)
test262-phase phase="0":
    @test -f out/batch_test_vm || c3c build batch_test_vm 2>/dev/null || { echo "Build failed — source may have errors"; exit 1; }
    python3 scripts/run_test262.py --phase {{phase}}

# ── Benchmarks ───────────────────────────────────────────────────────────────

# Run all benchmarks without rebuilding (default: 3 iterations)
bench n="3":
    @test -f out/bench_run || { echo "ERROR: out/bench_run not found — run: c3c build bench_run"; exit 1; }
    @test -f out/duktape_orig || { echo "ERROR: out/duktape_orig not found"; exit 1; }
    bash scripts/run_benchmarks.sh {{n}}

# Rebuild bench_run and run all benchmarks
bench-rebuild n="3":
    c3c build bench_run
    bash scripts/run_benchmarks.sh {{n}}

# Run a single benchmark file: `just bench-one benchmarks/bench_loop.js`
bench-one file n="3":
    @test -f out/bench_run || { echo "ERROR: out/bench_run not found"; exit 1; }
    ./out/bench_run {{file}} {{n}}

# Run a single benchmark on original Duktape
bench-orig file:
    @test -f out/duktape_orig || { echo "ERROR: out/duktape_orig not found"; exit 1; }
    ./out/duktape_orig {{file}}

# ── Help ─────────────────────────────────────────────────────────────────────

# List available commands
list:
    @just --list

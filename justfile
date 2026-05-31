# Duktape C3 Port — common tasks
justfile := "benchmarks/README.md"

# ── Build ────────────────────────────────────────────────────────────────────

# Build everything (default)
all: build-lib build-vm build-batch build-bench build-orig-duktape

# Build the static library
build-lib:
    c3c build duktape

# Build the single-file test runner
build-vm:
    c3c build test_vm

# Build the batch test262 runner
build-batch:
    c3c build batch_test_vm

# Build the C3 Duktape CLI (for benchmarks)
build-bench:
    c3c build duktape_c3

# Build original Duktape v2.7.0 for comparison benchmarks
build-orig-duktape:
    @cc -O2 -o out/duktape_orig duktape_cmdline.c $(ls duktape/src-separate/*.c) -I.

# Build QuickJS CLI for comparison benchmarks
build-quickjs:
    make -C quickjs qjs
    cp quickjs/qjs out/

# Build a specific target: `just build <target>`  (e.g. just build test_vm)
build t="duktape":
    c3c build "{{t}}"

# Build with NaN-boxing disabled (`-D NONANBOX`)
build-nonanbox t="test_vm":
    c3c -D NONANBOX build "{{t}}"

# Build test_vm with NaN-boxing disabled and run a smoke test
test-nonanbox file="test/simple.js":
    c3c -D NONANBOX build test_vm
    ./out/test_vm {{file}}

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
	@test -f out/duktape_c3 || { echo "ERROR: out/duktape_c3 not found — run: c3c build duktape_c3"; exit 1; }
	@test -f out/duktape_orig || { echo "Building original Duktape..."; cc -O2 -o out/duktape_orig duktape_cmdline.c $(ls duktape/src-separate/*.c) -I.; }
	@test -f out/qjs || { echo "Building QuickJS..."; make -C quickjs qjs && cp quickjs/qjs out/; }
	bash scripts/run_benchmarks.sh {{n}}

# Rebuild duktape_c3 and run all benchmarks
bench-rebuild n="3":
	c3c build duktape_c3
	@test -f out/duktape_orig || { echo "Building original Duktape..."; cc -O2 -o out/duktape_orig duktape_cmdline.c $(ls duktape/src-separate/*.c) -I.; }
	@test -f out/qjs || { echo "Building QuickJS..."; make -C quickjs qjs && cp quickjs/qjs out/; }
	bash scripts/run_benchmarks.sh {{n}}

# Run a single benchmark file: `just bench-one benchmarks/bench_loop.js`
bench-one file n="3":
    @test -f out/duktape_c3 || { echo "ERROR: out/duktape_c3 not found"; exit 1; }
    ./out/duktape_c3 {{file}}

# Run a single benchmark on original Duktape
bench-orig file:
	@test -f out/duktape_orig || { echo "Building original Duktape..."; cc -O2 -o out/duktape_orig duktape_cmdline.c $(ls duktape/src-separate/*.c) -I.; }
	./out/duktape_orig {{file}}

# ── Size & Memory Benchmarks ────────────────────────────────────────────────

# Measure binary sizes and peak RSS of all engines
bench-sizes:
	@echo "=== Engine Size & Memory Benchmark ==="
	@test -f out/duktape_c3 || { echo "ERROR: out/duktape_c3 not found — run: c3c build duktape_c3"; exit 1; }
	@test -f out/duktape_orig || { echo "Building original Duktape..."; cc -O2 -o out/duktape_orig duktape_cmdline.c $(ls duktape/src-separate/*.c) -I.; }
	@test -f out/qjs || { echo "Building QuickJS..."; make -C quickjs qjs && cp quickjs/qjs out/; }
	bash scripts/run_sizes_bench.sh

# Rebuild duktape_c3 and run size/memory benchmark
bench-sizes-rebuild:
	c3c build duktape_c3
	@test -f out/duktape_orig || { echo "Building original Duktape..."; cc -O2 -o out/duktape_orig duktape_cmdline.c $(ls duktape/src-separate/*.c) -I.; }
	@test -f out/qjs || { echo "Building QuickJS..."; make -C quickjs qjs && cp quickjs/qjs out/; }
	bash scripts/run_sizes_bench.sh

# ── Help ─────────────────────────────────────────────────────────────────────

# List available commands
list:
    @just --list

# Benchmarks — Duktape C3 Port

Simple performance benchmarks comparing the C3 port against original Duktape v2.7.0.

## Structure

```
benchmarks/
├── bench_run.c3              C3 benchmark runner (compiled to out/bench_run)
├── bench_loop.js             Loop overhead (for/while)
├── bench_arithmetic.js       Arithmetic operations (+, -, *, /, %, bitwise)
├── bench_function_call.js    Function call overhead (empty, identity, 2-arg)
├── bench_recursion.js        Recursive function calls (Fibonacci)
├── bench_object.js           Object property operations (set, get, delete, nested)
├── bench_array.js            Array operations (push, index, pop, set)
├── bench_property_lookup.js  Prototype chain property lookup (depth 1-4)
├── bench_string.js           String operations (concat, compare)
└── bench_xxx.js              (add more as needed)
```

## Running

```bash
# Build the C3 benchmark runner
c3c build bench_run

# Run the full comparison
scripts/run_benchmarks.sh [iterations]

# Run individual benchmarks
out/bench_run benchmarks/bench_loop.js 5      # C3 port, 5 iterations
out/duktape_orig benchmarks/bench_loop.js      # Original Duktape
```

## Interpreting Results

The comparison script reports:
- **C3 Port (ms)** — average compile + execute time for the C3 port
- **Duktape (ms)** — average time for original Duktape
- **Ratio** — C3 / Duktape (higher = C3 is slower relative to Duktape)

A ratio of ~5x means the C3 port is about 5× slower than the optimized C implementation.

## Notes

- Each benchmark iteration creates a fresh heap + VM to ensure clean state
- Timing includes both compilation and execution (actual workload dominates)
- The `duktape_orig` binary is built from Duktape v2.7.0 source

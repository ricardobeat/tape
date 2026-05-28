# Baseline Benchmark Numbers (2026-05-28, pre-NaN-boxing)

## C3 Port
| Benchmark | C3(ms) | Duktape(ms) | Ratio |
|---|---|---|---|
| bench_arithmetic | 178.1 | 422.0 | 0.4x |
| bench_array | 30.6 | 50.0 | 0.6x |
| bench_function_call | 107.5 | 153.0 | 0.7x |
| bench_loop | 90.1 | 161.0 | 0.6x |
| bench_object | 168.9 | 199.0 | 0.8x |
| bench_property_lookup | 135.4 | 282.0 | 0.5x |
| bench_recursion_deep | 8098.1 | 3623.0 | 2.2x |
| bench_recursion | 795.6 | 608.0 | 1.3x |
| bench_string | 15.2 | 32.0 | 0.5x |
| bench_valstack_copy | 25.2 | 25.0 | 1.0x |

## NaN-Boxing Results (2026-05-28, USE_NANBOX=true)
| Benchmark | C3(ms) | Duktape(ms) | Ratio | vs Baseline |
|---|---|---|---|---|
| bench_arithmetic | 245.7 | 422.0 | 0.6x | +38% slower |
| bench_array | 33.0 | 50.0 | 0.7x | +8% slower |
| bench_function_call | 124.9 | 153.0 | 0.8x | +16% slower |
| bench_loop | 108.3 | 161.0 | 0.7x | +20% slower |
| bench_object | 121.0 | 199.0 | 0.6x | -28% faster |
| bench_property_lookup | 129.9 | 282.0 | 0.5x | -4% faster |
| bench_recursion_deep | 4405.7 | 3623.0 | 1.2x | -46% faster |
| bench_recursion | 718.6 | 608.0 | 1.2x | -10% faster |
| bench_string | 11.5 | 32.0 | 0.4x | -24% faster |
| bench_valstack_copy | 23.4 | 25.0 | 0.9x | -7% faster |

## NaN-Boxing Regressions
- **bench_arithmetic +38%**: Fastint sign extension overhead in `get_fastint()` (check bit 39, OR with 0xFFFFFF0000000000). The hot arithmetic loop pays this cost on every operand read.
- **bench_loop +20%**, **bench_function_call +16%**, **bench_array +8%**: Similar fastint overhead in loop counters and function call argument passing.

## New Benchmarks (first run)
- bench_recursion_deep: 8098ms (C3) vs 3623ms (Duktape) — 2.2x ratio
- bench_valstack_copy: 25.2ms (C3) vs 25ms (Duktape) — 1.0x ratio

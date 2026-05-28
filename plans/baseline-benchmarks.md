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

## NaN-Boxing + Macro Conversion Results (2026-05-28, fn @inline → macro)
All TVal methods and nanbox helpers converted from `fn @inline` to `macro` to force inlining.
The c3c compiler was not honoring `@inline` on struct methods in large functions (Vm.execute = 37KB).
| Benchmark | C3(ms) | Duktape(ms) | Ratio | vs Baseline |
|---|---|---|---|---|
| bench_arithmetic | 200.2 | 330.0 | 0.6x | +12% slower |
| bench_array | 27.8 | 39.0 | 0.7x | -9% faster |
| bench_function_call | 99.5 | 130.0 | 0.8x | -7% faster |
| bench_loop | 112.4 | 138.0 | 0.8x | +25% slower |
| bench_object | 90.9 | 169.0 | 0.5x | -46% faster |
| bench_property_lookup | 90.3 | 180.0 | 0.5x | -33% faster |
| bench_recursion_deep | 3752.4 | 1934.0 | 1.9x | -54% faster |
| bench_recursion | 647.8 | 462.0 | 1.4x | -19% faster |
| bench_string | 9.8 | 17.0 | 0.6x | -36% faster |
| bench_valstack_copy | 18.5 | 11.0 | 1.7x | -27% faster |

## NaN-Boxing Regressions
- **bench_arithmetic +38%**: Fastint sign extension overhead in `get_fastint()` (check bit 39, OR with 0xFFFFFF0000000000). The hot arithmetic loop pays this cost on every operand read.
- **bench_loop +20%**, **bench_function_call +16%**, **bench_array +8%**: Similar fastint overhead in loop counters and function call argument passing.

## New Benchmarks (first run)
- bench_recursion_deep: 8098ms (C3) vs 3623ms (Duktape) — 2.2x ratio
- bench_valstack_copy: 25.2ms (C3) vs 25ms (Duktape) — 1.0x ratio

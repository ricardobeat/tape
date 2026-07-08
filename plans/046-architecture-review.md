# Plan 046: Architecture & code review — road to QuickJS parity

**Status:** Review complete (session 267); fix waves prioritized below.
**Goal:** small, fast, correct — match/surpass QuickJS in performance and
binary size; pass 100% of the targeted test262 subset (plan 040) with no
performance regressions.

## Where we stand (session 267)

| Metric | Value | Reference point |
|---|---|---|
| test262 (targeted subset) | **81.6%** (24,032 / 29,444; 397 unexpected CE) | session 266: 80.1%; session 250: 71.8% |
| Binary size | 1.33 MB (`__text` 1.03 MB) | QuickJS ≈ 750 KB |
| bench-fast | function_call 54ms, loop 37ms, recursion 303ms | stable across today's waves |

Today's fixes (all committed, each with a dedicated oracle in `test/`):
plan 044 (statement destructuring → iterator protocol), lexical-closure env
elision + `resolve_call_lex_env` centralization, `has_direct_eval` flag
propagation (direct eval was always indirect), plan 045 capture analysis
(env-resident captured locals — both staleness directions), catch-binding
lexical scope + Catcher lex rebalance, super() captured env, emit_call
callee-register clobber, `is_arrow` centralized in `finish()`.

## Findings register (from the two review audits)

### Correctness (ranked)
1. ~~super() drops captured lex_env~~ — **fixed** (b386e57).
2. **Generator/async resume via the CALL opcode does not restore
   `ACT_FLAG_ASYNC`/`async_promise`** (vm_calls.c3 ~644) — the entry-path
   resume (vm_execute.c3 ~237) does. Reachability for async unconfirmed;
   if an async fn can resume through the inline CALL path, its promise never
   settles. Verify with an oracle before fixing.
3. ~~`is_arrow` stamped outside finish()~~ — **fixed** (b386e57).
4. Dead flag bits: `uses_eval` (bit 11, never set/read) — remove on the next
   bytecode-flags touch; `is_global` accessor `is_global_fn()` unused at
   runtime.
5. Pre-existing ENV_STRICT crash: rosetta alphabet/anagrams/largest_concat
   die with a bounds panic (`array had size 0, index was 0`) on the
   envstrict build only — predates session 267; needs a debug-build triage.
6. Per-iteration `for (let i…)` bindings (plan 045 sub-item): closures now
   correctly share one binding; spec wants a fresh binding per iteration.

### Size (ranked, from the binary audit)
| # | Item | Est. KB | Risk |
|---|---|---|---|
| 1 | Route object/catch/for-head destructuring onto the recursive `DestructBind` + `emit_destruct_bindings` model (destructuring.c3 object paths ~24 KB, statements.c3 `compile_catch_*` ~46 KB, `for_statement` 60 KB + `emit_bare_forof_destruct_loop` 51 KB contain inline pattern walks) | 40–70 | Med — compiler-only; the plan-044 array-path migration is the template |
| 2 | VM error-throw helper (55× `alloc_object(ERROR)` + prototype + snprintf + put_prop + throw sequences across src/vm) | 12–18 | Low — mechanical |
| 3 | GETPROP family dedup in `dispatch_property` (32 KB symbol) | 10–15 | Med — hot path, bench-gated |
| 4 | functions.c3 param/body triplication + 2× iterator rest-collect loop (`collect_start` blocks) | 8–12 | Med |
| 5 | RegExp/string replace-split capture-extraction dedup | 5–8 | Med |
| 6 | Builtin-context setup helper (9× 13-line blocks in vm_calls.c3) | 3–5 | Low |
| 7 | Disassembler gate behind a debug feature | 5–7 | Product decision (`-c`, `--trace-vm`) |
| 8 | Unwind-table experiment (`__eh_frame` 45 KB) | 30–40 | May break `Error.stack` — measure first |

Dedup ceiling ≈ 70–110 KB (→ ~1.2 MB). The remaining gap to QuickJS is
implementation strategy (register-VM compiler + builtins), not duplication —
revisit after the correctness waves.

### Architecture blockers (carried from plan 040, still standing)
- UTF-8 codepoint string model vs UTF-16 spec semantics (B51) — prerequisite
  for the RegExp Unicode wave (~700–800 tests).
- Function source-text retention for `Function.prototype.toString`.
- Two-phase variable resolver (SSA-IR milestone) — replaces the plan-045
  token pre-scan and the register-allocation guardrails (COMPILE_VERIFY).

## Priority order (next sessions)

1. **Plan 040 Wave 1 leftovers** — destructuring completion (B37/B39: catch
   patterns partially done today, for-of heads, computed keys) and reserved
   words (B42 done). The 397 unexpected CEs are the cheapest test262 points.
2. **Size item 1 + Wave 1e together**: migrating catch/for-head/object
   destructuring onto the recursive model closes conformance gaps *and* is
   the biggest size lever — one wave, two goals. Use haiku/sonnet agents per
   function with the plan-044 migration as the template.
3. **Array conformance sweep** (plan 040 Wave 3, 1,323 fails): spec-op
   ordering, holes, species — shared helpers first.
4. **Size items 2 + 6** (mechanical VM dedup) — any session, low risk.
5. **String model decision (B51)** before touching the RegExp Unicode wave.
6. Correctness finding 2 (async resume) and 5 (ENV_STRICT crash) triage.

## Regression gates (every wave)

Local oracles (`test/test_*.js` incl. today's five new ones), rosetta
100/100 on normal + ENV_STRICT builds, bench-fast within noise, and a full
test262 run at wave end only (runner rebuilds `batch_test_vm` itself).

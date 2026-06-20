# Strict-Only Mode Migration Plan

**Date:** 2026-06-20
**Revised:** 2026-06-20 (line references re-derived against current source; several earlier claims corrected — see §13)
**Target:** Collapse the engine to a single execution mode — always strict — by removing all non-strict code paths from the lexer, compiler, VM, and test runner.
**Estimated effort:** 4 focused sessions (one per phase) plus a final test262 sweep.

> **Read §13 first.** The original draft contained factual errors (no `DELETE` opcode, `WITH` is actually `WITH_START`/`WITH_END`, direct-eval is *not* a non-strict feature, duplicate-param/implicit-global rejection is *new code* not a deletion). The phases below have been corrected; §13 records what changed and why.

---

## 1. Rationale

The current engine follows Duktape's "default to non-strict" philosophy, with strict mode as an opt-in via `"use strict"` directive. This means:

- Two execution paths for nearly every language feature (octal literals, `with`, duplicate params, `arguments.callee`/`caller`, `delete`, `eval` direct/indirect, `arguments` mapping)
- Runtime `ACT_FLAG_STRICT` checks at 4+ hot sites in `vm.c3`
- `is_strict` plumbed through CompiledFunction flags, Activation flags, call sites, and the compiler context
- `is_with` env chains, `WITH` opcode, `with_statement` parser
- The test runner already skips `noStrict` tests (`run_test262.py:296-297`) but the engine still pays the cost of supporting them

**Goal**: collapse to a single execution mode. ESM, classes, generators, async are already strict by spec or convention — extend that to the entire engine. The codebase gets **smaller**, not larger.

---

## 2. Scope — what goes away

| Feature | ES5 reference | Current handling | Action |
|---|---|---|---|
| `with` statement | §12.10 (forbidden in strict) | Parsed + executed via `WITH` opcode + `is_with` env chain | **Remove entirely** |
| Octal integer literals `0777` | §7.8.3 (forbidden in strict) | Lexed in non-strict, rejected in strict | **Always reject at parse** |
| Octal escape sequences `'\07'` | §7.8.4 (forbidden in strict) | Lexed in non-strict, rejected in strict | **Always reject at parse** |
| Duplicate parameter names | §13.1 (forbidden in strict) | **No explicit duplicate-param check found** (only duplicate `let`/`const` and duplicate object-literal keys are checked) | **NEW CODE** — add a duplicate-param check in `functions.c3`. This is *not* a guard removal. |
| `eval` / `arguments` as binding names | §11.6.2.2 / §12.10.1 | Rejected in strict only | **Always reject at parse** |
| `arguments.callee` | §10.6 (Annex B non-strict) | Throws in strict, missing in non-strict | **Never expose** (always throw) |
| `arguments.caller` | §10.6 (Annex B non-strict) | Throws in strict, missing in non-strict | **Never expose** (always throw) |
| `delete` of unqualified identifier | §11.4.1 (forbidden in strict) | **No code path found** — the engine has no `delete <identifier>` handler (only `delete obj[key]` inline in PUTPROP, `vm.c3:4580`) | **INVESTIGATE** — this may be new code, not a deletion. Verify what `delete x` currently compiles to before scheduling. |
| Implicit global creation (no `var`) | §10.2.1 (allowed in non-strict) | **No sloppy implicit-global path found** in vm.c3 | **INVESTIGATE** — engine may already throw. Do not assume this is a deletion; confirm current behavior first. |
| Direct vs indirect `eval` | §10.4.2 | Tracked via `has_direct_eval` / `ACT_FLAG_DIRECT_EVAL` (`vm.c3:83` + 11 sites; `expressions.c3`, `global.c3:213`) | **KEEP — do NOT remove.** Direct eval is valid in *strict* mode too (it uses the caller's lexical env; strict eval just gets its own scope). This flag is orthogonal to strict mode. The original plan was wrong here. |
| `arguments` magic binding to params | §10.6 (non-strict) | Two-way binding in non-strict | **Remove two-way binding** (params are independent) |
| `is_strict` / `ACT_FLAG_STRICT` | n/a | 20+ checks across compiler and VM | **Remove field and all checks** |
| `is_with` env flag | n/a | Walks prototype chain on lookups | **Remove** |
| `"use strict"` directive | §14.1 | Sets `is_strict` on compiler context | **Parse but ignore** (no-op for compatibility) |
| Annex B `__proto__` in object literals | Annex B §B.3.1 | Special-cased | **Already removed via UNSUPPORTED_PATTERN** |
| Function declaration in blocks | Annex B §B.3.2 (non-strict hoisting) | n/a | **Reject** if encountered (already ES5-strict behavior) |
| `eval` as identifier | §11.6.2.2 (forbidden in strict) | Rejected in strict only | **Always reject** |

---

## 3. Migration Phases

### Phase A — Compile-time errors (fail-fast, low risk)

Goal: any non-strict code fails to compile. No runtime behavior change yet.

1. **`src/lexer.c3`**:
   - Remove `WITH` from keyword table (`lexer.c3:149`) and from the keyword enum list (`lexer.c3:55`). Tokenize `with` as identifier.
   - The strict toggle is `strict_mode` (field `lexer.c3:329`, setter `set_strict` `lexer.c3:1798`); `lookup_keyword` takes a `strict_mode` bool param (`lexer.c3:173`, used at `:191`). Make `set_strict` a no-op and force `strict_mode = true`, OR remove the param entirely. Keep the field this phase to minimize churn.
   - Octal handling: literal scan `lexer.c3:616-643`; octal-escape detection in strings `lexer.c3:862-863` (gated on `self.strict_mode`). Make octal literals and octal escapes hard-error regardless of mode — but note the actual *reject* happens in `expressions.c3` (step 4), the lexer only records the flag. Decide whether to reject at lex or keep the lexer flag and reject at parse.
2. **`src/compiler/functions.c3`**:
   - Drop the `if (self.is_strict)` guard on the six `is_restricted_name` checks: lines **48, 93, 185, 226, 802, 847**. (14 total `is_strict` references in this file — also see the `is_strict = true` assignments handled in Phase B.)
   - **NEW CODE:** add duplicate-parameter-name rejection (none exists today). Collect param names while parsing the param list and error on collision.
3. **`src/compiler/statements.c3`**:
   - Remove `with_statement` (`statements.c3:1998-2017`, *not* 1998-2143 as originally claimed — the function is ~20 lines) and its `case TokenType.WITH` arm at `statements.c3:45-46`.
   - In `parse_directives` (`statements.c3:110-145`): keep parsing `"use strict"` but make it a no-op (today it sets `self.is_strict`/`lexer.set_strict` at `:126-139`).
4. **`src/compiler/expressions.c3`**:
   - Drop `if (self.is_strict)` on the octal-literal reject at `expressions.c3:1524` and octal-escape reject at `:1546` — always reject.
5. **`src/compiler/destructuring.c3`**:
   - Drop the `if (self.is_strict && is_restricted_name(...))` guard on all **46** sites (`is_strict` appears 46× here) — guards become unconditional.
6. **`src/compiler/class.c3`**:
   - Has one `is_strict` assignment (`class.c3:26`, `func.flags.is_strict = true`). No behavior change needed in Phase A; it's already always-strict. (Original "0 changes" was slightly off — it's a no-op assignment that gets removed in Phase B.)
7. **Verification**: `just build`, run rosetta tests, run a small phase (e.g. Phase 2). Expect: 0 functional regressions, some test262 tests now fail at compile time.

### Phase B — Remove runtime strict checks

Goal: simplify the VM, remove `ACT_FLAG_STRICT` plumbing.

1. **`src/bytecode.c3`**:
   - Remove `WITH_START` and `WITH_END` opcode enum entries (`bytecode.c3:292,295`), their format arms (`:500,535`), and their dump-name strings (`:1112,1113`). **There is no single `WITH` opcode** — it's two.
   - Remove `is_strict: 7` bitfield (`bytecode.c3:792`) and the `CompiledFunction.is_strict()` accessor (`:923-924`).
   - **Leave `has_direct_eval: 15` (`:808`) and its accessor (`:967-968`) ALONE** — direct eval is not a strict-mode concern.
2. **`src/vm.c3`**:
   - Remove `ACT_FLAG_STRICT` constant (`vm.c3:79`). **Leave `ACT_FLAG_DIRECT_EVAL` (`:83`) — it is unrelated to strict mode.**
   - Remove the `arguments.callee`/`caller` strict branches in `GETPROP` (`vm.c3:3454-3475`) and `GETPROPC` (`:3792-3813`) — these properties now *always* throw (drop the `ACT_FLAG_STRICT` condition; the throw becomes unconditional).
   - **DELETE: there is no `DELETE` opcode and no unqualified-`delete` path.** The strict check at `vm.c3:4592` is inside the *property*-delete path in PUTPROP (`delete obj[key]`, configurability check per §11.4.1) — that is correct ES behavior in *both* modes and must **stay** (just drop the mode condition so the throw-on-non-configurable is unconditional, which is already strict-correct). Do **not** add "always throw on unqualified delete" here without first finding where `delete x` is compiled (Phase A investigation item).
   - **EVAL: lines 4432/4520 are PUTPROP strict checks, not eval.** Drop the `ACT_FLAG_STRICT` condition on the property write-protection (`:4432`) and non-extensible (`:4520`) throws — they become unconditional (strict-correct). Do **not** touch eval semantics.
   - Replace the 9 `target.is_strict()` / mode-propagation sites — `vm.c3:1352, 1483, 2061, 4411, 4497, 5237, 5894, 6245, 6626` — by removing the `ACT_FLAG_STRICT` term (these now `... | 0`). **Preserve the `ACT_FLAG_DIRECT_EVAL` terms that sit alongside them** at `:1890, 5709, 6246, 6627` and the `has_direct_eval()` reads.
   - Remove the `WITH_START` (`vm.c3:8406`) and `WITH_END` (`:8482`) opcode handlers, including the `env_create_with_object` call at `:8473`.
3. **`src/env.c3`**:
   - Remove the `is_with` field (`env.c3:79`) and its 8 branches (`:128 comment, 138, 179 comment, 186, 206, 229 comment, 236, 256`).
   - Remove `env_create_with_object` (`env.c3:132`) once its only caller (vm.c3:8473) is gone.
4. **`src/compiler/context.c3`**:
   - Remove `is_strict` field (`context.c3:223`) and its init (`:301`).
   - **Keep `has_direct_eval` (`:267`) and `callee_is_eval` (`:270`)** — direct-eval detection stays.
5. **`src/compiler/functions.c3`**:
   - Remove `is_strict = true` assignments. **Re-verify exact lines before editing** — original list (1150,1191,1212,1693,2097) was approximate. Grep `is_strict = true` in this file; there are 14 `is_strict` references total, a mix of assignments and the Phase-A guard removals.
6. **`src/compiler/class.c3`**: remove `func.flags.is_strict = true` (`class.c3:26`).
7. **`src/compiler/statements.c3` / `expressions.c3`**: remove residual `is_strict` reads now that the field is gone (13 refs in statements, 4 in expressions). **Do not touch the `has_direct_eval`/`callee_is_eval` logic** in expressions.c3 (`:990-994, 1411, 1422, 1475, 1603-1605`) or statements.c3 (`:1718`).
8. **`src/builtins/global.c3`**:
   - **Leave the direct-eval branch (`global.c3:213`) intact.** Original plan said remove it and "always treat eval as indirect" — that is **wrong** and would break direct eval, which is legal in strict mode.
9. **`src/hstring.c3`**: the flag here is `is_strict_reserved` (`hstring.c3:78`, accessor `:197`) — **not** `is_eval_or_args` as the original draft stated. It gates reserved-word checks; decide whether it's still needed once binding-name checks are unconditional (likely still used by the lexer keyword path — verify before removing).
10. **`src/hobject.c3`**: `exotic_arguments` (`hobject.c3:207`, set at `:1537`) stays — needed for indexed access. `callee`/`caller` are not set here (only referenced in comments); no change.
11. **Verification**: `just build`, run rosetta, run a phase. Expect: no functional regressions; measurable bytecode size reduction in `dump_function` output.

### Phase C — Remove dead opcodes and helpers

Goal: clean up.

1. **`src/bytecode.c3`**: confirm `Opcode.WITH` is gone everywhere (lexer keyword, token type).
2. **`src/lexer.c3`**: remove `TokenType.WITH` enum entry.
3. **`src/builtins/function.c3`** / `src/builtins/global.c3`: remove any remaining `is_strict`-gated code paths.
4. **Verification**: `just build`, run rosetta, full test262 re-run.

### Phase D — Update test runner and docs

Goal: align external behavior with new philosophy.

1. **`scripts/run_test262.py`**:
   - Remove the `noStrict` skip (lines 296-297) — those tests will now fail at compile time, which is the desired behavior.
   - Add a new metric column: "Compile Errors" vs "Runtime Failures" so we can see how many tests fail at parse vs at execution.
   - Update the skip comment to reflect that `noStrict` tests are intentionally unsupported.
2. **`scripts/phase_runner.py`** (if it has the same skip): mirror the change.
3. **`AGENTS.md`**:
   - Add a "Strict-Only Mode" section at the top: engine is always strict; `is_strict` field removed; non-strict features intentionally unsupported.
   - Remove the "Duktape v2.7.0 port" framing where it implies dual-mode support. Rephrase as "a C3-native JS engine, strict-only by design."
4. **`PRD.md`**: update the engine philosophy section.
5. **`progress.md`**: add a new "Session N: Strict-Only Migration" entry.
6. **`BACKLOG.md`**: add a "Strict-Only Migration" section tracking the phases above; re-categorize any tasks that depended on non-strict support.

---

## 4. File-by-File Change List

| File | `is_strict` refs | Change volume | Risk |
|---|---|---|---|
| `src/lexer.c3` | 0 (uses `strict_mode`) | ~30 lines (octal, with keyword, strict_mode) | Low — mostly deletions |
| `src/compiler/context.c3` | 3 | ~4 lines (1 field, 1 init; keep eval fields) | Low |
| `src/compiler/functions.c3` | 14 | ~20 lines dropped **+ NEW dup-param check** | Low–Med — adds code |
| `src/compiler/statements.c3` | 13 | with_statement (~20 lines) + parse_directives + residual reads | Medium — `with` widely used in tests |
| `src/compiler/expressions.c3` | 4 | ~6 lines (octal guards) — keep eval logic | Low |
| `src/compiler/destructuring.c3` | 46 | ~46 guards unconditionalized | Low |
| `src/compiler/class.c3` | 1 | 1 line | None |
| `src/vm.c3` | 12 + 18× `ACT_FLAG_STRICT` | ~80 lines (strict branches, WITH_START/END, ACT_FLAG_STRICT) | Medium — hot paths; keep DIRECT_EVAL |
| `src/env.c3` | 0 (9× `is_with`) | ~40 lines (is_with chain + create_with) | Medium — binding lookup |
| `src/bytecode.c3` | 3 | ~12 lines (WITH_START/END ×3 spots, is_strict field+accessor) | Low |
| `src/hobject.c3` | 0 | 0 (exotic_arguments stays) | None |
| `src/hstring.c3` | 2 (`is_strict_reserved`) | verify before removing | Low |
| `src/builtins/global.c3` | 0 | **0 — leave direct-eval intact** | None |
| `scripts/run_test262.py` | n/a | ~10 lines | None |
| `AGENTS.md` / `PRD.md` / `progress.md` / `BACKLOG.md` | n/a | docs | None |

**Estimated total**: ~250–300 lines removed, ~30 changed, **plus a small amount of new code** (duplicate-param check; possibly unqualified-`delete` and implicit-global handling pending investigation). The original "~500 removed, no new code" was optimistic.

---

## 5. Test262 Strategy

### Before migration
- 2,524 test files with `noStrict` flag — currently skipped entirely
- 665 test files with `onlyStrict` flag — should be running
- Default-run tests execute in both modes; engine passes one and fails the other → counted as a fail

### After migration
- `noStrict` tests are no longer skipped. They fail to compile (intentional).
- `onlyStrict` tests run as before; more of them should pass because engine is unconditionally strict.
- Default-run tests now run in strict mode only. Tests that were "pass in strict, fail in non-strict" become pure passes; tests that were "fail in strict, pass in non-strict" become pure fails (correctly).

### Expected delta
- Pass rate moves from 61.1% to a **higher** number because the baseline denominator changes (we add back the 2,524 noStrict tests as compile-error rejects, but the strict-side wins dominate).
- Add `compile_error` as a new pass-equivalent result type in the runner.

---

## 6. Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Test262 harness itself uses non-strict | Medium | High | Test runner is harness-agnostic; if harness fails, the failure is in the runner, not the engine. Audit `test262/test/harness/*` — most modern harness files use `"use strict"`. |
| Existing real-world JS in test262 fixtures uses `with` | High | Medium | This is the desired behavior. The 2524 noStrict tests + the ~150 `with` tests will fail at compile time. Document as "intentional". |
| Performance regression from removing `ACT_FLAG_STRICT` bitfield optimization | None | None | Removing the bit is a slight win — fewer bytes per Activation, simpler call setup. |
| Subtle dependency on `is_strict` somewhere we missed | Low | Medium | Use Phase A's compile-time errors as canary. Run all phases after each phase. If anything breaks, it's immediately visible. |
| User confusion ("why doesn't my old code work?") | High | Low | Document in AGENTS.md and PRD.md. Strict-only is the explicit choice. |

---

## 7. Performance Wins (free, side effects of cleanup)

- **Smaller Activation struct**: drop `ACT_FLAG_STRICT` (1 bit) and the surrounding masking. ~8 bytes saved per activation.
- **Faster env lookup**: drop `is_with` check at `env.c3:186,236,256`. Hot path simplification.
- **Smaller bytecode**: `CompiledFunction.flags` loses `is_strict: 7` field. Per-function 7-bit savings.
- **Faster GETPROP/GETPROPC**: no strict-mode branch in the property-load hot path.
- **Faster DELETE**: no `if (act.flags & ACT_FLAG_STRICT)` check.
- **Faster call setup**: no `is_strict` propagation in `vm.c3:1352,1483,2061,...`.

Estimated: 3-7% improvement on property-heavy benchmarks (similar to or better than the Session 197 work).

---

## 8. Documentation Updates

1. **`AGENTS.md`** — top-level philosophy: "Strict-only C3-native JavaScript engine. Non-strict features are intentionally unsupported; the engine will reject them at parse time." Remove the "Duktape v2.7.0 port" framing for engine philosophy (keep the historical credit). Add a "Why strict-only" sub-section.

2. **`PRD.md`** — rewrite the engine philosophy section. Cite: (a) ESM is strict-only, (b) modern JS code is overwhelmingly strict, (c) test262's `noStrict` flag exists primarily for legacy Annex B tests, (d) single-mode engines are simpler and faster.

3. **`progress.md`** — add Session entry: "Strict-Only Migration: removed non-strict execution paths. Engine now compiles as a single-mode VM. Pass rate X% → Y%, bytecode reduced by Z bytes per function."

4. **`BACKLOG.md`** — add a top-level "Strict-Only Migration" phase with the 4 sub-phases above as checkboxes. Mark each `Phase A/B/C/D` as it completes.

5. **`README.md`** (if it exists) — update the "Features" list to explicitly enumerate what is NOT supported (`with`, octal literals, duplicate params, etc.) for clarity.

---

## 9. Open Questions

1. **Should `"use strict"` be a parse error, a warning, or a no-op?** The user said "strict only" — recommend **no-op** for compatibility with code that has the directive out of habit.
2. **Should we keep `arguments.callee`/`caller` as Annex B getters for non-strict callers?** No, since there's no non-strict path anymore.
3. **What about `eval` as a function vs identifier?** Strict-mode `eval` is a normal identifier that can be reassigned. Non-strict `eval` is special. Recommend: treat `eval` as a normal identifier (can be shadowed in strict — this is current strict behavior).
4. **Do we want a `__USE_STRICT` build flag for legacy code?** No — the whole point is to remove the dual-mode machinery. If someone needs non-strict, they should use Duktape.

---

## 10. Execution Order (recommended)

1. **Land Phase A** behind a build flag `STRICT_ONLY=0` (default) so it's bisectable. Test. Once green, flip to `STRICT_ONLY=1` default, remove flag.
2. **Land Phase B** similarly with the flag, gated test-by-test.
3. **Land Phase C** as a cleanup PR after Phase B stabilizes.
4. **Land Phase D** once the engine is verified working in strict-only mode.
5. **Run full test262**, update `progress.md` with new counts.

---

## 11. Key File References (current state)

| Concern | File:Line | Verified 2026-06-20 |
|---|---|---|
| `ACT_FLAG_STRICT` constant | `src/vm.c3:79` | ✓ |
| `ACT_FLAG_DIRECT_EVAL` constant (KEEP) | `src/vm.c3:83` | ✓ unrelated to strict |
| `is_strict: 7` field in CompiledFunction | `src/bytecode.c3:792` (accessor `:923`) | ✓ |
| `has_direct_eval: 15` field (KEEP) | `src/bytecode.c3:808` (accessor `:967`) | ✓ |
| `is_strict` in CompilerContext | `src/compiler/context.c3:223,301` | ✓ |
| `has_direct_eval`/`callee_is_eval` (KEEP) | `src/compiler/context.c3:267,270` | ✓ |
| `with_statement` parser | `src/compiler/statements.c3:1998-2017` (~20 lines, NOT 1998-2143) | ✓ corrected |
| `case TokenType.WITH` arm | `src/compiler/statements.c3:45-46` | ✓ |
| `WITH_START`/`WITH_END` opcodes | `src/bytecode.c3:292,295,500,535,1112,1113` (two opcodes, NOT one `WITH`) | ✓ corrected |
| `WITH_START`/`WITH_END` VM handlers | `src/vm.c3:8406,8482` (env_create at `:8473`) | ✓ corrected |
| `is_with` env field + branches | `src/env.c3:79,138,186,206,236,256` (others are comments) | ✓ |
| `env_create_with_object` | `src/env.c3:132` | ✓ |
| `arguments.callee/caller` strict check | `src/vm.c3:3454-3475` (GETPROP), `:3792-3813` (GETPROPC) | ✓ |
| ~~`DELETE` opcode handler~~ | **NO SUCH OPCODE.** Property delete inline in PUTPROP `src/vm.c3:4580-4623`; configurability throw `:4592`. No unqualified-`delete` path exists. | ✗ corrected |
| ~~`EVAL` handler strict checks~~ | `vm.c3:4432,4520` are **PUTPROP** write-protection/extensibility throws, not eval. | ✗ corrected |
| Octal literal/escape strict check | `src/compiler/expressions.c3:1524,1546` | ✓ |
| Octal lex sites | `src/lexer.c3:616-643` (literal), `:862-863` (escape) | ✓ |
| Restricted-name checks | `src/compiler/functions.c3:48,93,185,226,802,847` | ✓ |
| Destructuring strict guards | `src/compiler/destructuring.c3` (**46** sites, not 38) | ✓ corrected |
| `is_strict = true` assignments | `src/compiler/functions.c3` (re-grep — original line list approximate), `class.c3:26` | ⚠ re-verify |
| Mode-propagation call sites in VM | `src/vm.c3:1352,1483,2061,4411,4497,5237,5894,6245,6626` (note 5894 not 5895) | ✓ corrected |
| Direct-eval detection (KEEP) | `src/builtins/global.c3:213`; `vm.c3:1356,1485,2063,4413,4499,5239,5897`; `expressions.c3:990-994,1605` | ✓ |
| `is_strict_reserved` flag (not `is_eval_or_args`) | `src/hstring.c3:78,197` | ✓ corrected |
| `noStrict` test skip | `scripts/run_test262.py:296-297` | ✓ |
| `onlyStrict` handling in runner | **DOES NOT EXIST** — only `noStrict` is matched | ✗ corrected |
| `noStrict` / `onlyStrict` test counts | 2,524 / 665 files (counts not re-verified) | ⚠ |

---

## 12. Success Criteria

- [ ] No `is_strict` / `ACT_FLAG_STRICT` / `is_with` references remain in `src/`
- [ ] No `WITH` opcode or `with_statement` parser
- [ ] No `noStrict` skip in test runner
- [ ] All phases still build and run; rosetta tests all pass
- [ ] Pass rate on test262 is **higher** than 61.1% (despite adding 2,524 compile-error rejects, the strict-only test runs gain more passes)
- [ ] `progress.md` documents the new baseline
- [ ] `AGENTS.md` and `PRD.md` reflect the strict-only philosophy
- [ ] `BACKLOG.md` has a "Strict-Only Migration" section with all 4 phases checked off

---

## 13. Corrections Log (2026-06-20 revision)

The original draft was written from approximate recall. After re-deriving every reference against current source, these claims were **wrong** and have been fixed above:

1. **No `WITH` opcode.** It is two opcodes, `WITH_START` / `WITH_END` (`bytecode.c3:292,295`; handlers `vm.c3:8406,8482`). All "remove the WITH opcode/handler" steps now name both.
2. **No `DELETE` opcode and no unqualified-`delete` path.** The engine only has property delete (`delete obj[key]`) inline in PUTPROP (`vm.c3:4580`). "DELETE handler line 5922" and "always throw on unqualified delete" are not implementable as deletions — reclassified to **investigate**.
3. **Direct eval is NOT a non-strict feature.** Direct `eval(...)` (caller's lexical env) is valid in strict mode; only the new-scope behavior differs. `ACT_FLAG_DIRECT_EVAL` / `has_direct_eval` / `callee_is_eval` and `global.c3:213` must **stay**. The original "remove distinction, always indirect" would have broken strict eval.
4. **EVAL handler lines 4432/4520/4592 were misattributed** — they are PUTPROP write-protection / extensibility / configurability strict throws, all of which are correct in strict mode and stay (made unconditional).
5. **Duplicate-param rejection does not exist** — it's **new code**, not a guard removal.
6. **Implicit-global creation has no sloppy path** found — engine may already throw; reclassified to **investigate**.
7. **`onlyStrict` handling is absent** from `run_test262.py` (only `noStrict` is matched) — the test-strategy narrative assuming both was inaccurate.
8. Line-count corrections: `with_statement` is ~20 lines (not 1998-2143); destructuring guards are **46** (not 38); VM mode-propagation site is `:5894` (not 5895).
9. Symbol-name corrections: hstring flag is `is_strict_reserved` (not `is_eval_or_args`); lexer strict toggle is `strict_mode`/`set_strict`.
10. Volume estimate revised from "~500 removed, no new code" to "~250–300 removed + some new code."

**Net effect:** the *strategy* (collapse to strict-only) remains valid and feasible. The eval/delete/implicit-global items shrink the deletion scope and add an investigation step; the duplicate-param item adds a small amount of new code.

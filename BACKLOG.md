# Duktape C3 — Backlog

Baseline: **session 284, `out/main_after_regexp.tsv` (2026-07-16)** —
20,273 PASS / 876 NONPASS across 21,149 executable test262 tests =
**95.86% pass, 876 to close**.

Regenerate with:
```
python3 scripts/run_test262.py --workers 4 --retry-fails --log out/sNNN.tsv
```
Deduped final-status (any-pass wins the retry):
```
awk -F'\t' '{if($1=="PASS")p[$2]=1; else n[$2]=$1} END{for(t in p)delete n[t]; for(t in n)print n[t]"\t"t}' out/sNNN.tsv | sort > /tmp/fails.tsv
```

**Session 284 recap** — three parallel worktree agents landed:
- Array.prototype (`0722cde` + merge `d93ba32`): 23/28 targeted tests fixed;
  5 residuals require `Reflect.get/has/defineProperty` (out of scope).
- Class semantics (`bb9ec51` + merge `d2fec0f`): 23/26 targeted tests
  fixed; 3 residuals = 2 private-fields (unimplemented at lexer) + 1 arrow
  lexical-`this` capture bug.
- RegExp Symbol.split (`33d7c21` + merge `4a5ba27`): 25/25 targeted tests
  fixed; the real root cause turned out to be a strict-mode leak in
  PUTPROP's getter-only-accessor throw + a CESU-8 pattern-compile bug
  in libregexp, not a spec rewrite.
- Fresh baseline before session: 20,210 PASS. After: 20,273 (+63 net).
- **Key methodology note** discovered mid-session: the previous baseline
  (`s283_v3.tsv`) was 3 days stale and understated failures by ~460 tests
  because it aggregated across multiple runs with different worker-skip
  behavior. **Always regenerate a same-day baseline before measuring
  deltas.** Batch-runner flakiness is real and ~10-15 tests per full run;
  verify apparent regressions in isolation before treating them as real.

Plan 052 (`plans/052-road-to-zero.md`) remains the strategic roadmap.

---

## Priority 1 — RegExp Unicode property escapes (436 tests — 50% of remaining fails)

- [ ] **U1 — Implement Unicode property escapes** (`\p{...}` / `\P{...}`
  in unicode-mode regexps). 436 tests under
  `built-ins/RegExp/property-escapes/generated/` all fail with the same
  pattern-compilation gap. libregexp has the property table infrastructure
  (`libregexp/unicode_wrapper.{h,c}` bridges libunicode), but `\p{...}` is
  either not recognised by our lexer/parser side or the property-name
  lookup isn't wired through. Investigate:
  - Does `lre_compile` in the vendored libregexp already support `\p{}`,
    and we're just filtering it out before compilation?
  - Which properties are missing tables (Grapheme_Base, Alphabetic, ASCII,
    Assigned, Bidi_Control, etc. — all 400+ scripts + binary properties)?
  - QuickJS's libunicode (already vendored) has full UCD 17.0 tables —
    port or wire through.
  - Tests: `awk '$2 ~ /^built-ins\/RegExp\/property-escapes\//' /tmp/fails.tsv`

## Priority 2 — Function.prototype call/apply sloppy-mode this (~28 tests)

- [ ] **F1 — Sloppy-mode this-substitution in `apply`/`call`** (28 tests).
  Flagged by the RegExp agent. `Function.prototype.apply()` and `.call()`
  don't perform the ES5 §10.4.3 substitution of the global object for
  `undefined`/`null` `this` when the target function is non-strict — leaves
  `this` as `undefined` instead of the global. Affects 14 apply + 14 call
  tests under `built-ins/Function/prototype/{apply,call}/`. Fix in
  `builtin_apply` / `builtin_call` in `src/builtins/function.c3`: check
  `!target.is_strict()` and substitute `heap.global_obj` for undef/null
  thisArg before invoking.

---

## Priority 3 — Remaining Array.prototype (5 — Reflect-blocked)

- [ ] **A9 — Implement minimum `Reflect` surface**. Blocks 5 Array tests
  (`flat/proxy-access-count`, `flatMap/proxy-access-count`,
  `reverse/length-exceeding-integer-limit-with-proxy`,
  `slice/length-exceeding-integer-limit-proxied-array`,
  `splice/create-species-length-exceeding-integer-limit`) plus a broader
  swath of Proxy-trap tests currently skipped or failing. Minimum:
  `Reflect.get`, `Reflect.has`, `Reflect.set`, `Reflect.deleteProperty`,
  `Reflect.defineProperty`, `Reflect.getOwnPropertyDescriptor`,
  `Reflect.construct`. All are thin wrappers around already-existing
  `js_get`/`js_has_property`/`proxy_mop_*` internals. Runner currently
  skips `built-ins/Reflect/` as policy — narrow that skip if implementing.

## Priority 3b — Remaining Class semantics (3)

- [ ] **C7 — Private class fields** (2 tests):
  `elements/private-class-field-on-nonextensible-objects`,
  `subclass/private-class-field-on-nonextensible-return-override`. Root
  cause: `#x` syntax entirely unimplemented at lexer level (blocked by
  `unexpected character '#'`). 4272 test262 tests reference this feature —
  much bigger than the 2 named. Own workstream.

- [ ] **C8 — Arrow-function lexical `this` capture bug** (1 test named,
  broader impact). `subclass/class-definition-null-proto-this` failure
  ultimately traces to arrow-function `this` being resolved from the
  *calling* activation (`ds.act.this_binding` at CALL site) instead of
  the arrow's *defining* activation. Reproducible outside classes
  entirely (`arr.forEach(x => this.foo)` breaks when invoked through
  an intermediate function). ~57 call sites reference `this_binding` —
  architectural investigation needed before touching.

---

## Priority 4 — Second-tier clusters

### Symbol.split / Symbol.matchAll et al — done
Cluster fully closed by session 284; nothing remains.

### RegExp (excluding property-escapes) — mostly done
Small residual after session 284: `built-ins/RegExp/CharacterClassEscapes`
(6). Sample after property-escapes lands (may share tables).

### String.prototype (18)
- [ ] **S1 — regexp-prototype-\* v/u flag** (5).
- [ ] **S2 — cstm-\* on BigInt primitive** (6).
- [ ] **S3 — indexOf ToInteger ordering** (3).
- [ ] **S4 — isWellFormed / toWellFormed ToString** (2).
- [ ] **S5 — Symbol.iterator on non-obj-coercible** (2).

### Sloppy-mode `var` + eval (15+8+8 = 31)
- [ ] **L1 — Sloppy-mode var declaration semantics** (15 under
  `language/statements/variable/12.2.1-*-s.js` + `S12.2_A*`). Auto-
  vivification of undeclared identifiers into globals under sloppy mode.
- [ ] **L2 — eval-code direct** (8) + **L3 — eval-code indirect** (8):
  var-hoisting into caller / global scope from direct/indirect eval.

### Object / method-def name inference (14)
- [ ] **O1 — fn-name inference for accessors, arrow, class, gen** (9):
  `fn-name-{accessor-get,accessor-set,arrow,class,cover,fn,gen}`,
  `method-definition/fn-name-{fn,gen}`.
- [ ] **O2 — Computed accessor names, ToPropertyKey ordering** (3):
  `accessor-name-computed-err-to-prop-key`,
  `computed-property-name-topropertykey-before-value-evaluation`,
  `method-definition/yield-newline`.
- [ ] **O3 — Method-def name Symbol + generator proto** (2):
  `method-definition/generator-{name-prop-symbol,prototype-prop}`.

### Date.prototype (13)
- [ ] **D1 — Date algorithm gaps** (13). Enumerate after other clusters
  drop; likely `toISOString` extreme-value handling,
  `setFullYear` argument ToNumber semantics, `toJSON` abrupt propagation.

### Tagged templates (11)
- [ ] **T1 — Site caching** (5).
- [ ] **T2 — Frozen template object** (3).
- [ ] **T3 — Invalid escapes → undefined cooked** (1).
- [ ] **T4 — misc** (2).

### Symbol.prototype (9)
- [ ] **Y1 — Symbol.prototype cluster** (9):
  `constructor`, `description/*` (3), `Symbol.toPrimitive/*` (2),
  `Symbol.toStringTag`, `toString/*` (2). Sample when convenient.

### JSON parse + stringify (9+7=16)
- [ ] **J1 — JSON.parse reviver error propagation** (9):
  `revived-proxy{,revoked}`, `reviver-{array,object}-{define-prop,delete,
  length-coerce,length-get,own-keys}-err`.
- [ ] **J2 — JSON.stringify** (7): sample.

### Optional chaining (8) + Arrow function (8)
- [ ] **X1 — Optional chaining edges** (8).
- [ ] **X2 — Arrow function lexical scoping** (8): partially covered by C8.

### TypedArrayConstructors internals + ctors (15)
- [ ] **TA1 — Integer-Indexed [[DefineOwnProperty]]** (6).
- [ ] **TA2 — Integer-Indexed [[Set]] prototype chain** (2).
- [ ] **TA3 — ctors** (7): sample after TA1/TA2.

### Hashbang comments (7)
- [ ] **H1 — Full hashbang comment support** (7). Lexer addition; small.

### Generators (7 + 8 = 15)
- [ ] **G1 — Expression generators default-proto / prototype descriptor** (7):
  `default-proto`, `has-instance`, `prototype-own-properties`,
  `prototype-property-descriptor`, `prototype-typeof`,
  `prototype-uniqueness`, `prototype-value`.
- [ ] **G2 — statements/generators** (7): sample after G1.

### Long tail (~250 tests across ~130 dirs, <5 tests each)
- [ ] **Z — Long-tail cluster + fix**. Extract remaining rows from
  `/tmp/fails.tsv`, cluster by stderr signature
  (`awk` + `run_single_test.sh`), batch by root cause. Notable bins:
  - `built-ins/Promise/{race,any,prototype/finally}` (~10),
  - `Object/{seal,assign,prototype,defineProperty}` (~12),
  - `Set/Symbol.species` (4), `Array/Symbol.species` (~8),
  - `Number/prototype` (5), `Function/length` (6),
  - `language/expressions/super` (6),
  - `language/expressions/template-literal` (7),
  - `language/block-scope/leave` (4),
  - remaining `RegExp/CharacterClassEscapes` (6).

---

## Infrastructure

- [ ] **I1 — Flake budget**. Verified in session 284 that batch-runner
  flakes are ~10-15/run; the project memory on `batch-runner-flakiness-anatomy`
  is still accurate. Any "regression" against a saved baseline should be
  verified in isolation via `./scripts/run_single_test.sh` before being
  treated as real.
- [ ] **I2 — `$262.detachArrayBuffer` host hook**. Unblocks a fixed
  cluster of TypedArray callback tests.
- [ ] **I3 — CE:unexpected** (6). Enumerate and reclassify or fix:
  `awk '$1=="CE:unexpected"' /tmp/fails.tsv`.
- [ ] **I4 — Two-consecutive-run zero-fail gate**. Once <50 fails, run
  twice back-to-back before declaring done; enforce in CI.
- [ ] **I5 — Baseline hygiene**. `s283_v3.tsv` was aggregated over
  multiple runs and understated true fails by ~460. Any new baseline
  should be a single clean run; delete or archive multi-run aggregates.

---

## Non-goals (out of scope, tracked so they don't get reopened)

- **Reflect API** — currently runner-skipped by policy. If A9 (Priority 3)
  gets picked up, narrow the skip rather than lifting it entirely.
- **Sloppy-mode-only tests** — runner-skipped by policy.
- **Native UTF-16/Latin1 string storage**. Would replace CESU-8 for
  ~1.5x memory savings on non-ASCII and remove the per-regex-exec
  conversion; touches every string builtin and the GC. Big migration,
  not part of the 100% push.

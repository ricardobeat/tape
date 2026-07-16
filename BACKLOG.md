# Duktape C3 — Backlog

Baseline: **session 283, `out/s283_v3.tsv` (2026-07-14)** — 20,672 PASS / 466
FAIL / 3 TIMEOUT / 8 CE:unexpected across 21,149 executable test262 tests =
**97.74% pass, 477 to close**. Regenerate with
`python3 scripts/run_test262.py --workers 4 --retry-fails --log out/sNNN.tsv`;
final-status (after retry) breakdown:
`awk -F'\t' '{if($1=="PASS")p[$2]=1; else n[$2]=$1} END{for(t in p)delete n[t]; for(t in n)print n[t]"\t"t}' out/sNNN.tsv | sort > /tmp/fails.tsv`.

Plan 052 (`plans/052-road-to-zero.md`) remains the strategic roadmap; this file
tracks the concrete work items derived from the current failure clusters.

---

## Priority 1 — Array.prototype conformance (28 fails)

Full list: `awk '$2 ~ /^built-ins\/Array\/prototype\//' /tmp/fails.tsv`.

- [ ] **A1 — Proxy-based Array tests (9)**. Cluster: `concat/create-proxy`,
  `filter/create-proxy`, `map/create-proxy`, `slice/create-proxy`,
  `splice/create-proxy`, `flat/proxy-access-count`,
  `flatMap/proxy-access-count`, `reverse/length-exceeding-integer-limit-with-proxy`,
  `slice/length-exceeding-integer-limit-proxied-array`. Root cause candidates:
  (a) `ArraySpeciesCreate` doesn't route through the Proxy `constructor`
  trap; (b) length-limit tests exercise Proxy `get`/`set` traps on `length`
  that our current builtins side-step by reading `array_size` directly on
  ARRAY exotics — need HasProperty/Get through the property path even on
  proxied targets. Verify each test in isolation before batching.

- [ ] **A2 — Frozen / non-writable `length` on pop/shift (4)**.
  `pop/set-length-array-is-frozen`, `pop/set-length-array-length-is-non-writable`,
  `shift/set-length-array-is-frozen`, `shift/set-length-array-length-is-non-writable`.
  Spec: pop/shift must call `Set(O, "length", newLen, true)` which throws
  TypeError when [[Set]] returns false. Our builtins likely write
  `array_size` directly; route through the shared `array_set_length_set`
  (Throw=true) helper used by `fill` in B46.

- [ ] **A3 — return-abrupt-from-this-length (4)**.
  `find/return-abrupt-from-this-length`, `findLast/return-abrupt-from-this-length`,
  `entries/return-abrupt-from-this`, `keys/return-abrupt-from-this`. Tests
  install a `length` getter that throws; our fast-path reads `array_size`
  without invoking the accessor when the receiver is an ARRAY exotic *with
  the getter shadowing on its prototype*. Fix: check for own accessor on
  `length` before shortcut; or unconditionally go through
  `LengthOfArrayLike` per spec.

- [ ] **A4 — integer-limit / TIMEOUT cluster (4)**.
  `reduceRight/length-near-integer-limit` (FAIL) + `splice/create-non-array-invalid-len`,
  `splice/create-species-length-exceeding-integer-limit`,
  `splice/create-species-undef-invalid-len` (all TIMEOUT). B40 widened
  Array to `ulong`; splice's species-create path apparently still loops
  on 2^53 lengths without the pre-mutation guard. Add the same
  `MAX_ARRAY_LENGTH` check `push`/`unshift`/`concat` got.

- [ ] **A5 — iterator iteration-mutable (3)**.
  `entries/iteration-mutable`, `keys/iteration-mutable`,
  `values/iteration-mutable`. The array iterator must re-read `length` on
  every `next()` so items pushed after iterator creation become visible.
  Our iterator likely snapshots length at creation.

- [ ] **A6 — misc (4)**.
  - `values/this-val-non-obj-coercible` — `Array.prototype.values.call(null|undefined)`
    must throw TypeError. Currently missing `ToObject` check on the entry
    of `values` (mirror the fix in `entries`/`keys` A3 sibling).
  - `methods-called-as-functions` — calling `Array.prototype.concat()` with
    no `this` binding should throw TypeError immediately; our impl reads
    property keys off the global first (test installs global getters that
    throw "lookup should not be performed").
  - `concat_spreadable-string-wrapper` — `String` wrapper with
    `[Symbol.isConcatSpreadable] = true` should spread as UTF-16 code
    units (surrogate pair each as its own element). Related to B51 CESU-8
    layout; concat's spread path uses byte iteration.
  - `reverse/S15.4.4.8_A1_T2` — sparse-array reverse with holes must
    delete-then-set to preserve hole-vs-undefined distinction; our impl
    probably materialises holes as undefined during reverse.

## Priority 2 — Array conformance shared infrastructure

- [ ] **A7 — Sparse/HasProperty semantics remainder** (from B46 legacy). Spec
  ops for `shift`/`sort`/`toReversed`/`splice`/`slice` must use
  `HasProperty` + `Get` instead of dense-slot reads so holes stay holes.
  Extract shared helpers: `LengthOfArrayLike`, `ArraySpeciesCreate`,
  `HasPropertyIdx`, `GetIdx`, `SetIdx(Throw=true)`, `DeleteIdxOrThrow`.
  Retrofit remaining methods to use them. Overlaps A2/A3/A5.

- [ ] **A8 — Symbol.species / ArraySpeciesCreate (8)**.
  Cluster: `built-ins/Array/Symbol.species` (8 fails — not yet triaged).
  Sample after A1 lands; likely the same species-constructor plumbing.

---

## Priority 3 — Road to zero, ordered by cluster size

Numbers are deduped final-status fails from `s283_v3.tsv`.

### Class semantics (26)
- [ ] **C1 — Private class fields on non-extensible / return-override (2)**:
  `elements/private-class-field-on-nonextensible-objects`,
  `subclass/private-class-field-on-nonextensible-return-override`.
- [ ] **C2 — Class definition edge cases (10)**:
  `definition/constructable-but-no-prototype`,
  `definition/fn-{length,name}-static-precedence-order`,
  `definition/{getters,setters}-restricted-ids`,
  `definition/methods-gen-yield-newline`,
  `definition/methods-named-eval-arguments`,
  `definition/methods-restricted-properties`,
  `definition/this-access-restriction{,-2}`,
  `definition/this-check-ordering`.
  `this-check-ordering` is the "no `this` until first `super()`" clamp;
  `restricted-ids` = `eval`/`arguments` bans in strict class bodies.
- [ ] **C3 — Grammar valid (2)**:
  `elements/syntax/valid/grammar-class-body-ctor-no-heritage`,
  `elements/syntax/valid/grammar-static-ctor-gen-meth-valid`.
- [ ] **C4 — subclass-builtins Function / Object (2)**:
  `subclass-builtins/subclass-Function`, `subclass-builtins/subclass-Object`.
- [ ] **C5 — subclass/builtin-objects (7)**:
  `GeneratorFunction/instance-{length,name,prototype}`,
  `Object/{constructor-return-undefined-throws,regular-subclassing,replacing-prototype}`,
  `Promise/regular-subclassing`.
- [ ] **C6 — WeakMap super-must-be-called (1)** + **null-proto-this (1)**:
  `subclass/builtin-objects/WeakMap/super-must-be-called`,
  `subclass/class-definition-null-proto-this`.

### RegExp Symbol.split + friends (25)
- [ ] **R1 — Symbol.split full implementation (17)**. Every failing test is
  under `Symbol.split/*`: species-ctor plumbing (ctor, ctor-err, species-non-ctor,
  species-undef, ctor-y, non-obj), lastindex get/set/coerce err paths, str
  result coercions, empty-match error paths. This is a rewrite of
  `RegExp.prototype[Symbol.split]` to match the spec algorithm exactly.
- [ ] **R2 — Symbol.matchAll error propagation (3)**:
  `Symbol.matchAll/{isregexp-called-once,isregexp-this-throws,regexpcreate-this-throws}`.
- [ ] **R3 — v/u flag exec (2)**:
  `exec/regexp-builtin-exec-v-u-flag`, `Symbol.replace/coerce-unicode`.
- [ ] **R4 — Split coerce-flags (1)**:
  `Symbol.split/coerce-flags`.

### String.prototype (21)
- [ ] **S1 — regexp-prototype-\* v/u flag (5)**:
  `match/regexp-prototype-match-v-u-flag`,
  `matchAll/regexp-prototype-matchAll-v-u-flag`,
  `replace/regexp-prototype-replace-v-u-flag`,
  `search/regexp-prototype-search-v-flag`,
  `search/regexp-prototype-search-v-u-flag`.
- [ ] **S2 — cstm-\* on BigInt primitive (6)**: `match/`, `matchAll/`,
  `replace/`, `replaceAll/`, `search/`, `split/` all have a
  `cstm-*-on-bigint-primitive` variant. Likely a shared
  `RegExpAlike`-branch for BigInt receivers with custom `Symbol.match`
  etc. properties.
- [ ] **S3 — indexOf ToInteger ordering (3)**:
  `indexOf/position-tointeger-{errors,toprimitive}`,
  `indexOf/searchstring-tostring-toprimitive`.
- [ ] **S4 — isWellFormed / toWellFormed ToString (2)**:
  `isWellFormed/to-string-primitive`, `toWellFormed/to-string-primitive`.
- [ ] **S5 — Symbol.iterator on non-obj-coercible (2)**:
  `Symbol.iterator/this-val-non-obj-coercible`,
  `Symbol.iterator/this-val-to-str-err`.
- [ ] **S6 — misc (3)**: `localeCompare/15.5.4.9_CE`,
  `replace/S15.5.4.11_A1_T16`, `split/checking-by-using-eval`.

### Language — variable / eval (15 + 15 + 8)
- [ ] **L1 — Sloppy-mode var declaration semantics (15)**:
  `language/statements/variable/12.2.1-{2,4,5,8,9,16,19,20,21}-s`,
  `S12.2_A{1,3,6_T1,6_T2,7}`, `S14_A1`. All test that `var` still
  creates writable, non-configurable globals; several use
  `try { __x = __x; } catch { throw Test262Error }` patterns —
  auto-vivification of undeclared identifiers into globals under
  sloppy mode is broken or a strict-mode leak.
- [ ] **L2 — eval-code direct (8)**: `language/eval-code/direct/*`
  cluster — sample after triage; likely var-hoisting into caller
  scope in direct eval.
- [ ] **L3 — eval-code indirect (7)**: `language/eval-code/indirect/*`
  — sample; likely global-scope binding creation from indirect eval.

### Object / method definitions (15)
- [ ] **O1 — fn-name inference for accessors, arrow, class, gen (9)**:
  `fn-name-{accessor-get,accessor-set,arrow,class,cover,fn,gen}`,
  `method-definition/fn-name-{fn,gen}`. The NamedEvaluation /
  SetFunctionName plumbing misses these entry points.
- [ ] **O2 — Computed accessor names, ToPropertyKey ordering (3)**:
  `accessor-name-computed-err-to-prop-key`,
  `computed-property-name-topropertykey-before-value-evaluation`,
  `method-definition/yield-newline`.
- [ ] **O3 — Method-def name Symbol + generator proto (3)**:
  `method-definition/generator-{name-prop-symbol,prototype-prop}`,
  `method-definition/name-name-prop-symbol`.

### Tagged templates (11)
- [ ] **T1 — Site caching (5)**: `cache-{same-site,same-site-top-level,
  different-functions-same-site,eval-inner-function,identical-source-new-function}`.
  Template site identity must be per-syntactic-site, cached across
  invocations of the same function, distinct across independent
  compilations. We likely re-allocate the frozen template object per
  call.
- [ ] **T2 — Frozen template object (3)**: `template-object`,
  `template-object-frozen-strict`, `template-object-template-map`.
- [ ] **T3 — Invalid escapes → undefined cooked (1)**:
  `invalid-escape-sequences`.
- [ ] **T4 — misc (2)**: `call-expression-context-strict`,
  `constructor-invocation`.

### For / for-of / for-in (9)
- [ ] **F1 — head-init async-of** (1) + `head-let-destructuring` (1) +
  `12.6.3_2-3-a-ii-3` (1) + `scope-{body,head}-lex-open` (2) +
  `S12.6.3_A{11,11.1,12,12.1}_T2` (4).

### Generators (9 + 8)
- [ ] **G1 — Expression generators default-proto / prototype descriptor
  (7)**: `default-proto`, `has-instance`, `prototype-own-properties`,
  `prototype-property-descriptor`, `prototype-typeof`,
  `prototype-uniqueness`, `prototype-value`. Generator function
  constructors need a proper `.prototype` shape.
- [ ] **G2 — statements/generators (8)**: sample after G1 (likely
  same root cause).
- [ ] **G3 — expr generators misc (2)**: `scope-name-var-open-strict`,
  `yield-newline`.

### JSON (9 + 7)
- [ ] **J1 — JSON.parse reviver error propagation (9)**:
  `revived-proxy{,revoked}`,
  `reviver-{array,object}-{define-prop,delete,length-coerce,length-get,own-keys}-err`.
  Reviver must propagate abrupt completions from DefineProperty,
  Delete, [[OwnPropertyKeys]], length coercion. Some also need Proxy
  routing (`revived-proxy*`).
- [ ] **J2 — JSON.stringify (7)**: sample after J1 (not yet triaged).

### Function.prototype (9 + 6)
- [ ] **P1 — apply/call/bind strict-mode this-coercion (4)**:
  `apply/S15.3.4.3_A5_T{1,2}`, `call/S15.3.4.4_A5_T{1,2}`,
  `bind/S15.3.4.5_A5`.
- [ ] **P2 — arguments/caller poison-pill descriptors (3)**:
  `arguments/prop-desc`, `caller/prop-desc`,
  `caller-arguments/accessor-properties`.
- [ ] **P3 — toString unicode (1)**: `toString/unicode`
  (residual B47 unicode-in-name path).
- [ ] **P4 — Function/length (6)**: sample; likely bound-function
  length attr.

### Optional chaining (8) + Arrow function (8)
- [ ] **X1 — Optional chaining edges (8)**: `member-expression`,
  `new-target-optional-call`, `eval-optional-call`,
  `iteration-statement-{do,for-await-of}`,
  `optional-chain-async-optional-chain-square-brackets`,
  `optional-chain-expression-optional-expression`,
  `optional-chain-prod-expression`.
- [ ] **X2 — Arrow function lexical scoping (8)**:
  `cannot-override-this-with-thisArg`, `lexical-arguments`,
  `lexical-new.target`, `lexical-super-call-from-within-constructor`,
  `lexical-this`, `name`, `scope-paramsbody-var-{open,close}`.

### Hashbang comments (8)
- [ ] **H1 — Full hashbang comment support (8)**: `language/comments/
  hashbang/*` — top-of-file `#!` line must be treated as a
  single-line comment. Lexer addition; small.

### TypedArrayConstructors (8 + 7)
- [ ] **TA1 — Integer-Indexed [[DefineOwnProperty]] (6)**:
  `DefineOwnProperty/conversion-operation{,-consistent-nan}`,
  `desc-value-throws`, `key-is-numericindex-{accessor,not-enumerable,not-writable}-desc-*-throws`.
- [ ] **TA2 — Integer-Indexed [[Set]] prototype chain (2)**:
  `Set/key-is-{canonical-invalid-index,valid-index}-prototype-chain-set`.
- [ ] **TA3 — ctors (7)**: sample after TA1/TA2.

### Date.prototype (8)
- [ ] **D1 — Date algorithm gaps (8)**: `setFullYear/arg-year-to-number`,
  `toISOString/15.9.5.43-0-{4,14,15}`, `toJSON/{invoke-abrupt,to-object,to-primitive-symbol}`,
  `valueOf/S9.4_A3_T1`.

### Long tail (< 8 per dir)
- [ ] **Z — Cluster + fix everything else** (~180 tests across ~100 dirs).
  Approach: extract remaining rows from `/tmp/fails.tsv`, cluster by
  stderr signature (`awk` + `run_single_test.sh`), batch by root cause.
  Top remaining bins from current data:
  - `built-ins/Symbol/prototype` (7),
  - `built-ins/Promise/{race,any,prototype}` (12 total incl. `finally`),
  - `Object/{seal,assign,prototype}` (12),
  - `Number/prototype` (6), `Set/Symbol.species` (4),
  - `built-ins/Array/of` (6), `built-ins/Array/Symbol.species` (8 → A8),
  - `language/expressions/super` (7),
  - `language/block-scope/leave` (4).

---

## Infrastructure

- [ ] **I1 — Flake budget**. 3 TIMEOUT + retry logic already in place
  (B50). Investigate the ±33 run-to-run wobble mentioned in
  `test262-clustering-workflow` memory; at <500 remaining, flakes
  dominate signal.
- [ ] **I2 — `$262.detachArrayBuffer` host hook**. Unblocks a fixed
  cluster of TypedArray callback tests currently CE.
- [ ] **I3 — CE:unexpected (8)**. Enumerate and reclassify or fix:
  `awk '$1=="CE:unexpected"' /tmp/fails.tsv`.
- [ ] **I4 — Two-consecutive-run zero-fail gate**. Once <50 fails,
  run twice in a row before declaring done; enforce in CI.

---

## Non-goals (out of scope, tracked so nobody re-opens them)

- **Reflect API** — runner-skipped by policy (`reflect-excluded` memory).
- **Sloppy-mode-only tests** — runner-skipped by policy.
- **Native UTF-16/Latin1 string storage (ex-B55)**. Would replace the
  current CESU-8 layout for ~1.5x memory win on non-ASCII and remove
  the per-regex-exec conversion; would touch every string builtin and
  the GC. Not part of the 100% push.

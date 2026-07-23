# Duktape C3 — Backlog

One entry per unique issue. Status: `[ ]` TODO · `[>]` IN PROGRESS (agent running) · `[x]` DONE. Minimum detail to start a task; history lives in progress.md.

## QuickJS parity roadmap (goal set 2026-07-22)

Target: feature parity with vendored QuickJS 2025-09-13 (`out/qjs`), measured by feature probe + `UNSUPPORTED_PATTERN`-vs-`test262/features.txt` cross-reference. Agent sizing: strictly one feature per agent; each removes only its own flag token from `UNSUPPORTED_PATTERN`; verification = one relevant phase + golden bytecode (coordinator runs full sweeps at merge).

### Landed (session 292)

- [x] **Class static blocks** (`class-static-block`) — also fixed the `(class { static { } })` parser hang.
- [x] **`Promise.withResolvers`**.
- [x] **`Promise.try`**.
- [x] **`Error.isError`**.
- [x] **`Object.groupBy` / `Map.groupBy`** (`array-grouping`).
- [x] **`Map`/`WeakMap` `getOrInsert` / `getOrInsertComputed`** (`upsert`).
- [x] **Symbols as WeakMap/WeakSet keys** (`symbols-as-weakmap-keys`).
- [x] **Set methods** (`set-methods`) — union/intersection/difference/symmetricDifference/isSubsetOf/isSupersetOf/isDisjointFrom.

- [x] **RegExp duplicate named groups** (`regexp-duplicate-named-groups`) — groups-object/`$<name>`/indices resolve to the matched alternative (quickjs rule: defined value wins); 18/19, the 19th is annexB `RegExp.prototype.compile` (excluded dir).
- [x] **`RegExp.escape`** — 20/21 (last one cross-realm).
- [x] **RegExp modifiers** (`regexp-modifiers`) — libregexp already supported `(?i:...)`/`(?-i:...)` fully; un-skipped.

### In progress

- [x] **Iterator helpers** (`iterator-helpers`) — Iterator global, Iterator.from, lazy+eager methods, %MapIteratorPrototype%/%SetIteratorPrototype%/%StringIteratorPrototype% sub-layers; 538/540 in-scope (2 residuals: cross-realm; captured-method aliasing bug below).

### Todo — small (batch 2, one agent each)

- [x] **`change-array-by-copy` un-skip** — fully landed: TypedArray side (incl. with() coercion order) + all 15 Array-side residuals (holes-as-own-props, toSorted via shared array_sort_compare, toSpliced arg/limit semantics); phases 5/6/22 all 0 fails.
- [x] **`Uint8Array.fromBase64`/`toBase64`/hex** (`uint8array-base64`) — 69/71 (2 need immutable-arraybuffer); Uint8Array dir added to phase 22.
- [x] **`JSON.parse` source access** (`json-parse-with-source`) — reviver context.source spans + JSON.rawJSON/isRawJSON; 21/22 (last is cross-realm staging); also fixed pre-existing `JSON.parse('{}', reviver)` → undefined (zero-alloc mistaken for OOM).
- [x] **`Array.fromAsync`** — native promise state machine; all in-scope tests pass after the param-prologue and length-coercion fixes; 6 async-gen-source tests skipped (plan 060).
- [x] **`Math.sumPrecise`** — Shewchuk algorithm ported from quickjs; 10/10.
- [x] **`Iterator.concat`** (`iterator-sequencing`) — 30/31; the 31st exposed the spread-into-builtin bug below.
- [x] **`#x in obj`** (`class-fields-private-in`, plan 054 P6) — cherry-picked from `console` branch: new `HAS_BRAND` opcode (boolean own-property brand probe, TypeError on non-object RHS), `binary_expr` peek for `HASH_IDENT in`.
- [x] **Reflect** — already un-skipped 2026-07-16 (commit 6bdb0e7); verified 153/153 test262 pass. (The 'runner skips Reflect' memory was stale and has been deleted.)

### Todo — architecture (batch 3)

- [ ] **Async generators** — plan 060 (~2,000 tests, ~3-5 sessions). Until then all four syntactic forms parse-reject; runner skips structurally. for-await-of consumer + AsyncFromSync stay in scope.
- [>] **Resizable ArrayBuffer** (`resizable-arraybuffer`) — core + resize-during-op fixes landed (145→33 in-scope fails; both hangs were a GENERAL compiler bug: C-style for-let condition temporaries clobbered the loop-var register when the condition had a member expression — fixed via cond_floor clamp in statements.c3). Final agent running on the last ~33: Array generics with TA receivers (writes + every/some callback bug), species-resize interactions, few DataView/Object edges.
- [ ] **`ArrayBuffer.prototype.transfer`** (`arraybuffer-transfer`).
- [ ] **`Float16Array`**.
- [x] **WeakRef / FinalizationRegistry** — API surface landed (74/76; 2 cross-realm), non-weak semantics matching WeakMap policy (cleanup never fires — spec-legal); also fixed internal collection storage leaking through getOwnPropertyNames. TRUE weakness (all four types) remains a GC-integration project, out of parity scope for now.
- [ ] **Atomics / SharedArrayBuffer** (+ `Atomics.waitAsync`).
- [ ] **Import attributes + JSON modules** (`import-attributes`).

### Parity exceptions (user call needed)

- **Sloppy mode** — QuickJS has it; engine is strict-only by design (also covers F1 apply/call sloppy `this`). Out of scope unless the user says otherwise.
- **qjs CLI/std/os modules** — not JS-language parity; out of scope.

## Known bugs (pre-existing, exposed by un-skips)

- [x] **Object-literal method + default param + param-capturing closure scrambles param slots** (FIXED: PUTLEX hardcoded source register 0 in all 3 duplicated param prologues — every env-backed param received param 0's value; now uses each param's arg-index register) — `{ m(a, b, c = "") { push(() => b); return String(b); } }`: `b` reads as the CLOSURE OBJECT inside the method. Was breaking temporalHelpers.observeProperty → 6 fromAsync tests; the 7th needed a separate fromAsync length-coercion fix (ToPrimitive on object-valued length).
- [ ] **Borrowed array-iterator target in chained `.call().then()`** — `Expr.call(C, arrayArg).then(...)` frees/corrupts arrayArg when a builtin defers iteration to microtasks (built-in array iterator holds a borrowed pointer). Found by the fromAsync agent; statement break dodges it. VM refcount issue in .call re-dispatch.

- [x] **`test/json_stringify_ext.js` local test fails on main** — assertion `{"toJSON":{"lastIndex":0}}` was an obsolete V8 expectation; current Node 24, QuickJS, and SpiderMonkey all return `{"toJSON":{}}` (non-enumerable `lastIndex`). Test updated to match current engines.

- [x] **Arrows parse at any precedence level** — fixed via a shared `last_was_arrow_expr` marker set by `parse_arrow_function*` and a `check_no_arrow_rhs` macro called after every RHS recursive parse in `binary_expr`. Lone arrows (`[1].map(()=>1)`, `(a, ()=>1)`) still parse because `expression`/`assignment_expr`/`conditional_expr` reset the marker on entry and there is no binary op following the arrow in those contexts.

- [x] **Spread into builtin calls drops the last argument at 5+ args** — two coupled bugs fixed: the spread count register (CALL_S's nargs source) was allocated INSIDE the argv window and got overwritten at 5+ elements, and SPREAD_ARG stored borrowed refs that call teardown over-decref'd. `begin_spread_args` now reserves both control regs below first_arg; SPREAD_ARG takes owned refs.
- [ ] **Plain argument AFTER a large spread still miscompiles** — `f(1,...[2,3,4,5],99)` → `1,2,3,4,99,99`; REOPENED session 293: the console-branch attempt (442d5eb) was reverted after review — it left this case wrong AND broke multiple spreads (`f(...[1,2],...[3,4],5)` → `5,4,3,4,5`). Needs argument-array lowering or a VM-side spread buffer, with multi-spread tests in the battery.

- [x] **Captured-method aliasing** — NOT REPRODUCIBLE on merged HEAD (dedicated agent exhausted alias/IC/GC variants; coordinator re-confirmed 4 repro shapes clean). The iterator-helpers agent's mid-implementation observation was an artifact of its then-uncommitted state. Reopen only with a repro on current main. Note: the triggering test file is absent from our test262 snapshot.

- [x] **Getter/setter methods never create `arguments`** — fixed (console branch cherry-pick): both accessor invocation paths (invoke_getter + the two setter paths) now declare a sized arguments object like ordinary CALLs.
- [x] **`let x; var x;` redeclaration not rejected** — fixed (console branch cherry-pick): `block()` pre-scans var declarators (recursing into nested blocks, skipping function/class bodies) and rejects overlap with lexical names per §13.2.1.
- [x] **`await` as BindingIdentifier in nested-function positions** — fixed via shared `expect_binding_identifier()` honoring [Await]/[Yield] boundaries (arrow params inherit, bodies reset); 9/10, CE:unexpected back to 0; the 10th needs `using` (explicit-resource-management, unimplemented).
- [x] **`new Set(string)` throws** — fixed: `coll_construct` wraps primitives (correct [[Prototype]]) before the iterable check; `new Map("ab")` correctly TypeErrors on non-object entries.
- [x] **`Array.from` primitive-wrapper prototype** — fixed by the iterator-helpers agent (real [[Prototype]] set; numbers/booleans/bigints handled too).
- [x] **Large-string refcount leak** — >256-byte (`MAX_INTERN_BYTES`) non-interned strings from fromCodePoint/concat never decref'd (~5-7 MB/property-escapes test); FIXED (opus agent, s292): builtin/getter result-copy sites now release the transient setter-ref for non-interned non-symbol strings at refcount 1 (`Heap.store_builtin_result`); ~98.6% of the leak class gone (281→4 objects/test), ASan-clean. Residual ~45 KB/test through the same dispatch site left deliberately (needs raw-register-overwrite decref surgery — the Symbol-string UAF trap is documented in the helper). First agent's worktree diff (agent-a178867b5c7d24326) is superseded.
- [ ] **`RegExp.prototype.compile` missing entirely** — Annex B method; invisible today (annexB dir excluded), blocks 1 duplicate-named-groups test.
- [x] **Regexp literals never parse-time-validated** — CompilerContext.validate_regexp_literal now runs `re_compile` on every literal at parse time (also rejects unknown/duplicate/u-v flags); 80 `language/literals/regexp/early-err-*` $DONOTEVALUATE tests now produce the spec SyntaxError.

## Compiler / language

- [ ] **C7a-residual** — `MAX_PRIVATE_NAMES = 64` cap (context.c3); grow-on-demand (65+ private fields overflow slot 0).
- [ ] **L2** — Direct eval var-hoisting into caller/global scope.
- [ ] **E1** — Eval-super residuals (plan 059 §2-3): object-literal-method eval-super (`__super__` in uncaptured PUSH_LEX scope); `eval("super()")` in derived ctors (`is_constructable` hardcoded false); nested-eval `new.target` (eval CFs are `is_global`); `super` in plain fn-expr should be an early SyntaxError.
- [ ] **F2** — `Function.prototype.toString` NativeFunction grammar for builtin accessors (getter/setter builtin objects lack toString routing).

## Infrastructure

- [ ] **I2** — `$262.detachArrayBuffer` host hook (unblocks TypedArray callback tests).
- [ ] **I4** — Two-consecutive-run zero-fail gate; enforce in CI.
- [ ] **Runner skip-list re-tier** — regroup `UNSUPPORTED_PATTERN` comments by `features.txt` sections (ratified vs proposal); labels have drifted.

## Non-goals (do not reopen)

- **Native UTF-16/Latin1 string storage** — big GC/string-builtin migration.
- **X1 note** — the `(o?.m)()` undefined-this "fix" was a misdiagnosis and is reverted; parens preserve the optional-chain receiver (`optional-call-preserves-this.js`). Don't re-introduce.

## Done (compressed; details in progress.md by session)

- [x] Private class members complete: fields/methods/accessors/static (plan 054 P2-P5, C7), `\u` escapes (C7a), direct-eval visibility (C7b), dup-init TypeError (C7c), proxy/eval edges (C7d), public fields (P7, s289d).
- [x] Class-method/object-literal eval-super basics (E2) + escaped-arrow `super()` re-binding (s289-290).
- [x] Arrow lexical this/new.target (C8), arrow reparse scopes (X2), param-default capture (X3), template-substitution brace scanning (X4), named-funcexpr envs (X5), array fast-path key truncation (X1).
- [x] Strict PutValue on unresolvable references via RESOLVEVAR (L1); indirect-eval var-hoisting has no failing tests (L3).
- [x] AsyncFromSync tick ordering — AWAIT always via PromiseResolve + suspension; microtask drain gated to outermost reentry (s291).
- [x] Builtin clusters S1-S6, O1-O3, D1, T1-T4, Y1, J1-J2, G1-G2, TA1-TA3, Promise combinators, Symbol.split/matchAll, H1, BigInt (plan 056), `arguments` iterator, shared iterator prototypes — all cleared by s289d-291 full runs.
- [x] RegExp: property-escapes register-aliasing (P1), `\p{}` wiring (U1), >31-capture SIGABRT (R1), CharacterClassEscapes.
- [x] Huge sparse-array timeouts — ArraySetLength own-key scan (s291).
- [x] Valstack relocation corruption (I5) — entry_act.bottom + caller_valstack_top on grow; was the "RegExp flakiness" (s291).
- [x] Batch-runner SIGSEGV (dc0af6d); CE:unexpected 0 since s286 (I3); long-tail clustering (Z); sloppy/tzdata skip-list.

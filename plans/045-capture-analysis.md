# Plan 045: Capture analysis — env-resident captured locals

**Status:** Implemented (Phase A). `src/compiler/captures.c3` token pre-scan
runs before every function/arrow body compile; `declare_var` (plus a
retroactive pass for params) marks capture-set names `is_captured`. Also
fixed along the way: emit_call clobbering a named local used as callee at
top-of-stack, `var` redeclaration needing a capture-blind lookup
(`find_local_reg`), and for_statement's register-cache sync writing a stale
register over the env-authoritative captured loop var. Oracle:
`test/test_capture_analysis.js` (17/17). Per-iteration `for(let…)` bindings
remain open (closures now correctly share one binding; spec wants a fresh
binding per iteration).
**Priority:** High — silent wrong answers, not crashes. Almost certainly a
test262 failure cluster (closures over mutable state are everywhere).
**Related:** builds on the plan-044 store modes, the lexical-capture fix
(`resolve_call_lex_env`, `has_lexical_bindings`), and the direct-eval flag fix.

## The bug class

The register-resident-locals model keeps every local in a register and lets
`resolve_var` compile reads/writes to direct register access. Bindings are
*also* synced to the environment at declaration (DECLVAR/PUTLEX), and closures
read/write that env copy through the chain. Nothing keeps the two copies
coherent afterward:

```js
function m() { var x = 1; function g() { x = 2; } g(); return x; }  // → 1, want 2
function w() { let x = 1; const g = () => x; x = 2; return g(); }   // → 1, want 2
function e() { var v = 7; eval("v = 9;"); return v; }               // → 7, want 9
```

- Closure writes land in the env; the outer function keeps reading its stale
  register.
- Outer re-assignments (`x = 2`) are register-only stores; closures keep
  reading the stale env copy.
- Direct eval is a closure for this purpose: it can read *and write* any
  caller binding by name (assignment only — strict-only engine, so eval `var`
  declarations stay in the eval's own env).

The existing `is_captured` flag on `ScopeEntry` already produces exactly the
right code when set: `resolve_var` fails, so every access compiles to
GETVAR/PUTVAR/INC_VAR and the env copy is the single source of truth (the
catch-parameter and TDZ-shadowing paths rely on this today). What is missing
is the analysis that sets it for closure-captured names.

## Why marking at inner-function parse time is not enough

The inner function is parsed mid-way through the outer body. Any outer access
emitted *before* the closure's source position has already been compiled as a
register access, and in a loop that stale access re-executes after the
mutation:

```js
function f() {
  let x = 0;
  for (let i = 0; i < 2; i++) {
    use(x);                 // compiled once, before g is ever parsed
    const g = () => { x = 1; };
    g();
  }
}
```

So the capture set must be known **before the body is compiled** — a pre-scan,
same technique as `pre_scan_lexical_decls` (statements.c3:274) and
`hoist_decls` (entry.c3), which already save/restore the lexer and re-scan the
body tokens.

## Phase A — token pre-scan (sound, overapproximate)

1. **Pre-scan pass** (new, runs where `hoist_decls` runs, per function body):
   walk tokens to the body's closing brace, tracking brace depth.
   - On a `function` keyword: skip to its body `{`, then collect **every
     identifier token** until the matching `}` into the function's
     `captured_names` set (nested functions included — the scan doesn't
     recurse, it just collects everything inside).
   - On `=>`: arrow boundaries are ambiguous at token level. Degrade: set a
     `capture_all` flag for this function (every local becomes env-resident).
     A later refinement can bound the arrow body precisely.
   - On a direct `eval` identifier: set `capture_all` (eval reaches anything
     by name).
   - Set overflow (fixed-capacity table, e.g. 64 names × 64 bytes): set
     `capture_all`.
2. **Marking**: `declare_var` (and the param-declaration sites) check
   `capture_all || captured_names.contains(name)`; on hit, mark the new scope
   entry `is_captured = true` and set `has_captured_local` (keeps the elision
   pass and `needs_env` on). Everything downstream already works: reads emit
   GETVAR, writes emit PUTVAR, INC/DEC use INC_VAR/DEC_VAR, and closures see
   every update.
3. **Params**: captured params must be env-resident too. Verify the VM
   installs argument values into the fresh scope when `needs_env` (the eval
   fix demonstrated params are visible through the chain, so the install
   exists; confirm the compiler-side marking doesn't break the zero-copy arg
   window).
4. **Declaration ops**: a captured `var/let/const` declaration still emits its
   DECLVAR/PUTLEX via `emit_var_store`; the register copy simply stops being
   read. `DestructStoreMode.DECLARE` (plan 044) needs no change —
   `binding_regs` become write-once temps.

Overapproximation is safe by construction: a false positive (name shadowing,
property names collected from inner bodies) only costs env round-trips on
that name, never wrong values.

## Phase A costs and gates

- Compile time: one extra token scan per function body containing `function`
  (bodies without nested callables skip the set entirely).
- Runtime: captured locals pay GETVAR/PUTVAR per access (VarIC softens
  repeats). Functions without closures are untouched — the hot benches
  (`bench_function_call`, `bench_loop`, `bench_recursion`) must not move.
- `capture_all` on arrows is the blunt edge: measure rosetta (arrow-heavy)
  before deciding whether the arrow-body refinement is required in the same
  wave.

## Phase B — later, with the SSA-IR milestone

A proper two-phase resolver (parse once collecting scopes + references,
resolve register-vs-env per binding, then emit) removes the
overapproximation and the pre-scan entirely — QuickJS's `resolve_variables`
model. Out of scope here; this plan's `captured_names` machinery becomes the
seed data for it.

## Per-iteration `let` loop bindings (sub-item)

`for (let i = 0; i < 3; i++) arr.push(() => i)` must capture a fresh `i` per
iteration (got `3,3,3`-style sharing today; with capture analysis alone it
becomes a *correctly shared* single binding, still wrong per spec). Needs the
loop to re-create the lexical env each iteration and copy the loop variable
forward (PUSH_LEX + copy in the update sequence). Depends on this plan
(captured `i` must be env-resident first). Track as its own wave item.

## Oracle

`test/test_capture_analysis.js` covering: closure-write → outer-read (var and
let), outer-write → closure-read, read-modify-write both sides, eval-write →
outer-read, captured params, capture in loops (pre-closure-position reads),
shadowed names (false-positive soundness), and the per-iteration `let` case
(expected-fail until the sub-item lands).

## Regression floor

Destructure suites, `test_lexical_closure_capture.js`,
`test_direct_eval_scope.js`, rosetta 100/100 (normal + ENV_STRICT builds),
bench-fast within noise on closure-free benches.

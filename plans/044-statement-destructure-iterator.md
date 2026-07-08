# Plan 044: Iterator protocol for statement-level array destructuring

**Status:** Implemented. `array_destructure` / `array_destructure_assign` now
build the recursive `DestructBind[]` model and delegate to
`emit_destruct_bindings`; the legacy index/`.slice()` emitters are deleted.
The emitter gained a `DestructStoreMode` (PARAM_SYNC / DECLARE /
ASSIGN_TARGET) because the three call sites need different env-store ops:
parameters re-assign an existing binding (PUTVAR + GETVAR reload), statement
declarations must *declare* (DECLVAR / PUTLEX / PUTLEX_C via
`emit_var_store`), and assignment targets write register-resident locals
directly or bare-PUTVAR env residents (a PUTVAR+GETVAR pair would be
misread as loop-var sync by the register-locals elision and dropped).
Scope-stack names are backed by interned constant-pool bytes — a slice into
the stack-local `binds` array dangles after the parse function returns.
Oracle: `test/test_statement_destructure_iter.js` (13/13).
Known pre-existing, unrelated failure: closures over lexical locals lose
their PUTLEX stores to the env-elision gate (tracked separately).
**Related:** extends the plan-042 fix (iterator protocol for *function-parameter*
array destructuring) to the *statement* path. Discovered while validating
[043-call-frame-isolation.md](043-call-frame-isolation.md).
**Priority:** Medium — spec conformance gap; any `var [...] = <iterable>` where
the RHS is not a real Array silently misbehaves.

## The bug

Statement-level array destructuring reads elements by **index** and collects
rest via **`rhs.slice(n)`** (`src/compiler/destructuring.c3`,
`array_destructure` at line 18 and `array_destructure_assign` at line 1084).
Both assume the RHS is an Array. For any other iterable this breaks:

| RHS | `var [a,b]=x` | `var [h,...t]=x` |
|---|---|---|
| Array | ✅ | ✅ |
| Generator / custom iterable | ❌ returns `undefined` | ❌ throws "undefined is not a function" (`.slice` missing) |

Per ES2015 §13.3.3 (ArrayAssignmentPattern / BindingPattern) destructuring must
use the **iterator protocol** (`Symbol.iterator` → `.next()` → `.value`/`.done`),
exactly as the parameter path already does since plan 042.

## Why it can't be a partial fix

The head elements and the rest element share one iterator cursor. If the head
elements keep reading by index while only the rest switches to `.next()`, the
rest restarts from element 0 (the iterator was never advanced) and the head
reads from a possibly-non-indexable iterable. The whole function must move to
the iterator protocol atomically.

## Proposed fix

Reuse the machinery plan 042 already built. `emit_destruct_bindings`
(`src/compiler/functions.c3:398`) implements the full protocol over a generic
`DestructBind[]` + `group_regs`/`binding_regs` and is **not** parameter-specific.

1. Adapt `array_destructure` (statement `var/let/const [...] = rhs`) to build the
   `DestructBind[]` shape `emit_destruct_bindings` expects and delegate to it,
   deleting the index/`.slice()` emission.
2. Same for `array_destructure_assign` (assignment `[a, ...b] = rhs`), preserving
   assignment-target semantics (member expressions, existing bindings) rather
   than fresh declarations.
3. Keep the register-overlay discipline from plan 043 — `emit_destruct_bindings`
   already uses the pre-scan + `alloc_persistent_reg` path, so cross-call
   collectors stay safe.

## Testing / oracle

- New oracle covering `var [a,b] = gen()`, `var [h,...t] = gen()`, nested rest,
  holes/elision, and custom (non-generator) iterables at statement scope.
- Extend `test/test_call_frame_overlay.js` scope OR add a sibling that exercises
  the statement path (currently that file deliberately avoids it).
- Regression floor: `test_destructure_{array,object,let_const,regression}`,
  `test_rest_nested`, rosetta 100/100, plus test262 Phase 15/21 no-regression.
- The array RHS fast case (`var [a,b] = [1,2]`) must stay correct and ideally
  not regress in bytecode size — consider keeping an Array fast-path if the
  iterator route measurably bloats the common case.

## Risk

Larger than plan 043 — this rewrites two emission functions. The head/rest
cursor-sharing invariant is the correctness crux; the oracle must cover a
generator RHS (single-use iterator) so any accidental re-iteration is caught.

# Plan 043: Systematic fix for CALL callee-frame register overlay

**Status:** Implemented (Parts 1–2 core). Part 3 and the COMPILE_VERIFY
assertion intentionally deferred — see "As-built" below.
**Depends on / supersedes workaround in:** [042-call-callee-register-overlay.md](042-call-callee-register-overlay.md)
**Priority:** Medium — removes a whole class of latent miscompiles in any
multi-CALL loop that carries live state across iterations.

## As-built (what actually landed)

- **Part 1 done:** `reserve_call_frame(callee_reg, nargs)` added to
  `src/compiler/regalloc.c3` as the single source of truth. All 8 open-coded
  `next_reg` bumps (`context.c3:557`; `destructuring.c3` ×7) now funnel through
  it. The two `Object.assign` sites (`destructuring.c3` rest paths) emit
  `CALL … nargs=2` but previously reserved only through `callee+3` (one arg
  slot); the reservation was **corrected** to `reserve_call_frame(reg, 2)` so
  both arg slots are protected. All other sites are 1-arg (`+3`) or the 0-arg
  default thunk (`+2`), preserved exactly.
- **Part 2 done (allocation side):** `alloc_persistent_reg()` added — a thin,
  intent-documenting wrapper over `alloc_reg` for cross-call live state. The
  synthetic-rest pre-scan (`functions.c3`) now allocates through it.
- **Part 3 (emit_call wrapper) — skipped, not deferred.** None of the 8 call
  sites can use it: register setup (GETPROP of the method, arg loads) happens
  *between* the reservation and the CALL emit, so reservation and emit cannot be
  fused. Adding an uncalled `emit_call` would be dead code. Revisit only if a
  new call site with no intervening setup appears.
- **COMPILE_VERIFY assertion — deferred.** A faithful "no live-across-call reg
  sits at ≥ callee_reg+2" assertion needs cross-call liveness tracking the
  compiler deliberately does not have (that is the very machinery the "when to
  revisit" section below says to defer). A partial version (checking only the
  pre-scan regs) would give false confidence, so it was not added. Tie this to
  the SSA-IR milestone.
- **Oracle added:** `test/test_call_frame_overlay.js` — rest collection driven
  by a user-JS generator `.next()` loop with live priors, forcing the collector
  high in the register file. 6/6 pass.
- **Out-of-scope bug found:** statement-level `var [h, ...t] = userIterable`
  still uses index/`.slice()` access and is broken for any non-array iterable
  (generators, custom iterables). This is the plan-042 *iterator-protocol* class
  on the statement path (not register overlay); filed as **plan 044**.

Validation: builds clean; rosetta 100/100; destructuring regression suites
155/155 (`test_destructure_{array,object,let_const,regression}`, `test_rest_nested`)
plus the 5 plan-042 tests and the new overlay oracle.

## Problem recap

The VM uses a **sliding-window** register model (`src/vm/vm_calls.c3`). On CALL
`A=result, B=callee, C=nargs`, the callee's register frame is placed directly in
the caller's register array at `callee_reg + 2` (`vm_calls.c3:66-68`):

```c3
uint frame_start = callee_reg + 2;
TVal* new_bottom = ds.regs_base + frame_start;
```

Arguments are passed **in place** — the fast path relies on `new_regs == old_args`
and skips the copy entirely (`vm_calls.c3:958-964`). This zero-copy arg passing
is a deliberate, load-bearing performance property. **Any fix must preserve it.**

The consequence: every caller register `>= callee_reg + 2` is clobbered by a
CALL. If live caller state (e.g. an array being built across loop iterations)
sits in that range, it is silently overwritten with the callee's `r0`.

## Why plan 042's options A/D are wrong for this VM

Options A (per-activation register copy) and D (separate frame pointer) both
break the sliding window — they'd force an arg copy on every call and regress
the hot path. Given the architecture, the correct family is **Option C
(reserve the danger zone in the compiler)**, but done *systematically* instead of
by hand.

## The real problem: the workaround is already everywhere, uncentralized

The "bump `next_reg` past the call frame" idiom is **already open-coded ~10
times**, each a hand-written variant of the same invariant:

```c3
// context.c3:557
if (self.next_reg <= call_base + 1) self.next_reg = call_base + 2;
// destructuring.c3:321, 354, 1424, 1455, 2382 …
if (self.next_reg < callee_reg + 3) self.next_reg = callee_reg + 3;
// destructuring.c3:1012, 2182 …
if (self.next_reg <= assign_callee_reg + 2) self.next_reg = assign_callee_reg + 3;
```

Note the off-by-one drift between sites (`+2` vs `+3`, `<` vs `<=`). Each is a
place where the invariant "no live caller reg overlaps the callee frame" is
re-derived by hand, and each is a place a future edit can get it subtly wrong —
exactly how the destructuring bug in plan 042 arose. This is the thing to fix,
not the VM.

## Proposed fix

Two coordinated pieces, both compiler-only, VM untouched.

### Part 1 — Centralize the danger-zone reservation

Add to `src/compiler/regalloc.c3`:

```c3
/// Reserve the callee frame region for a CALL whose callee occupies
/// `callee_reg` (func at callee_reg, this at callee_reg+1, args above).
/// After this returns, no register the allocator hands out can overlap the
/// callee frame that the VM will overlay at `callee_reg + 2`.
///
/// This is the single source of truth for the sliding-window CALL invariant
/// documented in plan 042. Every CALL emission site must funnel through here
/// (directly, or via emit_call below) instead of open-coding `next_reg` bumps.
fn void CompilerContext.reserve_call_frame(&self, ushort callee_reg, ushort nargs) {
    ushort frame_top = callee_reg + 2 + nargs;   // first reg above the args
    if (self.next_reg < frame_top) self.next_reg = frame_top;
    if (self.next_reg > self.max_reg) self.max_reg = self.next_reg;
}
```

Then replace each of the ~10 open-coded bumps with a `reserve_call_frame` call.
This alone kills the off-by-one drift and gives one place to reason about the
invariant.

### Part 2 — Make cross-call live state provably safe

Reserving the frame only helps registers allocated *after* the reservation. The
plan-042 bug was a register (`array_reg`) that had to stay live *across* the
call and happened to land inside the frame. The systematic guarantee:

> **A register that must survive a CALL must be allocated below `callee_reg`.**

Enforce this at the two places it matters:

1. **Loop-carried collectors** (rest arrays, for-of accumulators). These are
   already handled correctly for the leaf/synthetic cases via the pre-scan in
   `functions.c3:412-416` and the use of `bind_reg`. Generalize that: introduce
   a helper `alloc_persistent_reg()` that allocates from a low-water mark and is
   documented as "survives calls," and route loop accumulators through it. The
   existing pre-scan becomes one caller of this helper.

2. **A debug assertion tying the two together.** In the CALL emission helper,
   assert (under `$if $feature(COMPILE_VERIFY)`) that no register currently
   marked live-across-call sits at `>= callee_reg + 2`. This converts the
   plan-042 class of bug from "silent wrong value at runtime" into "loud compile
   abort in a debug build," which is the whole point of a systematic fix.

### Part 3 (optional, follow-up) — a thin `emit_call` wrapper

Fold callee-frame reservation + the CALL emit into one helper so new call sites
can't forget the reservation:

```c3
fn void CompilerContext.emit_call(&self, ushort result_reg, ushort callee_reg, ushort nargs) {
    self.reserve_call_frame(callee_reg, nargs);
    self.emit_abc(Opcode.CALL, result_reg, callee_reg, nargs);
}
```

Migrate call sites opportunistically; not required for correctness once Parts 1–2
land, but it's the durable ergonomic win.

## Why not just leave the workaround?

The workaround works today but is O(call-sites) fragile: correctness depends on
every current and future CALL emitter independently re-deriving the `+2` offset
and remembering to keep loop-carried state low. Parts 1–2 make it O(1): one
reservation helper, one allocation helper, one debug assertion. The VM fast path
is untouched, so there is zero runtime cost.

## Implementation steps

1. Add `reserve_call_frame` + `alloc_persistent_reg` to `regalloc.c3`.
2. Replace the ~10 open-coded `next_reg` bumps (`context.c3:557`,
   `destructuring.c3:321,354,1012,1424,1455,2182,2382`) with `reserve_call_frame`.
   Verify each site's intended `nargs` — some pass 0 args (`+2`), some reserve a
   this-only frame (`+3` was covering callee+this+one). Get these exactly right;
   this is the delicate part.
3. Route the destructuring pre-scan (`functions.c3:412-416`) through
   `alloc_persistent_reg`.
4. Add the `COMPILE_VERIFY` assertion in the CALL path.
5. Add `emit_call` and migrate the destructuring/functions call sites.

## Testing / oracle

- **Regression floor:** the plan-042 tests must stay green —
  `test/destructure_iterable.js`, `destructure_iterable2.js`,
  `destructure_comprehensive.js`, `destructure_rest_debug.js`,
  `destructure_array_check.js`.
- **Targeted new oracle:** a test that builds an array across a user-JS `.next()`
  loop with *many* prior register allocations, to force the collector high in
  the register file — this is what surfaced the original bug and must pass.
- **test262:** Phase 15 (destructuring) and Phase 21 must not regress from the
  post-session-266 baseline (1287 / 261 pass). Validate with those two phases
  plus `bench-fast`, not a full suite run.
- **No perf regression:** confirm the VM diff is empty; the change is
  compiler-only.

## Risk

The only delicate step is #2 — getting each reserved frame width exactly right.
An over-reservation wastes registers (harmless but measurable against
MAX_REGISTERS); an under-reservation reintroduces the bug. The `COMPILE_VERIFY`
assertion from step 4 is the safety net and should land in the same change.

## Allocator design: when to revisit

This plan deliberately keeps the existing single-pass, stack-discipline
register allocator (`src/compiler/regalloc.c3`) rather than replacing it with a
linear-scan or graph-coloring design. That is the correct choice for a non-JIT
bytecode interpreter: it is structurally the same allocator Lua and Duktape use,
and the sliding-window CALL convention is Lua's. The plan-042 bug is not a design
flaw — it is the watermark discipline (which Lua centralizes) being open-coded in
~10 places. Parts 1–2 above fix that directly.

A real allocator (liveness analysis, live-range splitting, spilling) would buy
three things: (1) correctness for cross-call lifetimes — but plan 043 already
gets this centrally, far cheaper; (2) tighter `num_regs`, saving `TVal::size` of
per-activation valstack per reclaimed register — a genuine but currently modest
win; (3) graceful degradation past the hard `MAX_REGISTERS = 512` ceiling
(`regalloc.c3:23` aborts via `libc::abort()`), which only matters for pathological
generated code not seen in the corpus.

Revisit the allocator design only when one of these triggers fires:

- **A JIT tier is added.** The prerequisite for both a JIT and a serious
  allocator is an SSA IR between the AST and bytecode. Tie any allocator
  redesign to that milestone rather than doing it standalone.
- **Profiling shows `num_regs`-driven valstack growth is a measurable memory or
  cache cost** in real workloads (not microbenchmarks).
- **The 512-register ceiling starts aborting real user code** (not adversarial
  input).

Until then, the stack allocator plus centralized call-frame reservation (this
plan) is the right point on the cost/benefit curve.

# Plan 061 — Engine-wide consolidation (design review)

**Status:** DRAFT (session 295). User-requested full-design review: reduce duplication, increase elegance/compactness at constant performance and correctness. Method: four read-only subsystem surveys → this ranked plan → one fix agent per item, each gated on golden bytecode + bench-fast + relevant phase sweeps.

**Evidence baseline:** this session alone, duplication caused: the PUTLEX-r0 param bug (fixed 3×), the in_formal_params flag (chased through 5 sites), ~15 core.c3 merge conflicts, the arguments-object divergence (4 builders, 2 missing @@iterator), and the resume-routing drift.

## A. Generator/async machinery (survey complete)

Ranked consolidations (full details + file:line in survey; invariants noted per item):

- **A1 `pop_to_caller(ds, …)` epilogue** — the caller-frame restore tail is copied 9+ times across YIELD/AWAIT/ays_*/GEN_START paths; single helper with the halt-at-zero branch and conditional ds.code_* reload. Highest mechanical win, lowest risk.
- **A2 `suspend_generator(ds, gs, kind, save_pc)`** — one register/env/pc save routine replacing 4 copies (sync yield, sync yield*, ays_save_body, ag_suspend_on_await). save_pc stays a parameter; must not clobber GEN_AWAITING_RETURN; thunk case keeps pending_resume_reg + gen_act frame source.
- **A3 `attach_await_reaction(...)` factory** — six hand-rolled fulfill/reject pair builders → one, parameterized by ordinals + state carrier (var_env+is_async_state vs property slot). Centralize the OOM rollback (is_async_state/var_env clearing) with it; is_async_state is what GC-marks the gs.
- **A4 Single suspend-outcome channel** — drop gs.ag_suspend_kind (never branched); make async_gen_resume_body RETURN a {SETTLED_YIELD|SETTLED_RETURN|SETTLED_THROW|SUSPENDED_AWAIT} outcome replacing the heap.ag_did_await + heap.has_error + returned-object triple the drain currently sniffs.
- **A5 Tagged completion {kind, value}** — replace the resume_kind + resume/throw/return_value 4-field union; preserve the stale-completion resets in LOAD_RESUME/YIELD_STAR_ASYNC.
- **A6 One resume_into_frame(gs)** — unify vm_calls.c3 inline-CALL and vm_execute.c3 call_fn resume copies; reconcile the divergent this_binding restore. Also demote heap.resume_gen to a single-shot handoff consumed at resume-push (opcodes already distrust it in favor of act.async_gen_state).
- **A7 (cleanup) retire heap.did_yield/yield_value on async paths; delete delegated_index if truly unused.**

Ordering: A1 → A2 → A3 (mechanical, independently verifiable) → A5 → A4 → A6 (semantic). Each gates on: phases 21/24/15 zero, golden 9/9, rosetta, bench-fast flat, ASan over generator families.

## B. Compiler (survey pending)
## C. Builtins/registration (survey pending)
## D. VM/heap conventions (survey pending)

## Execution rules

One item per agent (Opus for A-series and anything touching vm_generators.c3); byte-identical golden bytecode unless a change is justified in the commit; no behavioral drift — this plan changes SHAPE, not semantics. Fail counts must stay at their pre-refactor values (currently: full suite 65 fail / 1 CE with 3 fix agents in flight; re-baseline before starting).

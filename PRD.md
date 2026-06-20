# PRD: Duktape C3 — ECMA-262 Compliant JavaScript Engine

## Goal

A port of the Duktape engine to C3, passing at least 80% of the ECMAScript test262 conformace suite.

Goals: beat Duktape in performance. Low memory consumption. Runnable on low-powered devices and multiple platforms.

Leverage C3's native features for memory safety and it's stdlib; use Duktape's and QuickJS's architectures as reference.

- **Strict-only engine.** A single execution mode — always strict. Non-strict / Annex B
  features (`with`, legacy octal literals/escapes, duplicate params, implicit globals,
  unqualified `delete`, `arguments.callee`/`caller`, two-way `arguments`↔param binding) are
  unsupported and rejected at parse time. `eval` and the direct/indirect-eval distinction are
  not non-strict features and are fully supported.

- RegExp is implemented using libregexp (from QuickJS)

- when path is unclear, compare Duktape source against QuickJS to figure out a viable approach

- ignore *staging* features in the ECMAScript spec, focus on ES5/ES6 core

- **test262 skip list** — ~60% of test262 is irrelevant for a clean-slate engine targeting
  Node/Bun/browser compatibility (Annex B, ECMA-402, Stage 3 proposals, engine quirks).
  The full analysis and rationale is in `test262_relevance_report.md`. All test runners
  (`scripts/test262_skip.cfg`, `scripts/run_test262.py`,
  `test262_runner/run_real.sh`, `test262_runner/quick.sh`) use a shared skip list derived
  from that report. Update the skip list there when implementing new features.

( DO NOT EDIT )

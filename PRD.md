# PRD: Duktape C3 — ECMA-262 Compliant JavaScript Engine

## Goal

An efficient port of the Duktape engine to C3, passing at least 80% of the ECMAScript test262 conformace suite.

## Strategy

Leverage C3's native features for memory safety and it's stdlib; use Duktape's architecture as reference.

## Architecture

### Value System
- **TVal** — 16-byte tagged union: `{ tag: TValTag, union { boolean, number (f64), fastint (i48), pointer } }`
- **Tags:** UNDEFINED, NULL, BOOLEAN, NUMBER, FASTINT, STRING, OBJECT, LIGHTFUNC, BUFFER, POINTER
- **FASTINT** — 48-bit integer stored in the double's NaN-space (Duktape-compatible)
- **STRING** — Interned, reference-counted HString with inline UTF-8 data
- **OBJECT** — HObject with property table, prototype chain, object class flags

### Bytecode
- 32-bit fixed-width instructions: `{ opcode(8), A(8), B(8), C(8) }`
- 91 opcodes covering loads, stores, arithmetic, calls, control flow, object access
- Formats: ABC, A_BC, A_SBX, WIDE_SABC, NONE
- Up to 256 registers per function, 16M constant pool

### VM Execution
- Value stack with activation records (max 128 calls deep)
- Register-based: operands reference registers within current frame
- Inner/outer loop pattern: inner loop executes bytecode, outer loop restarts on ECMAScript-to-ECMAScript calls

### Memory Management
- Reference counting for strings and objects (immediate free)
- Mark-and-sweep GC for cycles (not yet implemented)
- String interning via hash table with PRNG-seeded hash function
- Property table with open-addressing hash table on HObject

### Scope Chain
- EnvRecord with parent link, bindings via HObject property table
- Global scope, function scope, catch scope
- **Lexical environment (let/const)** — implemented: PUSH_LEX/POP_LEX opcodes, PUTLEX (let) / PUTLEX_C (const) for declarations, INITTZ for TDZ sentinel initialization at block entry, GETVAR/PUTVAR searches lex_env first, block scoping via EnvRecord chain on act.lex_env. TDZ sentinel infrastructure with `is_captured` shadowing detection forces GETVAR across scope boundaries. Const runtime enforcement (TypeError on reassignment) via non-writable property flags. Full TDZ enforcement at block entry via pre-scan lexical declaration collection.

### RegExp
- using libregexp (from QuickJS)

### Arrow Functions (ES6)
- `is_arrow` flag on CompiledFunction (bit 12 in FuncFlags)
- Parse `IDENTIFIER => expr`, `() => expr`, `(params) => expr`, `(params) => { body }`
- Lexical `this` — inherited from enclosing scope at call time (VM ignores stack `this` slot)
- Cannot be used as constructor — `new Arrow()` throws TypeError
- No `.prototype` property — skipped in CLOSURE opcode handler
- Implicit return for expression bodies; block bodies need explicit `return`

### Template Literals (ES6)
- Lexer split into `scan_template_head()` + `scan_template_after_expr()` with `TemplateState` tracking
- Tokens: TEMPLATE_HEAD (`text${`), TEMPLATE_MIDDLE (`}text${`), TEMPLATE_TAIL (`}text\``)
- Brace-balance tracking in lexer (`template_brace_balance`) handles object/function bodies inside `${}`
- No-substitution templates (`` `text` ``) return STRING token — zero cost
- Compiler emits LDCONST for template parts + ADD for concatenation (ADD opcode handles ToString coercion)
- Escape sequences processed identically to string literals (\n, \t, \uXXXX, \xHH, etc.)
- Line continuations (`\<LF>`) supported
- Tagged templates not yet implemented; nested templates deferred

## Deviations from Duktape

- **Computed goto dispatch (from QuickJS)** — Replace the inner loop switch-based dispatch with a computed goto jump table (direct threading). This eliminates a branch prediction bottleneck and typically yields 15-30% improvement on bytecode-heavy workloads.

- **Strict-only mode** — The engine operates exclusively in ES5 strict mode. There is no sloppy/non-strict code path. All code is treated as strict by default, eliminating `is_strict` runtime branching, non-strict `this` coercion, and non-strict error handling paths. The `"use strict"` directive is recognized but is semantically redundant.

## Technical notes

- **FASTINT preservation** — Arithmetic ops keep FASTINT when both operands are FASTINT and result fits in 48-bit range. Fall back to NUMBER otherwise.

- **String interning consistency** — Both compiler and runtime use the same heap's PRNG-seeded hash function for string deduplication. `str_table_insert` must not create duplicate entries.

- **Union field ordering** — TVal's union (boolean/number/fastint/pointer) is sensitive to write order. For NUMBER tag: set `number` LAST. For OBJECT tag: set `pointer` LAST.

- when path is unclear, compare Duktape source against QuickJS to figure out a viable approach

- ignore *staging* features in the ECMAScript spec, focus on ES5/ES6 core

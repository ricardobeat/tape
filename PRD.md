# PRD: Duktape C3 — ECMA-262 Compliant JavaScript Engine

## 1. Executive Summary

**Goal:** A faithful, production-quality port of Duktape 2.7.0 to modern C3, passing the full ECMAScript test262 conformance suite (~53,500 tests).

**Strategy:** Leverage C3's native features (faults, optionals, modules, defer, bitstructs) for safety and clarity while preserving Duktape's proven architecture (value stack, register-based bytecode, reference-counted objects with mark-and-sweep GC).

**Current State (baseline):** 21/53,568 passing. Core VM, calling convention, closures, basic operators, `new` operator, and NaN semantics are solid.

## 2. Architecture

### 2.1 Value System
- **TVal** — 16-byte tagged union: `{ tag: TValTag, union { boolean, number (f64), fastint (i48), pointer } }`
- **Tags:** UNDEFINED, NULL, BOOLEAN, NUMBER, FASTINT, STRING, OBJECT, LIGHTFUNC, BUFFER, POINTER
- **FASTINT** — 48-bit integer stored in the double's NaN-space (Duktape-compatible)
- **STRING** — Interned, reference-counted HString with inline UTF-8 data
- **OBJECT** — HObject with property table, prototype chain, object class flags

### 2.2 Bytecode
- 32-bit fixed-width instructions: `{ opcode(8), A(8), B(8), C(8) }`
- 91 opcodes covering loads, stores, arithmetic, calls, control flow, object access
- Formats: ABC, A_BC, A_SBX, WIDE_SABC, NONE
- Up to 256 registers per function, 16M constant pool

### 2.3 VM Execution
- Value stack with activation records (max 128 calls deep)
- Register-based: operands reference registers within current frame
- Inner/outer loop pattern: inner loop executes bytecode, outer loop restarts on ECMAScript-to-ECMAScript calls

### 2.4 Memory Management
- Reference counting for strings and objects (immediate free)
- Mark-and-sweep GC for cycles (not yet implemented)
- String interning via hash table with PRNG-seeded hash function
- Property table with open-addressing hash table on HObject

### 2.5 Scope Chain
- EnvRecord with parent link, bindings via HObject property table
- Global scope, function scope, catch scope
- Lexical environment (let/const) — not yet implemented

### 2.6 RegExp
- SKIP regexp implementation for now - well use a third party library

## 5. Key Technical Decisions

1. **FASTINT preservation** — Arithmetic ops keep FASTINT when both operands are FASTINT and result fits in 48-bit range. Fall back to NUMBER otherwise.

2. **NUMBER/FASTINT equivalence** — SEQ/SNEQ/EQ/NEQ treat NUMBER and FASTINT as the same ES type, comparing by numeric value.

3. **Deferred GETPROP** — Member expressions in LHS position (assignment target) defer GETPROP emission; PUTPROP is emitted instead when assignment is detected.

4. **String interning consistency** — Both compiler and runtime use the same heap's PRNG-seeded hash function for string deduplication. `str_table_insert` must not create duplicate entries.

5. **NaN semantics** — IEEE 754: `NaN !== NaN`, `NaN == NaN` returns false. `isNaN()` checks via `math::is_nan()`. `print_tval` displays "NaN" and "Infinity".

6. **Union field ordering** — TVal's union (boolean/number/fastint/pointer) is sensitive to write order. For NUMBER tag: set `number` LAST. For OBJECT tag: set `pointer` LAST.

## 6. Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| GC not implemented | Memory leaks on cyclic references | Defer; ref-counting covers 95% of cases |
| eval not implemented | 500+ tests blocked | Implement as separate compiler invocation |
| ES6+ complexity | 30,000+ tests require major effort | Prioritize ES5 conformance first |
| Performance | C3 compilation may differ from C | Profile and optimize hotspots |
| Duktape divergence | Architecture drift from reference | Regular comparison with duktape/src-separate/ |

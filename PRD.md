# PRD: Duktape C3 — ECMA-262 Compliant JavaScript Engine

## Goal

A port of the Duktape engine to C3, passing at least 80% of the ECMAScript test262 conformace suite.

Goals: beat Duktape in performance. Low memory consumption. Runnable on low-powered devices and multiple platforms.

## Technical notes

Leverage C3's native features for memory safety and it's stdlib; use Duktape's architecture as reference.

- RegExp is implemented using libregexp (from QuickJS)

- **FASTINT preservation** — Arithmetic ops keep FASTINT when both operands are FASTINT and result fits in 52-bit signed integer range (±2^51). Fall back to NUMBER otherwise. Bitwise ops always produce Int32 which fits in FASTINT.

- **String interning consistency** — Both compiler and runtime use the same heap's PRNG-seeded hash function for string deduplication. `str_table_insert` must not create duplicate entries.

- **Union field ordering** — TVal's union (boolean/number/fastint/pointer) is sensitive to write order. For NUMBER tag: set `number` LAST. For OBJECT tag: set `pointer` LAST.

- when path is unclear, compare Duktape source against QuickJS to figure out a viable approach

- ignore *staging* features in the ECMAScript spec, focus on ES5/ES6 core

( DO NOT EDIT )

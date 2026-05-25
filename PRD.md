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

### RegExp
- using libregexp (from QuickJS)

## Technical notes

- **FASTINT preservation** — Arithmetic ops keep FASTINT when both operands are FASTINT and result fits in 48-bit range. Fall back to NUMBER otherwise.

- **String interning consistency** — Both compiler and runtime use the same heap's PRNG-seeded hash function for string deduplication. `str_table_insert` must not create duplicate entries.

- **Union field ordering** — TVal's union (boolean/number/fastint/pointer) is sensitive to write order. For NUMBER tag: set `number` LAST. For OBJECT tag: set `pointer` LAST.

- when path is unclear, compare Duktape source against QuickJS to figure out a viable approach

- ignore *staging* features in the ECMAScript spec, focus on ES5/ES6 core

### Phase 19: Symbol (ES6)

- **Symbol** — constructor, Symbol.for(key), Symbol.keyFor(sym), Symbol.prototype.toString(), Symbol.prototype.valueOf()
- Symbol values stored as HString with 0xFF prefix byte and `is_symbol` flag
- Global symbol registry for `Symbol.for`/`Symbol.keyFor` using heap-resident linear arrays
- Keyword-as-property-name: compiler now accepts any keyword token after `.` as an IdentifierName (ES5 §11.2.1)
- GETPROP auto-box routes symbol primitives to Symbol.prototype (not String.prototype)

### Phase 20: Promise (ES6)

- **Promise** — constructor, Promise.resolve(x), Promise.reject(r), Promise.prototype.then(onFulfilled, onRejected), Promise.prototype.catch(onRejected), Promise.prototype.finally(onFinally), Promise.all(iterable), Promise.race(iterable)
- Internal state machine (pending/fulfilled/rejected) stored in HObject's array_part
- Reaction queue for chained `.then()` callbacks
- Static methods registered as LIGHTFUNC on the Promise constructor
- Class name `[object Promise]` wired in Object.prototype.toString

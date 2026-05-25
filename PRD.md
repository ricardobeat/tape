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

- **FASTINT preservation** — Arithmetic ops keep FASTINT when both operands are FASTINT and result fits in 52-bit signed integer range (±2^51). Fall back to NUMBER otherwise. Bitwise ops always produce Int32 which fits in FASTINT.

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

## Performance Optimizations (Session 59)

### FASTINT preservation
All arithmetic ops (SUB, MUL, MOD) now keep FASTINT when both operands are FASTINT and the result fits in the 52-bit signed integer range. Previously only ADD had this optimization.

Unary ops (UNP, UNM) keep FASTINT when the input is FASTINT — no conversion to double.

### Fast Int32 path for bitwise ops
Bitwise ops (BNOT, BAND, BOR, BXOR, SHL, SHR, USHR) extract Int32 operands directly without converting through double, and store results as FASTINT (always fits since Int32). This eliminates FASTINT→double→int32→double roundtrips.

### FASTINT direct comparison
Comparison ops (LT, LE, GT, GE) compare FASTINT operands directly as 64-bit integers, avoiding conversion to double. Mixed NUMBER/FASTINT comparisons still use `num_val()`.

### Session 60: Struct assignment for TVal + regs_base hoist

**Problem**: The VM inner dispatch loop copied TVal values field-by-field (tag, fastint, number, pointer = 4 separate stores) instead of using struct assignment. This caused 3 redundant 8-byte stores per copy (the union was written 3 times before the final write settled). Additionally, `regs_base` (the register-file base pointer into the valstack) was recomputed via `ptr_from_byteoff(vm.valstack, act.bottom_byteoff)` on every single instruction, despite being stable for the entire activation's lifetime.

**Fix**:
- Replaced all field-by-field copies in the dispatch loop with `*ra = *rb` struct assignment: LDREG, LDCONST, LDTHIS, GETPROP (all 5 auto-box branches), GETVAR (lex_env + var_env), CATCH
- Hoisted `regs_base` from the inner loop body to the outer restart loop, computing it once per activation instead of once per instruction

**Benchmark impact** (5-iteration averages):
| Benchmark | Before (ms) | After (ms) | Change |
|---|---|---|---|
| bench_object | 1053.4 | 833.8 | **-20.8%** |
| bench_function_call | 954.5 | 839.0 | **-12.1%** |
| bench_loop | 724.6 | 698.2 | -3.6% |
| bench_array | 196.9 | 193.8 | -1.6% |
| bench_property_lookup | 859.2 | 848.3 | -1.3% |
| bench_recursion | 3737.1 | 3719.0 | -0.5% |
| bench_string | 60.6 | 60.8 | +0.2% |

# Duktape-C3

A port of the [Duktape JavaScript engine](https://duktape.org/) from C to [C3](https://c3-lang.org/).

## Status

**Work in Progress** — Core infrastructure and compiler implemented (~7500 lines)

### Completed Modules ✅

- **`types.c3`** (458 lines) — Core type system
  - Tagged value representation (`TVal`)
  - Type checks and conversions
  - Heap object headers
  - Reference counting infrastructure

- **`heap.c3`** (465 lines) — Memory management
  - Heap allocation/deallocation
  - String interning table
  - Garbage collection hooks
  - Longjmp state for error handling

- **`hstring.c3`** (570 lines) — Interned strings
  - UTF-8 string representation
  - String hashing and interning
  - Character/codepoint iteration
  - String operations (concat, slice, compare)

- **`hobject.c3`** (878 lines) — JavaScript objects
  - Property storage and lookup
  - Object classes (Object, Array, Function, etc.)
  - Prototype chain
  - Property descriptors and attributes
  - Extensible, sealed, frozen states

- **`bytecode.c3`** (944 lines) — Bytecode VM
  - 91 opcodes (LDVAR, STVAR, CALL, ADD, etc.)
  - 4 instruction formats (ABC, A_BC, ABC_WIDE, SABC)
  - Compiled function representation
  - Constant pool
  - Disassembler

- **`lexer.c3`** (1266 lines) — JavaScript tokenizer
  - Full ES2015+ token set (106 token types)
  - Numbers: decimal, hex, octal, binary, float, scientific
  - Strings: escape sequences, Unicode, line continuations
  - Template literals
  - All punctuators including `?.`, `??`, `**`, `===`, `=>`, etc.
  - Comment handling
  - Strict mode support

- **`parser.c3`** (797 lines) — JavaScript parser
  - AST-based recursive descent parser
  - Expression parsing with precedence climbing
  - All operators: unary, binary, ternary, assignment
  - Member access (dot and bracket notation)
  - Control flow: if/else, while, for, return, break, continue
  - Variable declarations (var/let/const)
  - Block statements
  - Expression statements

- **`compiler.c3`** (2188 lines) — Bytecode compiler
  - Direct bytecode emission from parse tree
  - Register allocation
  - Scope management with lexical scoping
  - Constant pool generation
  - Jump patching for control flow
  - Loop and try/catch handling

### Next Steps 🔨

- **Executor** — Bytecode interpreter with call stack
- **Value Stack & API** — Public C API for embedding
- **Garbage Collector** — Mark-and-sweep with refcounting
- **Built-in Objects** — Object, Array, Function, String, Number, etc.
- **Built-in Functions** — Global functions (parseInt, isNaN, etc.)

## Building

Requires [C3 v0.8.0+](https://c3-lang.org/)

```bash
c3c build
```

This produces `out/duktape.a` static library.

## Project Structure

```
duktape-c3/
├── src/           # Core modules
│   ├── types.c3      # Type system
│   ├── heap.c3       # Memory management
│   ├── hstring.c3    # Interned strings
│   ├── hobject.c3    # JavaScript objects
│   ├── bytecode.c3   # VM instructions
│   ├── lexer.c3      # Tokenizer
│   ├── parser.c3     # Parser (AST)
│   └── compiler.c3   # Bytecode compiler
├── cli/           # CLI REPL (todo)
├── test/          # Tests (todo)
└── project.json   # C3 project config
```

## Design Notes

### Tagged Values

Like original Duktape, we use NaN-boxing for efficient value representation:
- 64-bit double for numbers
- Special NaN bit patterns for other types (undefined, null, bool, pointer)
- Pointer tagging for heap objects (strings, objects, functions)

### Memory Management

Hybrid approach:
- **Reference counting** for immediate reclamation
- **Mark-and-sweep GC** for cycles
- **String interning** for memory efficiency

### Bytecode

Register-based VM similar to Lua:
- Fixed 32-bit instructions
- Multiple formats for different operand counts
- Direct constant pool access
- Efficient for common operations

## License

MIT (following original Duktape license)

## References

- [Duktape](https://duktape.org/) — Original C implementation
- [C3 Language](https://c3-lang.org/) — C3 docs and spec
- [ECMAScript 2015+](https://262.ecma-international.org/) — JavaScript spec

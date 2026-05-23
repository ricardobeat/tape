# Agents — Duktape C3 Port Notes

> **High-level project phases and progress are tracked in `tasks.md`.**
> Check it before starting work to understand where we are and what's next.

## Implementation Process: Subagent-Driven Development

**For every implementation step, use subagents to:**

1. **Review original Duktape source** (`duktape/src-separate/`) for the feature being implemented
2. **Analyze the calling convention, data layouts, and VM semantics** in the original C code
3. **Propose the C3 implementation** using native C3 features (not just C-style ports)
4. **Implement the fix/feature** in the C3 codebase
5. **Build and test** to verify correctness

**Key principle**: This is a faithful port of Duktape v2.7.0 to C3, but we should leverage C3's native features where they improve clarity or safety:
- C3's `fault` system instead of C error codes
- C3's optionals (`T?`) instead of null checks
- C3's `defer` for cleanup
- C3's module system for organization
- C3's named parameters for clarity
- C3's `bitstruct` for flag fields

**When reviewing original Duktape code**, always note:
- The exact C implementation being ported
- Any simplifications or changes made for the C3 port
- Edge cases and error handling in the original

## C3 Syntax Findings (Critical for Agents)

### 1. No `->` operator — use `.` for pointer member access

C3 auto-dereferences pointers. Use `.` for both struct and pointer member access:

```c3
// WRONG (C-style)
ra->tag = UNDEFINED;
ra->pointer = null;
val->number = 42.0;

// CORRECT (C3)
ra.tag = UNDEFINED;
ra.pointer = null;
val.number = 42.0;
```

This applies everywhere: struct members, method calls on pointers, etc.

### 2. Type names cannot be ALL UPPERCASE

C3 enforces naming conventions:
- Types: `UpperCamelCase` (NOT `ALL_CAPS`)
- Functions/variables: `snake_case`
- Constants/enum values: `ALL_CAPS`

```c3
// WRONG
struct VM { ... }       // Error: Names of structs cannot be all uppercase
fn void test(VM* vm)    // Error: Parameter names may not be all uppercase

// CORRECT
struct Vm { ... }
fn void test(Vm* vm)
```

### 3. Enum member access uses `.` not `::`

```c3
enum TValTag : char { UNDEFINED, STRING, ... }

// WRONG
v.tag = TValTag::UNDEFINED;    // Error after module prefix

// CORRECT — bare name when type is in scope
v.tag = UNDEFINED;

// CORRECT — module-qualified
v.tag = types::UNDEFINED;
```

### 4. Module-qualified type + enum uses `.`

```c3
// WRONG
hobject::hobject_alloc(heap, hobject::ObjClass::OBJECT);

// CORRECT
hobject::hobject_alloc(heap, hobject::ObjClass.OBJECT);
```

### 5. Functions from other modules MUST use module prefix

```c3
import duktape::env;

// WRONG
env_declare(global_env, key, val);

// CORRECT
env::env_declare(global_env, key, val);
```

### 6. `%s` with `char*` (ZString) prints pointer address, not content

`io::printf("%s", char_ptr)` prints the pointer value in hex, NOT the string content.
Use `io::print(char_slice)` or manual byte-by-byte output:

```c3
// WRONG — prints hex pointer address
HString* s = ...;
io::printf("%s", s.get_cstr());

// CORRECT — print byte slice
HString* s = ...;
char[] d = s.get_data();
for (usz j = 0; j < d.len; j++) {
    io::putchar(d[j]);
}
```

### 7. `catch` bindings are scoped to the `if` block

```c3
// WRONG — f is not accessible outside the if block
CompiledFunction*? func = compiler::compile(&lex, hp);
if (catch f = func) { return 1; }
f.code_count;  // Error: 'f' not found

// CORRECT
CompiledFunction*? func = compiler::compile(&lex, hp);
CompiledFunction* f;
if (try ff = func) {
    f = ff;
} else {
    return 1;
}
f.code_count;  // OK
```

### 8. `io::print` vs `io::printfn`

- `io::print(value)` — prints without newline (works on String/char[])
- `io::printn(value)` — prints with newline
- `io::printf(fmt, ...)` — formatted print without newline
- `io::printfn(fmt, ...)` — formatted print with newline

### 9. String interning — use heap's hash function consistently

The heap's `hash_string()` uses a PRNG seed. ALL string interning must use the same
hash function to ensure pointer deduplication works:

```c3
// Both compiler and runtime must use heap.hash_string(), NOT hstring::hash_string()
uint hash = heap.hash_string(name);  // seeded — use this
// hstring::hash_string(name)        // unseeded — DON'T use this for interning
```

### 10. File loading

```c3
import std::io;

// Load file into temp-allocated buffer
char[]? source = file::load_temp("path/to/file.js");
if (catch err = source) { ... }
```

## Project Structure

```
src/
  types.c3       — TVal, TValTag, HeapHeader, fault codes
  heap.c3        — Heap allocator, string interning table
  hstring.c3     — Interned UTF-8 strings
  hobject.c3     — Objects with property tables
  bytecode.c3    — 91 opcodes, instruction encoding, CompiledFunction
  lexer.c3       — Tokenizer
  parser.c3      — AST parser (mostly done)
  compiler.c3    — Direct bytecode emission (bypasses parser)
  vm.c3          — Bytecode interpreter (value stack + activations)
  env.c3         — Scope chain / environment records
  builtins.c3    — Built-in functions (print, console.log)
```

## VM Architecture

- **Value stack**: Dynamic TVal array, registers accessed as `valstack[valstack_bottom + insn.a]`
- **Activation records**: Fixed-size array on VM struct (max 128)
- **Scope chain**: `EnvRecord` with parent link, bindings via `HObject` property table
- **String interning**: Compiler and runtime share the heap's string table for pointer deduplication

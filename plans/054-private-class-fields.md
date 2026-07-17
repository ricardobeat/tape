# Plan 054 — Private Class Fields

> **Status**: Draft (rev 2 — incorporates review fixes)
> **Target**: Implement `#name` private fields, methods, accessors, static private members, and public fields
> **Impact**: ~4,272 test262 tests reference private class features (currently all skipped)
> **Blocking**: C7 in BACKLOG.md

---

## Architecture Decision: Hidden Symbol Keys, Allocated at Class Evaluation

Private fields are stored as **regular properties with hidden symbol keys** on
instance objects. This is the QuickJS/Duktape approach and reuses the existing
property infrastructure entirely — `find_prop_idx()`, `put_prop()`, hash tables,
shapes all work unchanged because keys are `void*` (pointer equality). Hidden
symbols are HStrings with the `0xFF 0xFF` prefix; `hstring_alloc` already
auto-sets `is_symbol` + `is_hidden` (`src/hstring.c3:335`).

**Why hidden symbols, not a separate storage table:**
- Zero new runtime data structures for property lookup
- Shape deduplication works naturally
- No memory overhead per object beyond the property itself
- The key's `is_hidden` flag identifies private properties everywhere — no
  new `PropFlags` bit is needed (don't burn bit 4; check `key.is_hidden()`)

**Critical constraint — per-evaluation freshness.** Per spec
(ClassDefinitionEvaluation creates a fresh PrivateEnvironment), each
*evaluation* of a class produces distinct Private Names:

```js
function make() { return class { #x = 1; static get(o) { return o.#x; } }; }
const A = make(), B = make();
A.get(new B());   // must throw TypeError
```

Therefore private-name symbols **cannot live in the constant pool** (shared
across all evaluations of the same bytecode). Instead:

- A `NEW_PRIV_SYM` opcode allocates a fresh hidden symbol at class-evaluation
  time into a scope slot.
- Private accesses resolve the symbol from that slot (a compiler-managed
  lexical variable), exactly like QuickJS threads private names through
  closure variables.
- The class **brand** is one of these per-evaluation symbols.

**Critical constraint — own-property semantics.** `GETPROPC`/`PUTPROP` walk
the prototype chain; private access must not. `Object.create(instance).#x`
must throw TypeError. The brand check (`CHK_BRAND`) therefore does an
**own-property-only** lookup. Once the brand gates access, prototype-walking
reads of private *methods* (which legitimately live on the prototype) are
safe, and field reads find the own property directly.

**Brand checking** uses one unique hidden symbol per class evaluation, stamped
as an own property (`this[brand_sym] = true`) on every instance during
construction. One symbol suffices — own-presence of the unique key *is* the
check; no separate brand-value symbol.

**Field initialization** is compiled as a separate hidden init function called
by the VM at the spec-mandated point (after `this` binding). It is **not**
inlined into the constructor body — inlining is observably wrong (see P2f).

---

## Scope & Phasing

| Phase | What | New tests | Est. effort |
|-------|------|-----------|-------------|
| **P1** | Lexer + hidden symbols + `NEW_PRIV_SYM` + enumeration filter | 0 (infra) | Small |
| **P2** | Private fields (`#x = val`, `this.#x`, `this.#x = val`) | ~200 | Medium |
| **P3** | Private methods (`#m() {}`, `this.#m()`) + brand check | ~100 | Medium |
| **P4** | Private accessors (`get #x()`, `set #x()`) | ~60 | Small |
| **P5** | Static private (`static #x`, `static #m()`, `static get/set #x`) | ~80 | Medium |
| **P6** | `#x in obj` ergonomic brand checks | ~40 | Small |
| **P7** | Public fields (`x = val`, `static x = val`, `[expr] = val`) | ~200 | Medium |
| **P8** | Edge cases, error messages, test262 skip-list update | — | Small |

P2–P7 commit incrementally. P7 (public fields) shares all the field-init
infrastructure and should follow immediately.

**Out of scope** (explicitly, so the skips stay):
- Static initialization blocks (`static { ... }`) — `class-static-block`
  remains skipped; separate feature, separate plan.
- `nonextensible-applies-to-private` (Stage 3 proposal) — stays in
  `test262_skip.cfg`.

---

## P1 — Lexer & Infrastructure

### 1a. New token type: `HASH_IDENT`

**File**: `src/lexer.c3` — TokenType enum (after `OPT_CHAIN`, line ~82)

Add:
```
HASH_IDENT,    // #name — private identifier
```

The lexer scans `#` + identifier characters and produces a single `HASH_IDENT`
token. The token text is the identifier part **without** the `#` (e.g. `#foo`
produces token text `foo`).

### 1b. Lexer `#` handling

**File**: `src/lexer.c3` — single-char operator switch (~line 1517)

Add `case '#'` before the `default: LEX_ERROR`:
1. Advance past `#`
2. If next char is a valid identifier start (`[a-zA-Z_$]`):
   - Scan identifier continuation chars (`[a-zA-Z0-9_$]`)
   - Return `HASH_IDENT` with the identifier text (without `#`)
3. Otherwise: `LEX_ERROR` (bare `#` is invalid; hashbang `#!` at file start
   is a separate lexer feature, H1 in BACKLOG.md)

`HASH_IDENT` tokens must NOT be matched against the keyword table — the `#`
scanner returns `HASH_IDENT` directly, bypassing
`scan_identifier_or_keyword()`.

### 1c. Runtime hidden-symbol allocation: `NEW_PRIV_SYM`

**File**: `src/bytecode.c3` — new opcode

```c3
/// Allocate a fresh hidden symbol at class-evaluation time.
/// A=dst register, B=constant pool index of the description string
/// (e.g. "foo" or "#ClassName brand" — for debugging only).
/// dst := new hidden symbol (unique per execution of this instruction).
NEW_PRIV_SYM,
```

The handler wraps a `create_hidden_symbol(heap, desc)` helper in
`src/builtins/symbol.c3`: like `create_symbol_string()` (symbol.c3:20) but
with a `0xFF 0xFF` prefix instead of `0xFF`, unique hash from
`g_symbol_counter`, NOT interned. `hstring_alloc`'s existing prefix detection
sets `is_symbol` + `is_hidden` automatically.

The result is stored as a STRING TVal in a register/scope slot — normal
refcounting applies; no constant-pool involvement (`add_string_constant`
interns `char[]` and cannot hold these anyway, `src/compiler/constants.c3:92`).

### 1d. Private-name lexical slots

Each private name declared in a class body gets a **compiler-managed lexical
variable** in the scope enclosing the class, named with a source-illegal
prefix so user code can never collide, e.g. `"#priv:foo"` (and
`"#priv:<class> brand"` for the brand). At class evaluation:

```
NEW_PRIV_SYM  slot_foo,  "foo"
NEW_PRIV_SYM  slot_brand, "brand"
```

Method bodies, field initializers, and nested arrows reference these slots
through the **existing closure-variable machinery** — no new capture logic.
This is what makes per-evaluation freshness fall out for free: each class
evaluation runs `NEW_PRIV_SYM` again and closures capture that evaluation's
symbols.

### 1e. Enumeration filter for hidden symbols

**File**: `src/builtins/object.c3` (+ `src/builtins/reflect.c3`)

No `is_hidden()` filtering exists today (verified — zero call sites outside
hstring.c3). String-key paths already `continue` on `is_symbol()`, so only
the symbol-enumerating paths need the filter:

| Function | Change |
|----------|--------|
| `Object.getOwnPropertySymbols()` (object.c3:652) | `if (key.is_hidden()) continue;` |
| `ordinary_own_keys()` symbol phase | `if (key.is_hidden()) continue;` |
| `Reflect.ownKeys()` | `if (key.is_hidden()) continue;` |
| Proxy `ownKeys` trap target enumeration | same filter on the target walk |

This makes private fields completely invisible to user-code enumeration.
Grep for every `is_symbol()` check that *includes* (rather than skips)
symbols and audit each one.

---

## P2 — Private Instance Fields

### 2a. Two-phase private-name handling in the class compiler

**File**: `src/compiler/context.c3` + `src/compiler/class.c3`

```c3
const uint MAX_PRIVATE_NAMES = 64;

struct PrivateNameEntry {
    char[] name;        // e.g. "foo" (without #)
    uint   slot;        // lexical slot holding the runtime symbol
    bool   is_method;   // declared as method/accessor (affects write errors)
    bool   has_getter;
    bool   has_setter;
}

// Stack of private scopes — push on class entry, pop on class exit
PrivateNameEntry[MAX_PRIVATE_NAMES] private_names;
uint private_name_count;
uint[MAX_CLASS_NESTING] private_scope_start;
uint private_scope_count;
```

**Phase A — declaration pre-scan.** Before compiling any member bodies, scan
the class body's member names (using the existing lexer-snapshot/re-parse
machinery, cf. `deferred-member-target-reparse`) and **declare** every
private name in the current scope. Errors caught here:
- Duplicate declaration `class { #x; #x; }` → SyntaxError
  (exception: one getter + one setter for the same name is legal)
- `#constructor` → SyntaxError (spec: class-name `#constructor` forbidden)

**Phase B — strict resolution.** `resolve_private_name(name)` searches the
scope stack from innermost outward and returns the entry, or **SyntaxError**
if not found. There is **no** get-or-create: `this.#undeclared` in a class
that doesn't declare `#undeclared` is a compile-time error, as is `#x`
outside any class body.

Declaration-before-use across the body works naturally: a field initializer
may reference a `#name` declared later, because Phase A registered all names
first.

### 2b. Class body parser: detect `HASH_IDENT` members

**File**: `src/compiler/class.c3` — main class body loop (~line 371–532)

Add a `HASH_IDENT` branch alongside the existing name forms:
- `#foo = expr;` / `#foo;` → private field (init expr optional)
- `#foo(...)` → private method (P3)
- `get`/`set` followed by `HASH_IDENT` → private accessor (P4). The existing
  getter/setter detection path (~lines 431–484) sees IDENTIFIER `get`/`set`
  first, then must accept `HASH_IDENT` as the member name.
- `static`, `async`, `*` modifiers combine as usual.

### 2c. Field records

**File**: `src/compiler/context.c3`

```c3
const uint MAX_CLASS_FIELDS = 64;

struct ClassField {
    bool   is_static;
    bool   is_private;
    uint   priv_slot;        // lexical slot of the private symbol (private only)
    uint   key_const_idx;    // interned string key (public non-computed only)
    uint   computed_key_reg; // register holding the evaluated key (public computed only)
    // initializer compiled into the class's field-init function (see 2d)
}
```

### 2d. Field initializers compile into a hidden init function

All instance-field initializers for a class compile into **one hidden inner
function** (`__field_init__`), in source order, conceptually:

```js
function __field_init__() {   // called with this = the new instance
    this[#foo_sym] = <foo_init_expr>;
    this.publicField = <pub_init_expr>;
}
```

**Why a function, not inline bytecode in the constructor** (this is settled,
not open):
- `new.target` inside a field initializer must be `undefined`; inlined into
  the constructor it would see the constructor's `new.target`.
- `arguments` inside a field initializer is a **SyntaxError** (early error) —
  the initializer is its own function body, and compiling it as one gives the
  check a natural home.
- In a derived constructor, init must run **when `super()` returns**, at each
  `SUPER_CALL` site — not at constructor entry.
- The default derived constructor is synthesized without the lexer
  (`make_default_constructor`, `src/compiler/class.c3:22`); there is no body
  to inject into.

The init function is a normal inner function compiled inside the class scope,
so it closes over the private-name slots (1d) and has correct `[[HomeObject]]`
for `super.` property references in initializers.

Add to `CompiledFunction`:
```c3
uint field_init_inner_idx;   // MAX_INNER_FUNCS = no instance fields
uint brand_slot;             // lexical slot of the brand symbol (or sentinel)
```

### 2e. VM call sites for field init + brand stamp

**File**: `src/vm/vm_execute.c3`, `src/vm/vm_calls.c3`

- **Base class**: after `this` is allocated (vm_execute.c3:661 area), before
  the constructor body runs: stamp brand, then call `__field_init__(this)`.
- **Derived class**: inside `super_init_this_chain()` (vm_calls.c3:30), right
  after `this` is bound: stamp brand, then call `__field_init__(this)`.
- **Default constructors** (`make_default_constructor`): same VM-side hook —
  because the calls live in the VM construct path, synthesized constructors
  need no bytecode changes.

An abrupt completion from an initializer propagates out of the construction
normally.

### 2f. Private field access expressions

**File**: `src/compiler/expressions.c3`

`obj.#foo` (read):
1. Compile `obj` into a register
2. `resolve_private_name("foo")` → slot; load symbol from slot into `key_reg`
3. `CHK_BRAND obj_reg, brand_slot_reg` — own-only brand check (see 2g)
4. `GETPROP dst, obj_reg, key_reg` — after the brand check, the chain walk is
   safe: fields are own; methods/accessors are on the prototype by design

`obj.#foo = expr` (write):
1. Same resolution + `CHK_BRAND`
2. If the name resolved to a **method** (`is_method && !has_setter`):
   compile-time TypeError-at-runtime path — private methods are not writable;
   emit a throw. If accessor without setter: same.
3. `PUTPROP obj_reg, key_reg, val_reg`

Because the brand implies every declared field was unconditionally installed
by `__field_init__`, a passing brand check guarantees the own property exists
— `PUTPROP` cannot accidentally *create* a private field on a foreign object.

Also support:
- `obj?.#foo` — optional chaining short-circuits before the brand check
- `delete obj.#foo` → SyntaxError (early error, P8)

### 2g. Brand opcodes

**File**: `src/bytecode.c3`

```c3
/// Stamp brand: A=object, B=register holding the brand symbol.
/// obj[brand_sym] = true, as a non-enumerable, non-configurable,
/// non-writable own property. Skips the extensibility check
/// (PrivateFieldAdd/PrivateBrandAdd have no [[Extensible]] gate).
ADD_BRAND,

/// Check brand: A=object, B=register holding the brand symbol.
/// TypeError unless obj has brand_sym as an OWN property.
/// Own-only: must NOT walk the prototype chain, otherwise
/// Object.create(instance).#x would falsely pass.
CHK_BRAND,
```

One symbol per class evaluation serves as the brand; own-presence of the key
is the entire check (no brand *value* symbol — presence of the unique key is
already unforgeable).

**Inheritance**: `Base` stamps `this[base_brand]`, `Derived` stamps
`this[derived_brand]` — different keys, no collision. A subclass instance
carries both brands, so both classes' private accesses work.

**Spec note**: the spec only installs brands for classes with private
methods/accessors and uses field-presence (PrivateFieldFind) for fields. We
stamp the brand whenever the class has *any* private member and use it
uniformly. This is observably equivalent because `__field_init__`
unconditionally installs every field alongside the brand. The known deviation
is the skipped `nonextensible-applies-to-private` cluster (out of scope).
`ADD_BRAND` and the field-init `PUTPROP`s must bypass the extensibility check
so that the return-override trick (`constructor() { return frozenObj; }`)
still installs fields per spec — route them through a raw own-property
define, not the generic `put_prop` path.

---

## P3 — Private Methods

Private methods are stored as **non-writable, non-enumerable,
non-configurable properties** on the **prototype** (instance methods) or
**constructor** (static), keyed by the per-evaluation hidden symbol.

### 3a. Compilation

When `#foo(...)` is parsed:
1. Resolve `#foo` (declared in Phase A) → slot
2. Compile the body as an inner function (same as regular methods); generator
   (`*#m`) and async (`async #m`) combine naturally — existing machinery
3. Extend `ClassMethod`:
   ```c3
   bool is_private;
   uint priv_slot;   // lexical slot of the hidden symbol
   ```
4. Method installation (~class.c3:762–816): load the symbol from its slot
   into `key_reg`, then the existing `CLASS_INITPROP` — but with
   `{writable:false, enumerable:false, configurable:false}` flags for the
   private case.

### 3b. Access

`this.#method()` compiles as:
```
CHK_BRAND this, brand_reg
GETPROP   f, this, method_sym_reg    // found on the prototype — fine, brand gated
CALL      dst, f, this, ...
```

No new opcodes. `.name` is `"#foo"` — prepend `#` when building
`method_name_buf`.

---

## P4 — Private Accessors

`get #foo()` / `set #foo(v)`: the getter/setter path (class.c3:431–484)
accepts `HASH_IDENT` after `get`/`set`; install via `CLASS_INITGET`/
`CLASS_INITSET` with the symbol loaded from its slot. Phase A records
`has_getter`/`has_setter` so that:
- `get #x` + `set #x` in one class → legal, merged
- read of a set-only accessor / write of a get-only accessor → TypeError

Access is identical to fields (brand check + `GETPROP`/`PUTPROP`; the VM's
existing accessor-property dispatch invokes the getter/setter).

---

## P5 — Static Private Members

- `static #x = expr` → own property on the **constructor object**; static
  field inits compile into a second hidden init function
  (`__static_init__`) run once right after class evaluation, with
  `this` = the constructor.
- `static #m()` / `static get/set #x` → installed on the constructor with
  hidden-symbol keys.
- Brand: `ADD_BRAND ctor_reg, brand_reg` during class evaluation (a separate
  static brand symbol, distinct from the instance brand — `C.#m` must not
  work on instances and vice versa). `C.#x` access then brand-checks the
  constructor.

---

## P6 — `#x in obj` (Ergonomic Brand Checks, ES2022)

The `class-fields-private-in` feature flag appears throughout the private
test dirs; without this a large slice stays red.

**File**: `src/compiler/expressions.c3` — in the `in` relational parse, when
the LHS token is `HASH_IDENT`:
1. `resolve_private_name` → slot (SyntaxError if unresolved — `#x in obj`
   outside a declaring class is an early error)
2. Emit an own-property presence test of the symbol on the RHS object —
   a non-throwing variant of `CHK_BRAND` (or a `HAS_OWN` opcode if one
   exists; add `CHK_BRAND`'s boolean twin otherwise). For methods/accessors,
   test the **brand** instead of the key (the key lives on the prototype).

Result is a boolean; RHS must be an object else TypeError.

---

## P7 — Public Fields

Public fields reuse the field-init functions from P2/P5. Differences:
- Key is an interned string (or an evaluated computed key), not a symbol
- No brand check
- `enumerable: true`, installed via **CreateDataPropertyOrThrow** semantics
  (own define, not `[[Set]]` — must not trigger setters on the prototype)

**Computed keys** `[expr] = val`: per spec the key expression is evaluated
**once, at class-definition time**, in source order interleaved with method
name evaluation — *not* per construction. Compile the key evaluation into the
class-evaluation bytecode, store the result in a hidden lexical slot (same
mechanism as private-name slots), and have `__field_init__` read the slot.

Name inference: `x = function(){}` / `x = () => {}` / `x = class {}` gets
`name` `"x"` — route through the existing fn-name inference used for
assignments.

---

## P8 — Edge Cases & Cleanup

### 8a. Early errors (compile time)

- `delete obj.#foo` → SyntaxError
- `#foo` reference with no declaration in any enclosing class → SyntaxError
- Duplicate private declaration (except get/set pair) → SyntaxError
- `#constructor` as a private name → SyntaxError
- `arguments` in any field initializer → SyntaxError
- `super()` call in a field initializer → SyntaxError

### 8b. Runtime errors

- Brand-check failure → TypeError: "Cannot read private member #foo from an
  object whose class did not declare it"
- Write to private method / get-only accessor → TypeError
- `this.#foo` before `super()` in a derived constructor → the existing `this`
  TDZ machinery already throws ReferenceError

### 8c. Test262 skip-list updates

In `scripts/run_test262.py` UNSUPPORTED_PATTERN, remove (per phase, as each
lands):
- `class-fields-private`, `class-static-fields-private` (P2/P5)
- `class-methods-private`, `class-static-methods-private` (P3)
- `class-fields-private-in` (P6)
- `class-fields-public`, `class-static-fields-public` (P7)

Keep skipped: `class-static-block`, `nonextensible-applies-to-private`.

---

## Implementation Order (Recommended Commits)

1. **Commit 1 (P1)**: Lexer `HASH_IDENT` + `create_hidden_symbol` +
   `NEW_PRIV_SYM` opcode + enumeration filters. Pure infra, zero behavior
   change.
2. **Commit 2 (P2)**: Private instance fields — two-phase name scope,
   `__field_init__`, `ADD_BRAND`/`CHK_BRAND` (own-only), VM init hooks.
   Enable `class-fields-private`.
3. **Commit 3 (P3)**: Private methods. Enable `class-methods-private`.
4. **Commit 4 (P4)**: Private accessors.
5. **Commit 5 (P5)**: Static private members. Enable the static suites.
6. **Commit 6 (P6)**: `#x in obj`. Enable `class-fields-private-in`.
7. **Commit 7 (P7)**: Public fields (incl. computed keys evaluated once).
   Enable the public-field suites.
8. **Commit 8 (P8)**: Edge cases, error messages, skip-list cleanup.

---

## Risk Assessment

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| Per-evaluation freshness regressions (shared symbols) | High | `NEW_PRIV_SYM` at evaluation time is the design; test the `make()` twice pattern explicitly |
| Proto-chain leakage through brand/field lookup | High | `CHK_BRAND` is own-only by definition; test `Object.create(instance).#x` |
| Brand inheritance bugs (subclass private access) | High | Per-class brand keys; test `class B extends A` with private members in both |
| Field init ordering (computed keys, side effects) | Medium | Single `__field_init__` in source order; computed keys evaluated at class definition |
| `this` TDZ in derived field init | Medium | Init runs inside `super_init_this_chain` after `this` binds |
| Refcount bugs on symbols in scope slots | Medium | Normal TVal refcounting; watch the class-scope teardown path (cf. `builtin-result-ownership`) |
| Hidden symbols leaking via enumeration | Low | P1e filters + audit of every symbol-including `is_symbol()` path |
| Shape explosion from unique keys per evaluation | Medium | Classes evaluated in loops create distinct shapes per evaluation — same cost as QuickJS; acceptable |

---

## Files to Modify

| File | Changes |
|------|---------|
| `src/lexer.c3` | `HASH_IDENT` token, `#` scanner |
| `src/compiler/tokens.c3` | `HASH_IDENT` advance/peek helpers |
| `src/compiler/context.c3` | Private-name scope (two-phase), `ClassField`, slots |
| `src/compiler/class.c3` | Pre-scan pass, private member parsing, `__field_init__`/`__static_init__` compilation, brand emission |
| `src/compiler/expressions.c3` | `obj.#foo` read/write, `obj?.#foo`, `#x in obj` |
| `src/bytecode.c3` | `NEW_PRIV_SYM`, `ADD_BRAND`, `CHK_BRAND`; `field_init_inner_idx`/`brand_slot` on CompiledFunction |
| `src/builtins/symbol.c3` | `create_hidden_symbol()` helper |
| `src/builtins/object.c3` | `is_hidden` filter in symbol enumeration |
| `src/builtins/reflect.c3` | `is_hidden` filter in `ownKeys` |
| `src/vm/vm_execute.c3` | Brand stamp + field-init call in base construct path; opcode dispatch |
| `src/vm/vm_calls.c3` | Brand stamp + field-init call in `super_init_this_chain` |
| `src/vm/vm_control.c3` | `NEW_PRIV_SYM`/`ADD_BRAND`/`CHK_BRAND` handlers |
| `scripts/run_test262.py` | Remove private/public field skip patterns per phase |

---

## Quick Reference: ES2022 Spec Sections

| Section | Topic |
|---------|-------|
| §6.2.4 | PrivateEnvironmentRecord |
| §7.3.23 | PrivateElementFind(O, P) |
| §7.3.24 | PrivateFieldAdd(O, P, V) |
| §7.3.25 | PrivateGet(O, P) |
| §7.3.26 | PrivateSet(O, P, V) |
| §7.3.27 | PrivateBrand / InitializeInstanceElements |
| §7.3.28 | PrivateMethodOrAccessorAdd(O, P, method, isStatic) |
| §13.10.1 | RelationalExpression: PrivateIdentifier `in` |
| §15.7.14 | ClassDefinitionEvaluation |
| §15.7.15 | ClassElementEvaluation |

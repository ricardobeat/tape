# Plan 038: Numeric Separators & BigInt

## Numeric Separators (`1_000_000`)

ES2021 feature. Already partially implemented in the lexer — hex, octal, binary paths
compute value inline and skip `_` correctly. **Decimal path is broken**: it passes the
raw source (with `_` chars) to `strtod`, which stops at the first `_`.

**Fix**: strip underscores from the `strtod` buffer before parsing.

### Files
- `src/lexer.c3` — `scan_number()`, decimal `strtod` block (~line 832)

### Validation
- `just rosetta` — no regressions
- `just run test/num_sep.js` — all values correct

---

## BigInt

New primitive type. Adds `typeof` support, arithmetic, comparison, and basic conversions.

### Files
- `src/types.c3` — new `TAG_BIGINT`, TVal union case, `set_bigint()`/`get_bigint()`
- `src/lexer.c3` — scan `123n` as `BIGINT` token type
- `src/compiler/expressions.c3` — emit bigint literal constants
- `src/vm/vm_execute.c3` — bigint arithmetic/comparison opcodes (or error for MVP)
- `src/builtins/*.c3` — `typeof` returns `"bigint"`, `BigInt()` constructor
- `test/bigint.js` — test file

### Scope (MVP)
- Literal syntax: `123n`, `0xFFn`
- `typeof x === "bigint"`
- Implicit conversion errors (bigint + number throws TypeError)
- No full arithmetic suite — defer to a follow-up plan

### Validation
- `just rosetta` — no regressions
- `just run test/bigint.js` — basic ops pass

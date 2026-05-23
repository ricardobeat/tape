# Duktape C3 — Next Impact Priorities

Based on test262 analysis:

## High Impact, Low Effort
1. **Fix SETALEN** — array `.length` is never set (1-line fix)
2. **Built-in functions** — `parseInt`, `parseFloat`, `isNaN`, `isFinite`
3. **Exponentiation operator `**` ** — already implemented in bytecode, add test

## Medium Impact, Medium Effort  
4. **Implement `new` operator** — 59 test262 tests
5. **Implement `for-in`** — 115 test262 tests (INITFOR/NEXTFOR stubs)
6. **Implement try/catch/throw** — 201 test262 tests

## Near Future
7. **Rest parameters** — `function(...args)` 
8. **Array built-ins** — `.push`, `.pop`, `.length`
9. **String built-ins** — `.indexOf`, `.slice`

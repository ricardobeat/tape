# Technical Debt Cleanup — Magic Constants, Callable Kind, Tagged Struct, Proto Iterator

## Motivation

Four low-risk refactoring items identified during the May 29 review that improve
code clarity, reduce sentinel-based logic, and eliminate duplicated patterns
with minimal behavioural change.

---

## Item 1 — Named Constants for Magic Buffer Sizes

**Scope**: `src/vm.c3`, `src/builtins.c3`  
**Risk**: Very low (pure rename)  
**Effort**: ~10 minutes

### Current state

Two magic sizes appear as literals:

| Size     | Sites (vm.c3) | Sites (builtins.c3) |
|----------|---------------|---------------------|
| `char[160]` | 15            | 0                   |
| `char[32]`  | 1             | 6                   |

Every use allocates a stack buffer then calls `libc::snprintf(&buf, N, ...)`
followed by a length check `len > 0 && len < N`. The `160` constant exists only
in `vm.c3` (error-message formatting); `32` exists in both files (number/date
formatting).

All `char[160]` sites follow the same pattern:

```c3
char[160] buf;
int len = libc::snprintf(&buf, 160, "...", ...);
if (len > 0 && len < 160) {
    HString* msg_str = intern_string(vm, buf[:len]);
    // ... set .message on error object
}
```

All `char[32]` sites follow the same pattern:

```c3
char[32] buf;
int len = libc::snprintf(&buf, 32, "...", ...);
if (len < 0) { /* error handling */ }
// ... use buf[:len] to create interned string
```

### Plan

1. Add two `const` declarations in `src/types.c3` (within a dedicated section
   near the top, after the `USE_NANBOX` constant):

    ```c3
    /// Maximum length of a formatted error-message string (160 bytes).
    const uint ERROR_MSG_BUF = 160;
    /// Maximum length of a number/date-to-string temporary buffer (32 bytes).
    const uint FORMAT_BUF = 32;
    ```

    *Why `types.c3`?* It is the lowest-level module already imported by both
    `vm.c3` and `builtins.c3` via `import common;`. No new dependency edges.

2. In `src/vm.c3`: replace all 15 `char[160] buf` → `char[types::ERROR_MSG_BUF] buf`,
   and the corresponding `snprintf(..., 160, ...)` / `len < 160` literals.

3. In `src/vm.c3`: replace the one `char[32] buf` (line 452) → `char[types::FORMAT_BUF] buf`,
   and the `snprintf(..., 32, ...)` / `len >= 32` literal.

4. In `src/builtins.c3`: replace all 6 `char[32] buf` → `char[types::FORMAT_BUF] buf`,
   and the corresponding `snprintf(..., 32, ...)` literals.

5. **Smoke test**: `c3c build test_vm && ./out/test_vm test/simple.js` still prints `3`.

### Validation

- grep for `char\[16[09]\]` and `char\[3[12]\]` after changes to verify no literals remain.
- The `160` is used as both allocation size AND snprintf limit — both must change.
- The `32` is used as both allocation size AND snprintf limit — both must change.
- C3 `const uint` can be used in array declaration via `char[N] buf` (confirmed valid).

---

## Item 2 — `enum CalleeKind` to Replace `builtin_fn_index < 0` / `comp_func != null` Dual Guard

**Scope**: `src/hobject.c3` (enum + struct field), `src/vm.c3` (call sites),
          `src/builtins.c3` (assignment sites)  
**Risk**: Low (new field replaces two-field guard; `comp_func` and
          `builtin_fn_index` remain for their non-classification uses)  
**Effort**: ~20 minutes

### Current state

Callable objects fall into two categories, currently discriminated by a **two-field
guard** at every call site:

```c3
// Pattern A — builtin callable:
comp_func == null && builtin_fn_index >= 0
// Pattern B — compiled function callable:
comp_func != null && builtin_fn_index < 0
```

This pattern appears at 10+ sites across `vm.c3` (call, constructor invoke,
new, super calls). The guard is redundant: `builtin_fn_index >= 0` implies
`comp_func == null` and vice-versa, but the code checks both to be safe.

Additionally, callable-but-neither objects exist (bound functions) where
`comp_func == null && builtin_fn_index < 0`, caught by `is_callable()` before
the guard is even reached.

### Plan

1. Add an enum in `src/hobject.c3` near the `ObjClass` / `ObjFlags` definitions
   (after the existing enums at the top):

    ```c3
    /// Discriminator for a callable object's invocation kind.
    /// Stored in HObject.callable_kind.  Meaningful only when
    /// flags.callable is true.
    enum CallableKind : ushort {
        COMPILED_FN,        /// JS function — dispatch via comp_func
        BUILTIN_FN,         /// Native builtin — dispatch via builtin_fn_index
        BOUND_FN,           /// Bound function — dispatch via bound_call logic
        OTHER               /// Callable but none of the above (rare)
    }
    ```

2. Add a field to `HObject` (insert after line 345, before the closing `}`):

    ```c3
        /// Discriminator for this callable's invocation kind (meaningful only
        /// when flags.callable is true).
        CallableKind  callable_kind;
    ```

3. In `hobject.c3`, update the object initialiser (line ~934–944) to set
   `obj.callable_kind = CallableKind.OTHER` in the common path, then override
   at each assignment of `comp_func` or `builtin_fn_index`.

4. Update the two key assignment patterns in `builtins.c3`:

   - When `func_obj.builtin_fn_index = (int)fn_index;` is set → also set
     `func_obj.callable_kind = CallableKind.BUILTIN_FN;`
   - When `func_obj.builtin_fn_index = -1;` is set (function object) → also set
     `func_obj.callable_kind = CallableKind.COMPILED_FN;`
   - Bound function `bound_obj.builtin_fn_index = (int)BUILTIN_BOUND_CALL;`
     → `bound_obj.callable_kind = CallableKind.BOUND_FN;`

5. Replace compound guards in `vm.c3`:

    **Before:**
    ```c3
    if (hobj != null && hobj.is_callable() && hobj.comp_func == null && hobj.builtin_fn_index >= 0) {
    ```
    **After:**
    ```c3
    if (hobj != null && hobj.is_callable() && hobj.callable_kind == CallableKind.BUILTIN_FN) {
    ```

    **Before:**
    ```c3
    if (hobj_fast != null && hobj_fast.is_callable() && hobj_fast.comp_func != null && hobj_fast.builtin_fn_index < 0) {
    ```
    **After:**
    ```c3
    if (hobj_fast != null && hobj_fast.is_callable() && hobj_fast.callable_kind == CallableKind.COMPILED_FN) {
    ```

    **Before (discrimination via `comp_func == null`):**
    ```c3
    if (hobj.comp_func == null) {
        if (hobj.builtin_fn_index >= 0) {
    ```
    **After:**
    ```c3
    if (hobj.callable_kind == CallableKind.BUILTIN_FN) {
    ```

6. For the few remaining direct checks on `comp_func` (e.g., line 815 `hobj.comp_func != null`
   in the dynamic call fast path, line 2178 `setter_obj.comp_func != null` for
   accessor invocations), these stay as-is — they check for the *presence of a
   compiled function*, not for classification. The enum is for the two-field
   *guard* only.

7. **Backward compat**: The old `comp_func == null && builtin_fn_index >= 0`
   pattern would still work after this change; we replace it everywhere
   systematically in one pass.

### Validation

- All 10+ sites with `builtin_fn_index < 0` or `builtin_fn_index >= 0` guards
  in `vm.c3` must be converted to the enum check.
- The `builtin_fn_index = -1` sentinel stays valid (still used as sentinel for
  "no builtin index" in the non-callable case) but never needs to be compared
  at classification sites.
- `c3c build test_vm` compiles. `./out/test_vm test/simple.js` returns `3`.
- Run test262 subset if available.

---

## Item 3 — Tagged Struct Return for `get_prop_or_accessor_proto`

**Scope**: `src/hobject.c3`, `src/vm.c3:1982`  
**Risk**: Low (return type change, one call site)  
**Effort**: ~10 minutes

### Current state

The function `get_prop_or_accessor_proto` currently returns a `PropLookupKind`
enum and writes two out-params + one optional out-param:

```c3
fn PropLookupKind HObject.get_prop_or_accessor_proto(
    &self, void* key, bool want_getter,
    AccessorResult* acc_out, TVal* data_out, HObject** owner_out)
{
    // ...
    return PropLookupKind.PROP_ACCESSOR;  // acc_out set
    // or
    *data_out = pe.value;
    *owner_out = cur;
    return PropLookupKind.PROP_DATA;
}
```

Call site at `vm.c3:1982`:

```c3
hobject::AccessorResult acc;
TVal data_val;
HObject* owner = null;
hobject::PropLookupKind kind = hobj.get_prop_or_accessor_proto(key, true, &acc, &data_val, &owner);
if (kind == hobject::PropLookupKind.PROP_ACCESSOR) {
    // use acc
} else if (kind == hobject::PropLookupKind.PROP_DATA) {
    // use data_val, owner
}
```

### Plan

1. Define a small tagged union struct in `src/hobject.c3` (near `PropLookupKind`):

    ```c3
    /// Combined result of a prototype-chain lookup.
    /// Either `kind == PROP_DATA` (use `data_val`, optionally `owner`),
    /// or `kind == PROP_ACCESSOR` (use `acc`),
    /// or `kind == PROP_NOT_FOUND`.
    struct PropLookupResult {
        PropLookupKind kind;
        union {
            struct { TVal data_val; HObject* owner; };
            AccessorResult acc;
        };
    }
    ```

2. Change the function signature to return `PropLookupResult`:

    ```c3
    fn PropLookupResult HObject.get_prop_or_accessor_proto(
        &self, void* key, bool want_getter)
    {
        // ...
        return { .kind = PropLookupKind.PROP_ACCESSOR, .acc = { .accessor_fn = ..., .this_obj = ..., .found = true } };
        // or
        return { .kind = PropLookupKind.PROP_DATA, .data_val = pe.value, .owner = cur };
        // or
        return { .kind = PropLookupKind.PROP_NOT_FOUND };
    }
    ```

3. Update the call site in `vm.c3`:

    ```c3
    hobject::PropLookupResult res = hobj.get_prop_or_accessor_proto(key, true);
    if (res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
        // use res.acc
        TVal obj_val;
        obj_val.set_object(hobj);
        if (invoke_getter(vm, &res.acc, &obj_val, (uint)insn.a, act, &curr_pc, &needs_restart, regs_base)) { ... }
    } else if (res.kind == hobject::PropLookupKind.PROP_DATA) {
        *ra = res.data_val;
        if (res.owner != null && ic_base != null) { ... }
    }
    ```

### Validation

- C3 supports anonymous union inside struct (confirmed via compiler tests).
- The `union` layout must be such that `PropLookupResult.size` equals
  `sizeof(PropLookupKind) + max(sizeof(AccessorResult), sizeof(TVal) + sizeof(HObject*))`.
- No other call sites exist (confirmed: `get_prop_or_accessor_proto` called once).
- `c3c build test_vm` compiles. `./out/test_vm test/simple.js` returns `3`.

---

## Item 4 — Factor Duplicated Proto-Chain Walks Into an Iterator

**Scope**: `src/hobject.c3` (existing helpers + new iterator),
          `src/vm.c3` (3 open-coded walks)  
**Risk**: Medium (introduces new abstraction; existing helpers remain for
          callers that don't need the iterator)  
**Effort**: ~25 minutes

### Current state

There are **three distinct proto-chain walk patterns** open-coded in `vm.c3`:

1. **INSTANCEOF** (line 1777–1786) — walk to check if `cur == proto_obj`
2. **GETPROTOTYPEOF / prototype check** (line 1851–1860) — same pattern,
   different starting object
3. **for-in key collection** (line 654) — walk collecting all enumerable keys

And **four helpers** in `hobject.c3` that also do their own walk:

- `get_prop_proto` (line 1008–1021)
- `find_accessor_proto` (line 1030–1054)
- `get_prop_or_accessor_proto` (line 1134–1157)
- `has_prop_proto` (line 1162–1174)

All use `const uint MAX_PROTO_DEPTH = 256;` as a local constant, and all follow
the pattern:

```c3
const uint MAX_PROTO_DEPTH = 256;
HObject* cur = self;
uint depth = 0;
while (cur != null && depth < MAX_PROTO_DEPTH) {
    // ... process cur ...
    cur = cur.prototype;
    depth++;
}
```

### Plan

1. **Define a shared constant** in `src/hobject.c3` at module scope (replace the 7
   local copies):

    ```c3
    /// Maximum prototype chain depth before we assume a cycle / infinite loop.
    const uint MAX_PROTO_DEPTH = 256;
    ```

2. **Create an iterator macro** that encapsulates the walk:

    ```c3
    /// Iterate over each object in the prototype chain starting at `obj`.
    /// `depth` is a `uint` counter available inside the loop body.
    /// Example:
    ///     hobject::foreach_proto(obj, depth) {
    ///         // use obj (the loop variable) and depth
    ///     }
    macro foreach_proto(obj, depth, body) {
        $foreach depth = 0;  // shadow variable

    }
    ```

   Actually, C3 macros support `$foreach` but the cleanest approach for this
   codebase is a **simple helper function** that returns the next object:

    ```c3
    /// Return the next object in the prototype chain, or null if the chain
    /// is exhausted or exceeds MAX_PROTO_DEPTH.
    /// Advances `depth` by one.
    fn HObject*? proto_next(HObject* cur, uint* depth) {
        if (cur == null) return null~;
        if (*depth >= MAX_PROTO_DEPTH) return null~;
        cur = cur.prototype;
        (*depth)++;
        return cur;
    }
    ```

   Wait — C3 optionals cannot express "null-but-not-exhausted" well.
   Better: a simple `fn HObject* proto_next(HObject* cur, uint* depth)` that
   returns `null` when done, and caller checks `cur == null`.

   Actually, the cleanest C3 approach is a macro with a while-loop wrapper:
   This is complex due to C3 macro limitations. Let me think of a simpler approach.

   **Alternative — simple helpers for the two common patterns:**

   (a) `is_prototype_of(probe, target)` for the INSTANCEOF/GETPROTOTYPEOF
       checks — returns bool.

   (b) Keep the existing helpers as-is but make them all use the shared
       `MAX_PROTO_DEPTH` constant instead of local copies.

   (c) For the for-in collector, use the shared constant.

   This is less ambitious but doesn't require C3 macro gymnastics.

3. **Concrete sub-plan**:

    a. Add `const uint MAX_PROTO_DEPTH = 256;` once at module scope in
       `hobject.c3` (before the helper functions, around line 1000).

    b. Remove the 4 local `const uint MAX_PROTO_DEPTH = 256;` declarations in
       `hobject.c3` (lines 1008, 1030, 1134, 1162).

    c. Remove the 3 local declarations in `vm.c3` (lines 641, 1777, 1851).
       They must reference `hobject::MAX_PROTO_DEPTH` instead.

    d. Add a convenience predicate in `hobject.c3`:

        ```c3
        /// Returns true if `probe` appears anywhere in the prototype chain of `obj`.
        fn bool HObject.is_prototype_of(&self, HObject* probe) {
            HObject* cur = self;
            uint depth = 0;
            while (cur != null && depth < MAX_PROTO_DEPTH) {
                if (cur == probe) return true;
                cur = cur.prototype;
                depth++;
            }
            return false;
        }
        ```

    e. Replace the two open-coded INSTANCEOF/GETPROTOTYPEOF walks in `vm.c3`
       (lines 1777–1786 and 1851–1860) with calls to `rb.is_prototype_of(proto_obj)`:

        ```c3
        // Before (line 1779):
        const uint MAX_PROTO_DEPTH = 256;
        uint depth = 0;
        while (cur != null && depth < MAX_PROTO_DEPTH) {
            if (cur == proto_obj) { ra.set_boolean(true); break; }
            cur = cur.prototype;
            depth++;
        }

        // After:
        if (rb.is_prototype_of(proto_obj)) {
            ra.set_boolean(true);
        }
        ```

    f. For the for-in collector (line 654), keep the open-coded walk but
       reference `hobject::MAX_PROTO_DEPTH` instead of the local constant.

4. **Impact on existing helpers**:
   - `get_prop_proto` — keeps its own loop, uses shared `MAX_PROTO_DEPTH`.
   - `find_accessor_proto` — keeps its own loop, uses shared `MAX_PROTO_DEPTH`.
   - `get_prop_or_accessor_proto` — keeps its own loop, uses shared `MAX_PROTO_DEPTH`.
   - `has_prop_proto` — keeps its own loop, uses shared `MAX_PROTO_DEPTH`.

   These are all doing different things inside the loop body; a shared iterator
   would require callback/macro abstractions that aren't worth the complexity
   in this codebase.

### Validation

- All 7 local `const uint MAX_PROTO_DEPTH = 256;` declarations removed.
- `hobject::MAX_PROTO_DEPTH` referenced from `vm.c3` where the local was used.
- The 2 INSTANCEOF/GETPROTOTYPEOF walks replaced with `is_prototype_of()`.
- `c3c build test_vm` compiles. `./out/test_vm test/simple.js` returns `3`.
- For-in key collection still works (the for-in collector is the most complex
  walk and must be manually verified via test262 or a property enumeration test).

---

## Execution Strategy

| Item | Dependencies | Parallelizable | Recommended order |
|------|-------------|---------------|-------------------|
| 1    | None        | Yes with 2    | 1st (trivial, safe) |
| 2    | None        | Yes with 1    | 2nd (touches many files) |
| 3    | None        | Yes with 4    | 3rd (single function, single call site) |
| 4    | None        | Yes with 3    | 4th (medium risk, last) |

All four items are independent and could be done in any order. The recommended
order goes from safest/most mechanical to most impactful.

After each item: `c3c build test_vm && ./out/test_vm test/simple.js` for smoke test.

---

## Risk Assessment

| Item | Risk | Mitigation |
|------|------|------------|
| 1    | Low  | Simple find-and-replace; grep verifies no survivors |
| 2    | Low  | New field doesn't affect layout significantly (1 `ushort`); old guards still compile but are replaced systematically; grep for remaining `builtin_fn_index < 0` and `builtin_fn_index >= 0` |
| 3    | Low  | Single call site; compiler catches mismatches; union reduces pointer/param count |
| 4    | Medium | New `is_prototype_of` method; ensures INSTANCEOF/GETPROTOTYPEOF match existing behaviour; for-in walk unchanged pattern |

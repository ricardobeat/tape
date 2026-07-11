# Plan 050 — Proxy (and the minimal Reflect it needs)

Status: PLANNED (session 276). Scoped against the live tree; `built-ins/Proxy` and
`built-ins/Reflect` are currently excluded from the test262 denominator
(`scripts/run_test262.py:100` dir-skip, `:132` feature-flag `Proxy`). Landing this
deliberately grows the subset (plan 040 no-silent-shrinkage rule).

## Why / scope decision

| Directory / tag | Raw tests | Notes |
|---|---|---|
| built-ins/Proxy (dir) | 311 | The trap semantics + invariant matrix |
| `features: [Proxy]` elsewhere | 479 total | ~168 outside the Proxy dir: Array/Object/RegExp/for-of paths that probe engine behavior *through* a Proxy |
| built-ins/Reflect (dir) | 153 | Excluded separately ([[reflect-excluded]]); Proxy default-trap behavior is defined in terms of Reflect but does **not** require the JS-visible `Reflect` global |

Real-world motivation: Proxy is depended on by more mainstream tooling than BigInt or
async-iteration — Vue 3 reactivity, MobX, immer, `sinon`, various ORMs, and any
membrane/observability library. It is the highest real-world-coverage-per-unit-effort
of the three deferred features. It is also the **hardest to make invariant-correct** —
test262's Proxy suite is largely about the [[Get]]/[[Set]]/[[Delete]]/[[DefineOwnProperty]]
invariants that a trap result is validated against.

### Engine state today

Scaffolding exists but is inert:
- `ObjClass.PROXY` enumerated (src/hobject.c3:129).
- `flags.exotic_proxyobj` bit reserved (src/hobject.c3:209), set in the plain-object
  init path (src/hobject.c3:1650-1651).
- Sized as a plain 72-byte object (src/hobject.c3:574, :590, :628).
- **No** target/handler storage, **no** `Proxy` global, **no** interception anywhere.

### Out of scope (documented exclusions)

- `Proxy.revocable` beyond the basic revoked-throws behavior is *in* scope (cheap), but
  `Reflect` as a JS global stays excluded ([[reflect-excluded]]) — we implement the
  Reflect *operations* as internal C3 helpers, not as a user-visible object.
- Proxy-as-`class extends` target, Proxy-as-`new.target`, and Proxy exotic `[[Call]]`/
  `[[Construct]]` on a non-callable target: the `apply`/`construct` traps are in scope;
  Proxy participating in the class subclassing machinery is a follow-up.

## The core architectural problem

Property access is **not funneled through one chokepoint**. There are ~824 call sites
touching `get_prop_proto` / `get_prop_or_accessor_proto` / `put_prop` / `has_prop_proto`
/ `es_delete_prop` across the tree, and ~163 of them are inside `src/builtins/*.c3`.
The VM opcode handlers (`GETPROP`/`PUTPROP`/`GETPROPC`/`DELPROP`/`IN` at
src/vm/vm_execute.c3:1704-1873, src/vm/vm_property.c3) are one family; the builtins are
another. A Proxy's whole point is that *every* MOP (meta-object protocol) operation on it
must route to a trap. So the prerequisite is a **single MOP layer** that both the VM and
builtins call, with Proxy interception living inside it.

We do **not** need to rewrite 824 call sites. The plan is:

1. Introduce ordinary-object MOP entry points that already exist in spirit
   (`get_prop_or_accessor_proto`, `put_prop`, …) as the *only* sanctioned MOP surface,
   and add a `proxy_dispatch` fast check at the top of each.
2. Because a Proxy can appear anywhere an object can, the check must be at the MOP
   boundary, not the call sites. Any call site that reaches an HObject through one of
   the sanctioned entry points gets Proxy behavior for free.
3. Audit the ~163 builtin call sites only for ones that reach into `array_part()` /
   `prop_values()` **directly** (bypassing the MOP) — those are the leaks. The array
   generics I touched this session (`arr_get_elem_vm`, `arr_has_prop`) are exactly this
   pattern and already funnel most reads correctly; the direct-slot writers are the risk.

## Design

### D1. Storage — target + handler in the extra union

Add to the `HObjectExtra` union (src/hobject.c3:410+):

```c3
struct HObjectProxy {
    HObject* target;    // [[ProxyTarget]] — null once revoked
    HObject* handler;   // [[ProxyHandler]] — null once revoked
}
```

Fits in the 72-byte plain layout (two pointers). GC must mark both (heap.c3 trace
switch, keyed on `obj_class == PROXY`). Revocation = set both to null; every trap entry
checks `target == null` → throw TypeError "Cannot perform '<op>' on a proxy that has been
revoked".

### D2. A `proxy_op_*` helper per essential internal method

Implement the 13 essential internal methods as C3 functions taking `(vm, proxy, ...)`.
Each: (a) revoked check, (b) `trap = GetMethod(handler, "<name>")`, (c) if trap is
undefined → forward to the target's ordinary MOP (this is the "default = Reflect.x"
behavior, done in C3, no JS Reflect), (d) call the trap, (e) **validate the result
against the target's invariants**, throwing TypeError on violation.

The 13, in rough dependency order (get/set/has/getOwnPropertyDescriptor/defineProperty
are the bulk of the tests):

| Internal method | Trap | Invariant checks (the hard part) |
|---|---|---|
| [[Get]] | `get` | non-configurable non-writable data prop → result must SameValue target's; non-configurable accessor w/ undefined getter → result must be undefined |
| [[Set]] | `set` | mirror of Get for writability |
| [[Has]] | `has` | can't hide a non-configurable own prop; can't report absent on non-extensible target's own prop |
| [[GetOwnProperty]] | `getOwnPropertyDescriptor` | the densest invariant set — configurability/extensibility consistency, completion of the returned descriptor |
| [[DefineOwnProperty]] | `defineProperty` | can't add to non-extensible; can't define incompatible with a non-configurable existing |
| [[Delete]] | `deleteProperty` | can't delete a non-configurable own prop |
| [[OwnPropertyKeys]] | `ownKeys` | must include all non-configurable keys + all keys if non-extensible; no dup keys; keys must be String/Symbol |
| [[GetPrototypeOf]] | `getPrototypeOf` | non-extensible target → must return target's proto |
| [[SetPrototypeOf]] | `setPrototypeOf` | mirror |
| [[IsExtensible]] | `isExtensible` | must agree with target |
| [[PreventExtensions]] | `preventExtensions` | can't report success unless target is non-extensible |
| [[Call]] | `apply` | target must be callable |
| [[Construct]] | `construct` | target must be a constructor; result must be Object |

### D3. Wiring into the VM

At the top of each MOP boundary function (`get_prop_or_accessor_proto`, `put_prop`,
`has_prop_proto`, `es_delete_prop`, and the descriptor/keys/proto/extensible helpers used
by `Object.*`), add:

```c3
if (self.flags.exotic_proxyobj) return proxy_op_get(...);  // etc.
```

Because these are already the funnels for the VM opcodes (vm_property.c3) and for
`builtins_generic_get` (163 builtin uses), one guard per boundary covers most of the
surface. `[[Call]]`/`[[Construct]]` hook into the call dispatch (`vm_calls.c3`) — a Proxy
with `callable`/`constructor` flags mirrored from its target.

### D4. `IsCallable` / `IsConstructor` / `IsArray` recursion

`Array.isArray(proxy)` and internal IsArray must recurse through the proxy target
(spec §7.2.2). `typeof proxy` is `"function"` iff the target is callable. These are small
but easy to forget — they read the proxy's target, not the proxy.

## Risks / why it's large

1. **The invariant matrix is the work**, not the trap plumbing. Getting D2's right-hand
   column correct across all 13 methods is most of the 311 dir tests.
2. **Slot-bypass leaks.** Any builtin that reads `array_part()`/`prop_values()` directly
   on what turns out to be a Proxy silently skips the trap. Requires an audit of the ~163
   builtin property touches; the array/typed-array generics are the main offenders.
3. **Recursion + revocation mid-operation.** A trap can revoke its own proxy, or return
   another proxy; the validation reads of the *target* must themselves be MOP calls
   (a target can be a proxy). Re-entrancy and stack depth need care.
4. **No JS Reflect to lean on.** The spec defines defaults via Reflect; we hand-roll each
   default forward in C3. Correct, but it means the "trap absent" path is real code per
   method, not a one-liner.

## Effort estimate

**Large — ~2,000–3,000 lines, multi-session.** Roughly: storage + global + revocable
(~1 day), the 13 trap functions with defaults (~2 days), the invariant validation matrix
(~2–3 days, the bulk), slot-bypass audit + IsArray/IsCallable recursion (~1 day). Highest
real-world payoff of the three deferred features; also the highest correctness surface.

Sequencing suggestion: land get/set/has/getOwnPropertyDescriptor/defineProperty/ownKeys
first (covers the majority of tests and the reactivity-library use case), then the
proto/extensibility group, then apply/construct.

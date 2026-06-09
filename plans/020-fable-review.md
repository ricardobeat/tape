# Plan 020 — Optimization Review (Fable)

Codebase review for simple optimizations with performance, size, or memory
efficiency gains. Findings ordered by impact-to-effort ratio. Checked against
the optimization history in progress.md (sessions 114–148); none overlap with
work already done.

## High impact

### 1. GC pacing is capped far too low — likely the biggest win

**Where:** `src/heap.c3:45-47`, `src/heap.c3:1626-1633`

A full mark-and-sweep runs every ≤4096 allocations (`GC_MAX_TRIGGER = 4096`),
but each pass costs O(live objects): it walks the whole heap list to clear
flags, marks, and sweeps. Once a program holds ~100k live objects, you pay a
100k-object traversal every 4096 allocations — total GC cost grows
quadratically with heap size.

**Fix:** set the next trigger proportional to `live_obj_count`
(e.g. `max(1024, live_obj_count)`) and drop the 4096 cap. One-line change,
large speedup on allocation-heavy workloads.

### 2. String wrapper objects eagerly materialize one property per character

**Where:** `src/builtins/string.c3:19` (`populate_string_indexed_props`),
called from `src/vm.c3:5837`, `src/vm.c3:6133`, `src/builtins/object.c3:64`,
`src/builtins/object.c3:172`, `src/builtins/array.c3:1815`,
`src/builtins/string.c3:63`

The loop does `snprintf` + `str_intern` + `put_prop` per character — and each
`put_prop` performs a shape transition. A wrapper around a 10KB string creates
10k properties (24 bytes each, plus interned key strings, plus 10k shape
transitions).

**Fix:** the `exotic_stringobj` flag already exists. Serve indexed reads from
`HString.char_at` in the property-get path and only materialize properties
when actually enumerated. Big memory and perf win whenever strings are boxed.

### 3. `snprintf("%u")` used for integer-index keys inside loops

**Where:** `src/vm.c3:919`, `src/vm.c3:3545`, `src/vm.c3:4165`,
`src/vm.c3:4275`, `src/vm.c3:4516`; `src/builtins/string.c3:744`, `768`,
`797`, `842`, `884`, `907`, `1782`

Rest params, spread, apply, and string/array index paths format each index
with `snprintf`, which is ~10–20× slower than the `int_to_buf` helper that
already exists at `src/vm.c3:495`.

**Fix:** mechanical substitution of `snprintf("%u", i)` → `int_to_buf`.
Additionally, add a small-integer string cache in `Heap` (an `HString*[256]`
for indices 0–255, like Duktape/QuickJS) to skip the FNV hash + table probe
per element entirely.

### 4. `"toString"` / `"valueOf"` re-interned on every object coercion

**Where:** `src/vm.c3:581` (`vm_to_string`), `to_primitive_value` around
`src/vm.c3:755-845`; also `"[object Object]"` and `"[function]"` at
`src/vm.c3:594-597`

Every object→string or ToPrimitive conversion hashes and probes the string
table for `"toString"` / `"valueOf"`. The `BuiltinStr` pre-interned cache
(`src/heap.c3:296`) doesn't include them.

**Fix:** add `TO_STRING`, `VALUE_OF` (and optionally `OBJECT_OBJECT`,
`FUNCTION_BRACKET`) to the `BuiltinStr` enum and use the cache. Trivial
change, removes hashing from a very hot coercion path.

## Medium impact

### 5. `PropFlags` stored twice — drop it from `PropValue`

**Where:** `src/hobject.c3:291-297` (`PropValue`) vs `src/hobject.c3:305-310`
(`ShapeProperty`)

Property flags live both in the shared `ShapeProperty` and in every per-object
`PropValue`. `PropValue` is 24 bytes (two 8-byte TVals + 1 flag byte + 7
padding); removing the duplicated flags shrinks it to 16 bytes — a 33%
reduction in per-object property storage and better cache density on every
property scan.

**Fix:** read flags from the shape at call sites. Mechanical but touches
several files; `delete_prop`'s private-shape rebuild needs care.

### 6. Iterator state fields burden every object

**Where:** `src/hobject.c3:417-420`

`iterator_target`, `iterator_index`, `iterator_kind` (16 bytes) sit in every
`HObject` but are only used by iterator-class objects (iterator.c3, map.c3,
set.c3).

**Fix:** move them into the `HObjectExtra` union as a new variant — saves 16
bytes per object heap-wide. The GC mark of `iterator_target` in heap.c3 needs
an obj-class guard.

### 7. `Array.prototype.join` truncates silently at 4096 bytes

**Where:** `src/builtins/array.c3:585-609`

Correctness bug as much as a perf issue: results longer than 4090 bytes are
silently cut off. It also copies byte-by-byte in nested loops.

**Fix:** two-pass approach — sum element lengths, allocate once, `memcpy`
pieces. Faster and correct.

### 8. Number→string always uses `%.17g`

**Where:** `src/vm.c3:534` (`vm_number_to_string`)

`0.1` stringifies as `"0.10000000000000001"` — spec-violating output (ES
requires shortest round-trip) and longer strings to hash/intern.

**Fix:** format with `%.15g`, `strtod` it back, and only fall back to
`%.16g`/`%.17g` if it doesn't round-trip. Fixes observable behavior and
shrinks interned numeric strings.

## Minor (compile-time / code size)

- **Keyword lookup is a linear scan** over ~40 entries with byte-compare for
  every identifier token (`src/lexer.c3:171`). Dispatch on length or first
  character first — cuts lexing cost on identifier-dense code.
- **Constant pool dedup is O(n²)** (`src/compiler.c3:706` scans all existing
  constants per add). Fine for small functions; a hash keyed by value bits
  would help large literal-heavy scripts.
- **Allocator bypass:** `ensure_prop_hash` and `grow_props` use
  `libc::malloc/realloc` directly (`src/hobject.c3:545`, `936-938`), skipping
  the heap's pluggable allocator and its accounting — worth unifying if custom
  allocators matter.

## Suggested sequencing

1. **#1 and #4** — near one-liners, immediate wins.
2. **#3** — mechanical substitution plus small-int cache.
3. **#2** — lazy string-wrapper indices (largest combined perf + memory win).
4. **#5–#8** as follow-ups, each independently landable.

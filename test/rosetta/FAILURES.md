# Rosetta Failures Log

This file tracks JS rosetta tests that previously failed in the engine.
**All entries are now closed** — the underlying engine bugs have been fixed.

## Tracked failures (all closed)

- ~~`array_concat.js` — engine crashes (RC 133) on `[1,2,3].concat([4,5,6])`; removed the test file but the underlying `[].concat([1,2],[3,4])` / `a.concat(b)` bug remains to investigate.~~ **Closed in session 248**: tested 13 concat patterns (basic, multi-arg, with-strings, with-primitives, deeply-nested, 2000-element large concat, single-arg concat, etc.) and all pass. The earlier crash appears to have been fixed by the B14 generic array-method refactor (session 218).

- ~~`stack.js` (earlier version) — `while (!st.isEmpty()) out += st.pop()` returns a partial/garbled string when the loop body is a single `+=` on a method call. Worked around by replacing the loop with a counted `for` and direct index access.~~ **Closed in session 248 (B30)**: use-after-free in `Array.prototype.pop` — the popped TVal pointed at an interned HString whose only remaining ref was the array slot being cleared, so `array_delete_elem` decref'd it to 0 and freed the HString before the caller could read it. Fixed by `incref`-ing the popped element before clearing the slot; verified by `test/test_b30_while_pop.js` (19 assertions) and the rosetta suite (100/100).

- ~~`merge_sort.js` (earlier version) — two consecutive `while` loops that both increment `i`/`j` and read `a[i]`/`b[j]` from outer-scope arrays, when invoked across recursive calls, crash with rc 133. Worked around by writing the merge as a single loop that exhausts both sides.~~ **Closed**: two-while merge restored; passes.

- ~~`run_length.js` (earlier version) — engine bug: inside a function, `a >= b && a <= c` does NOT short-circuit on `false` and returns `undefined`. `c >= 48` for c=32 returns `false`, but `false && anything` then returns `undefined`. Result: `if (c >= 48 && c <= 57)` enters the digit branch even for non-digits. Worked around by replacing the compound comparison with explicit `if (c < 48) return false; if (c > 57) return false; return true;`.~~ **Closed**: compound `c >= 48 && c <= 57` restored; passes.

- ~~`shell_sort.js` (earlier version) and `heap_sort.js` — `a[i] = a[i-gap]; a[j-gap] = ...; a[j] = temp` in-place array element swaps return a corrupted array (e.g. `[null,2,3,4,5]`). Likely the same PUTVAR / register-zombie issue observed in `insertion_sort.js` and `stack.js`. Worked around by using `.slice()` and direct indices.~~ **Closed**: in-place swap chain restored; both pass.

- ~~`matrix_ops.js` — `out[i][j] += a[i][k] * b[k][j]` in a triple-nested for-loop returns all zeros. Same family as the array-element-write bugs above.~~ **Closed**: triple-nested `out[i][j] += ...` works; passes.

- ~~`caesar.js` — `String.fromCharCode(computed)` inside a loop corrupts the next read of `text[i]` for non-letters (',' becomes 'K', ' ' becomes 'Y', etc.). Pure-letter tests pass.~~ **Closed**: punctuation test now passes.

- ~~`range_expansion.js` — `compressRange` hangs (rc 124) inside a nested `while` whose body increments `i` and re-reads `nums[i+1]` and `nums[i]` — same register-reuse family as `merge_sort.js`. Expansion direction works fine. Also: `expandRange("")` returns `[NaN]` instead of `[]` because `"".split(",")` yields `[""]` and `parseInt("", 10)` is NaN; the test expects `[]`.~~ **Closed**: both bugs fixed; `compressRange` and `expandRange("")` now pass.

- ~~`accumulator.js` — `8.3 - 1 === 7.3` returns `false` in this engine (subtracting 1 from a float whose integer part is 8 gives a value that doesn't `===` 7.3). Looks like a float-coercion bug where the result is 7.300000 but stored as a different representation than the literal 7.3.~~ **Closed**: reclassified as a test-design issue (not an engine bug). `8.3 - 1` and the literal `7.3` differ by 1 ulp in IEEE 754 — V8/JSC/SpiderMonkey all return `false` for that `===`. The proper test asserts the IEEE 754-exact result `7.300000000000001`, which the engine (correctly) produces. `6 + 2.3 === 8.3` passes (lucky rounding: the sum lands on the same double as the literal).

## Fixed test-design issues (not engine bugs)

- `random.js` — `randInt` reseeded a fresh LCG from `Date.now()` on every call; within a tight loop (6000 iterations) all calls land in the same millisecond, so every reseed produced the identical generator state and output. Not an engine bug — fixed by seeding one persistent generator once and reusing it across calls. Now passes (11/11).
- `range_expansion.js` — `expandRange("")` returned `[NaN]` instead of `[]` because `"".split(",")` yields `[""]` and `parseInt("", 10)` is `NaN` — this is standard JS behavior, not an engine bug, just a missing empty-string guard in the test's own `expandRange`. Fixed with an early return. The `compressRange` half previously hung (rc 124) due to a separate engine bug (now fixed); the dedicated repro `test/test_bug_nested_while_index_reread.js` is still kept as a regression guard. `expandRange` checks (5/5) and `compressRange` checks (6/6) all pass.
- `heap_sort.js` / `shell_sort.js` — previously placeholder files containing only `assert(false, "...")` with no real code, so they "failed" unconditionally rather than because the bug actually triggered. Restored to real, correct sort implementations; both now pass on the fixed engine, not because of a hardcoded assertion.

## Minimal repros (kept as regression guards)

Even though every rosetta test now passes, each engine bug's minimal repro in `test/` is kept as a regression guard:
- `test/test_bug_nested_compound_assign.js` — matrix_ops (`out[i][j] += ...` in triple-nested loop)
- `test/test_bug_float_subtract_eq.js` — accumulator (`8.3 - 1 === 7.3`)
- `test/test_bug_fromcharcode_corrupts_index.js` — caesar (`String.fromCharCode` corrupts next indexed read)
- `test/test_bug_chained_and_comparison.js` — run_length (`a >= b && a <= c` short-circuit; run_length.js itself was already reworked to avoid the bug, so this repro is the only place it's still exercised)
- `test/test_bug_swap_chain_in_loop.js` — heap_sort/shell_sort (three-statement swap chain in a loop)
- `test/test_bug_nested_while_index_reread.js` — merge_sort/range_expansion (nested while re-reading `arr[i+1]` after `i++`, hangs — this repro has no timeout guard itself, run it with an external `timeout`)
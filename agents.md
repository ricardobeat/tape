# Agents — Duktape C3 Port Notes

> **High-level project phases and progress are tracked in `progress.md`.**
> Check it before starting work to understand where we are and what's next.

## Implementation Process: Subagent-Driven Development

**Key principle**: This is a faithful port of Duktape v2.7.0 to C3, but we should leverage C3's native features where they improve clarity or safety. Check the stdlib reference for what is available when planning a new feature.

**When reviewing original Duktape code**, always note:
- The exact C implementation being ported
- Any simplifications or changes made for the C3 port
- Edge cases and error handling in the original

## NaN-Boxing Gotchas (src/types.c3)

The NaN-boxing encoding uses `NANBOX_BASE | (tag << shift) | payload` to store tagged values in the mantissa of IEEE 754 NaN values. Two bugs were found and fixed during implementation:

1. **Tag shift collides with NaN exponent bits**: `NANBOX_TAG_SHIFT = 48` placed tags in bits 55-48, which overlap with NANBOX_BASE's `0xFFF8...` prefix. The correct shift is **40**, placing tags in bits 47-40 where NANBOX_BASE has zeros. `NANBOX_PAYLOAD_MASK` must also be `0x000000FFFFFFFFFF` (bits 39-0), not `0x0000FFFFFFFFFFFF`.

2. **C3 operator precedence in `nanbox_is_double`**: The expression `(v >> 52) & 0x7FF != 0x7FF0` parses as `(v >> 52) & (0x7FF != 0x7FF0)` in C3, which evaluates to `(v >> 52) & 1` — making every tagged value look like a double. Must use parentheses: `((v >> 52) & 0x7FF) != 0x7FF`.

**Rule of thumb**: In C3, always parenthesize bitwise operations mixed with comparisons. `&` / `|` / `^` bind differently than in C.

3. **Fastint sign extension with 40-bit payload**: The payload is only 40 bits (not 52), so negative fastints lose their sign bit when encoded via `(ulong)val & 0x000000FFFFFFFFFF`. The fix: `get_fastint()` must check bit 39 (not bit 51) for sign, and sign-extend with `0xFFFFFF0000000000` (not `0xFFF0000000000000`). Range is ±2^39 (~549 billion), sufficient for typical JS integer values.

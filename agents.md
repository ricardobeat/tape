# Duktape C3 Port


> **See spec at PRD.md.**
> **High-level project phases and progress are tracked in `progress.md`.**
> Check it before starting work to understand where we are and what's next.

**Key principle**: This is a faithful port of Duktape v2.7.0 to C3, but we should leverage C3's native features where they improve clarity or safety. Check the stdlib reference for what is available when planning a new feature.

## Build Flags

- `-D NONANBOX` — disable NaN-boxing, using the 16-byte tagged union `TVal` instead. Default is nanbox-on. Use `just build-nonanbox` or `just test-nonanbox` to exercise the non-nanbox path (e.g., for 16-bit ESP32 targets).

## NaN-Boxing Gotchas (src/types.c3)

The NaN-boxing encoding stores tagged values in the mantissa of IEEE 754 NaN values using Duktape's scheme: **16-bit tags in bits 63-48**, 48-bit payload in bits 47-0.

### Current encoding (Duktape-style)

Tags are full 16-bit values: `TAG_FASTINT=0xFFF1`, `TAG_UNDEFINED=0xFFF3`, etc. A value is a double if `bits >> 48 <= 0xFFF0`. Tagged values have `bits >> 48 >= 0xFFF1`.

**NaN normalization**: Negative NaNs have bits 63-48 in 0xFFF8-0xFFFF, which collides with tagged values. `set_number()` normalizes any double with bits 63-48 >= 0xFFF8 to the canonical positive NaN `0x7FF8000000000000`.

**Fastint sign extension**: 48-bit payload, branchless: `(long)(bits << 16) >> 16`. Range is ±2^47 (~140 trillion).

### Bugs encountered during implementation

1. **C3 operator precedence in `nanbox_is_double`**: The expression `(v >> 52) & 0x7FF != 0x7FF0` parses as `(v >> 52) & (0x7FF != 0x7FF0)` in C3, which evaluates to `(v >> 52) & 1` — making every tagged value look like a double. Must use parentheses: `((v >> 52) & 0x7FF) != 0x7FF`.

**Rule of thumb**: In C3, always parenthesize bitwise operations mixed with comparisons. `&` / `|` / `^` bind differently than in C.

2. **Small tag scheme collision**: An earlier scheme used 4-bit tags (0-8) shifted into bits 51-48 with `NANBOX_BASE = 0xFFF8000000000000`. This collided because NANBOX_BASE already has bits 51-48 = 0x8, making `nanbox_get_tag(UNDEFINED)` return 8 instead of 0. Fixed by switching to Duktape's 16-bit tag scheme.

3. **Negative NaN collision**: A scheme with `NANBOX_BASE = 0xFFF0000000000000` and 4-bit tags in bits 51-48 worked for positive values but negative NaN doubles (0xFFF8...) had bits 51-48 = 0x8, colliding with tags. Fixed by NaN normalization in `set_number()`.

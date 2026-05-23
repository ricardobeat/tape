# Agents — Duktape C3 Port Notes

> **High-level project phases and progress are tracked in `progress.md`.**
> Check it before starting work to understand where we are and what's next.

## Implementation Process: Subagent-Driven Development

**Key principle**: This is a faithful port of Duktape v2.7.0 to C3, but we should leverage C3's native features where they improve clarity or safety. Check the stdlib reference for what is available when planning a new feature.

**When reviewing original Duktape code**, always note:
- The exact C implementation being ported
- Any simplifications or changes made for the C3 port
- Edge cases and error handling in the original

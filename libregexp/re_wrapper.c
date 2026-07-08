/*
 * RegExp wrapper — implementation using QuickJS libregexp
 */
#include <stdlib.h>
#include <string.h>
#include "libregexp.h"
#include "re_wrapper.h"

/* User-provided callbacks for libregexp */
bool lre_check_stack_overflow(void *opaque, size_t alloca_size)
{
    (void)opaque; (void)alloca_size;
    return false;
}

int lre_check_timeout(void *opaque)
{
    (void)opaque;
    return 0;
}

void *lre_realloc(void *opaque, void *ptr, size_t size)
{
    (void)opaque;
    if (size == 0) { free(ptr); return NULL; }
    return realloc(ptr, size);
}

struct ReCompiled {
    uint8_t* bc;
    int      bc_len;
    int      capture_count;
};

ReCompiled* re_compile(const char* pattern, size_t pattern_len,
                       int flags, char* error_msg, int error_msg_size)
{
    int lre_flags = 0;
    if (flags & RE_FLAG_IGNORECASE)   lre_flags |= LRE_FLAG_IGNORECASE;
    if (flags & RE_FLAG_MULTILINE)    lre_flags |= LRE_FLAG_MULTILINE;
    if (flags & RE_FLAG_DOTALL)       lre_flags |= LRE_FLAG_DOTALL;
    if (flags & RE_FLAG_UNICODE)      lre_flags |= LRE_FLAG_UNICODE;
    if (flags & RE_FLAG_STICKY)       lre_flags |= LRE_FLAG_STICKY;
    if (flags & RE_FLAG_INDICES)      lre_flags |= LRE_FLAG_INDICES;
    if (flags & RE_FLAG_UNICODE_SETS) lre_flags |= LRE_FLAG_UNICODE_SETS;
    /* per ES2024: u and v are mutually exclusive */
    if ((lre_flags & LRE_FLAG_UNICODE) && (lre_flags & LRE_FLAG_UNICODE_SETS)) {
        if (error_msg && error_msg_size > 0) {
            strncpy(error_msg, "invalid regular expression flags", error_msg_size - 1);
            error_msg[error_msg_size - 1] = '\0';
        }
        return NULL;
    }

    char internal_error[128];
    int bc_len;
    uint8_t* bc = lre_compile(&bc_len, internal_error, sizeof(internal_error),
                               pattern, pattern_len, lre_flags, NULL);
    if (!bc) {
        if (error_msg && error_msg_size > 0) {
            strncpy(error_msg, internal_error, error_msg_size - 1);
            error_msg[error_msg_size - 1] = '\0';
        }
        return NULL;
    }

    ReCompiled* re = (ReCompiled*)malloc(sizeof(ReCompiled));
    if (!re) { lre_realloc(NULL, bc, 0); return NULL; }

    re->bc = bc;
    re->bc_len = bc_len;
    re->capture_count = lre_get_capture_count(bc);

    if (error_msg && error_msg_size > 0) error_msg[0] = '\0';
    return re;
}

/* Decode a single UTF-8 (CESU-8) byte sequence starting at p, advance *p past it. */
static uint32_t decode_utf8_unit(const uint8_t** p, const uint8_t* end)
{
    const uint8_t* s = *p;
    uint8_t c0 = s[0];
    if (c0 < 0x80) { *p = s + 1; return c0; }
    if ((c0 & 0xE0) == 0xC0 && s + 1 < end) {
        *p = s + 2;
        return ((c0 & 0x1F) << 6) | (s[1] & 0x3F);
    }
    if ((c0 & 0xF0) == 0xE0 && s + 2 < end) {
        *p = s + 3;
        return ((c0 & 0x0F) << 12) | ((s[1] & 0x3F) << 6) | (s[2] & 0x3F);
    }
    /* invalid/truncated lead byte: treat as a single raw byte unit */
    *p = s + 1;
    return c0;
}

/*
 * Convert a CESU-8 buffer (each UTF-16 code unit independently encoded as a
 * standalone UTF-8 sequence) into a flat uint16_t buffer, and record for each
 * emitted code unit the CESU-8 byte offset it started at (plus one trailing
 * entry for the end-of-buffer byte offset), so exec results can be mapped
 * back from code-unit offsets to CESU-8 byte offsets.
 */
static uint16_t* cesu8_to_utf16(const uint8_t* input, int input_len,
                                 int** out_byte_offsets, int* out_unit_count)
{
    uint16_t* units = (uint16_t*)malloc(sizeof(uint16_t) * (input_len + 1));
    int* offsets = (int*)malloc(sizeof(int) * (input_len + 1));
    if (!units || !offsets) { free(units); free(offsets); return NULL; }

    const uint8_t* p = input;
    const uint8_t* end = input + input_len;
    int n = 0;
    while (p < end) {
        offsets[n] = (int)(p - input);
        units[n] = (uint16_t)decode_utf8_unit(&p, end);
        n++;
    }
    offsets[n] = input_len;

    *out_byte_offsets = offsets;
    *out_unit_count = n;
    return units;
}

/* Map a code-unit offset (as returned by lre_exec in 16-bit modes) back to a
 * CESU-8 byte offset using the offsets table built by cesu8_to_utf16(). */
static int unit_offset_to_byte_offset(const int* byte_offsets, int unit_count, int unit_offset)
{
    if (unit_offset < 0) return -1;
    if (unit_offset > unit_count) unit_offset = unit_count;
    return byte_offsets[unit_offset];
}

int re_exec(ReCompiled* re, const char* input, int input_len,
            int start_offset,
            int* out_start, int* out_end, int* out_num_captures,
            int* caps_start, int* caps_end, int max_captures)
{
    if (!re || !re->bc) return RE_ERROR;

    int total_captures = re->capture_count;
    if (total_captures > RE_MAX_CAPTURES) total_captures = RE_MAX_CAPTURES;

    uint8_t* capture[RE_MAX_CAPTURES * 2];

    /* lre_exec derives is_unicode from the compiled bytecode itself and
     * internally promotes cbuf_type 1->2 (surrogate-pair combining) when the
     * u/v flag is set; the buffer stride is always 2 bytes/unit regardless,
     * so we must always pass 1 here (passing 2 doubles cbuf_end's stride). */
    int cbuf_type = 1;

    uint16_t* units = NULL;
    int* byte_offsets = NULL;
    int unit_count = 0;
    int unit_start_offset = start_offset;

    units = cesu8_to_utf16((const uint8_t*)input, input_len, &byte_offsets, &unit_count);
    if (!units) return RE_ERROR;

    /* start_offset is a CESU-8 byte offset; find the matching unit index
     * (start_offset always lands exactly on a unit boundary in our storage). */
    for (int i = 0; i <= unit_count; i++) {
        if (byte_offsets[i] >= start_offset) { unit_start_offset = i; break; }
        unit_start_offset = i + 1;
    }

    int ret = lre_exec(capture, re->bc,
                       (const uint8_t*)units, unit_start_offset, unit_count,
                       cbuf_type, NULL);

    if (ret == RE_MATCH) {
        if (out_start) {
            int u = capture[0] ? (int)((const uint16_t*)capture[0] - units) : -1;
            *out_start = unit_offset_to_byte_offset(byte_offsets, unit_count, u);
        }
        if (out_end) {
            int u = capture[1] ? (int)((const uint16_t*)capture[1] - units) : -1;
            *out_end = unit_offset_to_byte_offset(byte_offsets, unit_count, u);
        }
        if (out_num_captures) *out_num_captures = total_captures - 1;

        for (int i = 1; i < total_captures && (i - 1) < max_captures; i++) {
            int idx = i * 2;
            int su = capture[idx] ? (int)((const uint16_t*)capture[idx] - units) : -1;
            int eu = capture[idx + 1] ? (int)((const uint16_t*)capture[idx + 1] - units) : -1;
            caps_start[i - 1] = unit_offset_to_byte_offset(byte_offsets, unit_count, su);
            caps_end[i - 1] = unit_offset_to_byte_offset(byte_offsets, unit_count, eu);
        }
        free(units);
        free(byte_offsets);
        return RE_MATCH;
    }

    free(units);
    free(byte_offsets);

    if (ret == 0) return RE_NO_MATCH;
    return RE_ERROR;
}

void re_free(ReCompiled* re)
{
    if (re) {
        if (re->bc) lre_realloc(NULL, re->bc, 0);
        free(re);
    }
}

const char* re_get_groupnames(ReCompiled* re)
{
    if (!re || !re->bc) return NULL;
    return lre_get_groupnames(re->bc);
}

int re_get_capture_count(ReCompiled* re)
{
    if (!re || !re->bc) return 0;
    return re->capture_count;
}

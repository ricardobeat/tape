/*
 * Unicode normalization wrapper — implementation using QuickJS libunicode
 */
#include <stdlib.h>
#include <string.h>
#include "libunicode.h"
#include "unicode_wrapper.h"
#include "cutils.h"

/* Default realloc callback for libunicode's DynBuf */
static void *default_realloc(void *opaque, void *ptr, size_t size)
{
    (void)opaque;
    if (size == 0) {
        free(ptr);
        return NULL;
    }
    return realloc(ptr, size);
}

uint32_t* unicode_normalize_simple(const uint32_t* src, int src_len,
                                    int n_type, int* out_len)
{
    uint32_t *result = NULL;
    int len;

    if (out_len) *out_len = -1;

    len = unicode_normalize(&result, src, src_len,
                            (UnicodeNormalizationEnum)n_type,
                            NULL, default_realloc);

    if (len < 0) {
        /* On failure, unicode_normalize sets *pdst to NULL */
        if (out_len) *out_len = -1;
        return NULL;
    }

    if (out_len) *out_len = len;
    return result;
}

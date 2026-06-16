/*
 * Unicode normalization wrapper — simplified C API for libunicode
 *
 * Provides a simple non-intrusive function for C3 interop.
 */
#ifndef UNICODE_WRAPPER_H
#define UNICODE_WRAPPER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Normalize a string of uint32_t codepoints.
 *
 * Parameters:
 *   src     - input codepoint array (not modified)
 *   src_len - number of codepoints in src
 *   n_type  - normalization form: 0=NFC, 1=NFD, 2=NFKC, 3=NFKD
 *   out_len - on success, set to the number of codepoints in the result
 *
 * Returns a newly malloc'd uint32_t array (caller must free with free()).
 * Returns NULL on failure (e.g. out of memory).
 */
uint32_t* unicode_normalize_simple(const uint32_t* src, int src_len,
                                   int n_type, int* out_len);

#ifdef __cplusplus
}
#endif

#endif /* UNICODE_WRAPPER_H */

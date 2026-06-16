/*
 * Unicode normalization C bindings — C3 interop with QuickJS libunicode via unicode_wrapper
 */
module duktape::unicode_bindings;

/*
 * Normalize a string of uint32_t codepoints.
 * Returns newly malloc'd uint32_t array (caller must free with libc::free).
 * Returns NULL on failure. Sets *out_len to the number of codepoints.
 */
extern fn uint* unicode_normalize_simple(uint* src, int src_len,
                                          int n_type, int* out_len);

/* Normalization form constants (matching libunicode.h) */
const int UNICODE_NFC  = 0;
const int UNICODE_NFD  = 1;
const int UNICODE_NFKC = 2;
const int UNICODE_NFKD = 3;

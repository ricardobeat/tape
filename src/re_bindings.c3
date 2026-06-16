/*
 * RegExp C bindings — C3 interop with QuickJS libregexp via re_wrapper
 */
module duktape::re_bindings;

extern fn void* re_compile(char* pattern, usz pattern_len,
                           int flags, char* error_msg, int error_msg_size);

extern fn int re_exec(void* re, char* input, int input_len,
                      int start_offset,
                      int* out_start, int* out_end, int* out_num_captures,
                      int* caps_start, int* caps_end, int max_captures);

extern fn void re_free(void* re);

extern fn char* re_get_groupnames(void* re);

extern fn int re_get_capture_count(void* re);

/* Constants matching re_wrapper.h */
const int RE_FLAG_IGNORECASE = 2;
const int RE_FLAG_MULTILINE  = 4;
const int RE_FLAG_DOTALL     = 8;

const int RE_MATCH    = 1;
const int RE_NO_MATCH = 0;
const int RE_ERROR    = -1;

const int RE_MAX_CAPTURES = 32;

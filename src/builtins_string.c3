/// String-related builtin functions for the Duktape C3 port.
/// String.prototype method implementations are defined in the parent builtins module
/// and re-exported here for organizational purposes.
module duktape::builtins_string;

import duktape::types;
import duktape::hstring;
import duktape::builtins;

// Export all String-related functions from builtins module
extern fn void builtin_string(BuiltinContext* ctx);
extern fn void builtin_string_proto_toString(BuiltinContext* ctx);
extern fn void builtin_string_proto_valueOf(BuiltinContext* ctx);
extern fn void builtin_string_fromcharcode(BuiltinContext* ctx);
extern fn void builtin_string_fromcodepoint(BuiltinContext* ctx);
extern fn HString* string_proto_get_this(BuiltinContext* ctx);
extern fn double builtin_to_integer(TVal* val);
extern fn uint clamp_index(double d, uint len);
extern fn void builtin_string_proto_charAt(BuiltinContext* ctx);
extern fn void builtin_string_proto_charCodeAt(BuiltinContext* ctx);
extern fn void builtin_string_proto_indexOf(BuiltinContext* ctx);
extern fn void builtin_string_proto_slice(BuiltinContext* ctx);
extern fn void builtin_string_proto_substring(BuiltinContext* ctx);
extern fn void builtin_string_proto_substr(BuiltinContext* ctx);
extern fn void builtin_string_proto_toLowerCase(BuiltinContext* ctx);
extern fn void builtin_string_proto_toUpperCase(BuiltinContext* ctx);
extern fn void builtin_string_proto_trim(BuiltinContext* ctx);
extern fn void builtin_string_proto_split(BuiltinContext* ctx);
extern fn void builtin_string_proto_concat(BuiltinContext* ctx);
extern fn void builtin_string_proto_replace(BuiltinContext* ctx);
extern fn void builtin_string_proto_includes(BuiltinContext* ctx);
extern fn void builtin_string_proto_startsWith(BuiltinContext* ctx);
extern fn void builtin_string_proto_endsWith(BuiltinContext* ctx);
extern fn void builtin_string_proto_repeat(BuiltinContext* ctx);
extern fn void builtin_string_proto_trimStart(BuiltinContext* ctx);
extern fn void builtin_string_proto_trimEnd(BuiltinContext* ctx);
extern fn void builtin_string_proto_codePointAt(BuiltinContext* ctx);
extern fn void builtin_string_proto_at(BuiltinContext* ctx);
extern fn void builtin_string_proto_padStart(BuiltinContext* ctx);
extern fn void builtin_string_proto_padEnd(BuiltinContext* ctx);
extern fn void builtin_string_proto_lastIndexOf(BuiltinContext* ctx);
extern fn void builtin_string_proto_match(BuiltinContext* ctx);
extern fn void builtin_string_proto_search(BuiltinContext* ctx);
extern fn bool is_regexp_object(TVal* val);


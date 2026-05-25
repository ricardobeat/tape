/// Duktape bytecode virtual machine — register-based interpreter.
///
/// Architecture matches Duktape's duk_js_executor.c and duk_js_call.c:
/// - Value stack with activation records indexed by byte offsets
/// - CALL opcode: A=nargs, BC=base (callee at base, this at base+1, args at base+2..base+1+nargs)
/// - Bytecode executed via inner loop that restarts on ECMAScript-to-ECMAScript calls
module duktape::vm;

import duktape::types;
import duktape::bytecode;
import duktape::heap;
import duktape::hstring;
import duktape::hobject;
import duktape::env;
import duktape::builtins;
import duktape::re_bindings;
import std::io;
import std::math;
import libc;

// ============================================================================
// Fault codes
// ============================================================================

faultdef VM_ERROR;
faultdef STACK_OVERFLOW;

// ============================================================================
// Constants
// ============================================================================

const uint MAX_CALLS        = 128;
const uint INITIAL_VALSTACK = 1024;

// ============================================================================
// Activation record (matches duk_activation in duktape)
// ============================================================================

struct Activation {
    /// Function being executed (for compfunc/natfunc; borrowed reference)
    void* func;
    /// Previous (parent) activation, or null for outermost
    Activation* parent;
    /// Current variable environment
    EnvRecord* var_env;
    /// Current lexical environment
    EnvRecord* lex_env;
    /// Current catcher chain (null if none)
    void* cat;

    /// Next instruction to execute (points into bytecode; stable pointer)
    /// null for native calls
    Instruction* curr_pc;
    /// Byte offset into valstack for this activation's bottom (absolute).
    /// Used to reset valstack_bottom on return.
    uint bottom_byteoff;
    /// Byte offset into valstack where return value goes (absolute).
    /// Only set for non-topmost activations.
    uint retval_byteoff;
    /// valstack_end byte offset to restore when returning to this activation
    uint reserve_byteoff;
    /// Flags: strict, tailcalled, construct, etc.
    uint flags;
    /// The 'this' binding for this activation (full TVal)
    TVal this_binding;
    /// For construct calls: the originally created object (before constructor ran)
    HObject* new_target;
    /// Value stack pointer to function (borrowed; for lightfuncs)
    TVal tv_func;
}

const uint ACT_FLAG_STRICT         = 1u << 0;
const uint ACT_FLAG_TAILCALLED     = 1u << 1;
const uint ACT_FLAG_CONSTRUCT      = 1u << 2;
const uint ACT_FLAG_PREVENT_YIELD  = 1u << 3;
const uint ACT_FLAG_DIRECT_EVAL    = 1u << 4;

// ============================================================================
// Catcher — exception handler chain entry
// ============================================================================

/// Flags for catcher struct.
const uint CATCHER_FLAG_CATCH_ENABLED    = 1u << 0;
const uint CATCHER_FLAG_FINALLY_ENABLED  = 1u << 1;

/// A catcher entry pushed by TRY for exception handling.
/// Singly-linked list rooted in Activation.cat.
struct Catcher {
    /// Previous (parent) catcher in the chain, or null if none.
    Catcher* parent;
    /// Flags: CATCHER_FLAG_*
    uint flags;
    /// The thrown exception value (set by THROW, read by CATCH).
    TVal thrown_val;
    /// Absolute PC of the catch handler (CATCH instruction).
    Instruction* catch_pc;
    /// Absolute PC of the finally handler (FINALLY instruction), or null if none.
    Instruction* finally_pc;
}

// ============================================================================
// For-in enumeration state
// ============================================================================

/// Runtime state for a for-in loop iteration.  Created by INITFOR and
/// consumed/freed by NEXTFOR.
///
/// `keys` holds a flat array of interned HString* pointers collected from
/// the object and its prototype chain (omitting duplicates).  The array
/// and the struct itself are plain-malloc'd and freed when the loop
/// finishes (NEXTFOR returning false) or on catcher unwind.
struct ForInState {
    HString** keys;    /// Array of interned property-name HString* pointers
    uint count;        /// Number of keys in the array
    uint index;        /// Current position (next key to return)
}

// ============================================================================
// VM state (matches duk_hthread)
// ============================================================================

struct Vm {
    Heap* heap;

    // Value stack
    TVal* valstack;        /// Base pointer of value stack
    uint valstack_size;    /// Allocated size in slots
    TVal* valstack_top;   /// Current top (one-past-last used slot)
    TVal* valstack_end;   /// End of allocated space
    uint valstack_bottom; /// Byte offset to current activation's bottom

    // Activation/call stack
    Activation[MAX_CALLS] activations;
    uint activation_count;

    // Current execution state (stable pointers reloaded on restart)
    CompiledFunction* current_func;
    Instruction* curr_pc; /// Pointer to current PC variable (for sync)

    // Global environment
    EnvRecord* global_env;

    // Return value (for outer executor return)
    TVal return_val;

    // Error state
    bool has_error;
}

// ============================================================================
// Catcher chain — helper functions
// ============================================================================

/// Walk the catcher chain and throw a value.
/// Searches the full activation chain, unwinding intermediate activations
/// when a catcher is found in a parent activation.
///
/// Returns true if a catcher was found (execution continues after restart).
/// Returns false if no catcher was found anywhere in the call stack
/// (caller should return VM_ERROR~).
fn bool vm_throw_value(Vm* vm, TVal thrown_val, Activation* act,
                       Instruction** curr_pc, bool* needs_restart) {
    // Walk through current and parent activations
    Activation* search_act = act;
    while (search_act != null) {
        Catcher* cat = (Catcher*)search_act.cat;
        while (cat != null) {
            if (cat.flags & CATCHER_FLAG_CATCH_ENABLED) {
                cat.thrown_val = thrown_val;
                cat.flags &= ~CATCHER_FLAG_CATCH_ENABLED;
                *curr_pc = cat.catch_pc;
                search_act.curr_pc = *curr_pc;
                *needs_restart = true;

                // If we found the catcher in a parent activation, unwind
                // intermediate activations so the VM resumes at the right level.
                if (search_act != act) {
                    // Pop all activations down to the one with the catcher
                    while (vm.activation_count > 0
                           && &vm.activations[vm.activation_count - 1] != search_act) {
                        vm.activation_count--;
                    }
                    // Restore the valstack_bottom for the target activation
                    vm.valstack_bottom = search_act.bottom_byteoff;
                    // Restore valstack_top to match the target function's nregs
                    if (search_act.func != null) {
                        CompiledFunction* target_func = (CompiledFunction*)search_act.func;
                        uint target_nregs = target_func.num_regs;
                        uint target_bottom_idx = search_act.bottom_byteoff / TVal::size;
                        vm.valstack_top = (TVal*)((usz)vm.valstack
                            + (usz)(target_bottom_idx + target_nregs) * TVal::size);
                    }
                }
                return true;
            }
            if (cat.flags & CATCHER_FLAG_FINALLY_ENABLED) {
                cat.thrown_val = thrown_val;
                *curr_pc = cat.finally_pc;
                search_act.curr_pc = *curr_pc;
                *needs_restart = true;

                if (search_act != act) {
                    while (vm.activation_count > 0
                           && &vm.activations[vm.activation_count - 1] != search_act) {
                        vm.activation_count--;
                    }
                    vm.valstack_bottom = search_act.bottom_byteoff;
                    if (search_act.func != null) {
                        CompiledFunction* target_func = (CompiledFunction*)search_act.func;
                        uint target_nregs = target_func.num_regs;
                        uint target_bottom_idx = search_act.bottom_byteoff / TVal::size;
                        vm.valstack_top = (TVal*)((usz)vm.valstack
                            + (usz)(target_bottom_idx + target_nregs) * TVal::size);
                    }
                }
                return true;
            }
            cat = cat.parent;
        }
        search_act = search_act.parent;
    }
    return false;
}

/// Helper to get byte offset from valstack base to a pointer
fn uint byte_offset(TVal* base, TVal* ptr) @inline {
    return (uint)((usz)ptr - (usz)base);
}

/// Helper to get TVal* from valstack base and byte offset.
fn TVal* ptr_from_byteoff(TVal* base, uint byteoff) @inline {
    assert(byteoff % (uint)TVal::size == 0);
    return (TVal*)((usz)base + (usz)byteoff);
}

// ============================================================================
// Helpers
// ============================================================================

/// Extract a numeric double from a TVal (promoting FASTINT if needed).
fn double num_val(TVal* val) @inline {
    if (val.tag == FASTINT) {
        return (double)val.fastint;
    }
    return val.number;
}

/// ECMAScript truthiness.
fn bool is_truthy(TVal* val) @inline {
    switch (val.tag) {
        case UNDEFINED: return false;
        case NULL_VAL:  return false;
        case BOOLEAN:   return val.boolean;
        case NUMBER:    return val.number != 0.0 && !math::is_nan(val.number);
        case FASTINT:   return val.fastint != 0;
        case STRING:    return ((HString*)val.pointer).blen > 0;
        case OBJECT:    return true;
        case LIGHTFUNC: return true;
        default:        return true;
    }
}

/// Ensure the value stack has room for `needed` more slots.
fn bool ensure_valstack(Vm* vm, uint needed) {
    uint used = (uint)((usz)vm.valstack_top - (usz)vm.valstack) / TVal::size;
    if (used + needed <= vm.valstack_size) {
        return true;
    }
    uint new_size = vm.valstack_size;
    while (new_size < used + needed) {
        new_size *= 2;
    }
    uint old_used = (uint)((usz)vm.valstack_top - (usz)vm.valstack) / TVal::size;
    void* new_raw = libc::realloc(vm.valstack, (usz)new_size * TVal::size);
    if (new_raw == null) {
        return false;
    }
    vm.valstack = (TVal*)new_raw;
    vm.valstack_size = new_size;
    vm.valstack_top = (TVal*)((usz)vm.valstack + (usz)(old_used * TVal::size));
    vm.valstack_end = (TVal*)((usz)vm.valstack + (usz)(new_size * TVal::size));
    return true;
}

/// Get the current activation. Returns null if no activations.
fn Activation* curr_act(Vm* vm) @inline {
    if (vm.activation_count == 0) return null;
    assert(vm.activation_count <= MAX_CALLS);
    return &vm.activations[vm.activation_count - 1];
}

/// Get valstack_bottom as TVal*
fn TVal* valstack_bottom_ptr(Vm* vm) @inline {
    return ptr_from_byteoff(vm.valstack, curr_act(vm).bottom_byteoff);
}

/// Convert a TVal to an interned string key for property access.
fn void* get_prop_key(Vm* vm, TVal* val) {
    if (val.tag == STRING) {
        return val.pointer;
    }
    HString*? s = vm_to_string(vm, val);
    if (try h = s) {
        return h;
    }
    return null;
}

/// Look up a property on an object, walking the prototype chain.
fn TVal get_prop_with_proto(HObject* obj, void* key) {
    TVal? result = obj.get_prop_proto(key);
    if (try v = result) {
        return v;
    }
    TVal undef;
    undef.tag = UNDEFINED;
    undef.pointer = null;
    return undef;
}

// ============================================================================
// String helpers
// ============================================================================

/// Intern a raw byte slice into the VM's string table.
fn HString* intern_string(Vm* vm, char[] data) {
    uint hash = vm.heap.hash_string(data);
    HString* existing = vm.heap.str_table_lookup(data, hash);
    if (existing != null) {
        return existing;
    }
    HString*? new_s = hstring::hstring_alloc(vm.heap, data, hash);
    if (try s = new_s) {
        vm.heap.str_table_insert(s);
        return s;
    }
    return null;
}

/// Return the interned typeof string for a TVal per ES spec.
fn HString* typeof_string(Vm* vm, TVal* val) {
    switch (val.tag) {
        case UNDEFINED: return intern_string(vm, "undefined");
        case NULL_VAL:  return intern_string(vm, "object");
        case BOOLEAN:   return intern_string(vm, "boolean");
        case NUMBER:    return intern_string(vm, "number");
        case FASTINT:   return intern_string(vm, "number");
        case STRING:    return intern_string(vm, "string");
        case OBJECT:
            HObject* hobj = (HObject*)val.pointer;
            if (hobj != null && hobj.is_callable()) {
                return intern_string(vm, "function");
            }
            return intern_string(vm, "object");
        case LIGHTFUNC: return intern_string(vm, "function");
        default:        return intern_string(vm, "undefined");
    }
}

/// Convert a double to an interned HString* using snprintf.
fn HString*? vm_number_to_string(Vm* vm, double val) {
    char[64] buf;
    int len = libc::snprintf(&buf, 64, "%.17g", val);
    if (len < 0 || len >= 64) {
        return null;
    }
    char[] s = buf[:len];
    uint hash = vm.heap.hash_string(s);
    HString* existing = vm.heap.str_table_lookup(s, hash);
    if (existing != null) {
        return existing;
    }
    HString*? new_s = hstring::hstring_alloc(vm.heap, s, hash);
    if (try hstr = new_s) {
        vm.heap.str_table_insert(hstr);
        return hstr;
    }
    return null;
}

/// Convert a TVal to an interned HString*.
fn HString*? vm_to_string(Vm* vm, TVal* val) {
    switch (val.tag) {
        case STRING:
            return (HString*)val.pointer;
        case NUMBER:
            return vm_number_to_string(vm, val.number);
        case FASTINT:
            return vm_number_to_string(vm, (double)val.fastint);
        case BOOLEAN:
            if (val.boolean) {
                return intern_string(vm, "true");
            }
            return intern_string(vm, "false");
        case UNDEFINED:
            return intern_string(vm, "undefined");
        case NULL_VAL:
            return intern_string(vm, "null");
        case OBJECT:
            return intern_string(vm, "[object Object]");
        case LIGHTFUNC:
            return intern_string(vm, "[function]");
        default:
            return intern_string(vm, "undefined");
    }
}

/// Returns true for ECMAScript white-space and line-terminator characters
/// (ASCII subset: Tab, VT, FF, Space, NBSP, LF, CR).
fn bool is_ecma_whitespace(char c) @inline {
    return c == 0x09 || c == 0x0B || c == 0x0C
        || c == 0x20 || c == 0xA0
        || c == 0x0A || c == 0x0D;
}

/// ECMAScript ToNumber for strings (§7.1.3.1).
///
/// Converts an HString* to a double, trimming ECMAScript whitespace and
/// parsing numeric literals (decimal, hex, Infinity).  Returns NaN when
/// the string does not represent a valid numeric literal.
fn double hstring_to_number(HString* hstr) {
    char* cstr = hstr.get_cstr();
    uint blen = hstr.blen;

    // --- skip leading ECMAScript whitespace ---
    uint start = 0;
    while (start < blen && is_ecma_whitespace(cstr[start])) {
        start++;
    }

    // Empty or all-whitespace -> +0
    if (start == blen) {
        return 0.0;
    }

    char* p = cstr + start;

    // --- Infinity / -Infinity / +Infinity ---
    if (libc::strcmp((ZString)p, "Infinity") == 0)   return double::inf;
    if (libc::strcmp((ZString)p, "+Infinity") == 0)  return double::inf;
    if (libc::strcmp((ZString)p, "-Infinity") == 0)  return -double::inf;

    // --- Hex integer literal (0x...) ---
    if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) {
        uint j = 2;
        ulong val = 0;
        while (p[j] != 0) {
            char c = p[j];
            uint digit;
            if      (c >= '0' && c <= '9') { digit = (uint)(c - '0'); }
            else if (c >= 'a' && c <= 'f') { digit = (uint)(c - 'a' + 10); }
            else if (c >= 'A' && c <= 'F') { digit = (uint)(c - 'A' + 10); }
            else { break; }   // non-hex terminates the literal

            val = (val << 4) | digit;
            j++;
        }
        // Trailing must be whitespace
        while (p[j] != 0) {
            if (!is_ecma_whitespace(p[j])) return double::nan;
            j++;
        }
        return (double)val;
    }

    // --- Decimal via libc::strtod ---
    char* endptr;
    double result = libc::strtod(p, &endptr);

    // Nothing was consumed -> NaN
    if (endptr == p) {
        return double::nan;
    }

    // Trailing characters must be whitespace only
    while (*endptr != 0) {
        if (!is_ecma_whitespace(*endptr)) {
            return double::nan;
        }
        endptr++;
    }

    return result;
}

/// Extract [[PrimitiveValue]] from Boolean/Number/String wrapper objects.
/// For non-wrapper objects, returns the value unchanged.
fn TVal to_primitive_value(TVal* val) {
    if (val.tag == OBJECT && val.pointer != null) {
        HObject* obj = (HObject*)val.pointer;
        hobject::ObjClass cls = obj.get_class();
        if (cls == hobject::ObjClass.BOOLEAN &&
            obj.primitive_value.tag == BOOLEAN) {
            TVal result;
            result.tag = BOOLEAN;
            result.boolean = obj.primitive_value.boolean;
            return result;
        }
        if (cls == hobject::ObjClass.NUMBER &&
            (obj.primitive_value.tag == NUMBER || obj.primitive_value.tag == FASTINT)) {
            TVal result;
            result.tag = obj.primitive_value.tag;
            result.number = obj.primitive_value.number;
            return result;
        }
        if (cls == hobject::ObjClass.STRING &&
            obj.primitive_value.tag == STRING) {
            TVal result;
            result.tag = STRING;
            result.pointer = obj.primitive_value.pointer;
            return result;
        }
    }
    return *val;
}

const uint FORIN_INITIAL_CAP = 64;

/// Grow an HString** array if needed.
fn bool forin_ensure_cap(HString*** arr, uint* cap, uint need) {
    if (need >= *cap) {
        uint new_cap = *cap * 2;
        HString** new_arr = (HString**)libc::realloc(*arr, new_cap * HString*::size);
        if (new_arr == null) return false;
        *arr = new_arr;
        *cap = new_cap;
    }
    return true;
}

/// Add a key if not already in the seen set (pointer compare for interned strings).
fn bool forin_add_key(HString*** keys, uint* count,
                      HString*** seen, uint* seen_cnt, uint* cap,
                      HString* key) {
    for (uint j = 0; j < *seen_cnt; j++) {
        if ((*seen)[j] == key) return true;
    }
    if (!forin_ensure_cap(keys, cap, *count + 1)) return false;
    if (!forin_ensure_cap(seen, cap, *seen_cnt + 1)) return false;
    (*keys)[*count] = key;
    (*count)++;
    (*seen)[*seen_cnt] = key;
    (*seen_cnt)++;
    return true;
}

/// Collect all enumerable property keys from an object and its prototype
/// chain, de-duplicated (own keys shadow prototype keys).
///
/// Returns a malloc'd ForInState, or null if allocation fails.
/// The caller (NEXTFOR) is responsible for freeing via `libc::free`.
fn ForInState* collect_forin_keys(Vm* vm, HObject* obj) {
    const uint MAX_PROTO_DEPTH = 256;

    uint cap = FORIN_INITIAL_CAP;
    HString** keys = (HString**)libc::malloc(cap * HString*::size);
    if (keys == null) return null;
    uint count = 0;

    HString** seen = (HString**)libc::malloc(cap * HString*::size);
    if (seen == null) { libc::free(keys); return null; }
    uint seen_cnt = 0;

    HObject* cur = obj;
    uint depth = 0;
    while (cur != null && depth < MAX_PROTO_DEPTH) {
        // Own named properties
        for (uint i = 0; i < cur.prop_count; i++) {
            if (cur.props[i].flags.enumerable && cur.props[i].key != null) {
                HString* k = (HString*)cur.props[i].key;
                if (!forin_add_key(&keys, &count, &seen, &seen_cnt, &cap, k)) {
                    libc::free(keys);
                    libc::free(seen);
                    return null;
                }
            }
        }

        // Own dense array part indices
        for (uint i = 0; i < cur.array_size; i++) {
            if (!cur.array_part[i].is_undefined()) {
                char[16] buf;
                int len = libc::snprintf(&buf, 16, "%u", i);
                if (len > 0 && len < 16) {
                    char[] s = buf[:(uint)len];
                    HString* k = intern_string(vm, s);
                    if (k == null) continue;
                    if (!forin_add_key(&keys, &count, &seen, &seen_cnt, &cap, k)) {
                        libc::free(keys);
                        libc::free(seen);
                        return null;
                    }
                }
            }
        }

        cur = cur.prototype;
        depth++;
    }

    libc::free(seen);

    ForInState* state = (ForInState*)libc::malloc(ForInState::size);
    if (state == null) { libc::free(keys); return null; }
    state.keys = keys;
    state.count = count;
    state.index = 0;
    return state;
}

/// ECMAScript Abstract Equality Comparison (§7.2.14).
fn bool abstract_eq(TVal* a, TVal* b) {
    // Same type -> strict equality
    if (a.tag == b.tag) {
        return strict_eq(a, b);
    }

    // null/undefined pair
    if ((a.tag == NULL_VAL && b.tag == UNDEFINED) ||
        (a.tag == UNDEFINED && b.tag == NULL_VAL)) {
        return true;
    }

    // NUMBER/FASTINT: treat as same "numeric" type
    if (a.tag == NUMBER && b.tag == FASTINT) {
        return a.number == (double)b.fastint;
    }
    if (a.tag == FASTINT && b.tag == NUMBER) {
        return (double)a.fastint == b.number;
    }

    // Boolean -> ToNumber
    if (a.tag == BOOLEAN) {
        TVal a_num;
        a_num.tag = NUMBER;
        a_num.number = a.boolean ? 1.0 : 0.0;
        return abstract_eq(&a_num, b);
    }
    if (b.tag == BOOLEAN) {
        TVal b_num;
        b_num.tag = NUMBER;
        b_num.number = b.boolean ? 1.0 : 0.0;
        return abstract_eq(a, &b_num);
    }

    // String + Number -> ToNumber(string)
    if (a.tag == STRING && (b.tag == NUMBER || b.tag == FASTINT)) {
        double num = hstring_to_number((HString*)a.pointer);
        if (b.tag == FASTINT) return num == (double)b.fastint;
        return num == b.number;
    }
    if (b.tag == STRING && (a.tag == NUMBER || a.tag == FASTINT)) {
        double num = hstring_to_number((HString*)b.pointer);
        if (a.tag == FASTINT) return (double)a.fastint == num;
        return a.number == num;
    }

    // Object + Boolean/Number/String -> ToPrimitive
    if (a.tag == OBJECT && (b.tag == BOOLEAN || b.tag == NUMBER || b.tag == FASTINT || b.tag == STRING)) {
        TVal prim = to_primitive_value(a);
        if (prim.tag != OBJECT) {
            return abstract_eq(&prim, b);
        }
        return false;
    }
    if (b.tag == OBJECT && (a.tag == BOOLEAN || a.tag == NUMBER || a.tag == FASTINT || a.tag == STRING)) {
        TVal prim = to_primitive_value(b);
        if (prim.tag != OBJECT) {
            return abstract_eq(a, &prim);
        }
        return false;
    }

    return false;
}

/// Strict equality check (same as SEQ).
fn bool strict_eq(TVal* a, TVal* b) @inline {
    if (a.tag == b.tag) {
        switch (a.tag) {
            case UNDEFINED: return true;
            case NULL_VAL:  return true;
            case BOOLEAN:   return a.boolean == b.boolean;
            case NUMBER:
                if (math::is_nan(a.number) && math::is_nan(b.number)) return false;
                return a.number == b.number;
            case FASTINT:   return a.fastint == b.fastint;
            case STRING:    return a.pointer == b.pointer;
            case OBJECT:    return a.pointer == b.pointer;
            default:        return false;
        }
    }
    // NUMBER and FASTINT are the same ES type
    if ((a.tag == NUMBER && b.tag == FASTINT) ||
        (a.tag == FASTINT && b.tag == NUMBER)) {
        return num_val(a) == num_val(b);
    }
    return false;
}

// ============================================================================
// Call handling (matches duk_js_call.c)
// ============================================================================

/// Set up a new activation for a function call.
/// Value stack must have: [func this arg0 arg1 ... argN]
/// idx_func = index of func on value stack
fn bool setup_call(Vm* vm, uint idx_func, uint nargs, bool is_construct) {
    // Save current activation state
    Activation* caller_act = curr_act(vm);
    uint caller_bottom = caller_act.bottom_byteoff;

    // retval_byteoff: where to write return value in caller's frame
    caller_act.retval_byteoff = byte_offset(vm.valstack, ptr_from_byteoff(vm.valstack, caller_bottom) + idx_func);

    // Get target function
    TVal* func_slot = ptr_from_byteoff(vm.valstack, caller_bottom) + idx_func;
    TVal func_val = *func_slot;

    CompiledFunction* target_func = null;
    EnvRecord* var_env = null;
    EnvRecord* lex_env = null;

    if (func_val.tag == LIGHTFUNC) {
        // Lightfunc: always strict, just call directly
        // Nothing special needed for var_env/lex_env
    } else if (func_val.tag == OBJECT) {
        HObject* hobj = (HObject*)func_val.pointer;
        if (hobj != null && hobj.is_callable() && hobj.comp_func != null) {
            target_func = hobj.comp_func;
            var_env = hobj.var_env;
            lex_env = hobj.lex_env;
        } else {
            return false;
        }
    } else {
        return false;
    }

    // Allocate new activation
    if (vm.activation_count >= MAX_CALLS) {
        return false;
    }
    Activation* new_act = &vm.activations[vm.activation_count];
    vm.activation_count++;

    // Compute new valstack bottom (after func + this + args)
    uint new_bottom_byteoff = caller_bottom + ((uint)idx_func + 2) * (uint)TVal::size;

    // Set up activation
    new_act.parent = caller_act;
    new_act.func = target_func;
    new_act.var_env = var_env;
    new_act.lex_env = lex_env;
    new_act.cat = null;
    new_act.curr_pc = null;
    new_act.bottom_byteoff = new_bottom_byteoff;
    new_act.retval_byteoff = 0;
    new_act.reserve_byteoff = byte_offset(vm.valstack, vm.valstack_end);
    new_act.flags = ACT_FLAG_STRICT;
    if (is_construct) {
        new_act.flags |= ACT_FLAG_CONSTRUCT;
    }

    // Set up 'this' binding from slot idx_func+1
    TVal* this_slot = ptr_from_byteoff(vm.valstack, caller_bottom) + idx_func + 1;
    new_act.this_binding = *this_slot;

    // Move valstack_bottom to new activation
    vm.valstack_bottom = new_bottom_byteoff;

    return true;
}

/// Handle return from current activation.
/// val: the return value (or undefined for RETUNDEF)
fn TVal handle_return(Vm* vm, TVal val) {
    if (vm.activation_count == 0) {
        vm.return_val = val;
        return val;
    }

    Activation* callee_act = curr_act(vm);
    uint callee_result_byteoff = callee_act.retval_byteoff;

    // Pop activation
    vm.activation_count--;

    // If we just popped the last activation, there is no caller
    if (vm.activation_count == 0) {
        vm.return_val = val;
        return val;
    }

    Activation* caller_act = curr_act(vm);
    assert(caller_act != null);

    // Restore valstack_bottom to caller's
    vm.valstack_bottom = caller_act.bottom_byteoff;

    // Write result to caller's frame at the saved retval_byteoff
    if (callee_result_byteoff != 0 && callee_result_byteoff < vm.valstack_size * TVal::size) {
        // For construct calls: if return value is not an object, use this_binding
        TVal final_val = val;
        if ((callee_act.flags & ACT_FLAG_CONSTRUCT) != 0) {
            if (final_val.tag != OBJECT || final_val.pointer == null) {
                // Return the instance (this) instead of the constructor's return value
                if (callee_act.this_binding.tag == OBJECT && callee_act.this_binding.pointer != null) {
                    final_val = callee_act.this_binding;
                }
            }
        }
        TVal* result_slot = ptr_from_byteoff(vm.valstack, callee_result_byteoff);
        *result_slot = final_val;
    }

    // Restore valstack_top to match caller's nregs
    if (caller_act.func != null) {
        CompiledFunction* caller_func = (CompiledFunction*)caller_act.func;
        uint caller_nregs = caller_func.num_regs;
        uint caller_bottom_idx = caller_act.bottom_byteoff / TVal::size;
        vm.valstack_top = (TVal*)((usz)vm.valstack + (usz)(caller_bottom_idx + caller_nregs) * TVal::size);
    }

    return val;
}

// ============================================================================
// VM creation / destruction
// ============================================================================

/// Create and initialise a new VM.
fn Vm*? vm_create(Heap* heap) {
    void* raw = libc::malloc(Vm::size);
    if (raw == null) {
        return VM_ERROR~;
    }
    libc::memset(raw, 0, Vm::size);

    Vm* vm = (Vm*)raw;
    vm.heap = heap;

    // Allocate value stack
    void* vs_raw = libc::malloc((usz)INITIAL_VALSTACK * TVal::size);
    if (vs_raw == null) {
        libc::free(raw);
        return VM_ERROR~;
    }
    vm.valstack = (TVal*)vs_raw;
    vm.valstack_size = INITIAL_VALSTACK;
    vm.valstack_top = (TVal*)vs_raw;
    vm.valstack_end = (TVal*)((usz)vs_raw + (usz)INITIAL_VALSTACK * TVal::size);

    // Create global environment
    EnvRecord*? global = env::env_create(heap, null);
    if (catch err = global) {
        libc::free(vs_raw);
        libc::free(raw);
        return VM_ERROR~;
    }
    vm.global_env = global;

    // Register the global environment's bindings object as a GC root
    // so that mark-and-sweep never collects the global scope.
    heap.register_gc_root(global.bindings.as_header());

    // Register built-ins
    if (!builtins::register_builtins(global, heap)) {
        env::env_destroy(global);
        libc::free(vs_raw);
        libc::free(raw);
        return VM_ERROR~;
    }

    vm.activation_count = 0;
    vm.has_error = false;
    vm.current_func = null;
    vm.curr_pc = null;

    return vm;
}

/// Destroy a VM and release all owned resources.
fn void vm_destroy(Vm* vm) {
    if (vm == null) return;
    // env_destroy is NOT called here because all HObjects are tracked
    // in the heap's gc_objects array and freed by heap.destroy().
    // Calling env_destroy would double-free those tracked objects.
    if (vm.valstack != null) {
        libc::free(vm.valstack);
    }
    libc::free(vm);
}

// ============================================================================
// Main execution loop
// ============================================================================

/// Execute a compiled function from the start.
/// Matches duk_js_execute_bytecode() outer/inner pattern.
fn TVal? Vm.execute(Vm* vm, CompiledFunction* func) {
    // Set up initial activation (matches outer executor setup)
    Activation* entry_act = &vm.activations[0];
    vm.activation_count = 1;

    entry_act.func = func;
    entry_act.parent = null;
    entry_act.var_env = vm.global_env;
    entry_act.lex_env = vm.global_env;
    entry_act.cat = null;
    entry_act.curr_pc = func.code;  // Points into bytecode
    entry_act.bottom_byteoff = 0;
    entry_act.retval_byteoff = 0;
    entry_act.reserve_byteoff = byte_offset(vm.valstack, vm.valstack_end);
    entry_act.flags = ACT_FLAG_STRICT;

    TVal this_val;
    this_val.tag = UNDEFINED;
    this_val.pointer = null;
    entry_act.this_binding = this_val;

    // Allocate value stack slots for the function (nregs = total register count)
    uint nregs = func.num_regs;
    if (!ensure_valstack(vm, nregs)) {
        return VM_ERROR~;
    }

    // Initialize registers to undefined
    for (uint i = 0; i < nregs; i++) {
        vm.valstack[i].tag = UNDEFINED;
        vm.valstack[i].pointer = null;
    }
    vm.valstack_top = (TVal*)((usz)vm.valstack + (usz)nregs * TVal::size);
    vm.valstack_bottom = 0;

    vm.current_func = func;

    Instruction* code_base;
    uint code_count;
    TVal* constants;
    Activation* act;
    Instruction* curr_pc;
    bool needs_restart;

    // Outer restart loop: on ECMAScript-to-ECMAScript calls, reload state
    needs_restart = true;
    for (;;) {
        if (!needs_restart) {
            break;
        }
        needs_restart = false;

        act = &vm.activations[vm.activation_count - 1];
        vm.current_func = (CompiledFunction*)act.func;
        code_base = vm.current_func.code;
        code_count = vm.current_func.code_count;
        constants = vm.current_func.constants;
        nregs = vm.current_func.num_regs;

        curr_pc = act.curr_pc;

        TVal* regs_base = ptr_from_byteoff(vm.valstack, act.bottom_byteoff);

        // Inner dispatch loop
        for (; !needs_restart; ) {
            if (curr_pc >= code_base + code_count) {
                TVal undef_val;
                undef_val.tag = UNDEFINED;
                undef_val.pointer = null;
                handle_return(vm, undef_val);
                if (vm.activation_count == 0) {
                    return vm.return_val;
                }
                needs_restart = true;
                break;
            }

            Instruction insn = *curr_pc;
            curr_pc++;
            act.curr_pc = curr_pc;

            Opcode op = insn.op;

            TVal* ra = regs_base + ((uint)insn.a);
            TVal* rb = regs_base + ((uint)insn.b);
            TVal* rc = regs_base + ((uint)insn.c);

        switch (op) {

        // === LOAD / STORE ===

        case Opcode.LDREG:
            *ra = *rb;
            break;

        case Opcode.LDCONST: {
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                *ra = constants[bc];
            } else {
                ra.tag = UNDEFINED;
                ra.pointer = null;
            }
            break;
        }

        case Opcode.LDINT:
            ra.tag = FASTINT;
            ra.fastint = (long)insn.get_sbc();
            break;

        case Opcode.LDINTX: {
            long ix_high = ra.fastint;
            ra.fastint = (ix_high << 16) | (long)insn.get_bc();
            break;
        }

        case Opcode.LDUNDEF:
            ra.tag = UNDEFINED;
            ra.pointer = null;
            break;

        case Opcode.LDNULL:
            ra.tag = NULL_VAL;
            ra.pointer = null;
            break;

        case Opcode.LDTRUE:
            ra.tag = BOOLEAN;
            ra.boolean = true;
            break;

        case Opcode.LDFALSE:
            ra.tag = BOOLEAN;
            ra.boolean = false;
            break;

        case Opcode.LDTHIS:
            *ra = act.this_binding;
            break;

        // === ARITHMETIC ===

        case Opcode.ADD:
            // String concatenation check
            if (rb.tag == STRING || rc.tag == STRING) {
                HString*? left_str = vm_to_string(vm, rb);
                HString*? right_str = vm_to_string(vm, rc);
                if (try ls = left_str && try rs = right_str) {
                    HString*? concat = hstring::hstring_concat(vm.heap, ls, rs);
                    if (try cs = concat) {
                        // Intern the concatenated string for pointer dedup
                        char[] cd = cs.get_data();
                        HString* interned = intern_string(vm, cd);
                        // Free the raw concat result (not tracked by heap)
                        hstring::hstring_free(cs);
                        ra.tag = STRING;
                        ra.pointer = interned;
                    } else {
                        ra.tag = UNDEFINED;
                        ra.pointer = null;
                    }
                } else {
                    ra.tag = UNDEFINED;
                    ra.pointer = null;
                }
            } else if (rb.tag == FASTINT && rc.tag == FASTINT) {
                // Both operands are fast integers — keep as fastint if result fits
                long sum = rb.fastint + rc.fastint;
                if (sum >= types::FASTINT_MIN && sum <= types::FASTINT_MAX) {
                    ra.tag = FASTINT;
                    ra.fastint = sum;
                } else {
                    ra.tag = NUMBER;
                    ra.number = (double)sum;
                }
            } else {
                double add_b = num_val(rb);
                double add_c = num_val(rc);
                ra.tag = NUMBER;
                ra.number = add_b + add_c;
            }
            break;

        case Opcode.SUB:
            if (rb.tag == FASTINT && rc.tag == FASTINT) {
                long diff = rb.fastint - rc.fastint;
                if (diff >= types::FASTINT_MIN && diff <= types::FASTINT_MAX) {
                    ra.tag = FASTINT;
                    ra.fastint = diff;
                } else {
                    ra.tag = NUMBER;
                    ra.number = (double)diff;
                }
            } else {
                double sub_b = num_val(rb);
                double sub_c = num_val(rc);
                ra.tag = NUMBER;
                ra.number = sub_b - sub_c;
            }
            break;

        case Opcode.MUL:
            if (rb.tag == FASTINT && rc.tag == FASTINT) {
                // Use 64-bit multiply and check overflow
                long mul_result = rb.fastint * rc.fastint;
                if (mul_result >= types::FASTINT_MIN && mul_result <= types::FASTINT_MAX) {
                    ra.tag = FASTINT;
                    ra.fastint = mul_result;
                } else {
                    ra.tag = NUMBER;
                    ra.number = (double)mul_result;
                }
            } else {
                double mul_b = num_val(rb);
                double mul_c = num_val(rc);
                ra.tag = NUMBER;
                ra.number = mul_b * mul_c;
            }
            break;

        case Opcode.DIV: {
            double div_b = num_val(rb);
            double div_c = num_val(rc);
            ra.tag = NUMBER;
            ra.number = div_b / div_c;
            break;
        }

        case Opcode.MOD:
            if (rb.tag == FASTINT && rc.tag == FASTINT && rc.fastint != 0) {
                long mod_result = rb.fastint % rc.fastint;
                // Result always fits in FASTINT range
                ra.tag = FASTINT;
                ra.fastint = mod_result;
            } else {
                double mod_b = num_val(rb);
                double mod_c = num_val(rc);
                ra.tag = NUMBER;
                ra.number = (mod_b % mod_c);
            }
            break;

        case Opcode.EXP: {
            double exp_b = num_val(rb);
            double exp_c = num_val(rc);
            ra.tag = NUMBER;
            ra.number = math::pow(exp_b, exp_c);
            break;
        }

        // === UNARY ===

        case Opcode.UNP:
            if (rb.tag == FASTINT) {
                // Unary + on FASTINT stays FASTINT
                ra.tag = FASTINT;
                ra.fastint = rb.fastint;
            } else {
                double unp_b = num_val(rb);
                ra.tag = NUMBER;
                ra.number = unp_b;
            }
            break;

        case Opcode.UNM:
            if (rb.tag == FASTINT) {
                // Unary - on FASTINT stays FASTINT (negation always fits)
                ra.tag = FASTINT;
                ra.fastint = -rb.fastint;
            } else {
                double unm_b = num_val(rb);
                ra.tag = NUMBER;
                ra.number = -unm_b;
            }
            break;

        case Opcode.BNOT:
            // Bitwise NOT always produces Int32, always fits in FASTINT
        {
            int bnot_b = (rb.tag == FASTINT) ? (int)rb.fastint : (int)rb.number;
            ra.tag = FASTINT;
            ra.fastint = (long)(~bnot_b);
            break;
        }

        case Opcode.LNOT:
            ra.tag = BOOLEAN;
            ra.boolean = !is_truthy(rb);
            break;

        case Opcode.TYPEOF: {
            HString* ts = typeof_string(vm, rb);
            ra.tag = STRING;
            ra.pointer = ts;
            break;
        }

        case Opcode.VOID:
            ra.tag = UNDEFINED;
            ra.pointer = null;
            break;

        // === BITWISE ===

        case Opcode.BAND:
            // Bitwise ops always produce Int32, always fit in FASTINT
        {
            int band_b = (rb.tag == FASTINT) ? (int)rb.fastint : (int)rb.number;
            int band_c = (rc.tag == FASTINT) ? (int)rc.fastint : (int)rc.number;
            ra.tag = FASTINT;
            ra.fastint = (long)(band_b & band_c);
            break;
        }

        case Opcode.BOR:
        {
            int bor_b = (rb.tag == FASTINT) ? (int)rb.fastint : (int)rb.number;
            int bor_c = (rc.tag == FASTINT) ? (int)rc.fastint : (int)rc.number;
            ra.tag = FASTINT;
            ra.fastint = (long)(bor_b | bor_c);
            break;
        }

        case Opcode.BXOR:
        {
            int bxor_b = (rb.tag == FASTINT) ? (int)rb.fastint : (int)rb.number;
            int bxor_c = (rc.tag == FASTINT) ? (int)rc.fastint : (int)rc.number;
            ra.tag = FASTINT;
            ra.fastint = (long)(bxor_b ^ bxor_c);
            break;
        }

        case Opcode.SHL:
        {
            int shl_b = (rb.tag == FASTINT) ? (int)rb.fastint : (int)rb.number;
            int shl_c = (rc.tag == FASTINT) ? (int)rc.fastint : (int)rc.number;
            ra.tag = FASTINT;
            ra.fastint = (long)(shl_b << (shl_c & 0x1F));
            break;
        }

        case Opcode.SHR:
        {
            int shr_b = (rb.tag == FASTINT) ? (int)rb.fastint : (int)rb.number;
            int shr_c = (rc.tag == FASTINT) ? (int)rc.fastint : (int)rc.number;
            ra.tag = FASTINT;
            ra.fastint = (long)(shr_b >> (shr_c & 0x1F));
            break;
        }

        case Opcode.USHR:
        {
            uint ushr_b = (rb.tag == FASTINT) ? (uint)rb.fastint : (uint)(int)rb.number;
            int  ushr_c = (rc.tag == FASTINT) ? (int)rc.fastint : (int)rc.number;
            ra.tag = FASTINT;
            ra.fastint = (long)(ushr_b >> (ushr_c & 0x1F));
            break;
        }

        // === COMPARISON ===

        case Opcode.EQ:
            ra.tag = BOOLEAN;
            ra.boolean = abstract_eq(rb, rc);
            break;

        case Opcode.NEQ:
            ra.tag = BOOLEAN;
            ra.boolean = !abstract_eq(rb, rc);
            break;

        case Opcode.SEQ: {
            bool seq_r = false;
            if (rb.tag == rc.tag) {
                switch (rb.tag) {
                    case UNDEFINED: seq_r = true; break;
                    case NULL_VAL:  seq_r = true; break;
                    case BOOLEAN:   seq_r = (rb.boolean == rc.boolean); break;
                    case NUMBER:
                        // NaN !== NaN per IEEE 754 / ES spec
                        if (math::is_nan(rb.number) || math::is_nan(rc.number)) {
                            seq_r = false;
                        } else {
                            seq_r = (rb.number == rc.number);
                        }
                        break;
                    case FASTINT:   seq_r = (rb.fastint == rc.fastint); break;
                    case STRING:    seq_r = (rb.pointer == rc.pointer); break;
                    case OBJECT:    seq_r = (rb.pointer == rc.pointer); break;
                    case LIGHTFUNC: seq_r = (rb.pointer == rc.pointer); break;
                    case POINTER:   seq_r = (rb.pointer == rc.pointer); break;
                    case BUFFER:    seq_r = (rb.pointer == rc.pointer); break;
                    default: break;
                }
            } else if ((rb.tag == NUMBER && rc.tag == FASTINT) ||
                       (rb.tag == FASTINT && rc.tag == NUMBER)) {
                // NUMBER and FASTINT are the same ES type — compare by value
                seq_r = (num_val(rb) == num_val(rc));
            }
            ra.tag = BOOLEAN;
            ra.boolean = seq_r;
            break;
        }

        case Opcode.SNEQ: {
            bool sneq_r = true;
            if (rb.tag == rc.tag) {
                switch (rb.tag) {
                    case UNDEFINED: sneq_r = false; break;
                    case NULL_VAL:  sneq_r = false; break;
                    case BOOLEAN:   sneq_r = (rb.boolean != rc.boolean); break;
                    case NUMBER:
                        // NaN !== NaN per IEEE 754
                        if (math::is_nan(rb.number) && math::is_nan(rc.number)) {
                            sneq_r = true;  // NaN !== NaN
                        } else {
                            sneq_r = (rb.number != rc.number);
                        }
                        break;
                    case FASTINT:   sneq_r = (rb.fastint != rc.fastint); break;
                    case STRING:    sneq_r = (rb.pointer != rc.pointer); break;
                    case OBJECT:    sneq_r = (rb.pointer != rc.pointer); break;
                    case LIGHTFUNC: sneq_r = (rb.pointer != rc.pointer); break;
                    case POINTER:   sneq_r = (rb.pointer != rc.pointer); break;
                    case BUFFER:    sneq_r = (rb.pointer != rc.pointer); break;
                    default: sneq_r = true; break;
                }
            } else if ((rb.tag == NUMBER && rc.tag == FASTINT) ||
                       (rb.tag == FASTINT && rc.tag == NUMBER)) {
                sneq_r = (num_val(rb) != num_val(rc));
            }
            ra.tag = BOOLEAN;
            ra.boolean = sneq_r;
            break;
        }

        case Opcode.LT:
            ra.tag = BOOLEAN;
            if (rb.tag == STRING && rc.tag == STRING) {
                ra.boolean = (hstring::hstring_compare((HString*)rb.pointer, (HString*)rc.pointer) < 0);
            } else if (rb.tag == FASTINT && rc.tag == FASTINT) {
                ra.boolean = (rb.fastint < rc.fastint);
            } else {
                ra.boolean = (num_val(rb) < num_val(rc));
            }
            break;

        case Opcode.LE:
            ra.tag = BOOLEAN;
            if (rb.tag == STRING && rc.tag == STRING) {
                ra.boolean = (hstring::hstring_compare((HString*)rb.pointer, (HString*)rc.pointer) <= 0);
            } else if (rb.tag == FASTINT && rc.tag == FASTINT) {
                ra.boolean = (rb.fastint <= rc.fastint);
            } else {
                ra.boolean = (num_val(rb) <= num_val(rc));
            }
            break;

        case Opcode.GT:
            ra.tag = BOOLEAN;
            if (rb.tag == STRING && rc.tag == STRING) {
                ra.boolean = (hstring::hstring_compare((HString*)rb.pointer, (HString*)rc.pointer) > 0);
            } else if (rb.tag == FASTINT && rc.tag == FASTINT) {
                ra.boolean = (rb.fastint > rc.fastint);
            } else {
                ra.boolean = (num_val(rb) > num_val(rc));
            }
            break;

        case Opcode.GE:
            ra.tag = BOOLEAN;
            if (rb.tag == STRING && rc.tag == STRING) {
                ra.boolean = (hstring::hstring_compare((HString*)rb.pointer, (HString*)rc.pointer) >= 0);
            } else if (rb.tag == FASTINT && rc.tag == FASTINT) {
                ra.boolean = (rb.fastint >= rc.fastint);
            } else {
                ra.boolean = (num_val(rb) >= num_val(rc));
            }
            break;

        case Opcode.INSTANCEOF: {
            // ES5 §11.8.6: RelationalExpression instanceof ShiftExpression
            // Right side must be an object (or LIGHTFUNC in our internal repr.)
            // Right side must be callable (has [[HasInstance]])
            // [[HasInstance]] §15.3.5.3: if Type(lval) is not Object → false
            //   Get rval.prototype, walk lval's prototype chain
            ra.tag = BOOLEAN;
            ra.boolean = false;

            TVal rval = *rc;
            if (rval.tag == LIGHTFUNC) {
                // LIGHTFUNC builtins are callable; look up their prototype
                uint fn_idx = (uint)rval.fastint;
                HObject* proto_obj = null;
                switch (fn_idx) {
                    case 6:  proto_obj = vm.heap.err_proto;         break; // BUILTIN_ERROR
                    case 7:  proto_obj = vm.heap.type_err_proto;    break; // BUILTIN_TYPE_ERROR
                    case 8:  proto_obj = vm.heap.range_err_proto;   break; // BUILTIN_RANGE_ERROR
                    case 9:  proto_obj = vm.heap.ref_err_proto;     break; // BUILTIN_REFERENCE_ERROR
                    case 10: proto_obj = vm.heap.syntax_err_proto;  break; // BUILTIN_SYNTAX_ERROR
                    case 11: proto_obj = vm.heap.eval_err_proto;    break; // BUILTIN_EVAL_ERROR
                    case 13: proto_obj = vm.heap.bool_proto;        break; // BUILTIN_BOOLEAN
                    case 16: proto_obj = vm.heap.string_proto;      break; // BUILTIN_STRING
                    case 22: proto_obj = vm.heap.object_proto;      break; // BUILTIN_OBJECT
                    case 25: proto_obj = vm.heap.array_proto;       break; // BUILTIN_ARRAY
                    default: break;
                }
                if (proto_obj != null && rb.tag == OBJECT) {
                    HObject* cur = (HObject*)rb.pointer;
                    const uint MAX_PROTO_DEPTH = 256;
                    uint depth = 0;
                    while (cur != null && depth < MAX_PROTO_DEPTH) {
                        if (cur == proto_obj) {
                            ra.boolean = true;
                            break;
                        }
                        cur = cur.prototype;
                        depth++;
                    }
                }
                break;
            }

            if (rval.tag != OBJECT) {
                // TypeError: right-hand side must be an object
                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = vm.heap.type_err_proto;
                    HString* msg_key = intern_string(vm, "message");
                    HString* msg_val = intern_string(vm, "Right-hand side of instanceof is not an object");
                    TVal msg_tv;
                    msg_tv.tag = STRING;
                    msg_tv.pointer = msg_val;
                    err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                    TVal err_val;
                    err_val.tag = OBJECT;
                    err_val.pointer = err;
                    if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                        return VM_ERROR~;
                    }
                } else {
                    return VM_ERROR~;
                }
                break;
            }

            HObject* rfunc = (HObject*)rval.pointer;
            if (rfunc == null || !rfunc.is_callable()) {
                // TypeError: right-hand side must be callable
                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = vm.heap.type_err_proto;
                    HString* msg_key = intern_string(vm, "message");
                    HString* msg_val = intern_string(vm, "Right-hand side of instanceof is not callable");
                    TVal msg_tv;
                    msg_tv.tag = STRING;
                    msg_tv.pointer = msg_val;
                    err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                    TVal err_val;
                    err_val.tag = OBJECT;
                    err_val.pointer = err;
                    if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                        return VM_ERROR~;
                    }
                } else {
                    return VM_ERROR~;
                }
                break;
            }

            // §15.3.5.3 step 1: If Type(lval) is not Object → false
            if (rb.tag != OBJECT) {
                break;
            }

            // Get rval.prototype
            HString* proto_key_str = intern_string(vm, "prototype");
            TVal proto_val = get_prop_with_proto(rfunc, proto_key_str);
            if (proto_val.tag != OBJECT) {
                // ES5 §15.3.5.3 step 3: If Type(O) is not Object, throw a TypeError.
                // But gracefully handle missing .prototype by returning false.
                ra.boolean = false;
                break;
            }

            HObject* proto_obj = (HObject*)proto_val.pointer;
            HObject* cur = (HObject*)rb.pointer;
            const uint MAX_PROTO_DEPTH = 256;
            uint depth = 0;
            while (cur != null && depth < MAX_PROTO_DEPTH) {
                if (cur == proto_obj) {
                    ra.boolean = true;
                    break;
                }
                cur = cur.prototype;
                depth++;
            }
            break;
        }

        case Opcode.IN: {
            // ES5 §11.8.7: RelationalExpression in ShiftExpression
            // Right side must be an object; TypeError otherwise.
            // Returns true if the object has a property with the given name
            // (own or inherited — check via [[HasProperty]]).
            ra.tag = BOOLEAN;
            ra.boolean = false;

            if (rc.tag != OBJECT) {
                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = vm.heap.type_err_proto;
                    HString* msg_key = intern_string(vm, "message");
                    HString* msg_val = intern_string(vm, "in requires an object");
                    TVal msg_tv;
                    msg_tv.tag = STRING;
                    msg_tv.pointer = msg_val;
                    err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WEC);
                    TVal err_val;
                    err_val.tag = OBJECT;
                    err_val.pointer = err;
                    if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                        return VM_ERROR~;
                    }
                } else {
                    return VM_ERROR~;
                }
                break;
            }

            HObject* obj = (HObject*)rc.pointer;
            void* key = get_prop_key(vm, rb);
            if (key != null) {
                ra.boolean = obj.has_prop_proto(key);
            }
            break;
        }

        // === CONTROL FLOW ===

        case Opcode.JUMP: {
            int sabc = insn.get_sabc();
            int target = (int)((long)(curr_pc - code_base) + (long)sabc);
            curr_pc = code_base + target;
            act.curr_pc = curr_pc;
            break;
        }

        case Opcode.IF_TRUE:
            if (is_truthy(ra)) {
                int sbx = insn.get_sbc();
                int target = (int)((long)(curr_pc - code_base) + (long)sbx);
                curr_pc = code_base + target;
                act.curr_pc = curr_pc;
            }
            break;

        case Opcode.IF_FALSE:
            if (!is_truthy(ra)) {
                int sbx = insn.get_sbc();
                int target = (int)((long)(curr_pc - code_base) + (long)sbx);
                curr_pc = code_base + target;
                act.curr_pc = curr_pc;
            }
            break;

        // === PROPERTY ACCESS ===

        case Opcode.GETPROP:
            if (rb.tag == OBJECT) {
                HObject* hobj = (HObject*)rb.pointer;
                void* key = get_prop_key(vm, rc);
                if (key != null) {
                    TVal found = get_prop_with_proto(hobj, key);
                    *ra = found;
                } else {
                    ra.tag = UNDEFINED;
                    ra.pointer = null;
                }
            } else if (rb.tag == NULL_VAL || rb.tag == UNDEFINED) {
                // TypeError: Cannot read properties of null/undefined
                HString* name_hstr = null;
                if (rc.tag == STRING) {
                    name_hstr = (HString*)rc.pointer;
                }
                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = vm.heap.type_err_proto;
                    char[160] buf;
                    if (name_hstr != null) {
                        int len = libc::snprintf(&buf, 160, "Cannot read properties of %s (reading '%s')",
                                                 (rb.tag == NULL_VAL ? "null" : "undefined"),
                                                 name_hstr.get_cstr());
                        if (len > 0 && len < 160) {
                            HString* msg_str = intern_string(vm, buf[:len]);
                            TVal msg_val;
                            msg_val.tag = STRING;
                            msg_val.pointer = msg_str;
                            HString* msg_key = intern_string(vm, "message");
                            err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                        }
                    }
                    TVal err_val;
                    err_val.tag = OBJECT;
                    err_val.pointer = err;
                    if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                        return VM_ERROR~;
                    }
                } else {
                    return VM_ERROR~;
                }
            } else if (rb.tag == STRING) {
                // Check if this is a Symbol (0xFF-prefixed string)
                HString* h_str = (HString*)rb.pointer;
                if (h_str != null && h_str.is_symbol() && vm.heap.symbol_proto != null) {
                    // Auto-box symbol primitive: walk Symbol.prototype chain
                    HString* key = get_prop_key(vm, rc);
                    if (key != null) {
                        TVal found = get_prop_with_proto(vm.heap.symbol_proto, key);
                        *ra = found;
                    } else {
                        ra.tag = UNDEFINED;
                        ra.pointer = null;
                    }
                } else {
                    // Auto-box string primitive: walk String.prototype chain
                    HString* key = get_prop_key(vm, rc);
                    if (key != null && vm.heap.string_proto != null) {
                        TVal found = get_prop_with_proto(vm.heap.string_proto, key);
                        *ra = found;
                    } else {
                        ra.tag = UNDEFINED;
                        ra.pointer = null;
                    }
                }
            } else if (rb.tag == NUMBER || rb.tag == FASTINT) {
                // Auto-box number primitive: walk Number.prototype chain
                HString* key = get_prop_key(vm, rc);
                if (key != null && vm.heap.number_proto != null) {
                    TVal found = get_prop_with_proto(vm.heap.number_proto, key);
                    *ra = found;
                } else {
                    ra.tag = UNDEFINED;
                    ra.pointer = null;
                }
            } else if (rb.tag == BOOLEAN) {
                // Auto-box boolean primitive: walk Boolean.prototype chain
                HString* key = get_prop_key(vm, rc);
                if (key != null && vm.heap.bool_proto != null) {
                    TVal found = get_prop_with_proto(vm.heap.bool_proto, key);
                    *ra = found;
                } else {
                    ra.tag = UNDEFINED;
                    ra.pointer = null;
                }
            } else {
                ra.tag = UNDEFINED;
                ra.pointer = null;
            }
            break;

        case Opcode.PUTPROP:
            if (ra.tag == OBJECT) {
                HObject* hobj = (HObject*)ra.pointer;
                void* key = get_prop_key(vm, rb);
                if (key != null) {
                    hobj.put_prop(key, *rc, hobject::PROP_FLAGS_WEC);
                }
            } else if (ra.tag == NULL_VAL || ra.tag == UNDEFINED) {
                // TypeError: Cannot set properties of null/undefined
                HString* name_hstr = null;
                if (rb.tag == STRING) {
                    name_hstr = (HString*)rb.pointer;
                }
                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = vm.heap.type_err_proto;
                    char[160] buf;
                    if (name_hstr != null) {
                        int len = libc::snprintf(&buf, 160, "Cannot set properties of %s (setting '%s')",
                                                 (ra.tag == NULL_VAL ? "null" : "undefined"),
                                                 name_hstr.get_cstr());
                        if (len > 0 && len < 160) {
                            HString* msg_str = intern_string(vm, buf[:len]);
                            TVal msg_val;
                            msg_val.tag = STRING;
                            msg_val.pointer = msg_str;
                            HString* msg_key = intern_string(vm, "message");
                            err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                        }
                    }
                    TVal err_val;
                    err_val.tag = OBJECT;
                    err_val.pointer = err;
                    if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                        return VM_ERROR~;
                    }
                } else {
                    return VM_ERROR~;
                }
            }
            break;

        case Opcode.DELPROP: {
            // ES5 §11.4.1: delete operator
            // A = delete B[C], where B = object, C = property key
            // Returns boolean: true if deleted or not found,
            // false if the property exists and is non-configurable.
            ra.tag = BOOLEAN;
            ra.boolean = true;

            if (rb.tag == OBJECT) {
                HObject* hobj = (HObject*)rb.pointer;
                void* key = get_prop_key(vm, rc);
                if (key != null) {
                    ra.boolean = hobj.es_delete_prop(key);
                }
            }
            // For null, undefined, and other primitives:
            // [[Delete]] on a non-object base always returns true.
            break;
        }

        // === OBJECT / ARRAY CREATION ===

        case Opcode.NEWOBJ: {
            HObject*? new_obj = vm.heap.alloc_object(hobject::ObjClass.OBJECT);
            if (try o = new_obj) {
                o.prototype = vm.heap.object_proto;
                ra.tag = OBJECT;
                ra.pointer = o;
            } else {
                ra.tag = UNDEFINED;
                ra.pointer = null;
            }
            break;
        }

        case Opcode.NEWARR: {
            HObject*? new_arr = vm.heap.alloc_object(hobject::ObjClass.ARRAY);
            if (try a = new_arr) {
                a.prototype = vm.heap.array_proto;
                ra.tag = OBJECT;
                ra.pointer = a;
            } else {
                ra.tag = UNDEFINED;
                ra.pointer = null;
            }
            break;
        }

        case Opcode.NEWREGEXP: {
            // A = dest register, BC = constant pool index of "/pattern/flags" string
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                TVal raw_tv = constants[bc];
                if (raw_tv.tag == STRING) {
                    HString* raw_hs = (HString*)raw_tv.pointer;
                    char[] raw = raw_hs.get_data();
                    usz len = raw.len;

                    // Parse "/pattern/flags" by finding the closing '/'
                    // Flags are only letters, so scan backwards past them
                    usz end_slash = len - 1;
                    while (end_slash > 0 &&
                           ((raw[end_slash] >= 'a' && raw[end_slash] <= 'z') ||
                            (raw[end_slash] >= 'A' && raw[end_slash] <= 'Z'))) {
                        end_slash--;
                    }

                    if (end_slash > 0 && raw[0] == '/' && raw[end_slash] == '/') {
                        char[] pattern_data = raw[1..end_slash - 1];
                        char[] flag_data = {};
                        if (end_slash + 1 < len) {
                            flag_data = raw[end_slash + 1..len - 1];
                        }

                        // Convert JS flags to libregexp flag bits
                        int flags = 0;
                        int js_flags = 0;  // 1=g, 2=i, 4=m
                        for (usz i = 0; i < flag_data.len; i++) {
                            char f = flag_data[i];
                            if (f == 'g') {
                                js_flags |= 1;
                            } else if (f == 'i') {
                                flags |= re_bindings::RE_FLAG_IGNORECASE;
                                js_flags |= 2;
                            } else if (f == 'm') {
                                flags |= re_bindings::RE_FLAG_MULTILINE;
                                js_flags |= 4;
                            } else if (f == 's') {
                                flags |= re_bindings::RE_FLAG_DOTALL;
                            }
                        }

                        // Compile the regexp
                        // lre_compile requires a null-terminated pattern string
                        char[256] pattern_buf;
                        usz copy_len = pattern_data.len < 255 ? pattern_data.len : 255;
                        libc::memcpy(&pattern_buf, pattern_data.ptr, copy_len);
                        pattern_buf[copy_len] = 0;
                        char[128] error_buf;
                        void* compiled = re_bindings::re_compile(
                            &pattern_buf, copy_len,
                            flags, &error_buf, 128
                        );

                        if (compiled != null) {
                            HObject*? obj_raw = vm.heap.alloc_object(hobject::ObjClass.REGEXP);
                            if (try obj = obj_raw) {
                                obj.prototype = vm.heap.regexp_proto;
                                obj.regexp_data = compiled;
                                // Store pattern string as primitive_value
                                HString* pattern_hs = intern_string(vm, pattern_data);
                                obj.primitive_value.tag = STRING;
                                obj.primitive_value.pointer = pattern_hs;
                                // Set instance properties (ES5 §15.10.7)
                                HString* source_key = intern_string(vm, "source");
                                TVal source_tv;
                                source_tv.tag = STRING;
                                source_tv.pointer = pattern_hs;
                                obj.put_prop(source_key, source_tv, hobject::PROP_FLAGS_WEC);
                                HString* global_key = intern_string(vm, "global");
                                TVal global_tv;
                                global_tv.tag = BOOLEAN;
                                global_tv.boolean = (js_flags & 1) != 0;
                                obj.put_prop(global_key, global_tv, hobject::PROP_FLAGS_WEC);
                                HString* ignorecase_key = intern_string(vm, "ignoreCase");
                                TVal ignorecase_tv;
                                ignorecase_tv.tag = BOOLEAN;
                                ignorecase_tv.boolean = (js_flags & 2) != 0;
                                obj.put_prop(ignorecase_key, ignorecase_tv, hobject::PROP_FLAGS_WEC);
                                HString* multiline_key = intern_string(vm, "multiline");
                                TVal multiline_tv;
                                multiline_tv.tag = BOOLEAN;
                                multiline_tv.boolean = (js_flags & 4) != 0;
                                obj.put_prop(multiline_key, multiline_tv, hobject::PROP_FLAGS_WEC);
                                HString* lastindex_key = intern_string(vm, "lastIndex");
                                TVal lastindex_tv;
                                lastindex_tv.tag = FASTINT;
                                lastindex_tv.fastint = 0;
                                obj.put_prop(lastindex_key, lastindex_tv, hobject::PROP_FLAGS_WEC);
                                ra.tag = OBJECT;
                                ra.pointer = obj;
                            } else {
                                // If alloc failed, free the compiled regexp
                                re_bindings::re_free(compiled);
                                ra.tag = UNDEFINED;
                                ra.pointer = null;
                            }
                        } else {
                            // re_compile failed — still create an empty regexp object
                            // so typeof works correctly
                            HObject*? obj_raw = vm.heap.alloc_object(hobject::ObjClass.REGEXP);
                            if (try obj = obj_raw) {
                                obj.prototype = vm.heap.regexp_proto;
                                obj.regexp_data = null;
                                HString* pattern_hs = intern_string(vm, pattern_data);
                                obj.primitive_value.tag = STRING;
                                obj.primitive_value.pointer = pattern_hs;
                                ra.tag = OBJECT;
                                ra.pointer = obj;
                            } else {
                                ra.tag = UNDEFINED;
                                ra.pointer = null;
                            }
                        }
                    } else {
                        ra.tag = UNDEFINED;
                        ra.pointer = null;
                    }
                } else {
                    ra.tag = UNDEFINED;
                    ra.pointer = null;
                }
            } else {
                ra.tag = UNDEFINED;
                ra.pointer = null;
            }
            break;
        }

        case Opcode.SETALEN: {
            // A = array register, BC = element count (high-water mark)
            if (ra.tag == OBJECT) {
                HObject* hobj = (HObject*)ra.pointer;
                uint count = insn.get_bc();
                HString* len_str = intern_string(vm, "length");
                TVal len_val;
                len_val.tag = FASTINT;
                len_val.fastint = (long)count;
                hobj.put_prop(len_str, len_val, hobject::PROP_FLAGS_WEC);
            }
            break;
        }

        case Opcode.ARRSPRD: {
            // A = target array reg, B = index reg (in/out), C = source array reg
            if (ra.tag == OBJECT && rc.tag == OBJECT) {
                HObject* target = (HObject*)ra.pointer;
                HObject* source = (HObject*)rc.pointer;
                if (source != null) {
                    // Get source .length
                    HString* len_key = intern_string(vm, "length");
                    TVal len_tv = get_prop_with_proto(source, len_key);
                    long src_len = 0;
                    if (len_tv.tag == FASTINT) {
                        src_len = len_tv.fastint;
                    } else if (len_tv.tag == NUMBER) {
                        src_len = (long)len_tv.number;
                    }

                    // Get current index
                    long idx = 0;
                    if (rb.tag == FASTINT) {
                        idx = rb.fastint;
                    } else if (rb.tag == NUMBER) {
                        idx = (long)rb.number;
                    }

                    // Copy elements
                    for (long i = 0; i < src_len; i++) {
                        char[16] ibuf;
                        int ilen = libc::snprintf(&ibuf, 16, "%ld", idx + i);
                        if (ilen > 0 && ilen < 16) {
                            HString* key = intern_string(vm, ibuf[:ilen]);
                            if (key != null) {
                                char[16] jbuf;
                                int jlen = libc::snprintf(&jbuf, 16, "%ld", i);
                                if (jlen > 0 && jlen < 16) {
                                    HString* src_key = intern_string(vm, jbuf[:jlen]);
                                    if (src_key != null) {
                                        TVal elem = get_prop_with_proto(source, src_key);
                                        target.put_prop(key, elem, hobject::PROP_FLAGS_WEC);
                                    }
                                }
                            }
                        }
                    }

                    // Update index register
                    rb.tag = FASTINT;
                    rb.fastint = idx + src_len;
                }
            }
            break;
        }

        case Opcode.SPREAD_ARG: {
            // A = dest start reg, B = count out reg, C = source array reg
            if (rc.tag == OBJECT) {
                HObject* source = (HObject*)rc.pointer;
                if (source != null) {
                    // Get source .length
                    HString* len_key = intern_string(vm, "length");
                    TVal len_tv = get_prop_with_proto(source, len_key);
                    long src_len = 0;
                    if (len_tv.tag == FASTINT) {
                        src_len = len_tv.fastint;
                    } else if (len_tv.tag == NUMBER) {
                        src_len = (long)len_tv.number;
                    }

                    uint dest_start = insn.a;
                    uint count_reg = insn.b;

                    // Copy elements from source array into consecutive registers
                    for (long i = 0; i < src_len; i++) {
                        TVal* dest_slot = regs_base + dest_start + (uint)i;
                        char[16] jbuf;
                        int jlen = libc::snprintf(&jbuf, 16, "%ld", i);
                        if (jlen > 0 && jlen < 16) {
                            HString* src_key = intern_string(vm, jbuf[:jlen]);
                            if (src_key != null) {
                                TVal elem = get_prop_with_proto(source, src_key);
                                dest_slot.tag = elem.tag;
                                dest_slot.fastint = elem.fastint;
                                dest_slot.number = elem.number;
                                dest_slot.pointer = elem.pointer;
                            } else {
                                dest_slot.tag = UNDEFINED;
                                dest_slot.pointer = null;
                            }
                        }
                    }

                    // Store count in output register
                    TVal* count_slot = regs_base + count_reg;
                    count_slot.tag = FASTINT;
                    count_slot.fastint = src_len;
                }
            } else {
                // Non-object: spread 0 elements, store 0
                TVal* count_slot = regs_base + insn.b;
                count_slot.tag = FASTINT;
                count_slot.fastint = 0;
            }
            break;
        }

        // === FUNCTION CALLS ===
        // Duktape CALL: A=result_reg, B=callee_reg, C=nargs
        // Layout: valstack[base] = callee, valstack[base+1] = this, valstack[base+2..base+1+nargs] = args
        //
        // CALL_S: same layout but nargs is read from valstack[C] at runtime

        case Opcode.CALL:
        case Opcode.CALL_S: {
            // Compiler convention: A=result_reg, B=callee_reg, C=nargs (or nargs_reg for CALL_S)
            uint result_reg = insn.a;
            uint callee_reg = insn.b;
            uint nargs;
            if (op == Opcode.CALL_S) {
                // Read nargs from the register at index C
                TVal* nargs_slot = regs_base + insn.c;
                if (nargs_slot.tag == FASTINT) {
                    nargs = (uint)nargs_slot.fastint;
                } else if (nargs_slot.tag == NUMBER) {
                    nargs = (uint)nargs_slot.number;
                } else {
                    nargs = 0;
                }
            } else {
                nargs = insn.c;
            }

            TVal* func_slot = regs_base + callee_reg;
            TVal func_val = *func_slot;

            if (func_val.tag == LIGHTFUNC) {
                uint fn_idx = (uint)func_val.fastint;

                builtins::BuiltinContext ctx;
                ctx.vm = vm;
                ctx.regs = vm.valstack;
                ctx.base_reg = (ushort)((act.bottom_byteoff / (uint)TVal::size) + callee_reg + 2);
                ctx.argc = (ushort)nargs;
                ctx.result = regs_base + result_reg;
                ctx.heap = vm.heap;
                ctx.this_val = regs_base[callee_reg + 1];
                ctx.is_constructor = false;
                ctx.needs_re_dispatch = false;
                ctx.re_nargs = 0;
                ctx.global_env = vm.global_env;
                ctx.should_throw = false;

                builtins::dispatch_builtin(fn_idx, &ctx);

                if (ctx.should_throw) {
                    if (!vm_throw_value(vm, ctx.throw_value, act, &curr_pc, &needs_restart)) {
                        return VM_ERROR~;
                    }
                    break;
                }

                if (ctx.needs_re_dispatch) {
                    // Builtin (.call/.apply/bound) modified the stack — re-dispatch
                    func_val = regs_base[callee_reg];
                    nargs = ctx.re_nargs;
                    // Fall through to OBJECT handling
                } else {
                    break;
                }
            }

            if (func_val.tag != OBJECT) {
                // TypeError: value is not a function
                HString* type_str = typeof_string(vm, &func_val);
                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = vm.heap.type_err_proto;
                    char[160] buf;
                    int len = libc::snprintf(&buf, 160, "%s is not a function",
                                             type_str.get_cstr());
                    if (len > 0 && len < 160) {
                        HString* msg_str = intern_string(vm, buf[:len]);
                        TVal msg_val;
                        msg_val.tag = STRING;
                        msg_val.pointer = msg_str;
                        HString* msg_key = intern_string(vm, "message");
                        err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                    }
                    TVal err_val;
                    err_val.tag = OBJECT;
                    err_val.pointer = err;
                    if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                        return VM_ERROR~;
                    }
                } else {
                    return VM_ERROR~;
                }
                break;
            }

            // === OBJECT CALL HANDLING ===
            HObject* hobj = (HObject*)func_val.pointer;
            if (hobj == null || !hobj.is_callable()) {
                // TypeError: object is not callable (e.g., a non-function object)
                HString* type_str = typeof_string(vm, &func_val);
                HObject*? err_raw2 = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err2 = err_raw2) {
                    err2.prototype = vm.heap.type_err_proto;
                    char[160] buf;
                    int len = libc::snprintf(&buf, 160, "%s is not a function",
                                             type_str.get_cstr());
                    if (len > 0 && len < 160) {
                        HString* msg_str = intern_string(vm, buf[:len]);
                        TVal msg_val;
                        msg_val.tag = STRING;
                        msg_val.pointer = msg_str;
                        HString* msg_key = intern_string(vm, "message");
                        err2.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                    }
                    TVal err_val2;
                    err_val2.tag = OBJECT;
                    err_val2.pointer = err2;
                    if (!vm_throw_value(vm, err_val2, act, &curr_pc, &needs_restart)) {
                        return VM_ERROR~;
                    }
                } else {
                    return VM_ERROR~;
                }
                break;
            }

            // Handle builtin function objects (e.g., Number as OBJECT tag)
            if (hobj.comp_func == null) {
                if (hobj.builtin_fn_index >= 0) {
                    uint fn_idx = (uint)hobj.builtin_fn_index;
                    builtins::BuiltinContext ctx;
                    ctx.vm = vm;
                    ctx.regs = vm.valstack;
                    ctx.base_reg = (ushort)((act.bottom_byteoff / (uint)TVal::size) + callee_reg + 2);
                    ctx.argc = (ushort)nargs;
                    ctx.result = regs_base + result_reg;
                    ctx.heap = vm.heap;
                    ctx.this_val = regs_base[callee_reg + 1];
                    ctx.is_constructor = false;
                    ctx.needs_re_dispatch = false;
                    ctx.re_nargs = 0;
                    ctx.global_env = vm.global_env;
                    ctx.should_throw = false;
                    builtins::dispatch_builtin(fn_idx, &ctx);

                    if (ctx.should_throw) {
                        if (!vm_throw_value(vm, ctx.throw_value, act, &curr_pc, &needs_restart)) {
                            return VM_ERROR~;
                        }
                        break;
                    }

                    if (ctx.needs_re_dispatch) {
                        // Re-dispatch from bound function: re-read target from stack
                        func_val = regs_base[callee_reg];
                        hobj = (HObject*)func_val.pointer;
                        nargs = ctx.re_nargs;
                        // Only support re-dispatch to compiled functions from here;
                        // if the target is another builtin, just break
                        if (hobj.comp_func != null) {
                            // Continue to compiled function handling below (skip error)
                        } else {
                            break;
                        }
                    } else {
                        break;
                    }
                } else {
                    // Callable object with no compiled function and no builtin index: error
                    HString* type_str = typeof_string(vm, &func_val);
                    HObject*? err_raw2 = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                    if (try err2 = err_raw2) {
                        err2.prototype = vm.heap.type_err_proto;
                        char[160] buf;
                        int len = libc::snprintf(&buf, 160, "%s is not a function",
                                                 type_str.get_cstr());
                        if (len > 0 && len < 160) {
                            HString* msg_str = intern_string(vm, buf[:len]);
                            TVal msg_val;
                            msg_val.tag = STRING;
                            msg_val.pointer = msg_str;
                            HString* msg_key = intern_string(vm, "message");
                            err2.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                        }
                        TVal err_val2;
                        err_val2.tag = OBJECT;
                        err_val2.pointer = err2;
                        if (!vm_throw_value(vm, err_val2, act, &curr_pc, &needs_restart)) {
                            return VM_ERROR~;
                        }
                    } else {
                        return VM_ERROR~;
                    }
                    break;
                }
            }

            CompiledFunction* target = hobj.comp_func;

            // === Generator function handling (ES6 §25.3) ===
            if (target.is_generator()) {
                // Resume path: .next()/.throw()/.return() set heap.resume_gen
                if (vm.heap.resume_gen != null && (CompiledFunction*)vm.heap.resume_gen.func == target) {
                    GeneratorState* gs = vm.heap.resume_gen;

                    if (gs.state == GEN_COMPLETED) {
                        vm.heap.resume_gen = null;
                        regs_base[result_reg].tag = UNDEFINED;
                        regs_base[result_reg].pointer = null;
                        break;
                    }

                    // Set state to EXECUTING
                    gs.state = GEN_EXECUTING;

                    // Calculate register layout
                    uint frame_start_r = callee_reg + 2;
                    uint new_bottom_idx_r = (act.bottom_byteoff / TVal::size) + frame_start_r;
                    uint needed_r = new_bottom_idx_r + target.num_regs;

                    if (!ensure_valstack(vm, needed_r)) {
                        gs.state = GEN_SUSPENDED_YIELD;
                        regs_base[result_reg].tag = UNDEFINED;
                        regs_base[result_reg].pointer = null;
                        break;
                    }

                    regs_base = ptr_from_byteoff(vm.valstack, act.bottom_byteoff);

                    if (vm.activation_count >= MAX_CALLS) {
                        gs.state = GEN_SUSPENDED_YIELD;
                        regs_base[result_reg].tag = UNDEFINED;
                        regs_base[result_reg].pointer = null;
                        break;
                    }

                    // Push activation
                    Activation* new_act_r = &vm.activations[vm.activation_count];
                    vm.activation_count++;

                    new_act_r.parent = act;
                    new_act_r.func = target;
                    new_act_r.var_env = gs.var_env;
                    new_act_r.lex_env = gs.lex_env;
                    new_act_r.cat = null;
                    new_act_r.curr_pc = gs.saved_pc;
                    new_act_r.bottom_byteoff = new_bottom_idx_r * (uint)TVal::size;
                    new_act_r.retval_byteoff = act.bottom_byteoff + result_reg * (uint)TVal::size;
                    new_act_r.reserve_byteoff = byte_offset(vm.valstack, vm.valstack_end);
                    new_act_r.flags = ACT_FLAG_STRICT | ACT_FLAG_PREVENT_YIELD;
                    new_act_r.this_binding = gs.this_binding;

                    // Copy saved registers to valstack
                    TVal* new_regs_r = ptr_from_byteoff(vm.valstack, new_act_r.bottom_byteoff);
                    uint new_nregs_r = target.num_regs;
                    for (uint i = 0; i < new_nregs_r; i++) {
                        new_regs_r[i] = gs.saved_regs[i];
                    }

                    vm.valstack_top = (TVal*)((usz)new_regs_r + (usz)new_nregs_r * TVal::size);
                    vm.valstack_bottom = new_act_r.bottom_byteoff;

                    needs_restart = true;
                    break;
                }

                // Initial call: create generator object, don't execute body
                // Calculate register layout
                uint frame_start = callee_reg + 2;
                uint new_bottom_idx = (act.bottom_byteoff / TVal::size) + frame_start;
                uint needed = new_bottom_idx + target.num_regs;

                if (!ensure_valstack(vm, needed)) {
                    regs_base[result_reg].tag = UNDEFINED;
                    regs_base[result_reg].pointer = null;
                    break;
                }

                regs_base = ptr_from_byteoff(vm.valstack, act.bottom_byteoff);

                // Allocate GeneratorState
                void* gs_raw = vm.heap.alloc_func(vm.heap.heap_udata, GeneratorState::size);
                if (gs_raw == null) {
                    regs_base[result_reg].tag = UNDEFINED;
                    regs_base[result_reg].pointer = null;
                    break;
                }
                GeneratorState* gs = (GeneratorState*)gs_raw;
                libc::memset(gs_raw, 0, GeneratorState::size);

                gs.state = GEN_SUSPENDED_START;
                gs.func = target;
                gs.num_regs = target.num_regs;
                gs.saved_pc = target.code;
                gs.var_env = hobj.var_env;
                gs.lex_env = hobj.lex_env;
                gs.this_binding = regs_base[callee_reg + 1];

                // Allocate and copy saved registers
                usz regs_bytes = (usz)target.num_regs * TVal::size;
                void* regs_raw = vm.heap.alloc_func(vm.heap.heap_udata, regs_bytes);
                if (regs_raw == null) {
                    vm.heap.free_func(vm.heap.heap_udata, gs_raw);
                    regs_base[result_reg].tag = UNDEFINED;
                    regs_base[result_reg].pointer = null;
                    break;
                }
                gs.saved_regs = (TVal*)regs_raw;
                libc::memset(regs_raw, 0, regs_bytes);

                // Initialize registers with args (rest = undefined for extra slots)
                TVal* base = ptr_from_byteoff(vm.valstack, (usz)new_bottom_idx * TVal::size);
                TVal* old_args = regs_base + callee_reg + 2;
                uint copy_count = target.has_rest() ? (uint)target.num_formals : nargs;
                if (copy_count > target.num_regs) copy_count = target.num_regs;
                for (uint i = 0; i < copy_count; i++) {
                    base[i] = old_args[i];
                    gs.saved_regs[i] = old_args[i];
                }
                for (uint i = copy_count; i < target.num_regs; i++) {
                    base[i].set_undefined();
                    gs.saved_regs[i].tag = UNDEFINED;
                    gs.saved_regs[i].pointer = null;
                }

                // Handle rest parameter: build rest array and store in saved_regs
                if (target.has_rest() && nargs > (uint)target.num_formals) {
                    uint rest_idx = (uint)target.num_formals;
                    uint overflow = nargs - (uint)target.num_formals;

                    HObject*? arr_raw = vm.heap.alloc_object(hobject::ObjClass.ARRAY);
                    if (try a = arr_raw) {
                        a.prototype = vm.heap.array_proto;
                        for (uint i = 0; i < overflow; i++) {
                            char[16] ibuf;
                            int ilen = libc::snprintf(&ibuf, 16, "%u", i);
                            if (ilen > 0 && ilen < 16) {
                                HString* key = intern_string(vm, ibuf[:ilen]);
                                if (key != null) {
                                    a.put_prop(key, old_args[(uint)target.num_formals + i], hobject::PROP_FLAGS_WEC);
                                }
                            }
                        }
                        HString* len_str = intern_string(vm, "length");
                        TVal len_val;
                        len_val.tag = FASTINT;
                        len_val.fastint = (long)overflow;
                        a.put_prop(len_str, len_val, hobject::PROP_FLAGS_WEC);

                        base[rest_idx].tag = OBJECT;
                        base[rest_idx].pointer = a;
                        gs.saved_regs[rest_idx].tag = OBJECT;
                        gs.saved_regs[rest_idx].pointer = a;
                    }
                }

                // Create Generator HObject
                HObject*? gen_obj_raw = vm.heap.alloc_object(hobject::ObjClass.GENERATOR);
                HObject* gen_obj;
                if (try go = gen_obj_raw) {
                    gen_obj = go;
                } else {
                    vm.heap.free_func(vm.heap.heap_udata, gs.saved_regs);
                    vm.heap.free_func(vm.heap.heap_udata, gs_raw);
                    regs_base[result_reg].tag = UNDEFINED;
                    regs_base[result_reg].pointer = null;
                    break;
                }
                gen_obj.prototype = vm.heap.generator_proto;
                gen_obj.generator_data = gs;

                // Return generator object as the call result
                TVal* result_slot = regs_base + result_reg;
                result_slot.tag = OBJECT;
                result_slot.pointer = gen_obj;
                break;
            }

            // New callee frame starts right after func and this in the caller frame
            // Layout: callee_reg = func, callee_reg+1 = this, callee_reg+2.. callee_reg+1+nargs = args
            uint frame_start = callee_reg + 2;
            uint new_bottom_idx = (act.bottom_byteoff / TVal::size) + frame_start;
            uint needed = new_bottom_idx + target.num_regs;

            if (!ensure_valstack(vm, needed)) {
                regs_base[result_reg].tag = UNDEFINED;
                regs_base[result_reg].pointer = null;
                break;
            }

            regs_base = ptr_from_byteoff(vm.valstack, act.bottom_byteoff);
            func_slot = regs_base + callee_reg;

            if (vm.activation_count >= MAX_CALLS) {
                regs_base[result_reg].tag = UNDEFINED;
                regs_base[result_reg].pointer = null;
                break;
            }

            Activation* new_act = &vm.activations[vm.activation_count];
            vm.activation_count++;

            new_act.parent = act;
            new_act.func = target;
            new_act.var_env = hobj.var_env;
            new_act.lex_env = hobj.lex_env;
            new_act.cat = null;
            new_act.curr_pc = target.code;
            new_act.bottom_byteoff = new_bottom_idx * (uint)TVal::size;
            new_act.retval_byteoff = act.bottom_byteoff + result_reg * (uint)TVal::size;
            new_act.reserve_byteoff = byte_offset(vm.valstack, vm.valstack_end);
            new_act.flags = ACT_FLAG_STRICT;
            // Arrow functions use lexical this (inherited from enclosing scope)
            if (target.is_arrow()) {
                new_act.this_binding = act.this_binding;
            } else {
                new_act.this_binding = regs_base[callee_reg + 1];
            }

            TVal* new_regs = ptr_from_byteoff(vm.valstack, new_act.bottom_byteoff);
            uint new_nregs = target.num_regs;

            // Copy args
            TVal* old_args = regs_base + callee_reg + 2;
            if (target.has_rest()) {
                // Only copy the formal parameters (not the rest parameter)
                uint copy_count = (uint)target.num_formals;
                for (uint i = 0; i < nargs && i < copy_count; i++) {
                    new_regs[i] = old_args[i];
                }

                // Build rest array from overflow args
                uint rest_idx = copy_count;
                uint overflow = (nargs > copy_count) ? (nargs - copy_count) : 0;

                HObject*? arr_raw = vm.heap.alloc_object(hobject::ObjClass.ARRAY);
                if (try a = arr_raw) {
                    a.prototype = vm.heap.array_proto;
                    // Copy overflow args into the array
                    for (uint i = 0; i < overflow; i++) {
                        char[16] ibuf;
                        int ilen = libc::snprintf(&ibuf, 16, "%u", i);
                        if (ilen > 0 && ilen < 16) {
                            HString* key = intern_string(vm, ibuf[:ilen]);
                            if (key != null) {
                                TVal elem = old_args[copy_count + i];
                                a.put_prop(key, elem, hobject::PROP_FLAGS_WEC);
                            }
                        }
                    }
                    // Set .length
                    HString* len_str = intern_string(vm, "length");
                    TVal len_val;
                    len_val.tag = FASTINT;
                    len_val.fastint = (long)overflow;
                    a.put_prop(len_str, len_val, hobject::PROP_FLAGS_WEC);

                    new_regs[rest_idx].tag = OBJECT;
                    new_regs[rest_idx].pointer = a;
                } else {
                    new_regs[rest_idx].tag = UNDEFINED;
                    new_regs[rest_idx].pointer = null;
                }

                // Fill remaining registers with UNDEFINED (after the rest param)
                for (uint i = rest_idx + 1; i < new_nregs; i++) {
                    new_regs[i].tag = UNDEFINED;
                    new_regs[i].pointer = null;
                }
            } else {
                for (uint i = 0; i < nargs && i < (uint)target.num_args; i++) {
                    new_regs[i] = old_args[i];
                }
                for (uint i = nargs; i < new_nregs; i++) {
                    new_regs[i].tag = UNDEFINED;
                    new_regs[i].pointer = null;
                }
            }

            vm.valstack_top = (TVal*)((usz)new_regs + (usz)new_nregs * (usz)TVal::size);
            vm.valstack_bottom = new_act.bottom_byteoff;

            needs_restart = true;
            break;
        }

        case Opcode.CALL_PROP:
            ra.tag = UNDEFINED;
            ra.pointer = null;
            break;

        case Opcode.SETPROTO: {
            // A.[[Prototype]] = B
            // ABC format: A=obj_reg, B=proto_reg
            if (ra.tag != OBJECT || rb.tag != OBJECT) {
                // Non-object operands — silently ignore or error
                break;
            }
            HObject* obj = (HObject*)ra.pointer;
            HObject* proto = (HObject*)rb.pointer;
            if (obj != null && proto != null) {
                obj.prototype = proto;
            }
            break;
        }

        case Opcode.SUPER_CALL: {
            // A = super(B, args...) — call superclass constructor
            // Uses current activation's new.target
            uint result_reg = insn.a;
            uint callee_reg = insn.b;
            uint nargs = insn.c;

            TVal* super_slot = regs_base + callee_reg;
            TVal super_val = *super_slot;

            if (super_val.tag != OBJECT) {
                // TypeError: superclass is not a constructor
                HString* type_str = typeof_string(vm, &super_val);
                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = vm.heap.type_err_proto;
                    char[160] buf;
                    int len = libc::snprintf(&buf, 160, "%s is not a constructor",
                                             type_str.get_cstr());
                    if (len > 0 && len < 160) {
                        HString* msg_str = intern_string(vm, buf[:len]);
                        TVal msg_val;
                        msg_val.tag = STRING;
                        msg_val.pointer = msg_str;
                        HString* msg_key = intern_string(vm, "message");
                        err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                    }
                    TVal err_val;
                    err_val.tag = OBJECT;
                    err_val.pointer = err;
                    if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                        return VM_ERROR~;
                    }
                }
                break;
            }

            HObject* super_hobj = (HObject*)super_val.pointer;
            if (super_hobj == null || !super_hobj.is_callable()) {
                // TypeError: not callable
                HString* type_str = typeof_string(vm, &super_val);
                HObject*? err_raw2 = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err2 = err_raw2) {
                    err2.prototype = vm.heap.type_err_proto;
                    char[160] buf;
                    int len2 = libc::snprintf(&buf, 160, "%s is not a constructor",
                                              type_str.get_cstr());
                    if (len2 > 0 && len2 < 160) {
                        HString* msg_str = intern_string(vm, buf[:len2]);
                        TVal msg_val;
                        msg_val.tag = STRING;
                        msg_val.pointer = msg_str;
                        HString* msg_key = intern_string(vm, "message");
                        err2.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                    }
                    TVal err_val2;
                    err_val2.tag = OBJECT;
                    err_val2.pointer = err2;
                    if (!vm_throw_value(vm, err_val2, act, &curr_pc, &needs_restart)) {
                        return VM_ERROR~;
                    }
                }
                break;
            }

            // Use new.target from the current activation (set by NEW_OBJ)
            HObject* new_target = act.new_target;
            if (new_target == null) {
                // Not in a constructor — new.target is undefined
                // Fall back to simple call behavior
                // This shouldn't normally happen since super() is only valid in constructors
                ra.tag = UNDEFINED;
                ra.pointer = null;
                break;
            }

            // Handle builtin super constructors
            if (super_hobj.comp_func == null) {
                if (super_hobj.builtin_fn_index >= 0) {
                    uint fn_idx = (uint)super_hobj.builtin_fn_index;
                    builtins::BuiltinContext ctx;
                    ctx.vm = vm;
                    ctx.regs = vm.valstack;
                    ctx.base_reg = (ushort)(act.bottom_byteoff / TVal::size) + (ushort)(callee_reg + 2);
                    ctx.argc = (ushort)nargs;
                    ctx.result = regs_base + result_reg;
                    ctx.heap = vm.heap;
                    ctx.this_val = regs_base[callee_reg + 1];
                    ctx.is_constructor = true;
                    ctx.needs_re_dispatch = false;
                    ctx.re_nargs = 0;
                    ctx.global_env = vm.global_env;
                    ctx.should_throw = false;
                    builtins::dispatch_builtin(fn_idx, &ctx);
                }
                break;
            }

            CompiledFunction* super_target = super_hobj.comp_func;

            // Set up activation frame for superclass constructor
            // The 'this' slot should already have new_target (set by caller)
            uint frame_start = callee_reg + 2;
            uint new_bottom_idx = (act.bottom_byteoff / TVal::size) + frame_start;
            uint needed = new_bottom_idx + super_target.num_regs;

            if (!ensure_valstack(vm, needed)) {
                ra.tag = UNDEFINED;
                ra.pointer = null;
                break;
            }

            regs_base = ptr_from_byteoff(vm.valstack, act.bottom_byteoff);

            if (vm.activation_count >= MAX_CALLS) {
                ra.tag = UNDEFINED;
                ra.pointer = null;
                break;
            }

            Activation* new_act = &vm.activations[vm.activation_count];
            vm.activation_count++;

            new_act.parent = act;
            new_act.func = super_target;
            new_act.var_env = super_hobj.var_env;
            new_act.lex_env = super_hobj.lex_env;
            new_act.cat = null;
            new_act.curr_pc = super_target.code;
            new_act.bottom_byteoff = new_bottom_idx * (uint)TVal::size;
            new_act.retval_byteoff = act.bottom_byteoff + result_reg * (uint)TVal::size;
            new_act.reserve_byteoff = byte_offset(vm.valstack, vm.valstack_end);
            new_act.flags = ACT_FLAG_CONSTRUCT | ACT_FLAG_STRICT;
            new_act.this_binding = regs_base[callee_reg + 1];
            new_act.new_target = new_target;  // Pass through new.target

            TVal* new_regs = ptr_from_byteoff(vm.valstack, new_act.bottom_byteoff);
            uint new_nregs = super_target.num_regs;

            // Copy args
            TVal* old_args = regs_base + callee_reg + 2;
            if (super_target.has_rest()) {
                uint copy_count = (uint)super_target.num_formals;
                for (uint i = 0; i < nargs && i < copy_count; i++) {
                    new_regs[i] = old_args[i];
                }
                uint rest_idx = copy_count;
                uint overflow = (nargs > copy_count) ? (nargs - copy_count) : 0;
                HObject*? rest_obj_raw = vm.heap.alloc_object(hobject::ObjClass.ARRAY);
                if (try rest_obj = rest_obj_raw) {
                    rest_obj.prototype = vm.heap.array_proto;
                    // Copy overflow args into the array
                    for (uint j = 0; j < overflow; j++) {
                        char[16] ibuf;
                        int ilen = libc::snprintf(&ibuf, 16, "%u", j);
                        if (ilen > 0 && ilen < 16) {
                            HString* key = intern_string(vm, ibuf[:ilen]);
                            if (key != null) {
                                TVal elem = old_args[copy_count + j];
                                rest_obj.put_prop(key, elem, hobject::PROP_FLAGS_WEC);
                            }
                        }
                    }
                    // Set .length
                    HString* len_key = intern_string(vm, "length");
                    TVal len_val;
                    len_val.tag = FASTINT;
                    new_regs[rest_idx].tag = OBJECT;
                    new_regs[rest_idx].pointer = rest_obj;
                } else {
                    new_regs[rest_idx].tag = UNDEFINED;
                    new_regs[rest_idx].pointer = null;
                }
                for (uint i = copy_count + 1; i < new_nregs; i++) {
                    new_regs[i].tag = UNDEFINED;
                    new_regs[i].pointer = null;
                }
            } else {
                for (uint i = 0; i < nargs && i < new_nregs; i++) {
                    new_regs[i] = old_args[i];
                }
                for (uint i = nargs; i < new_nregs; i++) {
                    new_regs[i].tag = UNDEFINED;
                    new_regs[i].pointer = null;
                }
            }

            vm.valstack_top = (TVal*)((usz)new_regs + (usz)new_nregs * (usz)TVal::size);
            vm.valstack_bottom = new_act.bottom_byteoff;

            needs_restart = true;
            break;
        }

        case Opcode.NEWTARGET: {
            // A = new.target
            HObject* nt = act.new_target;
            if (nt != null) {
                ra.tag = OBJECT;
                ra.pointer = nt;
            } else {
                ra.tag = UNDEFINED;
                ra.pointer = null;
            }
            break;
        }

        case Opcode.NEW_OBJ: {
            // Compiler convention: A=result_reg, B=callee_reg, C=nargs
            uint result_reg = insn.a;
            uint callee_reg = insn.b;
            uint nargs = insn.c;

            TVal* func_slot = regs_base + callee_reg;
            TVal func_val = *func_slot;

            // Handle lightfunc built-in constructors (Error, TypeError, etc.)
            if (func_val.tag == LIGHTFUNC) {
                uint fn_idx = (uint)func_val.fastint;
                builtins::BuiltinContext ctx;
                ctx.vm = vm;
                ctx.regs = vm.valstack;
                ctx.base_reg = (ushort)((act.bottom_byteoff / (uint)TVal::size) + callee_reg + 2);
                ctx.argc = (ushort)nargs;
                ctx.result = regs_base + result_reg;
                ctx.heap = vm.heap;
                ctx.this_val = regs_base[callee_reg + 1];
                ctx.is_constructor = true;
                ctx.needs_re_dispatch = false;
                ctx.re_nargs = 0;
                ctx.global_env = vm.global_env;
                ctx.should_throw = false;
                builtins::dispatch_builtin(fn_idx, &ctx);
                if (ctx.should_throw) {
                    if (!vm_throw_value(vm, ctx.throw_value, act, &curr_pc, &needs_restart)) {
                        return VM_ERROR~;
                    }
                    break;
                }
                break;
            }

            if (func_val.tag != OBJECT) {
                // TypeError: value is not a constructor
                HString* type_str = typeof_string(vm, &func_val);
                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = vm.heap.type_err_proto;
                    char[160] buf;
                    int len = libc::snprintf(&buf, 160, "%s is not a constructor",
                                             type_str.get_cstr());
                    if (len > 0 && len < 160) {
                        HString* msg_str = intern_string(vm, buf[:len]);
                        TVal msg_val;
                        msg_val.tag = STRING;
                        msg_val.pointer = msg_str;
                        HString* msg_key = intern_string(vm, "message");
                        err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                    }
                    TVal err_val;
                    err_val.tag = OBJECT;
                    err_val.pointer = err;
                    if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                        return VM_ERROR~;
                    }
                } else {
                    return VM_ERROR~;
                }
                break;
            }

            HObject* hobj = (HObject*)func_val.pointer;
            if (hobj == null || !hobj.is_callable()) {
                // TypeError: object is not a constructor
                HString* type_str = typeof_string(vm, &func_val);
                HObject*? err_raw2 = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err2 = err_raw2) {
                    err2.prototype = vm.heap.type_err_proto;
                    char[160] buf;
                    int len = libc::snprintf(&buf, 160, "%s is not a constructor",
                                             type_str.get_cstr());
                    if (len > 0 && len < 160) {
                        HString* msg_str = intern_string(vm, buf[:len]);
                        TVal msg_val;
                        msg_val.tag = STRING;
                        msg_val.pointer = msg_str;
                        HString* msg_key = intern_string(vm, "message");
                        err2.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                    }
                    TVal err_val2;
                    err_val2.tag = OBJECT;
                    err_val2.pointer = err2;
                    if (!vm_throw_value(vm, err_val2, act, &curr_pc, &needs_restart)) {
                        return VM_ERROR~;
                    }
                } else {
                    return VM_ERROR~;
                }
                break;
            }

            // Handle builtin function objects (e.g., Number as OBJECT tag)
            if (hobj.comp_func == null) {
                if (hobj.builtin_fn_index >= 0) {
                    uint fn_idx = (uint)hobj.builtin_fn_index;
                    builtins::BuiltinContext ctx;
                    ctx.vm = vm;
                    ctx.regs = vm.valstack;
                    ctx.base_reg = (ushort)((act.bottom_byteoff / (uint)TVal::size) + callee_reg + 2);
                    ctx.argc = (ushort)nargs;
                    ctx.result = regs_base + result_reg;
                    ctx.heap = vm.heap;
                    ctx.this_val = regs_base[callee_reg + 1];
                    ctx.is_constructor = true;
                    ctx.needs_re_dispatch = false;
                    ctx.re_nargs = 0;
                    ctx.global_env = vm.global_env;
                    ctx.should_throw = false;
                    builtins::dispatch_builtin(fn_idx, &ctx);
                    if (ctx.should_throw) {
                        if (!vm_throw_value(vm, ctx.throw_value, act, &curr_pc, &needs_restart)) {
                            return VM_ERROR~;
                        }
                        break;
                    }
                    break;
                }
                // Object claims to be callable but has no compiled function
                // and no builtin index — treat as non-constructor
                HString* type_str = typeof_string(vm, &func_val);
                HObject*? err_raw2 = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err2 = err_raw2) {
                    err2.prototype = vm.heap.type_err_proto;
                    char[160] buf;
                    int len = libc::snprintf(&buf, 160, "%s is not a constructor",
                                             type_str.get_cstr());
                    if (len > 0 && len < 160) {
                        HString* msg_str = intern_string(vm, buf[:len]);
                        TVal msg_val;
                        msg_val.tag = STRING;
                        msg_val.pointer = msg_str;
                        HString* msg_key = intern_string(vm, "message");
                        err2.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                    }
                    TVal err_val2;
                    err_val2.tag = OBJECT;
                    err_val2.pointer = err2;
                    if (!vm_throw_value(vm, err_val2, act, &curr_pc, &needs_restart)) {
                        return VM_ERROR~;
                    }
                } else {
                    return VM_ERROR~;
                }
                break;
            }

            CompiledFunction* target = hobj.comp_func;

            // Arrow functions cannot be used as constructors (ES6 §14.2.2)
            if (target.is_arrow()) {
                HString* type_str = typeof_string(vm, &func_val);
                HObject*? err_raw3 = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err3 = err_raw3) {
                    err3.prototype = vm.heap.type_err_proto;
                    char[160] buf;
                    int len = libc::snprintf(&buf, 160, "%s is not a constructor",
                                             type_str.get_cstr());
                    if (len > 0 && len < 160) {
                        HString* msg_str = intern_string(vm, buf[:len]);
                        TVal msg_val;
                        msg_val.tag = STRING;
                        msg_val.pointer = msg_str;
                        HString* msg_key = intern_string(vm, "message");
                        err3.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                    }
                    TVal err_val3;
                    err_val3.tag = OBJECT;
                    err_val3.pointer = err3;
                    if (!vm_throw_value(vm, err_val3, act, &curr_pc, &needs_restart)) {
                        return VM_ERROR~;
                    }
                } else {
                    return VM_ERROR~;
                }
                break;
            }

            // Step 1: Create new object
            HObject*? new_obj_raw = vm.heap.alloc_object(hobject::ObjClass.OBJECT);
            if (catch err = new_obj_raw) {
                regs_base[result_reg].tag = UNDEFINED;
                regs_base[result_reg].pointer = null;
                break;
            }
            HObject* new_obj = new_obj_raw;

            // Step 2: Set prototype from constructor.prototype
            HString* proto_key = intern_string(vm, "prototype");
            TVal? proto_val = hobj.get_prop_proto(proto_key);
            if (try pv = proto_val) {
                if (pv.tag == OBJECT && pv.pointer != null) {
                    new_obj.prototype = (HObject*)pv.pointer;
                }
            }

            // Step 3: Place new object in this-slot
            TVal this_tval;
            this_tval.tag = OBJECT;
            this_tval.pointer = new_obj;
            regs_base[callee_reg + 1] = this_tval;
            uint frame_start = callee_reg + 2;
            uint new_bottom_idx = (act.bottom_byteoff / TVal::size) + frame_start;
            uint needed = new_bottom_idx + target.num_regs;

            if (!ensure_valstack(vm, needed)) {
                regs_base[result_reg].tag = UNDEFINED;
                regs_base[result_reg].pointer = null;
                break;
            }

            regs_base = ptr_from_byteoff(vm.valstack, act.bottom_byteoff);
            func_slot = regs_base + callee_reg;

            if (vm.activation_count >= MAX_CALLS) {
                regs_base[result_reg].tag = UNDEFINED;
                regs_base[result_reg].pointer = null;
                break;
            }

            Activation* new_act = &vm.activations[vm.activation_count];
            vm.activation_count++;

            new_act.parent = act;
            new_act.func = target;
            new_act.var_env = hobj.var_env;
            new_act.lex_env = hobj.lex_env;
            new_act.cat = null;
            new_act.curr_pc = target.code;
            new_act.bottom_byteoff = new_bottom_idx * (uint)TVal::size;
            new_act.retval_byteoff = act.bottom_byteoff + result_reg * (uint)TVal::size;
            new_act.reserve_byteoff = byte_offset(vm.valstack, vm.valstack_end);
            new_act.flags = ACT_FLAG_CONSTRUCT | ACT_FLAG_STRICT;
            new_act.this_binding = this_tval;
            new_act.new_target = hobj;  // constructor function, not instance

            TVal* new_regs2 = ptr_from_byteoff(vm.valstack, new_act.bottom_byteoff);
            uint new_nregs2 = target.num_regs;

            // Copy args
            TVal* old_args2 = regs_base + callee_reg + 2;
            if (target.has_rest()) {
                uint copy_count = (uint)target.num_formals;
                for (uint i = 0; i < nargs && i < copy_count; i++) {
                    new_regs2[i] = old_args2[i];
                }

                uint rest_idx = copy_count;
                uint overflow = (nargs > copy_count) ? (nargs - copy_count) : 0;

                HObject*? arr2_raw = vm.heap.alloc_object(hobject::ObjClass.ARRAY);
                if (try a2 = arr2_raw) {
                    a2.prototype = vm.heap.array_proto;
                    for (uint i = 0; i < overflow; i++) {
                        char[16] ibuf2;
                        int ilen2 = libc::snprintf(&ibuf2, 16, "%u", i);
                        if (ilen2 > 0 && ilen2 < 16) {
                            HString* key2 = intern_string(vm, ibuf2[:ilen2]);
                            if (key2 != null) {
                                TVal elem2 = old_args2[copy_count + i];
                                a2.put_prop(key2, elem2, hobject::PROP_FLAGS_WEC);
                            }
                        }
                    }
                    HString* len_str2 = intern_string(vm, "length");
                    TVal len_val2;
                    len_val2.tag = FASTINT;
                    len_val2.fastint = (long)overflow;
                    a2.put_prop(len_str2, len_val2, hobject::PROP_FLAGS_WEC);

                    new_regs2[rest_idx].tag = OBJECT;
                    new_regs2[rest_idx].pointer = a2;
                } else {
                    new_regs2[rest_idx].tag = UNDEFINED;
                    new_regs2[rest_idx].pointer = null;
                }

                for (uint i = rest_idx + 1; i < new_nregs2; i++) {
                    new_regs2[i].tag = UNDEFINED;
                    new_regs2[i].pointer = null;
                }
            } else {
                for (uint i = 0; i < nargs && i < (uint)target.num_args; i++) {
                    new_regs2[i] = old_args2[i];
                }
                for (uint i = nargs; i < new_nregs2; i++) {
                    new_regs2[i].tag = UNDEFINED;
                    new_regs2[i].pointer = null;
                }
            }

            vm.valstack_top = (TVal*)((usz)new_regs2 + (usz)new_nregs2 * (usz)TVal::size);
            vm.valstack_bottom = new_act.bottom_byteoff;

            needs_restart = true;
            break;
        }

        case Opcode.TAILCALL:
            break;

        // === GENERATORS ===

        case Opcode.LOAD_RESUME: {
            // LOAD_RESUME A — load the value passed to .next(val) into A.
            // Emitted after YIELD so the yield expression evaluates to the
            // resume value. Also handles throw/return injection: for THROW,
            // call vm_throw_value to find the nearest catcher; for RETURN,
            // mark the generator complete and return to the caller.
            if (vm.heap.resume_gen != null) {
                GeneratorState* gs_lr = vm.heap.resume_gen;
                ResumeKind rk = gs_lr.resume_kind;

                if (rk == THROW) {
                    // Inject exception: find the nearest catcher in the generator
                    TVal throw_val = gs_lr.throw_value;
                    vm.heap.resume_gen = null;

                    if (!vm_throw_value(vm, throw_val, act, &curr_pc, &needs_restart)) {
                        // No catcher in generator — pop activation and
                        // propagate error to the caller's catcher chain.
                        gs_lr.state = GEN_COMPLETED;

                        if (vm.activation_count > 0) {
                            vm.activation_count--;
                            if (vm.activation_count > 0) {
                                Activation* caller_act = &vm.activations[vm.activation_count - 1];
                                vm.valstack_bottom = caller_act.bottom_byteoff;
                                uint caller_bottom_idx = caller_act.bottom_byteoff / TVal::size;
                                if (caller_act.func != null) {
                                    CompiledFunction* caller_func = (CompiledFunction*)caller_act.func;
                                    vm.valstack_top = (TVal*)((usz)vm.valstack
                                        + (usz)(caller_bottom_idx + caller_func.num_regs) * TVal::size);
                                }

                                // Try to find a catcher in the caller's chain
                                if (!vm_throw_value(vm, throw_val, caller_act,
                                                    &caller_act.curr_pc, &needs_restart)) {
                                    // Unhandled — set error for the VM to return
                                    vm.has_error = true;
                                    TVal* ret_slot = ptr_from_byteoff(vm.valstack,
                                        caller_act.retval_byteoff);
                                    ret_slot[0] = throw_val;
                                }
                            }
                        }
                    }
                    needs_restart = true;
                    break;
                }

                if (rk == RETURN) {
                    // Inject return: mark generator complete, return to caller
                    TVal ret_val = gs_lr.return_value;
                    gs_lr.state = GEN_COMPLETED;
                    gs_lr.resume_kind = NEXT;
                    vm.heap.resume_gen = null;

                    // Pop the generator activation
                    if (vm.activation_count > 0) {
                        Activation* gen_act = &vm.activations[vm.activation_count - 1];
                        uint ret_byteoff = gen_act.retval_byteoff;
                        vm.activation_count--;
                        if (vm.activation_count > 0) {
                            Activation* caller_act = &vm.activations[vm.activation_count - 1];
                            vm.valstack_bottom = caller_act.bottom_byteoff;
                            uint caller_bottom_idx = caller_act.bottom_byteoff / TVal::size;
                            if (caller_act.func != null) {
                                CompiledFunction* caller_func = (CompiledFunction*)caller_act.func;
                                vm.valstack_top = (TVal*)((usz)vm.valstack
                                    + (usz)(caller_bottom_idx + caller_func.num_regs) * TVal::size);
                            }

                            // Write return value to caller's return slot
                            TVal* ret_slot = ptr_from_byteoff(vm.valstack, caller_act.retval_byteoff);
                            ret_slot[0] = ret_val;
                        }
                    }
                    needs_restart = true;
                    break;
                }

                // Normal NEXT — load resume value
                ra[0] = gs_lr.resume_value;
            } else {
                ra[0].set_undefined();
            }
            break;
        }

        case Opcode.YIELD: {
            // YIELD A — suspend generator and return {value: A, done: false}
            // heap.resume_gen was set by the .next()/.throw()/.return() builtin
            if (vm.heap.resume_gen != null) {
                GeneratorState* gs = vm.heap.resume_gen;

                // Save current state
                TVal* regs_base_r = ptr_from_byteoff(vm.valstack, act.bottom_byteoff);
                for (uint i = 0; i < gs.num_regs; i++) {
                    gs.saved_regs[i] = regs_base_r[i];
                }
                gs.saved_pc = curr_pc;  // curr_pc already points past YIELD
                gs.var_env = act.var_env;
                gs.lex_env = act.lex_env;
                gs.this_binding = act.this_binding;
                gs.state = GEN_SUSPENDED_YIELD;

                // Store the yielded value
                vm.heap.yield_value = ra[0];

                // Check resume kind for throw/return injection
                ResumeKind rkind = gs.resume_kind;

                if (rkind == THROW) {
                    // .throw() — inject exception at yield point
                    // Pop activation, set has_error so the outer loop
                    // re-enters the generator with an exception pending
                    vm.heap.resume_gen = null;
                    vm.heap.did_yield = true;

                    if (vm.activation_count > 0) {
                        Activation* yield_act = &vm.activations[vm.activation_count - 1];
                        uint ret_byteoff = yield_act.retval_byteoff;

                        // Write the exception as the result (will be caught by try/catch inside generator)
                        TVal* ret_slot = ptr_from_byteoff(vm.valstack, ret_byteoff);
                        ret_slot[0] = gs.throw_value;

                        vm.activation_count--;
                        if (vm.activation_count > 0) {
                            Activation* caller_act2 = &vm.activations[vm.activation_count - 1];
                            vm.valstack_bottom = caller_act2.bottom_byteoff;
                            uint caller_bottom_idx2 = caller_act2.bottom_byteoff / TVal::size;
                            if (caller_act2.func != null) {
                                CompiledFunction* caller_func2 = (CompiledFunction*)caller_act2.func;
                                vm.valstack_top = (TVal*)((usz)vm.valstack
                                    + (usz)(caller_bottom_idx2 + caller_func2.num_regs) * TVal::size);
                            }
                        }
                    }
                    needs_restart = true;
                    break;
                }

                if (rkind == RETURN) {
                    // .return() — inject return at yield point
                    // Mark generator as completed, return {value: rv, done: true}
                    gs.state = GEN_COMPLETED;
                    vm.heap.resume_gen = null;
                    vm.heap.did_yield = false;

                    HObject*? robj_raw = vm.heap.alloc_object(hobject::ObjClass.OBJECT);
                    TVal wrapped_val;
                    if (try robj = robj_raw) {
                        robj.prototype = vm.heap.object_proto;
                        HString* val_key = intern_string(vm, "value");
                        if (val_key != null) robj.put_prop(val_key, gs.return_value, hobject::PROP_FLAGS_WEC);
                        HString* done_key = intern_string(vm, "done");
                        TVal done_val;
                        done_val.tag = BOOLEAN;
                        done_val.boolean = true;
                        if (done_key != null) robj.put_prop(done_key, done_val, hobject::PROP_FLAGS_WEC);
                        wrapped_val.tag = OBJECT;
                        wrapped_val.pointer = robj;
                    } else {
                        wrapped_val = gs.return_value;
                    }

                    if (vm.activation_count > 0) {
                        Activation* yield_act = &vm.activations[vm.activation_count - 1];
                        uint ret_byteoff = yield_act.retval_byteoff;
                        TVal* ret_slot = ptr_from_byteoff(vm.valstack, ret_byteoff);
                        ret_slot[0] = wrapped_val;

                        vm.activation_count--;
                        if (vm.activation_count > 0) {
                            Activation* caller_act2 = &vm.activations[vm.activation_count - 1];
                            vm.valstack_bottom = caller_act2.bottom_byteoff;
                            uint caller_bottom_idx2 = caller_act2.bottom_byteoff / TVal::size;
                            if (caller_act2.func != null) {
                                CompiledFunction* caller_func2 = (CompiledFunction*)caller_act2.func;
                                vm.valstack_top = (TVal*)((usz)vm.valstack
                                    + (usz)(caller_bottom_idx2 + caller_func2.num_regs) * TVal::size);
                            }
                        }
                    }
                    needs_restart = true;
                    break;
                }

                // Normal .next() — clear resume_gen so CALL handler doesn't try to resume again
                vm.heap.resume_gen = null;
            }

            vm.heap.did_yield = true;

            // Pop activation and return to caller (the .next() builtin's context)
            if (vm.activation_count > 0) {
                Activation* yield_act = &vm.activations[vm.activation_count - 1];
                uint ret_byteoff = yield_act.retval_byteoff;

                // Create IteratorResult {value: yieldVal, done: false}
                HObject*? result_obj_raw = vm.heap.alloc_object(hobject::ObjClass.OBJECT);
                TVal wrapped_val;
                if (try robj = result_obj_raw) {
                    robj.prototype = vm.heap.object_proto;
                    HString* val_key = intern_string(vm, "value");
                    if (val_key != null) robj.put_prop(val_key, vm.heap.yield_value, hobject::PROP_FLAGS_WEC);
                    HString* done_key = intern_string(vm, "done");
                    TVal done_val;
                    done_val.tag = BOOLEAN;
                    done_val.boolean = false;
                    if (done_key != null) robj.put_prop(done_key, done_val, hobject::PROP_FLAGS_WEC);
                    wrapped_val.tag = OBJECT;
                    wrapped_val.pointer = robj;
                } else {
                    wrapped_val = vm.heap.yield_value;
                }

                // Write wrapped result to caller's frame
                TVal* ret_slot = ptr_from_byteoff(vm.valstack, ret_byteoff);
                ret_slot[0] = wrapped_val;

                vm.activation_count--;
                if (vm.activation_count > 0) {
                    Activation* caller_act2 = &vm.activations[vm.activation_count - 1];
                    vm.valstack_bottom = caller_act2.bottom_byteoff;
                    uint caller_bottom_idx2 = caller_act2.bottom_byteoff / TVal::size;
                    if (caller_act2.func != null) {
                        CompiledFunction* caller_func2 = (CompiledFunction*)caller_act2.func;
                        vm.valstack_top = (TVal*)((usz)vm.valstack
                            + (usz)(caller_bottom_idx2 + caller_func2.num_regs) * TVal::size);
                    }
                }
            }
            needs_restart = true;
            break;
        }

        case Opcode.YIELD_STAR: {
            // yield* iterable — this opcode should NOT be reached in normal
            // execution. The compiler transforms yield* into a loop of
            // GETIDX + YIELD instructions. If we get here, just set undefined.
            ra[0].set_undefined();
            break;
        }

        // === RETURNS ===

        case Opcode.RET:
            // If we're in a generator, mark as completed
            if (vm.heap.resume_gen != null) {
                GeneratorState* gs = vm.heap.resume_gen;
                gs.state = GEN_COMPLETED;
                vm.heap.yield_value = ra[0];
                vm.heap.did_yield = false;  // completed, not yielded
                vm.heap.resume_gen = null;

                // Wrap in IteratorResult {value: returnVal, done: true}
                HObject*? robj_raw = vm.heap.alloc_object(hobject::ObjClass.OBJECT);
                TVal wrapped_val;
                if (try robj = robj_raw) {
                    robj.prototype = vm.heap.object_proto;
                    HString* val_key = intern_string(vm, "value");
                    if (val_key != null) robj.put_prop(val_key, ra[0], hobject::PROP_FLAGS_WEC);
                    HString* done_key = intern_string(vm, "done");
                    TVal done_val;
                    done_val.tag = BOOLEAN;
                    done_val.boolean = true;
                    if (done_key != null) robj.put_prop(done_key, done_val, hobject::PROP_FLAGS_WEC);
                    wrapped_val.tag = OBJECT;
                    wrapped_val.pointer = robj;
                } else {
                    wrapped_val = ra[0];
                }

                // Write wrapped result to caller's frame
                Activation* ret_act = &vm.activations[vm.activation_count - 1];
                uint ret_byteoff = ret_act.retval_byteoff;
                TVal* ret_slot = ptr_from_byteoff(vm.valstack, ret_byteoff);
                ret_slot[0] = wrapped_val;

                vm.activation_count--;
                if (vm.activation_count > 0) {
                    Activation* caller_act3 = &vm.activations[vm.activation_count - 1];
                    vm.valstack_bottom = caller_act3.bottom_byteoff;
                    uint caller_bottom_idx3 = caller_act3.bottom_byteoff / TVal::size;
                    if (caller_act3.func != null) {
                        CompiledFunction* caller_func3 = (CompiledFunction*)caller_act3.func;
                        vm.valstack_top = (TVal*)((usz)vm.valstack
                            + (usz)(caller_bottom_idx3 + caller_func3.num_regs) * TVal::size);
                    }
                }
                needs_restart = true;
                break;
            }
            handle_return(vm, *ra);
            if (vm.activation_count == 0) {
                return vm.return_val;
            }
            needs_restart = true;
            break;

        case Opcode.RETUNDEF: {
            TVal undef_val;
            undef_val.tag = UNDEFINED;
            undef_val.pointer = null;

            // If we're in a generator, mark as completed
            if (vm.heap.resume_gen != null) {
                GeneratorState* gs2 = vm.heap.resume_gen;
                gs2.state = GEN_COMPLETED;
                vm.heap.yield_value = undef_val;
                vm.heap.did_yield = false;  // completed, not yielded
                vm.heap.resume_gen = null;

                Activation* ret_act2 = &vm.activations[vm.activation_count - 1];
                uint ret_byteoff2 = ret_act2.retval_byteoff;
                TVal* ret_slot2 = ptr_from_byteoff(vm.valstack, ret_byteoff2);
                ret_slot2[0] = undef_val;

                vm.activation_count--;
                if (vm.activation_count > 0) {
                    Activation* caller_act4 = &vm.activations[vm.activation_count - 1];
                    vm.valstack_bottom = caller_act4.bottom_byteoff;
                    uint caller_bottom_idx4 = caller_act4.bottom_byteoff / TVal::size;
                    if (caller_act4.func != null) {
                        CompiledFunction* caller_func4 = (CompiledFunction*)caller_act4.func;
                        vm.valstack_top = (TVal*)((usz)vm.valstack
                            + (usz)(caller_bottom_idx4 + caller_func4.num_regs) * TVal::size);
                    }
                }
                needs_restart = true;
                break;
            }

            handle_return(vm, undef_val);
            if (vm.activation_count == 0) {
                return vm.return_val;
            }
            needs_restart = true;
            break;
        }

        // === VARIABLE ACCESS ===

        case Opcode.GETVAR: {
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                TVal name_val = constants[bc];
                if (name_val.tag == STRING) {
                    void* key = name_val.pointer;

                    // Search lexical environment first (for let/const bindings)
                    TVal? result = env::env_get_lex(act.lex_env, key);
                    if (try v = result) {
                        // Check for TDZ sentinel
                        if (env::is_tdz_sentinel(&v)) {
                            HString* name_hstr = (HString*)key;
                            HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                            if (try err = err_raw) {
                                err.prototype = vm.heap.ref_err_proto;
                                char[160] buf;
                                int len = libc::snprintf(&buf, 160, "Cannot access '%s' before initialization",
                                                         name_hstr.get_cstr());
                                if (len > 0 && len < 160) {
                                    HString* msg_str = intern_string(vm, buf[:len]);
                                    TVal msg_val;
                                    msg_val.tag = STRING;
                                    msg_val.pointer = msg_str;
                                    HString* msg_key = intern_string(vm, "message");
                                    err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                                }
                                TVal err_val;
                                err_val.tag = OBJECT;
                                err_val.pointer = err;
                                if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                                    return VM_ERROR~;
                                }
                            } else {
                                return VM_ERROR~;
                            }
                        } else {
                            *ra = v;
                        }
                    } else {
                        // Not in lex_env — search var_env
                        result = env::env_get(act.var_env, key);
                        if (try v2 = result) {
                            *ra = v2;
                        } else {
                            // ReferenceError: variable not declared
                            HString* name_hstr = (HString*)key;
                            HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                            if (try err = err_raw) {
                                err.prototype = vm.heap.ref_err_proto;
                                char[160] buf;
                                int len = libc::snprintf(&buf, 160, "%s is not defined",
                                                         name_hstr.get_cstr());
                                if (len > 0 && len < 160) {
                                    HString* msg_str = intern_string(vm, buf[:len]);
                                    TVal msg_val;
                                    msg_val.tag = STRING;
                                    msg_val.pointer = msg_str;
                                    HString* msg_key = intern_string(vm, "message");
                                    err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                                }
                                TVal err_val;
                                err_val.tag = OBJECT;
                                err_val.pointer = err;
                                if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                                    return VM_ERROR~;
                                }
                            } else {
                                return VM_ERROR~;
                            }
                        }
                    }
                } else {
                    ra.tag = UNDEFINED;
                    ra.pointer = null;
                }
            } else {
                ra.tag = UNDEFINED;
                ra.pointer = null;
            }
            break;
        }

        case Opcode.TYPEOFIDENT: {
            // ES5 §11.4.3: typeof on an unresolvable reference returns "undefined"
            // instead of throwing ReferenceError.
            // ES6: typeof on a TDZ variable THROWS ReferenceError.
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                TVal name_val = constants[bc];
                if (name_val.tag == STRING) {
                    void* key = name_val.pointer;

                    // Search lexical environment first (for let/const bindings)
                    TVal? result = env::env_get_lex(act.lex_env, key);
                    if (try v = result) {
                        // Check for TDZ sentinel
                        if (env::is_tdz_sentinel(&v)) {
                            // TDZ: throw ReferenceError (ES6 behavior)
                            HString* name_hstr = (HString*)key;
                            HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                            if (try err = err_raw) {
                                err.prototype = vm.heap.ref_err_proto;
                                char[160] buf;
                                int len = libc::snprintf(&buf, 160, "Cannot access '%s' before initialization",
                                                         name_hstr.get_cstr());
                                if (len > 0 && len < 160) {
                                    HString* msg_str = intern_string(vm, buf[:len]);
                                    TVal msg_val;
                                    msg_val.tag = STRING;
                                    msg_val.pointer = msg_str;
                                    HString* msg_key = intern_string(vm, "message");
                                    err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                                }
                                TVal err_val;
                                err_val.tag = OBJECT;
                                err_val.pointer = err;
                                if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                                    return VM_ERROR~;
                                }
                            } else {
                                return VM_ERROR~;
                            }
                        } else {
                            HString* ts = typeof_string(vm, &v);
                            ra.tag = STRING;
                            ra.pointer = ts;
                        }
                    } else {
                        // Not in lex_env — search var_env
                        result = env::env_get(act.var_env, key);
                        if (try v2 = result) {
                            HString* ts = typeof_string(vm, &v2);
                            ra.tag = STRING;
                            ra.pointer = ts;
                        } else {
                            // Unresolvable reference → "undefined" (no error)
                            HString* ts = intern_string(vm, "undefined");
                            ra.tag = STRING;
                            ra.pointer = ts;
                        }
                    }
                } else {
                    ra.tag = UNDEFINED;
                    ra.pointer = null;
                }
            } else {
                ra.tag = UNDEFINED;
                ra.pointer = null;
            }
            break;
        }

        case Opcode.PUTVAR: {
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                TVal name_val = constants[bc];
                if (name_val.tag == STRING) {
                    void* key = name_val.pointer;
                    // Check lex_env first — if the binding is a let/const,
                    // we need to update it in the lexical environment, not
                    // create a new var_env binding.
                    if (env::env_has_lex(act.lex_env, key)) {
                        // Enforce const: check writability of existing binding
                        if (!env::env_is_lex_writable(act.lex_env, key)) {
                            HString* name_hstr = (HString*)key;
                            HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                            if (try err = err_raw) {
                                err.prototype = vm.heap.type_err_proto;
                                char[160] buf;
                                int len = libc::snprintf(&buf, 160, "Assignment to constant variable '%s'",
                                                         name_hstr.get_cstr());
                                if (len > 0 && len < 160) {
                                    HString* msg_str = intern_string(vm, buf[:len]);
                                    TVal msg_val;
                                    msg_val.tag = STRING;
                                    msg_val.pointer = msg_str;
                                    HString* msg_key = intern_string(vm, "message");
                                    err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                                }
                                TVal err_val;
                                err_val.tag = OBJECT;
                                err_val.pointer = err;
                                if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                                    return VM_ERROR~;
                                }
                            } else {
                                return VM_ERROR~;
                            }
                            break;
                        }
                        env::env_put_lex(act.lex_env, key, *ra);
                    } else {
                        env::env_put(act.var_env, key, *ra);
                    }
                }
            }
            break;
        }

        case Opcode.PUTLEX: {
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                TVal name_val = constants[bc];
                if (name_val.tag == STRING) {
                    void* key = name_val.pointer;
                    env::env_declare_lex(act.lex_env, key, *ra);
                }
            }
            break;
        }

        case Opcode.PUTLEX_C: {
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                TVal name_val = constants[bc];
                if (name_val.tag == STRING) {
                    void* key = name_val.pointer;
                    act.lex_env.bindings.put_prop(key, *ra, hobject::PROP_FLAGS_EC);
                }
            }
            break;
        }

        case Opcode.INITTZ: {
            // Store the TDZ sentinel for a variable name in the current
            // lexical environment.  This marks the binding as uninitialized
            // so that GETVAR throws a ReferenceError (temporal dead zone)
            // if the variable is accessed before its PUTLEX/PUTLEX_C.
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                TVal name_val = constants[bc];
                if (name_val.tag == STRING) {
                    void* key = name_val.pointer;
                    TVal tdz = env::tdz_sentinel();
                    act.lex_env.bindings.put_prop(key, tdz, hobject::PROP_FLAGS_WEC);
                }
            }
            break;
        }

        case Opcode.DELVAR:
            ra.tag = BOOLEAN;
            ra.boolean = true;
            break;

        // === CLOSURES ===

        case Opcode.CLOSURE: {
            uint bc = insn.get_bc();
            if (bc < vm.current_func.inner_count) {
                CompiledFunction* template = vm.current_func.inner_funcs[bc];

                HObject*? func_obj_raw = vm.heap.alloc_object(hobject::ObjClass.FUNCTION);
                if (try func_obj = func_obj_raw) {
                    func_obj.prototype = vm.heap.function_proto;
                    func_obj.flags.callable = true;
                    func_obj.flags.constructable = template.is_constructable();
                    func_obj.comp_func = template;
                    func_obj.var_env = act.var_env;
                    func_obj.lex_env = act.lex_env;

                    // Set .length property (ES5 §15.3.5.1)
                    HString* len_key = intern_string(vm, "length");
                    TVal len_val;
                    len_val.tag = FASTINT;
                    len_val.fastint = (long)template.num_formals;
                    func_obj.put_prop(len_key, len_val, hobject::PROP_FLAGS_WEC);

                    // Arrow functions don't get a .prototype property (ES6 §14.2.16)
                    if (!template.is_arrow()) {
                        // ES5 §13.2: create .prototype property (plain object with .constructor)
                        HObject*? proto_obj_raw = vm.heap.alloc_object(hobject::ObjClass.OBJECT);
                        if (try proto_obj = proto_obj_raw) {
                            proto_obj.prototype = vm.heap.object_proto;
                            // Set .constructor on the prototype object
                            HString* constr_key = intern_string(vm, "constructor");
                            TVal constr_val;
                            constr_val.tag = OBJECT;
                            constr_val.pointer = func_obj;
                            proto_obj.put_prop(constr_key, constr_val, hobject::PROP_FLAGS_WEC);
                            // Set .prototype on the function
                            HString* proto_key = intern_string(vm, "prototype");
                            TVal proto_tv;
                            proto_tv.tag = OBJECT;
                            proto_tv.pointer = proto_obj;
                            func_obj.put_prop(proto_key, proto_tv, hobject::PROP_FLAGS_WEC);
                        }
                    }

                    ra.tag = OBJECT;
                    ra.pointer = func_obj;
                } else {
                    ra.tag = UNDEFINED;
                    ra.pointer = null;
                }
            } else {
                ra.tag = UNDEFINED;
                ra.pointer = null;
            }
            break;
        }

        case Opcode.GETBOUND:
            ra.tag = UNDEFINED;
            ra.pointer = null;
            break;

        // === ITEraTOR ===

        case Opcode.INITFOR: {
            // ra = object to enumerate, rb = iter_state (output)
            // null/undefined → skip loop (rb = null marker)
            if (ra.tag == NULL_VAL || ra.tag == UNDEFINED) {
                rb.set_null();
                break;
            }

            // Get the object (ToObject for primitives)
            HObject* obj;
            if (ra.tag == OBJECT) {
                obj = (HObject*)ra.pointer;
            } else if (ra.tag == BOOLEAN) {
                HObject*? wrapped = vm.heap.alloc_object(hobject::ObjClass.BOOLEAN);
                if (catch _err = wrapped) { rb.set_null(); break; }
                obj = wrapped;
                obj.prototype = vm.heap.bool_proto;
                obj.primitive_value.tag = BOOLEAN;
                obj.primitive_value.boolean = ra.boolean;
            } else if (ra.tag == STRING) {
                HObject*? wrapped = vm.heap.alloc_object(hobject::ObjClass.STRING);
                if (catch _err = wrapped) { rb.set_null(); break; }
                obj = wrapped;
                obj.prototype = vm.heap.string_proto;
                obj.primitive_value.tag = STRING;
                obj.primitive_value.pointer = ra.pointer;
            } else if (ra.tag == NUMBER || ra.tag == FASTINT) {
                HObject*? wrapped = vm.heap.alloc_object(hobject::ObjClass.NUMBER);
                if (catch _err = wrapped) { rb.set_null(); break; }
                obj = wrapped;
                obj.prototype = vm.heap.number_proto;
                obj.primitive_value = *ra;
            } else {
                rb.set_null();
                break;
            }

            // Collect enumerable keys
            ForInState* state = collect_forin_keys(vm, obj);
            if (state == null) {
                rb.set_null();
                break;
            }
            rb.tag = POINTER;
            rb.pointer = state;
            break;
        }

        case Opcode.NEXTFOR: {
            // ra = iter_var (output key), rb = has_next (output bool)
            // rc = iter_state (input ForInState*)
            ForInState* state = (ForInState*)rc.pointer;
            if (state == null || state.index >= state.count) {
                // No more keys — clean up and signal done
                if (state != null) {
                    libc::free(state.keys);
                    libc::free(state);
                }
                rb.tag = BOOLEAN;
                rb.boolean = false;
                ra.set_undefined();
                break;
            }

            // Return the next key
            ra.tag = STRING;
            ra.pointer = state.keys[state.index];
            state.index++;
            rb.tag = BOOLEAN;
            rb.boolean = true;
            break;
        }

        // === EXCEPTION HANDLING ===

        case Opcode.TRY: {
            // Encoding: A = flags (bit0=catch, bit1=finally)
            //           BC = catch_offset (from TRY PC to CATCH instruction)
            // The next instruction word stores finally_offset in its BC field.
            uint flags = insn.a;
            uint catch_offset = insn.get_bc();

            // Read the jump slot (next instruction word) for finally_offset
            Instruction jump_slot = *curr_pc;
            curr_pc++;
            act.curr_pc = curr_pc;
            uint finally_offset = jump_slot.get_bc(); // BC field stores finally offset

            // Compute absolute handler PCs
            Instruction* base_pc = curr_pc - 2; // back to TRY instruction
            Instruction* catch_pc = base_pc + (int)catch_offset;
            Instruction* finally_pc = (finally_offset != 0)
                ? (base_pc + (int)finally_offset)
                : null;

            // Allocate catcher
            Catcher* cat = (Catcher*)libc::malloc(Catcher::size);
            if (cat == null) {
                // Out of memory — skip catcher creation, try block will run unprotected
                break;
            }
            cat.parent = (Catcher*)act.cat;
            cat.flags = flags;
            cat.thrown_val.tag = UNDEFINED;
            cat.thrown_val.pointer = null;
            cat.catch_pc = catch_pc;
            cat.finally_pc = finally_pc;

            act.cat = (void*)cat;
            break;
        }

        case Opcode.ENDTRY: {
            // Pop the catcher (normal exit from try block)
            Catcher* cat = (Catcher*)act.cat;
            if (cat != null) {
                act.cat = (void*)cat.parent;
                libc::free(cat);
            }
            break;
        }

        case Opcode.THROW: {
            TVal thrown_val = *ra;
            if (!vm_throw_value(vm, thrown_val, act, &curr_pc, &needs_restart)) {
                return VM_ERROR~;
            }
            break;
        }

        case Opcode.CATCH: {
            // Read the thrown exception from the nearest catcher
            Catcher* cat = (Catcher*)act.cat;
            if (cat != null) {
                *ra = cat.thrown_val;

                // Clear thrown value
                cat.thrown_val.tag = UNDEFINED;
                cat.thrown_val.pointer = null;

                // If no finally handler, pop the catcher now.
                // If there IS a finally, keep the catcher on the chain so that
                // re-throws in the catch block are handled by the finally handler.
                if (cat.finally_pc == null) {
                    act.cat = (void*)cat.parent;
                    libc::free(cat);
                }
            } else {
                ra.tag = UNDEFINED;
                ra.pointer = null;
            }
            break;
        }

        case Opcode.FINALLY:
            // No-op marker — the catcher's finally_pc points here.
            // When entered via normal fall-through (after catch or via jump),
            // there may or may not be a catcher on the chain.
            break;

        case Opcode.ENDFINALLY: {
            // Check if we entered the finally block via a pending exception.
            // Look for a catcher with FINALLY_ENABLED that has a pending thrown_val.
            Catcher* cat = (Catcher*)act.cat;
            if (cat != null && (cat.flags & CATCHER_FLAG_FINALLY_ENABLED) != 0) {
                bool has_pending = (cat.thrown_val.tag != UNDEFINED);
                TVal pending_val = cat.thrown_val;

                // Pop the finally catcher
                act.cat = (void*)cat.parent;
                libc::free(cat);

                if (has_pending) {
                    // Re-throw the pending exception
                    if (!vm_throw_value(vm, pending_val, act, &curr_pc, &needs_restart)) {
                        return VM_ERROR~;
                    }
                }
                // else: normal continuation, nothing to re-throw
            }
            // else: entered via normal flow (no catcher), nothing to do
            break;
        }

        // === MISC ===

        case Opcode.NOP:
            break;

        case Opcode.DEBUGGER:
            break;

        case Opcode.BREAK:
            break;

        case Opcode.CONTINUE:
            break;

        case Opcode.INITSET:
            break;

        case Opcode.INITGET:
            break;

        case Opcode.INITSETI:
            break;

        case Opcode.CSVARI:
            break;

        // === WITH STATEMENT ===

        case Opcode.WITH_START: {
            // Register A holds the with-object.  Call ToObject
            // (primitives are wrapped), then push a new env record onto
            // the current activation's var_env chain.
            TVal obj_val = *ra;
            HObject* obj;

            if (obj_val.tag == OBJECT) {
                obj = (HObject*)obj_val.pointer;
            } else if (obj_val.tag == NULL_VAL || obj_val.tag == UNDEFINED) {
                // TypeError: with cannot be applied to null/undefined
                HString* msg_key = intern_string(vm, "message");
                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = vm.heap.type_err_proto;
                    char[80] buf;
                    int len = libc::snprintf(&buf, 80,
                        "Cannot use 'with' on %s",
                        (obj_val.tag == NULL_VAL ? "null" : "undefined"));
                    if (len > 0 && len < 80) {
                        HString* msg_str = intern_string(vm, buf[:len]);
                        TVal msg_val;
                        msg_val.tag = STRING;
                        msg_val.pointer = msg_str;
                        err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                    }
                    TVal err_val;
                    err_val.tag = OBJECT;
                    err_val.pointer = err;
                    if (!vm_throw_value(vm, err_val, act, &curr_pc, &needs_restart)) {
                        return VM_ERROR~;
                    }
                } else {
                    return VM_ERROR~;
                }
                break;
            } else if (obj_val.tag == BOOLEAN) {
                HObject*? wrapped = vm.heap.alloc_object(hobject::ObjClass.BOOLEAN);
                if (catch _err = wrapped) { break; }
                obj = wrapped;
                obj.prototype = vm.heap.bool_proto;
                obj.primitive_value.tag = BOOLEAN;
                obj.primitive_value.boolean = obj_val.boolean;
            } else if (obj_val.tag == STRING) {
                HObject*? wrapped = vm.heap.alloc_object(hobject::ObjClass.STRING);
                if (catch _err = wrapped) { break; }
                obj = wrapped;
                obj.prototype = vm.heap.string_proto;
                obj.primitive_value.tag = STRING;
                obj.primitive_value.pointer = obj_val.pointer;
            } else if (obj_val.tag == NUMBER || obj_val.tag == FASTINT) {
                HObject*? wrapped = vm.heap.alloc_object(hobject::ObjClass.NUMBER);
                if (catch _err = wrapped) { break; }
                obj = wrapped;
                obj.prototype = vm.heap.number_proto;
                obj.primitive_value = obj_val;
            } else {
                // POINTER or BUFFER
                break;
            }

            // Create a with-env record wrapping the object and push it
            // onto the current activation's var_env.
            EnvRecord*? env_raw = env::env_create_with_object(act.var_env, obj);
            if (try new_env = env_raw) {
                act.var_env = new_env;
            } else {
                return VM_ERROR~;
            }
            break;
        }

        case Opcode.WITH_END: {
            // Pop the current with-env from the scope chain.
            // NOTE: we do NOT free the env record here because a closure
            // created inside the `with` block may have captured it via
            // func_obj.var_env = act.var_env (see CLOSURE opcode).
            // Freeing it would leave a dangling pointer in the closure
            // and crash on subsequent env_get calls.
            if (act.var_env != null && act.var_env.parent != null) {
                act.var_env = act.var_env.parent;
            }
            break;
        }

        case Opcode.PUSH_LEX: {
            // Push a new declarative environment record onto act.lex_env.
            EnvRecord*? env_raw = env::env_create_declarative(vm.heap, act.lex_env);
            if (try new_env = env_raw) {
                act.lex_env = new_env;
            } else {
                return VM_ERROR~;
            }
            break;
        }

        case Opcode.POP_LEX: {
            // Pop the current lexical environment from the scope chain.
            if (act.lex_env != null && act.lex_env.parent != null) {
                act.lex_env = act.lex_env.parent;
            }
            break;
        }

        default:
            io::eprintfn("Unknown opcode: %d", op.ordinal);
            return VM_ERROR~;
        }
    }
    }
    return vm.return_val;
}
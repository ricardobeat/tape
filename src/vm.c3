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

    // Object + String/Number -> ToPrimitive (TODO)
    // For now fall through to false
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
    bool is_strict = (callee_act.flags & ACT_FLAG_STRICT) != 0;

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
        // For construct calls: if return value is not an object, use new_target
        TVal final_val = val;
        if ((callee_act.flags & ACT_FLAG_CONSTRUCT) != 0) {
            if (final_val.tag != OBJECT || final_val.pointer == null) {
                if (callee_act.new_target != null) {
                    final_val.tag = OBJECT;
                    final_val.pointer = callee_act.new_target;
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
    env::env_destroy(vm.global_env);
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
            uint insn_raw = (uint)insn.op.ordinal;

            TVal* regs_base = ptr_from_byteoff(vm.valstack, act.bottom_byteoff);
            TVal* ra = regs_base + ((uint)insn.a);
            TVal* rb = regs_base + ((uint)insn.b);
            TVal* rc = regs_base + ((uint)insn.c);

        switch (op) {

        // === LOAD / STORE ===

        case Opcode.LDREG:
            ra.tag = rb.tag;
            ra.fastint = rb.fastint;
            ra.number = rb.number;
            ra.pointer = rb.pointer;
            break;

        case Opcode.LDCONST: {
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                ra.tag = constants[bc].tag;
                ra.fastint = constants[bc].fastint;
                ra.number = constants[bc].number;
                ra.pointer = constants[bc].pointer;
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
            ra.tag = act.this_binding.tag;
            ra.fastint = act.this_binding.fastint;
            ra.number = act.this_binding.number;
            ra.pointer = act.this_binding.pointer;
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
                if (sum >= -2251799813685248L && sum <= 2251799813685247L) {
                    ra.tag = FASTINT;
                    ra.fastint = sum;
                } else {
                    ra.tag = NUMBER;
                    ra.number = (double)sum;
                }
            } else {
                ra.tag = NUMBER;
                ra.number = num_val(rb) + num_val(rc);
            }
            break;

        case Opcode.SUB:
            ra.tag = NUMBER;
            ra.number = num_val(rb) - num_val(rc);
            break;

        case Opcode.MUL:
            ra.tag = NUMBER;
            ra.number = num_val(rb) * num_val(rc);
            break;

        case Opcode.DIV:
            ra.tag = NUMBER;
            ra.number = num_val(rb) / num_val(rc);
            break;

        case Opcode.MOD:
            ra.tag = NUMBER;
            ra.number = (num_val(rb) % num_val(rc));
            break;

        case Opcode.EXP:
            ra.tag = NUMBER;
            ra.number = math::pow(num_val(rb), num_val(rc));
            break;

        // === UNARY ===

        case Opcode.UNP:
            ra.tag = NUMBER;
            ra.number = num_val(rb);
            break;

        case Opcode.UNM:
            ra.tag = NUMBER;
            ra.number = -num_val(rb);
            break;

        case Opcode.BNOT:
            ra.tag = NUMBER;
            ra.number = (double)(~(int)num_val(rb));
            break;

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
            ra.tag = NUMBER;
            ra.number = (double)((int)num_val(rb) & (int)num_val(rc));
            break;

        case Opcode.BOR:
            ra.tag = NUMBER;
            ra.number = (double)((int)num_val(rb) | (int)num_val(rc));
            break;

        case Opcode.BXOR:
            ra.tag = NUMBER;
            ra.number = (double)((int)num_val(rb) ^ (int)num_val(rc));
            break;

        case Opcode.SHL:
            ra.tag = NUMBER;
            ra.number = (double)((int)num_val(rb) << ((int)num_val(rc) & 0x1F));
            break;

        case Opcode.SHR:
            ra.tag = NUMBER;
            ra.number = (double)((int)num_val(rb) >> ((int)num_val(rc) & 0x1F));
            break;

        case Opcode.USHR:
            ra.tag = NUMBER;
            ra.number = (double)((uint)num_val(rb) >> ((int)num_val(rc) & 0x1F));
            break;

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
            } else {
                ra.boolean = (num_val(rb) < num_val(rc));
            }
            break;

        case Opcode.LE:
            ra.tag = BOOLEAN;
            if (rb.tag == STRING && rc.tag == STRING) {
                ra.boolean = (hstring::hstring_compare((HString*)rb.pointer, (HString*)rc.pointer) <= 0);
            } else {
                ra.boolean = (num_val(rb) <= num_val(rc));
            }
            break;

        case Opcode.GT:
            ra.tag = BOOLEAN;
            if (rb.tag == STRING && rc.tag == STRING) {
                ra.boolean = (hstring::hstring_compare((HString*)rb.pointer, (HString*)rc.pointer) > 0);
            } else {
                ra.boolean = (num_val(rb) > num_val(rc));
            }
            break;

        case Opcode.GE:
            ra.tag = BOOLEAN;
            if (rb.tag == STRING && rc.tag == STRING) {
                ra.boolean = (hstring::hstring_compare((HString*)rb.pointer, (HString*)rc.pointer) >= 0);
            } else {
                ra.boolean = (num_val(rb) >= num_val(rc));
            }
            break;

        case Opcode.INSTANCEOF:
            ra.tag = BOOLEAN;
            ra.boolean = false;
            break;

        case Opcode.IN:
            ra.tag = BOOLEAN;
            ra.boolean = false;
            break;

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
                    ra.tag = get_prop_with_proto(hobj, key).tag;
                    ra.fastint = get_prop_with_proto(hobj, key).fastint;
                    ra.number = get_prop_with_proto(hobj, key).number;
                    ra.pointer = get_prop_with_proto(hobj, key).pointer;
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
            }
            break;

        case Opcode.DELPROP:
            ra.tag = BOOLEAN;
            ra.boolean = true;
            break;

        // === OBJECT / ARRAY CREATION ===

        case Opcode.NEWOBJ: {
            HObject*? new_obj = hobject::hobject_alloc(vm.heap, hobject::ObjClass.OBJECT);
            if (try o = new_obj) {
                ra.tag = OBJECT;
                ra.pointer = o;
            } else {
                ra.tag = UNDEFINED;
                ra.pointer = null;
            }
            break;
        }

        case Opcode.NEWARR: {
            HObject*? new_arr = hobject::hobject_alloc(vm.heap, hobject::ObjClass.ARRAY);
            if (try a = new_arr) {
                ra.tag = OBJECT;
                ra.pointer = a;
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

        // === FUNCTION CALLS ===
        // Duktape CALL: A=nargs, BC=base
        // Layout: valstack[base] = callee, valstack[base+1] = this, valstack[base+2..base+1+nargs] = args

        case Opcode.CALL: {
            // Compiler convention: A=result_reg, B=callee_reg, C=nargs
            uint result_reg = insn.a;
            uint callee_reg = insn.b;
            uint nargs = insn.c;

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

                builtins::dispatch_builtin(fn_idx, &ctx);
                break;
            }

            if (func_val.tag != OBJECT) {
                regs_base[result_reg].tag = UNDEFINED;
                regs_base[result_reg].pointer = null;
                break;
            }

            HObject* hobj = (HObject*)func_val.pointer;
            if (hobj == null || !hobj.is_callable() || hobj.comp_func == null) {
                regs_base[result_reg].tag = UNDEFINED;
                regs_base[result_reg].pointer = null;
                break;
            }

            CompiledFunction* target = hobj.comp_func;

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
            TVal undef_this;
            undef_this.tag = UNDEFINED;
            undef_this.pointer = null;
            new_act.this_binding = undef_this;

            TVal* new_regs = ptr_from_byteoff(vm.valstack, new_act.bottom_byteoff);
            uint new_nregs = target.num_regs;

            // Copy args: from callee_reg+2..callee_reg+1+nargs to new frame reg 0..nargs-1
            TVal* old_args = regs_base + callee_reg + 2;
            for (uint i = 0; i < nargs && i < (uint)target.num_args; i++) {
                new_regs[i] = old_args[i];
            }
            for (uint i = nargs; i < new_nregs; i++) {
                new_regs[i].tag = UNDEFINED;
                new_regs[i].pointer = null;
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
                builtins::dispatch_builtin(fn_idx, &ctx);
                break;
            }

            if (func_val.tag != OBJECT) {
                regs_base[result_reg].tag = UNDEFINED;
                regs_base[result_reg].pointer = null;
                break;
            }

            HObject* hobj = (HObject*)func_val.pointer;
            if (hobj == null || !hobj.is_callable() || hobj.comp_func == null) {
                regs_base[result_reg].tag = UNDEFINED;
                regs_base[result_reg].pointer = null;
                break;
            }

            CompiledFunction* target = hobj.comp_func;

            // Step 1: Create new object
            HObject*? new_obj_raw = hobject::hobject_alloc(vm.heap, hobject::ObjClass.OBJECT);
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
            new_act.flags = ACT_FLAG_STRICT | ACT_FLAG_CONSTRUCT;
            new_act.this_binding = this_tval;
            new_act.new_target = new_obj;

            TVal* new_regs = ptr_from_byteoff(vm.valstack, new_act.bottom_byteoff);
            uint new_nregs = target.num_regs;

            // Copy args
            TVal* old_args = regs_base + callee_reg + 2;
            for (uint i = 0; i < nargs && i < (uint)target.num_args; i++) {
                new_regs[i] = old_args[i];
            }
            for (uint i = nargs; i < new_nregs; i++) {
                new_regs[i].tag = UNDEFINED;
                new_regs[i].pointer = null;
            }

            vm.valstack_top = (TVal*)((usz)new_regs + (usz)new_nregs * (usz)TVal::size);
            vm.valstack_bottom = new_act.bottom_byteoff;

            needs_restart = true;
            break;
        }

        case Opcode.TAILCALL:
            break;

        // === RETURNS ===

        case Opcode.RET:
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
                    TVal? result = env::env_get(act.var_env, key);
                    if (try v = result) {
                        ra.tag = v.tag;
                        ra.fastint = v.fastint;
                        ra.number = v.number;
                        ra.pointer = v.pointer;
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

        case Opcode.PUTVAR: {
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                TVal name_val = constants[bc];
                if (name_val.tag == STRING) {
                    void* key = name_val.pointer;
                    env::env_put(act.var_env, key, *ra);
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

                HObject*? func_obj_raw = hobject::hobject_alloc(vm.heap, hobject::ObjClass.FUNCTION);
                if (try func_obj = func_obj_raw) {
                    func_obj.flags.callable = true;
                    func_obj.comp_func = template;
                    func_obj.var_env = act.var_env;
                    func_obj.lex_env = act.lex_env;

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

        case Opcode.INITFOR:
            ra.tag = UNDEFINED;
            ra.pointer = null;
            break;

        case Opcode.NEXTFOR:
            ra.tag = BOOLEAN;
            ra.boolean = false;
            rb.tag = BOOLEAN;
            rb.boolean = false;
            break;

        // === EXCEPTION HANDLING (stubs) ===

        case Opcode.TRY:
            break;

        case Opcode.ENDTRY:
            break;

        case Opcode.THROW:
            return VM_ERROR~;

        case Opcode.CATCH:
            ra.tag = UNDEFINED;
            ra.pointer = null;
            break;

        case Opcode.FINALLY:
            break;

        case Opcode.ENDFINALLY:
            break;

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

        default:
            io::eprintfn("Unknown opcode: %d", op.ordinal);
            return VM_ERROR~;
        }
    }
    }
    return vm.return_val;
}
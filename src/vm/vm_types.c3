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

const uint MAX_CALLS        = 512;
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
    /// Pointer into valstack for this activation's bottom (absolute).
    /// Used to reset valstack_bottom on return.
    TVal* bottom;
    /// Pointer into valstack where return value goes (absolute).
    /// Only set for non-topmost activations.
    TVal* retval;
    /// Flags: strict, tailcalled, construct, etc.
    uint flags;
    /// The 'this' binding for this activation (full TVal)
    TVal this_binding;
    /// For construct calls: the originally created object (before constructor ran)
    HObject* new_target;
    /// For async functions: the associated Promise (owned reference while activation is live)
    HObject* async_promise;
    /// For async functions: pointer to saved GeneratorState for AWAIT resume
    void* async_gen_state;
    /// Value stack pointer to function (borrowed; for lightfuncs)
    TVal tv_func;
    /// Highest register index that ever held a heap ref (object/buffer).
    /// 0 means no heap refs in any register — decref_callee_regs can skip.
    uint max_heap_reg;
    /// Caller's valstack_top saved at CALL time — restored on RET without recomputation.
    TVal* caller_valstack_top;
}

const uint ACT_FLAG_TAILCALLED     = 1u << 0;
const uint ACT_FLAG_CONSTRUCT      = 1u << 1;
const uint ACT_FLAG_PREVENT_YIELD  = 1u << 2;
const uint ACT_FLAG_DIRECT_EVAL    = 1u << 3;
const uint ACT_FLAG_ASYNC          = 1u << 4;

// ============================================================================
// Catcher — exception handler chain entry
// ============================================================================

/// Flags for catcher struct.
const uint CATCHER_FLAG_CATCH_ENABLED    = 1u << 0;
const uint CATCHER_FLAG_FINALLY_ENABLED  = 1u << 1;
const uint CATCHER_FLAG_PENDING_RETURN   = 1u << 2;
const uint CATCHER_FLAG_PENDING_BREAK    = 1u << 3;
const uint CATCHER_FLAG_PENDING_CONTINUE = 1u << 4;
const uint CATCHER_FLAG_IN_FINALLY       = 1u << 5;

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
    /// Saved return value for return-through-finally (set by RET).
    TVal return_val;
    /// Saved PC target for break/continue-through-finally.
    Instruction* pending_pc;
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
    TVal* valstack_bottom; /// Pointer to current activation's bottom

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

    // Debug tracing (zero overhead when false — single predicted-not-taken branch)
    bool trace;

    // Error state
    bool has_error;

    // Pending throw from ToPrimitive/ToNumber (set by to_primitive_value,
    // checked by opcode handlers that call vm_to_number)
    TVal throw_value;
    bool throw_pending;
}

// ============================================================================
// Per-frame dispatch state — bundled so sub-dispatch functions can be
// extracted into separate files without threading 12 parameters.
// ============================================================================

struct Dispatch {
    Vm* vm;
    Activation* act;
    Instruction* code_base;
    uint code_count;
    TVal* constants;
    hobject::ICEntry* ic_base;
    hobject::VarICEntry* var_ic_base;
    uint nregs;
    TVal* regs_base;
    Instruction* curr_pc;
    bool needs_restart;
}

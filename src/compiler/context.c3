module duktape::compiler;

import duktape::types;
import duktape::lexer;
import duktape::bytecode;
import duktape::hstring;
import duktape::hobject;
import duktape::heap;
import libc;
import std::io;

// ============================================================================
// Fault codes
// ============================================================================

faultdef COMPILE_ERROR;
faultdef SCOPE_ERROR;
faultdef REGISTER_OVERFLOW;
faultdef CODE_OVERFLOW;
faultdef CONST_OVERFLOW;

// ============================================================================
// Constants
// ============================================================================

const uint MAX_REGISTERS  = 512;
const uint MAX_PARAMS     = 32;
const uint MAX_CODE        = 4096;
const uint MAX_CONSTANTS   = 1024;
const uint MAX_INNER_FUNCS = 64;
const uint MAX_SCOPE_DEPTH = 256;
const uint MAX_LOOP_DEPTH  = 16;
const uint MAX_TRY_DEPTH   = 8;
const uint MAX_LABELS       = 16;
const uint MAX_CONST_HASH   = 1024;  // Open-addressing hash table for constant dedup
/// Insertion cap keeping at least 25% of slots empty so probes terminate early.
const uint MAX_CONST_HASH_FILL = MAX_CONST_HASH - MAX_CONST_HASH / 4;

/// Sentinel for "no patch" in break/continue patch lists.
const uint NO_PATCH = 0xFFFF_FFFF;

// Hash table entry for constant pool deduplication.
// Maps constant TVal bits to constant pool index via open-addressing.
struct ConstHashEntry {
    ulong hash;   // 0 = empty slot; TVal bits otherwise
    uint  index;  // index into constants array
}

// ============================================================================
// Binary operator precedence levels (for Pratt parser)
// ============================================================================

const int PREC_NONE          = 0;
const int PREC_COMMA         = 1;
const int PREC_ASSIGNMENT    = 2;
const int PREC_CONDITIONAL   = 3;
const int PREC_NULLISH       = 4;
const int PREC_LOGICAL_OR    = 5;
const int PREC_LOGICAL_AND   = 6;
const int PREC_BITWISE_OR    = 7;
const int PREC_BITWISE_XOR   = 8;
const int PREC_BITWISE_AND   = 9;
const int PREC_EQUALITY      = 10;
const int PREC_RELATIONAL    = 11;
const int PREC_SHIFT         = 12;
const int PREC_ADDITIVE      = 13;
const int PREC_MULTIPLICATIVE = 14;
const int PREC_EXPONENTIATION = 15;
const int PREC_UNARY          = 16;
const int PREC_POSTFIX        = 17;
const int PREC_CALL           = 18;

// ============================================================================
// Supporting structures
// ============================================================================

enum ScopeKind : char {
    VAR,
    LET,
    CONST,
}

struct ScopeEntry {
    char[] name;
    ushort reg;
    ScopeKind kind;
    bool is_captured;
}

struct LoopInfo {
    uint continue_target;
    uint break_patch_head;
    uint continue_patch_head; ///< chain of pending continue jumps (deferred until target resolved)
    bool is_loop;             ///< false for switch pseudo-loops (continue skips these)
}

struct TryInfo {
    uint catch_addr;
    uint finally_addr;
}

struct LabelInfo {
    char[] name;
    uint loop_index;   ///< index into loop_stack (NO_PATCH if not yet resolved)
    bool is_loop;      ///< true if this label refers to a loop (supports continue)
}

/// Tracks a break/continue patch chain for forward-patching jumps.
struct PatchEntry {
    uint addr;        // instruction index to patch
    uint next;        // index of next in chain, or NO_PATCH
}

/// Tracks a parameter with a default value expression.
struct ParamDefault {
    ushort param_reg;       // register holding the parameter
    uint    param_name_idx; // constant index of the parameter name
    uint    default_func_idx; // index into inner_funcs for the default expression
}

/// Tracks a binding in an array destructuring pattern.
struct ArrayBind {
    ushort reg;
    uint   name_idx;
    bool   is_rest;
    bool   is_hole;
}

/// Tracks a binding in an object destructuring pattern.
struct ObjBind {
    ushort reg;
    uint   name_idx;
    uint   key_idx;
}

// ============================================================================
// CompilerContext
// ============================================================================

struct CompilerContext {
    Lexer* lexer;
    void* heap;

    // Current function being compiled
    CompiledFunction* current_func;

    // Register allocation
    ushort next_reg;
    ushort max_reg;

    // Constant pool
    TVal[MAX_CONSTANTS] constants;
    uint const_count;
    // Hash table for constant deduplication: maps TVal bits → constant index
    ConstHashEntry[MAX_CONST_HASH] const_hash;
    uint const_hash_count;

    // Code emission
    Instruction[MAX_CODE] code;
    uint code_count;

    // Inner functions
    CompiledFunction*[MAX_INNER_FUNCS] inner_funcs;
    uint inner_func_count;

    // Scope tracking
    ScopeEntry[MAX_SCOPE_DEPTH] scope_stack;
    uint scope_depth;

    // Loop/break/continue tracking
    LoopInfo[MAX_LOOP_DEPTH] loop_stack;
    uint loop_depth;

    // Try/catch tracking
    TryInfo[MAX_TRY_DEPTH] try_stack;
    uint try_depth;

    // Label tracking
    LabelInfo[MAX_LABELS] labels;
    uint label_count;

    // Patch list pool for break/continue forward patches
    PatchEntry[256] patches;
    uint patch_count;

    // Track last identifier resolved via GETVAR (for assignment write-back)
    bool last_was_getvar;
    uint last_getvar_name_idx;
    /// Set when the last primary_expr returned a live local variable register directly.
    bool last_was_local_var;
    ushort last_local_var_reg;
    /// LHS mode: when true, member_expr saves obj/key without emitting GETPROP
    bool lhs_mode;
    /// Delete mode: when true, member_expr saves obj/key for delete.
    /// Separate from lhs_mode because expression() inside [bracket] calls
    /// assignment_expr which resets lhs_mode.
    bool del_mode;
    bool last_was_member;
    ushort last_member_obj_reg;
    ushort last_member_prop_reg;

    /// Property call: the object register to use as 'this' in emit_call.
    /// Set to MAX_REGISTERS when not in a property call.
    ushort call_prop_obj_reg;

    // Global scope flag: when true, all var decls use environment only (no register cache)
    bool is_global;

    // Eval mode: when true, expression statements save their last result
    // to eval_acc_reg for eval's implicit return value.
    bool   eval_mode;
    ushort eval_acc_reg;

    // Strict mode: set by "use strict" directive prologue.
    bool is_strict;

    // Token pushback buffer for limited backtracking (used by arrow function parsing).
    Token[4] pushback_stack;
    uint pushback_count;

    // Default parameter tracking
    ParamDefault[MAX_PARAMS] defaults;
    ushort default_count;

    // Rest parameter tracking
    bool has_rest;
    ushort rest_formal_count;   // number of formals before rest parameter
    ushort num_args;            // total parameter count (including rest)

    // Class-related tracking
    bool is_constructable;      // true when compiling a class constructor
    bool in_class_body;         // true when parsing a class body (enables super)
    bool has_super_binding;     // true when class has extends (super() available)

    // Generator tracking
    bool is_generator;          // true when compiling a generator function (function*)

    // arguments tracking
    bool uses_arguments;        // true when 'arguments' is referenced in function body

    // Local binding tracking — used to decide needs_env optimisation.
    // Set to true when the function body contains any var/function declarations
    // that would be hoisted to the function scope.
    bool has_local_bindings;

    // Closure tracking — set to true when a nested function is defined in
    // this function's body.  Combined with has_local_bindings to decide
    // needs_env: if the function has var bindings but no nested functions
    // that could capture them, the env can be skipped.
    bool has_closures;

    // Direct eval tracking — when true, the CALL path must create a fresh env.
    bool has_direct_eval;

    // Arrow/async tracking — needed for needs_env computation in finish().
    bool is_arrow;
    bool is_async;
}

// ============================================================================
// CompilerContext — initialisation and finalisation
// ============================================================================

fn void CompilerContext.init(&self, Lexer* lex, void* heap) {
    libc::memset(self, 0, CompilerContext::size);
    self.lexer = lex;
    self.heap = heap;
    self.next_reg = 0;
    self.max_reg = 0;
    self.const_count = 0;
    self.code_count = 0;
    self.inner_func_count = 0;
    self.scope_depth = 0;
    self.loop_depth = 0;
    self.try_depth = 0;
    self.label_count = 0;
    self.patch_count = 0;
    self.const_hash_count = 0;
    self.call_prop_obj_reg = MAX_REGISTERS;
    self.pushback_count = 0;

    // Strict-only engine: all code runs in strict mode by default
    self.is_strict = true;
    self.lexer.set_strict(true);
}

/// Finalise compilation: allocate a CompiledFunction and copy code/constants.
fn CompiledFunction*? CompilerContext.finish(&self) {
    // Allocate the CompiledFunction struct
    void* raw = libc::malloc(CompiledFunction::size);
    if (raw == null) {
        return COMPILE_ERROR~;
    }
    libc::memset(raw, 0, CompiledFunction::size);

    CompiledFunction* func = (CompiledFunction*)raw;
    func.flags.htype = HType.OBJECT;

    // --- Peephole: fuse GETVAR + INC/DEC + PUTVAR into INC_VAR/DEC_VAR ---
    // Pattern: GETVAR r, name  /  INC r  /  PUTVAR r, name
    //   → NOP  /  INC_VAR name  /  NOP
    // Saves 2 dispatches per loop iteration on the hot counter path.
    if (self.code_count >= 3) {
        for (uint i = 0; i + 2 < self.code_count; i++) {
            Opcode op0 = self.code[i].op;
            Opcode op1 = self.code[i + 1].op;
            Opcode op2 = self.code[i + 2].op;
            if (op0 == Opcode.GETVAR
                && (op1 == Opcode.INC || op1 == Opcode.DEC)
                && op2 == Opcode.PUTVAR) {
                uint reg_a = self.code[i].a;
                if (self.code[i + 1].a == reg_a && self.code[i + 2].a == reg_a) {
                    uint name0 = self.code[i].get_bc();
                    uint name2 = self.code[i + 2].get_bc();
                    if (name0 == name2 && name0 < self.const_count) {
                        Opcode fused = (op1 == Opcode.INC) ? Opcode.INC_VAR : Opcode.DEC_VAR;
                        self.code[i] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
                        self.code[i + 1] = bytecode::make_a_bc(fused, 0, name0);
                        self.code[i + 2] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
                    }
                }
            }
        }
    }

    // Copy instruction stream
    if (self.code_count > 0) {
        usz code_bytes = (usz)self.code_count * Instruction::size;
        void* code_raw = libc::malloc(code_bytes);
        if (code_raw == null) {
            libc::free(raw);
            return COMPILE_ERROR~;
        }
        libc::memcpy(code_raw, &self.code[0], code_bytes);
        func.code = (Instruction*)code_raw;
        func.code_count = self.code_count;
    }

    // Copy constant pool
    if (self.const_count > 0) {
        usz const_bytes = (usz)self.const_count * TVal::size;
        void* const_raw = libc::malloc(const_bytes);
        if (const_raw == null) {
            if (func.code != null) { libc::free(func.code); }
            libc::free(raw);
            return COMPILE_ERROR~;
        }
        libc::memcpy(const_raw, &self.constants[0], const_bytes);
        func.constants = (TVal*)const_raw;
        func.const_count = self.const_count;
    }

    // Copy inner functions
    if (self.inner_func_count > 0) {
        usz inner_bytes = (usz)self.inner_func_count * CompiledFunction*::size;
        void* inner_raw = libc::malloc(inner_bytes);
        if (inner_raw == null) {
            if (func.code != null) { libc::free(func.code); }
            if (func.constants != null) { libc::free(func.constants); }
            libc::free(raw);
            return COMPILE_ERROR~;
        }
        libc::memcpy(inner_raw, &self.inner_funcs[0], inner_bytes);
        func.inner_funcs = (CompiledFunction**)inner_raw;
        func.inner_count = self.inner_func_count;
    }

    func.num_regs = self.max_reg;
    func.flags.is_strict = self.is_strict;
    func.flags.has_rest = self.has_rest;
    func.flags.is_constructable = self.is_constructable;
    func.flags.is_generator = self.is_generator;
    func.flags.uses_arguments = self.uses_arguments;

    // `needs_env` controls whether the CALL fast path allocates a fresh
    // env record + bindings object per call (2 allocations).  We only need
    // a fresh env when the function's scope is actually accessed at runtime:
    //   - var bindings captured by a nested closure
    //   - arguments object
    //   - direct eval
    // Functions with var declarations but no closures, eval, or arguments
    // can reuse the parent's env directly.
    bool has_params_needing_env = self.has_rest || self.default_count > 0;
    bool needs_runtime_env = (self.has_local_bindings && self.has_closures)
                          || self.uses_arguments
                          || self.has_direct_eval;
    bool can_skip_env = !needs_runtime_env
                     && !has_params_needing_env
                     && !self.is_arrow
                     && !self.is_generator
                     && !self.is_async;
    func.flags.needs_env = !can_skip_env;
    func.num_args = self.num_args;
    if (self.has_rest) {
        func.num_formals = self.rest_formal_count;
    } else {
        func.num_formals = self.num_args;
    }

    // Allocate Inline Cache array — one entry per instruction, zeroed.
    if (func.code_count > 0) {
        usz ic_bytes = (usz)func.code_count * hobject::ICEntry::size;
        void* ic_raw = libc::malloc(ic_bytes);
        if (ic_raw != null) {
            libc::memset(ic_raw, 0, ic_bytes);
            func.ic_entries = ic_raw;
            func.ic_count = func.code_count;
        }

        // Allocate Variable IC array — one entry per instruction, zeroed.
        usz vic_bytes = (usz)func.code_count * hobject::VarICEntry::size;
        void* vic_raw = libc::malloc(vic_bytes);
        if (vic_raw != null) {
            libc::memset(vic_raw, 0, vic_bytes);
            func.var_ic_entries = vic_raw;
            func.var_ic_count = func.code_count;
        }
    }

    // Track the CompiledFunction for cleanup when the heap is destroyed
    heap::Heap* hp = (heap::Heap*)self.heap;
    hp.track_compiled_func(raw);

    return func;
}

/// Maximum number of lexical declarations in a single pre-scan pass.
const uint MAX_PRESCAN_NAMES = 64;

/// Stores the position and length of a variable name in the source text.
struct NameSpan {
    uint pos;   // byte offset into the source buffer
    uint len;   // length in bytes
}

const uint MAX_CLASS_METHODS = 32;

struct ClassMethod {
    char[] name;
    uint   inner_idx;
    bool   is_static;
    bool   is_getter;
    bool   is_setter;
    uint   computed_key_inner_idx;  // MAX_INNER_FUNCS = not computed
}

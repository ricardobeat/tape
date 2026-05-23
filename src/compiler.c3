/// Duktape compiler — recursive-descent parser with direct bytecode emission.
///
/// Takes tokens from the Lexer and emits register-based bytecode into a
/// CompiledFunction.  The compiler implements a full recursive-descent
/// parser covering ECMAScript statements and expressions, using a Pratt
/// parser for binary operator precedence.
///
/// Usage:
///   Lexer lex = Lexer.init(source, heap);
///   CompiledFunction* fn = compile(&lex, heap)!;
module duktape::compiler;

import duktape::types;
import duktape::lexer;
import duktape::bytecode;
import duktape::hstring;
import duktape::heap;
import libc;

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

const uint MAX_REGISTERS  = 256;
const uint MAX_CODE        = 4096;
const uint MAX_CONSTANTS   = 1024;
const uint MAX_INNER_FUNCS = 64;
const uint MAX_SCOPE_DEPTH = 256;
const uint MAX_LOOP_DEPTH  = 16;
const uint MAX_TRY_DEPTH   = 8;
const uint MAX_LABELS       = 16;

/// Sentinel for "no patch" in break/continue patch lists.
const uint NO_PATCH = 0xFFFF_FFFF;

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

struct ScopeEntry {
    char[] name;
    ushort reg;
    bool is_const;
    bool is_captured;
}

struct LoopInfo {
    uint continue_target;
    uint break_patch_head;
}

struct TryInfo {
    uint catch_addr;
    uint finally_addr;
}

struct LabelInfo {
    char[] name;
    uint loop_depth;
}

/// Tracks a break/continue patch chain for forward-patching jumps.
struct PatchEntry {
    uint addr;        // instruction index to patch
    uint next;        // index of next in chain, or NO_PATCH
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
    /// LHS mode: when true, member_expr saves obj/key without emitting GETPROP
    bool lhs_mode;
    bool last_was_member;
    ushort last_member_obj_reg;
    ushort last_member_prop_reg;

    /// Property call: the object register to use as 'this' in emit_call.
    /// Set to MAX_REGISTERS when not in a property call.
    ushort call_prop_obj_reg;

    // Global scope flag: when true, all var decls use environment only (no register cache)
    bool is_global;
}

// ============================================================================
// Top-level entry points
// ============================================================================

/// Compile a complete program (sequence of statements).
/// Returns the top-level CompiledFunction or a fault on error.
fn CompiledFunction*? compile(Lexer* lex, void* heap) {
    CompilerContext ctx;
    ctx.init(lex, heap);
    ctx.is_global = true;

    // Parse statements until EOF
    while (!ctx.is_at_end()) {
        ctx.statement()!;
    }

    // Emit implicit "return undefined" at end of program
    ctx.emit_simple(Opcode.RETUNDEF);

    return ctx.finish()!;
}

/// Compile a function expression or declaration.
/// `is_expr` is true for function expressions, false for declarations.
fn CompiledFunction*? compile_function(Lexer* lex, void* heap, bool is_expr) {
    CompilerContext ctx;
    ctx.init(lex, heap);

    // Parse function body
    ctx.parse_function_body(is_expr)!;

    return ctx.finish()!;
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
    self.call_prop_obj_reg = MAX_REGISTERS;
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

    return func;
}

// ============================================================================
// Token consumption helpers
// ============================================================================

/// Advance: consume the next token from the lexer and return it.
fn Token? CompilerContext.advance(&self) {
    Token tok = self.lexer.next_token()!;
    return tok;
}

/// Expect the next token to be of the given type; consume and return it.
/// Returns COMPILE_ERROR if the type doesn't match.
fn Token? CompilerContext.expect(&self, TokenType tt) {
    Token tok = self.lexer.next_token()!;
    if (tok.type != tt) {
        return COMPILE_ERROR~;
    }
    return tok;
}

/// If the next token matches `tt`, consume it and return true.
/// Otherwise leave it unconsumed and return false.
fn bool CompilerContext.match(&self, TokenType tt) {
    if (try tok = self.lexer.peek()) {
        if (tok.type == tt) {
            // Consume it by calling next_token; ignore errors
            if (try _consumed = self.lexer.next_token()) {
                return true;
            }
        }
    }
    return false;
}

/// Peek at the next token type without consuming.
fn TokenType CompilerContext.peek_type(&self) {
    if (try tok = self.lexer.peek()) {
        return tok.type;
    }
    return TokenType.EOF_TOKEN;
}

/// Check if the next token is the given type without consuming.
fn bool CompilerContext.check(&self, TokenType tt) {
    return self.peek_type() == tt;
}

/// Returns true if we've reached the end of input.
fn bool CompilerContext.is_at_end(&self) {
    return self.peek_type() == TokenType.EOF_TOKEN;
}

// ============================================================================
// Register allocation
// ============================================================================

/// Allocate the next free register.
fn ushort CompilerContext.alloc_reg(&self) {
    ushort reg = self.next_reg;
    self.next_reg++;
    if (self.next_reg > self.max_reg) {
        self.max_reg = self.next_reg;
    }
    return reg;
}

/// Allocate multiple consecutive registers, returning the first.
fn ushort CompilerContext.alloc_regs(&self, ushort count) {
    ushort first = self.next_reg;
    self.next_reg += count;
    if (self.next_reg > self.max_reg) {
        self.max_reg = self.next_reg;
    }
    return first;
}

/// Free a register (only frees if it's the top of the stack).
fn void CompilerContext.free_reg(&self, ushort reg) {
    if (reg + 1 == self.next_reg) {
        self.next_reg--;
    }
}

/// Free registers back to a saved point.
fn void CompilerContext.free_regs_to(&self, ushort saved) {
    if (self.next_reg > saved) {
        self.next_reg = saved;
    }
}

// ============================================================================
// Code emission
// ============================================================================

/// Emit a raw instruction, returning its index in the code array.
fn uint CompilerContext.emit(&self, Instruction inst) {
    if (self.code_count >= MAX_CODE) {
        return self.code_count;  // silently cap (real impl would error)
    }
    uint idx = self.code_count;
    self.code[idx] = inst;
    self.code_count++;
    return idx;
}

/// Emit an instruction in A-B-C format.
fn uint CompilerContext.emit_abc(&self, Opcode op, uint a, uint b, uint c) {
    return self.emit(bytecode::make_abc(op, a, b, c));
}

/// Emit an instruction in A-BC format.
fn uint CompilerContext.emit_a_bc(&self, Opcode op, uint a, uint bc) {
    return self.emit(bytecode::make_a_bc(op, a, bc));
}

/// Emit an instruction in A-sBx format.
fn uint CompilerContext.emit_a_sbx(&self, Opcode op, uint a, int sbx) {
    return self.emit(bytecode::make_a_sbx(op, a, sbx));
}

/// Emit a JUMP instruction with a placeholder offset; return the index to patch.
fn uint CompilerContext.emit_jump(&self, Opcode op) {
    return self.emit(bytecode::make_sabc(op, 0));
}

/// Emit a conditional branch with placeholder offset.
fn uint CompilerContext.emit_cond_jump(&self, Opcode op, uint a) {
    return self.emit(bytecode::make_a_sbx(op, a, 0));
}

/// Patch a previously emitted JUMP to target the current code position.
fn void CompilerContext.patch_jump(&self, uint addr) {
    if (addr >= self.code_count) { return; }
    Opcode op = self.code[addr].op;
    int offset = (int)self.code_count - (int)addr - 1;

    if (op == Opcode.JUMP) {
        self.code[addr] = bytecode::make_sabc(Opcode.JUMP, offset);
    } else {
        // Conditional branch: preserve the A field
        uint a = self.code[addr].a;
        self.code[addr] = bytecode::make_a_sbx(op, a, offset);
    }
}

/// Emit a no-operand instruction.
fn uint CompilerContext.emit_simple(&self, Opcode op) {
    return self.emit(bytecode::make_abc(op, 0, 0, 0));
}

// ============================================================================
// Constant pool
// ============================================================================

/// Add a TVal to the constant pool and return its index.
fn uint CompilerContext.add_constant(&self, TVal val) {
    // Check for duplicates (number and fastint)
    for (uint i = 0; i < self.const_count; i++) {
        if (self.constants[i].tag == val.tag) {
            if (val.tag == TValTag.NUMBER) {
                if (self.constants[i].number == val.number) {
                    return i;
                }
            } else if (val.tag == TValTag.FASTINT) {
                if (self.constants[i].fastint == val.fastint) {
                    return i;
                }
            }
        }
    }

    if (self.const_count >= MAX_CONSTANTS) {
        return self.const_count;  // cap
    }
    uint idx = self.const_count;
    self.constants[idx] = val;
    self.const_count++;
    return idx;
}

/// Add a string constant: intern the string and add a STRING TVal to the pool.
fn uint CompilerContext.add_string_constant(&self, char[] str) {
    // Check for duplicate string constants by scanning existing entries
    for (uint i = 0; i < self.const_count; i++) {
        if (self.constants[i].tag == TValTag.STRING) {
            HString* existing = (HString*)self.constants[i].pointer;
            if (existing != null && existing.equals(str)) {
                return i;
            }
        }
    }

    // Intern the string via the heap's string table for pointer deduplication
    Heap* hp = (Heap*)self.heap;
    uint hash = hp.hash_string(str);

    // First, check if the string is already interned in the heap
    HString* hstr = hp.str_table_lookup(str, hash);
    if (hstr == null) {
        // Not found — allocate and insert
        hstr = hstring::hstring_alloc(self.heap, str, hash) ?? null;
        if (hstr != null) {
            hp.str_table_insert(hstr);
        }
    }

    TVal tv;
    if (hstr != null) {
        tv.tag = TValTag.STRING;
        tv.pointer = hstr;
    } else {
        // Fallback: store as pointer with null
        tv.tag = TValTag.STRING;
        tv.pointer = null;
    }

    if (self.const_count >= MAX_CONSTANTS) {
        return self.const_count;
    }
    uint idx = self.const_count;
    self.constants[idx] = tv;
    self.const_count++;
    return idx;
}

/// Add a number constant and return its index.
fn uint CompilerContext.add_number_constant(&self, double val) {
    TVal tv;
    tv.tag = TValTag.NUMBER;
    tv.number = val;
    return self.add_constant(tv);
}

// ============================================================================
// Scope management
// ============================================================================

/// Push a new scope level (for blocks, functions, etc.).
fn void CompilerContext.push_scope(&self) {
    // We use scope_depth as a marker; entries below it belong to outer scopes.
    // Nothing to allocate — scope_stack is shared with depth tracking.
}

/// Pop the current scope level, freeing any variables declared in it.
fn void CompilerContext.pop_scope(&self) {
    // Walk backwards through scope_stack and remove entries at current depth
    while (self.scope_depth > 0) {
        // Peek at the topmost entry
        ScopeEntry* top = &self.scope_stack[self.scope_depth - 1];
        // Free the register
        self.free_reg(top.reg);
        self.scope_depth--;
        break;  // We'll be called in a loop by the block parser
    }
}

/// Pop all scope entries added since `saved_depth`.
fn void CompilerContext.pop_scope_to(&self, uint saved_depth) {
    while (self.scope_depth > saved_depth) {
        ScopeEntry* top = &self.scope_stack[self.scope_depth - 1];
        self.free_reg(top.reg);
        self.scope_depth--;
    }
}

/// Declare a variable in the current scope.
fn ushort CompilerContext.declare_var(&self, char[] name, bool is_const) {
    ushort reg = self.alloc_reg();
    // At global scope, don't register-cache — use environment via PUTVAR/GETVAR
    if (!self.is_global && self.scope_depth < MAX_SCOPE_DEPTH) {
        self.scope_stack[self.scope_depth].name = name;
        self.scope_stack[self.scope_depth].reg = reg;
        self.scope_stack[self.scope_depth].is_const = is_const;
        self.scope_stack[self.scope_depth].is_captured = false;
        self.scope_depth++;
    }
    return reg;
}

/// Resolve a variable name to its register. Searches from innermost scope out.
fn ushort? CompilerContext.resolve_var(&self, char[] name) {
    // Search from top of scope stack backwards
    if (self.scope_depth == 0) {
        return SCOPE_ERROR~;
    }
    uint i = self.scope_depth;
    while (i > 0) {
        i--;
        if (str_eq(self.scope_stack[i].name, name)) {
            return self.scope_stack[i].reg;
        }
    }
    return SCOPE_ERROR~;
}

/// Check if a variable is const.
fn bool CompilerContext.is_var_const(&self, char[] name) {
    if (self.scope_depth == 0) {
        return false;
    }
    uint i = self.scope_depth;
    while (i > 0) {
        i--;
        if (str_eq(self.scope_stack[i].name, name)) {
            return self.scope_stack[i].is_const;
        }
    }
    return false;
}

// ============================================================================
// Patch list management (for break/continue)
// ============================================================================

/// Add a patch address to a chain. Returns the new head.
fn uint CompilerContext.add_patch(&self, uint chain_head, uint addr) {
    if (self.patch_count >= 256) {
        return chain_head;
    }
    uint idx = self.patch_count;
    self.patches[idx].addr = addr;
    self.patches[idx].next = chain_head;
    self.patch_count++;
    return idx;
}

/// Patch all jumps in a patch chain to point to the current code position.
fn void CompilerContext.patch_chain(&self, uint chain_head) {
    uint current = chain_head;
    while (current != NO_PATCH && current < self.patch_count) {
        uint addr = self.patches[current].addr;
        self.patch_jump(addr);
        current = self.patches[current].next;
    }
}

// ============================================================================
// Loop stack management
// ============================================================================

fn void CompilerContext.push_loop(&self, uint continue_target) {
    if (self.loop_depth < MAX_LOOP_DEPTH) {
        self.loop_stack[self.loop_depth].continue_target = continue_target;
        self.loop_stack[self.loop_depth].break_patch_head = NO_PATCH;
        self.loop_depth++;
    }
}

fn void CompilerContext.pop_loop(&self) {
    if (self.loop_depth > 0) {
        self.loop_depth--;
        // Patch all break jumps to current position
        self.patch_chain(self.loop_stack[self.loop_depth].break_patch_head);
    }
}

fn void CompilerContext.add_break_patch(&self, uint addr) {
    if (self.loop_depth > 0) {
        uint top = self.loop_depth - 1;
        self.loop_stack[top].break_patch_head =
            self.add_patch(self.loop_stack[top].break_patch_head, addr);
    }
}

// ============================================================================
// Statement parsing
// ============================================================================

/// Parse and compile a single statement, dispatching on token type.
fn void? CompilerContext.statement(&self) {
    TokenType tt = self.peek_type();

    switch (tt) {
        case TokenType.LBRACE:
            self.block()!;
        case TokenType.VAR:
            self.var_declaration()!;
        case TokenType.LET:
            self.var_declaration()!;
        case TokenType.CONST:
            self.var_declaration()!;
        case TokenType.IF:
            self.if_statement()!;
        case TokenType.WHILE:
            self.while_statement()!;
        case TokenType.DO:
            self.do_while_statement()!;
        case TokenType.FOR:
            self.for_statement()!;
        case TokenType.RETURN:
            self.return_statement()!;
        case TokenType.THROW:
            self.throw_statement()!;
        case TokenType.TRY:
            self.try_statement()!;
        case TokenType.SWITCH:
            self.switch_statement()!;
        case TokenType.BREAK:
            self.break_statement()!;
        case TokenType.CONTINUE:
            self.continue_statement()!;
        case TokenType.FUNCTION:
            self.function_declaration()!;
        case TokenType.SEMICOLON:
            // Empty statement
            self.advance()!;
        case TokenType.DEBUGGER:
            self.advance()!;
            self.emit_simple(Opcode.DEBUGGER);
            self.match(TokenType.SEMICOLON);
        default:
            self.expression_statement()!;
    }
}

/// Parse a block: { statement* }
fn void? CompilerContext.block(&self) {
    self.expect(TokenType.LBRACE)!;
    uint saved_depth = self.scope_depth;
    ushort saved_reg = self.next_reg;

    while (!self.check(TokenType.RBRACE) && !self.is_at_end()) {
        self.statement()!;
    }

    self.expect(TokenType.RBRACE)!;

    // Pop scope entries created inside the block
    self.pop_scope_to(saved_depth);
    self.free_regs_to(saved_reg);
}

/// Parse var/let/const declaration.
fn void? CompilerContext.var_declaration(&self) {
    Token decl_tok = self.advance()!;
    bool is_const = (decl_tok.type == TokenType.CONST);

    // Parse one or more variable declarators
    for (;;) {
        Token name_tok = self.expect(TokenType.IDENTIFIER)!;
        ushort reg = self.declare_var(name_tok.str_value, is_const);

        // Optional initializer
        if (self.match(TokenType.ASSIGN)) {
            ushort val_reg = self.assignment_expr()!;
            if (val_reg != reg) {
                self.emit_abc(Opcode.LDREG, (uint)reg, (uint)val_reg, 0);
            }
            self.free_reg(val_reg);
        } else {
            // Default initialize to undefined
            self.emit_abc(Opcode.LDUNDEF, (uint)reg, 0, 0);
        }

        // Also store in the environment so inner functions can find it via GETVAR
        uint name_idx = self.add_string_constant(name_tok.str_value);
        self.emit_a_bc(Opcode.PUTVAR, (uint)reg, name_idx);

        if (!self.match(TokenType.COMMA)) {
            break;
        }
    }

    self.match(TokenType.SEMICOLON);
}

/// Parse if/else statement.
fn void? CompilerContext.if_statement(&self) {
    self.expect(TokenType.IF)!;
    self.expect(TokenType.LPAREN)!;

    // Compile condition
    ushort cond_reg = self.expression()!;

    self.expect(TokenType.RPAREN)!;

    // Emit conditional jump (skip then-branch if false)
    uint false_jump = self.emit_cond_jump(Opcode.IF_FALSE, (uint)cond_reg);
    self.free_reg(cond_reg);

    // Compile then-branch
    self.statement()!;

    if (self.match(TokenType.ELSE)) {
        // Emit jump over else-branch
        uint end_jump = self.emit_jump(Opcode.JUMP);
        self.patch_jump(false_jump);

        // Compile else-branch
        self.statement()!;

        self.patch_jump(end_jump);
    } else {
        self.patch_jump(false_jump);
    }
}

/// Parse while statement.
fn void? CompilerContext.while_statement(&self) {
    self.expect(TokenType.WHILE)!;
    self.expect(TokenType.LPAREN)!;

    uint loop_start = self.code_count;
    self.push_loop(loop_start);

    // Compile condition
    ushort cond_reg = self.expression()!;

    self.expect(TokenType.RPAREN)!;

    // Jump out if condition is false
    uint exit_jump = self.emit_cond_jump(Opcode.IF_FALSE, (uint)cond_reg);
    self.free_reg(cond_reg);

    // Compile body
    self.statement()!;

    // Jump back to loop start
    int back_offset = (int)loop_start - (int)self.code_count - 1;
    self.emit(bytecode::make_sabc(Opcode.JUMP, back_offset));

    self.patch_jump(exit_jump);
    self.pop_loop();
}

/// Parse for statement (basic for, for-in, for-of).
fn void? CompilerContext.for_statement(&self) {
    self.expect(TokenType.FOR)!;
    self.expect(TokenType.LPAREN)!;

    uint saved_scope = self.scope_depth;
    ushort saved_reg = self.next_reg;

    // Check for for-in / for-of
    TokenType next_tt = self.peek_type();

    // Parse init (may be var/let/const or expression or empty)
    if (next_tt == TokenType.VAR || next_tt == TokenType.LET || next_tt == TokenType.CONST) {
        // Check if it's for-in: "var x in ..."
        // We parse the variable declaration keyword
        Token decl_tok = self.advance()!;
        bool is_const = (decl_tok.type == TokenType.CONST);
        Token name_tok = self.expect(TokenType.IDENTIFIER)!;

        // Check for "in" (for-in) or "of" (for-of)
        if (self.peek_type() == TokenType.IN) {
            // for (var x in obj) { ... }
            self.advance()!;  // consume 'in'
            ushort iter_var = self.declare_var(name_tok.str_value, is_const);
            ushort obj_reg = self.assignment_expr()!;
            self.expect(TokenType.RPAREN)!;

            // Emit INITFOR to set up the iterator
            ushort iter_state = self.alloc_reg();
            self.emit_abc(Opcode.INITFOR, (uint)obj_reg, (uint)iter_state, 0);

            uint loop_start = self.code_count;
            self.push_loop(loop_start);

            // Emit NEXTFOR: iter_var = next key, B = has_next
            ushort has_next = self.alloc_reg();
            self.emit_abc(Opcode.NEXTFOR, (uint)iter_var, (uint)has_next, (uint)iter_state);

            // If no more keys, exit
            uint exit_jump = self.emit_cond_jump(Opcode.IF_FALSE, (uint)has_next);
            self.free_reg(has_next);

            // Compile body
            self.statement()!;

            // Jump back to loop start
            int back_offset = (int)loop_start - (int)self.code_count - 1;
            self.emit(bytecode::make_sabc(Opcode.JUMP, back_offset));

            self.patch_jump(exit_jump);
            self.pop_loop();

            self.free_reg(iter_state);
            self.free_reg(obj_reg);
            self.pop_scope_to(saved_scope);
            self.free_regs_to(saved_reg);
            return;
        }

        // Standard for loop: we already consumed the decl keyword and identifier
        // Declare the variable and optionally initialize
        ushort var_reg = self.declare_var(name_tok.str_value, is_const);
        if (self.match(TokenType.ASSIGN)) {
            ushort init_val = self.assignment_expr()!;
            if (init_val != var_reg) {
                self.emit_abc(Opcode.LDREG, (uint)var_reg, (uint)init_val, 0);
            }
            self.free_reg(init_val);
        } else {
            self.emit_abc(Opcode.LDUNDEF, (uint)var_reg, 0, 0);
        }
        // Also store in environment (needed at global scope for GETVAR)
        uint name_idx = self.add_string_constant(name_tok.str_value);
        self.emit_a_bc(Opcode.PUTVAR, (uint)var_reg, name_idx);

        // More declarations?
        while (self.match(TokenType.COMMA)) {
            Token extra_name = self.expect(TokenType.IDENTIFIER)!;
            ushort extra_reg = self.declare_var(extra_name.str_value, is_const);
            if (self.match(TokenType.ASSIGN)) {
                ushort extra_val = self.assignment_expr()!;
                if (extra_val != extra_reg) {
                    self.emit_abc(Opcode.LDREG, (uint)extra_reg, (uint)extra_val, 0);
                }
                self.free_reg(extra_val);
            } else {
                self.emit_abc(Opcode.LDUNDEF, (uint)extra_reg, 0, 0);
            }
            uint extra_name_idx = self.add_string_constant(extra_name.str_value);
            self.emit_a_bc(Opcode.PUTVAR, (uint)extra_reg, extra_name_idx);
        }

        self.expect(TokenType.SEMICOLON)!;
    } else if (next_tt != TokenType.SEMICOLON) {
        // Expression init
        ushort init_reg = self.expression()!;
        self.free_reg(init_reg);
        self.expect(TokenType.SEMICOLON)!;
    } else {
        // Empty init
        self.expect(TokenType.SEMICOLON)!;
    }

    // Condition
    uint cond_start = self.code_count;
    uint exit_jump = NO_PATCH;

    if (!self.check(TokenType.SEMICOLON)) {
        ushort cond_reg = self.expression()!;
        exit_jump = self.emit_cond_jump(Opcode.IF_FALSE, (uint)cond_reg);
        self.free_reg(cond_reg);
    }
    self.expect(TokenType.SEMICOLON)!;

    // Update expression — compile it but jump over it initially
    uint update_jump = self.emit_jump(Opcode.JUMP);
    uint update_start = self.code_count;

    if (!self.check(TokenType.RPAREN)) {
        ushort update_reg = self.expression()!;
        self.free_reg(update_reg);
    }

    // Jump back to condition
    int cond_back = (int)cond_start - (int)self.code_count - 1;
    self.emit(bytecode::make_sabc(Opcode.JUMP, cond_back));

    self.expect(TokenType.RPAREN)!;

    self.patch_jump(update_jump);

    // Push loop with continue_target pointing to the update expression
    self.push_loop(update_start);

    // Compile body
    self.statement()!;

    // Jump to update
    int update_back = (int)update_start - (int)self.code_count - 1;
    self.emit(bytecode::make_sabc(Opcode.JUMP, update_back));

    // Patch exit
    if (exit_jump != NO_PATCH) {
        self.patch_jump(exit_jump);
    }

    self.pop_loop();
    self.pop_scope_to(saved_scope);
    self.free_regs_to(saved_reg);
}

/// Parse do-while statement.
fn void? CompilerContext.do_while_statement(&self) {
    self.expect(TokenType.DO)!;

    uint loop_start = self.code_count;
    // Continue target is the condition (we'll record the address after the body)
    self.push_loop(loop_start);  // temporary; we'll fix continue_target

    // Compile body
    self.statement()!;

    // Fix the continue target to point to the condition
    if (self.loop_depth > 0) {
        self.loop_stack[self.loop_depth - 1].continue_target = self.code_count;
    }

    self.expect(TokenType.WHILE)!;
    self.expect(TokenType.LPAREN)!;

    ushort cond_reg = self.expression()!;

    self.expect(TokenType.RPAREN)!;
    self.match(TokenType.SEMICOLON);

    // If condition is true, jump back to loop_start
    int back_offset = (int)loop_start - (int)self.code_count - 1;
    self.emit(bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cond_reg, back_offset));
    self.free_reg(cond_reg);

    self.pop_loop();
}

/// Parse return statement.
fn void? CompilerContext.return_statement(&self) {
    self.expect(TokenType.RETURN)!;

    // Check if there's a return value (not a semicolon or end-of-statement)
    TokenType next = self.peek_type();
    if (next == TokenType.SEMICOLON || next == TokenType.RBRACE ||
        next == TokenType.EOF_TOKEN) {
        self.emit_simple(Opcode.RETUNDEF);
    } else {
        ushort val_reg = self.expression()!;
        self.emit_abc(Opcode.RET, (uint)val_reg, 0, 0);
        self.free_reg(val_reg);
    }

    self.match(TokenType.SEMICOLON);
}

/// Parse throw statement.
fn void? CompilerContext.throw_statement(&self) {
    self.expect(TokenType.THROW)!;

    ushort val_reg = self.expression()!;
    self.emit_abc(Opcode.THROW, (uint)val_reg, 0, 0);
    self.free_reg(val_reg);

    self.match(TokenType.SEMICOLON);
}

/// Parse try/catch/finally statement.
///
/// Bytecode layout:
///   TRY A=flags, BC=catch_offset     — A bit0=catch, bit1=finally
///   NOP A=0,    BC=finally_offset    — jump slot (0 if no finally)
///   <try block>
///   ENDTRY
///   JUMP -> finally_or_after
///   [CATCH rX  — at try_addr + catch_offset]
///   [<catch block>]
///   [FINALLY   — at try_addr + finally_offset (if has_finally)]
///   [<finally block>]
///   [ENDFINALLY]
fn void? CompilerContext.try_statement(&self) {
    self.expect(TokenType.TRY)!;

    // Emit TRY instruction (placeholder: A=0, BC=0, jump_slot BC=0)
    uint try_addr = self.emit_a_bc(Opcode.TRY, 0, 0);
    // Jump slot — the VM reads this word for the finally_offset (BC field)
    uint jump_slot_addr = self.emit_a_bc(Opcode.NOP, 0, 0);

    // Push try info
    if (self.try_depth < MAX_TRY_DEPTH) {
        self.try_stack[self.try_depth].catch_addr = try_addr;
        self.try_stack[self.try_depth].finally_addr = NO_PATCH;
        self.try_depth++;
    }

    // Compile try block
    self.block()!;

    // Emit ENDTRY to pop the try handler (normal exit)
    self.emit_simple(Opcode.ENDTRY);

    // Jump (skips catch handler; target patched later)
    uint jump_over = self.emit_jump(Opcode.JUMP);

    // catch handler starts here
    uint catch_target = self.code_count;

    // Parse catch clause
    bool has_catch = false;
    bool has_finally = false;
    uint finally_tgt = 0;

    if (self.match(TokenType.CATCH)) {
        has_catch = true;
        uint catch_scope = self.scope_depth;
        ushort catch_saved_reg = self.next_reg;

        if (self.match(TokenType.LPAREN)) {
            Token catch_param = self.expect(TokenType.IDENTIFIER)!;
            self.expect(TokenType.RPAREN)!;

            ushort catch_var = self.declare_var(catch_param.str_value, false);
            self.emit_abc(Opcode.CATCH, (uint)catch_var, 0, 0);
            // For global scope, also PUTVAR the exception into the env so that
            // subsequent GETVAR for the catch variable finds it.
            if (self.is_global) {
                uint name_idx = self.add_string_constant(catch_param.str_value);
                self.emit_a_bc(Opcode.PUTVAR, (uint)catch_var, name_idx);
            }
        } else {
            // catch without binding (ES2019)
            ushort discard = self.alloc_reg();
            self.emit_abc(Opcode.CATCH, (uint)discard, 0, 0);
            self.free_reg(discard);
        }

        // Compile catch block
        self.block()!;

        self.pop_scope_to(catch_scope);
        self.free_regs_to(catch_saved_reg);
    }

    // Parse finally clause
    if (self.match(TokenType.FINALLY)) {
        has_finally = true;
        finally_tgt = self.code_count;

        // Patch the jump from the try block to land at FINALLY
        self.patch_jump(jump_over);

        // Emit FINALLY marker
        self.emit_simple(Opcode.FINALLY);

        // Compile finally block
        self.block()!;

        // Emit ENDFINALLY
        self.emit_simple(Opcode.ENDFINALLY);
    } else {
        // Patch jump to skip catch handler
        self.patch_jump(jump_over);
    }

    // Patch TRY instruction: A=flags, BC=catch_offset
    uint try_flags = (has_catch ? 1u : 0u) | (has_finally ? 2u : 0u);
    uint catch_offset = catch_target - try_addr;
    self.code[try_addr] = bytecode::make_a_bc(Opcode.TRY, try_flags, catch_offset);

    // Patch jump slot: BC=finally_offset (0 if no finally)
    uint finally_off = has_finally ? (finally_tgt - try_addr) : 0;
    self.code[jump_slot_addr] = bytecode::make_a_bc(Opcode.NOP, 0, finally_off);

    // Pop try info
    if (self.try_depth > 0) {
        self.try_depth--;
    }
}

/// Parse switch statement.
fn void? CompilerContext.switch_statement(&self) {
    self.expect(TokenType.SWITCH)!;
    self.expect(TokenType.LPAREN)!;

    ushort disc_reg = self.expression()!;

    self.expect(TokenType.RPAREN)!;
    self.expect(TokenType.LBRACE)!;

    // Push a "loop" for break handling (break in switch exits the switch)
    self.push_loop(self.code_count);

    // Collect case jump patches
    uint[64] case_jumps;
    uint case_count = 0;
    uint default_jump = NO_PATCH;

    // First pass: emit comparisons and jumps for each case
    // We need to scan ahead for cases, which is complex.
    // Simplified approach: process cases sequentially.

    while (!self.check(TokenType.RBRACE) && !self.is_at_end()) {
        if (self.match(TokenType.CASE)) {
            // Compile case expression
            ushort case_reg = self.expression()!;
            self.expect(TokenType.COLON)!;

            // Compare discriminant with case value
            ushort cmp_reg = self.alloc_reg();
            self.emit_abc(Opcode.SEQ, (uint)cmp_reg, (uint)disc_reg, (uint)case_reg);
            self.free_reg(case_reg);

            // Jump to the case body if they match
            uint match_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)cmp_reg);
            self.free_reg(cmp_reg);

            // Jump over the body if no match
            uint skip_jump = self.emit_jump(Opcode.JUMP);

            // Patch the match jump to here (the body)
            self.patch_jump(match_jump);

            // Compile case body statements
            while (!self.check(TokenType.CASE) && !self.check(TokenType.DEFAULT) &&
                   !self.check(TokenType.RBRACE) && !self.is_at_end()) {
                self.statement()!;
            }

            // If we fall through, we need to continue to next case
            // Patch the skip jump to after the body
            // But we want fall-through for matched cases...
            // Actually in a switch, once a case matches, we fall through.
            // This simplified implementation doesn't perfectly model fall-through.
            // Patch skip to here:
            self.patch_jump(skip_jump);

        } else if (self.match(TokenType.DEFAULT)) {
            self.expect(TokenType.COLON)!;

            // Compile default body
            while (!self.check(TokenType.CASE) && !self.check(TokenType.DEFAULT) &&
                   !self.check(TokenType.RBRACE) && !self.is_at_end()) {
                self.statement()!;
            }
        } else {
            // Unexpected token in switch
            return COMPILE_ERROR~;
        }
    }

    self.expect(TokenType.RBRACE)!;

    self.free_reg(disc_reg);
    self.pop_loop();
}

/// Parse break statement.
fn void? CompilerContext.break_statement(&self) {
    self.expect(TokenType.BREAK)!;

    // Optional label (not fully implemented — just handle unlabelled break)
    uint jump_addr = self.emit_jump(Opcode.JUMP);
    self.add_break_patch(jump_addr);

    self.match(TokenType.SEMICOLON);
}

/// Parse continue statement.
fn void? CompilerContext.continue_statement(&self) {
    self.expect(TokenType.CONTINUE)!;

    // Jump back to the continue target of the innermost loop
    if (self.loop_depth > 0) {
        uint target = self.loop_stack[self.loop_depth - 1].continue_target;
        int offset = (int)target - (int)self.code_count - 1;
        self.emit(bytecode::make_sabc(Opcode.JUMP, offset));
    } else {
        return COMPILE_ERROR~;
    }

    self.match(TokenType.SEMICOLON);
}

/// Parse expression statement.
fn void? CompilerContext.expression_statement(&self) {
    ushort reg = self.expression()!;
    self.free_reg(reg);
    self.match(TokenType.SEMICOLON);
}

/// Parse a function declaration (hoisted).
fn void? CompilerContext.function_declaration(&self) {
    self.expect(TokenType.FUNCTION)!;

    Token name_tok = self.expect(TokenType.IDENTIFIER)!;
    ushort func_reg = self.declare_var(name_tok.str_value, false);

    // Compile the function into a nested CompiledFunction
    CompiledFunction* inner = self.compile_inner_function(name_tok.str_value)!;

    // Add to inner functions table
    uint inner_idx = 0;
    if (self.inner_func_count < MAX_INNER_FUNCS) {
        inner_idx = self.inner_func_count;
        self.inner_funcs[inner_idx] = inner;
        self.inner_func_count++;
    }

    // Emit CLOSURE to create the function object
    self.emit_a_bc(Opcode.CLOSURE, (uint)func_reg, inner_idx);

    // Also store in environment so inner functions can find it via GETVAR
    uint name_idx = self.add_string_constant(name_tok.str_value);
    self.emit_a_bc(Opcode.PUTVAR, (uint)func_reg, name_idx);
}

/// Parse function body (parameters and block) and compile into a nested context.
fn void? CompilerContext.parse_function_body(&self, bool is_expr) {
    // Parse parameter list
    self.expect(TokenType.LPAREN)!;
    ushort arg_count = 0;

    if (!self.check(TokenType.RPAREN)) {
        for (;;) {
            Token param = self.expect(TokenType.IDENTIFIER)!;
            self.declare_var(param.str_value, false);
            arg_count++;

            if (!self.match(TokenType.COMMA)) {
                break;
            }
        }
    }

    self.expect(TokenType.RPAREN)!;

    // Compile function body block
    self.block()!;

    // Emit implicit return undefined if no explicit return
    // Check if last instruction is a return
    bool has_return = false;
    if (self.code_count > 0) {
        Opcode last_op = self.code[self.code_count - 1].op;
        if (last_op == Opcode.RET || last_op == Opcode.RETUNDEF) {
            has_return = true;
        }
    }
    if (!has_return) {
        self.emit_simple(Opcode.RETUNDEF);
    }
}

/// Compile an inner function (parameters + body) into a sub-CompiledFunction.
fn CompiledFunction*? CompilerContext.compile_inner_function(&self, char[] name) {
    // Create a new CompilerContext for the inner function
    CompilerContext inner_ctx;
    inner_ctx.init(self.lexer, self.heap);

    // Parse parameter list
    inner_ctx.expect(TokenType.LPAREN)!;
    ushort arg_count = 0;

    if (!inner_ctx.check(TokenType.RPAREN)) {
        for (;;) {
            Token param = inner_ctx.expect(TokenType.IDENTIFIER)!;
            ushort param_reg = inner_ctx.declare_var(param.str_value, false);
            // Store parameter in environment so inner functions can capture it
            uint param_name_idx = inner_ctx.add_string_constant(param.str_value);
            inner_ctx.emit_a_bc(Opcode.PUTVAR, (uint)param_reg, param_name_idx);
            arg_count++;

            if (!inner_ctx.match(TokenType.COMMA)) {
                break;
            }
        }
    }

    inner_ctx.expect(TokenType.RPAREN)!;

    // Compile function body
    inner_ctx.block()!;

    // Add implicit return undefined
    bool has_return = false;
    if (inner_ctx.code_count > 0) {
        Opcode last_op = inner_ctx.code[inner_ctx.code_count - 1].op;
        if (last_op == Opcode.RET || last_op == Opcode.RETUNDEF) {
            has_return = true;
        }
    }
    if (!has_return) {
        inner_ctx.emit_simple(Opcode.RETUNDEF);
    }

    CompiledFunction* func = inner_ctx.finish()!;
    func.num_args = arg_count;
    func.num_formals = arg_count;

    // Set function name
    if (name.len > 0) {
        func.name_ptr = name.ptr;
        func.name_len = (uint)name.len;
    }

    return func;
}

// ============================================================================
// Expression parsing
// ============================================================================

/// Parse a full expression (comma operator at lowest precedence).
fn ushort? CompilerContext.expression(&self) {
    ushort result = self.assignment_expr()!;

    // Handle comma operator: evaluate each, keep last
    while (self.match(TokenType.COMMA)) {
        self.free_reg(result);
        result = self.assignment_expr()!;
    }

    return result;
}

/// Parse an assignment expression.
fn ushort? CompilerContext.assignment_expr(&self) {
    // Parse LHS with lhs_mode enabled — member_expr saves (obj, key) without GETPROP
    self.lhs_mode = true;
    self.last_was_member = false;
    ushort left = self.conditional_expr()!;
    self.lhs_mode = false;

    TokenType tt2 = self.peek_type();

    // If LHS was a member expression but next token is NOT an assignment,
    // free the saved obj/key registers (GETPROP was already emitted)
    if (self.last_was_member && tt2 != TokenType.ASSIGN
        && tt2 != TokenType.PLUS_ASSIGN && tt2 != TokenType.MINUS_ASSIGN
        && tt2 != TokenType.STAR_ASSIGN && tt2 != TokenType.SLASH_ASSIGN
        && tt2 != TokenType.PERCENT_ASSIGN && tt2 != TokenType.STARSTAR_ASSIGN
        && tt2 != TokenType.SHL_ASSIGN && tt2 != TokenType.SHR_ASSIGN
        && tt2 != TokenType.USHR_ASSIGN && tt2 != TokenType.BIT_AND_ASSIGN
        && tt2 != TokenType.BIT_OR_ASSIGN && tt2 != TokenType.BIT_XOR_ASSIGN
        && tt2 != TokenType.LOG_AND_ASSIGN && tt2 != TokenType.LOG_OR_ASSIGN
        && tt2 != TokenType.NULLISH_ASSIGN) {
        self.free_reg(self.last_member_prop_reg);
        self.free_reg(self.last_member_obj_reg);
        self.last_was_member = false;
    }

    TokenType tt = tt2;

    // Check for assignment operators
    Opcode compound_op;
    bool is_compound = false;
    bool is_assign = false;

    switch (tt) {
        case TokenType.ASSIGN:
            is_assign = true;
        case TokenType.PLUS_ASSIGN:
            is_compound = true;
            compound_op = Opcode.ADD;
        case TokenType.MINUS_ASSIGN:
            is_compound = true;
            compound_op = Opcode.SUB;
        case TokenType.STAR_ASSIGN:
            is_compound = true;
            compound_op = Opcode.MUL;
        case TokenType.SLASH_ASSIGN:
            is_compound = true;
            compound_op = Opcode.DIV;
        case TokenType.PERCENT_ASSIGN:
            is_compound = true;
            compound_op = Opcode.MOD;
        case TokenType.STARSTAR_ASSIGN:
            is_compound = true;
            compound_op = Opcode.EXP;
        case TokenType.SHL_ASSIGN:
            is_compound = true;
            compound_op = Opcode.SHL;
        case TokenType.SHR_ASSIGN:
            is_compound = true;
            compound_op = Opcode.SHR;
        case TokenType.USHR_ASSIGN:
            is_compound = true;
            compound_op = Opcode.USHR;
        case TokenType.BIT_AND_ASSIGN:
            is_compound = true;
            compound_op = Opcode.BAND;
        case TokenType.BIT_OR_ASSIGN:
            is_compound = true;
            compound_op = Opcode.BOR;
        case TokenType.BIT_XOR_ASSIGN:
            is_compound = true;
            compound_op = Opcode.BXOR;
        case TokenType.LOG_AND_ASSIGN:
            is_compound = true;
            compound_op = Opcode.BAND;  // logical, handled differently at runtime
        case TokenType.LOG_OR_ASSIGN:
            is_compound = true;
            compound_op = Opcode.BOR;   // logical, handled differently at runtime
        case TokenType.NULLISH_ASSIGN:
            is_compound = true;
            compound_op = Opcode.BOR;   // nullish, handled differently at runtime
        default:
            return left;
    }

    // Consume the assignment operator
    self.advance()!;

    // Save LHS info (will be overwritten by RHS evaluation)
    bool lhs_was_getvar = self.last_was_getvar;
    uint lhs_getvar_name_idx = self.last_getvar_name_idx;
    bool lhs_was_member = self.last_was_member;
    ushort lhs_member_obj = self.last_member_obj_reg;
    ushort lhs_member_prop = self.last_member_prop_reg;

    // Compile right-hand side
    ushort right = self.assignment_expr()!;

    if (is_assign) {
        if (lhs_was_member) {
            // Member expression assignment: obj.prop = right
            self.emit_abc(Opcode.PUTPROP, (uint)lhs_member_obj, (uint)lhs_member_prop, (uint)right);
            self.free_reg(lhs_member_prop);
            self.free_reg(lhs_member_obj);
            self.free_reg(right);
            left = right;
        } else {
            // Simple assignment: left = right
            if (left != right) {
                self.emit_abc(Opcode.LDREG, (uint)left, (uint)right, 0);
            }
            self.free_reg(right);
            // If LHS was resolved via GETVAR, write back to environment
            if (lhs_was_getvar) {
                self.emit_a_bc(Opcode.PUTVAR, (uint)left, lhs_getvar_name_idx);
            }
        }
        return left;
    }

    if (is_compound) {
        // Compound assignment: left op= right => left = left op right
        self.emit_abc(compound_op, (uint)left, (uint)left, (uint)right);
        self.free_reg(right);
        // If LHS was resolved via GETVAR, write back to environment
        if (lhs_was_getvar) {
            self.emit_a_bc(Opcode.PUTVAR, (uint)left, lhs_getvar_name_idx);
        }
        return left;
    }

    return left;
}

/// Parse a conditional (ternary) expression: expr ? expr : expr
fn ushort? CompilerContext.conditional_expr(&self) {
    ushort result = self.binary_expr(PREC_NULLISH)!;

    if (self.match(TokenType.QUESTION)) {
        // Allocate result register
        ushort result_reg = self.alloc_reg();

        // Jump to else branch if condition is false
        uint false_jump = self.emit_cond_jump(Opcode.IF_FALSE, (uint)result);
        self.free_reg(result);

        // True branch
        ushort true_val = self.assignment_expr()!;
        self.emit_abc(Opcode.LDREG, (uint)result_reg, (uint)true_val, 0);
        self.free_reg(true_val);

        self.expect(TokenType.COLON)!;

        uint end_jump = self.emit_jump(Opcode.JUMP);
        self.patch_jump(false_jump);

        // False branch
        ushort false_val = self.assignment_expr()!;
        self.emit_abc(Opcode.LDREG, (uint)result_reg, (uint)false_val, 0);
        self.free_reg(false_val);

        self.patch_jump(end_jump);

        return result_reg;
    }

    return result;
}

/// Parse binary expressions using a Pratt parser with precedence climbing.
fn ushort? CompilerContext.binary_expr(&self, int min_prec) {
    ushort left = self.unary_expr()!;

    for (;;) {
        TokenType tt = self.peek_type();
        int prec = get_binary_precedence(tt);

        if (prec < min_prec) {
            break;
        }

        // Handle short-circuit operators specially
        if (tt == TokenType.LOG_AND) {
            self.advance()!;
            // Short-circuit: if left is falsy, skip right and result is left
            ushort result_reg = self.alloc_reg();
            self.emit_abc(Opcode.LDREG, (uint)result_reg, (uint)left, 0);
            uint skip_jump = self.emit_cond_jump(Opcode.IF_FALSE, (uint)result_reg);

            self.free_reg(left);
            ushort right = self.binary_expr(prec + 1)!;
            self.emit_abc(Opcode.LDREG, (uint)result_reg, (uint)right, 0);
            self.free_reg(right);

            self.patch_jump(skip_jump);
            left = result_reg;
            continue;
        }

        if (tt == TokenType.LOG_OR) {
            self.advance()!;
            // Short-circuit: if left is truthy, skip right and result is left
            ushort result_reg = self.alloc_reg();
            self.emit_abc(Opcode.LDREG, (uint)result_reg, (uint)left, 0);
            uint skip_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)result_reg);

            self.free_reg(left);
            ushort right = self.binary_expr(prec + 1)!;
            self.emit_abc(Opcode.LDREG, (uint)result_reg, (uint)right, 0);
            self.free_reg(right);

            self.patch_jump(skip_jump);
            left = result_reg;
            continue;
        }

        if (tt == TokenType.NULLISH) {
            self.advance()!;
            // Nullish coalescing: if left is not null/undefined, use left.
            // Can't use is_truthy (IF_TRUE) because falsy values like 0, false, ""
            // are NOT nullish. Check null and undefined explicitly:
            //   LDREG result, left
            //   LDNULL cmp
            //   SEQ cmp, result, cmp       ; cmp = (result == null)
            //   IF_TRUE cmp, +skip_right   ; if null, go to right
            //   LDUNDEF cmp
            //   SEQ cmp, result, cmp       ; cmp = (result == undefined)
            //   IF_TRUE cmp, +skip_right   ; if undefined, go to right
            //   JUMP after_right            ; not nullish, skip right
            // skip_right:
            //   LDREG result, right
            // after_right:
            ushort result_reg = self.alloc_reg();
            self.emit_abc(Opcode.LDREG, (uint)result_reg, (uint)left, 0);

            ushort cmp_reg = self.alloc_reg();
            // Check null
            self.emit_abc(Opcode.LDNULL, (uint)cmp_reg, 0, 0);
            self.emit_abc(Opcode.SEQ, (uint)cmp_reg, (uint)result_reg, (uint)cmp_reg);
            uint null_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)cmp_reg);
            // Check undefined
            self.emit_abc(Opcode.LDUNDEF, (uint)cmp_reg, 0, 0);
            self.emit_abc(Opcode.SEQ, (uint)cmp_reg, (uint)result_reg, (uint)cmp_reg);
            uint undef_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)cmp_reg);

            self.free_reg(cmp_reg);
            self.free_reg(left);

            // Not nullish — skip right side
            uint skip_jump = self.emit_jump(Opcode.JUMP);

            // Patch null and undefined jumps to here (right side)
            self.patch_jump(null_jump);
            self.patch_jump(undef_jump);

            ushort right = self.binary_expr(prec + 1)!;
            self.emit_abc(Opcode.LDREG, (uint)result_reg, (uint)right, 0);
            self.free_reg(right);

            self.patch_jump(skip_jump);
            left = result_reg;
            continue;
        }

        // Regular binary operator
        self.advance()!;

        // Right-to-left associativity for exponentiation
        int next_prec = prec + 1;
        if (tt == TokenType.STARSTAR) {
            next_prec = prec;  // right-associative
        }

        ushort right = self.binary_expr(next_prec)!;

        // Determine opcode
        Opcode op = token_to_binary_opcode(tt);

        // Emit the binary operation
        ushort result_reg = self.alloc_reg();
        self.emit_abc(op, (uint)result_reg, (uint)left, (uint)right);
        self.free_reg(right);
        self.free_reg(left);

        left = result_reg;
    }

    return left;
}

/// Parse a unary expression.
fn ushort? CompilerContext.unary_expr(&self) {
    TokenType tt = self.peek_type();

    switch (tt) {
        case TokenType.MINUS:
            self.advance()!;
            ushort operand = self.unary_expr()!;
            ushort result = self.alloc_reg();
            self.emit_abc(Opcode.UNM, (uint)result, (uint)operand, 0);
            self.free_reg(operand);
            return result;

        case TokenType.PLUS:
            self.advance()!;
            ushort op_plus = self.unary_expr()!;
            ushort res_plus = self.alloc_reg();
            self.emit_abc(Opcode.UNP, (uint)res_plus, (uint)op_plus, 0);
            self.free_reg(op_plus);
            return res_plus;

        case TokenType.LOG_NOT:
            self.advance()!;
            ushort op_not = self.unary_expr()!;
            ushort res_not = self.alloc_reg();
            self.emit_abc(Opcode.LNOT, (uint)res_not, (uint)op_not, 0);
            self.free_reg(op_not);
            return res_not;

        case TokenType.BIT_NOT:
            self.advance()!;
            ushort op_bnot = self.unary_expr()!;
            ushort res_bnot = self.alloc_reg();
            self.emit_abc(Opcode.BNOT, (uint)res_bnot, (uint)op_bnot, 0);
            self.free_reg(op_bnot);
            return res_bnot;

        case TokenType.TYPEOF:
            self.advance()!;
            ushort op_typeof = self.unary_expr()!;
            ushort res_typeof = self.alloc_reg();
            self.emit_abc(Opcode.TYPEOF, (uint)res_typeof, (uint)op_typeof, 0);
            self.free_reg(op_typeof);
            return res_typeof;

        case TokenType.VOID:
            self.advance()!;
            ushort op_void = self.unary_expr()!;
            ushort res_void = self.alloc_reg();
            self.emit_abc(Opcode.VOID, (uint)res_void, (uint)op_void, 0);
            self.free_reg(op_void);
            return res_void;

        case TokenType.DELETE:
            self.advance()!;
            // Simplified: delete of a simple expression
            ushort op_del = self.unary_expr()!;
            // For now, emit LDUNDEF as a placeholder
            ushort res_del = self.alloc_reg();
            self.emit_abc(Opcode.LDTRUE, (uint)res_del, 0, 0);
            self.free_reg(op_del);
            return res_del;

        case TokenType.INC:
            // Prefix ++
            self.advance()!;
            ushort op_inc = self.postfix_expr()!;
            ushort one_inc = self.alloc_reg();
            self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)one_inc, 1));
            self.emit_abc(Opcode.ADD, (uint)op_inc, (uint)op_inc, (uint)one_inc);
            self.free_reg(one_inc);
            return op_inc;

        case TokenType.DEC:
            // Prefix --
            self.advance()!;
            ushort op_dec = self.postfix_expr()!;
            ushort one_dec = self.alloc_reg();
            self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)one_dec, 1));
            self.emit_abc(Opcode.SUB, (uint)op_dec, (uint)op_dec, (uint)one_dec);
            self.free_reg(one_dec);
            return op_dec;

        case TokenType.NEW:
            return self.new_expr()!;

        default:
            return self.postfix_expr()!;
    }
}

/// Parse postfix expressions (++, --).
fn ushort? CompilerContext.postfix_expr(&self) {
    ushort operand = self.call_expr()!;

    TokenType tt = self.peek_type();
    if (tt == TokenType.INC) {
        self.advance()!;
        // Save original value
        ushort saved = self.alloc_reg();
        self.emit_abc(Opcode.LDREG, (uint)saved, (uint)operand, 0);

        // Increment the operand
        ushort one = self.alloc_reg();
        self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)one, 1));
        self.emit_abc(Opcode.ADD, (uint)operand, (uint)operand, (uint)one);
        self.free_reg(one);

        return saved;
    }

    if (tt == TokenType.DEC) {
        self.advance()!;
        // Save original value
        ushort saved = self.alloc_reg();
        self.emit_abc(Opcode.LDREG, (uint)saved, (uint)operand, 0);

        // Decrement the operand
        ushort one = self.alloc_reg();
        self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)one, 1));
        self.emit_abc(Opcode.SUB, (uint)operand, (uint)operand, (uint)one);
        self.free_reg(one);

        return saved;
    }

    return operand;
}

/// Parse call expressions: f(), f(a,b), obj.method(), obj[expr]().
fn ushort? CompilerContext.call_expr(&self) {
    ushort callee = self.member_expr()!;

    // If member_expr saved a property object but next token is not a call,
    // free the object register now.
    if (self.call_prop_obj_reg != MAX_REGISTERS && !self.check(TokenType.LPAREN)) {
        self.free_reg(self.call_prop_obj_reg);
        self.call_prop_obj_reg = MAX_REGISTERS;
    }

    for (;;) {
        if (self.check(TokenType.LPAREN)) {
            callee = self.emit_call(callee)!;
            // Free the property object used as 'this' (if any)
            if (self.call_prop_obj_reg != MAX_REGISTERS) {
                self.free_reg(self.call_prop_obj_reg);
                self.call_prop_obj_reg = MAX_REGISTERS;
            }
        } else if (self.match(TokenType.DOT)) {
            // Property access: callee.name
            Token prop_name = self.expect(TokenType.IDENTIFIER)!;
            uint prop_const = self.add_string_constant(prop_name.str_value);

            ushort prop_reg = self.alloc_reg();
            self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)prop_reg, prop_const));

            ushort result = self.alloc_reg();
            self.emit_abc(Opcode.GETPROP, (uint)result, (uint)callee, (uint)prop_reg);
            self.free_reg(prop_reg);

            // If next token is a call, keep the object alive for 'this'
            if (self.check(TokenType.LPAREN)) {
                self.call_prop_obj_reg = callee;
            } else {
                self.free_reg(callee);
            }
            callee = result;
        } else if (self.match(TokenType.LBRACKET)) {
            // Computed property access: callee[expr]
            ushort idx_reg = self.expression()!;
            self.expect(TokenType.RBRACKET)!;

            ushort result = self.alloc_reg();
            self.emit_abc(Opcode.GETPROP, (uint)result, (uint)callee, (uint)idx_reg);
            self.free_reg(idx_reg);

            // If next token is a call, keep the object alive for 'this'
            if (self.check(TokenType.LPAREN)) {
                self.call_prop_obj_reg = callee;
            } else {
                self.free_reg(callee);
            }
            callee = result;
        } else if (self.match(TokenType.OPT_CHAIN)) {
            // Optional chaining: callee?.prop or callee?.()
            // Simplified: treat as regular property access for now
            if (self.check(TokenType.LPAREN)) {
                callee = self.emit_call(callee)!;
            } else {
                Token prop_name = self.expect(TokenType.IDENTIFIER)!;
                uint prop_const = self.add_string_constant(prop_name.str_value);

                ushort prop_reg = self.alloc_reg();
                self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)prop_reg, prop_const));

                ushort result = self.alloc_reg();
                self.emit_abc(Opcode.GETPROP, (uint)result, (uint)callee, (uint)prop_reg);
                self.free_reg(prop_reg);
                self.free_reg(callee);
                callee = result;
            }
        } else {
            break;
        }
    }

    return callee;
}

/// Emit a function call for the callee in the given register.
///
/// Calling convention (matching original Duktape):
///   callee_reg + 0  = callee (function object)
///   callee_reg + 1  = arg 1
///   callee_reg + 2  = arg 2
///   ...
///   callee_reg + N  = arg N
///
/// The result is placed in a separate result register (A field).
/// The VM reads args from callee_reg + 1, so we must guarantee that layout.
fn ushort? CompilerContext.emit_call(&self, ushort callee_reg) {
    self.expect(TokenType.LPAREN)!;

    // Layout: callee_reg = func, callee_reg+1 = this, callee_reg+2.. callee_reg+1+nargs = args
    ushort first_arg = callee_reg + 2;

    // If the argument region overlaps with live registers (from an outer call),
    // move the callee to a free area first.  Otherwise an inner call's arg setup
    // would clobber live values (e.g. print(add(1,2)) clobbers print in r1).
    if (first_arg < self.next_reg) {
        ushort new_callee = self.next_reg;
        self.emit_abc(Opcode.LDREG, (uint)new_callee, (uint)callee_reg, 0);
        callee_reg = new_callee;
        first_arg = callee_reg + 2;
        // Account for the callee's new position so args don't overlap
        if (self.next_reg <= callee_reg + 1) {
            self.next_reg = callee_reg + 2;
        }
    }
    // Place undefined 'this' slot (or the property object for method calls)
    // DEBUG: check call_prop_obj_reg
    if (self.call_prop_obj_reg != MAX_REGISTERS) {
        // DEBUG: print the register number via stderr
        self.emit_abc(Opcode.LDREG, (uint)(callee_reg + 1), (uint)self.call_prop_obj_reg, 0);
        self.free_reg(self.call_prop_obj_reg);
        self.call_prop_obj_reg = MAX_REGISTERS;
    } else {
        self.emit_abc(Opcode.LDUNDEF, (uint)(callee_reg + 1), 0, 0);
    }
    if (self.next_reg < first_arg) {
        self.next_reg = first_arg;
    }

    // Compile arguments into consecutive registers starting at first_arg
    ushort arg_count = 0;

    if (!self.check(TokenType.RPAREN)) {
        for (;;) {
            ushort arg_reg = self.assignment_expr()!;
            // Ensure the argument is in the expected consecutive register
            ushort expected = first_arg + arg_count;
            if (arg_reg != expected) {
                self.emit_abc(Opcode.LDREG, (uint)expected, (uint)arg_reg, 0);
                self.free_reg(arg_reg);
            }
            arg_count++;

            if (!self.match(TokenType.COMMA)) {
                break;
            }
        }
    }

    self.expect(TokenType.RPAREN)!;

    // Emit CALL: A = result reg, B = callee reg, C = arg count
    // VM reads: callee = valstack[B], args = valstack[B+1 .. B+C]
    ushort result_reg = self.alloc_reg();
    self.emit_abc(Opcode.CALL, (uint)result_reg, (uint)callee_reg, (uint)arg_count);

    // Free argument registers (callee_reg itself stays allocated)
    self.free_regs_to(first_arg);
    // Re-allocate the result register
    if (result_reg >= self.next_reg) {
        self.next_reg = result_reg + 1;
        if (self.next_reg > self.max_reg) {
            self.max_reg = self.next_reg;
        }
    }

    return result_reg;
}

/// Parse new expression: new Constructor(args).
fn ushort? CompilerContext.new_expr(&self) {
    self.expect(TokenType.NEW)!;

    // Parse the constructor (could be member access)
    ushort ctor_reg = self.member_expr()!;

    // Args start right after constructor (same convention as emit_call)
    ushort first_arg = ctor_reg + 2;
    if (self.next_reg < first_arg) {
        self.next_reg = first_arg;
    }
    ushort arg_count = 0;

    if (self.match(TokenType.LPAREN)) {
        if (!self.check(TokenType.RPAREN)) {
            for (;;) {
                ushort arg_reg = self.assignment_expr()!;
                ushort expected = first_arg + arg_count;
                if (arg_reg != expected) {
                    self.emit_abc(Opcode.LDREG, (uint)expected, (uint)arg_reg, 0);
                    self.free_reg(arg_reg);
                }
                arg_count++;

                if (!self.match(TokenType.COMMA)) {
                    break;
                }
            }
        }
        self.expect(TokenType.RPAREN)!;
    }

    // Emit NEW_OBJ: result = new ctor(args...)
    ushort result_reg = self.alloc_reg();
    self.emit_abc(Opcode.NEW_OBJ, (uint)result_reg, (uint)ctor_reg, (uint)arg_count);

    self.free_regs_to(first_arg);
    if (result_reg >= self.next_reg) {
        self.next_reg = result_reg + 1;
        if (self.next_reg > self.max_reg) {
            self.max_reg = self.next_reg;
        }
    }

    return result_reg;
}

/// Parse member expression: property accesses and computed accesses.
fn ushort? CompilerContext.member_expr(&self) {
    ushort obj = self.primary_expr()!;

    for (;;) {
        if (self.match(TokenType.DOT)) {
            Token prop_name = self.expect(TokenType.IDENTIFIER)!;
            uint prop_const = self.add_string_constant(prop_name.str_value);

            ushort prop_reg = self.alloc_reg();
            self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)prop_reg, prop_const));

            // Always emit GETPROP
            ushort result = self.alloc_reg();
            self.emit_abc(Opcode.GETPROP, (uint)result, (uint)obj, (uint)prop_reg);

            if (self.lhs_mode) {
                // LHS mode: keep obj/prop alive for possible PUTPROP
                self.last_was_member = true;
                self.last_member_obj_reg = obj;
                self.last_member_prop_reg = prop_reg;
                // Also set up for potential method call 'this'
                if (self.peek_type() == TokenType.LPAREN) {
                    self.call_prop_obj_reg = obj;
                }
            } else {
                // RHS mode: free obj/prop immediately
                self.free_reg(prop_reg);
                // If next token is LPAREN, this is a method call.
                // Track the object for 'this' setup in emit_call.
                if (self.peek_type() == TokenType.LPAREN) {
                    self.call_prop_obj_reg = obj;
                } else {
                    self.free_reg(obj);
                }
            }
            obj = result;
        } else if (self.match(TokenType.LBRACKET)) {
            ushort idx_reg = self.expression()!;
            self.expect(TokenType.RBRACKET)!;

            ushort result = self.alloc_reg();
            self.emit_abc(Opcode.GETPROP, (uint)result, (uint)obj, (uint)idx_reg);

            if (self.lhs_mode) {
                self.last_was_member = true;
                self.last_member_obj_reg = obj;
                self.last_member_prop_reg = idx_reg;
                if (self.peek_type() == TokenType.LPAREN) {
                    self.call_prop_obj_reg = obj;
                }
            } else {
                self.free_reg(idx_reg);
                if (self.peek_type() == TokenType.LPAREN) {
                    self.call_prop_obj_reg = obj;
                } else {
                    self.free_reg(obj);
                }
            }
            obj = result;
        } else {
            break;
        }
    }

    return obj;
}

/// Parse primary expressions: literals, identifiers, grouping, etc.
fn ushort? CompilerContext.primary_expr(&self) {
    TokenType tt = self.peek_type();

    switch (tt) {
        case TokenType.NUMBER:
            self.last_was_getvar = false;
            Token num_tok = self.advance()!;
            ushort num_reg = self.alloc_reg();

            // Check if it fits in a signed 16-bit immediate
            double val = num_tok.num_value;
            int int_val = (int)val;
            if ((double)int_val == val && int_val >= bytecode::MIN_SBC && int_val <= bytecode::MAX_SBC) {
                self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)num_reg, int_val));
            } else {
                uint const_idx = self.add_number_constant(val);
                self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)num_reg, const_idx));
            }
            return num_reg;

        case TokenType.STRING:
            Token str_tok = self.advance()!;
            uint str_idx = self.add_string_constant(str_tok.str_value);
            ushort str_reg = self.alloc_reg();
            self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)str_reg, str_idx));
            return str_reg;

        case TokenType.IDENTIFIER:
            Token id_tok = self.advance()!;

            // Check for literal keywords tokenized as identifiers
            if (str_eq(id_tok.str_value, "true")) {
                self.last_was_getvar = false;
                ushort reg = self.alloc_reg();
                self.emit_abc(Opcode.LDTRUE, (uint)reg, 0, 0);
                return reg;
            }
            if (str_eq(id_tok.str_value, "false")) {
                self.last_was_getvar = false;
                ushort reg = self.alloc_reg();
                self.emit_abc(Opcode.LDFALSE, (uint)reg, 0, 0);
                return reg;
            }
            if (str_eq(id_tok.str_value, "null")) {
                self.last_was_getvar = false;
                ushort reg = self.alloc_reg();
                self.emit_abc(Opcode.LDNULL, (uint)reg, 0, 0);
                return reg;
            }
            if (str_eq(id_tok.str_value, "undefined")) {
                self.last_was_getvar = false;
                ushort reg = self.alloc_reg();
                self.emit_abc(Opcode.LDUNDEF, (uint)reg, 0, 0);
                return reg;
            }

            // Try to resolve as a local variable first (skip at global scope — use environment)
            if (!self.is_global) {
                if (try var_reg = self.resolve_var(id_tok.str_value)) {
                    self.last_was_getvar = false;
                    return var_reg;
                }
            }

            // Not found locally: emit GETVAR to look up by name at runtime
            uint name_idx = self.add_string_constant(id_tok.str_value);
            ushort id_reg = self.alloc_reg();
            self.emit(bytecode::make_a_bc(Opcode.GETVAR, (uint)id_reg, name_idx));
            self.last_was_getvar = true;
            self.last_getvar_name_idx = name_idx;
            return id_reg;

        case TokenType.THIS:
            self.advance()!;
            ushort this_reg = self.alloc_reg();
            self.emit_abc(Opcode.LDTHIS, (uint)this_reg, 0, 0);
            return this_reg;

        case TokenType.LPAREN:
            // Grouping expression
            self.advance()!;
            ushort inner = self.expression()!;
            self.expect(TokenType.RPAREN)!;
            return inner;

        case TokenType.LBRACE:
            return self.object_literal()!;

        case TokenType.LBRACKET:
            return self.array_literal()!;

        case TokenType.FUNCTION:
            return self.function_expr()!;

        case TokenType.TEMPLATE:
            Token tmpl_tok = self.advance()!;
            uint tmpl_idx = self.add_string_constant(tmpl_tok.str_value);
            ushort tmpl_reg = self.alloc_reg();
            self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)tmpl_reg, tmpl_idx));
            return tmpl_reg;

        default:
            // Check for literal keywords
            if (tt == TokenType.LET) {
                // 'let' used as identifier in non-strict mode
                Token let_tok = self.advance()!;
                if (try var_reg = self.resolve_var(let_tok.str_value)) {
                    return var_reg;
                }
                uint name_idx = self.add_string_constant(let_tok.str_value);
                ushort let_reg = self.alloc_reg();
                self.emit(bytecode::make_a_bc(Opcode.GETVAR, (uint)let_reg, name_idx));
                return let_reg;
            }
            return self.literal_keyword()!;
    }
}

/// Parse literal keyword values (true, false, null, undefined).
fn ushort? CompilerContext.literal_keyword(&self) {
    TokenType tt = self.peek_type();
    self.advance()!;

    ushort reg = self.alloc_reg();

    // Map certain keyword tokens to load instructions
    // The lexer produces these as keyword token types
    // We need to check the str_value for true/false/null/undefined
    // But those aren't separate token types in our lexer, so handle via
    // the token type directly:

    // Actually, looking at the lexer, true/false/null/undefined are
    // tokenized as IDENTIFIER tokens. Let's handle the case where
    // we reach here with an unexpected token.
    switch (tt) {
        default:
            // Emit LDUNDEF as a fallback for unrecognized primary expressions
            self.emit_abc(Opcode.LDUNDEF, (uint)reg, 0, 0);
    }

    return reg;
}

/// Parse object literal: { key: value, ... }
fn ushort? CompilerContext.object_literal(&self) {
    self.expect(TokenType.LBRACE)!;

    ushort obj_reg = self.alloc_reg();
    self.emit_abc(Opcode.NEWOBJ, (uint)obj_reg, 0, 0);

    if (!self.check(TokenType.RBRACE)) {
        for (;;) {
            if (self.check(TokenType.RBRACE)) {
                break;
            }

            // Parse property key
            ushort key_reg;

            TokenType key_tt = self.peek_type();
            if (key_tt == TokenType.IDENTIFIER || key_tt == TokenType.STRING) {
                Token key_tok = self.advance()!;
                uint key_idx = self.add_string_constant(key_tok.str_value);
                key_reg = self.alloc_reg();
                self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)key_reg, key_idx));
            } else if (key_tt == TokenType.NUMBER) {
                Token key_tok = self.advance()!;
                uint key_idx = self.add_number_constant(key_tok.num_value);
                key_reg = self.alloc_reg();
                self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)key_reg, key_idx));
            } else if (key_tt == TokenType.LBRACKET) {
                // Computed property key
                self.advance()!;
                key_reg = self.assignment_expr()!;
                self.expect(TokenType.RBRACKET)!;
            } else {
                return COMPILE_ERROR~;
            }

            // Check for getter/setter shorthand or method shorthand
            if (self.check(TokenType.LPAREN)) {
                // Method shorthand: key() { ... }
                ushort method_reg = self.function_expr_body()!;
                self.emit_abc(Opcode.PUTPROP, (uint)obj_reg, (uint)key_reg, (uint)method_reg);
                self.free_reg(method_reg);
                self.free_reg(key_reg);
            } else {
                // key: value
                self.expect(TokenType.COLON)!;
                ushort val_reg = self.assignment_expr()!;
                self.emit_abc(Opcode.PUTPROP, (uint)obj_reg, (uint)key_reg, (uint)val_reg);
                self.free_reg(val_reg);
                self.free_reg(key_reg);
            }

            if (!self.match(TokenType.COMMA)) {
                break;
            }
        }
    }

    self.expect(TokenType.RBRACE)!;
    return obj_reg;
}

/// Parse array literal: [ expr, expr, ... ]
fn ushort? CompilerContext.array_literal(&self) {
    self.expect(TokenType.LBRACKET)!;

    ushort arr_reg = self.alloc_reg();
    self.emit_abc(Opcode.NEWARR, (uint)arr_reg, 0, 0);

    uint index = 0;
    if (!self.check(TokenType.RBRACKET)) {
        for (;;) {
            if (self.check(TokenType.RBRACKET)) {
                break;
            }

            if (self.check(TokenType.COMMA)) {
                // Elision (hole in array)
                index++;
                self.advance()!;
                continue;
            }

            // Check for spread
            if (self.match(TokenType.ELLIPSIS)) {
                ushort spread_reg = self.assignment_expr()!;
                // Simplified: just store the spread value at the current index
                ushort idx_reg = self.alloc_reg();
                self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)idx_reg, (int)index));
                self.emit_abc(Opcode.PUTPROP, (uint)arr_reg, (uint)idx_reg, (uint)spread_reg);
                self.free_reg(idx_reg);
                self.free_reg(spread_reg);
                index++;
            } else {
                ushort elem_reg = self.assignment_expr()!;

                // Store element at index
                ushort idx_reg = self.alloc_reg();
                self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)idx_reg, (int)index));
                self.emit_abc(Opcode.PUTPROP, (uint)arr_reg, (uint)idx_reg, (uint)elem_reg);
                self.free_reg(idx_reg);
                self.free_reg(elem_reg);
                index++;
            }

            if (!self.match(TokenType.COMMA)) {
                break;
            }
        }
    }

    // Set array length
    self.emit(bytecode::make_a_bc(Opcode.SETALEN, (uint)arr_reg, index));

    self.expect(TokenType.RBRACKET)!;
    return arr_reg;
}

/// Parse a function expression: function name?(...) { ... }
fn ushort? CompilerContext.function_expr(&self) {
    self.expect(TokenType.FUNCTION)!;

    // Optional function name
    char[] name;
    if (self.check(TokenType.IDENTIFIER)) {
        Token name_tok = self.advance()!;
        name = name_tok.str_value;
    }

    // Compile the function body into a sub-context
    CompiledFunction* inner = self.compile_inner_function(name)!;

    // Add to inner functions table
    uint inner_idx = 0;
    if (self.inner_func_count < MAX_INNER_FUNCS) {
        inner_idx = self.inner_func_count;
        self.inner_funcs[inner_idx] = inner;
        self.inner_func_count++;
    }

    ushort result = self.alloc_reg();
    self.emit(bytecode::make_a_bc(Opcode.CLOSURE, (uint)result, inner_idx));
    return result;
}

/// Parse a function expression body (parameters + block) without the `function` keyword.
/// Used for method shorthand in object literals.
fn ushort? CompilerContext.function_expr_body(&self) {
    char[] name;  // anonymous
    CompiledFunction* inner = self.compile_inner_function(name)!;

    uint inner_idx = 0;
    if (self.inner_func_count < MAX_INNER_FUNCS) {
        inner_idx = self.inner_func_count;
        self.inner_funcs[inner_idx] = inner;
        self.inner_func_count++;
    }

    ushort result = self.alloc_reg();
    self.emit(bytecode::make_a_bc(Opcode.CLOSURE, (uint)result, inner_idx));
    return result;
}

// ============================================================================
// Precedence and opcode mapping helpers
// ============================================================================

/// Return the precedence of a binary operator token, or PREC_NONE if not a binary op.
fn int get_binary_precedence(TokenType tt) {
    switch (tt) {
        case TokenType.LOG_OR:      return PREC_LOGICAL_OR;
        case TokenType.LOG_AND:     return PREC_LOGICAL_AND;
        case TokenType.BIT_OR:      return PREC_BITWISE_OR;
        case TokenType.BIT_XOR:     return PREC_BITWISE_XOR;
        case TokenType.BIT_AND:     return PREC_BITWISE_AND;
        case TokenType.EQ:          return PREC_EQUALITY;
        case TokenType.NE:          return PREC_EQUALITY;
        case TokenType.SEQ:         return PREC_EQUALITY;
        case TokenType.SNE:         return PREC_EQUALITY;
        case TokenType.LT:          return PREC_RELATIONAL;
        case TokenType.GT:          return PREC_RELATIONAL;
        case TokenType.LE:          return PREC_RELATIONAL;
        case TokenType.GE:          return PREC_RELATIONAL;
        case TokenType.INSTANCEOF:  return PREC_RELATIONAL;
        case TokenType.IN:          return PREC_RELATIONAL;
        case TokenType.SHL:         return PREC_SHIFT;
        case TokenType.SHR:         return PREC_SHIFT;
        case TokenType.USHR:        return PREC_SHIFT;
        case TokenType.PLUS:        return PREC_ADDITIVE;
        case TokenType.MINUS:       return PREC_ADDITIVE;
        case TokenType.STAR:        return PREC_MULTIPLICATIVE;
        case TokenType.SLASH:       return PREC_MULTIPLICATIVE;
        case TokenType.PERCENT:     return PREC_MULTIPLICATIVE;
        case TokenType.STARSTAR:    return PREC_EXPONENTIATION;
        case TokenType.NULLISH:     return PREC_NULLISH;
        default:                    return PREC_NONE;
    }
}

/// Map a binary operator token type to the corresponding bytecode opcode.
fn Opcode token_to_binary_opcode(TokenType tt) {
    switch (tt) {
        case TokenType.PLUS:        return Opcode.ADD;
        case TokenType.MINUS:       return Opcode.SUB;
        case TokenType.STAR:        return Opcode.MUL;
        case TokenType.SLASH:       return Opcode.DIV;
        case TokenType.PERCENT:     return Opcode.MOD;
        case TokenType.STARSTAR:    return Opcode.EXP;
        case TokenType.BIT_AND:     return Opcode.BAND;
        case TokenType.BIT_OR:      return Opcode.BOR;
        case TokenType.BIT_XOR:     return Opcode.BXOR;
        case TokenType.SHL:         return Opcode.SHL;
        case TokenType.SHR:         return Opcode.SHR;
        case TokenType.USHR:        return Opcode.USHR;
        case TokenType.EQ:          return Opcode.EQ;
        case TokenType.NE:          return Opcode.NEQ;
        case TokenType.SEQ:         return Opcode.SEQ;
        case TokenType.SNE:         return Opcode.SNEQ;
        case TokenType.LT:          return Opcode.LT;
        case TokenType.LE:          return Opcode.LE;
        case TokenType.GT:          return Opcode.GT;
        case TokenType.GE:          return Opcode.GE;
        case TokenType.INSTANCEOF:  return Opcode.INSTANCEOF;
        case TokenType.IN:          return Opcode.IN;
        default:                    return Opcode.NOP;
    }
}

// ============================================================================
// String comparison helper
// ============================================================================

/// Compare two char slices for equality.
fn bool str_eq(char[] a, char[] b) {
    if (a.len != b.len) {
        return false;
    }
    if (a.len == 0) {
        return true;
    }
    for (usz i = 0; i < a.len; i++) {
        if (a[i] != b[i]) {
            return false;
        }
    }
    return true;
}

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
        // Scope markers have no register to free.
        if (top.kind != SCOPEMARK) {
            self.free_reg(top.reg);
        }
        self.scope_depth--;
    }
}

/// Push a scope marker to delimit block scope boundaries for duplicate
/// let/const detection.  The marker has no name and no register.
fn void CompilerContext.push_scope_marker(&self) {
    if (self.scope_depth < MAX_SCOPE_DEPTH) {
        self.scope_stack[self.scope_depth].name = (char[]){};
        self.scope_stack[self.scope_depth].reg = 0;
        self.scope_stack[self.scope_depth].kind = SCOPEMARK;
        self.scope_stack[self.scope_depth].is_captured = false;
        self.scope_depth++;
    }
}

/// Declare a variable in the current scope.
fn ushort CompilerContext.declare_var(&self, char[] name, ScopeKind kind) {
    ushort reg = self.alloc_reg();
    // Lexical bindings must survive env-elision when a closure can read them
    // through the env chain (see has_lexical_bindings in the elide/needs_env
    // gates).
    if (kind == LET || kind == CONST) {
        self.has_lexical_bindings = true;
    }
    // Push to scope_stack for all lexical declarations (even at global scope)
    // so duplicate let/const can be detected.  Var at global scope is still
    // hoisted to the function-scoped environment and doesn't need scope tracking.
    bool push_scope = !self.is_global || kind != VAR;
    if (push_scope && self.scope_depth < MAX_SCOPE_DEPTH) {
        self.scope_stack[self.scope_depth].name = name;
        self.scope_stack[self.scope_depth].reg = reg;
        self.scope_stack[self.scope_depth].kind = kind;
        self.scope_stack[self.scope_depth].is_captured = false;
        self.scope_depth++;
    }
    return reg;
}

/// Resolve a variable name to its register. Searches from innermost scope out.
/// Returns SCOPE_ERROR if not found or if the variable is captured (must go
/// through the environment chain instead of using a register).
fn ushort? CompilerContext.resolve_var(&self, char[] name) {
    // Search from top of scope stack backwards
    if (self.scope_depth == 0) {
        return SCOPE_ERROR~;
    }
    uint i = self.scope_depth;
    while (i > 0) {
        i--;
        if (str_eq(self.scope_stack[i].name, name)) {
            // If captured (e.g. shadowed by a let/const in an inner scope),
            // force environment lookup so the VM walks the lex_env chain.
            if (self.scope_stack[i].is_captured) {
                return SCOPE_ERROR~;
            }
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
            return self.scope_stack[i].kind == CONST;
        }
    }
    return false;
}

/// Check if a register is the slot of a declared local variable/let/const/param.
/// Returns true if the register holds a live local binding that must NOT be
/// freed by expression_statement (the binding outlives the expression).
fn bool CompilerContext.is_local_var_reg(&self, ushort reg) {
    if (self.scope_depth == 0) {
        return false;
    }
    for (uint i = 0; i < self.scope_depth; i++) {
        if (self.scope_stack[i].reg == reg) {
            return true;
        }
    }
    return false;
}

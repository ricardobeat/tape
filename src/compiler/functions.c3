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
// Function compilation
// ============================================================================

/// Parse function body (parameters and block) and compile into a nested context.
fn void? CompilerContext.parse_function_body(&self, bool is_expr) {
    // Parse parameter list
    self.expect(TokenType.LPAREN)!;
    ushort arg_count = 0;

    if (!self.check(TokenType.RPAREN)) {
        for (;;) {
            // Check for rest parameter
            if (self.match(TokenType.ELLIPSIS)) {
                Token rest_param = self.expect(TokenType.IDENTIFIER)!;
                if (self.is_strict && is_restricted_name(rest_param.str_value)) {
                    return COMPILE_ERROR~;
                }
                ushort rest_reg = self.declare_var(rest_param.str_value, VAR);
                uint rest_name_idx = self.add_string_constant(rest_param.str_value);
                self.emit_a_bc(Opcode.DECLVAR, (uint)rest_reg, rest_name_idx);
                arg_count++;
                self.has_rest = true;
                self.rest_formal_count = arg_count - 1;
                self.num_args = arg_count;
                // Rest parameter must be last
                break;
            }

            Token param = self.expect(TokenType.IDENTIFIER)!;
            if (self.is_strict && is_restricted_name(param.str_value)) {
                return COMPILE_ERROR~;
            }
            ushort param_reg = self.declare_var(param.str_value, VAR);
            uint param_name_idx = self.add_string_constant(param.str_value);
            // DECLVAR declares the parameter in the immediate var_env only.
            self.emit_a_bc(Opcode.DECLVAR, (uint)param_reg, param_name_idx);
            arg_count++;

            // Check for default value
            if (self.check(TokenType.ASSIGN)) {
                self.advance()!; // consume '='

                // Compile the default expression as an inner function
                CompiledFunction* default_func = self.compile_default_expr()!;

                // Add to inner functions table
                if (self.inner_func_count < MAX_INNER_FUNCS
                    && self.default_count < MAX_PARAMS) {
                    uint def_idx = self.inner_func_count;
                    self.inner_funcs[def_idx] = default_func;
                    self.defaults[self.default_count].param_reg = param_reg;
                    self.defaults[self.default_count].param_name_idx = param_name_idx;
                    self.defaults[self.default_count].default_func_idx = def_idx;
                    self.default_count++;
                    self.inner_func_count++;
                    self.has_closures = true;
                }
            }

            if (!self.match(TokenType.COMMA)) {
                break;
            }
        }
    }

    // Set num_args if not already set by rest parameter
    if (!self.has_rest) {
        self.num_args = arg_count;
    }

    self.expect(TokenType.RPAREN)!;

    // Push a function-level lexical scope for let/const at function top level.
    // This sits above the block-level PUSH_LEX emitted by block() so that
    // function-level let/const go into a scope that outlives inner blocks.
    // Skip when there are no default parameters (the only case that needs
    // a function-level scope distinct from the block scope).
    bool has_func_lex = self.default_count > 0;
    if (has_func_lex) {
        self.emit_simple(Opcode.PUSH_LEX);
    }

    // Emit default parameter checks (must run before body, after PUSH_LEX)
    for (ushort di = 0; di < self.default_count; di++) {
        ushort pr = self.defaults[di].param_reg;
        uint name_idx = self.defaults[di].param_name_idx;
        uint func_idx = self.defaults[di].default_func_idx;

        // Check if param != undefined; if so, skip default evaluation
        ushort undef_reg = self.alloc_reg();
        self.emit_abc(Opcode.LDUNDEF, (uint)undef_reg, 0, 0);
        ushort cmp_reg = self.alloc_reg();
        self.emit_abc(Opcode.SNEQ, (uint)cmp_reg, (uint)pr, (uint)undef_reg);
        self.free_reg(undef_reg);

        // IF_TRUE: skip past default evaluation (will be patched)
        uint skip_addr = self.code_count;
        self.emit(bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cmp_reg, 0));
        self.free_reg(cmp_reg);

        // CLOSURE for default function
        ushort closure_reg = self.alloc_reg();
        self.emit_a_bc(Opcode.CLOSURE, (uint)closure_reg, func_idx);

        // Set up call: consecutive registers for callee + this
        ushort call_base = self.alloc_reg();
        if (self.next_reg <= call_base + 1) {
            self.next_reg = call_base + 2;
        }
        ushort this_reg = self.alloc_reg();
        self.emit_abc(Opcode.LDREG, (uint)call_base, (uint)closure_reg, 0);
        self.emit_abc(Opcode.LDTHIS, (uint)(call_base + 1), 0, 0);

        self.emit_abc(Opcode.CALL, (uint)call_base, (uint)call_base, 0);

        // Copy result directly to the parameter register.
        // Also update the environment so closures can access the value.
        // GETVAR reloads from env to pr in case PUTVAR cleared it.
        self.emit_abc(Opcode.LDREG, (uint)pr, (uint)call_base, 0);
        self.emit_a_bc(Opcode.PUTVAR, (uint)pr, name_idx);
        self.emit_a_bc(Opcode.GETVAR, (uint)pr, name_idx);

        self.free_regs_to(call_base);

        // Patch the skip jump to land after default evaluation
        int skip_off = (int)self.code_count - (int)skip_addr - 1;
        self.code[skip_addr] = bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cmp_reg, skip_off);
    }

    // Compile function body block
    self.block(true)!;

    // Pop the function-level lexical scope.
    // NOTE: for functions with explicit return, this POP_LEX won't execute,
    // but that's harmless — the activation is destroyed on return.
    if (has_func_lex) {
        self.emit_simple(Opcode.POP_LEX);
    }

    // Emit implicit return undefined if no explicit return
    // Check if last instruction is a return
    bool has_return = false;
    if (self.code_count > 0) {
        Opcode last_op = self.code[self.code_count - 1].op;
        if (last_op == Opcode.RET || last_op == Opcode.RETUNDEF ||
            last_op == Opcode.RET_GEN || last_op == Opcode.RETUNDEF_GEN) {
            has_return = true;
        }
    }
    if (!has_return) {
        self.emit_simple(self.is_generator ? Opcode.RETUNDEF_GEN : Opcode.RETUNDEF);
    }
}

/// Compile a default parameter expression as a zero-argument inner function.
/// Free variables in the expression are resolved at runtime via GETVAR
/// against the outer scope's environment chain.
fn CompiledFunction*? CompilerContext.compile_default_expr(&self) {
    // Create a new CompilerContext for the default expression
    CompilerContext def_ctx;
    def_ctx.init(self.lexer, self.heap);

    // Strict-only engine: always strict
    def_ctx.is_strict = true;
    def_ctx.lexer.set_strict(true);

    // Propagate class context (for super expressions)
    def_ctx.in_class_body = self.in_class_body;
    def_ctx.has_super_binding = self.has_super_binding;

    // Function-level lexical scope (empty — no parameters)
    def_ctx.emit_simple(Opcode.PUSH_LEX);

    // Compile expression with implicit return
    ushort expr_reg = def_ctx.assignment_expr()!;
    def_ctx.emit_a_bc(Opcode.RET, (uint)expr_reg, 0);

    // Pop the function-level lexical scope
    def_ctx.emit_simple(Opcode.POP_LEX);

    CompiledFunction* func = def_ctx.finish()!;

    return func;
}

/// Compile a computed property key expression into a 0-arg inner function.
/// The caller must have already consumed the `[` token.
/// This function compiles the expression and `]` is consumed by the caller after.
fn CompiledFunction*? CompilerContext.compile_key_expr(&self) {
    CompilerContext key_ctx;
    key_ctx.init(self.lexer, self.heap);
    key_ctx.is_strict = true;
    key_ctx.lexer.set_strict(true);
    key_ctx.in_class_body = self.in_class_body;
    key_ctx.has_super_binding = self.has_super_binding;

    key_ctx.emit_simple(Opcode.PUSH_LEX);
    ushort expr_reg = key_ctx.assignment_expr()!;
    key_ctx.emit_a_bc(Opcode.RET, (uint)expr_reg, 0);
    key_ctx.emit_simple(Opcode.POP_LEX);

    CompiledFunction* func = key_ctx.finish()!;
    return func;
}

/// Compile an inner function (parameters + body) into a sub-CompiledFunction.
fn CompiledFunction*? CompilerContext.compile_inner_function(&self, char[] name) {
    // Create a new CompilerContext for the inner function
    CompilerContext inner_ctx;
    inner_ctx.init(self.lexer, self.heap);

    // Strict-only engine: always strict, no propagation needed
    inner_ctx.is_strict = true;
    inner_ctx.lexer.set_strict(true);

    // Propagate generator flag: if the caller is compiling a generator,
    // the inner context (which parses the body) needs to know it's in a generator.
    inner_ctx.is_generator = self.is_generator;

    // Propagate class context (for super expressions)
    inner_ctx.in_class_body = self.in_class_body;
    inner_ctx.has_super_binding = self.has_super_binding;

    // Parse parameter list
    inner_ctx.expect(TokenType.LPAREN)!;
    ushort arg_count = 0;

    if (!inner_ctx.check(TokenType.RPAREN)) {
        for (;;) {
            // Check for rest parameter
            if (inner_ctx.match(TokenType.ELLIPSIS)) {
                Token rest_param = inner_ctx.expect(TokenType.IDENTIFIER)!;
                if (inner_ctx.is_strict && is_restricted_name(rest_param.str_value)) {
                    return COMPILE_ERROR~;
                }
                ushort rest_reg = inner_ctx.declare_var(rest_param.str_value, VAR);
                uint rest_name_idx = inner_ctx.add_string_constant(rest_param.str_value);
                inner_ctx.emit_a_bc(Opcode.DECLVAR, (uint)rest_reg, rest_name_idx);
                arg_count++;
                inner_ctx.has_rest = true;
                inner_ctx.rest_formal_count = arg_count - 1;
                inner_ctx.num_args = arg_count;
                // Rest parameter must be last
                break;
            }

            Token param = inner_ctx.expect(TokenType.IDENTIFIER)!;
            if (inner_ctx.is_strict && is_restricted_name(param.str_value)) {
                return COMPILE_ERROR~;
            }
            ushort param_reg = inner_ctx.declare_var(param.str_value, VAR);
            // Store parameter in the immediate var_env only (DECLVAR).
            uint param_name_idx = inner_ctx.add_string_constant(param.str_value);
            inner_ctx.emit_a_bc(Opcode.DECLVAR, (uint)param_reg, param_name_idx);
            arg_count++;

            // Check for default value
            if (inner_ctx.check(TokenType.ASSIGN)) {
                inner_ctx.advance()!; // consume '='

                // Compile the default expression as an inner function
                CompiledFunction* default_func = inner_ctx.compile_default_expr()!;

                // Add to inner functions table
                if (inner_ctx.inner_func_count < MAX_INNER_FUNCS
                    && inner_ctx.default_count < MAX_PARAMS) {
                    uint def_idx = inner_ctx.inner_func_count;
                    inner_ctx.inner_funcs[def_idx] = default_func;
                    inner_ctx.defaults[inner_ctx.default_count].param_reg = param_reg;
                    inner_ctx.defaults[inner_ctx.default_count].param_name_idx = param_name_idx;
                    inner_ctx.defaults[inner_ctx.default_count].default_func_idx = def_idx;
                    inner_ctx.default_count++;
                    inner_ctx.inner_func_count++;
                }
            }

            if (!inner_ctx.match(TokenType.COMMA)) {
                break;
            }
        }
    }

    // Set num_args if not already set by rest parameter
    if (!inner_ctx.has_rest) {
        inner_ctx.num_args = arg_count;
    }

    inner_ctx.expect(TokenType.RPAREN)!;

    // Push a function-level lexical scope for let/const at function top level.
    // Skip when there are no default parameters.
    bool inner_has_func_lex = inner_ctx.default_count > 0;
    if (inner_has_func_lex) {
        inner_ctx.emit_simple(Opcode.PUSH_LEX);
    }

    // Emit default parameter checks (must run before body, after PUSH_LEX)
    for (ushort di = 0; di < inner_ctx.default_count; di++) {
        ushort pr = inner_ctx.defaults[di].param_reg;
        uint name_idx = inner_ctx.defaults[di].param_name_idx;
        uint func_idx = inner_ctx.defaults[di].default_func_idx;

        // Check if param != undefined; if so, skip default evaluation
        ushort undef_reg = inner_ctx.alloc_reg();
        inner_ctx.emit_abc(Opcode.LDUNDEF, (uint)undef_reg, 0, 0);
        ushort cmp_reg = inner_ctx.alloc_reg();
        inner_ctx.emit_abc(Opcode.SNEQ, (uint)cmp_reg, (uint)pr, (uint)undef_reg);
        inner_ctx.free_reg(undef_reg);

        // IF_TRUE: skip past default evaluation (will be patched)
        uint skip_addr = inner_ctx.code_count;
        inner_ctx.emit(bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cmp_reg, 0));
        inner_ctx.free_reg(cmp_reg);

        // CLOSURE for default function
        ushort closure_reg = inner_ctx.alloc_reg();
        inner_ctx.emit_a_bc(Opcode.CLOSURE, (uint)closure_reg, func_idx);

        // Set up call: consecutive registers for callee + this
        ushort call_base = inner_ctx.alloc_reg();
        if (inner_ctx.next_reg <= call_base + 1) {
            inner_ctx.next_reg = call_base + 2;
        }
        ushort this_reg = inner_ctx.alloc_reg();
        inner_ctx.emit_abc(Opcode.LDREG, (uint)call_base, (uint)closure_reg, 0);
        inner_ctx.emit_abc(Opcode.LDTHIS, (uint)(call_base + 1), 0, 0);

        inner_ctx.emit_abc(Opcode.CALL, (uint)call_base, (uint)call_base, 0);

        // Assign result to parameter register and sync to environment
        inner_ctx.emit_abc(Opcode.LDREG, (uint)pr, (uint)call_base, 0);
        inner_ctx.emit_a_bc(Opcode.PUTVAR, (uint)pr, name_idx);

        inner_ctx.free_regs_to(call_base);

        // Patch the skip jump to land after default evaluation
        int skip_off = (int)inner_ctx.code_count - (int)skip_addr - 1;
        inner_ctx.code[skip_addr] = bytecode::make_a_sbx(Opcode.IF_TRUE, (uint)cmp_reg, skip_off);
    }

    // Compile function body
    inner_ctx.block(true)!;

    // Pop the function-level lexical scope
    if (inner_has_func_lex) {
        inner_ctx.emit_simple(Opcode.POP_LEX);
    }

    // Add implicit return undefined
    bool has_return = false;
    if (inner_ctx.code_count > 0) {
        Opcode last_op = inner_ctx.code[inner_ctx.code_count - 1].op;
        if (last_op == Opcode.RET || last_op == Opcode.RETUNDEF ||
            last_op == Opcode.RET_GEN || last_op == Opcode.RETUNDEF_GEN) {
            has_return = true;
        }
    }
    if (!has_return) {
        inner_ctx.emit_simple(inner_ctx.is_generator ? Opcode.RETUNDEF_GEN : Opcode.RETUNDEF);
    }

    CompiledFunction* func = inner_ctx.finish()!;

    // Set function name
    if (name.len > 0) {
        func.name_ptr = name.ptr;
        func.name_len = (uint)name.len;
    }

    return func;
}

/// Parse a function expression: function name?(...) { ... }
fn ushort? CompilerContext.function_expr(&self) {
    self.expect(TokenType.FUNCTION)!;

    // Save and reset generator state
    bool saved_is_generator = self.is_generator;
    self.is_generator = false;

    // Check for generator star: function* name?() {}
    if (self.match(TokenType.STAR)) {
        self.is_generator = true;
    }

    // Optional function name
    char[] name;
    if (self.check(TokenType.IDENTIFIER)) {
        Token name_tok = self.advance()!;
        name = name_tok.str_value;
    }

    // Compile the function body into a sub-context
    CompiledFunction* inner = self.compile_inner_function(name)!;

    // Restore generator flag
    self.is_generator = saved_is_generator;

    // Add to inner functions table
    uint inner_idx = 0;
    if (self.inner_func_count < MAX_INNER_FUNCS) {
        inner_idx = self.inner_func_count;
        self.inner_funcs[inner_idx] = inner;
        self.inner_func_count++;
        self.has_closures = true;
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
        self.has_closures = true;
    }

    ushort result = self.alloc_reg();
    self.emit(bytecode::make_a_bc(Opcode.CLOSURE, (uint)result, inner_idx));
    return result;
}

/// Parse an arrow function: `(params) => expr` or `(params) => { body }`
/// or `param => expr`.  The caller has already consumed the leading `(`
/// or the single identifier.
///
/// `params`: pre-parsed parameter name slices (pointer to first element).
/// `param_count`: number of parameters.
fn ushort? CompilerContext.parse_arrow_function(&self, char[]* params, ushort param_count, bool has_rest) {
    // Consume the ARROW token
    self.expect(TokenType.ARROW)!;

    // Create inner CompiledFunction for the arrow
    CompiledFunction* inner = self.compile_arrow_inner(params, param_count, has_rest)!;

    // Add to inner functions table
    uint inner_idx = 0;
    if (self.inner_func_count < MAX_INNER_FUNCS) {
        inner_idx = self.inner_func_count;
        self.inner_funcs[inner_idx] = inner;
        self.inner_func_count++;
        self.has_closures = true;
    }

    ushort result = self.alloc_reg();
    self.emit(bytecode::make_a_bc(Opcode.CLOSURE, (uint)result, inner_idx));
    return result;
}

/// Compile an inner arrow function given its parameter names.
/// Arrow functions have `is_arrow = true`, lexical `this`, and no `.prototype`.
fn CompiledFunction*? CompilerContext.compile_arrow_inner(&self, char[]* params, ushort param_count, bool has_rest) {
    // Create a new CompilerContext for the arrow function
    CompilerContext arrow_ctx;
    arrow_ctx.init(self.lexer, self.heap);

    // Strict-only engine: always strict
    arrow_ctx.is_strict = true;
    arrow_ctx.lexer.set_strict(true);

    // Arrow functions use the parent scope — no fresh env needed.
    arrow_ctx.is_arrow = true;

    // Propagate class context (for super expressions)
    arrow_ctx.in_class_body = self.in_class_body;
    arrow_ctx.has_super_binding = self.has_super_binding;

    // Register parameters
    ushort formal_count = param_count;
    if (has_rest && param_count > 0) {
        formal_count = param_count - 1;
    }
    for (ushort i = 0; i < param_count; i++) {
        char[] name = params[i];
        if (arrow_ctx.is_strict && is_restricted_name(name)) {
            return COMPILE_ERROR~;
        }
        ushort param_reg = arrow_ctx.declare_var(name, VAR);
        uint param_name_idx = arrow_ctx.add_string_constant(name);
        arrow_ctx.emit_a_bc(Opcode.DECLVAR, (uint)param_reg, param_name_idx);
    }

    // Push a function-level lexical scope
    arrow_ctx.emit_simple(Opcode.PUSH_LEX);

    // Determine if body is block or expression
    if (arrow_ctx.check(TokenType.LBRACE)) {
        // Block body: { ... }
        arrow_ctx.advance()!;
        while (!arrow_ctx.check(TokenType.RBRACE) && !arrow_ctx.is_at_end()) {
            arrow_ctx.statement()!;
        }
        arrow_ctx.expect(TokenType.RBRACE)!;
        // No implicit return for block body
        bool has_explicit_return = false;
        if (arrow_ctx.code_count > 0) {
            Opcode last_op = arrow_ctx.code[arrow_ctx.code_count - 1].op;
            if (last_op == Opcode.RET || last_op == Opcode.RETUNDEF ||
                last_op == Opcode.RET_GEN || last_op == Opcode.RETUNDEF_GEN) {
                has_explicit_return = true;
            }
        }
        if (!has_explicit_return) {
            arrow_ctx.emit_simple(Opcode.RETUNDEF);
        }
    } else {
        // Expression body: implicitly return the expression value
        ushort expr_reg = arrow_ctx.assignment_expr()!;
        arrow_ctx.emit_a_bc(Opcode.RET, (uint)expr_reg, 0);
    }

    // Pop the function-level lexical scope
    arrow_ctx.emit_simple(Opcode.POP_LEX);

    // Set rest and formal counts before finish()
    arrow_ctx.has_rest = has_rest;
    arrow_ctx.rest_formal_count = formal_count;
    arrow_ctx.num_args = param_count;

    CompiledFunction* func = arrow_ctx.finish()!;
    func.flags.is_arrow = true;

    return func;
}

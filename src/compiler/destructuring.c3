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
// Destructuring patterns (array and object)
// ============================================================================

/// Parse array destructuring pattern: [a, b, ...rest] = rhs
/// The '[' has already been consumed.
fn void? CompilerContext.array_destructure(&self, ScopeKind kind, bool is_lexical, bool is_const) {
    ArrayBind[32] binds;
    uint bind_count = 0;

    // Parse pattern elements, declaring each binding as we go
    for (;;) {
        if (self.check(TokenType.RBRACKET)) break;

        if (self.check(TokenType.COMMA)) {
            self.advance()!;
            if (bind_count < 32) {
                binds[bind_count].is_hole = true;
                binds[bind_count].has_default = false;
                bind_count++;
            }
            continue;
        }

        if (self.match(TokenType.ELLIPSIS)) {
            Token rest_tok = self.expect(TokenType.IDENTIFIER)!;
            if (is_restricted_name(rest_tok.str_value)) return COMPILE_ERROR~;
            if (bind_count < 32) {
                ushort reg = self.declare_var(rest_tok.str_value, kind);
                binds[bind_count].reg = reg;
                binds[bind_count].name_idx = self.add_string_constant(rest_tok.str_value);
                binds[bind_count].is_rest = true;
                binds[bind_count].is_hole = false;
                binds[bind_count].has_default = false;
                bind_count++;
            }
            while (self.match(TokenType.COMMA)) {}
            break;
        }

        // Check for nested pattern
        if (self.check(TokenType.LBRACKET)) {
            // Nested array pattern: [a, [b, c]] = rhs
            self.advance()!; // consume '['
            // For nested patterns, we create a temp variable and recursively destructure
            // We'll handle this by parsing the inner bindings and later destructure from temp reg
            // For now, just parse as identifier (simple case)
            Token name_tok = self.expect(TokenType.IDENTIFIER)!;
            if (is_restricted_name(name_tok.str_value)) return COMPILE_ERROR~;
            if (bind_count < 32) {
                ushort reg = self.declare_var(name_tok.str_value, kind);
                binds[bind_count].reg = reg;
                binds[bind_count].name_idx = self.add_string_constant(name_tok.str_value);
                binds[bind_count].is_rest = false;
                binds[bind_count].is_hole = false;
                binds[bind_count].has_default = false;
                bind_count++;
            }
            self.expect(TokenType.RBRACKET)!;
        } else if (self.check(TokenType.LBRACE)) {
            // Nested object pattern: [a, {x, y}] = rhs
            self.advance()!; // consume '{'
            Token name_tok = self.expect(TokenType.IDENTIFIER)!;
            if (is_restricted_name(name_tok.str_value)) return COMPILE_ERROR~;
            if (bind_count < 32) {
                ushort reg = self.declare_var(name_tok.str_value, kind);
                binds[bind_count].reg = reg;
                binds[bind_count].name_idx = self.add_string_constant(name_tok.str_value);
                binds[bind_count].is_rest = false;
                binds[bind_count].is_hole = false;
                binds[bind_count].has_default = false;
                bind_count++;
            }
            self.expect(TokenType.RBRACE)!;
        } else {
            Token name_tok = self.expect(TokenType.IDENTIFIER)!;
            if (is_restricted_name(name_tok.str_value)) return COMPILE_ERROR~;
            if (bind_count < 32) {
                ushort reg = self.declare_var(name_tok.str_value, kind);
                binds[bind_count].reg = reg;
                binds[bind_count].name_idx = self.add_string_constant(name_tok.str_value);
                binds[bind_count].is_rest = false;
                binds[bind_count].is_hole = false;
                binds[bind_count].has_default = false;

                // Check for default: a = expr
                if (self.match(TokenType.ASSIGN)) {
                    binds[bind_count].has_default = true;
                    // Compile the default expression into a temp register
                    binds[bind_count].default_val_reg = self.assignment_expr()!;
                }

                bind_count++;
            }
        }

        if (!self.match(TokenType.COMMA)) break;
    }

    self.expect(TokenType.RBRACKET)!;

    // Default to undefined if no initializer
    if (!self.match(TokenType.ASSIGN)) {
        for (uint i = 0; i < bind_count; i++) {
            if (binds[i].is_hole) continue;
            self.emit_abc(Opcode.LDUNDEF, (uint)binds[i].reg, 0, 0);
            self.emit_var_store(binds[i].reg, binds[i].name_idx, is_lexical, is_const);
        }
        return;
    }

    // Evaluate RHS (after all bindings declared, so their regs are below RHS regs)
    ushort rhs_reg = self.assignment_expr()!;

    // Emit code for each binding: get property from RHS, store in binding reg
    for (uint i = 0; i < bind_count; i++) {
        if (binds[i].is_hole) continue;

        if (binds[i].is_rest) {
            // Rest element: call rhs.slice(rest_idx)
            // This creates a new array with elements from index rest_idx onward

            // Find the index of this rest element (count non-hole elements before it)
            uint rest_idx = 0;
            for (uint j = 0; j < i; j++) {
                if (!binds[j].is_hole) rest_idx++;
            }

            // Method call setup
            // CALL convention: callee at callee_reg, this at callee_reg+1, args at callee_reg+2..
            ushort callee_reg = self.alloc_reg();
            // Ensure the call area (callee, this, args) is above next_reg
            if (self.next_reg < callee_reg + 3) {
                self.next_reg = callee_reg + 3;
            }

            // Get "slice" method from rhs
            ushort slice_key_reg = self.alloc_reg();
            uint slice_key_idx = self.add_string_constant("slice");
            self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)slice_key_reg, slice_key_idx));
            ushort method_reg = self.alloc_reg();
            self.emit_abc(Opcode.GETPROP, (uint)method_reg, (uint)rhs_reg, (uint)slice_key_reg);

            // Move method to callee_reg (CALL reads function from callee_reg)
            self.emit_abc(Opcode.LDREG, (uint)callee_reg, (uint)method_reg, 0);

            // this = rhs at callee_reg + 1 (CALL reads 'this' from here)
            self.emit_abc(Opcode.LDREG, (uint)(callee_reg + 1), (uint)rhs_reg, 0);

            // arg = rest_idx at callee_reg + 2 (CALL reads args from here)
            self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)(callee_reg + 2), (int)rest_idx));

            // Call: rhs.slice(rest_idx)
            self.emit_abc(Opcode.CALL, (uint)callee_reg, (uint)callee_reg, 1);

            // Store result into binding register (result is in callee_reg after CALL)
            self.emit_abc(Opcode.LDREG, (uint)binds[i].reg, (uint)callee_reg, 0);

            // Free call area + temp regs (callee_reg, this, arg, slice_key, method)
            // All of these are above callee_reg, so free_regs_to handles them.
            // binds[i].reg is below callee_reg, so it survives.
            self.free_regs_to(callee_reg);
        } else {
            // Regular element: GETPROP rhs[i] → bind_reg
            ushort idx_reg = self.alloc_reg();
            self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)idx_reg, (int)i));
            self.emit_abc(Opcode.GETPROP, (uint)binds[i].reg, (uint)rhs_reg, (uint)idx_reg);
            self.free_reg(idx_reg);

            // Apply default if present: if value is undefined, use default
            if (binds[i].has_default) {
                // Check if value is undefined
                ushort undef_check_reg = self.alloc_reg();
                self.emit_abc(Opcode.LDUNDEF, (uint)undef_check_reg, 0, 0);
                ushort is_undef_reg = self.alloc_reg();
                self.emit_abc(Opcode.SEQ, (uint)is_undef_reg, (uint)binds[i].reg, (uint)undef_check_reg);
                self.free_reg(undef_check_reg);

                // If not undefined, jump over default
                uint skip_default = self.emit_cond_jump(Opcode.IF_FALSE, (uint)is_undef_reg);
                self.free_reg(is_undef_reg);

                // Load default value
                self.emit_abc(Opcode.LDREG, (uint)binds[i].reg, (uint)binds[i].default_val_reg, 0);

                // Patch jump
                self.patch_jump(skip_default);

                // Free the default value register
                self.free_reg(binds[i].default_val_reg);
            }
        }

        self.emit_var_store(binds[i].reg, binds[i].name_idx, is_lexical, is_const);
    }

    self.free_reg(rhs_reg);
}

/// Parse object destructuring pattern: {a, b: c, x = default} = rhs
/// The '{' has already been consumed.
fn void? CompilerContext.object_destructure(&self, ScopeKind kind, bool is_lexical, bool is_const) {
    ObjBind[32] binds;
    uint bind_count = 0;

    if (!self.check(TokenType.RBRACE)) {
        for (;;) {
            // Check for nested patterns first
            if (self.check(TokenType.LBRACE)) {
                // Nested object pattern: {a: {x, y}} = rhs
                self.advance()!; // consume '{'
                // Parse the nested binding name
                Token bind_tok = self.expect(TokenType.IDENTIFIER)!;
                if (is_restricted_name(bind_tok.str_value)) return COMPILE_ERROR~;

                // Check for colon (key: pattern) or just shorthand
                if (self.match(TokenType.COLON)) {
                    // Check if nested value is a pattern or simple identifier
                    if (self.check(TokenType.LBRACE)) {
                        self.advance()!; // consume '{'
                        // Parse nested object pattern
                        Token nested_name = self.expect(TokenType.IDENTIFIER)!;
                        if (is_restricted_name(nested_name.str_value)) return COMPILE_ERROR~;
                        if (bind_count < 32) {
                            ushort reg = self.declare_var(nested_name.str_value, kind);
                            binds[bind_count].reg = reg;
                            binds[bind_count].name_idx = self.add_string_constant(nested_name.str_value);
                            binds[bind_count].key_idx = self.add_string_constant(bind_tok.str_value);
                            binds[bind_count].has_default = false;
                            bind_count++;
                        }
                        // Parse remaining nested properties
                        while (self.match(TokenType.COMMA)) {
                            if (self.check(TokenType.RBRACE)) break;
                            Token nested_prop = self.expect(TokenType.IDENTIFIER)!;
                            if (is_restricted_name(nested_prop.str_value)) return COMPILE_ERROR~;
                            if (self.match(TokenType.COLON)) {
                                Token nested_bind = self.expect(TokenType.IDENTIFIER)!;
                                if (is_restricted_name(nested_bind.str_value)) return COMPILE_ERROR~;
                                if (bind_count < 32) {
                                    ushort reg = self.declare_var(nested_bind.str_value, kind);
                                    binds[bind_count].reg = reg;
                                    binds[bind_count].name_idx = self.add_string_constant(nested_bind.str_value);
                                    binds[bind_count].key_idx = self.add_string_constant(nested_prop.str_value);
                                    binds[bind_count].has_default = false;
                                    bind_count++;
                                }
                            } else {
                                if (bind_count < 32) {
                                    ushort reg = self.declare_var(nested_prop.str_value, kind);
                                    binds[bind_count].reg = reg;
                                    binds[bind_count].name_idx = self.add_string_constant(nested_prop.str_value);
                                    binds[bind_count].key_idx = self.add_string_constant(nested_prop.str_value);
                                    binds[bind_count].has_default = false;
                                    bind_count++;
                                }
                            }
                        }
                        self.expect(TokenType.RBRACE)!;
                    } else if (self.check(TokenType.LBRACKET)) {
                        self.advance()!; // consume '['
                        Token nested_name = self.expect(TokenType.IDENTIFIER)!;
                        if (is_restricted_name(nested_name.str_value)) return COMPILE_ERROR~;
                        if (bind_count < 32) {
                            ushort reg = self.declare_var(nested_name.str_value, kind);
                            binds[bind_count].reg = reg;
                            binds[bind_count].name_idx = self.add_string_constant(nested_name.str_value);
                            binds[bind_count].key_idx = self.add_string_constant(bind_tok.str_value);
                            binds[bind_count].has_default = false;
                            bind_count++;
                        }
                        // Parse remaining array elements
                        while (self.match(TokenType.COMMA)) {
                            if (self.check(TokenType.RBRACKET)) break;
                            Token nested_el = self.expect(TokenType.IDENTIFIER)!;
                            if (is_restricted_name(nested_el.str_value)) return COMPILE_ERROR~;
                            if (bind_count < 32) {
                                ushort reg = self.declare_var(nested_el.str_value, kind);
                                binds[bind_count].reg = reg;
                                binds[bind_count].name_idx = self.add_string_constant(nested_el.str_value);
                                binds[bind_count].key_idx = self.add_string_constant(nested_el.str_value);
                                binds[bind_count].has_default = false;
                                bind_count++;
                            }
                        }
                        self.expect(TokenType.RBRACKET)!;
                    } else {
                        // Simple key: value
                        Token val_tok = self.expect(TokenType.IDENTIFIER)!;
                        if (is_restricted_name(val_tok.str_value)) return COMPILE_ERROR~;
                        if (bind_count < 32) {
                            ushort reg = self.declare_var(val_tok.str_value, kind);
                            binds[bind_count].reg = reg;
                            binds[bind_count].name_idx = self.add_string_constant(val_tok.str_value);
                            binds[bind_count].key_idx = self.add_string_constant(bind_tok.str_value);
                            binds[bind_count].has_default = false;

                            // Check for default
                            if (self.match(TokenType.ASSIGN)) {
                                binds[bind_count].has_default = true;
                                binds[bind_count].default_val_reg = self.assignment_expr()!;
                            }

                            bind_count++;
                        }
                    }
                } else {
                    // Shorthand: {name}  →  key="name", binding=name
                    if (is_restricted_name(bind_tok.str_value)) return COMPILE_ERROR~;
                    if (bind_count < 32) {
                        ushort reg = self.declare_var(bind_tok.str_value, kind);
                        binds[bind_count].reg = reg;
                        binds[bind_count].name_idx = self.add_string_constant(bind_tok.str_value);
                        binds[bind_count].key_idx = self.add_string_constant(bind_tok.str_value);
                        binds[bind_count].has_default = false;
                        bind_count++;
                    }
                }

                // Close nested braces
                self.expect(TokenType.RBRACE)!;
            } else if (self.check(TokenType.LBRACKET)) {
                // Nested array pattern: {a: [x, y]} = rhs
                self.advance()!; // consume '['
                Token name_tok = self.expect(TokenType.IDENTIFIER)!;
                if (is_restricted_name(name_tok.str_value)) return COMPILE_ERROR~;
                self.expect(TokenType.RBRACKET)!;

                // Check for colon (key: pattern)
                if (self.match(TokenType.COLON)) {
                    // Parse array pattern
                    if (bind_count < 32) {
                        ushort reg = self.declare_var(name_tok.str_value, kind);
                        binds[bind_count].reg = reg;
                        binds[bind_count].name_idx = self.add_string_constant(name_tok.str_value);
                        binds[bind_count].key_idx = self.add_string_constant(name_tok.str_value);
                        binds[bind_count].has_default = false;
                        bind_count++;
                    }
                } else {
                    // Shorthand: {[name]}  →  key="name", binding=name
                    if (bind_count < 32) {
                        ushort reg = self.declare_var(name_tok.str_value, kind);
                        binds[bind_count].reg = reg;
                        binds[bind_count].name_idx = self.add_string_constant(name_tok.str_value);
                        binds[bind_count].key_idx = self.add_string_constant(name_tok.str_value);
                        binds[bind_count].has_default = false;
                        bind_count++;
                    }
                }
            } else {
                Token prop_tok = self.expect(TokenType.IDENTIFIER)!;

                if (self.match(TokenType.COLON)) {
                    // Keyed: {key: binding_name} or {key: pattern}
                    // Check if the value is a nested pattern
                    if (self.check(TokenType.LBRACE)) {
                        // Nested object pattern: {a: {x, y}}
                        self.advance()!; // consume '{'
                        // Parse first property of nested object
                        Token nested_name = self.expect(TokenType.IDENTIFIER)!;
                        if (is_restricted_name(nested_name.str_value)) return COMPILE_ERROR~;

                        if (self.match(TokenType.COLON)) {
                            // {a: {x: y}} - keyed
                            Token nested_bind = self.expect(TokenType.IDENTIFIER)!;
                            if (is_restricted_name(nested_bind.str_value)) return COMPILE_ERROR~;
                            if (bind_count < 32) {
                                ushort reg = self.declare_var(nested_bind.str_value, kind);
                                binds[bind_count].reg = reg;
                                binds[bind_count].name_idx = self.add_string_constant(nested_bind.str_value);
                                binds[bind_count].key_idx = self.add_string_constant(prop_tok.str_value);
                                binds[bind_count].has_default = false;

                                // Check for default
                                if (self.match(TokenType.ASSIGN)) {
                                    binds[bind_count].has_default = true;
                                    binds[bind_count].default_val_reg = self.assignment_expr()!;
                                }

                                bind_count++;
                            }
                        } else {
                            // {a: {x}} - shorthand inside nested
                            if (bind_count < 32) {
                                ushort reg = self.declare_var(nested_name.str_value, kind);
                                binds[bind_count].reg = reg;
                                binds[bind_count].name_idx = self.add_string_constant(nested_name.str_value);
                                binds[bind_count].key_idx = self.add_string_constant(prop_tok.str_value);
                                binds[bind_count].has_default = false;
                                bind_count++;
                            }
                        }

                        // Parse remaining properties in nested object
                        while (self.match(TokenType.COMMA)) {
                            if (self.check(TokenType.RBRACE)) break;
                            Token nested_prop = self.expect(TokenType.IDENTIFIER)!;
                            if (is_restricted_name(nested_prop.str_value)) return COMPILE_ERROR~;
                            if (self.match(TokenType.COLON)) {
                                Token nested_bind2 = self.expect(TokenType.IDENTIFIER)!;
                                if (is_restricted_name(nested_bind2.str_value)) return COMPILE_ERROR~;
                                if (bind_count < 32) {
                                    ushort reg = self.declare_var(nested_bind2.str_value, kind);
                                    binds[bind_count].reg = reg;
                                    binds[bind_count].name_idx = self.add_string_constant(nested_bind2.str_value);
                                    binds[bind_count].key_idx = self.add_string_constant(nested_prop.str_value);
                                    binds[bind_count].has_default = false;
                                    bind_count++;
                                }
                            } else {
                                if (bind_count < 32) {
                                    ushort reg = self.declare_var(nested_prop.str_value, kind);
                                    binds[bind_count].reg = reg;
                                    binds[bind_count].name_idx = self.add_string_constant(nested_prop.str_value);
                                    binds[bind_count].key_idx = self.add_string_constant(nested_prop.str_value);
                                    binds[bind_count].has_default = false;
                                    bind_count++;
                                }
                            }
                        }
                        self.expect(TokenType.RBRACE)!;
                    } else if (self.check(TokenType.LBRACKET)) {
                        // Nested array pattern: {a: [x, y]}
                        self.advance()!; // consume '['
                        Token bind_tok = self.expect(TokenType.IDENTIFIER)!;
                        if (is_restricted_name(bind_tok.str_value)) return COMPILE_ERROR~;

                        if (bind_count < 32) {
                            ushort reg = self.declare_var(bind_tok.str_value, kind);
                            binds[bind_count].reg = reg;
                            binds[bind_count].name_idx = self.add_string_constant(bind_tok.str_value);
                            binds[bind_count].key_idx = self.add_string_constant(prop_tok.str_value);
                            binds[bind_count].has_default = false;
                            bind_count++;
                        }

                        // Parse remaining array elements
                        while (self.match(TokenType.COMMA)) {
                            if (self.check(TokenType.RBRACKET)) break;
                            Token arr_el = self.expect(TokenType.IDENTIFIER)!;
                            if (is_restricted_name(arr_el.str_value)) return COMPILE_ERROR~;
                            if (bind_count < 32) {
                                ushort reg = self.declare_var(arr_el.str_value, kind);
                                binds[bind_count].reg = reg;
                                binds[bind_count].name_idx = self.add_string_constant(arr_el.str_value);
                                binds[bind_count].key_idx = self.add_string_constant(arr_el.str_value);
                                binds[bind_count].has_default = false;
                                bind_count++;
                            }
                        }
                        self.expect(TokenType.RBRACKET)!;
                    } else {
                        // Simple key: value
                        Token bind_tok = self.expect(TokenType.IDENTIFIER)!;
                        if (is_restricted_name(bind_tok.str_value)) return COMPILE_ERROR~;
                        if (bind_count < 32) {
                            ushort reg = self.declare_var(bind_tok.str_value, kind);
                            binds[bind_count].reg = reg;
                            binds[bind_count].name_idx = self.add_string_constant(bind_tok.str_value);
                            binds[bind_count].key_idx = self.add_string_constant(prop_tok.str_value);
                            binds[bind_count].has_default = false;

                            // Check for default
                            if (self.match(TokenType.ASSIGN)) {
                                binds[bind_count].has_default = true;
                                binds[bind_count].default_val_reg = self.assignment_expr()!;
                            }

                            bind_count++;
                        }
                    }
                } else {
                    // Shorthand: {name}  →  key="name", binding=name
                    if (is_restricted_name(prop_tok.str_value)) return COMPILE_ERROR~;
                    if (bind_count < 32) {
                        ushort reg = self.declare_var(prop_tok.str_value, kind);
                        binds[bind_count].reg = reg;
                        binds[bind_count].name_idx = self.add_string_constant(prop_tok.str_value);
                        binds[bind_count].key_idx = self.add_string_constant(prop_tok.str_value);
                        binds[bind_count].has_default = false;

                        // Check for default
                        if (self.match(TokenType.ASSIGN)) {
                            binds[bind_count].has_default = true;
                            binds[bind_count].default_val_reg = self.assignment_expr()!;
                        }

                        bind_count++;
                    }
                }
            }

            if (!self.match(TokenType.COMMA)) break;
        }
    }

    self.expect(TokenType.RBRACE)!;

    // Default to undefined if no initializer
    if (!self.match(TokenType.ASSIGN)) {
        for (uint i = 0; i < bind_count; i++) {
            self.emit_abc(Opcode.LDUNDEF, (uint)binds[i].reg, 0, 0);
            self.emit_var_store(binds[i].reg, binds[i].name_idx, is_lexical, is_const);
        }
        return;
    }

    // Evaluate RHS
    ushort rhs_reg = self.assignment_expr()!;

    // Emit GETPROP for each property: rhs[key] → bind_reg
    for (uint i = 0; i < bind_count; i++) {
        ushort key_reg = self.alloc_reg();
        self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)key_reg, binds[i].key_idx));
        self.emit_abc(Opcode.GETPROP, (uint)binds[i].reg, (uint)rhs_reg, (uint)key_reg);
        self.free_reg(key_reg);

        // Apply default if present: if value is undefined, use default
        if (binds[i].has_default) {
            // Check if value is undefined
            ushort undef_check_reg = self.alloc_reg();
            self.emit_abc(Opcode.LDUNDEF, (uint)undef_check_reg, 0, 0);
            ushort is_undef_reg = self.alloc_reg();
            self.emit_abc(Opcode.SEQ, (uint)is_undef_reg, (uint)binds[i].reg, (uint)undef_check_reg);
            self.free_reg(undef_check_reg);

            // If not undefined, jump over default
            uint skip_default = self.emit_cond_jump(Opcode.IF_FALSE, (uint)is_undef_reg);
            self.free_reg(is_undef_reg);

            // Load default value
            self.emit_abc(Opcode.LDREG, (uint)binds[i].reg, (uint)binds[i].default_val_reg, 0);

            // Patch jump
            self.patch_jump(skip_default);

            // Free the default value register
            self.free_reg(binds[i].default_val_reg);
        }

        self.emit_var_store(binds[i].reg, binds[i].name_idx, is_lexical, is_const);
    }

    self.free_reg(rhs_reg);
}

// ============================================================================
// Destructuring ASSIGNMENT (without let/const/var)
// ============================================================================

/// Parse array destructuring assignment: [a, b, ...rest] = rhs
/// The '[' has already been consumed.
/// Returns the RHS register (destructuring assignment evaluates to RHS value).
fn ushort? CompilerContext.array_destructure_assign(&self) {
    ArrayBind[32] binds;
    uint bind_count = 0;

    // Parse pattern elements, resolving existing variables instead of declaring new ones
    for (;;) {
        if (self.check(TokenType.RBRACKET)) break;

        if (self.check(TokenType.COMMA)) {
            self.advance()!;
            if (bind_count < 32) {
                binds[bind_count].is_hole = true;
                binds[bind_count].has_default = false;
                bind_count++;
            }
            continue;
        }

        if (self.match(TokenType.ELLIPSIS)) {
            Token rest_tok = self.expect(TokenType.IDENTIFIER)!;
            if (is_restricted_name(rest_tok.str_value)) return COMPILE_ERROR~;
            if (bind_count < 32) {
                ushort reg;
                if (try existing = self.resolve_var(rest_tok.str_value)) {
                    reg = existing;
                    binds[bind_count].is_resolved = true;
                } else {
                    reg = self.alloc_reg();
                    binds[bind_count].is_resolved = false;
                }
                binds[bind_count].reg = reg;
                binds[bind_count].name_idx = self.add_string_constant(rest_tok.str_value);
                binds[bind_count].is_rest = true;
                binds[bind_count].is_hole = false;
                binds[bind_count].has_default = false;
                bind_count++;
            }
            while (self.match(TokenType.COMMA)) {}
            break;
        }

        // Check for nested pattern (simplified: parse as flat identifier)
        if (self.check(TokenType.LBRACKET)) {
            self.advance()!; // consume '['
            Token name_tok = self.expect(TokenType.IDENTIFIER)!;
            if (is_restricted_name(name_tok.str_value)) return COMPILE_ERROR~;
            if (bind_count < 32) {
                ushort reg;
                if (try existing = self.resolve_var(name_tok.str_value)) {
                    reg = existing;
                    binds[bind_count].is_resolved = true;
                } else {
                    reg = self.alloc_reg();
                    binds[bind_count].is_resolved = false;
                }
                binds[bind_count].reg = reg;
                binds[bind_count].name_idx = self.add_string_constant(name_tok.str_value);
                binds[bind_count].is_rest = false;
                binds[bind_count].is_hole = false;
                binds[bind_count].has_default = false;
                bind_count++;
            }
            self.expect(TokenType.RBRACKET)!;
        } else if (self.check(TokenType.LBRACE)) {
            self.advance()!; // consume '{'
            Token name_tok = self.expect(TokenType.IDENTIFIER)!;
            if (is_restricted_name(name_tok.str_value)) return COMPILE_ERROR~;
            if (bind_count < 32) {
                ushort reg;
                if (try existing = self.resolve_var(name_tok.str_value)) {
                    reg = existing;
                    binds[bind_count].is_resolved = true;
                } else {
                    reg = self.alloc_reg();
                    binds[bind_count].is_resolved = false;
                }
                binds[bind_count].reg = reg;
                binds[bind_count].name_idx = self.add_string_constant(name_tok.str_value);
                binds[bind_count].is_rest = false;
                binds[bind_count].is_hole = false;
                binds[bind_count].has_default = false;
                bind_count++;
            }
            self.expect(TokenType.RBRACE)!;
        } else {
            Token name_tok = self.expect(TokenType.IDENTIFIER)!;
            if (is_restricted_name(name_tok.str_value)) return COMPILE_ERROR~;
            if (bind_count < 32) {
                ushort reg;
                if (try existing = self.resolve_var(name_tok.str_value)) {
                    reg = existing;
                    binds[bind_count].is_resolved = true;
                } else {
                    reg = self.alloc_reg();
                    binds[bind_count].is_resolved = false;
                }
                binds[bind_count].reg = reg;
                binds[bind_count].name_idx = self.add_string_constant(name_tok.str_value);
                binds[bind_count].is_rest = false;
                binds[bind_count].is_hole = false;
                binds[bind_count].has_default = false;

                // Check for default: a = expr
                if (self.match(TokenType.ASSIGN)) {
                    binds[bind_count].has_default = true;
                    // Compile the default expression into a temp register
                    binds[bind_count].default_val_reg = self.assignment_expr()!;
                }

                bind_count++;
            }
        }

        if (!self.match(TokenType.COMMA)) break;
    }

    self.expect(TokenType.RBRACKET)!;
    self.expect(TokenType.ASSIGN)!;

    // Evaluate RHS
    ushort rhs_reg = self.assignment_expr()!;

    // Emit code for each binding: get property from RHS, store in binding
    for (uint i = 0; i < bind_count; i++) {
        if (binds[i].is_hole) continue;

        if (binds[i].is_rest) {
            // Rest element: call rhs.slice(rest_idx)
            uint rest_idx = 0;
            for (uint j = 0; j < i; j++) {
                if (!binds[j].is_hole) rest_idx++;
            }

            // CALL convention: callee at callee_reg, this at callee_reg+1, args at callee_reg+2..
            ushort callee_reg = self.alloc_reg();
            if (self.next_reg < callee_reg + 3) {
                self.next_reg = callee_reg + 3;
            }

            ushort slice_key_reg = self.alloc_reg();
            uint slice_key_idx = self.add_string_constant("slice");
            self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)slice_key_reg, slice_key_idx));
            ushort method_reg = self.alloc_reg();
            self.emit_abc(Opcode.GETPROP, (uint)method_reg, (uint)rhs_reg, (uint)slice_key_reg);

            self.emit_abc(Opcode.LDREG, (uint)callee_reg, (uint)method_reg, 0);
            self.emit_abc(Opcode.LDREG, (uint)(callee_reg + 1), (uint)rhs_reg, 0);
            self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)(callee_reg + 2), (int)rest_idx));

            self.emit_abc(Opcode.CALL, (uint)callee_reg, (uint)callee_reg, 1);

            self.emit_abc(Opcode.LDREG, (uint)binds[i].reg, (uint)callee_reg, 0);
            self.free_regs_to(callee_reg);
        } else {
            // Regular element: GETPROP rhs[i] → bind_reg
            ushort idx_reg = self.alloc_reg();
            self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)idx_reg, (int)i));
            self.emit_abc(Opcode.GETPROP, (uint)binds[i].reg, (uint)rhs_reg, (uint)idx_reg);
            self.free_reg(idx_reg);

            // Apply default if present: if value is undefined, use default
            if (binds[i].has_default) {
                ushort undef_check_reg = self.alloc_reg();
                self.emit_abc(Opcode.LDUNDEF, (uint)undef_check_reg, 0, 0);
                ushort is_undef_reg = self.alloc_reg();
                self.emit_abc(Opcode.SEQ, (uint)is_undef_reg, (uint)binds[i].reg, (uint)undef_check_reg);
                self.free_reg(undef_check_reg);

                uint skip_default = self.emit_cond_jump(Opcode.IF_FALSE, (uint)is_undef_reg);
                self.free_reg(is_undef_reg);

                self.emit_abc(Opcode.LDREG, (uint)binds[i].reg, (uint)binds[i].default_val_reg, 0);
                self.patch_jump(skip_default);
                self.free_reg(binds[i].default_val_reg);
            }
        }

        // For assignment: if variable wasn't resolved locally, emit PUTVAR to write to env
        if (!binds[i].is_resolved) {
            ushort tmp = self.alloc_reg();
            self.emit_abc(Opcode.LDREG, (uint)tmp, (uint)binds[i].reg, 0);
            self.emit_a_bc(Opcode.PUTVAR, (uint)binds[i].reg, binds[i].name_idx);
            self.free_reg(binds[i].reg);
            binds[i].reg = tmp;
        }
        // If resolved locally, value is already in the register cache — no PUTVAR needed
    }

    self.free_reg(rhs_reg);
    return rhs_reg;
}

/// Parse object destructuring assignment: {a, b: c, x = default} = rhs
/// The '{' has already been consumed.
/// Returns the RHS register (destructuring assignment evaluates to RHS value).
fn ushort? CompilerContext.object_destructure_assign(&self) {
    ObjBind[32] binds;
    uint bind_count = 0;

    if (!self.check(TokenType.RBRACE)) {
        for (;;) {
            // Check for nested patterns first
            if (self.check(TokenType.LBRACE)) {
                self.advance()!; // consume '{'
                Token bind_tok = self.expect(TokenType.IDENTIFIER)!;
                if (is_restricted_name(bind_tok.str_value)) return COMPILE_ERROR~;

                if (self.match(TokenType.COLON)) {
                    if (self.check(TokenType.LBRACE)) {
                        self.advance()!; // consume '{'
                        Token nested_name = self.expect(TokenType.IDENTIFIER)!;
                        if (is_restricted_name(nested_name.str_value)) return COMPILE_ERROR~;
                        if (bind_count < 32) {
                            ushort reg;
                            if (try existing = self.resolve_var(nested_name.str_value)) {
                                reg = existing;
                                binds[bind_count].is_resolved = true;
                            } else {
                                reg = self.alloc_reg();
                                binds[bind_count].is_resolved = false;
                            }
                            binds[bind_count].reg = reg;
                            binds[bind_count].name_idx = self.add_string_constant(nested_name.str_value);
                            binds[bind_count].key_idx = self.add_string_constant(bind_tok.str_value);
                            binds[bind_count].has_default = false;
                            bind_count++;
                        }
                        while (self.match(TokenType.COMMA)) {
                            if (self.check(TokenType.RBRACE)) break;
                            Token nested_prop = self.expect(TokenType.IDENTIFIER)!;
                            if (is_restricted_name(nested_prop.str_value)) return COMPILE_ERROR~;
                            if (self.match(TokenType.COLON)) {
                                Token nested_bind = self.expect(TokenType.IDENTIFIER)!;
                                if (is_restricted_name(nested_bind.str_value)) return COMPILE_ERROR~;
                                if (bind_count < 32) {
                                    ushort reg;
                                    if (try existing = self.resolve_var(nested_bind.str_value)) {
                                        reg = existing;
                                        binds[bind_count].is_resolved = true;
                                    } else {
                                        reg = self.alloc_reg();
                                        binds[bind_count].is_resolved = false;
                                    }
                                    binds[bind_count].reg = reg;
                                    binds[bind_count].name_idx = self.add_string_constant(nested_bind.str_value);
                                    binds[bind_count].key_idx = self.add_string_constant(nested_prop.str_value);
                                    binds[bind_count].has_default = false;
                                    bind_count++;
                                }
                            } else {
                                if (bind_count < 32) {
                                    ushort reg;
                                    if (try existing = self.resolve_var(nested_prop.str_value)) {
                                        reg = existing;
                                        binds[bind_count].is_resolved = true;
                                    } else {
                                        reg = self.alloc_reg();
                                        binds[bind_count].is_resolved = false;
                                    }
                                    binds[bind_count].reg = reg;
                                    binds[bind_count].name_idx = self.add_string_constant(nested_prop.str_value);
                                    binds[bind_count].key_idx = self.add_string_constant(nested_prop.str_value);
                                    binds[bind_count].has_default = false;
                                    bind_count++;
                                }
                            }
                        }
                        self.expect(TokenType.RBRACE)!;
                    } else if (self.check(TokenType.LBRACKET)) {
                        self.advance()!; // consume '['
                        Token nested_name = self.expect(TokenType.IDENTIFIER)!;
                        if (is_restricted_name(nested_name.str_value)) return COMPILE_ERROR~;
                        if (bind_count < 32) {
                            ushort reg;
                            if (try existing = self.resolve_var(nested_name.str_value)) {
                                reg = existing;
                                binds[bind_count].is_resolved = true;
                            } else {
                                reg = self.alloc_reg();
                                binds[bind_count].is_resolved = false;
                            }
                            binds[bind_count].reg = reg;
                            binds[bind_count].name_idx = self.add_string_constant(nested_name.str_value);
                            binds[bind_count].key_idx = self.add_string_constant(bind_tok.str_value);
                            binds[bind_count].has_default = false;
                            bind_count++;
                        }
                        while (self.match(TokenType.COMMA)) {
                            if (self.check(TokenType.RBRACKET)) break;
                            Token nested_el = self.expect(TokenType.IDENTIFIER)!;
                            if (is_restricted_name(nested_el.str_value)) return COMPILE_ERROR~;
                            if (bind_count < 32) {
                                ushort reg;
                                if (try existing = self.resolve_var(nested_el.str_value)) {
                                    reg = existing;
                                    binds[bind_count].is_resolved = true;
                                } else {
                                    reg = self.alloc_reg();
                                    binds[bind_count].is_resolved = false;
                                }
                                binds[bind_count].reg = reg;
                                binds[bind_count].name_idx = self.add_string_constant(nested_el.str_value);
                                binds[bind_count].key_idx = self.add_string_constant(nested_el.str_value);
                                binds[bind_count].has_default = false;
                                bind_count++;
                            }
                        }
                        self.expect(TokenType.RBRACKET)!;
                    } else {
                        Token val_tok = self.expect(TokenType.IDENTIFIER)!;
                        if (is_restricted_name(val_tok.str_value)) return COMPILE_ERROR~;
                        if (bind_count < 32) {
                            ushort reg;
                            if (try existing = self.resolve_var(val_tok.str_value)) {
                                reg = existing;
                                binds[bind_count].is_resolved = true;
                            } else {
                                reg = self.alloc_reg();
                                binds[bind_count].is_resolved = false;
                            }
                            binds[bind_count].reg = reg;
                            binds[bind_count].name_idx = self.add_string_constant(val_tok.str_value);
                            binds[bind_count].key_idx = self.add_string_constant(bind_tok.str_value);
                            binds[bind_count].has_default = false;

                            if (self.match(TokenType.ASSIGN)) {
                                binds[bind_count].has_default = true;
                                binds[bind_count].default_val_reg = self.assignment_expr()!;
                            }

                            bind_count++;
                        }
                    }
                } else {
                    // Shorthand: {name}
                    if (is_restricted_name(bind_tok.str_value)) return COMPILE_ERROR~;
                    if (bind_count < 32) {
                        ushort reg;
                        if (try existing = self.resolve_var(bind_tok.str_value)) {
                            reg = existing;
                            binds[bind_count].is_resolved = true;
                        } else {
                            reg = self.alloc_reg();
                            binds[bind_count].is_resolved = false;
                        }
                        binds[bind_count].reg = reg;
                        binds[bind_count].name_idx = self.add_string_constant(bind_tok.str_value);
                        binds[bind_count].key_idx = self.add_string_constant(bind_tok.str_value);
                        binds[bind_count].has_default = false;
                        bind_count++;
                    }
                }
                self.expect(TokenType.RBRACE)!;
            } else if (self.check(TokenType.LBRACKET)) {
                self.advance()!; // consume '['
                Token name_tok = self.expect(TokenType.IDENTIFIER)!;
                if (is_restricted_name(name_tok.str_value)) return COMPILE_ERROR~;
                self.expect(TokenType.RBRACKET)!;

                if (self.match(TokenType.COLON)) {
                    if (bind_count < 32) {
                        ushort reg;
                        if (try existing = self.resolve_var(name_tok.str_value)) {
                            reg = existing;
                            binds[bind_count].is_resolved = true;
                        } else {
                            reg = self.alloc_reg();
                            binds[bind_count].is_resolved = false;
                        }
                        binds[bind_count].reg = reg;
                        binds[bind_count].name_idx = self.add_string_constant(name_tok.str_value);
                        binds[bind_count].key_idx = self.add_string_constant(name_tok.str_value);
                        binds[bind_count].has_default = false;
                        bind_count++;
                    }
                } else {
                    if (bind_count < 32) {
                        ushort reg;
                        if (try existing = self.resolve_var(name_tok.str_value)) {
                            reg = existing;
                            binds[bind_count].is_resolved = true;
                        } else {
                            reg = self.alloc_reg();
                            binds[bind_count].is_resolved = false;
                        }
                        binds[bind_count].reg = reg;
                        binds[bind_count].name_idx = self.add_string_constant(name_tok.str_value);
                        binds[bind_count].key_idx = self.add_string_constant(name_tok.str_value);
                        binds[bind_count].has_default = false;
                        bind_count++;
                    }
                }
            } else {
                Token prop_tok = self.expect(TokenType.IDENTIFIER)!;

                if (self.match(TokenType.COLON)) {
                    // Keyed: {key: binding_name} or {key: pattern}
                    if (self.check(TokenType.LBRACE)) {
                        self.advance()!; // consume '{'
                        Token nested_name = self.expect(TokenType.IDENTIFIER)!;
                        if (is_restricted_name(nested_name.str_value)) return COMPILE_ERROR~;

                        if (self.match(TokenType.COLON)) {
                            Token nested_bind = self.expect(TokenType.IDENTIFIER)!;
                            if (is_restricted_name(nested_bind.str_value)) return COMPILE_ERROR~;
                            if (bind_count < 32) {
                                ushort reg;
                                if (try existing = self.resolve_var(nested_bind.str_value)) {
                                    reg = existing;
                                    binds[bind_count].is_resolved = true;
                                } else {
                                    reg = self.alloc_reg();
                                    binds[bind_count].is_resolved = false;
                                }
                                binds[bind_count].reg = reg;
                                binds[bind_count].name_idx = self.add_string_constant(nested_bind.str_value);
                                binds[bind_count].key_idx = self.add_string_constant(prop_tok.str_value);
                                binds[bind_count].has_default = false;

                                if (self.match(TokenType.ASSIGN)) {
                                    binds[bind_count].has_default = true;
                                    binds[bind_count].default_val_reg = self.assignment_expr()!;
                                }

                                bind_count++;
                            }
                        } else {
                            if (bind_count < 32) {
                                ushort reg;
                                if (try existing = self.resolve_var(nested_name.str_value)) {
                                    reg = existing;
                                    binds[bind_count].is_resolved = true;
                                } else {
                                    reg = self.alloc_reg();
                                    binds[bind_count].is_resolved = false;
                                }
                                binds[bind_count].reg = reg;
                                binds[bind_count].name_idx = self.add_string_constant(nested_name.str_value);
                                binds[bind_count].key_idx = self.add_string_constant(prop_tok.str_value);
                                binds[bind_count].has_default = false;
                                bind_count++;
                            }
                        }

                        while (self.match(TokenType.COMMA)) {
                            if (self.check(TokenType.RBRACE)) break;
                            Token nested_prop = self.expect(TokenType.IDENTIFIER)!;
                            if (is_restricted_name(nested_prop.str_value)) return COMPILE_ERROR~;
                            if (self.match(TokenType.COLON)) {
                                Token nested_bind2 = self.expect(TokenType.IDENTIFIER)!;
                                if (is_restricted_name(nested_bind2.str_value)) return COMPILE_ERROR~;
                                if (bind_count < 32) {
                                    ushort reg;
                                    if (try existing = self.resolve_var(nested_bind2.str_value)) {
                                        reg = existing;
                                        binds[bind_count].is_resolved = true;
                                    } else {
                                        reg = self.alloc_reg();
                                        binds[bind_count].is_resolved = false;
                                    }
                                    binds[bind_count].reg = reg;
                                    binds[bind_count].name_idx = self.add_string_constant(nested_bind2.str_value);
                                    binds[bind_count].key_idx = self.add_string_constant(nested_prop.str_value);
                                    binds[bind_count].has_default = false;
                                    bind_count++;
                                }
                            } else {
                                if (bind_count < 32) {
                                    ushort reg;
                                    if (try existing = self.resolve_var(nested_prop.str_value)) {
                                        reg = existing;
                                        binds[bind_count].is_resolved = true;
                                    } else {
                                        reg = self.alloc_reg();
                                        binds[bind_count].is_resolved = false;
                                    }
                                    binds[bind_count].reg = reg;
                                    binds[bind_count].name_idx = self.add_string_constant(nested_prop.str_value);
                                    binds[bind_count].key_idx = self.add_string_constant(nested_prop.str_value);
                                    binds[bind_count].has_default = false;
                                    bind_count++;
                                }
                            }
                        }
                        self.expect(TokenType.RBRACE)!;
                    } else if (self.check(TokenType.LBRACKET)) {
                        self.advance()!; // consume '['
                        Token bind_tok = self.expect(TokenType.IDENTIFIER)!;
                        if (is_restricted_name(bind_tok.str_value)) return COMPILE_ERROR~;

                        if (bind_count < 32) {
                            ushort reg;
                            if (try existing = self.resolve_var(bind_tok.str_value)) {
                                reg = existing;
                                binds[bind_count].is_resolved = true;
                            } else {
                                reg = self.alloc_reg();
                                binds[bind_count].is_resolved = false;
                            }
                            binds[bind_count].reg = reg;
                            binds[bind_count].name_idx = self.add_string_constant(bind_tok.str_value);
                            binds[bind_count].key_idx = self.add_string_constant(prop_tok.str_value);
                            binds[bind_count].has_default = false;
                            bind_count++;
                        }

                        while (self.match(TokenType.COMMA)) {
                            if (self.check(TokenType.RBRACKET)) break;
                            Token arr_el = self.expect(TokenType.IDENTIFIER)!;
                            if (is_restricted_name(arr_el.str_value)) return COMPILE_ERROR~;
                            if (bind_count < 32) {
                                ushort reg;
                                if (try existing = self.resolve_var(arr_el.str_value)) {
                                    reg = existing;
                                    binds[bind_count].is_resolved = true;
                                } else {
                                    reg = self.alloc_reg();
                                    binds[bind_count].is_resolved = false;
                                }
                                binds[bind_count].reg = reg;
                                binds[bind_count].name_idx = self.add_string_constant(arr_el.str_value);
                                binds[bind_count].key_idx = self.add_string_constant(arr_el.str_value);
                                binds[bind_count].has_default = false;
                                bind_count++;
                            }
                        }
                        self.expect(TokenType.RBRACKET)!;
                    } else {
                        // Simple key: value
                        Token bind_tok = self.expect(TokenType.IDENTIFIER)!;
                        if (is_restricted_name(bind_tok.str_value)) return COMPILE_ERROR~;
                        if (bind_count < 32) {
                            ushort reg;
                            if (try existing = self.resolve_var(bind_tok.str_value)) {
                                reg = existing;
                                binds[bind_count].is_resolved = true;
                            } else {
                                reg = self.alloc_reg();
                                binds[bind_count].is_resolved = false;
                            }
                            binds[bind_count].reg = reg;
                            binds[bind_count].name_idx = self.add_string_constant(bind_tok.str_value);
                            binds[bind_count].key_idx = self.add_string_constant(prop_tok.str_value);
                            binds[bind_count].has_default = false;

                            if (self.match(TokenType.ASSIGN)) {
                                binds[bind_count].has_default = true;
                                binds[bind_count].default_val_reg = self.assignment_expr()!;
                            }

                            bind_count++;
                        }
                    }
                } else {
                    // Shorthand: {name}  →  key="name", binding=name
                    if (is_restricted_name(prop_tok.str_value)) return COMPILE_ERROR~;
                    if (bind_count < 32) {
                        ushort reg;
                        if (try existing = self.resolve_var(prop_tok.str_value)) {
                            reg = existing;
                            binds[bind_count].is_resolved = true;
                        } else {
                            reg = self.alloc_reg();
                            binds[bind_count].is_resolved = false;
                        }
                        binds[bind_count].reg = reg;
                        binds[bind_count].name_idx = self.add_string_constant(prop_tok.str_value);
                        binds[bind_count].key_idx = self.add_string_constant(prop_tok.str_value);
                        binds[bind_count].has_default = false;

                        if (self.match(TokenType.ASSIGN)) {
                            binds[bind_count].has_default = true;
                            binds[bind_count].default_val_reg = self.assignment_expr()!;
                        }

                        bind_count++;
                    }
                }
            }

            if (!self.match(TokenType.COMMA)) break;
        }
    }

    self.expect(TokenType.RBRACE)!;
    self.expect(TokenType.ASSIGN)!;

    // Evaluate RHS
    ushort rhs_reg = self.assignment_expr()!;

    // Emit GETPROP for each property: rhs[key] → bind_reg
    for (uint i = 0; i < bind_count; i++) {
        ushort key_reg = self.alloc_reg();
        self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)key_reg, binds[i].key_idx));
        self.emit_abc(Opcode.GETPROP, (uint)binds[i].reg, (uint)rhs_reg, (uint)key_reg);
        self.free_reg(key_reg);

        // Apply default if present: if value is undefined, use default
        if (binds[i].has_default) {
            ushort undef_check_reg = self.alloc_reg();
            self.emit_abc(Opcode.LDUNDEF, (uint)undef_check_reg, 0, 0);
            ushort is_undef_reg = self.alloc_reg();
            self.emit_abc(Opcode.SEQ, (uint)is_undef_reg, (uint)binds[i].reg, (uint)undef_check_reg);
            self.free_reg(undef_check_reg);

            uint skip_default = self.emit_cond_jump(Opcode.IF_FALSE, (uint)is_undef_reg);
            self.free_reg(is_undef_reg);

            self.emit_abc(Opcode.LDREG, (uint)binds[i].reg, (uint)binds[i].default_val_reg, 0);
            self.patch_jump(skip_default);
            self.free_reg(binds[i].default_val_reg);
        }

        // For assignment: if variable wasn't resolved locally, emit PUTVAR
        if (!binds[i].is_resolved) {
            ushort tmp = self.alloc_reg();
            self.emit_abc(Opcode.LDREG, (uint)tmp, (uint)binds[i].reg, 0);
            self.emit_a_bc(Opcode.PUTVAR, (uint)binds[i].reg, binds[i].name_idx);
            self.free_reg(binds[i].reg);
            binds[i].reg = tmp;
        }
    }

    self.free_reg(rhs_reg);
    return rhs_reg;
}

/// Compile a destructuring pattern in a for-of or for-in loop.
/// The iterator yields values that are assigned via the pattern.
fn void? CompilerContext.destructure_for_value(&self, ushort value_reg, ScopeKind kind, bool is_lexical, bool is_const, bool is_array_pattern) {
    if (is_array_pattern) {
        // Array pattern: for (let [a, b] of arr)
        // value_reg holds the yielded value — use iterator protocol to extract elements
        ArrayBind[32] binds;
        uint bind_count = 0;

        // Parse the pattern
        self.expect(TokenType.LBRACKET)!;
        for (;;) {
            if (self.check(TokenType.RBRACKET)) break;

            if (self.check(TokenType.COMMA)) {
                self.advance()!;
                if (bind_count < 32) {
                    binds[bind_count].is_hole = true;
                    binds[bind_count].has_default = false;
                    bind_count++;
                }
                continue;
            }

            if (self.match(TokenType.ELLIPSIS)) {
                Token rest_tok = self.expect(TokenType.IDENTIFIER)!;
                if (is_restricted_name(rest_tok.str_value)) return COMPILE_ERROR~;
                if (bind_count < 32) {
                    ushort reg = self.declare_var(rest_tok.str_value, kind);
                    binds[bind_count].reg = reg;
                    binds[bind_count].name_idx = self.add_string_constant(rest_tok.str_value);
                    binds[bind_count].is_rest = true;
                    binds[bind_count].is_hole = false;
                    binds[bind_count].has_default = false;
                    bind_count++;
                }
                while (self.match(TokenType.COMMA)) {}
                break;
            }

            Token name_tok = self.expect(TokenType.IDENTIFIER)!;
            if (is_restricted_name(name_tok.str_value)) return COMPILE_ERROR~;
            if (bind_count < 32) {
                ushort reg = self.declare_var(name_tok.str_value, kind);
                binds[bind_count].reg = reg;
                binds[bind_count].name_idx = self.add_string_constant(name_tok.str_value);
                binds[bind_count].is_rest = false;
                binds[bind_count].is_hole = false;
                binds[bind_count].has_default = false;

                // Check for default
                if (self.match(TokenType.ASSIGN)) {
                    binds[bind_count].has_default = true;
                    binds[bind_count].default_val_reg = self.assignment_expr()!;
                }

                bind_count++;
            }

            if (!self.match(TokenType.COMMA)) break;
        }
        self.expect(TokenType.RBRACKET)!;

        // Caller must have consumed RPAREN before calling this function.

        // === Emit extraction code using iterator protocol ===
        // Set up inner iterator on value_reg: value_reg[Symbol.iterator]()
        ushort inner_sym_reg = self.alloc_reg();
        self.emit_a_bc(Opcode.GETVAR, (uint)inner_sym_reg, self.add_string_constant("Symbol"));

        ushort inner_iter_key_reg = self.alloc_reg();
        self.emit_abc(Opcode.LDCONST, (uint)inner_iter_key_reg, self.add_string_constant("iterator"), 0);

        ushort inner_symbol_val_reg = self.alloc_reg();
        self.emit_abc(Opcode.GETPROP, (uint)inner_symbol_val_reg, (uint)inner_sym_reg, (uint)inner_iter_key_reg);
        self.free_reg(inner_iter_key_reg);
        self.free_reg(inner_sym_reg);

        ushort inner_method_reg = self.alloc_reg();
        self.emit_abc(Opcode.GETPROP, (uint)inner_method_reg, (uint)value_reg, (uint)inner_symbol_val_reg);
        self.free_reg(inner_symbol_val_reg);

        // Call value_reg[Symbol.iterator]() to get the inner iterator
        ushort inner_this_reg = self.alloc_reg();
        self.emit_abc(Opcode.LDREG, (uint)inner_this_reg, (uint)value_reg, 0);
        self.emit_abc(Opcode.CALL, (uint)inner_method_reg, (uint)inner_method_reg, 0);
        self.free_reg(inner_this_reg);

        // Get .next method from inner iterator
        ushort inner_next_reg = self.alloc_reg();
        ushort inner_next_key_reg = self.alloc_reg();
        self.emit_abc(Opcode.LDCONST, (uint)inner_next_key_reg, self.add_string_constant("next"), 0);
        self.emit_abc(Opcode.GETPROP, (uint)inner_next_reg, (uint)inner_method_reg, (uint)inner_next_key_reg);
        self.free_reg(inner_next_key_reg);

        // Set up callee + this for inner .next() calls
        ushort inner_callee_reg = self.alloc_reg();
        ushort inner_callee_this_reg = self.alloc_reg();
        self.emit_abc(Opcode.LDREG, (uint)inner_callee_reg, (uint)inner_next_reg, 0);
        self.emit_abc(Opcode.LDREG, (uint)inner_callee_this_reg, (uint)inner_method_reg, 0);

        // Emit extraction for each binding
        for (uint i = 0; i < bind_count; i++) {
            if (binds[i].is_hole) {
                // Advance the inner iterator by one — discard the value
                ushort hole_result_reg = self.alloc_reg();
                self.emit_abc(Opcode.CALL, (uint)hole_result_reg, (uint)inner_callee_reg, 0);
                self.free_reg(hole_result_reg);
                continue;
            }

            if (binds[i].is_rest) {
                // Rest element: collect all remaining values from inner iterator into a new array
                ushort arr_reg = self.alloc_reg();
                self.emit_abc(Opcode.NEWARR, (uint)arr_reg, 0, 0);

                uint collect_start = self.code_count;

                // Call .next()
                ushort inner_result_reg = self.alloc_reg();
                self.emit_abc(Opcode.CALL, (uint)inner_result_reg, (uint)inner_callee_reg, 0);

                // Check .done — exit if done
                ushort inner_done_key_reg = self.alloc_reg();
                ushort inner_done_reg = self.alloc_reg();
                self.emit_abc(Opcode.LDCONST, (uint)inner_done_key_reg, self.add_string_constant("done"), 0);
                self.emit_abc(Opcode.GETPROP, (uint)inner_done_reg, (uint)inner_result_reg, (uint)inner_done_key_reg);
                uint inner_done_jump = self.emit_cond_jump(Opcode.IF_TRUE, (uint)inner_done_reg);

                // Extract .value
                ushort inner_val_key_reg = self.alloc_reg();
                ushort inner_val_reg = self.alloc_reg();
                self.emit_abc(Opcode.LDCONST, (uint)inner_val_key_reg, self.add_string_constant("value"), 0);
                self.emit_abc(Opcode.GETPROP, (uint)inner_val_reg, (uint)inner_result_reg, (uint)inner_val_key_reg);
                self.free_reg(inner_val_key_reg);
                self.free_reg(inner_result_reg);

                // Push .value to array via arr.push(value)
                ushort push_key_reg = self.alloc_reg();
                self.emit_abc(Opcode.LDCONST, (uint)push_key_reg, self.add_string_constant("push"), 0);
                ushort push_method_reg = self.alloc_reg();
                self.emit_abc(Opcode.GETPROP, (uint)push_method_reg, (uint)arr_reg, (uint)push_key_reg);
                self.free_reg(push_key_reg);

                ushort push_callee_reg = self.alloc_reg();
                self.emit_abc(Opcode.LDREG, (uint)push_callee_reg, (uint)push_method_reg, 0);
                self.emit_abc(Opcode.LDREG, (uint)(push_callee_reg + 1), (uint)arr_reg, 0);
                if (self.next_reg < push_callee_reg + 3) {
                    self.next_reg = push_callee_reg + 3;
                }
                self.emit_abc(Opcode.LDREG, (uint)(push_callee_reg + 2), (uint)inner_val_reg, 0);
                self.free_reg(inner_val_reg);
                self.free_reg(push_method_reg);
                self.emit_abc(Opcode.CALL, (uint)push_callee_reg, (uint)push_callee_reg, 1);
                // push_callee_reg now holds the new length (unused)

                // Jump back to collect next value
                int back_offset = (int)collect_start - (int)self.code_count - 1;
                self.emit(bytecode::make_sabc(Opcode.JUMP, back_offset));

                self.patch_jump(inner_done_jump);

                // Free collect-loop temps
                self.free_reg(inner_done_key_reg);
                self.free_reg(inner_done_reg);

                // Store the collected array into the rest binding
                self.emit_abc(Opcode.LDREG, (uint)binds[i].reg, (uint)arr_reg, 0);
                self.free_reg(arr_reg);
            } else {
                // Regular binding: call .next() and extract .value
                ushort inner_result_reg = self.alloc_reg();
                self.emit_abc(Opcode.CALL, (uint)inner_result_reg, (uint)inner_callee_reg, 0);

                ushort inner_val_key_reg = self.alloc_reg();
                ushort inner_val_reg = self.alloc_reg();
                self.emit_abc(Opcode.LDCONST, (uint)inner_val_key_reg, self.add_string_constant("value"), 0);
                self.emit_abc(Opcode.GETPROP, (uint)inner_val_reg, (uint)inner_result_reg, (uint)inner_val_key_reg);
                self.free_reg(inner_val_key_reg);
                self.free_reg(inner_result_reg);

                // Store in binding register
                self.emit_abc(Opcode.LDREG, (uint)binds[i].reg, (uint)inner_val_reg, 0);
                self.free_reg(inner_val_reg);

                // Apply default if value is undefined
                if (binds[i].has_default) {
                    ushort undef_check_reg = self.alloc_reg();
                    self.emit_abc(Opcode.LDUNDEF, (uint)undef_check_reg, 0, 0);
                    ushort is_undef_reg = self.alloc_reg();
                    self.emit_abc(Opcode.SEQ, (uint)is_undef_reg, (uint)binds[i].reg, (uint)undef_check_reg);
                    self.free_reg(undef_check_reg);

                    uint skip_default = self.emit_cond_jump(Opcode.IF_FALSE, (uint)is_undef_reg);
                    self.free_reg(is_undef_reg);

                    self.emit_abc(Opcode.LDREG, (uint)binds[i].reg, (uint)binds[i].default_val_reg, 0);
                    self.patch_jump(skip_default);
                    self.free_reg(binds[i].default_val_reg);
                }
            }

            self.emit_var_store(binds[i].reg, binds[i].name_idx, is_lexical, is_const);
        }

        // Free inner iterator registers
        self.free_reg(inner_callee_this_reg);
        self.free_reg(inner_callee_reg);
        self.free_reg(inner_next_reg);
        self.free_reg(inner_method_reg);
    } else {
        // Object pattern: for (let {x, y} of arr)
        ObjBind[32] binds;
        uint bind_count = 0;

        // Parse the pattern
        self.expect(TokenType.LBRACE)!;
        if (!self.check(TokenType.RBRACE)) {
            for (;;) {
                Token prop_tok = self.expect(TokenType.IDENTIFIER)!;

                if (self.match(TokenType.COLON)) {
                    Token bind_tok = self.expect(TokenType.IDENTIFIER)!;
                    if (is_restricted_name(bind_tok.str_value)) return COMPILE_ERROR~;
                    if (bind_count < 32) {
                        ushort reg = self.declare_var(bind_tok.str_value, kind);
                        binds[bind_count].reg = reg;
                        binds[bind_count].name_idx = self.add_string_constant(bind_tok.str_value);
                        binds[bind_count].key_idx = self.add_string_constant(prop_tok.str_value);
                        binds[bind_count].has_default = false;

                        // Check for default
                        if (self.match(TokenType.ASSIGN)) {
                            binds[bind_count].has_default = true;
                            binds[bind_count].default_val_reg = self.assignment_expr()!;
                        }

                        bind_count++;
                    }
                } else {
                    if (is_restricted_name(prop_tok.str_value)) return COMPILE_ERROR~;
                    if (bind_count < 32) {
                        ushort reg = self.declare_var(prop_tok.str_value, kind);
                        binds[bind_count].reg = reg;
                        binds[bind_count].name_idx = self.add_string_constant(prop_tok.str_value);
                        binds[bind_count].key_idx = self.add_string_constant(prop_tok.str_value);
                        binds[bind_count].has_default = false;

                        // Check for default
                        if (self.match(TokenType.ASSIGN)) {
                            binds[bind_count].has_default = true;
                            binds[bind_count].default_val_reg = self.assignment_expr()!;
                        }

                        bind_count++;
                    }
                }

                if (!self.match(TokenType.COMMA)) break;
            }
        }
        self.expect(TokenType.RBRACE)!;

        // Caller must have consumed RPAREN before calling this function.

        // Emit extraction code
        for (uint i = 0; i < bind_count; i++) {
            ushort key_reg = self.alloc_reg();
            self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)key_reg, binds[i].key_idx));
            self.emit_abc(Opcode.GETPROP, (uint)binds[i].reg, (uint)value_reg, (uint)key_reg);
            self.free_reg(key_reg);

            // Apply default
            if (binds[i].has_default) {
                ushort undef_check_reg = self.alloc_reg();
                self.emit_abc(Opcode.LDUNDEF, (uint)undef_check_reg, 0, 0);
                ushort is_undef_reg = self.alloc_reg();
                self.emit_abc(Opcode.SEQ, (uint)is_undef_reg, (uint)binds[i].reg, (uint)undef_check_reg);
                self.free_reg(undef_check_reg);
                uint skip_default = self.emit_cond_jump(Opcode.IF_FALSE, (uint)is_undef_reg);
                self.free_reg(is_undef_reg);
                self.emit_abc(Opcode.LDREG, (uint)binds[i].reg, (uint)binds[i].default_val_reg, 0);
                self.patch_jump(skip_default);
                self.free_reg(binds[i].default_val_reg);
            }

            self.emit_var_store(binds[i].reg, binds[i].name_idx, is_lexical, is_const);
        }
    }
}

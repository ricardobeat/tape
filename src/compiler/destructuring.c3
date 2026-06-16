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
            if (self.is_strict && is_restricted_name(rest_tok.str_value)) return COMPILE_ERROR~;
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
            if (self.is_strict && is_restricted_name(name_tok.str_value)) return COMPILE_ERROR~;
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
            if (self.is_strict && is_restricted_name(name_tok.str_value)) return COMPILE_ERROR~;
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
            if (self.is_strict && is_restricted_name(name_tok.str_value)) return COMPILE_ERROR~;
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

            // Method call setup: callee_reg = rhs.slice(rest_idx)
            ushort callee_reg = self.alloc_reg();

            // Get "slice" method from rhs
            ushort slice_key_reg = self.alloc_reg();
            uint slice_key_idx = self.add_string_constant("slice");
            self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)slice_key_reg, slice_key_idx));
            ushort method_reg = self.alloc_reg();
            self.emit_abc(Opcode.GETPROP, (uint)method_reg, (uint)rhs_reg, (uint)slice_key_reg);

            // Move method to callee_reg
            self.emit_abc(Opcode.LDREG, (uint)callee_reg, (uint)method_reg, 0);

            // this = rhs (at callee_reg + 1)
            ushort this_reg = self.alloc_reg();
            self.emit_abc(Opcode.LDREG, (uint)this_reg, (uint)rhs_reg, 0);

            // arg = rest_idx (at callee_reg + 2)
            ushort arg_reg = self.alloc_reg();
            self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)arg_reg, (int)rest_idx));

            // Call: rhs.slice(rest_idx)
            self.emit_abc(Opcode.CALL, (uint)callee_reg, (uint)callee_reg, 1);

            // Free temps in reverse order (LIFO)
            self.free_reg(arg_reg);
            self.free_reg(this_reg);
            self.free_reg(method_reg);
            self.free_reg(slice_key_reg);

            // Store result
            self.emit_abc(Opcode.LDREG, (uint)binds[i].reg, (uint)callee_reg, 0);
            self.free_reg(callee_reg);
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
                if (self.is_strict && is_restricted_name(bind_tok.str_value)) return COMPILE_ERROR~;

                // Check for colon (key: pattern) or just shorthand
                if (self.match(TokenType.COLON)) {
                    // Check if nested value is a pattern or simple identifier
                    if (self.check(TokenType.LBRACE)) {
                        self.advance()!; // consume '{'
                        // Parse nested object pattern
                        Token nested_name = self.expect(TokenType.IDENTIFIER)!;
                        if (self.is_strict && is_restricted_name(nested_name.str_value)) return COMPILE_ERROR~;
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
                            if (self.is_strict && is_restricted_name(nested_prop.str_value)) return COMPILE_ERROR~;
                            if (self.match(TokenType.COLON)) {
                                Token nested_bind = self.expect(TokenType.IDENTIFIER)!;
                                if (self.is_strict && is_restricted_name(nested_bind.str_value)) return COMPILE_ERROR~;
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
                        if (self.is_strict && is_restricted_name(nested_name.str_value)) return COMPILE_ERROR~;
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
                            if (self.is_strict && is_restricted_name(nested_el.str_value)) return COMPILE_ERROR~;
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
                        if (self.is_strict && is_restricted_name(val_tok.str_value)) return COMPILE_ERROR~;
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
                    if (self.is_strict && is_restricted_name(bind_tok.str_value)) return COMPILE_ERROR~;
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
                if (self.is_strict && is_restricted_name(name_tok.str_value)) return COMPILE_ERROR~;
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
                        if (self.is_strict && is_restricted_name(nested_name.str_value)) return COMPILE_ERROR~;

                        if (self.match(TokenType.COLON)) {
                            // {a: {x: y}} - keyed
                            Token nested_bind = self.expect(TokenType.IDENTIFIER)!;
                            if (self.is_strict && is_restricted_name(nested_bind.str_value)) return COMPILE_ERROR~;
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
                            if (self.is_strict && is_restricted_name(nested_prop.str_value)) return COMPILE_ERROR~;
                            if (self.match(TokenType.COLON)) {
                                Token nested_bind2 = self.expect(TokenType.IDENTIFIER)!;
                                if (self.is_strict && is_restricted_name(nested_bind2.str_value)) return COMPILE_ERROR~;
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
                        if (self.is_strict && is_restricted_name(bind_tok.str_value)) return COMPILE_ERROR~;

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
                            if (self.is_strict && is_restricted_name(arr_el.str_value)) return COMPILE_ERROR~;
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
                        if (self.is_strict && is_restricted_name(bind_tok.str_value)) return COMPILE_ERROR~;
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
                    if (self.is_strict && is_restricted_name(prop_tok.str_value)) return COMPILE_ERROR~;
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

/// Compile a destructuring pattern in a for-of or for-in loop.
/// The iterator yields values that are assigned via the pattern.
fn void? CompilerContext.destructure_for_value(&self, ushort value_reg, ScopeKind kind, bool is_lexical, bool is_const, bool is_array_pattern) {
    if (is_array_pattern) {
        // Array pattern: for (let [a, b] of arr)
        // value_reg holds the yielded value (should be iterable-like)
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
                if (self.is_strict && is_restricted_name(rest_tok.str_value)) return COMPILE_ERROR~;
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
            if (self.is_strict && is_restricted_name(name_tok.str_value)) return COMPILE_ERROR~;
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
        self.expect(TokenType.RPAREN)!;

        // Emit extraction code
        for (uint i = 0; i < bind_count; i++) {
            if (binds[i].is_hole) continue;

            if (binds[i].is_rest) {
                // Rest element: slice from current index
                uint rest_idx = 0;
                for (uint j = 0; j < i; j++) {
                    if (!binds[j].is_hole) rest_idx++;
                }

                // Call value.slice(rest_idx)
                ushort callee_reg = self.alloc_reg();
                ushort slice_key_reg = self.alloc_reg();
                uint slice_key_idx = self.add_string_constant("slice");
                self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)slice_key_reg, slice_key_idx));
                ushort method_reg = self.alloc_reg();
                self.emit_abc(Opcode.GETPROP, (uint)method_reg, (uint)value_reg, (uint)slice_key_reg);

                // Move method to callee_reg
                self.emit_abc(Opcode.LDREG, (uint)callee_reg, (uint)method_reg, 0);

                // this = value (at callee_reg + 1)
                ushort this_reg = self.alloc_reg();
                self.emit_abc(Opcode.LDREG, (uint)this_reg, (uint)value_reg, 0);

                // arg = rest_idx (at callee_reg + 2)
                ushort arg_reg = self.alloc_reg();
                self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)arg_reg, (int)rest_idx));

                // Call
                self.emit_abc(Opcode.CALL, (uint)callee_reg, (uint)callee_reg, 1);

                // Free temps in reverse order (LIFO)
                self.free_reg(arg_reg);
                self.free_reg(this_reg);
                self.free_reg(method_reg);
                self.free_reg(slice_key_reg);

                self.emit_abc(Opcode.LDREG, (uint)binds[i].reg, (uint)callee_reg, 0);
                self.free_reg(callee_reg);
            } else {
                ushort idx_reg = self.alloc_reg();
                self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)idx_reg, (int)i));
                self.emit_abc(Opcode.GETPROP, (uint)binds[i].reg, (uint)value_reg, (uint)idx_reg);
                self.free_reg(idx_reg);

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
            }

            self.emit_var_store(binds[i].reg, binds[i].name_idx, is_lexical, is_const);
        }
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
                    if (self.is_strict && is_restricted_name(bind_tok.str_value)) return COMPILE_ERROR~;
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
                    if (self.is_strict && is_restricted_name(prop_tok.str_value)) return COMPILE_ERROR~;
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
        self.expect(TokenType.RPAREN)!;

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

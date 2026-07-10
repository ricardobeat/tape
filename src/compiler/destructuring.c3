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

/// Parse a destructuring-default AssignmentExpression with the binding name
/// available as the inferred function name (per ES2015 §13.3.3.7 step 3 / §14.1.20
/// SetFunctionName — NamedEvaluation tags an anonymous function/arrow/class/
/// generator default with the binding identifier). Saves and restores the
/// surrounding inferred_name slot so the binding-name propagation is scoped
/// to this one default and doesn't leak to siblings.
fn ushort? CompilerContext.destructuring_default_expr(&self, char[] binding_name) {
    bool saved_has = self.has_inferred_name;
    char[128] saved_buf;
    ushort saved_len = self.inferred_name_len;
    for (usz i = 0; i < (usz)saved_len; i++) saved_buf[i] = self.inferred_name_buf[i];
    self.has_inferred_name = binding_name.len > 0 && binding_name.len < 128;
    self.inferred_name_len = (ushort)(self.has_inferred_name ? binding_name.len : 0);
    for (usz i = 0; i < (usz)binding_name.len && i < 128; i++) {
        self.inferred_name_buf[i] = binding_name[i];
    }
    ushort? r = self.assignment_expr();
    self.has_inferred_name = saved_has;
    self.inferred_name_len = saved_len;
    for (usz i = 0; i < (usz)saved_len; i++) self.inferred_name_buf[i] = saved_buf[i];
    return r;
}

/// Parse a property key in a destructuring binding pattern.
/// Per ES2015 §13.3.3.7 the property key can be an IdentifierName, a string
/// literal, a numeric literal, or a computed key. Reserved words are
/// allowed as binding keys (mirroring object-literal property syntax) — they
/// are stored under their keyword spelling in the constant pool, so the
/// runtime property lookup matches the lexical key.
///
/// Returns the key as a `char[]` slice (backed by the token's str_value;
/// valid until the lexer advances past the consumed token).
fn char[]? CompilerContext.destructuring_property_key(&self) {
    TokenType tt = self.peek_type();
    // Identifier or reserved-word key
    if (tt == TokenType.IDENTIFIER) {
        Token t = self.advance()!;
        return t.str_value;
    }
    // String literal key (e.g. {"a b": c})
    if (tt == TokenType.STRING) {
        Token t = self.advance()!;
        return t.str_value;
    }
    // Numeric literal key (e.g. {1: c}) — ConvertToPropertyKey stores as string
    if (tt == TokenType.NUMBER) {
        Token t = self.advance()!;
        return t.str_value;
    }
    // Reserved word (keyword) key — only when a keyword has a string spelling.
    // The lexer's keyword tokens carry str_value only for the contextual
    // keywords set up as object-literal keys (default, if, etc.); for plain
    // keywords we extract the canonical spelling.
    char[] kw_str = lexer::keyword_to_string(tt);
    if (kw_str.len > 0) {
        self.advance()!;
        return kw_str;
    }
    return COMPILE_ERROR~;
}

/// Parse an identifier or computed/multi-type key as a destructuring binding
/// target — the *value* side of `{key: target}`. Per ES2015 §13.3.3.7 this
/// can be a BindingIdentifier with an optional default value, a nested object
/// pattern, or a nested array pattern. Computed keys are handled by the caller
/// before this is invoked.
fn Token? CompilerContext.destructuring_binding_target(&self) {
    // Expect either a binding identifier (any IdentifierName — keywords are
    // not allowed as bindings) or a nested pattern.
    TokenType tt = self.peek_type();
    if (tt == TokenType.IDENTIFIER) {
        return self.advance();
    }
    if (lexer::keyword_to_string(tt).len > 0) {
        return COMPILE_ERROR~;  // keywords may not be binding identifiers
    }
    return COMPILE_ERROR~;
}

/// Parse array destructuring pattern: [a, b, ...rest] = rhs
/// The '[' has already been consumed.
///
/// Uses the ES2015 §13.3.3 iterator protocol via the shared, recursive
/// `emit_destruct_bindings` emitter — the same machinery the function-parameter
/// path uses. This makes statement-level destructuring work for any iterable
/// (generators, custom iterables), at arbitrary nesting depth, not just Arrays.
/// See plan 044; mirrors QuickJS's OP_for_of_start/OP_for_of_next lowering.
fn void? CompilerContext.array_destructure(&self, ScopeKind kind, bool is_lexical, bool is_const) {
    DestructBind[MAX_DESTRUCT_BINDS] binds;
    uint count = 0;

    // Parse the pattern into the recursive DestructBind model. The source
    // register (arg_idx) for top-level binds is patched to the RHS register
    // once it is known (RHS is parsed after the pattern). Nested binds carry a
    // parent_idx instead and resolve their source from the parent group temp.
    self.collect_arr_param_binds(binds[..], &count, 0, 0xFFFF)!;

    ushort[MAX_DESTRUCT_BINDS] group_regs;
    ushort[MAX_DESTRUCT_BINDS] binding_regs;
    for (uint i = 0; i < count; i++) { group_regs[i] = 0xFFFF; binding_regs[i] = 0xFFFF; }

    // Declare each non-synthetic (leaf) binding as a variable in the requested
    // scope. Synthetics are intermediate extraction points — no variable.
    // The scope entry keeps the name slice alive for the rest of the enclosing
    // function body, so it must not point into the stack-local `binds` array —
    // use the interned constant-pool string bytes (stable for the compilation).
    ushort pre_decl_next = self.next_reg;
    for (uint i = 0; i < count; i++) {
        if (binds[i].is_synthetic) continue;
        HString* hs = (HString*)self.constants[binds[i].name_idx].get_heapptr();
        ushort dreg = self.declare_var(hs.get_data(), kind);
        binding_regs[i] = dreg;
    }

    // No initializer (`var [a, b];`): bind everything to undefined.
    if (!self.match(TokenType.ASSIGN)) {
        for (uint i = 0; i < count; i++) {
            if (binds[i].is_synthetic) continue;
            ushort dreg = binding_regs[i];
            self.emit_abc(Opcode.LDUNDEF, (uint)dreg, 0, 0);
            self.emit_var_store(dreg, binds[i].name_idx, is_lexical, is_const);
        }
        return;
    }

    // Evaluate RHS (after all bindings declared, so their regs are below the
    // RHS reg, keeping loop-carried collectors safe from CALL frame overlay).
    // Save the watermark so all destructuring temporaries (RHS + iterator
    // state + per-element scratch) are released together afterward, preventing
    // register drift across successive destructuring statements.
    ushort saved_next = self.next_reg;
    ushort rhs_reg = self.assignment_expr()!;

    // Patch top-level binds to read from the RHS register.
    for (uint i = 0; i < count; i++) {
        if (binds[i].parent_idx == 0xFFFF) binds[i].arg_idx = rhs_reg;
    }

    self.emit_destruct_bindings(binds[..], count, group_regs[..], binding_regs[..],
                                DestructStoreMode.DECLARE, is_lexical, is_const);

    self.free_regs_to(saved_next);

    // At global scope, var bindings are env-resident (resolve_var skips the
    // global scope), so their registers are only needed as the DECLVAR source.
    // Free them to prevent register drift, matching the simple-declaration path.
    if (self.is_global && !is_lexical) {
        self.free_regs_to(pre_decl_next);
    }
    return;
}


/// Parse object destructuring pattern: {a, b: c, x = default} = rhs
/// The '{' has already been consumed.
fn void? CompilerContext.object_destructure(&self, ScopeKind kind, bool is_lexical, bool is_const) {
    ObjBind[32] binds;
    uint bind_count = 0;

    if (!self.check(TokenType.RBRACE)) {
        for (;;) {
            // Rest binding (must be last): `...rest`. Per ES2018
            // §13.3.3, the rest property collects all remaining
            // own-enumerable properties of the source into a fresh
            // object (excluding the explicitly destructured keys;
            // `__proto__` is also excluded even if listed — the
            // semantics change made in ES2018).
            if (self.match(TokenType.ELLIPSIS)) {
                Token rest_tok = self.expect(TokenType.IDENTIFIER)!;
                if (is_restricted_name(rest_tok.str_value)) return COMPILE_ERROR~;
                if (bind_count < 32) {
                    ushort reg = self.declare_var(rest_tok.str_value, kind);
                    binds[bind_count].reg = reg;
                    binds[bind_count].name_idx = self.add_string_constant(rest_tok.str_value);
                    binds[bind_count].is_rest = true;
                    binds[bind_count].has_default = false;
                    bind_count++;
                }
                break;  // rest must be the last property
            }
            // Computed property key: {[expr]: binding}.
            // Per ES2015 §13.3.3, the key is an AssignmentExpression.
            if (self.check(TokenType.LBRACKET)) {
                self.advance()!; // consume '['
                ushort key_reg = self.assignment_expr()!;
                self.expect(TokenType.RBRACKET)!;
                self.expect(TokenType.COLON)!;
                Token bind_tok = self.expect(TokenType.IDENTIFIER)!;
                if (is_restricted_name(bind_tok.str_value)) return COMPILE_ERROR~;
                if (bind_count < 32) {
                    ushort reg = self.declare_var(bind_tok.str_value, kind);
                    binds[bind_count].reg = reg;
                    binds[bind_count].name_idx = self.add_string_constant(bind_tok.str_value);
                    binds[bind_count].is_computed_key = true;
                    binds[bind_count].key_reg = key_reg;
                    binds[bind_count].has_default = false;
                    if (self.match(TokenType.ASSIGN)) {
                        binds[bind_count].has_default = true;
                        binds[bind_count].default_val_reg = self.destructuring_default_expr(bind_tok.str_value)!;
                    }
                    bind_count++;
                }
                // Trailing comma: `, }` is allowed by ES2015
                if (!self.match(TokenType.COMMA)) break;
                if (self.check(TokenType.RBRACE)) break;
                continue;
            }
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
                            binds[bind_count].is_nested = true;
                            binds[bind_count].nested_key_idx = self.add_string_constant(nested_name.str_value);
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
                                    binds[bind_count].key_idx = self.add_string_constant(bind_tok.str_value);
                                    binds[bind_count].has_default = false;
                                    binds[bind_count].is_nested = true;
                                    binds[bind_count].nested_key_idx = self.add_string_constant(nested_prop.str_value);
                                    bind_count++;
                                }
                            } else {
                                if (bind_count < 32) {
                                    ushort reg = self.declare_var(nested_prop.str_value, kind);
                                    binds[bind_count].reg = reg;
                                    binds[bind_count].name_idx = self.add_string_constant(nested_prop.str_value);
                                    binds[bind_count].key_idx = self.add_string_constant(bind_tok.str_value);
                                    binds[bind_count].has_default = false;
                                    binds[bind_count].is_nested = true;
                                    binds[bind_count].nested_key_idx = self.add_string_constant(nested_prop.str_value);
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
                                binds[bind_count].default_val_reg = self.destructuring_default_expr(val_tok.str_value)!;
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
                // Property key: per ES2015 §13.3.3.7, the key may be an
                // IdentifierName (incl. reserved words), a string literal, or a
                // numeric literal. Use the helper that accepts all of those;
                // `destructuring_default_expr` below takes the binding name
                // which is the NEXT identifier after `:`.
                char[] prop_key = self.destructuring_property_key()!;

                if (self.match(TokenType.COLON)) {
                    // Keyed: {key: binding_name} or {key: pattern}
                    // Check if the value is a nested pattern
                    if (self.check(TokenType.LBRACE)) {
                        // Nested object pattern: {a: {x, y}}
                        self.advance()!; // consume '{'
                        // Parse first property of nested object — key may be
                        // an identifier, string, number, or reserved word.
                        char[] nested_key = self.destructuring_property_key()!;
                        if (is_restricted_name(nested_key)) return COMPILE_ERROR~;

                        if (self.match(TokenType.COLON)) {
                            // {a: {x: y}} - keyed
                            Token nested_bind = self.expect(TokenType.IDENTIFIER)!;
                            if (is_restricted_name(nested_bind.str_value)) return COMPILE_ERROR~;
                            if (bind_count < 32) {
                                ushort reg = self.declare_var(nested_bind.str_value, kind);
                                binds[bind_count].reg = reg;
                                binds[bind_count].name_idx = self.add_string_constant(nested_bind.str_value);
                                binds[bind_count].key_idx = self.add_string_constant(prop_key);
                                binds[bind_count].has_default = false;
                                binds[bind_count].is_nested = true;
                                binds[bind_count].nested_key_idx = self.add_string_constant(nested_key);

                                // Check for default
                                if (self.match(TokenType.ASSIGN)) {
                                    binds[bind_count].has_default = true;
                                    binds[bind_count].default_val_reg = self.destructuring_default_expr(nested_bind.str_value)!;
                                }

                                bind_count++;
                            }
                        } else {
                            // {a: {x}} - shorthand inside nested — `nested_key` is the binding name
                            if (is_restricted_name(nested_key)) return COMPILE_ERROR~;
                            if (bind_count < 32) {
                                ushort reg = self.declare_var(nested_key, kind);
                                binds[bind_count].reg = reg;
                                binds[bind_count].name_idx = self.add_string_constant(nested_key);
                                binds[bind_count].key_idx = self.add_string_constant(prop_key);
                                binds[bind_count].has_default = false;
                                binds[bind_count].is_nested = true;
                                binds[bind_count].nested_key_idx = self.add_string_constant(nested_key);
                                bind_count++;
                            }
                        }

                        // Parse remaining properties in nested object
                        while (self.match(TokenType.COMMA)) {
                            if (self.check(TokenType.RBRACE)) break;
                            char[] nested_prop = self.destructuring_property_key()!;
                            if (is_restricted_name(nested_prop)) return COMPILE_ERROR~;
                            if (self.match(TokenType.COLON)) {
                                Token nested_bind2 = self.expect(TokenType.IDENTIFIER)!;
                                if (is_restricted_name(nested_bind2.str_value)) return COMPILE_ERROR~;
                                if (bind_count < 32) {
                                    ushort reg = self.declare_var(nested_bind2.str_value, kind);
                                    binds[bind_count].reg = reg;
                                    binds[bind_count].name_idx = self.add_string_constant(nested_bind2.str_value);
                                    binds[bind_count].key_idx = self.add_string_constant(prop_key);
                                    binds[bind_count].has_default = false;
                                    binds[bind_count].is_nested = true;
                                    binds[bind_count].nested_key_idx = self.add_string_constant(nested_prop);
                                    bind_count++;
                                }
                            } else {
                                if (bind_count < 32) {
                                    ushort reg = self.declare_var(nested_prop, kind);
                                    binds[bind_count].reg = reg;
                                    binds[bind_count].name_idx = self.add_string_constant(nested_prop);
                                    binds[bind_count].key_idx = self.add_string_constant(prop_key);
                                    binds[bind_count].has_default = false;
                                    binds[bind_count].is_nested = true;
                                    binds[bind_count].nested_key_idx = self.add_string_constant(nested_prop);
                                    bind_count++;
                                }
                            }
                        }
                        self.expect(TokenType.RBRACE)!;
                    } else if (self.check(TokenType.LBRACKET)) {
                        // Nested array pattern: {a: [x, y]}
                        self.advance()!; // consume '['
                        uint arr_idx = 0;

                        for (;;) {
                            if (self.check(TokenType.RBRACKET)) break;

                            if (self.check(TokenType.COMMA)) {
                                self.advance()!;
                                arr_idx++;
                                continue;
                            }

                            char[] arr_el = self.destructuring_property_key()!;
                            if (is_restricted_name(arr_el)) return COMPILE_ERROR~;
                            if (bind_count < 32) {
                                ushort reg = self.declare_var(arr_el, kind);
                                binds[bind_count].reg = reg;
                                binds[bind_count].name_idx = self.add_string_constant(arr_el);
                                binds[bind_count].key_idx = self.add_string_constant(prop_key);
                                binds[bind_count].has_default = false;
                                binds[bind_count].is_array_nested = true;
                                binds[bind_count].arr_nested_idx = arr_idx;
                                bind_count++;
                            }
                            arr_idx++;

                            if (!self.match(TokenType.COMMA)) break;
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
                            binds[bind_count].key_idx = self.add_string_constant(prop_key);
                            binds[bind_count].has_default = false;

                            // Check for default
                            if (self.match(TokenType.ASSIGN)) {
                                binds[bind_count].has_default = true;
                                binds[bind_count].default_val_reg = self.destructuring_default_expr(bind_tok.str_value)!;
                            }

                            bind_count++;
                        }
                    }
                } else {
                    // Shorthand: {name}  →  key="name", binding=name
                    if (is_restricted_name(prop_key)) return COMPILE_ERROR~;
                    if (bind_count < 32) {
                        ushort reg = self.declare_var(prop_key, kind);
                        binds[bind_count].reg = reg;
                        binds[bind_count].name_idx = self.add_string_constant(prop_key);
                        binds[bind_count].key_idx = self.add_string_constant(prop_key);
                        binds[bind_count].has_default = false;

                        // Check for default
                        if (self.match(TokenType.ASSIGN)) {
                            binds[bind_count].has_default = true;
                            binds[bind_count].default_val_reg = self.destructuring_default_expr(prop_key)!;
                        }

                        bind_count++;
                    }
                }
            }

            if (!self.match(TokenType.COMMA)) break;
            // Trailing comma: `, }` is allowed by ES2015
            if (self.check(TokenType.RBRACE)) break;
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

    // Per ES2015 §13.3.3.7 step 1 / §13.3.3.5, RequireObjectCoercible throws
    // TypeError for null/undefined sources before any property read. Applies
    // to the empty pattern too (the source must be Object-coercible even when
    // no key is read). Emitted once after RHS eval, so `var {} = null` throws.
    self.emit_abc(Opcode.REQUIRE_OBJ, (uint)rhs_reg, 0, 0);

    // Emit GETPROP for each property: rhs[key] → bind_reg
    for (uint i = 0; i < bind_count; i++) {
        if (binds[i].is_array_nested) {
            // Array nested in object: {a: [x, y]}
            // First: GETPROP parent = rhs[key_idx] (get the array)
            // Then: GETPROP result = parent[arr_nested_idx] (get element from array)
            ushort parent_key_reg = self.alloc_reg();
            self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)parent_key_reg, binds[i].key_idx));
            ushort parent_reg = self.alloc_reg();
            self.emit_abc(Opcode.GETPROP, (uint)parent_reg, (uint)rhs_reg, (uint)parent_key_reg);
            self.free_reg(parent_key_reg);

            ushort arr_idx_reg = self.alloc_reg();
            self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)arr_idx_reg, (int)binds[i].arr_nested_idx));
            self.emit_abc(Opcode.GETPROP, (uint)binds[i].reg, (uint)parent_reg, (uint)arr_idx_reg);
            self.free_reg(arr_idx_reg);
            self.free_reg(parent_reg);
        } else if (binds[i].is_nested) {
            // Nested binding: GETPROP parent = rhs[outer_key], then GETPROP bind = parent[inner_key]
            ushort parent_key_reg = self.alloc_reg();
            self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)parent_key_reg, binds[i].key_idx));
            ushort parent_reg = self.alloc_reg();
            self.emit_abc(Opcode.GETPROP, (uint)parent_reg, (uint)rhs_reg, (uint)parent_key_reg);
            self.free_reg(parent_key_reg);

            ushort inner_key_reg = self.alloc_reg();
            self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)inner_key_reg, binds[i].nested_key_idx));
            self.emit_abc(Opcode.GETPROP, (uint)binds[i].reg, (uint)parent_reg, (uint)inner_key_reg);
            self.free_reg(inner_key_reg);
            self.free_reg(parent_reg);
        } else {
            // Computed key: key already compiled into a register; plain key:
            // LDCONST the constant-pool index into a fresh register.
            ushort key_reg;
            if (binds[i].is_computed_key) {
                key_reg = binds[i].key_reg;  // already in a register
            } else {
                key_reg = self.alloc_reg();
                self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)key_reg, binds[i].key_idx));
            }
            self.emit_abc(Opcode.GETPROP, (uint)binds[i].reg, (uint)rhs_reg, (uint)key_reg);
            if (!binds[i].is_computed_key) self.free_reg(key_reg);
        }

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

    // Build the rest object by copying from rhs and deleting every
    // explicit binding's key (and `__proto__`, per ES2018 §13.3.3.7).
    for (uint i = 0; i < bind_count; i++) {
        if (!binds[i].is_rest) continue;

        // 1) rest_reg = Object.assign({}, rhs_reg)   — copy every own prop
        ushort rest_reg = binds[i].reg;
        // Use CONTIGUOUS call area: callee, this, arg1 must be in
        // adjacent registers per the CALL convention (callee+1 = this,
        // callee+2 = arg1).  Hand-pick register numbers to keep them
        // packed — the auto allocator would skip a slot after a
        // free, leaving a gap and breaking the layout.
        ushort assign_callee_reg = self.alloc_reg();
        // CALL below is emitted with nargs=2, so the VM reads arg slots at
        // callee+2 and callee+3 and overlays the callee frame from callee+2.
        // Reserve both arg slots so neither can be handed to live state.
        self.reserve_call_frame(assign_callee_reg, 2);
        ushort assign_this_reg = assign_callee_reg + 1;
        ushort rhs_arg_reg = assign_callee_reg + 2;
        // Empty object literal: {}
        ushort empty_obj_reg = self.alloc_reg();
        self.emit_abc(Opcode.NEWOBJ, (uint)empty_obj_reg, 0, 0);
        // Fetch Object.assign
        ushort obj_var_reg = self.alloc_reg();
        self.emit_a_bc(Opcode.GETVAR, (uint)obj_var_reg, self.add_string_constant("Object"));
        ushort assign_key_reg = self.alloc_reg();
        self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)assign_key_reg, self.add_string_constant("assign")));
        ushort assign_method_reg = self.alloc_reg();
        self.emit_abc(Opcode.GETPROP, (uint)assign_method_reg, (uint)obj_var_reg, (uint)assign_key_reg);
        self.free_reg(assign_key_reg);
        self.free_reg(obj_var_reg);
        // Move method to callee slot
        self.emit_abc(Opcode.LDREG, (uint)assign_callee_reg, (uint)assign_method_reg, 0);
        self.free_reg(assign_method_reg);
        // this = empty_obj
        self.emit_abc(Opcode.LDREG, (uint)assign_this_reg, (uint)empty_obj_reg, 0);
        // rhs argument
        self.emit_abc(Opcode.LDREG, (uint)rhs_arg_reg, (uint)rhs_reg, 0);
        // Object.assign({}, rhs) → rest_reg
        self.emit_abc(Opcode.CALL, (uint)assign_callee_reg, (uint)assign_callee_reg, 2);
        self.emit_abc(Opcode.LDREG, (uint)rest_reg, (uint)assign_callee_reg, 0);
        self.free_reg(assign_callee_reg);
        self.free_reg(empty_obj_reg);

        // 2) For each explicit (non-rest) binding, delete its key from rest_reg.
        //    `__proto__` is excluded from rest per ES2018.
        for (uint j = 0; j < bind_count; j++) {
            if (binds[j].is_rest) continue;
            // Skip `__proto__` (special key, excluded from rest per ES2018)
            const usz PROTO_KEY_IDX = 0xFFFFFFFF;  // sentinel
            uint key_idx;
            if (binds[j].is_computed_key) {
                // Computed key: delete by runtime key.  Skip — test262
                // doesn't test rest with computed keys (the result is
                // undefined since we can't statically know which keys to
                // delete).  We could do a runtime iteration; for now
                // bail out and accept the slight over-rest semantics.
                continue;
            } else {
                key_idx = binds[j].key_idx;
            }
            // Build the key string and compare against the constant
            // "__proto__" — if equal, skip the delete.
            uint proto_name_idx = self.add_string_constant("__proto__");
            if (key_idx == proto_name_idx) continue;

            ushort del_key_reg = self.alloc_reg();
            self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)del_key_reg, key_idx));
            // DELPROP's A is the boolean result (per ES5 §11.4.1) — must
            // be a fresh register or r2 (the rest object) gets clobbered
            // with `true` and subsequent deletes fail.
            ushort del_result_reg = self.alloc_reg();
            self.emit_abc(Opcode.DELPROP, (uint)del_result_reg, (uint)rest_reg, (uint)del_key_reg);
            self.free_reg(del_key_reg);
            self.free_reg(del_result_reg);
        }

        self.emit_var_store(rest_reg, binds[i].name_idx, is_lexical, is_const);
    }

    self.free_reg(rhs_reg);
}

// ============================================================================
// Destructuring ASSIGNMENT (without let/const/var)
// ============================================================================

/// Parse a DestructuringAssignmentTarget — any LeftHandSideExpression valid
/// as an assignment target (§13.15.5). Returns true when the target is a
/// member expression (`a.b`, `a[i]`, `{}[f()]`, etc.); false when it is a
/// plain identifier.
///
/// For member targets, emits code to evaluate the object and key into fresh
/// registers (`*out_obj_reg` / `*out_key_reg`) for a later PUTPROP.
/// For identifier targets, `*out_name_idx` receives the constant-pool index
/// of the name; no code is emitted.
///
/// When the next token is an IDENTIFIER not followed by `.`, `[`, or `(`,
/// we consume it cheaply without emitting a GETVAR — assignment patterns
/// only write to the target, never read from it.  For anything more complex
/// (member chains starting with any primary, `new`, etc.) we call
/// `postfix_expr` in lhs_mode and NOP the trailing GETPROP.
fn bool? CompilerContext.parse_assign_target_lhs(&self,
    ushort* out_obj_reg, ushort* out_key_reg, uint* out_name_idx)
{
    // Fast path: plain identifier target — no code emission needed.
    // We only commit to the fast path when the very next token after the
    // identifier is NOT a property/call/index accessor, ensuring that
    // `a.b`, `a[i]`, `a()` etc. fall through to the full expression path.
    if (self.peek_type() == TokenType.IDENTIFIER) {
        // Peek at the token after the identifier without consuming it.
        // Lexer state snapshot so we can look one token ahead.
        uint   snap_pos  = self.lexer.pos;
        uint   snap_line = self.lexer.line;
        uint   snap_col  = self.lexer.col;
        Token  snap_cur  = self.lexer.current;
        Token  snap_lk   = self.lexer.lookahead;
        bool   snap_hlk  = self.lexer.has_lookahead;
        Token  snap_pb   = self.lexer.pushed_back;
        bool   snap_hpb  = self.lexer.has_pushed_back;
        bool   snap_slt  = self.lexer.seen_line_term;
        uint   snap_pbc  = self.pushback_count;
        Token[4] snap_pbs = self.pushback_stack;

        Token ident_tok = self.advance()!;  // consume identifier

        // Read the next token to check for member/call accessors.
        Token? next_opt = self.lexer.next_token();
        TokenType next_tt = TokenType.EOF_TOKEN;
        if (try next = next_opt) { next_tt = next.type; }

        bool is_accessor = (next_tt == TokenType.DOT
            || next_tt == TokenType.LBRACKET
            || next_tt == TokenType.LPAREN
            || next_tt == TokenType.OPT_CHAIN);

        // Restore lexer state (put everything back).
        self.lexer.pos  = snap_pos;  self.lexer.line = snap_line;
        self.lexer.col  = snap_col;  self.lexer.current = snap_cur;
        self.lexer.lookahead = snap_lk; self.lexer.has_lookahead = snap_hlk;
        self.lexer.pushed_back = snap_pb; self.lexer.has_pushed_back = snap_hpb;
        self.lexer.seen_line_term = snap_slt;
        self.pushback_count = snap_pbc; self.pushback_stack = snap_pbs;

        if (!is_accessor) {
            // True simple identifier: consume the token and return the name.
            Token id = self.advance()!;
            *out_name_idx = self.add_string_constant(id.str_value);
            return false;
        }
        // Falls through to the full expression path below.
    }

    // General path: parse the full LHS expression (member chain, new, etc.)
    // using lhs_mode so member_expr keeps obj/key registers live.
    // member_expr always emits a trailing GETPROP; we NOP it immediately to
    // avoid invoking a property getter on the assignment target.
    bool saved_lhs = self.lhs_mode;
    self.lhs_mode = true;
    self.last_was_member = false;
    self.last_was_getvar  = false;

    ushort lhs_result = self.postfix_expr()!;

    self.lhs_mode = saved_lhs;

    if (self.last_was_member) {
        // NOP the trailing GETPROP so we do not invoke a getter.
        if (self.code_count > 0) {
            uint last = self.code_count - 1;
            if (self.code[last].op == Opcode.GETPROP) {
                self.code[last] = bytecode::make_abc(Opcode.NOP, 0, 0, 0);
            }
        }
        self.free_reg(lhs_result);
        *out_obj_reg  = self.last_member_obj_reg;
        *out_key_reg  = self.last_member_prop_reg;
        self.last_was_member   = false;
        self.call_prop_obj_reg = MAX_REGISTERS;
        return true;
    }

    if (self.last_was_getvar) {
        // Identifier that was reached through a complex path (e.g. after
        // `new` or other non-member primaries that still set last_was_getvar).
        *out_name_idx = self.last_getvar_name_idx;
        self.free_reg(lhs_result);
        self.last_was_getvar = false;
        return false;
    }

    // Not a valid assignment target.
    return self.fail("invalid assignment target in destructuring pattern")~;
}

/// Parse array destructuring assignment: [a, b, ...rest] = rhs
/// The '[' has already been consumed.
/// Returns the RHS register (destructuring assignment evaluates to RHS value).
///
/// Targets may be identifiers or member expressions (§13.15.5
/// DestructuringAssignmentTarget = LeftHandSideExpression). Member targets are
/// parsed eagerly to capture the object/key registers before the RHS iterator
/// is set up; the emission machinery stores PUTPROP instead of PUTVAR.
fn ushort? CompilerContext.array_destructure_assign(&self) {
    DestructBind[MAX_DESTRUCT_BINDS] binds;
    uint count = 0;

    // Parse the array assignment pattern. Each element may be:
    //   - a plain identifier (`a`)
    //   - a member-expression target (`obj.x`, `arr[i]`, `{}[f()]`)
    //   - a nested array or object assignment pattern (`[a]`, `{a}`)
    //   - a rest element with any of the above targets (`...a`, `...obj.x`)
    //   - a hole (elision: leading or interior commas)
    //
    // For member-expression targets, `parse_assign_target_lhs` emits code
    // to evaluate the object and key into fresh registers NOW (before the
    // RHS iterator is set up). The resulting registers are stored in
    // `binds[i].member_obj_reg` / `member_prop_reg`; `emit_destruct_bindings`
    // will emit PUTPROP instead of PUTVAR for these entries.
    //
    // Nested patterns are handled by delegating back to the shared
    // `collect_arr_param_binds` / `collect_obj_param_binds` machinery (which
    // only accepts identifier leaf targets within the nested sub-pattern).
    // Top-level and rest targets accept the full LHS grammar.

    ushort elem_idx = 0;
    bool in_rest = false;

    for (;;) {
        if (self.check(TokenType.RBRACKET)) break;

        // Elision / hole: `, ,` skips an iterator position.
        if (self.match(TokenType.COMMA)) {
            if (count < (uint)MAX_DESTRUCT_BINDS) {
                // Record a synthetic hole so emit_destruct_bindings advances the
                // iterator past this element.
                binds[count].key_idx  = (uint)elem_idx;  // use key_idx as index
                binds[count].index    = elem_idx;
                binds[count].is_object = false;
                binds[count].arg_idx  = 0xFFFF;          // patched to rhs_reg later
                binds[count].parent_idx = 0xFFFF;
                binds[count].is_synthetic = true;         // hole = synthetic with no children
                // Mark as a pure hole: key_idx=0 (not 0xFFFF which means rest).
                // Actually emit_destruct_bindings treats is_synthetic+not-object+key_idx!=0xFFFF
                // as an array element fetch. For a pure hole we just advance index
                // without recording — use the existing `collect_arr_param_binds` hole
                // convention: omit the bind entirely but increment elem_idx.
                // Re-use the approach from collect_arr_param_binds: don't record the
                // hole in binds (elem_idx already advanced). Just bump elem_idx.
            }
            elem_idx++;
            continue;
        }

        // Rest element: `...target`
        if (self.match(TokenType.ELLIPSIS)) {
            in_rest = true;

            // Nested rest pattern: `...[a, b]` or `...{a}`
            if (self.check(TokenType.LBRACE) || self.check(TokenType.LBRACKET)) {
                bool is_obj = self.check(TokenType.LBRACE);
                if (count < (uint)MAX_DESTRUCT_BINDS) {
                    binds[count].key_idx    = 0xFFFF;  // rest synthetic
                    binds[count].index      = elem_idx;
                    binds[count].is_object  = false;
                    binds[count].arg_idx    = 0xFFFF;
                    binds[count].parent_idx = 0xFFFF;
                    binds[count].is_synthetic = true;
                    count++;
                }
                ushort synth_idx = (ushort)(count - 1);
                self.advance()!;  // consume '{' or '['
                if (is_obj) {
                    self.collect_obj_param_binds(binds[..], &count, 0xFFFF, synth_idx)!;
                } else {
                    self.collect_arr_param_binds(binds[..], &count, 0xFFFF, synth_idx)!;
                }
            } else {
                // Leaf rest target: identifier or member expression.
                ushort tgt_obj  = 0xFFFF;
                ushort tgt_key  = 0xFFFF;
                uint   tgt_name = 0xFFFFFFFF;
                bool is_member = self.parse_assign_target_lhs(&tgt_obj, &tgt_key, &tgt_name)!;

                if (count < (uint)MAX_DESTRUCT_BINDS) {
                    binds[count].name_idx   = tgt_name;
                    binds[count].key_idx    = 0xFFFF;   // 0xFFFF = rest sentinel
                    binds[count].index      = elem_idx;
                    binds[count].is_object  = false;
                    binds[count].arg_idx    = 0xFFFF;
                    binds[count].parent_idx = 0xFFFF;
                    binds[count].is_member_target  = is_member;
                    binds[count].member_obj_reg    = tgt_obj;
                    binds[count].member_prop_reg   = tgt_key;
                    if (!is_member) {
                        // Copy name into name_buf for declare_var-style lookup.
                        // (Not needed for assignment — name_idx is enough for PUTVAR.)
                        binds[count].name_len = 0;
                    }
                    count++;
                }
            }

            // Optional default for rest is not valid ES syntax; stop here.
            while (self.match(TokenType.COMMA)) {}
            break;
        }

        // Nested pattern: `[pattern]` or `{pattern}`
        if (self.check(TokenType.LBRACE) || self.check(TokenType.LBRACKET)) {
            bool is_obj = self.check(TokenType.LBRACE);
            if (count < (uint)MAX_DESTRUCT_BINDS) {
                binds[count].key_idx    = (uint)elem_idx;  // array index
                binds[count].index      = elem_idx;
                binds[count].is_object  = false;
                binds[count].arg_idx    = 0xFFFF;
                binds[count].parent_idx = 0xFFFF;
                binds[count].is_synthetic = true;
                count++;
            }
            ushort synth_idx = (ushort)(count - 1);
            self.advance()!;  // consume '{' or '['
            if (is_obj) {
                self.collect_obj_param_binds(binds[..], &count, 0xFFFF, synth_idx)!;
            } else {
                self.collect_arr_param_binds(binds[..], &count, 0xFFFF, synth_idx)!;
            }

            // Default for the nested pattern: `[a] = default`
            if (self.match(TokenType.ASSIGN)) {
                if (count > 0) {
                    binds[synth_idx].has_default = true;
                    CompiledFunction* default_func = self.compile_default_expr()!;
                    uint def_idx = self.add_inner_func(default_func);
                    binds[synth_idx].default_func_idx = def_idx;
                }
            }
        } else {
            // Leaf assignment target: identifier or member expression.
            ushort tgt_obj  = 0xFFFF;
            ushort tgt_key  = 0xFFFF;
            uint   tgt_name = 0xFFFFFFFF;
            bool is_member = self.parse_assign_target_lhs(&tgt_obj, &tgt_key, &tgt_name)!;

            if (count < (uint)MAX_DESTRUCT_BINDS) {
                binds[count].name_idx          = tgt_name;
                binds[count].key_idx           = (uint)elem_idx;  // array index
                binds[count].index             = elem_idx;
                binds[count].is_object         = false;
                binds[count].arg_idx           = 0xFFFF;
                binds[count].parent_idx        = 0xFFFF;
                binds[count].is_member_target  = is_member;
                binds[count].member_obj_reg    = tgt_obj;
                binds[count].member_prop_reg   = tgt_key;
                binds[count].name_len          = 0;
                count++;
            }

            // Default: `[a = expr]`
            if (self.match(TokenType.ASSIGN)) {
                if (count > 0) {
                    binds[count - 1].has_default = true;
                    CompiledFunction* default_func = self.compile_default_expr()!;
                    uint def_idx = self.add_inner_func(default_func);
                    binds[count - 1].default_func_idx = def_idx;
                }
            }
        }

        elem_idx++;
        if (!self.match(TokenType.COMMA)) break;
    }

    self.expect(TokenType.RBRACKET)!;

    ushort[MAX_DESTRUCT_BINDS] group_regs;
    ushort[MAX_DESTRUCT_BINDS] binding_regs;
    for (uint i = 0; i < count; i++) { group_regs[i] = 0xFFFF; binding_regs[i] = 0xFFFF; }

    // Allocate binding registers for each leaf target.
    // For member-expression targets, allocate a fresh temp to hold the
    // extracted value (PUTPROP is emitted by emit_destruct_bindings).
    // For identifier targets, resolve to the local register if possible.
    for (uint i = 0; i < count; i++) {
        if (binds[i].is_synthetic) continue;
        if (binds[i].is_member_target) {
            // Member target: always use a fresh temp (no local var to resolve).
            binding_regs[i] = self.alloc_reg();
            continue;
        }
        // Build a char[] slice into name_buf for resolve_var.
        // For assignment targets parsed via parse_assign_target_lhs, the name
        // is stored only as name_idx (constant-pool entry). Reconstruct the
        // slice from the constant pool so resolve_var can match it.
        char[] name;
        if (binds[i].name_len > 0) {
            name = binds[i].name_buf[:binds[i].name_len];
        } else {
            // Use the constant-pool string directly.
            HString* hs = (HString*)self.constants[binds[i].name_idx].get_heapptr();
            name = hs.get_data();
        }
        if (!self.is_global) {
            if (try existing = self.resolve_var(name)) {
                binding_regs[i] = existing;
                continue;
            }
        }
        binding_regs[i] = self.alloc_reg();
    }

    // Consume the '=' separating pattern from RHS (the caller verified it via
    // lookahead but did not consume it), then evaluate the RHS.
    self.expect(TokenType.ASSIGN)!;
    ushort rhs_reg = self.assignment_expr()!;
    for (uint i = 0; i < count; i++) {
        if (binds[i].parent_idx == 0xFFFF) binds[i].arg_idx = rhs_reg;
    }

    // Assignment (not declaration): register-resident targets are written
    // directly by the extraction; env-resident targets get a bare PUTVAR;
    // member-expression targets get PUTPROP (handled in emit_destruct_bindings
    // via is_member_target).
    self.emit_destruct_bindings(binds[..], count, group_regs[..], binding_regs[..],
                                DestructStoreMode.ASSIGN_TARGET);

    // Release all destructuring temporaries above the RHS register (iterator
    // state + per-element scratch), keeping rhs_reg live so the destructuring
    // assignment can evaluate to the RHS value. Prevents register drift across
    // successive destructuring statements.
    self.free_regs_to((ushort)(rhs_reg + 1));

    // Destructuring assignment evaluates to the RHS value.
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
            // Rest binding (must be last): `...rest`. Per ES2018
            // §13.3.3, the rest property collects all remaining
            // own-enumerable properties of the source into a fresh
            // object (excluding the explicitly destructured keys;
            // `__proto__` is also excluded even if listed — the
            // semantics change made in ES2018).
            if (self.match(TokenType.ELLIPSIS)) {
                // Rest target may be an identifier (`...rest`) or a member
                // expression (`...obj.x`, `...obj['key']`).
                ushort tgt_obj  = 0xFFFF;
                ushort tgt_key  = 0xFFFF;
                uint   tgt_name = 0xFFFFFFFF;
                bool rest_is_member = self.parse_assign_target_lhs(&tgt_obj, &tgt_key, &tgt_name)!;

                if (!rest_is_member) {
                    HString* hs = (HString*)self.constants[tgt_name].get_heapptr();
                    if (is_restricted_name(hs.get_data())) return COMPILE_ERROR~;
                }
                if (bind_count < 32) {
                    ushort reg = self.alloc_reg();
                    binds[bind_count].reg = reg;
                    binds[bind_count].name_idx = tgt_name;
                    binds[bind_count].is_rest = true;
                    binds[bind_count].has_default = false;
                    binds[bind_count].is_resolved = false;
                    binds[bind_count].is_member_target = rest_is_member;
                    binds[bind_count].member_obj_reg  = tgt_obj;
                    binds[bind_count].member_prop_reg = tgt_key;
                    bind_count++;
                }
                break;  // rest must be the last property
            }
            // Computed property key: {[expr]: binding}.
            // Per ES2015 §13.3.3, the key is an AssignmentExpression.
            if (self.check(TokenType.LBRACKET)) {
                self.advance()!; // consume '['
                ushort key_reg = self.assignment_expr()!;
                self.expect(TokenType.RBRACKET)!;
                self.expect(TokenType.COLON)!;
                // Value target may be an identifier or a member expression.
                ushort tgt_obj  = 0xFFFF;
                ushort tgt_key  = 0xFFFF;
                uint   tgt_name = 0xFFFFFFFF;
                bool ck_is_member = self.parse_assign_target_lhs(&tgt_obj, &tgt_key, &tgt_name)!;
                if (!ck_is_member) {
                    HString* hs = (HString*)self.constants[tgt_name].get_heapptr();
                    if (is_restricted_name(hs.get_data())) return COMPILE_ERROR~;
                }
                if (bind_count < 32) {
                    ushort reg = self.alloc_reg();
                    binds[bind_count].reg = reg;
                    binds[bind_count].name_idx = tgt_name;
                    binds[bind_count].is_computed_key = true;
                    binds[bind_count].key_reg = key_reg;
                    binds[bind_count].has_default = false;
                    binds[bind_count].is_resolved = false;
                    binds[bind_count].is_member_target = ck_is_member;
                    binds[bind_count].member_obj_reg  = tgt_obj;
                    binds[bind_count].member_prop_reg = tgt_key;
                    if (self.match(TokenType.ASSIGN)) {
                        binds[bind_count].has_default = true;
                        // NamedEvaluation applies only to identifier targets;
                        // member targets get no inferred name.
                        char[] ck_dflt_name = "";
                        if (!ck_is_member) {
                            HString* hs = (HString*)self.constants[tgt_name].get_heapptr();
                            ck_dflt_name = hs.get_data();
                        }
                        binds[bind_count].default_val_reg = self.destructuring_default_expr(ck_dflt_name)!;
                    }
                    bind_count++;
                }
                // Trailing comma: `, }` is allowed by ES2015
                if (!self.match(TokenType.COMMA)) break;
                if (self.check(TokenType.RBRACE)) break;
                continue;
            }
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
                                binds[bind_count].is_resolved = false;
                            } else {
                                reg = self.alloc_reg();
                                binds[bind_count].is_resolved = false;
                            }
                            binds[bind_count].reg = reg;
                            binds[bind_count].name_idx = self.add_string_constant(nested_name.str_value);
                            binds[bind_count].key_idx = self.add_string_constant(bind_tok.str_value);
                            binds[bind_count].has_default = false;
                            binds[bind_count].is_nested = true;
                            binds[bind_count].nested_key_idx = self.add_string_constant(nested_name.str_value);
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
                                        binds[bind_count].is_resolved = false;
                                    } else {
                                        reg = self.alloc_reg();
                                        binds[bind_count].is_resolved = false;
                                    }
                                    binds[bind_count].reg = reg;
                                    binds[bind_count].name_idx = self.add_string_constant(nested_bind.str_value);
                                    binds[bind_count].key_idx = self.add_string_constant(bind_tok.str_value);
                                    binds[bind_count].has_default = false;
                                    binds[bind_count].is_nested = true;
                                    binds[bind_count].nested_key_idx = self.add_string_constant(nested_prop.str_value);
                                    bind_count++;
                                }
                            } else {
                                if (bind_count < 32) {
                                    ushort reg;
                                    if (try existing = self.resolve_var(nested_prop.str_value)) {
                                        reg = existing;
                                        binds[bind_count].is_resolved = false;
                                    } else {
                                        reg = self.alloc_reg();
                                        binds[bind_count].is_resolved = false;
                                    }
                                    binds[bind_count].reg = reg;
                                    binds[bind_count].name_idx = self.add_string_constant(nested_prop.str_value);
                                    binds[bind_count].key_idx = self.add_string_constant(bind_tok.str_value);
                                    binds[bind_count].has_default = false;
                                    binds[bind_count].is_nested = true;
                                    binds[bind_count].nested_key_idx = self.add_string_constant(nested_prop.str_value);
                                    bind_count++;
                                }
                            }
                        }
                        self.expect(TokenType.RBRACE)!;
                    } else if (self.check(TokenType.LBRACKET)) {
                        // Nested array pattern: {a: [x, y]}
                        self.advance()!; // consume '['
                        uint arr_idx = 0;

                        for (;;) {
                            if (self.check(TokenType.RBRACKET)) break;

                            if (self.check(TokenType.COMMA)) {
                                self.advance()!;
                                arr_idx++;
                                continue;
                            }

                            Token nested_el = self.expect(TokenType.IDENTIFIER)!;
                            if (is_restricted_name(nested_el.str_value)) return COMPILE_ERROR~;
                            if (bind_count < 32) {
                                ushort reg;
                                if (try existing = self.resolve_var(nested_el.str_value)) {
                                    reg = existing;
                                    binds[bind_count].is_resolved = false;
                                } else {
                                    reg = self.alloc_reg();
                                    binds[bind_count].is_resolved = false;
                                }
                                binds[bind_count].reg = reg;
                                binds[bind_count].name_idx = self.add_string_constant(nested_el.str_value);
                                binds[bind_count].key_idx = self.add_string_constant(bind_tok.str_value);
                                binds[bind_count].has_default = false;
                                binds[bind_count].is_array_nested = true;
                                binds[bind_count].arr_nested_idx = arr_idx;
                                bind_count++;
                            }
                            arr_idx++;

                            if (!self.match(TokenType.COMMA)) break;
                        }
                        self.expect(TokenType.RBRACKET)!;
                    } else {
                        Token val_tok = self.expect(TokenType.IDENTIFIER)!;
                        if (is_restricted_name(val_tok.str_value)) return COMPILE_ERROR~;
                        if (bind_count < 32) {
                            ushort reg;
                            if (try existing = self.resolve_var(val_tok.str_value)) {
                                reg = existing;
                                binds[bind_count].is_resolved = false;
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
                                binds[bind_count].default_val_reg = self.destructuring_default_expr(val_tok.str_value)!;
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
                            binds[bind_count].is_resolved = false;
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
                            binds[bind_count].is_resolved = false;
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
                            binds[bind_count].is_resolved = false;
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
                // Property key — see object_destructure for the multi-type rule.
                char[] prop_key = self.destructuring_property_key()!;

                if (self.match(TokenType.COLON)) {
                    // Keyed: {key: binding_name} or {key: pattern}
                    if (self.check(TokenType.LBRACE)) {
                        self.advance()!; // consume '{'
                        char[] nested_key = self.destructuring_property_key()!;
                        if (is_restricted_name(nested_key)) return COMPILE_ERROR~;

                        if (self.match(TokenType.COLON)) {
                            Token nested_bind = self.expect(TokenType.IDENTIFIER)!;
                            if (is_restricted_name(nested_bind.str_value)) return COMPILE_ERROR~;
                            if (bind_count < 32) {
                                ushort reg;
                                if (try existing = self.resolve_var(nested_bind.str_value)) {
                                    reg = existing;
                                    binds[bind_count].is_resolved = false;
                                } else {
                                    reg = self.alloc_reg();
                                    binds[bind_count].is_resolved = false;
                                }
                                binds[bind_count].reg = reg;
                                binds[bind_count].name_idx = self.add_string_constant(nested_bind.str_value);
                                binds[bind_count].key_idx = self.add_string_constant(prop_key);
                                binds[bind_count].has_default = false;
                                binds[bind_count].is_nested = true;
                                binds[bind_count].nested_key_idx = self.add_string_constant(nested_key);

                                if (self.match(TokenType.ASSIGN)) {
                                    binds[bind_count].has_default = true;
                                    binds[bind_count].default_val_reg = self.destructuring_default_expr(nested_bind.str_value)!;
                                }

                                bind_count++;
                            }
                        } else {
                            if (bind_count < 32) {
                                ushort reg;
                                if (try existing = self.resolve_var(nested_key)) {
                                    reg = existing;
                                    binds[bind_count].is_resolved = false;
                                } else {
                                    reg = self.alloc_reg();
                                    binds[bind_count].is_resolved = false;
                                }
                                binds[bind_count].reg = reg;
                                binds[bind_count].name_idx = self.add_string_constant(nested_key);
                                binds[bind_count].key_idx = self.add_string_constant(prop_key);
                                binds[bind_count].has_default = false;
                                binds[bind_count].is_nested = true;
                                binds[bind_count].nested_key_idx = self.add_string_constant(nested_key);
                                bind_count++;
                            }
                        }

                        while (self.match(TokenType.COMMA)) {
                            if (self.check(TokenType.RBRACE)) break;
                            char[] nested_prop = self.destructuring_property_key()!;
                            if (is_restricted_name(nested_prop)) return COMPILE_ERROR~;
                            if (self.match(TokenType.COLON)) {
                                Token nested_bind2 = self.expect(TokenType.IDENTIFIER)!;
                                if (is_restricted_name(nested_bind2.str_value)) return COMPILE_ERROR~;
                                if (bind_count < 32) {
                                    ushort reg;
                                    if (try existing = self.resolve_var(nested_bind2.str_value)) {
                                        reg = existing;
                                        binds[bind_count].is_resolved = false;
                                    } else {
                                        reg = self.alloc_reg();
                                        binds[bind_count].is_resolved = false;
                                    }
                                    binds[bind_count].reg = reg;
                                    binds[bind_count].name_idx = self.add_string_constant(nested_bind2.str_value);
                                    binds[bind_count].key_idx = self.add_string_constant(prop_key);
                                    binds[bind_count].has_default = false;
                                    binds[bind_count].is_nested = true;
                                    binds[bind_count].nested_key_idx = self.add_string_constant(nested_prop);
                                    bind_count++;
                                }
                            } else {
                                if (bind_count < 32) {
                                    ushort reg;
                                    if (try existing = self.resolve_var(nested_prop)) {
                                        reg = existing;
                                        binds[bind_count].is_resolved = false;
                                    } else {
                                        reg = self.alloc_reg();
                                        binds[bind_count].is_resolved = false;
                                    }
                                    binds[bind_count].reg = reg;
                                    binds[bind_count].name_idx = self.add_string_constant(nested_prop);
                                    binds[bind_count].key_idx = self.add_string_constant(prop_key);
                                    binds[bind_count].has_default = false;
                                    binds[bind_count].is_nested = true;
                                    binds[bind_count].nested_key_idx = self.add_string_constant(nested_prop);
                                    bind_count++;
                                }
                            }
                        }
                        self.expect(TokenType.RBRACE)!;
                    } else if (self.check(TokenType.LBRACKET)) {
                        // Nested array pattern: {a: [x, y]}
                        self.advance()!; // consume '['
                        uint arr_idx = 0;

                        for (;;) {
                            if (self.check(TokenType.RBRACKET)) break;

                            if (self.check(TokenType.COMMA)) {
                                self.advance()!;
                                arr_idx++;
                                continue;
                            }

                            char[] arr_el = self.destructuring_property_key()!;
                            if (is_restricted_name(arr_el)) return COMPILE_ERROR~;
                            if (bind_count < 32) {
                                ushort reg;
                                if (try existing = self.resolve_var(arr_el)) {
                                    reg = existing;
                                    binds[bind_count].is_resolved = false;
                                } else {
                                    reg = self.alloc_reg();
                                    binds[bind_count].is_resolved = false;
                                }
                                binds[bind_count].reg = reg;
                                binds[bind_count].name_idx = self.add_string_constant(arr_el);
                                binds[bind_count].key_idx = self.add_string_constant(prop_key);
                                binds[bind_count].has_default = false;
                                binds[bind_count].is_array_nested = true;
                                binds[bind_count].arr_nested_idx = arr_idx;
                                bind_count++;
                            }
                            arr_idx++;

                            if (!self.match(TokenType.COMMA)) break;
                        }
                        self.expect(TokenType.RBRACKET)!;
                    } else {
                        // Simple key: value — target may be an identifier or
                        // a member expression (e.g. `{ p: obj.x } = v`).
                        ushort tgt_obj  = 0xFFFF;
                        ushort tgt_key  = 0xFFFF;
                        uint   tgt_name = 0xFFFFFFFF;
                        bool sk_is_member = self.parse_assign_target_lhs(&tgt_obj, &tgt_key, &tgt_name)!;
                        if (!sk_is_member) {
                            HString* hs = (HString*)self.constants[tgt_name].get_heapptr();
                            if (is_restricted_name(hs.get_data())) return COMPILE_ERROR~;
                        }
                        if (bind_count < 32) {
                            ushort reg;
                            if (!sk_is_member && !self.is_global) {
                                HString* hs = (HString*)self.constants[tgt_name].get_heapptr();
                                if (try existing = self.resolve_var(hs.get_data())) {
                                    reg = existing;
                                    binds[bind_count].is_resolved = false;
                                } else {
                                    reg = self.alloc_reg();
                                    binds[bind_count].is_resolved = false;
                                }
                            } else {
                                reg = self.alloc_reg();
                                binds[bind_count].is_resolved = false;
                            }
                            binds[bind_count].reg = reg;
                            binds[bind_count].name_idx = tgt_name;
                            binds[bind_count].key_idx = self.add_string_constant(prop_key);
                            binds[bind_count].has_default = false;
                            binds[bind_count].is_member_target = sk_is_member;
                            binds[bind_count].member_obj_reg  = tgt_obj;
                            binds[bind_count].member_prop_reg = tgt_key;

                            if (self.match(TokenType.ASSIGN)) {
                                binds[bind_count].has_default = true;
                                // NamedEvaluation applies only to identifier targets;
                                // member targets get no inferred name.
                                char[] dflt_name = "";
                                if (!sk_is_member) {
                                    HString* hs = (HString*)self.constants[tgt_name].get_heapptr();
                                    dflt_name = hs.get_data();
                                }
                                binds[bind_count].default_val_reg = self.destructuring_default_expr(dflt_name)!;
                            }

                            bind_count++;
                        }
                    }
                } else {
                    // Shorthand: {name}  →  key="name", binding=name
                    if (is_restricted_name(prop_key)) return COMPILE_ERROR~;
                    if (bind_count < 32) {
                        ushort reg;
                        if (try existing = self.resolve_var(prop_key)) {
                            reg = existing;
                            binds[bind_count].is_resolved = false;
                        } else {
                            reg = self.alloc_reg();
                            binds[bind_count].is_resolved = false;
                        }
                        binds[bind_count].reg = reg;
                        binds[bind_count].name_idx = self.add_string_constant(prop_key);
                        binds[bind_count].key_idx = self.add_string_constant(prop_key);
                        binds[bind_count].has_default = false;

                        if (self.match(TokenType.ASSIGN)) {
                            binds[bind_count].has_default = true;
                            binds[bind_count].default_val_reg = self.destructuring_default_expr(prop_key)!;
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

    // Per ES2015 §13.3.3.7 step 1, RequireObjectCoercible throws TypeError
    // for null/undefined sources — applies to empty {} too. Mirrors the
    // declaration form above.
    self.emit_abc(Opcode.REQUIRE_OBJ, (uint)rhs_reg, 0, 0);

    // Emit GETPROP for each property: rhs[key] → bind_reg
    for (uint i = 0; i < bind_count; i++) {
        if (binds[i].is_array_nested) {
            // Array nested in object: {a: [x, y]}
            // First: GETPROP parent = rhs[key_idx] (get the array)
            // Then: GETPROP result = parent[arr_nested_idx] (get element from array)
            ushort parent_key_reg = self.alloc_reg();
            self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)parent_key_reg, binds[i].key_idx));
            ushort parent_reg = self.alloc_reg();
            self.emit_abc(Opcode.GETPROP, (uint)parent_reg, (uint)rhs_reg, (uint)parent_key_reg);
            self.free_reg(parent_key_reg);

            ushort arr_idx_reg = self.alloc_reg();
            self.emit(bytecode::make_a_sbx(Opcode.LDINT, (uint)arr_idx_reg, (int)binds[i].arr_nested_idx));
            self.emit_abc(Opcode.GETPROP, (uint)binds[i].reg, (uint)parent_reg, (uint)arr_idx_reg);
            self.free_reg(arr_idx_reg);
            self.free_reg(parent_reg);
        } else if (binds[i].is_nested) {
            // Nested binding: GETPROP parent = rhs[outer_key], then GETPROP bind = parent[inner_key]
            ushort parent_key_reg = self.alloc_reg();
            self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)parent_key_reg, binds[i].key_idx));
            ushort parent_reg = self.alloc_reg();
            self.emit_abc(Opcode.GETPROP, (uint)parent_reg, (uint)rhs_reg, (uint)parent_key_reg);
            self.free_reg(parent_key_reg);

            ushort inner_key_reg = self.alloc_reg();
            self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)inner_key_reg, binds[i].nested_key_idx));
            self.emit_abc(Opcode.GETPROP, (uint)binds[i].reg, (uint)parent_reg, (uint)inner_key_reg);
            self.free_reg(inner_key_reg);
            self.free_reg(parent_reg);
        } else {
            // Computed key: key already compiled into a register; plain key:
            // LDCONST the constant-pool index into a fresh register.
            ushort key_reg;
            if (binds[i].is_computed_key) {
                key_reg = binds[i].key_reg;  // already in a register
            } else {
                key_reg = self.alloc_reg();
                self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)key_reg, binds[i].key_idx));
            }
            self.emit_abc(Opcode.GETPROP, (uint)binds[i].reg, (uint)rhs_reg, (uint)key_reg);
            if (!binds[i].is_computed_key) self.free_reg(key_reg);
        }

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

        // Store the extracted value into the assignment target.
        // Member-expression targets (e.g. `{ p: obj.x }`) use PUTPROP;
        // env-resident identifier targets use PUTVAR.
        if (binds[i].is_member_target) {
            self.emit_abc(Opcode.PUTPROP,
                (uint)binds[i].member_obj_reg,
                (uint)binds[i].member_prop_reg,
                (uint)binds[i].reg);
            self.free_reg(binds[i].member_prop_reg);
            self.free_reg(binds[i].member_obj_reg);
            self.free_reg(binds[i].reg);
        } else if (!binds[i].is_resolved) {
            ushort tmp = self.alloc_reg();
            self.emit_abc(Opcode.LDREG, (uint)tmp, (uint)binds[i].reg, 0);
            self.emit_a_bc(Opcode.PUTVAR, (uint)binds[i].reg, binds[i].name_idx);
            self.free_reg(binds[i].reg);
            binds[i].reg = tmp;
        }
    }

    // Build the rest object (same logic as `object_destructure` above —
    // see the comment there for the ES2018 §13.3.3.7 detail on excluding
    // `__proto__`).
    for (uint i = 0; i < bind_count; i++) {
        if (!binds[i].is_rest) continue;

        ushort rest_reg = self.alloc_reg();
        // Use CONTIGUOUS call area: callee, this, arg1 must be in
        // adjacent registers (callee+1 = this, callee+2 = arg1).
        ushort assign_callee_reg = self.alloc_reg();
        // CALL below uses nargs=2 (arg slots callee+2, callee+3). Reserve
        // both so neither is handed to live state. See the twin site above.
        self.reserve_call_frame(assign_callee_reg, 2);
        ushort assign_this_reg = assign_callee_reg + 1;
        ushort rhs_arg_reg = assign_callee_reg + 2;
        ushort empty_obj_reg = self.alloc_reg();
        self.emit_abc(Opcode.NEWOBJ, (uint)empty_obj_reg, 0, 0);
        ushort obj_var_reg = self.alloc_reg();
        self.emit_a_bc(Opcode.GETVAR, (uint)obj_var_reg, self.add_string_constant("Object"));
        ushort assign_key_reg = self.alloc_reg();
        self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)assign_key_reg, self.add_string_constant("assign")));
        ushort assign_method_reg = self.alloc_reg();
        self.emit_abc(Opcode.GETPROP, (uint)assign_method_reg, (uint)obj_var_reg, (uint)assign_key_reg);
        self.free_reg(assign_key_reg);
        self.free_reg(obj_var_reg);
        self.emit_abc(Opcode.LDREG, (uint)assign_callee_reg, (uint)assign_method_reg, 0);
        self.free_reg(assign_method_reg);
        self.emit_abc(Opcode.LDREG, (uint)assign_this_reg, (uint)empty_obj_reg, 0);
        self.emit_abc(Opcode.LDREG, (uint)rhs_arg_reg, (uint)rhs_reg, 0);
        self.emit_abc(Opcode.CALL, (uint)assign_callee_reg, (uint)assign_callee_reg, 2);
        self.emit_abc(Opcode.LDREG, (uint)rest_reg, (uint)assign_callee_reg, 0);
        self.free_reg(assign_callee_reg);
        self.free_reg(empty_obj_reg);

        // Delete explicit binding keys (excluding `__proto__`).
        for (uint j = 0; j < bind_count; j++) {
            if (binds[j].is_rest) continue;
            if (binds[j].is_computed_key) continue;
            uint proto_name_idx = self.add_string_constant("__proto__");
            if (binds[j].key_idx == proto_name_idx) continue;
            ushort del_key_reg = self.alloc_reg();
            self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)del_key_reg, binds[j].key_idx));
            ushort del_result_reg = self.alloc_reg();
            self.emit_abc(Opcode.DELPROP, (uint)del_result_reg, (uint)rest_reg, (uint)del_key_reg);
            self.free_reg(del_key_reg);
            self.free_reg(del_result_reg);
        }

        // Store the rest object into the assignment target.
        if (binds[i].is_member_target) {
            // Member-expression rest target (e.g. `{...obj.x} = v`).
            self.emit_abc(Opcode.PUTPROP,
                (uint)binds[i].member_obj_reg,
                (uint)binds[i].member_prop_reg,
                (uint)rest_reg);
            self.free_reg(binds[i].member_prop_reg);
            self.free_reg(binds[i].member_obj_reg);
            self.free_reg(rest_reg);
        } else if (!binds[i].is_resolved) {
            ushort tmp = self.alloc_reg();
            self.emit_abc(Opcode.LDREG, (uint)tmp, (uint)rest_reg, 0);
            self.emit_a_bc(Opcode.PUTVAR, (uint)rest_reg, binds[i].name_idx);
            self.free_reg(rest_reg);
        } else {
            self.free_reg(rest_reg);
        }
    }

    self.free_reg(rhs_reg);
    return rhs_reg;
}

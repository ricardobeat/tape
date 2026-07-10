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

    if (count == 0) {
        // Empty pattern `var [] = rhs`: still GetIterator(rhs), so
        // `var [] = undefined` throws TypeError per the spec.
        self.emit_empty_array_iter(rhs_reg);
    } else {
        self.emit_destruct_bindings(binds[..], count, group_regs[..], binding_regs[..],
                                    DestructStoreMode.DECLARE, is_lexical, is_const);
    }

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
    // Collect the pattern into the shared DestructBind model, then declare each
    // leaf and emit via the single emit_destruct_bindings — the same machinery
    // used by array_destructure, function parameters, and for-of. The '{' has
    // already been consumed; collect_obj_param_binds consumes its own '}'.
    DestructBind[MAX_DESTRUCT_BINDS] binds;
    uint count = 0;
    self.collect_obj_param_binds(binds[..], &count, 0, 0xFFFF)!;

    ushort[MAX_DESTRUCT_BINDS] group_regs;
    ushort[MAX_DESTRUCT_BINDS] binding_regs;
    for (uint i = 0; i < count; i++) { group_regs[i] = 0xFFFF; binding_regs[i] = 0xFFFF; }

    // Declare each non-synthetic leaf binding in the requested scope. The name
    // slice must outlive the enclosing body, so use the interned constant-pool
    // bytes rather than the stack-local binds array.
    ushort pre_decl_next = self.next_reg;
    for (uint i = 0; i < count; i++) {
        if (binds[i].is_synthetic) continue;
        HString* hs = (HString*)self.constants[binds[i].name_idx].get_heapptr();
        ushort dreg = self.declare_var(hs.get_data(), kind);
        binding_regs[i] = dreg;
    }

    // No initializer (`var {a};` — only valid via for-in/of heads, but keep the
    // path): bind everything to undefined. RequireObjectCoercible does not apply
    // without a source value.
    if (!self.match(TokenType.ASSIGN)) {
        for (uint i = 0; i < count; i++) {
            if (binds[i].is_synthetic) continue;
            self.emit_abc(Opcode.LDUNDEF, (uint)binding_regs[i], 0, 0);
            self.emit_var_store(binding_regs[i], binds[i].name_idx, is_lexical, is_const);
        }
        return;
    }

    ushort saved_next = self.next_reg;
    ushort rhs_reg = self.assignment_expr()!;

    // RequireObjectCoercible: an object pattern rejects null/undefined even when
    // empty (§13.3.3.6).
    self.emit_abc(Opcode.REQUIRE_OBJ, (uint)rhs_reg, 0, 0);

    for (uint i = 0; i < count; i++) {
        if (binds[i].parent_idx == 0xFFFF) binds[i].arg_idx = rhs_reg;
    }

    self.emit_destruct_bindings(binds[..], count, group_regs[..], binding_regs[..],
                                DestructStoreMode.DECLARE, is_lexical, is_const);

    self.free_regs_to(saved_next);

    // At global scope, var bindings are env-resident; free their registers to
    // prevent drift (matching array_destructure).
    if (self.is_global && !is_lexical) {
        self.free_regs_to(pre_decl_next);
    }
    return;
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
/// Collect an array assignment pattern into the shared DestructBind model.
/// Accepts the full LeftHandSideExpression grammar at top level and in rest
/// (identifiers, member expressions, nested array/object patterns, defaults,
/// elision holes). Consumes through the closing ']'. Shared by
/// array_destructure_assign and the bare for-of loop.
fn void? CompilerContext.collect_arr_assign_binds(&self,
    DestructBind[] binds_arg, uint* count_ptr)
{
    DestructBind[] binds = binds_arg;
    uint count = *count_ptr;
    ushort elem_idx = 0;
    bool in_rest = false;

    for (;;) {
        if (self.check(TokenType.RBRACKET)) break;

        // Elision / hole: `, ,` skips an iterator position. Record a hole so
        // emit_destruct_bindings calls IteratorStep at this position per
        // IteratorBindingInitialization §13.3.3 (matching collect_arr_param_binds).
        if (self.match(TokenType.COMMA)) {
            if (count < (uint)MAX_DESTRUCT_BINDS) {
                binds[count].key_idx    = 0;
                binds[count].index      = elem_idx;
                binds[count].is_object  = false;
                binds[count].arg_idx    = 0xFFFF;          // patched to rhs_reg later
                binds[count].parent_idx = 0xFFFF;
                binds[count].is_synthetic = true;
                binds[count].is_hole    = true;
                count++;
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

            // Default: `[a = expr]` — NamedEvaluation for identifier targets.
            if (self.match(TokenType.ASSIGN)) {
                if (count > 0) {
                    binds[count - 1].has_default = true;
                    char[] iname = "";
                    if (!is_member) {
                        HString* nhs = (HString*)self.constants[tgt_name].get_heapptr();
                        iname = nhs.get_data();
                    }
                    CompiledFunction* default_func = self.compile_default_expr(iname)!;
                    uint def_idx = self.add_inner_func(default_func);
                    binds[count - 1].default_func_idx = def_idx;
                }
            }
        }

        elem_idx++;
        if (!self.match(TokenType.COMMA)) break;
    }

    self.expect(TokenType.RBRACKET)!;
    *count_ptr = count;
}

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

    self.collect_arr_assign_binds(binds[..], &count)!;

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
        // Env-resident target: temp + forced PUTVAR so const-assignment throws.
        binding_regs[i] = self.alloc_reg();
        binds[i].assign_needs_putvar = true;
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
    if (count == 0) {
        // Empty pattern `[] = rhs`: still GetIterator(rhs) then close, so
        // `[] = undefined` throws TypeError per the spec.
        self.emit_empty_array_iter(rhs_reg);
    } else {
        self.emit_destruct_bindings(binds[..], count, group_regs[..], binding_regs[..],
                                    DestructStoreMode.ASSIGN_TARGET);
    }

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
/// Collect an object assignment pattern into the shared DestructBind model.
/// Handles: shorthand `{a}`, `{key: target}`, computed keys `{[e]: t}`,
/// member-expression targets (`{a: obj.x}`), nested array/object targets
/// (delegated to the param collectors, identifier leaves only), defaults
/// (`{a = d}`, `{a: t = d}`), and object rest (`{...target}`). Targets accept
/// the full LeftHandSideExpression grammar at the top level and in rest.
/// The '{' has already been consumed; this consumes its own '}'.
fn void? CompilerContext.collect_obj_assign_binds(&self,
    DestructBind[] binds, uint* count)
{
    if (self.check(TokenType.RBRACE)) { self.advance()!; return; }

    for (;;) {
        if (self.check(TokenType.RBRACE)) break;

        // Object rest: `{...target}` — must be last.
        if (self.match(TokenType.ELLIPSIS)) {
            ushort tgt_obj  = 0xFFFF;
            ushort tgt_key  = 0xFFFF;
            uint   tgt_name = 0xFFFFFFFF;
            bool is_member = self.parse_assign_target_lhs(&tgt_obj, &tgt_key, &tgt_name)!;
            if (!is_member) {
                HString* hs = (HString*)self.constants[tgt_name].get_heapptr();
                if (is_restricted_name(hs.get_data())) return COMPILE_ERROR~;
            }
            if (*count < binds.len) {
                binds[*count].name_idx         = tgt_name;
                binds[*count].key_idx          = 0xFFFF;   // object-rest sentinel
                binds[*count].is_object        = true;
                binds[*count].arg_idx          = 0xFFFF;
                binds[*count].parent_idx       = 0xFFFF;
                binds[*count].is_member_target = is_member;
                binds[*count].member_obj_reg   = tgt_obj;
                binds[*count].member_prop_reg  = tgt_key;
                binds[*count].name_len         = 0;
                (*count)++;
            }
            break;  // rest is the last property
        }

        // Property key: computed `[expr]`, or a literal/identifier key.
        bool is_computed = false;
        ushort computed_key_reg = 0xFFFF;
        uint key_idx = 0xFFFFFFFF;
        if (self.check(TokenType.LBRACKET)) {
            self.advance()!; // consume '['
            computed_key_reg = self.assignment_expr()!;
            self.expect(TokenType.RBRACKET)!;
            self.expect(TokenType.COLON)!;
            is_computed = true;
        } else {
            char[] key = self.destructuring_property_key()!;
            key_idx = self.add_string_constant(key);
        }

        // Shorthand `{a}` / `{a = d}`: no colon → the key is also the target name.
        bool shorthand = !is_computed && !self.check(TokenType.COLON);
        if (!is_computed && !shorthand) {
            self.expect(TokenType.COLON)!;
        }

        if (shorthand) {
            // `{a}` or `{a = d}` — identifier target named by the key.
            HString* hs = (HString*)self.constants[key_idx].get_heapptr();
            if (is_restricted_name(hs.get_data())) return COMPILE_ERROR~;
            if (*count < binds.len) {
                binds[*count].name_idx    = key_idx;
                binds[*count].key_idx     = key_idx;
                binds[*count].is_object   = true;
                binds[*count].arg_idx     = 0xFFFF;
                binds[*count].parent_idx  = 0xFFFF;
                binds[*count].name_len    = 0;
                (*count)++;
            }
            if (self.match(TokenType.ASSIGN)) {
                binds[*count - 1].has_default = true;
                // NamedEvaluation: `{a = fn}` names the anonymous fn "a".
                HString* nhs = (HString*)self.constants[key_idx].get_heapptr();
                CompiledFunction* df = self.compile_default_expr(nhs.get_data())!;
                binds[*count - 1].default_func_idx = self.add_inner_func(df);
            }
        } else if (self.check(TokenType.LBRACKET) || self.check(TokenType.LBRACE)) {
            // Nested pattern target: `key: [..]` / `key: {..}`. Emit a synthetic
            // group whose value is source[key]; delegate the sub-pattern to the
            // param collectors (identifier leaves only, like array assign).
            bool nested_is_obj = self.check(TokenType.LBRACE);
            uint synth = *count;
            if (*count < binds.len) {
                binds[*count].key_idx     = key_idx;
                binds[*count].is_object   = true;
                binds[*count].is_computed_key = is_computed;
                binds[*count].computed_key_reg = computed_key_reg;
                binds[*count].arg_idx     = 0xFFFF;
                binds[*count].parent_idx  = 0xFFFF;
                binds[*count].is_synthetic = true;
                (*count)++;
            }
            self.advance()!; // consume '[' or '{'
            if (nested_is_obj) {
                self.collect_obj_param_binds(binds, count, 0xFFFF, (ushort)synth)!;
            } else {
                self.collect_arr_param_binds(binds, count, 0xFFFF, (ushort)synth)!;
            }
            if (self.match(TokenType.ASSIGN)) {
                binds[synth].has_default = true;
                CompiledFunction* df = self.compile_default_expr()!;
                binds[synth].default_func_idx = self.add_inner_func(df);
            }
        } else {
            // `key: target` — target is an identifier or member expression.
            ushort tgt_obj  = 0xFFFF;
            ushort tgt_key  = 0xFFFF;
            uint   tgt_name = 0xFFFFFFFF;
            bool is_member = self.parse_assign_target_lhs(&tgt_obj, &tgt_key, &tgt_name)!;
            if (!is_member) {
                HString* hs = (HString*)self.constants[tgt_name].get_heapptr();
                if (is_restricted_name(hs.get_data())) return COMPILE_ERROR~;
            }
            if (*count < binds.len) {
                binds[*count].name_idx         = tgt_name;
                binds[*count].key_idx          = key_idx;
                binds[*count].is_object        = true;
                binds[*count].is_computed_key  = is_computed;
                binds[*count].computed_key_reg = computed_key_reg;
                binds[*count].arg_idx          = 0xFFFF;
                binds[*count].parent_idx       = 0xFFFF;
                binds[*count].is_member_target = is_member;
                binds[*count].member_obj_reg   = tgt_obj;
                binds[*count].member_prop_reg  = tgt_key;
                binds[*count].name_len         = 0;
                (*count)++;
            }
            if (self.match(TokenType.ASSIGN)) {
                binds[*count - 1].has_default = true;
                // NamedEvaluation for `{k: t = fn}` — only identifier targets.
                char[] iname = "";
                if (!is_member) {
                    HString* nhs = (HString*)self.constants[tgt_name].get_heapptr();
                    iname = nhs.get_data();
                }
                CompiledFunction* df = self.compile_default_expr(iname)!;
                binds[*count - 1].default_func_idx = self.add_inner_func(df);
            }
        }

        if (!self.match(TokenType.COMMA)) break;
    }

    self.expect(TokenType.RBRACE)!;
}

/// Parse object destructuring assignment: {a, b: c, x = default} = rhs
/// The '{' has already been consumed.
/// Returns the RHS register (destructuring assignment evaluates to RHS value).
fn ushort? CompilerContext.object_destructure_assign(&self) {
    DestructBind[MAX_DESTRUCT_BINDS] binds;
    uint count = 0;
    self.collect_obj_assign_binds(binds[..], &count)!;

    ushort[MAX_DESTRUCT_BINDS] group_regs;
    ushort[MAX_DESTRUCT_BINDS] binding_regs;
    for (uint i = 0; i < count; i++) { group_regs[i] = 0xFFFF; binding_regs[i] = 0xFFFF; }

    // Allocate a binding register per leaf: member targets and unresolvable
    // identifiers get a fresh temp; resolvable locals reuse their slot.
    for (uint i = 0; i < count; i++) {
        if (binds[i].is_synthetic) continue;
        if (binds[i].is_member_target) { binding_regs[i] = self.alloc_reg(); continue; }
        HString* hs = (HString*)self.constants[binds[i].name_idx].get_heapptr();
        char[] name = hs.get_data();
        if (!self.is_global) {
            if (try existing = self.resolve_var(name)) { binding_regs[i] = existing; continue; }
        }
        // Env-resident target (global, or captured/undeclared from a nested
        // scope): use a temp and force PUTVAR so the const-assignment check runs.
        binding_regs[i] = self.alloc_reg();
        binds[i].assign_needs_putvar = true;
    }

    self.expect(TokenType.ASSIGN)!;
    ushort rhs_reg = self.assignment_expr()!;

    // RequireObjectCoercible on the source (object pattern rejects null/undefined
    // even when empty).
    self.emit_abc(Opcode.REQUIRE_OBJ, (uint)rhs_reg, 0, 0);

    for (uint i = 0; i < count; i++) {
        if (binds[i].parent_idx == 0xFFFF) binds[i].arg_idx = rhs_reg;
    }

    if (count > 0) {
        self.emit_destruct_bindings(binds[..], count, group_regs[..], binding_regs[..],
                                    DestructStoreMode.ASSIGN_TARGET);
    }

    self.free_regs_to((ushort)(rhs_reg + 1));
    return rhs_reg;
}

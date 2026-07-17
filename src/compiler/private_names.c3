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
// Private class members (ES2022) — name resolution
//
// Each private name (`#foo`) declared in a class body gets a compiler-managed
// lexical variable in the scope enclosing the class (declared the same way
// as `__super__`, see class.c3), holding the per-evaluation runtime hidden
// symbol.  A stack of PrivateNameEntry records — scoped by class nesting —
// backs `resolve_private_name`; there is no get-or-create, so a reference to
// an undeclared name is a compile-time SyntaxError.
// ============================================================================

/// Push a fresh private-name scope for a class body about to be parsed.
fn void CompilerContext.push_private_scope(&self) {
    if (self.private_scope_depth < MAX_CLASS_NESTING) {
        self.private_scope_start[self.private_scope_depth] = self.private_name_count;
        self.private_scope_depth++;
    }
}

/// Pop the innermost private-name scope, discarding names declared inside it.
fn void CompilerContext.pop_private_scope(&self) {
    if (self.private_scope_depth > 0) {
        self.private_scope_depth--;
        self.private_name_count = self.private_scope_start[self.private_scope_depth];
    }
}

/// Declare a private name in the innermost (current) class scope.  Returns
/// a pointer to the new entry, or a fault on duplicate declaration (the
/// caller reports the SyntaxError) or table overflow.
///
/// Duplicate detection is scoped to the CURRENT class body only (names in
/// the same source span between the matching push/pop_private_scope calls);
/// an outer class's `#x` is legitimately shadowed by an inner class's own
/// `#x`, mirroring the spec's per-class PrivateEnvironment.
fn PrivateNameEntry*? CompilerContext.declare_private_name(&self, char[] name) {
    uint scope_begin = self.private_scope_depth > 0
        ? self.private_scope_start[self.private_scope_depth - 1] : 0;
    for (uint i = scope_begin; i < self.private_name_count; i++) {
        if (str_eq(self.private_names[i].name, name)) {
            return COMPILE_ERROR~;  // duplicate declaration
        }
    }
    if (self.private_name_count >= MAX_PRIVATE_NAMES) {
        return COMPILE_ERROR~;
    }
    uint idx = self.private_name_count;
    self.private_names[idx].name = name;
    self.private_names[idx].is_method = false;
    self.private_names[idx].has_getter = false;
    self.private_names[idx].has_setter = false;

    // Lexical binding name for the runtime symbol slot, e.g. "#priv:foo".
    // The '#' prefix is source-illegal as an identifier start (HASH_IDENT
    // tokens never include it), so user code can never collide with this
    // binding by name.
    char[80] slot_name_buf;
    char[] prefix = "#priv:";
    usz total_len = prefix.len + name.len;
    if (total_len > slot_name_buf.len) total_len = slot_name_buf.len;
    usz copy_name_len = total_len > prefix.len ? total_len - prefix.len : 0;
    for (usz i = 0; i < prefix.len; i++) slot_name_buf[i] = prefix[i];
    for (usz i = 0; i < copy_name_len; i++) slot_name_buf[prefix.len + i] = name[i];

    ushort slot_reg = self.declare_var(slot_name_buf[:total_len], LET);
    (void)slot_reg;
    self.private_names[idx].name_idx = self.add_string_constant(slot_name_buf[:total_len]);

    self.private_name_count++;
    return &self.private_names[idx];
}

/// Declare the class brand (one per class body that has any private member).
/// Uses a source-illegal name distinct from any user private name so it can
/// never be resolved via `resolve_private_name`.  Returns the string
/// constant index of the brand's lexical binding name (for this context's
/// own NEW_PRIV_SYM/PUTLEX emission — see class.c3).
fn uint CompilerContext.declare_class_brand(&self) {
    char[] brand_name = "#priv:brand";
    ushort slot_reg = self.declare_var(brand_name, LET);
    (void)slot_reg;
    return self.add_string_constant(brand_name);
}

/// Return the interned HString* for a lexical binding name (e.g.
/// "#priv:brand" or a private name's own "#priv:foo" slot name), as a raw
/// void* independent of any particular CompilerContext's constant pool.
/// Used to stamp CompiledFunction.brand_name_hstr / resolve field-init
/// symbols at construction time, when the reading code (VM construct path)
/// has no access to the class-enclosing context's constants array.
fn void* CompilerContext.intern_private_binding_name(&self, char[] name) {
    Heap* hp = (Heap*)self.heap;
    HString* hstr = hp.str_intern(name);
    return (void*)hstr;
}

/// Resolve a private name (without '#') to its declaring entry, searching
/// from the innermost enclosing class scope outward.  Returns a fault
/// (SyntaxError) if no enclosing class declares this name.
fn PrivateNameEntry*? CompilerContext.resolve_private_name(&self, char[] name) {
    uint i = self.private_name_count;
    while (i > 0) {
        i--;
        if (str_eq(self.private_names[i].name, name)) {
            return &self.private_names[i];
        }
    }
    return COMPILE_ERROR~;
}

/// Pre-scan a class body for private-name DECLARATIONS (Phase A, plan 054
/// §2a) and declare them all before any member body compiles, so that a
/// field initializer may forward-reference a `#name` declared later in the
/// same class.  The lexer must be positioned just BEFORE the class body's
/// opening `{`; on return the lexer state is fully restored (mirrors
/// pre_scan_captures / the for-loop LHS snapshot machinery).
///
/// Declarations recognised: `#name` at the class body's top nesting level,
/// immediately preceded by nothing, `static`, `get`, `set`, `async`, or `*`
/// (i.e. `#name` as a class-element key, not `this.#name` or `obj?.#name`
/// inside a method body, which never appear at brace-depth 0 relative to
/// the class body's own `{`).
fn void? CompilerContext.prescan_private_names(&self) {
    uint saved_pos    = self.lexer.pos;
    uint saved_line    = self.lexer.line;
    uint saved_col      = self.lexer.col;
    Token saved_cur    = self.lexer.current;
    Token saved_look    = self.lexer.lookahead;
    bool  saved_haslk   = self.lexer.has_lookahead;
    Token saved_push    = self.lexer.pushed_back;
    bool  saved_haspb   = self.lexer.has_pushed_back;
    bool  saved_slt     = self.lexer.seen_line_term;

    // Expect the class body's opening brace.
    Token? open_opt = self.lexer.next_token();
    if (catch _e = open_opt) {
        self.restore_prescan_lexer(saved_pos, saved_line, saved_col, saved_cur, saved_look, saved_haslk, saved_push, saved_haspb, saved_slt);
        return;
    }
    if (open_opt.type != TokenType.LBRACE) {
        self.restore_prescan_lexer(saved_pos, saved_line, saved_col, saved_cur, saved_look, saved_haslk, saved_push, saved_haspb, saved_slt);
        return;
    }

    uint depth = 1;  // inside the class body's own braces
    uint template_depth = 0;  // open template substitution levels
    TokenType prev_tt = TokenType.EOF_TOKEN;
    while (depth > 0) {
        Token? tok_opt = self.lexer.next_token();
        if (catch _e2 = tok_opt) break;
        Token tok = tok_opt;
        if (tok.type == TokenType.EOF_TOKEN) break;

        if (tok.type == TokenType.TEMPLATE_HEAD) {
            // The lexer consumed `...${; expression tokens follow, then a
            // RBRACE that belongs to the template substitution, not a block.
            template_depth++;
        } else if (tok.type == TokenType.RBRACE && template_depth > 0) {
            Token? part_opt = self.lexer.scan_template_after_expr();
            if (catch _e3 = part_opt) break;
            if (part_opt.type != TokenType.TEMPLATE_MIDDLE) {
                template_depth--;
            }
        } else if (tok.type == TokenType.LBRACE) {
            depth++;
        } else if (tok.type == TokenType.RBRACE) {
            depth--;
        } else if (tok.type == TokenType.HASH_IDENT && depth == 1) {
            // A HASH_IDENT at the class body's own nesting level is always a
            // declaration (method bodies/computed keys/initializers push
            // depth past 1 via their own `{`/`(`/`[`; `this.#x` accesses
            // never occur directly inside the class-body braces).
            char[] name = tok.str_value;
            bool is_ctor_name = str_eq(name, "constructor");
            if (is_ctor_name) {
                // #constructor is a SyntaxError (spec: forbidden private name).
                self.restore_prescan_lexer(saved_pos, saved_line, saved_col, saved_cur, saved_look, saved_haslk, saved_push, saved_haspb, saved_slt);
                return self.fail("#constructor is not allowed as a private name")~;
            }
            if (catch derr = self.declare_private_name(name)) {
                self.restore_prescan_lexer(saved_pos, saved_line, saved_col, saved_cur, saved_look, saved_haslk, saved_push, saved_haspb, saved_slt);
                return self.fail("duplicate private name declaration")~;
            }
        }
        prev_tt = tok.type;
    }
    (void)prev_tt;

    self.restore_prescan_lexer(saved_pos, saved_line, saved_col, saved_cur, saved_look, saved_haslk, saved_push, saved_haspb, saved_slt);
}

/// Restore lexer state captured before prescan_private_names ran.
fn void CompilerContext.restore_prescan_lexer(&self, uint pos, uint line, uint col,
        Token cur, Token look, bool haslk, Token push, bool haspb, bool slt) {
    self.lexer.pos             = pos;
    self.lexer.line            = line;
    self.lexer.col             = col;
    self.lexer.current         = cur;
    self.lexer.lookahead       = look;
    self.lexer.has_lookahead   = haslk;
    self.lexer.pushed_back     = push;
    self.lexer.has_pushed_back = haspb;
    self.lexer.seen_line_term  = slt;
}

/// Emit the shared prelude for a private-field access `obj.#name`: resolve
/// the name (SyntaxError if undeclared), CHK_BRAND `obj_reg` against the
/// OWNING CLASS's brand symbol (own-only presence check; TypeError at
/// runtime if absent — the brand, not this field's own key, is the
/// unforgeable per-class marker every field/method shares), then load this
/// name's own runtime symbol into a fresh register via GETVAR. Returns the
/// register holding the resolved field symbol — the caller emits
/// GETPROP/PUTPROP with it.
fn ushort? CompilerContext.emit_private_access(&self, char[] name, ushort obj_reg) {
    PrivateNameEntry* entry = self.resolve_private_name(name)!;
    ushort brand_reg = self.alloc_reg();
    self.emit(bytecode::make_a_bc(Opcode.GETVAR, (uint)brand_reg, entry.brand_name_idx));
    uint name_const_idx = self.add_string_constant(name);
    uint name_c = name_const_idx <= 0xFE ? name_const_idx : 0xFF;
    self.emit_abc(Opcode.CHK_BRAND, (uint)obj_reg, (uint)brand_reg, name_c);
    self.free_reg(brand_reg);

    ushort key_reg = self.alloc_reg();
    self.emit(bytecode::make_a_bc(Opcode.GETVAR, (uint)key_reg, entry.name_idx));
    return key_reg;
}

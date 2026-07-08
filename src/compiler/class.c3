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
// Class parsing (ES6)
// ============================================================================

/// Create a default constructor CompiledFunction without using the lexer.
/// has_super: if true, creates `constructor(...args) { super(...args); }`
/// otherwise creates `constructor() {}`.
/// class_name: when non-empty, used as the constructor's name property
/// (per ES2015 §14.5.14 step 17 + SetFunctionName, a class declaration's
/// default constructor inherits the class name as its .name).
fn CompiledFunction*? make_default_constructor(Heap* hp, bool has_super, char[] class_name) {
    void* raw = hp.alloc_func(hp.heap_udata, CompiledFunction::size);
    if (raw == null) return COMPILE_ERROR~;
    libc::memset(raw, 0, CompiledFunction::size);

    CompiledFunction* func = (CompiledFunction*)raw;
    func.flags.htype = HType.OBJECT;
    func.flags.is_constructable = true;
    // Class constructor: .prototype is non-configurable per ES2015 §14.5.14
    // step 25.  CLOSURE checks this flag and uses PROP_FLAGS_WENC (configurable=false).
    func.flags.is_class_ctor = true;

    // Set the constructor's name from the class name (per ES2015 SetFunctionName).
    // Heap-allocate so the name lives as long as the function (was session 219's
    // B09 fix for compile_inner_function; apply same here).
    if (class_name.len > 0) {
        char* name_heap = (char*)hp.alloc_func(hp.heap_udata, (usz)class_name.len + 1);
        if (name_heap == null) {
            hp.free_func(hp.heap_udata, raw);
            return COMPILE_ERROR~;
        }
        for (usz i = 0; i < class_name.len; i++) name_heap[i] = class_name[i];
        name_heap[class_name.len] = 0;
        func.name_ptr = name_heap;
        func.name_len = (uint)class_name.len;
    }

    if (has_super) {
        // constructor(...args) { super(...args); }
        func.flags.has_rest = true;
        func.num_args = 0;
        func.num_formals = 0;   // rest param doesn't count toward length
        func.num_regs = 24;     // r0=rest, r1=__super__, r2=this, r3..r22=spread, r23=count

        // Create interned string constant for "__super__"
        HString* super_str = hp.str_intern("__super__");
        if (super_str == null) {
            hp.free_func(hp.heap_udata, raw);
            return COMPILE_ERROR~;
        }
        func.const_count = 1;
        usz const_bytes = (usz)func.const_count * TVal::size;
        func.constants = (TVal*)hp.alloc_func(hp.heap_udata, const_bytes);
        if (func.constants == null) {
            hp.free_func(hp.heap_udata, raw);
            return COMPILE_ERROR~;
        }
        TVal super_tv;
        super_tv.set_string(super_str);
        func.constants[0] = super_tv;

        // Build bytecode:
        //   PUSH_LEX                      ; allocate lexical env
        //   GETVAR  r1, __super__          ; load superclass
        //   LDTHIS  r2                     ; load this
        //   SPREAD_ARG r3, r23, r0         ; spread rest args, count→r23
        //   SUPER_CALL_S r2, r1, r23       ; super(r1=superclass), result→r2
        //   POP_LEX
        //   RET r2
        func.code_count = 7;
        usz code_bytes = (usz)func.code_count * Instruction::size;
        func.code = (Instruction*)hp.alloc_func(hp.heap_udata, code_bytes);
        if (func.code == null) {
            hp.free_func(hp.heap_udata, func.constants);
            hp.free_func(hp.heap_udata, raw);
            return COMPILE_ERROR~;
        }

        Instruction* c = func.code;
        c[0] = bytecode::make_abc(Opcode.PUSH_LEX, 0, 0, 0);
        c[1] = bytecode::make_a_bc(Opcode.GETVAR, 1, 0);   // r1, constant idx 0
        c[2] = bytecode::make_abc(Opcode.LDTHIS, 2, 0, 0);  // r2 = this
        c[3] = bytecode::make_abc(Opcode.SPREAD_ARG, 3, 23, 0);  // r3.. = spread dest, r23 = count
        c[4] = bytecode::make_abc(Opcode.SUPER_CALL_S, 2, 1, 23); // result=r2, callee=r1, nargs_reg=r23
        c[5] = bytecode::make_abc(Opcode.POP_LEX, 0, 0, 0);
        c[6] = bytecode::make_abc(Opcode.RET, 2, 0, 0);
    } else {
        // constructor() {}
        func.num_args = 0;
        func.num_formals = 0;
        func.num_regs = 1;

        usz code_bytes = 3 * Instruction::size;
        void* code_raw = hp.alloc_func(hp.heap_udata, code_bytes);
        if (code_raw == null) { hp.free_func(hp.heap_udata, raw); return COMPILE_ERROR~; }
        func.code = (Instruction*)code_raw;
        func.code_count = 3;

        Instruction* c = func.code;
        c[0] = bytecode::make_abc(Opcode.PUSH_LEX, 0, 0, 0);
        c[1] = bytecode::make_abc(Opcode.POP_LEX, 0, 0, 0);
        c[2] = bytecode::make_abc(Opcode.RETUNDEF, 0, 0, 0);
    }

    return func;
}

/// Parse a class declaration: `class Name [extends Base] { body }`
fn void? CompilerContext.class_declaration(&self) {
    self.expect(TokenType.CLASS)!;
    Token name_tok = self.expect(TokenType.IDENTIFIER)!;

    // ES6 §14.5.14 Runtime Semantics: ClassDefinitionEvaluation creates a
    // fresh lexical environment (classScope) as a child of the current
    // LexicalEnvironment, with an *immutable* CreateImmutableBinding for the
    // class name.  Methods and the constructor close over classScope, so the
    // class name resolves to the constructor inside the class body but is
    // shadowed by the outer scope from outside.
    //
    // We model this with PUSH_LEX (allocate classScope) and PUTLEX_C
    // (mark the binding non-writable, which is what immutable binding maps
    // to in our env: PUTVAR on a non-writable binding throws TypeError).
    // Then we POP_LEX after storing the constructor into the OUTER let
    // binding (so `Foo` resolves to the constructor from the outer scope).

    // Outer let-style binding: holds the constructor after the class evaluates.
    // Same as the existing let/const treatment for class declarations.
    ushort class_reg = self.declare_var(name_tok.str_value, LET);
    uint class_name_idx = self.add_string_constant(name_tok.str_value);

    // Push the classScope (child of current lex_env).
    self.emit_simple(Opcode.PUSH_LEX);

    // Initialize the immutable className binding with undefined as a TDZ-like
    // placeholder.  PUTLEX_C stores the value AND marks the binding non-writable.
    // The binding is later overwritten with the constructor — PUTLEX_C on an
    // existing entry just re-stores the value (put_prop is overwrite-in-place),
    // which matches spec step 14's "InitializeReferencedBinding" semantics on
    // an uninitialized immutable binding.
    {
        ushort tmp_reg = self.alloc_reg();
        self.emit_abc(Opcode.LDUNDEF, (uint)tmp_reg, 0, 0);
        self.emit_a_bc(Opcode.PUTLEX_C, (uint)tmp_reg, class_name_idx);
        self.free_reg(tmp_reg);
    }

    // Parse extends clause and class body.  Methods CLOSURE here, capturing
    // classScope as their lex_env so the class name resolves to the
    // constructor from inside method bodies.
    ushort ctor_reg = self.parse_class_tail_with_name(name_tok.str_value)!;

    // Initialize the classScope's immutable binding with the constructor value
    // (overwriting the TDZ placeholder).
    self.emit_abc(Opcode.LDREG, (uint)class_reg, (uint)ctor_reg, 0);
    self.emit_a_bc(Opcode.PUTLEX_C, (uint)class_reg, class_name_idx);

    // Pop the classScope — methods retain it via CLOSURE capture.
    self.emit_simple(Opcode.POP_LEX);

    // Store the constructor into the OUTER let binding so `Foo` resolves to
    // the constructor from outside the class declaration as well.
    self.emit_a_bc(Opcode.PUTLEX, (uint)class_reg, class_name_idx);
    self.free_reg(ctor_reg);
}

/// Parse a class expression: `class [Name] [extends Base] { body }`
/// Returns the register holding the constructor.
fn ushort? CompilerContext.class_expression(&self) {
    self.expect(TokenType.CLASS)!;

    // Optional class name (only visible inside the class body).
    char[] name;
    uint class_name_idx = 0;
    ushort name_reg = MAX_REGISTERS;
    bool has_name = false;
    if (self.check(TokenType.IDENTIFIER)) {
        Token name_tok = self.advance()!;
        name = name_tok.str_value;
        // For named class expressions, track the name on the scope stack so
        // inner function expressions can resolve it (name inference).
        name_reg = self.declare_var(name, LET);
        class_name_idx = self.add_string_constant(name);
        has_name = true;
    }

    // Push classScope only when we have a class name — the immutable binding
    // is the only thing the spec puts in classScope, and anonymous class
    // expressions don't need one.  When we DO push, the classScope is a child
    // of the current lex env; methods CLOSURE'd inside capture it.
    if (has_name) {
        self.emit_simple(Opcode.PUSH_LEX);

        // Initialize the immutable className binding with undefined
        // (PUTLEX_C marks it non-writable → PUTVAR throws TypeError).
        {
            ushort tmp_reg = self.alloc_reg();
            self.emit_abc(Opcode.LDUNDEF, (uint)tmp_reg, 0, 0);
            self.emit_a_bc(Opcode.PUTLEX_C, (uint)tmp_reg, class_name_idx);
            self.free_reg(tmp_reg);
        }
    }

    // Parse extends clause and class body.
    // Anonymous class expression: pass empty name so default constructor
    // has empty .name (per ES2015 anonymous class expression).
    ushort ctor_reg = self.parse_class_tail_with_name(name)!;

    // For named class expressions, initialize the classScope's immutable
    // binding with the constructor, then pop classScope.  Methods retain it
    // via CLOSURE capture, so `C` inside methods resolves to the class.
    if (has_name) {
        self.emit_abc(Opcode.LDREG, (uint)name_reg, (uint)ctor_reg, 0);
        self.emit_a_bc(Opcode.PUTLEX_C, (uint)name_reg, class_name_idx);
        self.emit_simple(Opcode.POP_LEX);
    }

    return ctor_reg;
}

/// Parse the tail of a class: optional `extends` clause + class body.
/// Returns the register holding the constructor function.
/// `class_name`: when non-empty, the default constructor inherits this name
/// as its `.name` property (ES2015 §14.5.14 + SetFunctionName).
fn ushort? CompilerContext.parse_class_tail_with_name(&self, char[] class_name) {
    // Save state for restoration after class body
    bool saved_in_class_body = self.in_class_body;
    bool saved_has_super = self.has_super_binding;

    self.in_class_body = true;
    self.has_super_binding = false;

    // Parse optional extends clause
    ushort base_reg = MAX_REGISTERS;
    if (self.match(TokenType.EXTENDS)) {
        base_reg = self.assignment_expr()!;
        self.has_super_binding = true;

        // Store the super class in an internal variable so the constructor
        // can access it via GETVAR for super() calls.
        char[] super_name = "__super__";
        ushort super_reg = self.declare_var(super_name, LET);
        uint super_name_idx = self.add_string_constant(super_name);
        self.emit_abc(Opcode.LDREG, (uint)super_reg, (uint)base_reg, 0);
        self.emit_a_bc(Opcode.PUTLEX, (uint)super_reg, super_name_idx);
    }

    // Parse class body
    self.expect(TokenType.LBRACE)!;

    // Track methods found in the class body
    ClassMethod[MAX_CLASS_METHODS] methods;
    ushort method_count = 0;

    // Track constructor
    uint ctor_inner_idx = 0xFFFFFFFF;  // sentinel

    while (!self.check(TokenType.RBRACE) && !self.is_at_end()) {
        // Skip semicolons (empty class elements)
        if (self.match(TokenType.SEMICOLON)) {
            continue;
        }

        // Refresh `lexer.token_start` so the offset captured below reflects
        // this iteration's first token (not stale state from the previous
        // element's closing `}`).
        self.lexer.refresh_token_start();

        // Capture source start for Function.prototype.toString (ES2019 §19.2.3.5).
        uint class_elem_src_start = self.lexer.token_start;

        // Check for static modifier
        bool is_static = false;
        if (self.match(TokenType.STATIC)) {
            is_static = true;
        }

        // ES2015 §14.4: generator-method shorthand — `*m() { yield ... }`.
        // Save the generator + async flags; they are only overridden right
        // before compiling the method body below. Anything parsed before that
        // (identifier method names, `[expr]` computed keys) runs in the
        // *enclosing* function's context, so we must not clear the flags here.
        bool saved_is_generator = self.is_generator;
        bool saved_is_async = self.is_async;
        // ES2017 §14.6: async-method shorthand — `async m() { await ... }`.
        // `async` is not a keyword; match_async_method_prefix consumes it only
        // when it is a modifier (followed on the same line by a method name),
        // so `async() {}` still parses as a method named "async".
        bool is_async_method = self.match_async_method_prefix();
        bool is_generator_method = self.match(TokenType.STAR);
        // Async generator methods (`async *m() {}`) are not supported.
        if (is_async_method && is_generator_method) {
            return self.fail("async generator methods are not supported")~;
        }

        // Get the method name
        Token method_name;
        bool is_constructor = false;
        bool is_getter = false;
        bool is_setter = false;

        // Check for computed key [expr]
        bool has_computed_key = false;
        uint computed_key_inner_idx = 0xFFFFFFFF;

        if (self.check(TokenType.LBRACKET)) {
            self.advance()!;  // consume `[`
            // ES2015 §14.5.13 step 1: a computed key whose *literal string value* is
            // "prototype" combined with `static` is an early SyntaxError (covered by
            // §14.5.1's "static method named prototype" rule — test262
            // static-method-non-configurable-err).  Detect that literal-string form
            // at compile time so we can reject it cleanly instead of waiting for a
            // runtime TypeError out of DefinePropertyOrThrow.
            if (self.check(TokenType.STRING)) {
                Token str_tok = self.advance()!;
                self.expect(TokenType.RBRACKET)!;
                has_computed_key = false;
                // Reuse the IDENTIFIER / string / static-prototype early-error check
                // below by treating the string as a fixed-name method token.
                method_name = str_tok;
                // Fall through to the static-prototype check below.
            } else {
                // Generic computed key (variable, expression, etc.): compile the key
                // expression as a 0-arg inner function, evaluated at class instantiation.
                has_computed_key = true;
                CompiledFunction* key_func = self.compile_key_expr()!;
                self.expect(TokenType.RBRACKET)!;
                computed_key_inner_idx = self.add_inner_func(key_func);
                method_name = lexer::make_token(TokenType.IDENTIFIER, 0, 0);
            }
        } else if (self.check(TokenType.IDENTIFIER)
               || lexer::keyword_to_string(self.peek_type()).len > 0) {
            // IDENTIFIER or any keyword (extends, class, if, return, etc.) as method name
            method_name = self.advance()!;
            // Check for getter/setter: `get prop() {}` / `set prop(v) {}`
            // Skip when this is a generator-method shorthand — `*get` / `*set` is a SyntaxError.
            if (!is_generator_method && (method_name.str_value.len == 3
                 && method_name.str_value[0] == 'g'
                 && method_name.str_value[1] == 'e'
                 && method_name.str_value[2] == 't')
                || (!is_generator_method && method_name.str_value.len == 3
                    && method_name.str_value[0] == 's'
                    && method_name.str_value[1] == 'e'
                    && method_name.str_value[2] == 't')) {
                // Check if next token is a property key (not `:` or `(`)
                if (!self.check(TokenType.COLON) && !self.check(TokenType.LPAREN)) {
                    // This is a getter/setter declaration
                    is_getter = (method_name.str_value[0] == 'g');
                    is_setter = !is_getter;
                    // Parse the actual property name
                    if (self.check(TokenType.LBRACKET)) {
                        // Computed getter/setter key
                        self.advance()!; // consume `[`
                        has_computed_key = true;
                        CompiledFunction* accessor_key_func = self.compile_key_expr()!;
                        self.expect(TokenType.RBRACKET)!;
                        computed_key_inner_idx = self.add_inner_func(accessor_key_func);
                        method_name = lexer::make_token(TokenType.IDENTIFIER, 0, 0);
                    } else if (self.check(TokenType.IDENTIFIER) || self.check(TokenType.STRING)
                               || lexer::keyword_to_string(self.peek_type()).len > 0) {
                        method_name = self.advance()!;
                    } else if (self.check(TokenType.NUMBER)) {
                        method_name = self.advance()!;
                    } else {
                        return COMPILE_ERROR~;
                    }
                    // Early error: getter/setter named "constructor" (non-static only)
                    if (!is_static && method_name.str_value.len == 11
                        && method_name.str_value[0] == 'c'
                        && method_name.str_value[1] == 'o'
                        && method_name.str_value[2] == 'n'
                        && method_name.str_value[3] == 's'
                        && method_name.str_value[4] == 't'
                        && method_name.str_value[5] == 'r'
                        && method_name.str_value[6] == 'u'
                        && method_name.str_value[7] == 'c'
                        && method_name.str_value[8] == 't'
                        && method_name.str_value[9] == 'o'
                        && method_name.str_value[10] == 'r') {
                        return COMPILE_ERROR~;
                    }
                }
            }
            // Check for constructor name and related early errors
            if (method_name.str_value.len == 11
                && method_name.str_value[0] == 'c'
                && method_name.str_value[1] == 'o'
                && method_name.str_value[2] == 'n'
                && method_name.str_value[3] == 's'
                && method_name.str_value[4] == 't'
                && method_name.str_value[5] == 'r'
                && method_name.str_value[6] == 'u'
                && method_name.str_value[7] == 'c'
                && method_name.str_value[8] == 't'
                && method_name.str_value[9] == 'o'
                && method_name.str_value[10] == 'r') {
                if (!is_static && (is_getter || is_setter)) {
                    // getter/setter named "constructor" — already handled above
                    return COMPILE_ERROR~;
                }
                if (ctor_inner_idx != 0xFFFFFFFF) {
                    // duplicate constructor is a SyntaxError
                    return COMPILE_ERROR~;
                }
                if (!is_static) {
                    is_constructor = true;
                }
            }
            // Early error: static method/getter/setter named "prototype"
            if (is_static && method_name.str_value.len == 9
                && method_name.str_value[0] == 'p'
                && method_name.str_value[1] == 'r'
                && method_name.str_value[2] == 'o'
                && method_name.str_value[3] == 't'
                && method_name.str_value[4] == 'o'
                && method_name.str_value[5] == 't'
                && method_name.str_value[6] == 'y'
                && method_name.str_value[7] == 'p'
                && method_name.str_value[8] == 'e') {
                return COMPILE_ERROR~;
            }
        } else if (self.check(TokenType.STRING)) {
            method_name = self.advance()!;
        } else if (self.check(TokenType.NUMBER)) {
            method_name = self.advance()!;
        } else {
            return COMPILE_ERROR~;
        }

        // Compile the method as an inner function
        // Save and restore is_constructable
        bool saved_constructable = self.is_constructable;

        if (is_constructor) {
            self.is_constructable = true;
        } else {
            self.is_constructable = false;
        }

        // ES2015 §14.5.13: starred methods cannot be constructors, getters, or
        // setters. Catch those before compile_inner_function so we get a clean
        // compile error instead of a miscompiled function.
        if (is_generator_method && (is_constructor || is_getter || is_setter)) {
            return COMPILE_ERROR~;
        }

        // ES2017 §14.6: async methods cannot be constructors, getters, or
        // setters either (`async constructor()`, `async get x()` are
        // SyntaxErrors).
        if (is_async_method && (is_constructor || is_getter || is_setter)) {
            return COMPILE_ERROR~;
        }

        // Set the generator/async flags to exactly this method's own kind so
        // compile_inner_function propagates them into the method body; the
        // saved flags are restored right after so the next sibling element
        // (and the enclosing context) do not inherit them. Assign (not just
        // set-on-true): a plain method defined inside a generator/async body
        // must NOT inherit the enclosing function's flags.
        self.is_generator = is_generator_method;
        self.is_async = is_async_method;

        // ES2015 §14.5.13: getter/setter methods in class bodies have a name
        // prefixed with "get " or "set " (matching object literal semantics).
        // For a computed key ([expr]) the name is the empty string per spec.
        // The constructor method's name is special — per ES2015 §14.5.14
        // ClassDefinitionEvaluation + §14.3.7 DefineMethod, the constructor's
        // name is the className (passed via DefineMethod).  For an anonymous
        // class, that means the constructor's name is "" (per spec).
        char[128] method_name_buf;
        usz method_name_len = 0;
        if (is_constructor) {
            // Constructor's name = className (empty for anonymous class)
            if (class_name.len < 128) {
                for (usz i = 0; i < class_name.len; i++) method_name_buf[i] = class_name[i];
                method_name_len = class_name.len;
            }
        } else if (has_computed_key) {
            // Leave name empty — the actual key is computed at class evaluation time.
            method_name_len = 0;
        } else if (is_getter || is_setter) {
            char[] prefix = is_getter ? "get " : "set ";
            usz prop_len = method_name.str_value.len;
            if (prefix.len + prop_len < 128) {
                for (usz i = 0; i < prefix.len; i++) method_name_buf[i] = prefix[i];
                for (usz i = 0; i < prop_len; i++) method_name_buf[prefix.len + i] = method_name.str_value[i];
                method_name_len = prefix.len + prop_len;
            }
        } else {
            usz prop_len = method_name.str_value.len;
            if (prop_len < 128) {
                for (usz i = 0; i < prop_len; i++) method_name_buf[i] = method_name.str_value[i];
                method_name_len = prop_len;
            }
        }

        CompiledFunction* inner = self.compile_inner_function(method_name_buf[:method_name_len], false, class_elem_src_start)!;

        self.is_constructable = saved_constructable;
        self.is_generator = saved_is_generator;
        self.is_async = saved_is_async;

        // Add to inner functions table
        uint inner_idx = self.add_inner_func(inner);

        if (is_constructor) {
            ctor_inner_idx = inner_idx;
        } else if (method_count < MAX_CLASS_METHODS) {
            methods[method_count].name = method_name.str_value;
            methods[method_count].inner_idx = inner_idx;
            methods[method_count].is_static = is_static;
            methods[method_count].is_getter = is_getter;
            methods[method_count].is_setter = is_setter;
            methods[method_count].computed_key_inner_idx = computed_key_inner_idx;
            method_count++;
        }
    }

    self.expect(TokenType.RBRACE)!;

    // If no constructor was specified, create a default one
    if (ctor_inner_idx == 0xFFFFFFFF) {
        heap::Heap* hp = (heap::Heap*)self.heap;
        CompiledFunction*? ctor_func_raw = make_default_constructor(hp, self.has_super_binding, class_name);
        if (catch err = ctor_func_raw) {
            return COMPILE_ERROR~;
        }
        CompiledFunction* ctor_func = ctor_func_raw;
        // Track for heap cleanup
        hp.track_compiled_func((void*)ctor_func);
        ctor_inner_idx = self.add_inner_func(ctor_func);
    }

    // Emit CLOSURE for the constructor
    ushort ctor_reg = self.alloc_reg();
    self.emit(bytecode::make_a_bc(Opcode.CLOSURE, (uint)ctor_reg, ctor_inner_idx));

    // Set up prototype
    ushort proto_reg = self.alloc_reg();
    uint proto_name_idx = self.add_string_constant("prototype");
    {
        ushort proto_key_reg = self.alloc_reg();
        self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)proto_key_reg, proto_name_idx));
        self.emit_abc(Opcode.GETPROP, (uint)proto_reg, (uint)ctor_reg, (uint)proto_key_reg);
        self.free_reg(proto_key_reg);
    }

    // If extends, set proto.__proto__ = Base.prototype
    if (base_reg != MAX_REGISTERS) {
        ushort base_proto_reg = self.alloc_reg();
        {
            ushort base_proto_key_reg = self.alloc_reg();
            self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)base_proto_key_reg, proto_name_idx));
            self.emit_abc(Opcode.GETPROP, (uint)base_proto_reg, (uint)base_reg, (uint)base_proto_key_reg);
            self.free_reg(base_proto_key_reg);
        }
        self.emit_abc(Opcode.SETPROTO, (uint)proto_reg, (uint)base_proto_reg, 0);
        // ctor.__proto__ = Base (static inheritance)
        self.emit_abc(Opcode.SETPROTO, (uint)ctor_reg, (uint)base_reg, 0);
        self.free_reg(base_proto_reg);
    }

    // Install methods on prototype or constructor (static)
    for (ushort mi = 0; mi < method_count; mi++) {
        uint mi_idx = methods[mi].inner_idx;
        ushort method_reg = self.alloc_reg();
        self.emit(bytecode::make_a_bc(Opcode.CLOSURE, (uint)method_reg, mi_idx));

        ushort target_reg = methods[mi].is_static ? ctor_reg : proto_reg;

        // Get the key register — either from computed key expression or static name
        ushort key_reg;
        if (methods[mi].computed_key_inner_idx != 0xFFFFFFFF) {
            // Computed key: CLOSURE + CALL to evaluate key expression
            // CALL convention: CALL result_reg, callee_reg, nargs
            // this must be at callee_reg + 1, args at callee_reg + 2, ...
            key_reg = self.alloc_reg();
            self.emit(bytecode::make_a_bc(Opcode.CLOSURE, (uint)key_reg, methods[mi].computed_key_inner_idx));
            ushort this_slot = self.alloc_reg(); // must be key_reg + 1
            self.emit(bytecode::make_a_bc(Opcode.LDTHIS, (uint)this_slot, 0));
            self.emit_abc(Opcode.CALL, (uint)key_reg, (uint)key_reg, 0);
            self.free_reg(this_slot);
        } else {
            uint key_idx = self.add_string_constant(methods[mi].name);
            key_reg = self.alloc_reg();
            self.emit(bytecode::make_a_bc(Opcode.LDCONST, (uint)key_reg, key_idx));
        }

        if (methods[mi].is_getter) {
            self.emit_abc(Opcode.INITGET, (uint)target_reg, (uint)key_reg, (uint)method_reg);
        } else if (methods[mi].is_setter) {
            self.emit_abc(Opcode.INITSET, (uint)target_reg, (uint)key_reg, (uint)method_reg);
        } else {
            self.emit_abc(Opcode.PUTPROP, (uint)target_reg, (uint)key_reg, (uint)method_reg);
        }

        self.free_reg(key_reg);
        self.free_reg(method_reg);
    }

    self.free_reg(proto_reg);

    // Restore class body state
    self.in_class_body = saved_in_class_body;
    self.has_super_binding = saved_has_super;

    return ctor_reg;
}

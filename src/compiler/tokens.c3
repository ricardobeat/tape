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
// Error recording helper
// ============================================================================

/// Record a compile error with the current lexer position, then return COMPILE_ERROR~.
/// Callers: `return self.fail("message")!;` or `return self.fail("message");`
macro fault CompilerContext.fail(&self, char[] msg) {
    if (g_last_err_msg[0] == 0) {
        g_last_err_line = self.lexer.line;
        g_last_err_col  = self.lexer.col;
        // Copy msg into fixed buffer (truncate if necessary, always NUL-terminate).
        usz copy_len = msg.len < (g_last_err_msg.len - 1) ? msg.len : (g_last_err_msg.len - 1);
        libc::memcpy(&g_last_err_msg[0], msg.ptr, copy_len);
        g_last_err_msg[copy_len] = 0;
    }
    return COMPILE_ERROR;
}

// ============================================================================
// Token consumption helpers
// ============================================================================

/// Advance: consume the next token from the lexer and return it.
fn Token? CompilerContext.advance(&self) {
    // Check pushback buffer first
    if (self.pushback_count > 0) {
        self.pushback_count--;
        return self.pushback_stack[self.pushback_count];
    }
    Token? tok_opt = self.lexer.next_token();
    if (catch _err = tok_opt) {
        // Lex error — record position and a descriptive message (only if no prior error).
        if (g_last_err_msg[0] == 0) {
            g_last_err_line = self.lexer.line;
            // After a single-char lex error the lexer has already advanced pos/col by 1;
            // back up by one to report the column of the offending character.
            g_last_err_col  = self.lexer.col > 0 ? self.lexer.col - 1 : 0;
            // Identify the offending character if we can.
            uint bad_pos = self.lexer.pos > 0 ? self.lexer.pos - 1 : 0;
            if (bad_pos < (uint)self.lexer.source.len) {
                char c = self.lexer.source[bad_pos];
                char[128] buf;
                usz n = (usz)libc::snprintf(&buf[0], buf.len,
                    "unexpected character '%c' (not supported)", c);
                usz copy_len = n < (g_last_err_msg.len - 1) ? n : (g_last_err_msg.len - 1);
                libc::memcpy(&g_last_err_msg[0], &buf[0], copy_len);
                g_last_err_msg[copy_len] = 0;
            } else {
                char[] msg = "unexpected end of input";
                usz copy_len = msg.len < (g_last_err_msg.len - 1) ? msg.len : (g_last_err_msg.len - 1);
                libc::memcpy(&g_last_err_msg[0], msg.ptr, copy_len);
                g_last_err_msg[copy_len] = 0;
            }
        }
        return COMPILE_ERROR~;
    }
    return tok_opt;
}

/// Expect the next token to be of the given type; consume and return it.
/// Returns COMPILE_ERROR if the type doesn't match.
fn Token? CompilerContext.expect(&self, TokenType tt) {
    Token tok = self.advance()!;
    if (tok.type != tt) {
        // Only record if no earlier error has already been captured.
        if (g_last_err_msg[0] == 0) {
            char[128] buf;
            char[] want = lexer::token_type_name(tt);
            char[] got  = lexer::token_type_name(tok.type);
            usz n = (usz)libc::snprintf(&buf[0], buf.len, "expected '%.*s', got '%.*s'",
                                        (int)want.len, want.ptr,
                                        (int)got.len,  got.ptr);
            g_last_err_line = tok.line;
            g_last_err_col  = tok.col;
            usz copy_len = n < (g_last_err_msg.len - 1) ? n : (g_last_err_msg.len - 1);
            libc::memcpy(&g_last_err_msg[0], &buf[0], copy_len);
            g_last_err_msg[copy_len] = 0;
        }
        return COMPILE_ERROR~;
    }
    return tok;
}

/// If the next token matches `tt`, consume it and return true.
/// Otherwise leave it unconsumed and return false.
fn bool CompilerContext.match(&self, TokenType tt) {
    if (self.check(tt)) {
        if (try _tok = self.advance()) {
            return true;
        }
    }
    return false;
}

/// Peek at the next token type without consuming.
fn TokenType CompilerContext.peek_type(&self) {
    // Check pushback buffer first
    if (self.pushback_count > 0) {
        return self.pushback_stack[self.pushback_count - 1].type;
    }
    Token? peek_opt = self.lexer.peek();
    if (catch _peek_err = peek_opt) {
        // Lex error during peek — record it now (only if no prior error captured).
        if (g_last_err_msg[0] == 0) {
            g_last_err_line = self.lexer.line;
            g_last_err_col  = self.lexer.col > 0 ? self.lexer.col - 1 : 0;
            uint bad_pos = self.lexer.pos > 0 ? self.lexer.pos - 1 : 0;
            if (bad_pos < (uint)self.lexer.source.len) {
                char c = self.lexer.source[bad_pos];
                char[128] buf;
                usz n = (usz)libc::snprintf(&buf[0], buf.len,
                    "unexpected character '%c' (not supported)", c);
                usz copy_len = n < (g_last_err_msg.len - 1) ? n : (g_last_err_msg.len - 1);
                libc::memcpy(&g_last_err_msg[0], &buf[0], copy_len);
                g_last_err_msg[copy_len] = 0;
            } else {
                char[] msg = "unexpected end of input";
                usz copy_len = msg.len < (g_last_err_msg.len - 1) ? msg.len : (g_last_err_msg.len - 1);
                libc::memcpy(&g_last_err_msg[0], msg.ptr, copy_len);
                g_last_err_msg[copy_len] = 0;
            }
        }
        return TokenType.EOF_TOKEN;
    }
    return peek_opt.type;
}

/// Check if the next token is the given type without consuming.
fn bool CompilerContext.check(&self, TokenType tt) {
    return self.peek_type() == tt;
}

/// Read the next token as a property name (IdentifierName).
/// After '.' or other contexts where any keyword can be used as a name,
/// this returns the string value regardless of whether the token is an
/// IDENTIFIER or a keyword token.
fn char[]? CompilerContext.read_property_name(&self) {
    Token? tok_opt = self.lexer.next_token();
    if (catch err = tok_opt) return COMPILE_ERROR~;
    Token tok = tok_opt;
    if (tok.str_value.len > 0) return tok.str_value;
    char[] kw_str = lexer::keyword_to_string(tok.type);
    if (kw_str.len > 0) return kw_str;
    return COMPILE_ERROR~;
}

/// Check if the next token is a template literal token (backtick-originated).
/// Only returns true for tokens that START a template literal (TEMPLATE, TEMPLATE_HEAD,
/// or STRING with is_template). Does NOT return true for TEMPLATE_MIDDLE or TEMPLATE_TAIL
/// which appear only inside an already-in-progress template parse.
fn bool CompilerContext.is_next_template(&self) {
    // Check compiler pushback buffer first
    if (self.pushback_count > 0) {
        Token tok = self.pushback_stack[self.pushback_count - 1];
        return (tok.type == TokenType.STRING && tok.is_template)
            || tok.type == TokenType.TEMPLATE
            || tok.type == TokenType.TEMPLATE_HEAD;
    }
    if (try tok = self.lexer.peek()) {
        return (tok.type == TokenType.STRING && tok.is_template)
            || tok.type == TokenType.TEMPLATE
            || tok.type == TokenType.TEMPLATE_HEAD;
    }
    return false;
}

/// Returns true if we've reached the end of input.
fn bool CompilerContext.is_at_end(&self) {
    return self.peek_type() == TokenType.EOF_TOKEN;
}

/// Push a token back into the input stream for backtracking.
/// The next call to advance() will return this token.
/// Supports up to 4 tokens of lookback.
fn void CompilerContext.pushback(&self, Token tok) {
    if (self.pushback_count < 4) {
        self.pushback_stack[self.pushback_count] = tok;
        self.pushback_count++;
    }
}

/// Detect the `async` prefix for function declarations/expressions.
/// Returns true and consumes the `async` token if the current token is
/// the identifier "async" and the next token is "function" (not a
/// function call like `async(x) => ...` or a method like `async(x)`).
/// Returns false and leaves the input untouched otherwise.
fn bool CompilerContext.match_async_function(&self) {
    if (self.peek_type() != TokenType.IDENTIFIER) return false;
    Token? cur_opt = self.advance();
    if (catch _e = cur_opt) return false;
    Token cur = cur_opt;
    // Check the identifier name is "async"
    if (cur.str_value.len != 5) {
        self.pushback(cur);
        return false;
    }
    if (cur.str_value[0] != 'a' || cur.str_value[1] != 's' ||
        cur.str_value[2] != 'y' || cur.str_value[3] != 'n' ||
        cur.str_value[4] != 'c') {
        self.pushback(cur);
        return false;
    }
    // Peek the next token: must be `function`
    TokenType next = self.peek_type();
    if (next != TokenType.FUNCTION) {
        // `async` was used as a regular identifier (e.g., variable or arrow param)
        self.pushback(cur);
        return false;
    }
    // Consume was the `async`; next call to advance() will return `function`.
    return true;
}

/// Skip tokens from the **lexer** (not the compiler pushback) until a SEMICOLON
/// or RPAREN is seen at paren/bracket depth 0.  The terminating token is NOT consumed.
/// Used by loop rotation to skip over the for-loop increment without emitting code.
/// Returns true on success, false on unexpected EOF or error.
///
/// Depth tracking: LPAREN/RPAREN increment/decrement a depth counter; the scan stops
/// when a SEMICOLON is seen at depth 0, or when a RPAREN is seen at depth 0.
fn bool CompilerContext.skip_expr_lex(&self) {
    int depth = 0;
    for (;;) {
        Token? tok_opt = self.lexer.next_token();
        if (catch _err = tok_opt) { return false; }
        Token tok = tok_opt;
        switch (tok.type) {
            case TokenType.EOF_TOKEN: return false;
            case TokenType.LPAREN:   depth++; continue;
            case TokenType.LBRACKET: depth++; continue;
            case TokenType.RPAREN: {
                if (depth == 0) {
                    // Put it back via the lexer's single-token pushback
                    self.lexer.pushed_back = tok;
                    self.lexer.has_pushed_back = true;
                    return true;
                }
                depth--;
            }
            case TokenType.RBRACKET: {
                if (depth > 0) { depth--; }
            }
            case TokenType.SEMICOLON: {
                if (depth == 0) {
                    self.lexer.pushed_back = tok;
                    self.lexer.has_pushed_back = true;
                    return true;
                }
            }
            default: {}
        }
    }
}

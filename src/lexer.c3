/// Lexer module for the Duktape JavaScript engine.
///
/// Tokenizes ECMAScript source code (ES2015+ subset) into a stream of
/// tokens.  Handles UTF-8 source, numeric literals (decimal, hex, octal,
/// binary, float, exponent), string literals with full escape sequence
/// support, template literals, regular expression literals, and all
/// ES2015+ punctuators and keywords.
module duktape::lexer;

import duktape::types;
import std::math;

// ============================================================================
// Fault codes
// ============================================================================

/// Raised when the lexer encounters invalid or unexpected input.
faultdef LEX_ERROR;

/// Returned when a keyword lookup does not match.
faultdef NOT_A_KEYWORD;

// ============================================================================
// Constants
// ============================================================================

/// Maximum size for the string escape-processing buffer.
const uint STRING_BUF_SIZE = 65536;

// ============================================================================
// Token types
// ============================================================================

enum TokenType : ushort {
    // Literals
    EOF_TOKEN,
    NUMBER,
    STRING,
    REGEXP,
    TEMPLATE,

    // Identifiers and keywords
    IDENTIFIER,

    // Keywords (alphabetical)
    BREAK, CASE, CATCH, CONTINUE, DEBUGGER, DEFAULT, DELETE, DO, ELSE,
    FINALLY, FOR, FUNCTION, IF, IN, INSTANCEOF, NEW, RETURN, SWITCH,
    THIS, THROW, TRY, TYPEOF, VAR, VOID, WHILE, WITH,

    // ES2015+ keywords
    CLASS, CONST, EXPORT, EXTENDS, IMPORT, SUPER, YIELD, LET, STATIC,

    // Future reserved
    ENUM, AWAIT,

    // Strict mode reserved
    IMPLEMENTS, INTERFACE, PACKAGE, PRIVATE, PROTECTED, PUBLIC,

    // Punctuators
    LBRACE, RBRACE, LPAREN, RPAREN, LBRACKET, RBRACKET,
    DOT, ELLIPSIS, SEMICOLON, COMMA,
    LT, GT, LE, GE, EQ, NE, SEQ, SNE,
    PLUS, MINUS, STAR, SLASH, PERCENT, STARSTAR,
    INC, DEC,
    SHL, SHR, USHR,
    BIT_AND, BIT_OR, BIT_XOR, BIT_NOT,
    LOG_AND, LOG_OR, LOG_NOT, NULLISH,
    QUESTION, COLON,
    ASSIGN, PLUS_ASSIGN, MINUS_ASSIGN, STAR_ASSIGN, SLASH_ASSIGN,
    PERCENT_ASSIGN, STARSTAR_ASSIGN, SHL_ASSIGN, SHR_ASSIGN, USHR_ASSIGN,
    BIT_AND_ASSIGN, BIT_OR_ASSIGN, BIT_XOR_ASSIGN,
    LOG_AND_ASSIGN, LOG_OR_ASSIGN, NULLISH_ASSIGN,
    ARROW,
    OPT_CHAIN,
}

// ============================================================================
// Token
// ============================================================================

struct Token {
    TokenType type;
    uint line;
    uint col;
    double num_value;
    char[] str_value;
    bool str_owns_memory;
}

/// Create a simple token with no value payload.
fn Token make_token(TokenType tt, uint line, uint col) {
    Token t;
    t.type = tt;
    t.line = line;
    t.col = col;
    t.num_value = 0.0;
    t.str_value = {};
    t.str_owns_memory = false;
    return t;
}

// ============================================================================
// Keyword table
// ============================================================================

struct KeywordEntry {
    char[] name;
    TokenType type;
    bool strict_only;
}

const KeywordEntry[*] KEYWORDS = {
    { "break",       TokenType.BREAK,       false },
    { "case",        TokenType.CASE,        false },
    { "catch",       TokenType.CATCH,       false },
    { "continue",    TokenType.CONTINUE,    false },
    { "debugger",    TokenType.DEBUGGER,    false },
    { "default",     TokenType.DEFAULT,     false },
    { "delete",      TokenType.DELETE,      false },
    { "do",          TokenType.DO,          false },
    { "else",        TokenType.ELSE,        false },
    { "finally",     TokenType.FINALLY,     false },
    { "for",         TokenType.FOR,         false },
    { "function",    TokenType.FUNCTION,    false },
    { "if",          TokenType.IF,          false },
    { "in",          TokenType.IN,          false },
    { "instanceof",  TokenType.INSTANCEOF,  false },
    { "new",         TokenType.NEW,         false },
    { "return",      TokenType.RETURN,      false },
    { "switch",      TokenType.SWITCH,      false },
    { "this",        TokenType.THIS,        false },
    { "throw",       TokenType.THROW,       false },
    { "try",         TokenType.TRY,         false },
    { "typeof",      TokenType.TYPEOF,      false },
    { "var",         TokenType.VAR,         false },
    { "void",        TokenType.VOID,        false },
    { "while",       TokenType.WHILE,       false },
    { "with",        TokenType.WITH,        false },
    { "class",       TokenType.CLASS,       false },
    { "const",       TokenType.CONST,       false },
    { "export",      TokenType.EXPORT,      false },
    { "extends",     TokenType.EXTENDS,     false },
    { "import",      TokenType.IMPORT,      false },
    { "super",       TokenType.SUPER,       false },
    { "yield",       TokenType.YIELD,       false },
    { "let",         TokenType.LET,         false },
    { "static",      TokenType.STATIC,      false },
    { "enum",        TokenType.ENUM,        false },
    { "await",       TokenType.AWAIT,       false },
    { "implements",  TokenType.IMPLEMENTS,  true  },
    { "interface",   TokenType.INTERFACE,   true  },
    { "package",     TokenType.PACKAGE,     true  },
    { "private",     TokenType.PRIVATE,     true  },
    { "protected",   TokenType.PROTECTED,   true  },
    { "public",      TokenType.PUBLIC,      true  },
};

/// Look up an identifier to see if it is a keyword.
/// Returns the keyword token type, or NOT_A_KEYWORD fault if not a keyword.
fn TokenType? lookup_keyword(char[] name, bool strict_mode) {
    foreach (&kw : KEYWORDS) {
        if (kw.name.len == name.len) {
            bool match = true;
            for (usz i = 0; i < name.len; i++) {
                if (kw.name[i] != name[i]) {
                    match = false;
                    break;
                }
            }
            if (match) {
                if (kw.strict_only && !strict_mode) {
                    return NOT_A_KEYWORD~;
                }
                return kw.type;
            }
        }
    }
    return NOT_A_KEYWORD~;
}

// ============================================================================
// Character classification helpers
// ============================================================================

fn bool is_digit(char c) {
    return c >= '0' && c <= '9';
}

fn bool is_hex_digit(char c) {
    return (c >= '0' && c <= '9') ||
           (c >= 'a' && c <= 'f') ||
           (c >= 'A' && c <= 'F');
}

fn uint hex_value(char c) {
    if (c >= '0' && c <= '9') return (uint)(c - '0');
    if (c >= 'a' && c <= 'f') return (uint)(c - 'a') + 10;
    if (c >= 'A' && c <= 'F') return (uint)(c - 'A') + 10;
    return 0;
}

fn bool is_octal_digit(char c) {
    return c >= '0' && c <= '7';
}

fn bool is_binary_digit(char c) {
    return c == '0' || c == '1';
}

fn bool is_line_terminator(char c) {
    return c == '\n' || c == '\r';
}

/// Check if a Unicode codepoint is a valid identifier start character.
fn bool is_identifier_start(uint cp) {
    if (cp >= 'a' && cp <= 'z') return true;
    if (cp >= 'A' && cp <= 'Z') return true;
    if (cp == '_' || cp == '$') return true;
    // Simplified Unicode ID_Start ranges
    if (cp >= 0x00C0 && cp <= 0x00D6) return true;
    if (cp >= 0x00D8 && cp <= 0x00F6) return true;
    if (cp >= 0x00F8 && cp <= 0x02FF) return true;
    if (cp >= 0x0370 && cp <= 0x037D) return true;
    if (cp >= 0x037F && cp <= 0x1FFF) return true;
    if (cp >= 0x200C && cp <= 0x200D) return true;
    if (cp >= 0x2070 && cp <= 0x218F) return true;
    if (cp >= 0x2C00 && cp <= 0x2FEF) return true;
    if (cp >= 0x3001 && cp <= 0xD7FF) return true;
    if (cp >= 0xF900 && cp <= 0xFDCF) return true;
    if (cp >= 0xFDF0 && cp <= 0xFFFD) return true;
    if (cp >= 0x10000 && cp <= 0xEFFFF) return true;
    return false;
}

/// Check if a Unicode codepoint is a valid identifier continuation character.
fn bool is_identifier_part(uint cp) {
    if (is_identifier_start(cp)) return true;
    if (cp >= '0' && cp <= '9') return true;
    // Unicode combining marks, connector punctuation
    if (cp >= 0x0300 && cp <= 0x036F) return true;
    if (cp == 0x200C || cp == 0x200D) return true;
    return false;
}

/// Check if a character is ASCII whitespace (space, tab, VT, FF, NBSP).
fn bool is_whitespace(char c) {
    return c == ' ' || c == '\t' || c == 0x0B || c == 0x0C || c == (char)0xA0;
}

// ============================================================================
// UTF-8 encoding helper
// ============================================================================

/// Encode a Unicode codepoint as UTF-8 into the buffer at the given offset.
/// Returns the new offset.
fn uint encode_utf8_to_buf(char[STRING_BUF_SIZE]* buf, uint offset, uint cp) {
    if (cp < 0x80) {
        (*buf)[offset] = (char)cp;
        return offset + 1;
    }
    if (cp < 0x800) {
        (*buf)[offset]     = (char)(0xC0 | (cp >> 6));
        (*buf)[offset + 1] = (char)(0x80 | (cp & 0x3F));
        return offset + 2;
    }
    if (cp < 0x10000) {
        (*buf)[offset]     = (char)(0xE0 | (cp >> 12));
        (*buf)[offset + 1] = (char)(0x80 | ((cp >> 6) & 0x3F));
        (*buf)[offset + 2] = (char)(0x80 | (cp & 0x3F));
        return offset + 3;
    }
    (*buf)[offset]     = (char)(0xF0 | (cp >> 18));
    (*buf)[offset + 1] = (char)(0x80 | ((cp >> 12) & 0x3F));
    (*buf)[offset + 2] = (char)(0x80 | ((cp >> 6) & 0x3F));
    (*buf)[offset + 3] = (char)(0x80 | (cp & 0x3F));
    return offset + 4;
}

// ============================================================================
// Lexer state
// ============================================================================

struct Lexer {
    char[] source;
    uint pos;
    uint line;
    uint col;
    Token current;
    Token lookahead;
    bool has_lookahead;
    bool strict_mode;
    void* heap;
}

// ============================================================================
// Lexer — initialisation
// ============================================================================

/// Create a new lexer for the given source text.
fn Lexer lexer_init(char[] source, void* heap) {
    Lexer lex;
    lex.source = source;
    lex.pos = 0;
    lex.line = 1;
    lex.col = 1;
    lex.current = make_token(TokenType.EOF_TOKEN, 1, 1);
    lex.lookahead = make_token(TokenType.EOF_TOKEN, 1, 1);
    lex.has_lookahead = false;
    lex.strict_mode = false;
    lex.heap = heap;
    return lex;
}

/// Reinitialize a lexer with new source text.
fn void Lexer.reset(&self, char[] source) {
    self.source = source;
    self.pos = 0;
    self.line = 1;
    self.col = 1;
    self.current = make_token(TokenType.EOF_TOKEN, 1, 1);
    self.lookahead = make_token(TokenType.EOF_TOKEN, 1, 1);
    self.has_lookahead = false;
}

// ============================================================================
// Lexer — low-level source reading
// ============================================================================

/// Peek at the current character without advancing.  Returns 0 at EOF.
fn char Lexer.peek_char(&self) {
    if (self.pos >= (uint)self.source.len) return 0;
    return self.source[self.pos];
}

/// Peek at the character at offset `n` from the current position.
fn char Lexer.peek_char_at(&self, uint n) {
    uint idx = self.pos + n;
    if (idx >= (uint)self.source.len) return 0;
    return self.source[idx];
}

/// Advance one byte and return the consumed character.
fn char Lexer.advance_char(&self) {
    if (self.pos >= (uint)self.source.len) return 0;
    char c = self.source[self.pos];
    self.pos++;
    if (c == '\n') {
        self.line++;
        self.col = 1;
    } else {
        self.col++;
    }
    return c;
}

/// Decode a UTF-8 codepoint at the current position.
/// Returns the codepoint and advances past it.
fn uint Lexer.read_codepoint(&self) {
    if (self.pos >= (uint)self.source.len) return 0;
    char b0 = self.source[self.pos];

    // ASCII fast path
    if (b0 < 0x80) {
        self.pos++;
        if (b0 == '\n') {
            self.line++;
            self.col = 1;
        } else {
            self.col++;
        }
        return (uint)b0;
    }

    uint cp;
    uint seq_len;
    if ((b0 & 0xE0) == 0xC0) {
        cp = (uint)(b0 & 0x1F);
        seq_len = 2;
    } else if ((b0 & 0xF0) == 0xE0) {
        cp = (uint)(b0 & 0x0F);
        seq_len = 3;
    } else if ((b0 & 0xF8) == 0xF0) {
        cp = (uint)(b0 & 0x07);
        seq_len = 4;
    } else {
        // Invalid UTF-8 lead byte
        self.pos++;
        self.col++;
        return 0xFFFD;
    }

    self.pos++;
    self.col++;

    for (uint i = 1; i < seq_len; i++) {
        if (self.pos >= (uint)self.source.len) return 0xFFFD;
        char cb = self.source[self.pos];
        if ((cb & 0xC0) != 0x80) return 0xFFFD;
        cp = (cp << 6) | (uint)(cb & 0x3F);
        self.pos++;
    }

    return cp;
}

/// Peek at the current UTF-8 codepoint without advancing.
fn uint Lexer.peek_codepoint(&self) {
    uint saved_pos = self.pos;
    uint saved_line = self.line;
    uint saved_col = self.col;
    uint cp = self.read_codepoint();
    self.pos = saved_pos;
    self.line = saved_line;
    self.col = saved_col;
    return cp;
}

/// Returns true if the lexer has reached the end of source.
fn bool Lexer.at_end(&self) {
    return self.pos >= (uint)self.source.len;
}

/// Returns the number of source bytes remaining.
fn uint Lexer.remaining(&self) {
    if (self.pos >= (uint)self.source.len) return 0;
    return (uint)self.source.len - self.pos;
}

// ============================================================================
// Lexer — skip whitespace and comments
// ============================================================================

/// Skip whitespace, line terminators, single-line comments (//),
/// and multi-line comments (/* ... */).
fn void Lexer.skip_whitespace_and_comments(&self) {
    while (!self.at_end()) {
        char c = self.peek_char();

        // Whitespace
        if (is_whitespace(c) || c == '\n' || c == '\r') {
            if (c == '\r' && self.peek_char_at(1) == '\n') {
                // CR+LF counts as one line terminator
                self.pos += 2;
                self.line++;
                self.col = 1;
            } else {
                self.advance_char();
            }
            continue;
        }

        // Single-line comment
        if (c == '/' && self.peek_char_at(1) == '/') {
            self.pos += 2;
            self.col += 2;
            while (!self.at_end()) {
                char cc = self.peek_char();
                if (cc == '\n' || cc == '\r') break;
                self.pos++;
                self.col++;
            }
            continue;
        }

        // Multi-line comment
        if (c == '/' && self.peek_char_at(1) == '*') {
            self.pos += 2;
            self.col += 2;
            while (!self.at_end()) {
                if (self.peek_char() == '*' && self.peek_char_at(1) == '/') {
                    self.pos += 2;
                    self.col += 2;
                    break;
                }
                self.advance_char();
            }
            continue;
        }

        // Unicode BOM (U+FEFF encoded as EF BB BF) treated as whitespace
        if (c == (char)0xEF && self.remaining() >= 3) {
            if (self.source[self.pos + 1] == (char)0xBB &&
                self.source[self.pos + 2] == (char)0xBF) {
                self.pos += 3;
                self.col++;
                continue;
            }
        }

        break;
    }
}

// ============================================================================
// Lexer — scan numeric literal
// ============================================================================

/// Parse a numeric literal token.
/// Supports: decimal, hex (0x/0X), octal (0o/0O), binary (0b/0B),
/// floating point with optional exponent.
fn Token? Lexer.scan_number(&self) {
    uint start_line = self.line;
    uint start_col = self.col;
    uint start_pos = self.pos;
    double value = 0.0;

    char c = self.peek_char();

    // Check for hex, octal, or binary prefix
    if (c == '0' && self.remaining() >= 2) {
        char next = self.peek_char_at(1);

        // Hexadecimal: 0x or 0X
        if (next == 'x' || next == 'X') {
            self.pos += 2;
            self.col += 2;
            if (self.at_end() || !is_hex_digit(self.peek_char())) {
                return LEX_ERROR~;
            }
            while (!self.at_end() && is_hex_digit(self.peek_char())) {
                value = value * 16.0 + (double)hex_value(self.peek_char());
                self.pos++;
                self.col++;
            }
            Token tok = make_token(TokenType.NUMBER, start_line, start_col);
            tok.num_value = value;
            tok.str_value = self.source[start_pos..self.pos-1];
            return tok;
        }

        // Octal: 0o or 0O
        if (next == 'o' || next == 'O') {
            self.pos += 2;
            self.col += 2;
            if (self.at_end() || !is_octal_digit(self.peek_char())) {
                return LEX_ERROR~;
            }
            while (!self.at_end() && is_octal_digit(self.peek_char())) {
                value = value * 8.0 + (double)(self.peek_char() - '0');
                self.pos++;
                self.col++;
            }
            Token tok = make_token(TokenType.NUMBER, start_line, start_col);
            tok.num_value = value;
            tok.str_value = self.source[start_pos..self.pos-1];
            return tok;
        }

        // Binary: 0b or 0B
        if (next == 'b' || next == 'B') {
            self.pos += 2;
            self.col += 2;
            if (self.at_end() || !is_binary_digit(self.peek_char())) {
                return LEX_ERROR~;
            }
            while (!self.at_end() && is_binary_digit(self.peek_char())) {
                value = value * 2.0 + (double)(self.peek_char() - '0');
                self.pos++;
                self.col++;
            }
            Token tok = make_token(TokenType.NUMBER, start_line, start_col);
            tok.num_value = value;
            tok.str_value = self.source[start_pos..self.pos-1];
            return tok;
        }
    }

    // Decimal integer part
    while (!self.at_end() && is_digit(self.peek_char())) {
        value = value * 10.0 + (double)(self.peek_char() - '0');
        self.pos++;
        self.col++;
    }

    // Fractional part
    if (!self.at_end() && self.peek_char() == '.') {
        // Ensure it's not ... (ellipsis) - just check next char isn't '.'
        if (self.peek_char_at(1) != '.') {
            self.pos++;
            self.col++;
            double frac = 0.1;
            while (!self.at_end() && is_digit(self.peek_char())) {
                value = value + (double)(self.peek_char() - '0') * frac;
                frac *= 0.1;
                self.pos++;
                self.col++;
            }
        }
    }

    // Exponent part
    if (!self.at_end() && (self.peek_char() == 'e' || self.peek_char() == 'E')) {
        self.pos++;
        self.col++;
        bool neg_exp = false;
        if (!self.at_end() && (self.peek_char() == '+' || self.peek_char() == '-')) {
            neg_exp = self.peek_char() == '-';
            self.pos++;
            self.col++;
        }
        if (self.at_end() || !is_digit(self.peek_char())) {
            return LEX_ERROR~;
        }
        double exp_val = 0.0;
        while (!self.at_end() && is_digit(self.peek_char())) {
            exp_val = exp_val * 10.0 + (double)(self.peek_char() - '0');
            self.pos++;
            self.col++;
        }
        if (neg_exp) exp_val = -exp_val;
        value = value * math::pow(10.0, exp_val);
    }

    Token tok = make_token(TokenType.NUMBER, start_line, start_col);
    tok.num_value = value;
    tok.str_value = self.source[start_pos..self.pos-1];
    return tok;
}

// ============================================================================
// Lexer — scan string literal
// ============================================================================

/// Parse a string literal ('...' or "...").
/// Handles escape sequences: \n \r \t \b \f \v \\ \' \" \0
/// \xHH  \uHHHH  \u{H..H}  line continuation (\<newline>)
fn Token? Lexer.scan_string(&self) {
    uint start_line = self.line;
    uint start_col = self.col;
    char quote = self.advance_char();

    // Fast path: scan ahead to see if there are any escape sequences.
    // If not, we can return a slice directly into the source.
    uint scan_pos = self.pos;
    bool has_escapes = false;
    while (scan_pos < (uint)self.source.len) {
        char sc = self.source[scan_pos];
        if (sc == quote) break;
        if (sc == '\\') { has_escapes = true; break; }
        if (sc == '\n' || sc == '\r') {
            return LEX_ERROR~;
        }
        scan_pos++;
    }

    if (!has_escapes) {
        // No escapes — return slice into source
        uint str_start = self.pos;
        self.pos = scan_pos;
        self.col += scan_pos - str_start;
        if (self.at_end() || self.peek_char() != quote) {
            return LEX_ERROR~;
        }
        self.advance_char(); // consume closing quote
        Token tok = make_token(TokenType.STRING, start_line, start_col);
        if (scan_pos > str_start) {
            tok.str_value = self.source[str_start..scan_pos-1];
        } else {
            tok.str_value = {};
        }
        tok.str_owns_memory = false;
        return tok;
    }

    // Slow path: build decoded string in stack buffer.
    char[STRING_BUF_SIZE] buf;
    uint buf_len = 0;

    while (!self.at_end()) {
        char ch = self.peek_char();

        if (ch == quote) {
            self.advance_char(); // consume closing quote
            Token tok = make_token(TokenType.STRING, start_line, start_col);
            if (buf_len > 0) {
                tok.str_value = buf[0..buf_len-1];
            } else {
                tok.str_value = {};
            }
            tok.str_owns_memory = false;
            return tok;
        }

        if (ch == '\n' || ch == '\r') {
            return LEX_ERROR~;
        }

        if (ch == '\\') {
            self.advance_char(); // consume backslash
            if (self.at_end()) return LEX_ERROR~;

            char esc = self.advance_char();
            switch (esc) {
                case 'n':  buf[buf_len] = '\n'; buf_len++;
                case 'r':  buf[buf_len] = '\r'; buf_len++;
                case 't':  buf[buf_len] = '\t'; buf_len++;
                case 'b':  buf[buf_len] = 0x08; buf_len++;
                case 'f':  buf[buf_len] = 0x0C; buf_len++;
                case 'v':  buf[buf_len] = 0x0B; buf_len++;
                case '0':  buf[buf_len] = 0;    buf_len++;
                case '\'': buf[buf_len] = '\''; buf_len++;
                case '"':  buf[buf_len] = '"';  buf_len++;
                case '\\': buf[buf_len] = '\\'; buf_len++;

                case 'x':
                    // \xHH
                    if (self.remaining() < 2) return LEX_ERROR~;
                    char h1 = self.advance_char();
                    char h2 = self.advance_char();
                    if (!is_hex_digit(h1) || !is_hex_digit(h2)) return LEX_ERROR~;
                    uint hval = hex_value(h1) * 16 + hex_value(h2);
                    buf[buf_len] = (char)hval;
                    buf_len++;

                case 'u':
                    if (self.at_end()) return LEX_ERROR~;
                    if (self.peek_char() == '{') {
                        // \u{H..H} — variable length Unicode escape
                        self.advance_char(); // consume {
                        uint ucp = 0;
                        uint udigits = 0;
                        while (!self.at_end() && self.peek_char() != '}') {
                            if (!is_hex_digit(self.peek_char())) return LEX_ERROR~;
                            ucp = ucp * 16 + hex_value(self.peek_char());
                            self.advance_char();
                            udigits++;
                            if (ucp > 0x10FFFF) return LEX_ERROR~;
                        }
                        if (self.at_end() || udigits == 0) return LEX_ERROR~;
                        self.advance_char(); // consume }
                        buf_len = encode_utf8_to_buf(&buf, buf_len, ucp);
                    } else {
                        // \uHHHH — exactly 4 hex digits
                        if (self.remaining() < 4) return LEX_ERROR~;
                        uint ucp4 = 0;
                        for (int i = 0; i < 4; i++) {
                            char hc = self.advance_char();
                            if (!is_hex_digit(hc)) return LEX_ERROR~;
                            ucp4 = ucp4 * 16 + hex_value(hc);
                        }
                        buf_len = encode_utf8_to_buf(&buf, buf_len, ucp4);
                    }

                case '\n':
                    // Line continuation — just skip the newline
                    break;
                case '\r':
                    // Line continuation — also skip following \n if present
                    if (!self.at_end() && self.peek_char() == '\n') {
                        self.advance_char();
                    }

                default:
                    // Non-escape: in non-strict mode, treat as literal
                    buf[buf_len] = esc;
                    buf_len++;
            }
        } else {
            // Regular character
            buf[buf_len] = ch;
            buf_len++;
            self.advance_char();
        }

        if (buf_len >= STRING_BUF_SIZE - 6) {
            return LEX_ERROR~;
        }
    }

    // Reached end of source without closing quote
    return LEX_ERROR~;
}

// ============================================================================
// Lexer — scan identifier or keyword
// ============================================================================

/// Parse an identifier or keyword.
fn Token? Lexer.scan_identifier(&self) {
    uint start_line = self.line;
    uint start_col = self.col;
    uint start_pos = self.pos;

    // First character is already validated as identifier start
    self.read_codepoint();

    // Continue consuming identifier part characters
    while (!self.at_end()) {
        uint cp = self.peek_codepoint();
        if (!is_identifier_part(cp)) break;
        self.read_codepoint();
    }

    char[] name = self.source[start_pos..self.pos-1];

    // Check if this identifier is a keyword
    if (try kw = lookup_keyword(name, self.strict_mode)) {
        Token tok = make_token(kw, start_line, start_col);
        tok.str_value = name;
        return tok;
    }

    // Regular identifier
    Token tok = make_token(TokenType.IDENTIFIER, start_line, start_col);
    tok.str_value = name;
    return tok;
}

// ============================================================================
// Lexer — scan punctuator
// ============================================================================

/// Parse a punctuator (operator or delimiter).
/// Handles all single, double, triple, and quad-character operators.
fn Token? Lexer.scan_punctuator(&self) {
    uint start_line = self.line;
    uint start_col = self.col;
    char c = self.peek_char();
    char c2 = self.peek_char_at(1);
    char c3 = self.peek_char_at(2);
    char c4 = self.peek_char_at(3);

    // ---- Four-character operators ----

    // >>>= (unsigned right shift assign)
    if (c == '>' && c2 == '>' && c3 == '>' && c4 == '=') {
        self.pos += 4; self.col += 4;
        return make_token(TokenType.USHR_ASSIGN, start_line, start_col);
    }

    // ---- Three-character operators ----

    if (c == '=' && c2 == '=' && c3 == '=') {
        self.pos += 3; self.col += 3;
        return make_token(TokenType.SEQ, start_line, start_col);
    }
    if (c == '!' && c2 == '=' && c3 == '=') {
        self.pos += 3; self.col += 3;
        return make_token(TokenType.SNE, start_line, start_col);
    }
    if (c == '>' && c2 == '>' && c3 == '>') {
        self.pos += 3; self.col += 3;
        return make_token(TokenType.USHR, start_line, start_col);
    }
    if (c == '*' && c2 == '*' && c3 == '=') {
        self.pos += 3; self.col += 3;
        return make_token(TokenType.STARSTAR_ASSIGN, start_line, start_col);
    }
    if (c == '.' && c2 == '.' && c3 == '.') {
        self.pos += 3; self.col += 3;
        return make_token(TokenType.ELLIPSIS, start_line, start_col);
    }
    if (c == '<' && c2 == '<' && c3 == '=') {
        self.pos += 3; self.col += 3;
        return make_token(TokenType.SHL_ASSIGN, start_line, start_col);
    }
    if (c == '>' && c2 == '>' && c3 == '=') {
        self.pos += 3; self.col += 3;
        return make_token(TokenType.SHR_ASSIGN, start_line, start_col);
    }
    if (c == '&' && c2 == '&' && c3 == '=') {
        self.pos += 3; self.col += 3;
        return make_token(TokenType.LOG_AND_ASSIGN, start_line, start_col);
    }
    if (c == '|' && c2 == '|' && c3 == '=') {
        self.pos += 3; self.col += 3;
        return make_token(TokenType.LOG_OR_ASSIGN, start_line, start_col);
    }
    if (c == '?' && c2 == '?' && c3 == '=') {
        self.pos += 3; self.col += 3;
        return make_token(TokenType.NULLISH_ASSIGN, start_line, start_col);
    }

    // ---- Two-character operators ----

    if (c == '=' && c2 == '=') {
        self.pos += 2; self.col += 2;
        return make_token(TokenType.EQ, start_line, start_col);
    }
    if (c == '!' && c2 == '=') {
        self.pos += 2; self.col += 2;
        return make_token(TokenType.NE, start_line, start_col);
    }
    if (c == '=' && c2 == '>') {
        self.pos += 2; self.col += 2;
        return make_token(TokenType.ARROW, start_line, start_col);
    }
    if (c == '<' && c2 == '=') {
        self.pos += 2; self.col += 2;
        return make_token(TokenType.LE, start_line, start_col);
    }
    if (c == '>' && c2 == '=') {
        self.pos += 2; self.col += 2;
        return make_token(TokenType.GE, start_line, start_col);
    }
    if (c == '<' && c2 == '<') {
        self.pos += 2; self.col += 2;
        return make_token(TokenType.SHL, start_line, start_col);
    }
    if (c == '>' && c2 == '>') {
        self.pos += 2; self.col += 2;
        return make_token(TokenType.SHR, start_line, start_col);
    }
    if (c == '+' && c2 == '+') {
        self.pos += 2; self.col += 2;
        return make_token(TokenType.INC, start_line, start_col);
    }
    if (c == '-' && c2 == '-') {
        self.pos += 2; self.col += 2;
        return make_token(TokenType.DEC, start_line, start_col);
    }
    if (c == '+' && c2 == '=') {
        self.pos += 2; self.col += 2;
        return make_token(TokenType.PLUS_ASSIGN, start_line, start_col);
    }
    if (c == '-' && c2 == '=') {
        self.pos += 2; self.col += 2;
        return make_token(TokenType.MINUS_ASSIGN, start_line, start_col);
    }
    if (c == '*' && c2 == '*') {
        self.pos += 2; self.col += 2;
        return make_token(TokenType.STARSTAR, start_line, start_col);
    }
    if (c == '*' && c2 == '=') {
        self.pos += 2; self.col += 2;
        return make_token(TokenType.STAR_ASSIGN, start_line, start_col);
    }
    if (c == '/' && c2 == '=') {
        self.pos += 2; self.col += 2;
        return make_token(TokenType.SLASH_ASSIGN, start_line, start_col);
    }
    if (c == '%' && c2 == '=') {
        self.pos += 2; self.col += 2;
        return make_token(TokenType.PERCENT_ASSIGN, start_line, start_col);
    }
    if (c == '&' && c2 == '&') {
        self.pos += 2; self.col += 2;
        return make_token(TokenType.LOG_AND, start_line, start_col);
    }
    if (c == '|' && c2 == '|') {
        self.pos += 2; self.col += 2;
        return make_token(TokenType.LOG_OR, start_line, start_col);
    }
    if (c == '?' && c2 == '?') {
        self.pos += 2; self.col += 2;
        return make_token(TokenType.NULLISH, start_line, start_col);
    }
    if (c == '?' && c2 == '.') {
        // Optional chaining: ?. but NOT ?.digit (that would be ternary + .5)
        if (!is_digit(c3)) {
            self.pos += 2; self.col += 2;
            return make_token(TokenType.OPT_CHAIN, start_line, start_col);
        }
    }
    if (c == '&' && c2 == '=') {
        self.pos += 2; self.col += 2;
        return make_token(TokenType.BIT_AND_ASSIGN, start_line, start_col);
    }
    if (c == '|' && c2 == '=') {
        self.pos += 2; self.col += 2;
        return make_token(TokenType.BIT_OR_ASSIGN, start_line, start_col);
    }
    if (c == '^' && c2 == '=') {
        self.pos += 2; self.col += 2;
        return make_token(TokenType.BIT_XOR_ASSIGN, start_line, start_col);
    }

    // ---- Single-character operators ----

    self.pos++;
    self.col++;
    switch (c) {
        case '{': return make_token(TokenType.LBRACE, start_line, start_col);
        case '}': return make_token(TokenType.RBRACE, start_line, start_col);
        case '(': return make_token(TokenType.LPAREN, start_line, start_col);
        case ')': return make_token(TokenType.RPAREN, start_line, start_col);
        case '[': return make_token(TokenType.LBRACKET, start_line, start_col);
        case ']': return make_token(TokenType.RBRACKET, start_line, start_col);
        case '.': return make_token(TokenType.DOT, start_line, start_col);
        case ';': return make_token(TokenType.SEMICOLON, start_line, start_col);
        case ',': return make_token(TokenType.COMMA, start_line, start_col);
        case '<': return make_token(TokenType.LT, start_line, start_col);
        case '>': return make_token(TokenType.GT, start_line, start_col);
        case '=': return make_token(TokenType.ASSIGN, start_line, start_col);
        case '!': return make_token(TokenType.LOG_NOT, start_line, start_col);
        case '+': return make_token(TokenType.PLUS, start_line, start_col);
        case '-': return make_token(TokenType.MINUS, start_line, start_col);
        case '*': return make_token(TokenType.STAR, start_line, start_col);
        case '/': return make_token(TokenType.SLASH, start_line, start_col);
        case '%': return make_token(TokenType.PERCENT, start_line, start_col);
        case '&': return make_token(TokenType.BIT_AND, start_line, start_col);
        case '|': return make_token(TokenType.BIT_OR, start_line, start_col);
        case '^': return make_token(TokenType.BIT_XOR, start_line, start_col);
        case '~': return make_token(TokenType.BIT_NOT, start_line, start_col);
        case '?': return make_token(TokenType.QUESTION, start_line, start_col);
        case ':': return make_token(TokenType.COLON, start_line, start_col);
        default:  return LEX_ERROR~;
    }
}

// ============================================================================
// Lexer — scan regular expression literal
// ============================================================================

/// Parse a regular expression literal: /pattern/flags
/// This should be called when the parser context indicates a regexp is
/// expected (i.e., not a division operator).
fn Token? Lexer.scan_regexp(&self) {
    uint start_line = self.line;
    uint start_col = self.col;
    uint start_pos = self.pos;

    // Consume the opening /
    self.advance_char();

    // Scan the pattern
    bool in_char_class = false;
    while (!self.at_end()) {
        char c = self.peek_char();

        if (c == '\n' || c == '\r') {
            return LEX_ERROR~;
        }

        if (c == '\\') {
            // Escape sequence — consume backslash and next char
            self.advance_char();
            if (self.at_end() || self.peek_char() == '\n') {
                return LEX_ERROR~;
            }
            self.advance_char();
            continue;
        }

        if (c == '[') {
            in_char_class = true;
            self.advance_char();
            continue;
        }

        if (c == ']' && in_char_class) {
            in_char_class = false;
            self.advance_char();
            continue;
        }

        if (c == '/' && !in_char_class) {
            break;
        }

        self.advance_char();
    }

    if (self.at_end() || self.peek_char() != '/') {
        return LEX_ERROR~;
    }

    // Consume the closing /
    self.advance_char();

    // Scan flags: g, i, m, s, u, y, d
    while (!self.at_end()) {
        char fc = self.peek_char();
        if ((fc >= 'a' && fc <= 'z') || (fc >= 'A' && fc <= 'Z')) {
            self.advance_char();
        } else {
            break;
        }
    }

    Token tok = make_token(TokenType.REGEXP, start_line, start_col);
    tok.str_value = self.source[start_pos..self.pos-1];
    return tok;
}

// ============================================================================
// Lexer — scan template literal
// ============================================================================

/// Parse a template literal (backtick-delimited string).
/// Returns a TEMPLATE token containing the raw source text including
/// backticks.  Template expressions (${...}) are included in the raw text;
/// full template parsing is handled at a higher level.
fn Token? Lexer.scan_template(&self) {
    uint start_line = self.line;
    uint start_col = self.col;
    uint start_pos = self.pos;

    // Consume the opening backtick
    self.advance_char();

    uint brace_depth = 0;

    while (!self.at_end()) {
        char c = self.peek_char();

        if (c == '\\') {
            // Escape sequence — skip next character
            self.advance_char();
            if (!self.at_end()) {
                self.advance_char();
            }
            continue;
        }

        if (c == '$' && self.peek_char_at(1) == '{') {
            // Template expression start
            self.advance_char(); // $
            self.advance_char(); // {
            brace_depth++;
            // Scan until matching closing brace, handling nesting
            while (!self.at_end() && brace_depth > 0) {
                char tc = self.peek_char();
                if (tc == '{') {
                    brace_depth++;
                    self.advance_char();
                } else if (tc == '}') {
                    brace_depth--;
                    if (brace_depth > 0) {
                        self.advance_char();
                    }
                } else if (tc == '\'' || tc == '"') {
                    // Skip nested string literal inside expression
                    char tq = self.advance_char();
                    while (!self.at_end() && self.peek_char() != tq) {
                        if (self.peek_char() == '\\') {
                            self.advance_char();
                        }
                        if (!self.at_end()) self.advance_char();
                    }
                    if (!self.at_end()) self.advance_char(); // closing quote
                } else if (tc == '`') {
                    // Nested template literal — skip through it
                    self.advance_char();
                } else {
                    self.advance_char();
                }
            }
            // After the while loop, we're at the closing }
            if (!self.at_end() && self.peek_char() == '}') {
                self.advance_char();
            }
            continue;
        }

        if (c == '`') {
            // End of template literal
            self.advance_char();
            Token tok = make_token(TokenType.TEMPLATE, start_line, start_col);
            tok.str_value = self.source[start_pos..self.pos-1];
            return tok;
        }

        self.advance_char();
    }

    // Unterminated template literal
    return LEX_ERROR~;
}

// ============================================================================
// Lexer — main tokenisation entry point
// ============================================================================

/// Advance to the next token and return it.
fn Token? Lexer.next_token(&self) {
    // If we have a lookahead token, consume it.
    if (self.has_lookahead) {
        self.has_lookahead = false;
        self.current = self.lookahead;
        return self.current;
    }

    self.skip_whitespace_and_comments();

    if (self.at_end()) {
        Token tok = make_token(TokenType.EOF_TOKEN, self.line, self.col);
        self.current = tok;
        return tok;
    }

    char c = self.peek_char();

    // Number: starts with a digit, or . followed by a digit
    if (is_digit(c) || (c == '.' && self.remaining() >= 2 && is_digit(self.peek_char_at(1)))) {
        Token tok = self.scan_number()!;
        self.current = tok;
        return tok;
    }

    // String literal
    if (c == '\'' || c == '"') {
        Token tok = self.scan_string()!;
        self.current = tok;
        return tok;
    }

    // Template literal
    if (c == '`') {
        Token tok = self.scan_template()!;
        self.current = tok;
        return tok;
    }

    // Identifier or keyword
    uint cp = self.peek_codepoint();
    if (is_identifier_start(cp)) {
        Token tok = self.scan_identifier()!;
        self.current = tok;
        return tok;
    }

    // Punctuator
    Token tok = self.scan_punctuator()!;
    self.current = tok;
    return tok;
}

/// Peek at the next token without consuming it.
fn Token? Lexer.peek(&self) {
    if (self.has_lookahead) {
        return self.lookahead;
    }

    // Save current state
    Token saved_current = self.current;

    Token tok = self.next_token()!;
    self.lookahead = tok;
    self.has_lookahead = true;

    // Restore current (next_token overwrote it)
    self.current = saved_current;

    return tok;
}

/// Expect the next token to be of the given type.
/// If it matches, advance past it and return the consumed token.
/// Otherwise return LEX_ERROR.
fn Token? Lexer.expect(&self, TokenType expected) {
    Token tok = self.next_token()!;
    if (tok.type != expected) {
        return LEX_ERROR~;
    }
    return tok;
}

/// Check if the next token is of the given type without consuming it.
fn bool Lexer.check(&self, TokenType tt) {
    if (try tok = self.peek()) {
        return tok.type == tt;
    }
    return false;
}

/// If the next token matches the given type, consume it and return true.
/// Otherwise leave the lexer state unchanged and return false.
fn bool Lexer.match_token(&self, TokenType tt) {
    if (self.check(tt)) {
        if (try _tok = self.next_token()) {
            return true;
        }
    }
    return false;
}

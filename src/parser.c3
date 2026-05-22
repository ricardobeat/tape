/// Parser and compiler module for the Duktape JavaScript engine.
///
/// Parses JavaScript source code into an AST and compiles it to bytecode.
module duktape::parser;

import duktape::types;
import duktape::heap;
import duktape::lexer;
import duktape::bytecode;

// ============================================================================
// Fault codes
// ============================================================================

faultdef PARSE_ERROR;
faultdef COMPILE_ERROR;

// ============================================================================
// AST Node Types
// ============================================================================

enum NodeType : ushort {
    // Literals
    NUMBER_LIT,
    STRING_LIT,
    BOOL_LIT,
    NULL_LIT,
    UNDEFINED_LIT,
    
    // Identifiers
    IDENTIFIER,
    
    // Expressions
    BINARY_OP,      // a + b, a === b, etc.
    UNARY_OP,       // -a, !a, ++a, etc.
    ASSIGN,         // a = b
    CALL,           // f(a, b)
    MEMBER,         // a.b or a[b]
    CONDITIONAL,    // a ? b : c
    
    // Statements
    EXPR_STMT,
    BLOCK,
    VAR_DECL,
    IF_STMT,
    WHILE_STMT,
    FOR_STMT,
    RETURN_STMT,
    BREAK_STMT,
    CONTINUE_STMT,
    
    // Functions
    FUNCTION_DECL,
    FUNCTION_EXPR,
}

// ============================================================================
// AST Nodes
// ============================================================================

struct ASTNode {
    NodeType type;
    uint line;
    uint col;
    
    // For literals
    double num_val;
    char[] str_val;
    bool bool_val;
    
    // For identifiers
    char[] name;
    
    // For operators
    lexer::TokenType op;
    
    // Child nodes (indices into parser's node pool)
    uint left;
    uint right;
    uint condition;
    uint[] children;  // For blocks, call args, etc.
}

// ============================================================================
// Parser State
// ============================================================================

struct Parser {
    Heap* heap;
    lexer::Lexer lexer;
    ASTNode* nodes;
    uint node_count;
    uint node_capacity;
    
    // Error state
    bool has_error;
    char[256] error_msg;
    uint error_line;
    uint error_col;
}

// ============================================================================
// Parser Creation
// ============================================================================

/// Create a new parser for the given source code.
fn Parser? parser_init(Heap* heap, char[] source) {
    Parser p;
    p.heap = heap;
    p.lexer = lexer::lexer_init(source, (void*)heap);
    p.node_capacity = 256;
    p.node_count = 0;
    // ASTNode is ~80 bytes, allocate generously
    p.nodes = (ASTNode*)heap.alloc((usz)(p.node_capacity * 128))!;
    p.has_error = false;
    return p;
}

// ============================================================================
// Error Reporting
// ============================================================================

/// Report a parse error at the current token position.
fn void Parser.error(&self, char* msg) {
    if (self.has_error) return;
    self.has_error = true;
    // TODO: Copy msg to error_msg
    self.error_line = self.lexer.current.line;
    self.error_col = self.lexer.current.col;
}

// ============================================================================
// AST Node Creation (to be implemented by subagents)
// ============================================================================

/// Create a number literal node.
fn uint Parser.make_number(&self, double val, uint line, uint col) {
    uint index = self.node_count;
    if (self.node_count >= self.node_capacity) {
        self.error("Too many AST nodes");
        return 0;
    }
    self.nodes[self.node_count++] = {
        .type = NodeType.NUMBER_LIT,
        .num_val = val,
        .line = line,
        .col = col
    };
    return index;
}

/// Create a string literal node.
fn uint Parser.make_string(&self, char[] val, uint line, uint col) {
    uint index = self.node_count;
    ASTNode node = {
        .type = NodeType.STRING_LIT,
        .str_val = val,
        .line = line,
        .col = col
    };
    self.nodes[self.node_count++] = node;
    return index;
}

/// Create a boolean literal node.
fn uint Parser.make_bool(&self, bool val, uint line, uint col) {
    uint index = self.node_count;
    ASTNode node = {
        .type = NodeType.BOOL_LIT,
        .line = line,
        .col = col,
        .bool_val = val
    };
    self.nodes[self.node_count++] = node;
    return index;
}

/// Create a null literal node.
fn uint Parser.make_null(&self, uint line, uint col) {
    uint idx = self.node_count;
    ASTNode node = {
        .type = NodeType.NULL_LIT,
        .line = line,
        .col = col,
    };
    self.nodes[self.node_count++] = node;
    return idx;
}

/// Create an identifier node.
fn uint Parser.make_identifier(&self, char[] name, uint line, uint col) {
    uint index = self.node_count;
    ASTNode node = {
        .type = NodeType.IDENTIFIER,
        .name = name,
        .line = line,
        .col = col,
    };
    self.nodes[self.node_count++] = node;
    return index;
}

/// Create a binary operation node.
fn uint Parser.make_binary(&self, lexer::TokenType op, uint left, uint right, uint line, uint col) {
    uint index = self.node_count;
    ASTNode node = {
        .type = NodeType.BINARY_OP,
        .op = op,
        .left = left,
        .right = right,
        .line = line,
        .col = col
    };
    self.nodes[self.node_count++] = node;
    return index;
}

/// Create a unary operation node.
fn uint Parser.make_unary(&self, lexer::TokenType op, uint operand, uint line, uint col) {
    uint idx = self.node_count;
    ASTNode node = {
        .type = NodeType.UNARY_OP,
        .op = op,
        .left = operand,
        .line = line,
        .col = col,
    };
    self.nodes[self.node_count++] = node;
    return idx;
}

// ============================================================================
// Expression Parsing (to be implemented by subagents)
// ============================================================================

/// Parse a primary expression (literal, identifier, or parenthesized expression).
fn uint? Parser.parse_primary(&self) {
    lexer::Token tok = self.lexer.next_token()!;
    
    switch (tok.type) {
        case lexer::TokenType.NUMBER:
            return self.make_number(tok.num_value, tok.line, tok.col);
        case lexer::TokenType.STRING:
            return self.make_string(tok.str_value, tok.line, tok.col);
        case lexer::TokenType.IDENTIFIER:
            // Check for literal keywords: true, false, null, undefined
            if (tok.str_value.len == 4 && tok.str_value[0] == 't' && tok.str_value[1] == 'r' && 
                tok.str_value[2] == 'u' && tok.str_value[3] == 'e') {
                return self.make_bool(true, tok.line, tok.col);
            }
            if (tok.str_value.len == 5 && tok.str_value[0] == 'f' && tok.str_value[1] == 'a' && 
                tok.str_value[2] == 'l' && tok.str_value[3] == 's' && tok.str_value[4] == 'e') {
                return self.make_bool(false, tok.line, tok.col);
            }
            if (tok.str_value.len == 4 && tok.str_value[0] == 'n' && tok.str_value[1] == 'u' && 
                tok.str_value[2] == 'l' && tok.str_value[3] == 'l') {
                return self.make_null(tok.line, tok.col);
            }
            return self.make_identifier(tok.str_value, tok.line, tok.col);
        case lexer::TokenType.LPAREN:
            uint expr = self.parse_expression()!;
            self.lexer.expect(lexer::TokenType.RPAREN)!;
            return expr;
        default:
            self.error("Unexpected token in primary expression");
            return PARSE_ERROR~;
    }
}

/// Parse a postfix expression (member access, function calls, ++, --).
fn uint? Parser.parse_postfix(&self) {
    uint left = self.parse_primary()!;
    
    while (true) {
        lexer::TokenType tt = self.lexer.current.type;
        
        if (tt == lexer::TokenType.DOT) {
            uint line = self.lexer.current.line;
            uint col = self.lexer.current.col;
            self.lexer.next_token()!;
            
            lexer::Token id_tok = self.lexer.expect(lexer::TokenType.IDENTIFIER)!;
            
            uint idx = self.node_count;
            ASTNode node = {
                .type = NodeType.MEMBER,
                .op = lexer::TokenType.DOT,
                .left = left,
                .name = id_tok.str_value,
                .line = line,
                .col = col,
            };
            self.nodes[self.node_count++] = node;
            left = idx;
        } else if (tt == lexer::TokenType.LBRACKET) {
            uint line = self.lexer.current.line;
            uint col = self.lexer.current.col;
            self.lexer.next_token()!;
            
            uint index_expr = self.parse_expression()!;
            self.lexer.expect(lexer::TokenType.RBRACKET)!;
            
            uint idx = self.node_count;
            ASTNode node = {
                .type = NodeType.MEMBER,
                .op = lexer::TokenType.LBRACKET,
                .left = left,
                .right = index_expr,
                .line = line,
                .col = col,
            };
            self.nodes[self.node_count++] = node;
            left = idx;
        } else if (tt == lexer::TokenType.LPAREN) {
            self.error("Function calls not yet implemented");
            return PARSE_ERROR~;
        } else {
            break;
        }
    }
    
    // Check for postfix INC or DEC
    if (self.lexer.current.type == lexer::TokenType.INC ||
        self.lexer.current.type == lexer::TokenType.DEC) {
        
        lexer::TokenType op = self.lexer.current.type;
        uint line = self.lexer.current.line;
        uint col = self.lexer.current.col;
        self.lexer.next_token()!;
        
        left = self.make_unary(op, left, line, col);
    }
    
    return left;
}

/// Parse a unary expression (!, ~, +, -, ++, --, typeof, void, delete).
fn uint? Parser.parse_unary(&self) {
    lexer::TokenType token_type = self.lexer.current.type;
    
    // Check if current token is a unary operator
    if (token_type == lexer::TokenType.LOG_NOT ||
        token_type == lexer::TokenType.BIT_NOT ||
        token_type == lexer::TokenType.PLUS ||
        token_type == lexer::TokenType.MINUS ||
        token_type == lexer::TokenType.INC ||
        token_type == lexer::TokenType.DEC ||
        token_type == lexer::TokenType.TYPEOF ||
        token_type == lexer::TokenType.VOID ||
        token_type == lexer::TokenType.DELETE) {
        
        // Save operator and position
        lexer::TokenType op = token_type;
        uint line = self.lexer.current.line;
        uint col = self.lexer.current.col;
        
        // Advance to next token
        self.lexer.next_token()!;
        
        // Recursively parse operand
        uint operand = self.parse_unary()!;
        
        // Return unary expression
        return self.make_unary(op, operand, line, col);
    }
    
    // No unary operator, parse postfix expression
    return self.parse_postfix();
}

/// Get operator precedence (higher number = higher precedence).
fn int get_precedence(lexer::TokenType op) {
    switch (op) {
        case lexer::TokenType.DOT:
        case lexer::TokenType.LBRACKET:
        case lexer::TokenType.LPAREN:
            return 15;
        case lexer::TokenType.INC:
        case lexer::TokenType.DEC:
            return 14;
        case lexer::TokenType.LOG_NOT:
        case lexer::TokenType.BIT_NOT:
        case lexer::TokenType.TYPEOF:
        case lexer::TokenType.VOID:
        case lexer::TokenType.DELETE:
            return 13;
        case lexer::TokenType.STARSTAR:
            return 12;
        case lexer::TokenType.STAR:
        case lexer::TokenType.SLASH:
        case lexer::TokenType.PERCENT:
            return 11;
        case lexer::TokenType.PLUS:
        case lexer::TokenType.MINUS:
            return 10;
        case lexer::TokenType.SHL:
        case lexer::TokenType.SHR:
        case lexer::TokenType.USHR:
            return 9;
        case lexer::TokenType.LT:
        case lexer::TokenType.LE:
        case lexer::TokenType.GT:
        case lexer::TokenType.GE:
        case lexer::TokenType.IN:
        case lexer::TokenType.INSTANCEOF:
            return 8;
        case lexer::TokenType.EQ:
        case lexer::TokenType.NE:
        case lexer::TokenType.SEQ:
        case lexer::TokenType.SNE:
            return 7;
        case lexer::TokenType.BIT_AND:
            return 6;
        case lexer::TokenType.BIT_XOR:
            return 5;
        case lexer::TokenType.BIT_OR:
            return 4;
        case lexer::TokenType.LOG_AND:
            return 3;
        case lexer::TokenType.LOG_OR:
        case lexer::TokenType.NULLISH:
            return 2;
        case lexer::TokenType.QUESTION:
            return 1;
        case lexer::TokenType.ASSIGN:
        case lexer::TokenType.PLUS_ASSIGN:
        case lexer::TokenType.MINUS_ASSIGN:
        case lexer::TokenType.STAR_ASSIGN:
        case lexer::TokenType.SLASH_ASSIGN:
        case lexer::TokenType.PERCENT_ASSIGN:
        case lexer::TokenType.STARSTAR_ASSIGN:
        case lexer::TokenType.SHL_ASSIGN:
        case lexer::TokenType.SHR_ASSIGN:
        case lexer::TokenType.USHR_ASSIGN:
        case lexer::TokenType.BIT_AND_ASSIGN:
        case lexer::TokenType.BIT_OR_ASSIGN:
        case lexer::TokenType.BIT_XOR_ASSIGN:
        case lexer::TokenType.LOG_AND_ASSIGN:
        case lexer::TokenType.LOG_OR_ASSIGN:
        case lexer::TokenType.NULLISH_ASSIGN:
            return 0;
        default:
            return -1;
    }
}

/// Parse a binary expression with precedence climbing.
fn uint? Parser.parse_binary(&self, int min_prec) {
    uint left = self.parse_unary()!;
    
    while (true) {
        int prec = get_precedence(self.lexer.current.type);
        if (prec < min_prec) break;
        
        lexer::TokenType op = self.lexer.current.type;
        uint line = self.lexer.current.line;
        uint col = self.lexer.current.col;
        
        self.lexer.next_token()!;
        
        uint right = self.parse_binary(prec + 1)!;
        left = self.make_binary(op, left, right, line, col);
    }
    
    return left;
}

/// Parse an assignment expression.
fn uint? Parser.parse_assignment(&self) {
    // TODO: implement
    return PARSE_ERROR~;
}

/// Parse a conditional expression (ternary ? :).
fn uint? Parser.parse_conditional(&self) {
    // TODO: implement
    return PARSE_ERROR~;
}

/// Parse a full expression.
fn uint? Parser.parse_expression(&self) {
    return self.parse_conditional();
}

// ============================================================================
// Statement Parsing (to be implemented by subagents)
// ============================================================================

/// Parse a variable declaration (var/let/const).
fn uint? Parser.parse_var_decl(&self) {
    // TODO: implement
    return PARSE_ERROR~;
}

/// Parse an if statement.
fn uint? Parser.parse_if_stmt(&self) {
    // TODO: implement
    return PARSE_ERROR~;
}

/// Parse a while statement.
fn uint? Parser.parse_while_stmt(&self) {
    // TODO: implement
    return PARSE_ERROR~;
}

/// Parse a for statement.
fn uint? Parser.parse_for_stmt(&self) {
    // TODO: implement
    return PARSE_ERROR~;
}

/// Parse a return statement.
fn uint? Parser.parse_return_stmt(&self) {
    // TODO: implement
    return PARSE_ERROR~;
}

/// Parse a block statement.
fn uint? Parser.parse_block(&self) {
    // TODO: implement
    return PARSE_ERROR~;
}

/// Parse a statement.
fn uint? Parser.parse_statement(&self) {
    // TODO: implement
    return PARSE_ERROR~;
}

/// Parse a function declaration.
fn uint? Parser.parse_function(&self) {
    // TODO: implement
    return PARSE_ERROR~;
}

/// Parse a program (list of statements).
fn uint? Parser.parse_program(&self) {
    // TODO: implement
    return PARSE_ERROR~;
}

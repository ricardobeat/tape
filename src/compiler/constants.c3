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
// Constant pool
// ============================================================================

/// Add a TVal to the constant pool and return its index.
fn uint CompilerContext.add_constant(&self, TVal val) {
    // Check for duplicates (number and fastint)
    for (uint i = 0; i < self.const_count; i++) {
        if (self.constants[i].get_tag() == val.get_tag()) {
            if (val.is_number()) {
                if (self.constants[i].get_number() == val.get_number()) {
                    return i;
                }
            } else if (val.is_fastint()) {
                if (self.constants[i].get_fastint() == val.get_fastint()) {
                    return i;
                }
            }
        }
    }

    if (self.const_count >= MAX_CONSTANTS) {
        return self.const_count;  // cap
    }
    uint idx = self.const_count;
    self.constants[idx] = val;
    self.const_count++;
    return idx;
}

/// Add a string constant: intern the string and add a STRING TVal to the pool.
fn uint CompilerContext.add_string_constant(&self, char[] str) {
    // Check for duplicate string constants by scanning existing entries
    for (uint i = 0; i < self.const_count; i++) {
        if (self.constants[i].is_string()) {
            HString* existing = (HString*)self.constants[i].get_heapptr();
            if (existing != null && existing.equals(str)) {
                return i;
            }
        }
    }

    // Intern the string via the heap's string table for pointer deduplication
    Heap* hp = (Heap*)self.heap;
    uint hash = hp.hash_string(str);

    // First, check if the string is already interned in the heap
    HString* hstr = hp.str_table_lookup(str, hash);
    if (hstr == null) {
        // Not found — allocate and insert
        hstr = hstring::hstring_alloc(self.heap, str, hash) ?? null;
        if (hstr != null) {
            hp.str_table_insert(hstr);
        }
    }

    TVal tv;
    if (hstr != null) {
        tv.set_string(hstr);
    } else {
        // Fallback: store as pointer with null
        tv.set_string(null);
    }

    if (self.const_count >= MAX_CONSTANTS) {
        return self.const_count;
    }
    uint idx = self.const_count;
    self.constants[idx] = tv;
    if (hstr != null) { ((types::HeapHeader*)hstr).incref(); }
    self.const_count++;
    return idx;
}

/// Add a number constant and return its index.
fn uint CompilerContext.add_number_constant(&self, double val) {
    TVal tv;
    tv.set_number(val);
    return self.add_constant(tv);
}

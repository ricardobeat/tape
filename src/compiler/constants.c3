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

/// Look up a constant in the hash table and return its index, or const_count if not found.
fn uint CompilerContext.lookup_constant_hash(&self, ulong val_bits) {
    if (self.const_hash == null || self.const_hash_cap == 0) return self.const_count;
    // Use the low bits of the TVal as initial hash probe
    uint hash = (uint)(val_bits >> 1) % self.const_hash_cap;

    // Linear probe: find empty slot or matching entry
    for (uint attempt = 0; attempt < self.const_hash_cap; attempt++) {
        uint idx = (hash + attempt) % self.const_hash_cap;
        if (self.const_hash[idx].hash == 0) {
            // Empty slot: not found
            return self.const_count;
        }
        if (self.const_hash[idx].hash == val_bits) {
            // Found matching entry
            return self.const_hash[idx].index;
        }
    }
    // Hash table full (shouldn't happen if maintained correctly)
    return self.const_count;
}

/// Insert a constant into the hash table.
///
/// Skipped once the table reaches its fill cap (later constants are then
/// appended without dedup) and for all-zero bits, which are
/// indistinguishable from an empty slot.
fn void CompilerContext.insert_constant_hash(&self, ulong val_bits, uint idx) {
    if (self.const_hash == null || self.const_hash_count >= self.const_hash_fill || val_bits == 0) {
        return;
    }
    uint hash = (uint)(val_bits >> 1) % self.const_hash_cap;

    // Linear probe: find empty slot
    for (uint attempt = 0; attempt < self.const_hash_cap; attempt++) {
        uint slot = (hash + attempt) % self.const_hash_cap;
        if (self.const_hash[slot].hash == 0) {
            self.const_hash[slot].hash = val_bits;
            self.const_hash[slot].index = idx;
            self.const_hash_count++;
            return;
        }
    }
}

/// Add a TVal to the constant pool and return its index.
fn uint CompilerContext.add_constant(&self, TVal val) {
    ulong val_bits = val.get_raw_bits();
    TValTag tag = val.get_tag();

    // Only deduplicate numbers and fastints via hash table;
    // strings are handled separately via add_string_constant.
    if (tag == NUMBER || tag == FASTINT) {
        uint found_idx = self.lookup_constant_hash(val_bits);
        if (found_idx < self.const_count) {
            return found_idx;
        }
    }

    self.ensure_const_cap();
    if (self.const_count >= self.const_cap) {
        return self.const_count;  // hard cap
    }
    uint idx = self.const_count;
    self.constants[idx] = val;

    // Insert into hash table for future lookups
    if (tag == NUMBER || tag == FASTINT) {
        self.insert_constant_hash(val_bits, idx);
    }

    self.const_count++;
    return idx;
}

/// Add a string constant: intern the string and add a STRING TVal to the pool.
fn uint CompilerContext.add_string_constant(&self, char[] str) {
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
            ((types::HeapHeader*)hstr).incref();
            hstr.flags.is_interned = true;
        }
    }

    TVal tv;
    if (hstr != null) {
        tv.set_string(hstr);
    } else {
        // Fallback: store as pointer with null
        tv.set_string(null);
    }

    ulong val_bits = tv.get_raw_bits();

    // Check if this string (by pointer) is already in the constant pool
    uint found_idx = self.lookup_constant_hash(val_bits);
    if (found_idx < self.const_count) {
        // The pool entry already holds its references; release the one taken
        // by set_string above.
        if (hstr != null) { hp.decref((types::HeapHeader*)hstr); }
        return found_idx;
    }

    self.ensure_const_cap();
    if (self.const_count >= self.const_cap) {
        return self.const_count;
    }
    uint idx = self.const_count;
    self.constants[idx] = tv;
    // Insert into hash table for future lookups
    self.insert_constant_hash(val_bits, idx);
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

/// Add a BigInt constant (interned digit string) and return its index.
fn uint CompilerContext.add_bigint_constant(&self, char[] digits) {
    Heap* hp = (Heap*)self.heap;
    uint hash = hp.hash_string(digits);

    // Intern the digit string
    HString* hstr = hp.str_table_lookup(digits, hash);
    if (hstr == null) {
        hstr = hstring::hstring_alloc(self.heap, digits, hash) ?? null;
        if (hstr != null) {
            hp.str_table_insert(hstr);
            ((types::HeapHeader*)hstr).incref();
            hstr.flags.is_interned = true;
        }
    }

    // Wrap as BIGINT TVal (set_bigint does incref)
    TVal tv;
    if (hstr != null) {
        tv.set_bigint(hstr);
    } else {
        tv.set_bigint(null);
    }

    ulong val_bits = tv.get_raw_bits();

    // Check if this bigint (by pointer) is already in the constant pool
    uint found_idx = self.lookup_constant_hash(val_bits);
    if (found_idx < self.const_count) {
        // Release tv's reference; pool already has one
        if (hstr != null) { hp.decref((types::HeapHeader*)hstr); }
        return found_idx;
    }

    self.ensure_const_cap();
    if (self.const_count >= self.const_cap) {
        if (hstr != null) { hp.decref((types::HeapHeader*)hstr); }
        return self.const_count;
    }
    uint idx = self.const_count;
    self.constants[idx] = tv;
    self.insert_constant_hash(val_bits, idx);
    // Pool entry takes over tv's reference; give it one more for the pool slot
    if (hstr != null) { ((types::HeapHeader*)hstr).incref(); }
    self.const_count++;
    return idx;
}

/// Iterator protocol: %IteratorPrototype%, Array/String/Map/Set/RegExpString iterators.
module duktape::builtins;
import duktape::types;
import libc;

import duktape::heap;
import duktape::hstring;
import duktape::hobject;
import duktape::re_bindings;

// ============================================================================
// Iterator protocol — built-in @@iterator methods and .next() functions
// ============================================================================

/// Array.prototype[Symbol.iterator] — creates an array iterator object.
fn void builtin_array_proto_symbol_iter(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;

    // Get `this` — must be an object
    TVal this_val = ctx.this_val;
    HObject* iterable;
    if (this_val.is_object()) {
        iterable = (HObject*)this_val.get_heapptr();
    } else {
        // Non-object `this`: wrap it
        HObject*? wrapped = heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err = wrapped) { ctx.result.set_undefined(); return; }
        iterable = wrapped;
    }

    // Create an ARRAY_ITERATOR object
    HObject*? iter_raw = heap.alloc_object(hobject::ObjClass.ARRAY_ITERATOR);
    if (catch err = iter_raw) { ctx.result.set_undefined(); return; }
    HObject* iter = iter_raw;
    (*iter.extra_ptr()).iter.target = iterable;
    (*iter.extra_ptr()).iter.index = 0;
    iter.prototype = heap.iterator_proto;

    // Add .next method as an own property
    HString* next_key = builtin_intern_string(heap, "next");
    if (next_key != null) {
        HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
        if (try fn_obj = fn_raw) {
            (*fn_obj.extra_ptr()).func.builtin_fn_index = (int)BUILTIN_ARRAY_ITERATOR_NEXT;
            fn_obj.flags.callable = true;
            fn_obj.prototype = heap.function_proto;
            TVal fn_tv;
            fn_tv.set_object(fn_obj);
            iter.put_prop(next_key, fn_tv, hobject::PROP_FLAGS_NWC);
        }
    }

    ctx.result.set_object(iter);
}

/// Helper: create an array iterator with a specific kind.
/// kind: 0=value (default), 1=key, 2=key+value (entries)
fn void create_array_iterator(BuiltinContext* ctx, uint kind) {
    Heap* heap = ctx.heap;
    TVal this_val = ctx.this_val;
    HObject* iterable;
    if (this_val.is_object()) {
        iterable = (HObject*)this_val.get_heapptr();
    } else {
        HObject*? wrapped = heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err = wrapped) { ctx.result.set_undefined(); return; }
        iterable = wrapped;
    }
    HObject*? iter_raw = heap.alloc_object(hobject::ObjClass.ARRAY_ITERATOR);
    if (catch err = iter_raw) { ctx.result.set_undefined(); return; }
    HObject* iter = iter_raw;
    (*iter.extra_ptr()).iter.target = iterable;
    (*iter.extra_ptr()).iter.index = 0;
    (*iter.extra_ptr()).iter.kind = kind;
    iter.prototype = heap.iterator_proto;
    HString* next_key = builtin_intern_string(heap, "next");
    if (next_key != null) {
        HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
        if (try fn_obj = fn_raw) {
            (*fn_obj.extra_ptr()).func.builtin_fn_index = (int)BUILTIN_ARRAY_ITERATOR_NEXT;
            fn_obj.flags.callable = true;
            fn_obj.prototype = heap.function_proto;
            TVal fn_tv;
            fn_tv.set_object(fn_obj);
            iter.put_prop(next_key, fn_tv, hobject::PROP_FLAGS_NWC);
        }
    }
    ctx.result.set_object(iter);
}

/// Helper: create a Map iterator with a specific kind.
/// kind: 0=values, 1=keys, 2=entries
fn void create_map_iterator(BuiltinContext* ctx, uint kind) {
    Heap* heap = ctx.heap;
    HObject* map = check_map(ctx);
    if (map == null) { ctx.result.set_undefined(); return; }

    HObject*? iter_raw = heap.alloc_object(hobject::ObjClass.MAP_ITERATOR);
    if (catch err = iter_raw) { ctx.result.set_undefined(); return; }
    HObject* iter = iter_raw;
    (*iter.extra_ptr()).iter.target = map;
    (*iter.extra_ptr()).iter.index = 0;
    (*iter.extra_ptr()).iter.kind = kind;
    iter.prototype = heap.iterator_proto;

    HString* next_key = builtin_intern_string(heap, "next");
    if (next_key != null) {
        HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
        if (try fn_obj = fn_raw) {
            (*fn_obj.extra_ptr()).func.builtin_fn_index = (int)BUILTIN_MAP_ITERATOR_NEXT;
            fn_obj.flags.callable = true;
            fn_obj.prototype = heap.function_proto;
            TVal fn_tv;
            fn_tv.set_object(fn_obj);
            iter.put_prop(next_key, fn_tv, hobject::PROP_FLAGS_NWC);
        }
    }
    ctx.result.set_object(iter);
}

/// Helper: create a Set iterator with a specific kind.
/// kind: 0=values, 1=keys, 2=entries
fn void create_set_iterator(BuiltinContext* ctx, uint kind) {
    Heap* heap = ctx.heap;
    HObject* set = check_set(ctx);
    if (set == null) { ctx.result.set_undefined(); return; }

    HObject*? iter_raw = heap.alloc_object(hobject::ObjClass.SET_ITERATOR);
    if (catch err = iter_raw) { ctx.result.set_undefined(); return; }
    HObject* iter = iter_raw;
    (*iter.extra_ptr()).iter.target = set;
    (*iter.extra_ptr()).iter.index = 0;
    (*iter.extra_ptr()).iter.kind = kind;
    iter.prototype = heap.iterator_proto;

    HString* next_key = builtin_intern_string(heap, "next");
    if (next_key != null) {
        HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
        if (try fn_obj = fn_raw) {
            (*fn_obj.extra_ptr()).func.builtin_fn_index = (int)BUILTIN_SET_ITERATOR_NEXT;
            fn_obj.flags.callable = true;
            fn_obj.prototype = heap.function_proto;
            TVal fn_tv;
            fn_tv.set_object(fn_obj);
            iter.put_prop(next_key, fn_tv, hobject::PROP_FLAGS_NWC);
        }
    }
    ctx.result.set_object(iter);
}
fn void builtin_array_proto_values(BuiltinContext* ctx) {
    create_array_iterator(ctx, 0);
}

/// Array.prototype.keys — ES2015 §22.1.3.17 (kind=1)
fn void builtin_array_proto_keys(BuiltinContext* ctx) {
    create_array_iterator(ctx, 1);
}

/// Array.prototype.entries — ES2015 §22.1.3.5 (kind=2)
fn void builtin_array_proto_entries(BuiltinContext* ctx) {
    create_array_iterator(ctx, 2);
}

/// String.prototype[Symbol.iterator] — creates a string iterator object.
fn void builtin_string_proto_symbol_iter(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;

    // Get `this` — must be a string or String object
    TVal this_val = ctx.this_val;
    HString* str_data = null;
    if (this_val.is_string()) {
        str_data = (HString*)this_val.get_heapptr();
    } else if (this_val.is_object()) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        if ((*obj.extra_ptr()).prim.primitive_value.is_string()) {
            str_data = (HString*)(*obj.extra_ptr()).prim.primitive_value.get_heapptr();
        }
    }

    if (str_data == null) {
        ctx.result.set_undefined();
        return;
    }

    // Create a STRING_ITERATOR object
    HObject*? iter_raw = heap.alloc_object(hobject::ObjClass.STRING_ITERATOR);
    if (catch err = iter_raw) { ctx.result.set_undefined(); return; }
    HObject* iter = iter_raw;
    // Store the string as primitive_value (for GC tracing via mark_tval).
    // extra.prim.primitive_value occupies bytes 0-7; extra.iter.index
    // occupies bytes 8-11 — non-overlapping, so both can be used together.
    (*iter.extra_ptr()).prim.primitive_value.set_string(str_data);
    (*iter.extra_ptr()).iter.index = 0;
    iter.prototype = heap.iterator_proto;

    // Add .next method as an own property
    HString* next_key = builtin_intern_string(heap, "next");
    if (next_key != null) {
        HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
        if (try fn_obj = fn_raw) {
            (*fn_obj.extra_ptr()).func.builtin_fn_index = (int)BUILTIN_STRING_ITERATOR_NEXT;
            fn_obj.flags.callable = true;
            fn_obj.prototype = heap.function_proto;
            TVal fn_tv;
            fn_tv.set_object(fn_obj);
            iter.put_prop(next_key, fn_tv, hobject::PROP_FLAGS_NWC);
        }
    }

    ctx.result.set_object(iter);
}

/// %IteratorPrototype%[@@iterator] (ES6 §25.1.2.1) — returns `this`.
fn void builtin_iterator_proto_symbol_iter(BuiltinContext* ctx) {
    *ctx.result = ctx.this_val;
}

/// Array iterator .next() — returns {value, done}.
fn void builtin_array_iterator_next(BuiltinContext* ctx) {
    TVal this_val = ctx.this_val;
    Heap* heap = ctx.heap;

    if (!this_val.is_object()) {
        ctx.should_throw = true;
        ctx.result.set_undefined();
        return;
    }

    HObject* iter = (HObject*)this_val.get_heapptr();
    if (iter.get_class() != hobject::ObjClass.ARRAY_ITERATOR) {
        ctx.should_throw = true;
        ctx.result.set_undefined();
        return;
    }

    HObject* target = (*iter.extra_ptr()).iter.target;
    if (target == null) {
        ctx.result.set_undefined();
        return;
    }

    uint idx = (*iter.extra_ptr()).iter.index;

    // Check if done — always use .length (cached array_length for ARRAY exotic)
    bool done = false;
    TVal value;
    value.set_undefined();

    // Get length: use cached array_length for ARRAY exotic, else .length property
    long len = 0;
    if (target.get_class() == hobject::ObjClass.ARRAY) {
        len = (long)*target.array_len_ptr();
    } else {
        TVal? len_val = target.get_prop_proto((HString*)heap.strs[heap::BuiltinStr.LENGTH]);
        if (try lv = len_val) {
            if (lv.is_fastint()) {
                len = lv.get_fastint();
            } else if (lv.is_number()) {
                len = (long)lv.get_number();
            }
        }
    }

    if ((long)idx >= len) {
        done = true;
    } else {
        // Try dense array part first, then fall back to property table
        TVal? elem = target.get_array_idx(idx);
        if (try v = elem) {
            value = v;
        } else {
            // Not in dense part — try property table via stringified index
            char[32] idx_buf;
            int idx_len = libc::snprintf(&idx_buf[0], 32, "%u", idx);
            uint idx_hash = heap.hash_string(idx_buf[:idx_len]);
            HString* idx_str = heap.str_table_lookup(idx_buf[:idx_len], idx_hash);
            if (idx_str == null) {
                HString*? new_str = hstring::hstring_alloc(heap, idx_buf[:idx_len], idx_hash);
                if (try s = new_str) {
                    heap.str_table_insert(s);
                    idx_str = s;
                }
            }
            if (idx_str != null) {
                TVal? elem_val = target.get_prop_proto(idx_str);
                if (try ev = elem_val) {
                    value = ev;
                }
                // else: element is a hole — value stays undefined
            }
        }
    }

    if (!done) {
        (*iter.extra_ptr()).iter.index = idx + 1;
    }

    // Adjust value based on iterator kind
    uint kind = (*iter.extra_ptr()).iter.kind;
    if (kind == 1) {
        // keys() iterator: value = index
        value.set_fastint((long)idx);
    } else if (kind == 2) {
        // entries() iterator: value = [index, value]
        HObject*? pair_raw = heap.alloc_object(hobject::ObjClass.ARRAY);
        if (try pair = pair_raw) {
            pair.prototype = heap.array_proto;
            TVal idx_tv;
            idx_tv.set_fastint((long)idx);
            pair.set_array_idx(0, idx_tv);
            pair.set_array_idx(1, value);
            pair.array_used = 2;
            value.set_object(pair);
        }
    }
    // kind==0: value stays as-is (default/@@iterator)

    // Create result object: {value, done}
    HObject*? result_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = result_raw) { ctx.result.set_undefined(); return; }
    HObject* result = result_raw;
    result.prototype = null;

    // Set .value
    HString* value_key = (HString*)heap.strs[heap::BuiltinStr.VALUE];
    result.put_prop(value_key, value, hobject::PROP_FLAGS_WEC);

    // Set .done
    HString* done_key = (HString*)heap.strs[heap::BuiltinStr.DONE];
    TVal done_tv;
    done_tv.set_boolean(done);
    result.put_prop(done_key, done_tv, hobject::PROP_FLAGS_WEC);

    ctx.result.set_object(result);
}

/// String iterator .next() — returns {value, done}.
fn void builtin_string_iterator_next(BuiltinContext* ctx) {
    TVal this_val = ctx.this_val;
    Heap* heap = ctx.heap;

    if (!this_val.is_object()) {
        ctx.should_throw = true;
        ctx.result.set_undefined();
        return;
    }

    HObject* iter = (HObject*)this_val.get_heapptr();
    if (iter.get_class() != hobject::ObjClass.STRING_ITERATOR) {
        ctx.should_throw = true;
        ctx.result.set_undefined();
        return;
    }

    HString* str = (HString*)(*iter.extra_ptr()).prim.primitive_value.get_heapptr();
    if (str == null) {
        ctx.result.set_undefined();
        return;
    }

    uint idx = (*iter.extra_ptr()).iter.index;
    char[] data = str.get_data();

    if (idx >= data.len) {
        // Done — return {value: undefined, done: true}
        HObject*? result_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err = result_raw) { ctx.result.set_undefined(); return; }
        HObject* result = result_raw;
        result.prototype = null;
        HString* done_key = (HString*)heap.strs[heap::BuiltinStr.DONE];
        TVal done_tv;
        done_tv.set_boolean(true);
        result.put_prop(done_key, done_tv, hobject::PROP_FLAGS_WEC);
        HString* value_key = (HString*)heap.strs[heap::BuiltinStr.VALUE];
        TVal undef;
        undef.set_undefined();
        result.put_prop(value_key, undef, hobject::PROP_FLAGS_WEC);
        ctx.result.set_object(result);
        return;
    }

    // Determine the byte length of the UTF-8 sequence starting at data[idx].
    // Cap at remaining bytes to handle truncated sequences gracefully.
    uint seq_len = hstring::utf8_seq_len(data[idx]);
    usz remain = (usz)(data.len - (long)idx);
    if ((usz)seq_len > remain) {
        seq_len = (uint)remain;
    }

    (*iter.extra_ptr()).iter.index = idx + seq_len;

    // Create result object: {value: char, done: false}
    HObject*? result_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = result_raw) { ctx.result.set_undefined(); return; }
    HObject* result = result_raw;
    result.prototype = null;

    // Set .value — code point string (1-4 bytes)
    HString* value_key = (HString*)heap.strs[heap::BuiltinStr.VALUE];
    HString* cp_str = heap.str_intern(data[idx : seq_len]);
    if (cp_str != null) {
        TVal value_tv;
        value_tv.set_string(cp_str);
        result.put_prop(value_key, value_tv, hobject::PROP_FLAGS_WEC);
    }

    // Set .done
    HString* done_key = (HString*)heap.strs[heap::BuiltinStr.DONE];
    TVal done_tv;
    done_tv.set_boolean(false);
    result.put_prop(done_key, done_tv, hobject::PROP_FLAGS_WEC);

    ctx.result.set_object(result);
}

/// RegExpStringIterator .next() — ES2020 §21.2.7.2.1
/// Lazily yields the next regexp match result.
fn void builtin_regexp_string_iterator_next(BuiltinContext* ctx) {
    TVal this_val = ctx.this_val;
    Heap* heap = ctx.heap;

    // Validate this
    if (!this_val.is_object()) {
        ctx.should_throw = true;
        ctx.result.set_undefined();
        return;
    }

    HObject* iter = (HObject*)this_val.get_heapptr();
    if (iter.get_class() != hobject::ObjClass.REGEXP_STRING_ITERATOR) {
        ctx.should_throw = true;
        ctx.result.set_undefined();
        return;
    }

    // If already done, return {value: undefined, done: true}
    uint flags = (*iter.extra_ptr()).regexp_iter.flags;
    if (flags & 2) { // done bit
        HObject*? result_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err = result_raw) { ctx.result.set_undefined(); return; }
        HObject* result = result_raw;
        result.prototype = null;
        HString* done_key = (HString*)heap.strs[heap::BuiltinStr.DONE];
        TVal done_tv;
        done_tv.set_boolean(true);
        result.put_prop(done_key, done_tv, hobject::PROP_FLAGS_WEC);
        HString* value_key = (HString*)heap.strs[heap::BuiltinStr.VALUE];
        TVal undef;
        undef.set_undefined();
        result.put_prop(value_key, undef, hobject::PROP_FLAGS_WEC);
        ctx.result.set_object(result);
        return;
    }

    HObject* rx = (*iter.extra_ptr()).regexp_iter.regexp;
    HString* s_hstr = (HString*)(*iter.extra_ptr()).regexp_iter.string_val.get_heapptr();
    if (rx == null || s_hstr == null) {
        ctx.result.set_undefined();
        return;
    }

    char* input = s_hstr.get_cstr();
    int input_len = (int)s_hstr.blen;
    bool global_flag = (flags & 1) != 0;

    // Get lastIndex from the regexp
    HString* li_key = builtin_intern_string(heap, "lastIndex");
    int search_pos = 0;
    if (try liv = rx.get_prop_proto(li_key)) {
        if (liv.is_fastint()) {
            search_pos = (int)liv.get_fastint();
        } else if (liv.is_number()) {
            search_pos = (int)liv.get_number();
        }
    }
    if (search_pos < 0) search_pos = 0;
    if (search_pos > input_len) {
        // lastIndex beyond end — no match per ES2020 §21.2.5.2.2 step 6
        // Also handles empty-match-at-end-of-string advance.
        (*iter.extra_ptr()).regexp_iter.flags |= 2;
        if (global_flag) {
            TVal zero_tv; zero_tv.set_fastint(0);
            rx.put_prop(li_key, zero_tv, hobject::PROP_FLAGS_WEC);
        }
        HObject*? result_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err = result_raw) { ctx.result.set_undefined(); return; }
        HObject* result = result_raw;
        result.prototype = null;
        HString* done_key = (HString*)heap.strs[heap::BuiltinStr.DONE];
        TVal done_tv;
        done_tv.set_boolean(true);
        result.put_prop(done_key, done_tv, hobject::PROP_FLAGS_WEC);
        HString* value_key = (HString*)heap.strs[heap::BuiltinStr.VALUE];
        TVal undef;
        undef.set_undefined();
        result.put_prop(value_key, undef, hobject::PROP_FLAGS_WEC);
        ctx.result.set_object(result);
        return;
    }

    // Execute regexp
    int out_start = 0;
    int out_end = 0;
    int out_num_captures = 0;
    int[re_bindings::RE_MAX_CAPTURES] caps_start;
    int[re_bindings::RE_MAX_CAPTURES] caps_end;
    libc::memset(&caps_start, 0, re_bindings::RE_MAX_CAPTURES * int::size);
    libc::memset(&caps_end, 0, re_bindings::RE_MAX_CAPTURES * int::size);

    int exec_result = re_bindings::re_exec(
        (*rx.extra_ptr()).regexp.regexp_data, input, input_len, search_pos,
        &out_start, &out_end, &out_num_captures,
        &caps_start, &caps_end, re_bindings::RE_MAX_CAPTURES
    );

    if (exec_result != re_bindings::RE_MATCH) {
        // No match — mark done and reset lastIndex to 0 if global
        (*iter.extra_ptr()).regexp_iter.flags |= 2;
        if (global_flag) {
            TVal zero_tv; zero_tv.set_fastint(0);
            rx.put_prop(li_key, zero_tv, hobject::PROP_FLAGS_WEC);
        }
        HObject*? result_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err = result_raw) { ctx.result.set_undefined(); return; }
        HObject* result = result_raw;
        result.prototype = null;
        HString* done_key = (HString*)heap.strs[heap::BuiltinStr.DONE];
        TVal done_tv;
        done_tv.set_boolean(true);
        result.put_prop(done_key, done_tv, hobject::PROP_FLAGS_WEC);
        HString* value_key = (HString*)heap.strs[heap::BuiltinStr.VALUE];
        TVal undef;
        undef.set_undefined();
        result.put_prop(value_key, undef, hobject::PROP_FLAGS_WEC);
        ctx.result.set_object(result);
        return;
    }

    // Match found — update lastIndex
    if (global_flag) {
        int next_pos = out_end;
        if (out_end == search_pos) {
            // Empty match: advance by one byte (per ES2020 §21.2.5.2.2
            // AdvanceStringIndex with unicode=false).  The original matchAll
            // loop did the same: search_pos = out_end + 1.
            next_pos = search_pos + 1;
        }
        TVal next_tv; next_tv.set_fastint((long)next_pos);
        rx.put_prop(li_key, next_tv, hobject::PROP_FLAGS_WEC);
    }

    // Create match result array (same layout as RegExp.prototype.exec)
    HObject*? match_arr_raw = heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = match_arr_raw) { ctx.result.set_undefined(); return; }
    HObject* match_arr = match_arr_raw;
    match_arr.prototype = heap.array_proto;

    // Element 0: full match string
    usz match_len = (usz)(out_end - out_start);
    HString* match_str;
    if (match_len == 0) {
        match_str = builtin_intern_string(heap, "");
    } else {
        match_str = builtin_intern_string(heap, input[out_start : match_len]);
    }
    TVal elem;
    elem.set_string(match_str);
    HString* zero_key = builtin_intern_string(heap, "0");
    match_arr.put_prop(zero_key, elem, hobject::PROP_FLAGS_WEC);

    // Capture groups
    uint match_arr_len = 1;
    int num_caps = out_num_captures;
    if (num_caps > re_bindings::RE_MAX_CAPTURES) num_caps = re_bindings::RE_MAX_CAPTURES;
    for (int i = 0; i < num_caps; i++) {
        HString* cap_str;
        if (caps_start[i] >= 0 && caps_end[i] >= 0) {
            usz cap_len = (usz)(caps_end[i] - caps_start[i]);
            cap_str = cap_len == 0
                ? builtin_intern_string(heap, "")
                : builtin_intern_string(heap, input[caps_start[i] : cap_len]);
        } else {
            cap_str = null;
        }
        TVal cap_elem;
        if (cap_str != null) {
            cap_elem.set_string(cap_str);
        } else {
            cap_elem.set_undefined();
        }
        match_arr.put_prop(heap.int_to_hstring((long)(i + 1)), cap_elem, hobject::PROP_FLAGS_WEC);
        match_arr_len++;
    }

    // Set index property
    TVal idx_tv;
    idx_tv.set_fastint((long)out_start);
    HString* idx_key = builtin_intern_string(heap, "index");
    match_arr.put_prop(idx_key, idx_tv, hobject::PROP_FLAGS_WEC);

    // Set input property
    TVal input_tv;
    input_tv.set_string(s_hstr);
    HString* input_key = builtin_intern_string(heap, "input");
    match_arr.put_prop(input_key, input_tv, hobject::PROP_FLAGS_WEC);

    // Set length
    TVal mlen_tv;
    mlen_tv.set_fastint((long)match_arr_len);
    HString* mlen_key = builtin_intern_string(heap, "length");
    match_arr.put_prop(mlen_key, mlen_tv, hobject::PROP_FLAGS_WEC);

    // Create result iterator result: {value: matchArr, done: false}
    HObject*? iter_result_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = iter_result_raw) { ctx.result.set_undefined(); return; }
    HObject* iter_result = iter_result_raw;
    iter_result.prototype = null;

    HString* value_key = (HString*)heap.strs[heap::BuiltinStr.VALUE];
    TVal match_tv;
    match_tv.set_object(match_arr);
    iter_result.put_prop(value_key, match_tv, hobject::PROP_FLAGS_WEC);

    HString* done_key = (HString*)heap.strs[heap::BuiltinStr.DONE];
    TVal done_tv;
    done_tv.set_boolean(false);
    iter_result.put_prop(done_key, done_tv, hobject::PROP_FLAGS_WEC);

    ctx.result.set_object(iter_result);
}

/// Create %IteratorPrototype% (ES6 §25.1.2).
/// %IteratorPrototype% has [Symbol.iterator]() that returns `this`.
fn bool register_iterator_prototype(Heap* heap) {
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = null;  // will be wired to object_proto later
    heap.iterator_proto = proto;

    // Add [Symbol.iterator]() → returns `this`
    HString* iter_sym = ensure_iterator_symbol(heap);
    if (iter_sym != null) {
        HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
        if (catch err = fn_raw) return false;
        HObject* fn_obj = fn_raw;
        (*fn_obj.extra_ptr()).func.builtin_fn_index = (int)BUILTIN_ITERATOR_PROTO_SYMBOL_ITER;
        fn_obj.flags.callable = true;
        fn_obj.prototype = heap.function_proto;
        // Set .name
        HString* name_key = builtin_intern_string(heap, "name");
        HString* name_val = builtin_intern_string(heap, "[Symbol.iterator]");
        if (name_key != null && name_val != null) {
            TVal name_tv;
            name_tv.set_string(name_val);
            fn_obj.put_prop(name_key, name_tv, hobject::PROP_FLAGS_NWC);
        }
        // Set .length = 0
        HString* len_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
        if (len_key != null) {
            TVal len_tv;
            len_tv.set_fastint(0);
            fn_obj.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NWC);
        }
        TVal iter_tv;
        iter_tv.set_object(fn_obj);
        proto.put_prop(iter_sym, iter_tv, hobject::PROP_FLAGS_WC);
    }

    return true;
}

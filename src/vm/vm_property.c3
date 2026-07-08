module duktape::vm;

import duktape::types;
import duktape::bytecode;
import duktape::heap;
import duktape::hstring;
import duktape::hobject;
import duktape::env;
import duktape::builtins;
import libc;
import duktape::re_bindings;
import std::math;

// ============================================================================
// vm_property — GETPROP / PUTPROP / DELPROP and inline-cache paths
// ============================================================================
/// Sub-dispatch for GETPROP, GETPROPC, GETPROPC_CACHED, GETPROPC2, PUTPROP, DELPROP opcodes.
fn TVal? dispatch_property(Dispatch* ds, Opcode op, TVal* ra, TVal* rb, TVal* rc, Instruction insn) {
    Vm* vm = ds.vm;
    switch (op) {
        case Opcode.GETPROP:
            if (rb.is_object()) {
                HObject* hobj = (HObject*)rb.get_heapptr();

                // Inline Cache fast path: check shape + key + prop_values pointer
                // NOTE: We use prop_values() (not prop_alloc) because prop_alloc is
                // NULL for objects with ≤4 inline properties, making the check always
                // true for all small objects. prop_values() returns a unique pointer
                // per object even for inline properties.
                if (ds.ic_base != null) {
                    uint pc_off = (uint)(ds.curr_pc - 1 - ds.code_base);
                    hobject::ICEntry* ic = ds.ic_base + pc_off;
                    void* lookup_key = null;
                    if (rc.is_string()) lookup_key = rc.get_heapptr();
                    if (lookup_key != null && ic.key == lookup_key && ic.shape_id == hobj.shape_id) {
                        HObject* ic_owner = ic.proto == null ? hobj : (HObject*)ic.proto;
                        if (ic.cached_prop_alloc == (void*)ic_owner.prop_values()) {
                            // Ultra-fast path: when the IC value is not a heap
                            // pointer (common for fastint/number results), skip
                            // decref/incref/track_heap_store entirely.
                            TVal ic_val = *ic.prop_value_ptr;
                            if (!ic_val.is_heap_allocated()) {
                                *ra = ic_val;
                            } else {
                                vm.heap.tval_copy_ref(ra, &ic_val);
                                track_heap_store(ds.act, ra, (uint)insn.a);
                            }
                            return (TVal){};
                        }
                    }
                }

                // Fast path: dense array indexed access (a[i] where i is a non-negative integer)
                // Also handles ARGUMENTS exotic objects for arguments[i] access
                if ((hobj.get_class() == hobject::ObjClass.ARRAY || hobj.get_class() == hobject::ObjClass.ARGUMENTS) && hobj.array_part() != null && (rc.is_fastint() || rc.is_number())) {
                    long idx_long = rc.is_fastint() ? rc.get_fastint() : (long)rc.get_number();
                    if (idx_long >= 0 && idx_long < (long)hobj.array_size) {
                        TVal? av = hobj.get_array_idx((uint)idx_long);
                        if (try v = av) {
                            vm.heap.tval_copy_ref(ra, &v);
                            track_heap_store(ds.act, ra, (uint)insn.a);
                            return (TVal){};
                        }
                        // Array hole — fall through to prototype chain lookup
                    }
                }

                // ARRAY exotic: .length fast path — return array_length directly
                if (hobj.get_class() == hobject::ObjClass.ARRAY && rc.is_string() && rc.get_heapptr() == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH]) {
                    ra.set_fastint((long)*hobj.array_len_ptr());
                    return (TVal){};
                }

                void* key = get_prop_key(vm, rc);
                if (key != null) {
                    // ES5 strict mode: arguments.callee throws TypeError.
                    // Strict-only engine: always throws.
                    if (hobj.get_class() == hobject::ObjClass.ARGUMENTS
                        && key == (void*)vm.heap.strs[heap::BuiltinStr.CALLEE]) {
                        if (!vm_throw_error(vm, vm.heap.type_err_proto, "'callee', 'arguments', and 'arguments.caller' may not be accessed in strict mode", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return VM_ERROR~;
                        }
                        return (TVal){};
                    }
                    // ES5 strict mode: function.caller and function.arguments throw TypeError
                    if (hobj.is_callable() && hobj.get_class() == hobject::ObjClass.FUNCTION) {
                        HString* key_hstr = (HString*)key;
                        if (key_hstr != null && (key_hstr.equals("caller") || key_hstr.equals("arguments"))) {
                            if (!vm_throw_error(vm, vm.heap.type_err_proto, "'caller' and 'arguments' properties may not be accessed on strict mode functions or the arguments objects for calls to them", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                return VM_ERROR~;
                            }
                            return (TVal){};
                        }
                    }
                    // STRING exotic: indexed access reads characters lazily from the primitive value.
                    // Handles both fastint/number keys (e.g. s[0]) and array-index string keys
                    // (e.g. s["0"]), avoiding the need to materialise per-character own properties.
                    if (hobj.flags.exotic_stringobj && (*hobj.extra_ptr()).prim.primitive_value.is_string()) {
                        long sidx = -1;
                        if (rc.is_fastint()) {
                            sidx = rc.get_fastint();
                        } else if (rc.is_number()) {
                            double d = rc.get_number();
                            if (d >= 0 && d == (double)(long)d) sidx = (long)d;
                        } else if (rc.is_string()) {
                            // String key that is a canonical array index (cached on HString)
                            HString* key_hstr = (HString*)rc.get_heapptr();
                            if (key_hstr != null && key_hstr.is_arridx()) {
                                sidx = (long)key_hstr.array_index();
                            }
                        }
                        if (sidx >= 0) {
                            HString* prim_str = (HString*)(*hobj.extra_ptr()).prim.primitive_value.get_heapptr();
                            if (sidx < (long)prim_str.char_length()) {
                                uint cp = prim_str.char_at((uint)sidx);
                                char[4] sbuf;
                                uint sblen = hstring::encode_codepoint(cp, sbuf[:4]);
                                HString* interned = intern_string(vm, sbuf[:sblen]);
                                if (interned != null) {
                                    vm.heap.set_reg_string(ra, interned);
                                } else {
                                    return VM_ERROR~;
                                }
                                return (TVal){};
                            }
                            // Out-of-range index on a string exotic: fall through to own-property
                            // lookup so that explicitly assigned out-of-range slots are still found.
                        }
                    }
                    // Megamorphic cache: try global (shape, key) → offset cache before full chain walk
                    hobject::MegamorphicEntry* mega = hobject::mega_cache_lookup(vm.heap, hobj, key);
                    if (mega != null) {
                        TVal mega_val = *mega.prop_value_ptr;
                        if (!mega_val.is_heap_allocated()) {
                            *ra = mega_val;
                        } else {
                            vm.heap.tval_copy_ref(ra, &mega_val);
                            track_heap_store(ds.act, ra, (uint)insn.a);
                        }
                        return (TVal){};
                    }
                    hobject::PropLookupResult res = hobj.get_prop_or_accessor_proto(key, true);
                    if (res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
                        TVal obj_val;
                        obj_val.set_object(hobj);
                        if (invoke_getter(vm, &res.acc, &obj_val, (uint)insn.a,
                                          ds.act, &ds.curr_pc, &ds.needs_restart, ds.regs_base)) {
                            ds.regs_base = ds.act.bottom;
                            return (TVal){};
                        }
                        return (TVal){};
                        } else if (res.kind == hobject::PropLookupKind.PROP_DATA) {
                            vm.heap.tval_copy_ref(ra, &res.data_val);
                            track_heap_store(ds.act, ra, (uint)insn.a);
                            // Populate IC for this site.
                            // Only cache OWN property lookups. Inherited lookups are not cached
                            // because the IC would have no way to detect modifications to
                            // intermediate objects in the prototype chain (e.g. when
                            // B.prototype.foo = ... is set, an IC that previously resolved
                            // b.foo via A.prototype would return a stale value). This matches
                            // the QuickJS approach where the shape itself encodes the proto
                            // and lookups always walk the current chain.
                            if (res.owner == hobj && res.owner != null && ds.ic_base != null) {
                                uint pc_off = (uint)(ds.curr_pc - 1 - ds.code_base);
                                hobject::ICEntry* ic = ds.ic_base + pc_off;
                                int owner_idx = res.owner.find_prop_idx(key);
                                if (owner_idx >= 0) {
                                    ic.shape_id = hobj.shape_id;
                                    ic.proto = null;  // own property
                                    ic.prop_idx = (ushort)owner_idx;
                                    ic.prop_flags = res.owner.get_prop_flags((uint)owner_idx);
                                    if (ic.key != null) { vm.heap.decref((types::HeapHeader*)ic.key); }
                                    ic.key = key;
                                    if (key != null) { ((types::HeapHeader*)key).incref(); }
                                    ic.prop_value_ptr = &res.owner.prop_values()[owner_idx];
                                    ic.cached_prop_alloc = (void*)res.owner.prop_values();
                                    // Also populate megamorphic cache for cross-site benefit
                                    hobject::mega_cache_store(vm.heap, hobj, key, res.owner, owner_idx);
                                }
                            }
                        } else {
                            ra.set_undefined();
                        }
                    } else {
                        ra.set_undefined();
                    }
            } else if (rb.is_null() || rb.is_undefined()) {
                // TypeError: Cannot read properties of null/undefined
                HString* name_hstr = null;
                if (rc.is_string()) {
                    name_hstr = (HString*)rc.get_heapptr();
                }
                char[types::ERROR_MSG_BUF] msg_buf;
                int msg_len;
                if (name_hstr != null) {
                    msg_len = libc::snprintf(&msg_buf, types::ERROR_MSG_BUF, "Cannot read properties of %s (reading '%s')",
                                              (rb.is_null() ? "null" : "undefined"),
                                              name_hstr.get_cstr());
                } else {
                    msg_len = libc::snprintf(&msg_buf, types::ERROR_MSG_BUF, "Cannot read properties of %s",
                                              (rb.is_null() ? "null" : "undefined"));
                }
                char[] msg_slice = (msg_len > 0 && msg_len < types::ERROR_MSG_BUF) ? msg_buf[:msg_len] : msg_buf[:0];
                if (!vm_throw_error(vm, vm.heap.type_err_proto, msg_slice, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return VM_ERROR~;
                }
            } else if (rb.is_string()) {
                // Check if this is a Symbol (0xFF-prefixed string)
                HString* h_str = (HString*)rb.get_heapptr();
                if (h_str != null && h_str.is_symbol() && vm.heap.symbol_proto != null) {
                    // Auto-box symbol primitive: create a temporary wrapper object
                    // so that accessor properties (like description getter) work correctly.
                    HString* key = get_prop_key(vm, rc);
                    if (key != null) {
                        HObject*? wrapper_raw = vm.heap.alloc_object(hobject::ObjClass.SYMBOL);
                        HObject* wrapper;
                        if (try w = wrapper_raw) {
                            wrapper = w;
                            wrapper.prototype = vm.heap.symbol_proto;
                            // Store the symbol primitive as [[SymbolData]]
                            wrapper.extra_ptr().prim.primitive_value = *rb;
                        } else {
                            ra.set_undefined();
                            return (TVal){};
                        }
                        hobject::PropLookupResult res = wrapper.get_prop_or_accessor_proto(key, true);
                        if (res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
                            TVal wrapper_tv;
                            wrapper_tv.set_object(wrapper);
                            if (invoke_getter(vm, &res.acc, &wrapper_tv, (uint)insn.a,
                                              ds.act, &ds.curr_pc, &ds.needs_restart, ds.regs_base)) {
                                ds.regs_base = ds.act.bottom;
                                return (TVal){};
                            }
                            return (TVal){};
                        } else if (res.kind == hobject::PropLookupKind.PROP_DATA) {
                            vm.heap.tval_copy_ref(ra, &res.data_val);
                            track_heap_store(ds.act, ra, (uint)insn.a);
                        } else {
                            ra.set_undefined();
                        }
                    } else {
                        ra.set_undefined();
                    }
                } else {
                    // Auto-box string primitive
                    HString* str_prim = (HString*)rb.get_heapptr();

                    // Fast path: numeric index → character at index
                    long str_idx = -1;
                    if (rc.is_fastint()) {
                        str_idx = rc.get_fastint();
                    } else if (rc.is_number()) {
                        double d = rc.get_number();
                        if (d >= 0 && d == (double)(long)d) {
                            str_idx = (long)d;
                        }
                    }
                    if (str_idx >= 0 && str_idx < (long)str_prim.char_length()) {
                        uint cp = str_prim.char_at((uint)str_idx);
                        char[4] cbuf;
                        uint cblen = hstring::encode_codepoint(cp, cbuf[:4]);
                        HString* interned = intern_string(vm, cbuf[:cblen]);
                        if (interned != null) {
                            vm.heap.set_reg_string(ra, interned);
                        } else {
                            return VM_ERROR~;
                        }
                        return (TVal){};
                    }

                    HString* key = get_prop_key(vm, rc);
                    if (key != null) {
                        // Fast path: .length → string character count
                        if (key == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH]) {
                            ra.set_fastint((long)h_str.char_length());
                            return (TVal){};
                        }
                        // Slow path: walk String.prototype chain
                        if (vm.heap.string_proto != null) {
                            TVal? result = vm.heap.string_proto.get_prop_proto(key);
                            if (try v = result) {
                                vm.heap.tval_copy_ref(ra, &v);
                                track_heap_store(ds.act, ra, (uint)insn.a);
                            } else {
                                ra.set_undefined();
                            }
                        } else {
                            ra.set_undefined();
                        }
                    } else {
                        ra.set_undefined();
                    }
                }
            } else if (rb.is_number() || rb.is_fastint()) {
                // Auto-box number primitive: walk Number.prototype chain
                HString* key = get_prop_key(vm, rc);
                if (key != null && vm.heap.number_proto != null) {
                    TVal? result = vm.heap.number_proto.get_prop_proto(key);
                    if (try v = result) {
                        vm.heap.tval_copy_ref(ra, &v);
                        track_heap_store(ds.act, ra, (uint)insn.a);
                    } else {
                        ra.set_undefined();
                    }
                } else {
                    ra.set_undefined();
                }
            } else if (rb.is_boolean()) {
                // Auto-box boolean primitive: walk Boolean.prototype chain
                HString* key = get_prop_key(vm, rc);
                if (key != null && vm.heap.bool_proto != null) {
                    TVal? result = vm.heap.bool_proto.get_prop_proto(key);
                    if (try v = result) {
                        vm.heap.tval_copy_ref(ra, &v);
                        track_heap_store(ds.act, ra, (uint)insn.a);
                    } else {
                        ra.set_undefined();
                    }
                } else {
                    ra.set_undefined();
                }
            } else if (rb.is_lightfunc()) {
                // LIGHTFUNC: resolve .name and .length from metadata, other props from Function.prototype
                uint fn_idx = (uint)(usz)rb.get_heapptr();
                HString* key = get_prop_key(vm, rc);
                if (key != null) {
                    if (key.equals("name")) {
                        if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], fn_idx, 0)) {
                            builtins::BuiltinMeta meta = builtins::builtin_get_metadata(fn_idx);
                            if (meta.name.len > 0) {
                                HString* name_str = intern_string(vm, meta.name);
                                vm.heap.set_reg_string(ra, name_str);
                            } else {
                                ra.set_undefined();
                            }
                        } else if (vm.heap.function_proto != null) {
                            TVal? result = vm.heap.function_proto.get_prop_proto(key);
                            if (try v = result) { vm.heap.tval_copy_ref(ra, &v); track_heap_store(ds.act, ra, (uint)insn.a); }
                            else { ra.set_undefined(); }
                        } else { ra.set_undefined(); }
                    } else if (key.equals("length")) {
                        if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], fn_idx, 1)) {
                            builtins::BuiltinMeta meta = builtins::builtin_get_metadata(fn_idx);
                            if (meta.arity >= 0) {
                                ra.set_number(meta.arity);
                            } else {
                                ra.set_undefined();
                            }
                        } else if (vm.heap.function_proto != null) {
                            TVal? result = vm.heap.function_proto.get_prop_proto(key);
                            if (try v = result) { vm.heap.tval_copy_ref(ra, &v); track_heap_store(ds.act, ra, (uint)insn.a); }
                            else { ra.set_undefined(); }
                        } else { ra.set_undefined(); }
                    } else if (key.equals("prototype")) {
                        if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], fn_idx, 2)) {
                            // Resolve .prototype for constructor lightfuncs (Boolean, Number, etc.)
                            HObject* proto_obj = lightfunc_get_proto(vm, fn_idx);
                            if (proto_obj != null) {
                                ra.set_object(proto_obj);
                                track_heap_store(ds.act, ra, (uint)insn.a);
                            } else {
                                ra.set_undefined();
                            }
                        } else if (vm.heap.function_proto != null) {
                            TVal? result = vm.heap.function_proto.get_prop_proto(key);
                            if (try v = result) { vm.heap.tval_copy_ref(ra, &v); track_heap_store(ds.act, ra, (uint)insn.a); }
                            else { ra.set_undefined(); }
                        } else { ra.set_undefined(); }
                    } else if (key.equals("caller") || key.equals("arguments")) {
                        // ES5 strict mode: accessing .caller and .arguments throws TypeError
                        if (!vm_throw_error(vm, vm.heap.type_err_proto, "'caller' and 'arguments' properties may not be accessed on strict mode functions or the arguments objects for calls to them", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return VM_ERROR~;
                        }
                    } else if (vm.heap.function_proto != null) {
                        // Walk Function.prototype for .call, .apply, .bind, etc.
                        TVal? result = vm.heap.function_proto.get_prop_proto(key);
                        if (try v = result) {
                            vm.heap.tval_copy_ref(ra, &v);
                            track_heap_store(ds.act, ra, (uint)insn.a);
                        } else {
                            ra.set_undefined();
                        }
                    } else {
                        ra.set_undefined();
                    }
                } else {
                    ra.set_undefined();
                }
            } else {
                ra.set_undefined();
            }
            return (TVal){};

        case Opcode.GETPROPC:
            // Fused LDCONST+GETPROP: key comes from constant pool (always a string).
            {
                TVal key_tval = ds.constants[(uint)insn.c];
                HString* key_hstr = (HString*)key_tval.get_heapptr();
                if (rb.is_object()) {
                    HObject* hobj = (HObject*)rb.get_heapptr();

                    // Inline Cache fast path: key is always non-null, skip lookup_key check.
                    if (ds.ic_base != null) {
                        uint pc_off = (uint)(ds.curr_pc - 1 - ds.code_base);
                        hobject::ICEntry* ic = ds.ic_base + pc_off;
                        if (ic.key == (void*)key_hstr && ic.shape_id == hobj.shape_id) {
                            HObject* ic_owner = ic.proto == null ? hobj : (HObject*)ic.proto;
                            if (ic.cached_prop_alloc == (void*)ic_owner.prop_values()) {
                                TVal ic_val = *ic.prop_value_ptr;
                                if (!ic_val.is_heap_allocated()) {
                                    *ra = ic_val;
                                } else {
                                    vm.heap.tval_copy_ref(ra, &ic_val);
                                    track_heap_store(ds.act, ra, (uint)insn.a);
                                }
                                return (TVal){};
                            }
                        }
                    }

                    // ARRAY exotic: .length fast path
                    if (hobj.get_class() == hobject::ObjClass.ARRAY && (void*)key_hstr == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH]) {
                        ra.set_fastint((long)*hobj.array_len_ptr());
                        return (TVal){};
                    }

                    void* key = (void*)key_hstr;
                    if (key != null) {
                        // ES5 strict mode: arguments.callee throws TypeError.
                        // Strict-only engine: always throws.
                        if (hobj.get_class() == hobject::ObjClass.ARGUMENTS
                            && key == (void*)vm.heap.strs[heap::BuiltinStr.CALLEE]) {
                            if (!vm_throw_error(vm, vm.heap.type_err_proto, "'callee', 'arguments', and 'arguments.caller' may not be accessed in strict mode", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                return VM_ERROR~;
                            }
                            return (TVal){};
                        }
                        // ES5 strict mode: function.caller and function.arguments throw TypeError
                        if (hobj.is_callable() && hobj.get_class() == hobject::ObjClass.FUNCTION
                            && (key_hstr.equals("caller") || key_hstr.equals("arguments"))) {
                            if (!vm_throw_error(vm, vm.heap.type_err_proto, "'caller' and 'arguments' properties may not be accessed on strict mode functions or the arguments objects for calls to them", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                return VM_ERROR~;
                            }
                            return (TVal){};
                        }
                        // STRING exotic: string-key indexed access (array-index string keys like "0")
                        if (hobj.flags.exotic_stringobj && (*hobj.extra_ptr()).prim.primitive_value.is_string()) {
                            if (key_hstr != null && key_hstr.is_arridx()) {
                                long sidx = (long)key_hstr.array_index();
                                HString* prim_str = (HString*)(*hobj.extra_ptr()).prim.primitive_value.get_heapptr();
                                if (sidx < (long)prim_str.char_length()) {
                                    uint cp = prim_str.char_at((uint)sidx);
                                    char[4] sbuf;
                                    uint sblen = hstring::encode_codepoint(cp, sbuf[:4]);
                                    HString* interned = intern_string(vm, sbuf[:sblen]);
                                    if (interned != null) {
                                        vm.heap.set_reg_string(ra, interned);
                                    } else {
                                        return VM_ERROR~;
                                    }
                                    return (TVal){};
                                }
                            }
                        }
                        // Megamorphic cache: try global (shape, key) → offset cache before full chain walk
                        hobject::MegamorphicEntry* mega = hobject::mega_cache_lookup(vm.heap, hobj, key);
                        if (mega != null) {
                            TVal mega_val = *mega.prop_value_ptr;
                            if (!mega_val.is_heap_allocated()) {
                                *ra = mega_val;
                            } else {
                                vm.heap.tval_copy_ref(ra, &mega_val);
                                track_heap_store(ds.act, ra, (uint)insn.a);
                            }
                            return (TVal){};
                        }
                        hobject::PropLookupResult res = hobj.get_prop_or_accessor_proto(key, true);
                        if (res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
                            TVal obj_val;
                            obj_val.set_object(hobj);
                            if (invoke_getter(vm, &res.acc, &obj_val, (uint)insn.a,
                                              ds.act, &ds.curr_pc, &ds.needs_restart, ds.regs_base)) {
                                ds.regs_base = ds.act.bottom;
                                return (TVal){};
                            }
                            return (TVal){};
                        } else if (res.kind == hobject::PropLookupKind.PROP_DATA) {
                            vm.heap.tval_copy_ref(ra, &res.data_val);
                            track_heap_store(ds.act, ra, (uint)insn.a);
                            // Populate IC for this site.
                            // Only cache OWN property lookups (see GETPROP comment).
                            if (res.owner == hobj && res.owner != null && ds.ic_base != null) {
                                uint pc_off = (uint)(ds.curr_pc - 1 - ds.code_base);
                                hobject::ICEntry* ic = ds.ic_base + pc_off;
                                int owner_idx = res.owner.find_prop_idx(key);
                                if (owner_idx >= 0) {
                                    ic.shape_id = hobj.shape_id;
                                    ic.proto = null;  // own property
                                    ic.prop_idx = (ushort)owner_idx;
                                    ic.prop_flags = res.owner.get_prop_flags((uint)owner_idx);
                                    if (ic.key != null) { vm.heap.decref((types::HeapHeader*)ic.key); }
                                    ic.key = key;
                                    if (key != null) { ((types::HeapHeader*)key).incref(); }
                                    ic.prop_value_ptr = &res.owner.prop_values()[owner_idx];
                                    ic.cached_prop_alloc = (void*)res.owner.prop_values();
                                    // Upgrade to cached variant now that IC is populated
                                    // Keep A, B, C operands the same, just change the opcode
                                    ds.curr_pc[-1] = bytecode::make_abc(bytecode::Opcode.GETPROPC_CACHED,
                                                                      (uint)insn.a, (uint)insn.b, (uint)insn.c);
                                    // Also populate megamorphic cache for cross-site benefit
                                    hobject::mega_cache_store(vm.heap, hobj, key, res.owner, owner_idx);
                                }
                            }
                        } else {
                            ra.set_undefined();
                        }
                    } else {
                        ra.set_undefined();
                    }
                } else if (rb.is_null() || rb.is_undefined()) {
                    char[types::ERROR_MSG_BUF] msg_buf;
                    int msg_len;
                    if (key_hstr != null) {
                        msg_len = libc::snprintf(&msg_buf, types::ERROR_MSG_BUF, "Cannot read properties of %s (reading '%s')",
                                                  (rb.is_null() ? "null" : "undefined"),
                                                  key_hstr.get_cstr());
                    } else {
                        msg_len = libc::snprintf(&msg_buf, types::ERROR_MSG_BUF, "Cannot read properties of %s",
                                                  (rb.is_null() ? "null" : "undefined"));
                    }
                    char[] msg_slice = (msg_len > 0 && msg_len < types::ERROR_MSG_BUF) ? msg_buf[:msg_len] : msg_buf[:0];
                    if (!vm_throw_error(vm, vm.heap.type_err_proto, msg_slice, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return VM_ERROR~;
                    }
                } else if (rb.is_string()) {
                    HString* h_str = (HString*)rb.get_heapptr();
                    if (h_str != null && h_str.is_symbol() && vm.heap.symbol_proto != null) {
                        if (key_hstr != null) {
                            // Auto-box symbol primitive: create a temporary wrapper object
                            // so that accessor properties (like description getter) work correctly.
                            HObject*? wrapper_raw = vm.heap.alloc_object(hobject::ObjClass.SYMBOL);
                            HObject* wrapper;
                            if (try w = wrapper_raw) {
                                wrapper = w;
                                wrapper.prototype = vm.heap.symbol_proto;
                                wrapper.extra_ptr().prim.primitive_value = *rb;
                            } else {
                                ra.set_undefined();
                                return (TVal){};
                            }
                            hobject::PropLookupResult res = wrapper.get_prop_or_accessor_proto(key_hstr, true);
                            if (res.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
                                TVal wrapper_tv;
                                wrapper_tv.set_object(wrapper);
                                if (invoke_getter(vm, &res.acc, &wrapper_tv, (uint)insn.a,
                                                  ds.act, &ds.curr_pc, &ds.needs_restart, ds.regs_base)) {
                                    ds.regs_base = ds.act.bottom;
                                    return (TVal){};
                                }
                                return (TVal){};
                            } else if (res.kind == hobject::PropLookupKind.PROP_DATA) {
                                vm.heap.tval_copy_ref(ra, &res.data_val);
                                track_heap_store(ds.act, ra, (uint)insn.a);
                            } else {
                                ra.set_undefined();
                            }
                        } else {
                            ra.set_undefined();
                        }
                    } else {
                        // Auto-box string primitive: constant string key — skip numeric-index fast path
                        if (key_hstr != null) {
                            // Fast path: .length → string character count
                            if ((void*)key_hstr == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH]) {
                                ra.set_fastint((long)h_str.char_length());
                                return (TVal){};
                            }
                            if (vm.heap.string_proto != null) {
                                TVal? result = vm.heap.string_proto.get_prop_proto((void*)key_hstr);
                                if (try v = result) {
                                    vm.heap.tval_copy_ref(ra, &v);
                                    track_heap_store(ds.act, ra, (uint)insn.a);
                                } else {
                                    ra.set_undefined();
                                }
                            } else {
                                ra.set_undefined();
                            }
                        } else {
                            ra.set_undefined();
                        }
                    }
                } else if (rb.is_number() || rb.is_fastint()) {
                    if (key_hstr != null && vm.heap.number_proto != null) {
                        TVal? result = vm.heap.number_proto.get_prop_proto((void*)key_hstr);
                        if (try v = result) {
                            vm.heap.tval_copy_ref(ra, &v);
                            track_heap_store(ds.act, ra, (uint)insn.a);
                        } else {
                            ra.set_undefined();
                        }
                    } else {
                        ra.set_undefined();
                    }
                } else if (rb.is_boolean()) {
                    if (key_hstr != null && vm.heap.bool_proto != null) {
                        TVal? result = vm.heap.bool_proto.get_prop_proto((void*)key_hstr);
                        if (try v = result) {
                            vm.heap.tval_copy_ref(ra, &v);
                            track_heap_store(ds.act, ra, (uint)insn.a);
                        } else {
                            ra.set_undefined();
                        }
                    } else {
                        ra.set_undefined();
                    }
                } else if (rb.is_lightfunc()) {
                    // LIGHTFUNC: resolve .name and .length from metadata, other props from Function.prototype
                    uint fn_idx = (uint)(usz)rb.get_heapptr();
                    if (key_hstr != null) {
                        if (key_hstr.equals("name")) {
                            if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], fn_idx, 0)) {
                                builtins::BuiltinMeta meta = builtins::builtin_get_metadata(fn_idx);
                                if (meta.name.len > 0) {
                                    HString* name_str = intern_string(vm, meta.name);
                                    vm.heap.set_reg_string(ra, name_str);
                                } else { ra.set_undefined(); }
                            } else if (vm.heap.function_proto != null) {
                                TVal? result = vm.heap.function_proto.get_prop_proto((void*)key_hstr);
                                if (try v = result) { vm.heap.tval_copy_ref(ra, &v); track_heap_store(ds.act, ra, (uint)insn.a); }
                                else { ra.set_undefined(); }
                            } else { ra.set_undefined(); }
                        } else if (key_hstr.equals("length")) {
                            if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], fn_idx, 1)) {
                                builtins::BuiltinMeta meta = builtins::builtin_get_metadata(fn_idx);
                                if (meta.arity >= 0) {
                                    ra.set_number(meta.arity);
                                } else { ra.set_undefined(); }
                            } else if (vm.heap.function_proto != null) {
                                TVal? result = vm.heap.function_proto.get_prop_proto((void*)key_hstr);
                                if (try v = result) { vm.heap.tval_copy_ref(ra, &v); track_heap_store(ds.act, ra, (uint)insn.a); }
                                else { ra.set_undefined(); }
                            } else { ra.set_undefined(); }
                        } else if (key_hstr.equals("prototype")) {
                            if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], fn_idx, 2)) {
                                HObject* proto_obj = lightfunc_get_proto(vm, fn_idx);
                                if (proto_obj != null) {
                                    ra.set_object(proto_obj);
                                    track_heap_store(ds.act, ra, (uint)insn.a);
                                } else { ra.set_undefined(); }
                            } else if (vm.heap.function_proto != null) {
                                TVal? result = vm.heap.function_proto.get_prop_proto((void*)key_hstr);
                                if (try v = result) { vm.heap.tval_copy_ref(ra, &v); track_heap_store(ds.act, ra, (uint)insn.a); }
                                else { ra.set_undefined(); }
                            } else { ra.set_undefined(); }
                        } else if (key_hstr.equals("caller") || key_hstr.equals("arguments")) {
                            // ES5 strict mode: accessing .caller and .arguments throws TypeError
                            if (!vm_throw_error(vm, vm.heap.type_err_proto, "'caller' and 'arguments' properties may not be accessed on strict mode functions or the arguments objects for calls to them", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                return VM_ERROR~;
                            }
                        } else if (vm.heap.function_proto != null) {
                            // Walk Function.prototype for .call, .apply, .bind, etc.
                            TVal? result = vm.heap.function_proto.get_prop_proto((void*)key_hstr);
                            if (try v = result) {
                                vm.heap.tval_copy_ref(ra, &v);
                                track_heap_store(ds.act, ra, (uint)insn.a);
                            } else {
                                ra.set_undefined();
                            }
                        } else {
                            ra.set_undefined();
                        }
                    } else {
                        ra.set_undefined();
                    }
                } else {
                    ra.set_undefined();
                }
            }
            return (TVal){};

        case Opcode.GETPROPC_CACHED: {
            // Specialized GETPROPC: IC is known warm. Only checks shape_id + prop_alloc.
            // Falls back to GETPROPC if the check fails (shape changed or props reallocated).
            TVal key_tval = ds.constants[(uint)insn.c];
            HString* key_hstr = (HString*)key_tval.get_heapptr();
            if (rb.is_object() && ds.ic_base != null) {
                HObject* hobj = (HObject*)rb.get_heapptr();
                uint pc_off = (uint)(ds.curr_pc - 1 - ds.code_base);
                hobject::ICEntry* ic = ds.ic_base + pc_off;
                if (ic.shape_id == hobj.shape_id) {
                    HObject* ic_owner = ic.proto == null ? hobj : (HObject*)ic.proto;
                    if (ic.cached_prop_alloc == (void*)ic_owner.prop_values()) {
                        TVal ic_val = *ic.prop_value_ptr;
                        if (!ic_val.is_heap_allocated()) {
                            *ra = ic_val;
                        } else {
                            vm.heap.tval_copy_ref(ra, &ic_val);
                            track_heap_store(ds.act, ra, (uint)insn.a);
                        }
                        return (TVal){};
                    }
                }
            }
            // IC miss or ds.ic_base null: downgrade back to GETPROPC and re-execute
            ds.curr_pc[-1] = bytecode::make_abc(bytecode::Opcode.GETPROPC,
                                            (uint)insn.a, (uint)insn.b, (uint)insn.c);
            ds.curr_pc--;
            return (TVal){};
        }

        case Opcode.GETPROPC2: {
            // Fused two-hop property access. Executes GETPROPC twice in one dispatch.
            // Format: insn[i] = GETPROPC2 A=dst_temp, B=src, C=key1
            //         insn[i+1] = (data: A=dst_final, C=key2)
            // After execution, ds.curr_pc advances past insn[i+1] (skips the data slot).

            TVal key1_tval = ds.constants[(uint)insn.c];
            HString* key1_hstr = (HString*)key1_tval.get_heapptr();

            // Read second hop's destination and key from the next instruction slot
            Instruction next_insn = ds.curr_pc[0];  // ds.curr_pc has already advanced past insn
            uint dst2_reg = (uint)next_insn.a;
            TVal key2_tval = ds.constants[(uint)next_insn.c];
            HString* key2_hstr = (HString*)key2_tval.get_heapptr();

            // Advance ds.curr_pc past the data slot
            ds.curr_pc++;

            TVal* ra2 = ds.regs_base + dst2_reg;

            if (rb.is_object()) {
                HObject* hobj1 = (HObject*)rb.get_heapptr();
                uint pc1 = (uint)(ds.curr_pc - 2 - ds.code_base);  // pc of GETPROPC2

                // === Hop 1: hobj1[key1] ===
                TVal mid_val;
                mid_val.set_undefined();                if (ds.ic_base != null) {
                    hobject::ICEntry* ic1 = ds.ic_base + pc1;
                    if (ic1.key == (void*)key1_hstr && ic1.shape_id == hobj1.shape_id) {
                        HObject* owner1 = ic1.proto == null ? hobj1 : (HObject*)ic1.proto;
                        if (ic1.cached_prop_alloc == (void*)owner1.prop_values()) {
                            mid_val = *ic1.prop_value_ptr;
                        }
                    }
                }

                // Full lookup for hop 1 if IC miss
                if (mid_val.is_undefined() && key1_hstr != null) {
                    // ARRAY .length fast path
                    if (hobj1.get_class() == hobject::ObjClass.ARRAY
                        && (void*)key1_hstr == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH]) {
                        mid_val.set_fastint((long)*hobj1.array_len_ptr());
                    } else {
                        void* key1 = (void*)key1_hstr;
                        hobject::PropLookupResult r1 = hobj1.get_prop_or_accessor_proto(key1, true);
                        if (r1.kind == hobject::PropLookupKind.PROP_DATA) {
                            mid_val = r1.data_val;
                            // Populate IC1 — only cache OWN property lookups (see GETPROP).
                            if (r1.owner == hobj1 && r1.owner != null && ds.ic_base != null) {
                                hobject::ICEntry* ic1 = ds.ic_base + pc1;
                                int idx1 = r1.owner.find_prop_idx(key1);
                                if (idx1 >= 0) {
                                    ic1.shape_id = hobj1.shape_id;
                                    ic1.proto = null;  // own property
                                    ic1.prop_idx = (ushort)idx1;
                                    if (ic1.key != null) { vm.heap.decref((types::HeapHeader*)ic1.key); }
                                    ic1.key = key1;
                                    if (key1 != null) { ((types::HeapHeader*)key1).incref(); }
                                    ic1.prop_value_ptr = &r1.owner.prop_values()[idx1];
                                    ic1.cached_prop_alloc = (void*)r1.owner.prop_values();
                                }
                            }
                        } else if (r1.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
                            // Accessor on the first hop: invoke the getter
                            // synchronously via the reentrant call_fn path.
                            // (A frame-based invoke_getter would resume past
                            // the fused pair and skip hop 2 entirely.)
                            TVal getter1 = r1.acc.accessor_fn;
                            if (!getter1.is_undefined() && !getter1.is_null() && vm.heap.call_fn != null) {
                                TVal this_tv1;
                                this_tv1.set_object(hobj1);
                                mid_val = vm.heap.call_fn(vm, getter1, null, 0, this_tv1);
                                if (vm.heap.has_error) {
                                    vm.has_error = true;
                                    return VM_ERROR~;
                                }
                            } else {
                                mid_val.set_undefined();
                            }
                        }
                    }
                }

                // === Hop 2: mid_val[key2] ===
                if (mid_val.is_object()) {                    HObject* hobj2 = (HObject*)mid_val.get_heapptr();
                    uint pc2 = (uint)(ds.curr_pc - 1 - ds.code_base);  // pc of the data slot

                    // IC fast path for hop 2
                    if (ds.ic_base != null && key2_hstr != null) {
                        hobject::ICEntry* ic2 = ds.ic_base + pc2;
                        if (ic2.key == (void*)key2_hstr && ic2.shape_id == hobj2.shape_id) {
                            HObject* owner2 = ic2.proto == null ? hobj2 : (HObject*)ic2.proto;
                            if (ic2.cached_prop_alloc == (void*)owner2.prop_values()) {
                                TVal ic2_val = *ic2.prop_value_ptr;
                                if (!ic2_val.is_heap_allocated()) {
                                    *ra2 = ic2_val;
                                } else {
                                    vm.heap.tval_copy_ref(ra2, &ic2_val);
                                    track_heap_store(ds.act, ra2, dst2_reg);
                                }
                                // Also store the intermediate result in ra (temp register)
                                if (mid_val.is_heap_allocated()) {
                                    vm.heap.tval_copy_ref(ra, &mid_val);
                                    track_heap_store(ds.act, ra, (uint)insn.a);
                                } else {
                                    *ra = mid_val;
                                }
                                return (TVal){};
                            }
                        }
                    }

                    // Full lookup for hop 2 if IC miss
                    if (key2_hstr != null) {
                        // ARRAY .length fast path
                        if (hobj2.get_class() == hobject::ObjClass.ARRAY
                            && (void*)key2_hstr == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH]) {
                            ra2.set_fastint((long)*hobj2.array_len_ptr());
                        } else {
                            void* key2 = (void*)key2_hstr;
                            hobject::PropLookupResult r2 = hobj2.get_prop_or_accessor_proto(key2, true);
                            if (r2.kind == hobject::PropLookupKind.PROP_DATA) {
                                vm.heap.tval_copy_ref(ra2, &r2.data_val);
                                track_heap_store(ds.act, ra2, dst2_reg);
                                // Populate IC2 — only cache OWN property lookups (see GETPROP).
                                if (r2.owner == hobj2 && r2.owner != null && ds.ic_base != null) {
                                    hobject::ICEntry* ic2 = ds.ic_base + pc2;
                                    int idx2 = r2.owner.find_prop_idx(key2);
                                    if (idx2 >= 0) {
                                        ic2.shape_id = hobj2.shape_id;
                                        ic2.proto = null;  // own property
                                        ic2.prop_idx = (ushort)idx2;
                                        if (ic2.key != null) { vm.heap.decref((types::HeapHeader*)ic2.key); }
                                        ic2.key = key2;
                                        if (key2 != null) { ((types::HeapHeader*)key2).incref(); }
                                        ic2.prop_value_ptr = &r2.owner.prop_values()[idx2];
                                        ic2.cached_prop_alloc = (void*)r2.owner.prop_values();
                                    }
                                }
                            } else if (r2.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
                                // Accessor on the second hop: synchronous
                                // getter call with this = the hop-1 result.
                                TVal getter2 = r2.acc.accessor_fn;
                                if (!getter2.is_undefined() && !getter2.is_null() && vm.heap.call_fn != null) {
                                    TVal gv2 = vm.heap.call_fn(vm, getter2, null, 0, mid_val);
                                    if (vm.heap.has_error) {
                                        vm.has_error = true;
                                        return VM_ERROR~;
                                    }
                                    vm.heap.tval_copy_ref(ra2, &gv2);
                                    track_heap_store(ds.act, ra2, dst2_reg);
                                } else {
                                    ra2.set_undefined();
                                }
                            } else {
                                ra2.set_undefined();
                            }
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else if (mid_val.is_lightfunc()) {
                    // LIGHTFUNC intermediate: resolve .name/.length/.prototype from metadata,
                    // other props from Function.prototype (mirrors GETPROPC lightfunc handling).
                    uint lf_fn_idx = (uint)(usz)mid_val.get_heapptr();
                    if (key2_hstr != null) {
                        if (key2_hstr.equals("name")) {
                            if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], lf_fn_idx, 0)) {
                                builtins::BuiltinMeta lf_meta = builtins::builtin_get_metadata(lf_fn_idx);
                                if (lf_meta.name.len > 0) {
                                    HString* name_str = intern_string(vm, lf_meta.name);
                                    vm.heap.set_reg_string(ra2, name_str);
                                } else { ra2.set_undefined(); }
                            } else if (vm.heap.function_proto != null) {
                                TVal? r = vm.heap.function_proto.get_prop_proto((void*)key2_hstr);
                                if (try v = r) { vm.heap.tval_copy_ref(ra2, &v); track_heap_store(ds.act, ra2, dst2_reg); }
                                else { ra2.set_undefined(); }
                            } else { ra2.set_undefined(); }
                        } else if (key2_hstr.equals("length")) {
                            if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], lf_fn_idx, 1)) {
                                builtins::BuiltinMeta lf_meta = builtins::builtin_get_metadata(lf_fn_idx);
                                if (lf_meta.arity >= 0) {
                                    ra2.set_number(lf_meta.arity);
                                } else { ra2.set_undefined(); }
                            } else if (vm.heap.function_proto != null) {
                                TVal? r = vm.heap.function_proto.get_prop_proto((void*)key2_hstr);
                                if (try v = r) { vm.heap.tval_copy_ref(ra2, &v); track_heap_store(ds.act, ra2, dst2_reg); }
                                else { ra2.set_undefined(); }
                            } else { ra2.set_undefined(); }
                        } else if (key2_hstr.equals("prototype")) {
                            if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], lf_fn_idx, 2)) {
                                HObject* lf_proto = lightfunc_get_proto(vm, lf_fn_idx);
                                if (lf_proto != null) {
                                    ra2.set_object(lf_proto);
                                    track_heap_store(ds.act, ra2, dst2_reg);
                                } else { ra2.set_undefined(); }
                            } else if (vm.heap.function_proto != null) {
                                TVal? r = vm.heap.function_proto.get_prop_proto((void*)key2_hstr);
                                if (try v = r) { vm.heap.tval_copy_ref(ra2, &v); track_heap_store(ds.act, ra2, dst2_reg); }
                                else { ra2.set_undefined(); }
                            } else { ra2.set_undefined(); }
                        } else if (vm.heap.function_proto != null) {
                            TVal? r = vm.heap.function_proto.get_prop_proto((void*)key2_hstr);
                            if (try v = r) { vm.heap.tval_copy_ref(ra2, &v); track_heap_store(ds.act, ra2, dst2_reg); }
                            else { ra2.set_undefined(); }
                        } else { ra2.set_undefined(); }
                    } else {
                        ra2.set_undefined();
                    }
                } else if (mid_val.is_string()) {
                    // STRING intermediate: auto-box for hop 2 (mirrors GETPROPC string handling).
                    HString* mid_str = (HString*)mid_val.get_heapptr();
                    if (mid_str != null && mid_str.is_symbol() && vm.heap.symbol_proto != null) {
                        if (key2_hstr != null) {
                            TVal? result = vm.heap.symbol_proto.get_prop_proto((void*)key2_hstr);
                            if (try v = result) {
                                vm.heap.tval_copy_ref(ra2, &v);
                                track_heap_store(ds.act, ra2, dst2_reg);
                            } else {
                                ra2.set_undefined();
                            }
                        } else {
                            ra2.set_undefined();
                        }
                    } else if (key2_hstr != null) {
                        // .length fast path
                        if ((void*)key2_hstr == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH]) {
                            ra2.set_fastint((long)mid_str.char_length());
                        } else if (vm.heap.string_proto != null) {
                            TVal? result = vm.heap.string_proto.get_prop_proto((void*)key2_hstr);
                            if (try v = result) {
                                vm.heap.tval_copy_ref(ra2, &v);
                                track_heap_store(ds.act, ra2, dst2_reg);
                            } else {
                                ra2.set_undefined();
                            }
                        } else {
                            ra2.set_undefined();
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else if (mid_val.is_number() || mid_val.is_fastint()) {
                    // NUMBER intermediate: auto-box for hop 2.
                    if (key2_hstr != null && vm.heap.number_proto != null) {
                        TVal? result = vm.heap.number_proto.get_prop_proto((void*)key2_hstr);
                        if (try v = result) {
                            vm.heap.tval_copy_ref(ra2, &v);
                            track_heap_store(ds.act, ra2, dst2_reg);
                        } else {
                            ra2.set_undefined();
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else if (mid_val.is_boolean()) {
                    // BOOLEAN intermediate: auto-box for hop 2.
                    if (key2_hstr != null && vm.heap.bool_proto != null) {
                        TVal? result = vm.heap.bool_proto.get_prop_proto((void*)key2_hstr);
                        if (try v = result) {
                            vm.heap.tval_copy_ref(ra2, &v);
                            track_heap_store(ds.act, ra2, dst2_reg);
                        } else {
                            ra2.set_undefined();
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else {
                    ra2.set_undefined();
                }

                // Store intermediate result in ra (temp register)
                if (mid_val.is_heap_allocated()) {
                    vm.heap.tval_copy_ref(ra, &mid_val);
                    track_heap_store(ds.act, ra, (uint)insn.a);
                } else {
                    *ra = mid_val;
                }
            } else if (rb.is_string()) {
                // rb is a string primitive — auto-box for hop 1, then hop 2 on the result.
                TVal mid_val;
                mid_val.set_undefined();
                HString* rb_str = (HString*)rb.get_heapptr();
                if (rb_str != null && key1_hstr != null) {
                    if (rb_str.is_symbol() && vm.heap.symbol_proto != null) {
                        TVal? result = vm.heap.symbol_proto.get_prop_proto((void*)key1_hstr);
                        if (try v = result) { mid_val = v; }
                    } else {
                        if ((void*)key1_hstr == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH]) {
                            mid_val.set_fastint((long)rb_str.char_length());
                        } else if (vm.heap.string_proto != null) {
                            TVal? result = vm.heap.string_proto.get_prop_proto((void*)key1_hstr);
                            if (try v = result) { mid_val = v; }
                        }
                    }
                }

                // Hop 2: mid_val[key2] (simplified — no IC)
                if (mid_val.is_object()) {
                    HObject* hobj2 = (HObject*)mid_val.get_heapptr();
                    if (hobj2 != null && key2_hstr != null) {
                        if (hobj2.get_class() == hobject::ObjClass.ARRAY
                            && (void*)key2_hstr == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH]) {
                            ra2.set_fastint((long)*hobj2.array_len_ptr());
                        } else {
                            hobject::PropLookupResult r2 = hobj2.get_prop_or_accessor_proto((void*)key2_hstr, true);
                            if (r2.kind == hobject::PropLookupKind.PROP_DATA) {
                                vm.heap.tval_copy_ref(ra2, &r2.data_val);
                                track_heap_store(ds.act, ra2, dst2_reg);
                            } else {
                                ra2.set_undefined();
                            }
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else if (mid_val.is_lightfunc()) {
                    uint lf_fn_idx2 = (uint)(usz)mid_val.get_heapptr();
                    if (key2_hstr != null) {
                        if (key2_hstr.equals("name")) {
                            if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], lf_fn_idx2, 0)) {
                                builtins::BuiltinMeta lf_meta = builtins::builtin_get_metadata(lf_fn_idx2);
                                if (lf_meta.name.len > 0) {
                                    HString* name_str = intern_string(vm, lf_meta.name);
                                    vm.heap.set_reg_string(ra2, name_str);
                                } else { ra2.set_undefined(); }
                            } else if (vm.heap.function_proto != null) {
                                TVal? r = vm.heap.function_proto.get_prop_proto((void*)key2_hstr);
                                if (try v = r) { vm.heap.tval_copy_ref(ra2, &v); track_heap_store(ds.act, ra2, dst2_reg); }
                                else { ra2.set_undefined(); }
                            } else { ra2.set_undefined(); }
                        } else if (key2_hstr.equals("length")) {
                            if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], lf_fn_idx2, 1)) {
                                builtins::BuiltinMeta lf_meta = builtins::builtin_get_metadata(lf_fn_idx2);
                                if (lf_meta.arity >= 0) {
                                    ra2.set_number(lf_meta.arity);
                                } else { ra2.set_undefined(); }
                            } else if (vm.heap.function_proto != null) {
                                TVal? r = vm.heap.function_proto.get_prop_proto((void*)key2_hstr);
                                if (try v = r) { vm.heap.tval_copy_ref(ra2, &v); track_heap_store(ds.act, ra2, dst2_reg); }
                                else { ra2.set_undefined(); }
                            } else { ra2.set_undefined(); }
                        } else if (key2_hstr.equals("prototype")) {
                            if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], lf_fn_idx2, 2)) {
                                HObject* lf_proto = lightfunc_get_proto(vm, lf_fn_idx2);
                                if (lf_proto != null) {
                                    ra2.set_object(lf_proto);
                                    track_heap_store(ds.act, ra2, dst2_reg);
                                } else { ra2.set_undefined(); }
                            } else if (vm.heap.function_proto != null) {
                                TVal? r = vm.heap.function_proto.get_prop_proto((void*)key2_hstr);
                                if (try v = r) { vm.heap.tval_copy_ref(ra2, &v); track_heap_store(ds.act, ra2, dst2_reg); }
                                else { ra2.set_undefined(); }
                            } else { ra2.set_undefined(); }
                        } else if (vm.heap.function_proto != null) {
                            TVal? r = vm.heap.function_proto.get_prop_proto((void*)key2_hstr);
                            if (try v = r) { vm.heap.tval_copy_ref(ra2, &v); track_heap_store(ds.act, ra2, dst2_reg); }
                            else { ra2.set_undefined(); }
                        } else { ra2.set_undefined(); }
                    } else {
                        ra2.set_undefined();
                    }
                } else if (mid_val.is_string()) {
                    HString* mid_str = (HString*)mid_val.get_heapptr();
                    if (mid_str != null && key2_hstr != null) {
                        // Always check for "length" by string content, not just
                        // by pointer identity — the constant pool may have a
                        // different HString instance for "length" than the
                        // BuiltinStr.LENGTH sentinel. Same pattern as in GETPROPC.
                        bool key2_is_length = (key2_hstr == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH])
                            || key2_hstr.equals("length");
                        if (key2_is_length) {
                            ra2.set_fastint((long)mid_str.char_length());
                        } else if (mid_str.is_symbol() && vm.heap.symbol_proto != null) {
                            TVal? result = vm.heap.symbol_proto.get_prop_proto((void*)key2_hstr);
                            if (try v = result) {
                                vm.heap.tval_copy_ref(ra2, &v);
                                track_heap_store(ds.act, ra2, dst2_reg);
                            } else {
                                ra2.set_undefined();
                            }
                        } else if (vm.heap.string_proto != null) {
                            TVal? result = vm.heap.string_proto.get_prop_proto((void*)key2_hstr);
                            if (try v = result) {
                                vm.heap.tval_copy_ref(ra2, &v);
                                track_heap_store(ds.act, ra2, dst2_reg);
                            } else {
                                ra2.set_undefined();
                            }
                        } else {
                            ra2.set_undefined();
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else if (mid_val.is_number() || mid_val.is_fastint()) {
                    if (key2_hstr != null && vm.heap.number_proto != null) {
                        TVal? result = vm.heap.number_proto.get_prop_proto((void*)key2_hstr);
                        if (try v = result) {
                            vm.heap.tval_copy_ref(ra2, &v);
                            track_heap_store(ds.act, ra2, dst2_reg);
                        } else {
                            ra2.set_undefined();
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else if (mid_val.is_boolean()) {
                    if (key2_hstr != null && vm.heap.bool_proto != null) {
                        TVal? result = vm.heap.bool_proto.get_prop_proto((void*)key2_hstr);
                        if (try v = result) {
                            vm.heap.tval_copy_ref(ra2, &v);
                            track_heap_store(ds.act, ra2, dst2_reg);
                        } else {
                            ra2.set_undefined();
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else {
                    ra2.set_undefined();
                }

                // Store mid_val in ra
                if (mid_val.is_heap_allocated()) {
                    vm.heap.tval_copy_ref(ra, &mid_val);
                    track_heap_store(ds.act, ra, (uint)insn.a);
                } else {
                    *ra = mid_val;
                }
            } else if (rb.is_lightfunc()) {
                // LIGHTFUNC source for hop 1: resolve .name/.length/.prototype from
                // metadata, other props from Function.prototype. Mirrors the
                // non-fused GETPROP lightfunc handling so chained accesses like
                // `URIError.prototype.constructor` work (session 219 B16 fix).
                TVal mid_val;
                mid_val.set_undefined();
                uint lf_fn_idx = (uint)(usz)rb.get_heapptr();
                if (key1_hstr != null) {
                    if (key1_hstr.equals("name")) {
                        if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], lf_fn_idx, 0)) {
                            builtins::BuiltinMeta lf_meta = builtins::builtin_get_metadata(lf_fn_idx);
                            if (lf_meta.name.len > 0) {
                                HString* name_str = intern_string(vm, lf_meta.name);
                                vm.heap.set_reg_string(ra, name_str);
                                mid_val.set_string(name_str);
                            } else { ra.set_undefined(); }
                        } else if (vm.heap.function_proto != null) {
                            TVal? r = vm.heap.function_proto.get_prop_proto((void*)key1_hstr);
                            if (try v = r) { vm.heap.tval_copy_ref(ra, &v); track_heap_store(ds.act, ra, (uint)insn.a); mid_val = v; }
                            else { ra.set_undefined(); }
                        } else { ra.set_undefined(); }
                    } else if (key1_hstr.equals("length")) {
                        if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], lf_fn_idx, 1)) {
                            builtins::BuiltinMeta lf_meta = builtins::builtin_get_metadata(lf_fn_idx);
                            if (lf_meta.arity >= 0) {
                                ra.set_number(lf_meta.arity);
                                mid_val.set_number(lf_meta.arity);
                            } else { ra.set_undefined(); }
                        } else if (vm.heap.function_proto != null) {
                            TVal? r = vm.heap.function_proto.get_prop_proto((void*)key1_hstr);
                            if (try v = r) { vm.heap.tval_copy_ref(ra, &v); track_heap_store(ds.act, ra, (uint)insn.a); mid_val = v; }
                            else { ra.set_undefined(); }
                        } else { ra.set_undefined(); }
                    } else if (key1_hstr.equals("prototype")) {
                        if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], lf_fn_idx, 2)) {
                            HObject* lf_proto = lightfunc_get_proto(vm, lf_fn_idx);
                            if (lf_proto != null) {
                                ra.set_object(lf_proto);
                                track_heap_store(ds.act, ra, (uint)insn.a);
                                mid_val.set_object(lf_proto);
                            } else { ra.set_undefined(); }
                        } else if (vm.heap.function_proto != null) {
                            TVal? r = vm.heap.function_proto.get_prop_proto((void*)key1_hstr);
                            if (try v = r) { vm.heap.tval_copy_ref(ra, &v); track_heap_store(ds.act, ra, (uint)insn.a); mid_val = v; }
                            else { ra.set_undefined(); }
                        } else { ra.set_undefined(); }
                    } else if (vm.heap.function_proto != null) {
                        TVal? r = vm.heap.function_proto.get_prop_proto((void*)key1_hstr);
                        if (try v = r) { vm.heap.tval_copy_ref(ra, &v); track_heap_store(ds.act, ra, (uint)insn.a); mid_val = v; }
                        else { ra.set_undefined(); }
                    } else { ra.set_undefined(); }
                } else { ra.set_undefined(); }

                // === Hop 2: mid_val[key2] (full dispatch, same as object-source path) ===
                if (mid_val.is_object()) {
                    HObject* hobj2 = (HObject*)mid_val.get_heapptr();
                    uint pc2 = (uint)(ds.curr_pc - 1 - ds.code_base);  // pc of the data slot

                    // IC fast path for hop 2
                    if (ds.ic_base != null && key2_hstr != null) {
                        hobject::ICEntry* ic2 = ds.ic_base + pc2;
                        if (ic2.key == (void*)key2_hstr && ic2.shape_id == hobj2.shape_id) {
                            HObject* owner2 = ic2.proto == null ? hobj2 : (HObject*)ic2.proto;
                            if (ic2.cached_prop_alloc == (void*)owner2.prop_values()) {
                                TVal ic2_val = *ic2.prop_value_ptr;
                                if (!ic2_val.is_heap_allocated()) {
                                    *ra2 = ic2_val;
                                } else {
                                    vm.heap.tval_copy_ref(ra2, &ic2_val);
                                    track_heap_store(ds.act, ra2, dst2_reg);
                                }
                                // Also store the intermediate result in ra (temp register)
                                if (mid_val.is_heap_allocated()) {
                                    vm.heap.tval_copy_ref(ra, &mid_val);
                                    track_heap_store(ds.act, ra, (uint)insn.a);
                                } else {
                                    *ra = mid_val;
                                }
                                return (TVal){};
                            }
                        }
                    }

                    // Full lookup for hop 2 if IC miss
                    if (key2_hstr != null) {
                        // ARRAY .length fast path
                        if (hobj2.get_class() == hobject::ObjClass.ARRAY
                            && (void*)key2_hstr == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH]) {
                            ra2.set_fastint((long)*hobj2.array_len_ptr());
                        } else {
                            void* key2 = (void*)key2_hstr;
                            hobject::PropLookupResult r2 = hobj2.get_prop_or_accessor_proto(key2, true);
                            if (r2.kind == hobject::PropLookupKind.PROP_DATA) {
                                vm.heap.tval_copy_ref(ra2, &r2.data_val);
                                track_heap_store(ds.act, ra2, dst2_reg);
                                // Populate IC2 — only cache OWN property lookups (see GETPROP).
                                if (r2.owner == hobj2 && r2.owner != null && ds.ic_base != null) {
                                    hobject::ICEntry* ic2 = ds.ic_base + pc2;
                                    int idx2 = r2.owner.find_prop_idx(key2);
                                    if (idx2 >= 0) {
                                        ic2.shape_id = hobj2.shape_id;
                                        ic2.proto = null;  // own property
                                        ic2.prop_idx = (ushort)idx2;
                                        if (ic2.key != null) { vm.heap.decref((types::HeapHeader*)ic2.key); }
                                        ic2.key = key2;
                                        if (key2 != null) { ((types::HeapHeader*)key2).incref(); }
                                        ic2.prop_value_ptr = &r2.owner.prop_values()[idx2];
                                        ic2.cached_prop_alloc = (void*)r2.owner.prop_values();
                                    }
                                }
                            } else if (r2.kind == hobject::PropLookupKind.PROP_ACCESSOR) {
                                // Accessor on the second hop: synchronous
                                // getter call with this = the hop-1 result.
                                TVal getter2 = r2.acc.accessor_fn;
                                if (!getter2.is_undefined() && !getter2.is_null() && vm.heap.call_fn != null) {
                                    TVal gv2 = vm.heap.call_fn(vm, getter2, null, 0, mid_val);
                                    if (vm.heap.has_error) {
                                        vm.has_error = true;
                                        return VM_ERROR~;
                                    }
                                    vm.heap.tval_copy_ref(ra2, &gv2);
                                    track_heap_store(ds.act, ra2, dst2_reg);
                                } else {
                                    ra2.set_undefined();
                                }
                            } else {
                                ra2.set_undefined();
                            }
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else if (mid_val.is_lightfunc()) {
                    // LIGHTFUNC intermediate: resolve .name/.length/.prototype from metadata,
                    // other props from Function.prototype (mirrors GETPROPC lightfunc handling).
                    uint lf_fn_idx2 = (uint)(usz)mid_val.get_heapptr();
                    if (key2_hstr != null) {
                        if (key2_hstr.equals("name")) {
                            if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], lf_fn_idx2, 0)) {
                                builtins::BuiltinMeta lf_meta = builtins::builtin_get_metadata(lf_fn_idx2);
                                if (lf_meta.name.len > 0) {
                                    HString* name_str = intern_string(vm, lf_meta.name);
                                    vm.heap.set_reg_string(ra2, name_str);
                                } else { ra2.set_undefined(); }
                            } else if (vm.heap.function_proto != null) {
                                TVal? r = vm.heap.function_proto.get_prop_proto((void*)key2_hstr);
                                if (try v = r) { vm.heap.tval_copy_ref(ra2, &v); track_heap_store(ds.act, ra2, dst2_reg); }
                                else { ra2.set_undefined(); }
                            } else { ra2.set_undefined(); }
                        } else if (key2_hstr.equals("length")) {
                            if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], lf_fn_idx2, 1)) {
                                builtins::BuiltinMeta lf_meta = builtins::builtin_get_metadata(lf_fn_idx2);
                                if (lf_meta.arity >= 0) {
                                    ra2.set_number(lf_meta.arity);
                                } else { ra2.set_undefined(); }
                            } else if (vm.heap.function_proto != null) {
                                TVal? r = vm.heap.function_proto.get_prop_proto((void*)key2_hstr);
                                if (try v = r) { vm.heap.tval_copy_ref(ra2, &v); track_heap_store(ds.act, ra2, dst2_reg); }
                                else { ra2.set_undefined(); }
                            } else { ra2.set_undefined(); }
                        } else if (key2_hstr.equals("prototype")) {
                            if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], lf_fn_idx2, 2)) {
                                HObject* lf_proto = lightfunc_get_proto(vm, lf_fn_idx2);
                                if (lf_proto != null) {
                                    ra2.set_object(lf_proto);
                                    track_heap_store(ds.act, ra2, dst2_reg);
                                } else { ra2.set_undefined(); }
                            } else if (vm.heap.function_proto != null) {
                                TVal? r = vm.heap.function_proto.get_prop_proto((void*)key2_hstr);
                                if (try v = r) { vm.heap.tval_copy_ref(ra2, &v); track_heap_store(ds.act, ra2, dst2_reg); }
                                else { ra2.set_undefined(); }
                            } else { ra2.set_undefined(); }
                        } else if (vm.heap.function_proto != null) {
                            TVal? r = vm.heap.function_proto.get_prop_proto((void*)key2_hstr);
                            if (try v = r) { vm.heap.tval_copy_ref(ra2, &v); track_heap_store(ds.act, ra2, dst2_reg); }
                            else { ra2.set_undefined(); }
                        } else { ra2.set_undefined(); }
                    } else {
                        ra2.set_undefined();
                    }
                } else if (mid_val.is_string()) {
                    // STRING intermediate: auto-box for hop 2 (mirrors GETPROPC string handling).
                    HString* mid_str = (HString*)mid_val.get_heapptr();
                    if (mid_str != null && mid_str.is_symbol() && vm.heap.symbol_proto != null) {
                        if (key2_hstr != null) {
                            TVal? result = vm.heap.symbol_proto.get_prop_proto((void*)key2_hstr);
                            if (try v = result) {
                                vm.heap.tval_copy_ref(ra2, &v);
                                track_heap_store(ds.act, ra2, dst2_reg);
                            } else {
                                ra2.set_undefined();
                            }
                        } else {
                            ra2.set_undefined();
                        }
                    } else if (key2_hstr != null) {
                        // .length fast path — check by content, not just pointer identity.
                        bool key2_is_length = ((void*)key2_hstr == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH])
                            || key2_hstr.equals("length");
                        if (key2_is_length) {
                            ra2.set_fastint((long)mid_str.char_length());
                        } else if (vm.heap.string_proto != null) {
                            TVal? result = vm.heap.string_proto.get_prop_proto((void*)key2_hstr);
                            if (try v = result) {
                                vm.heap.tval_copy_ref(ra2, &v);
                                track_heap_store(ds.act, ra2, dst2_reg);
                            } else {
                                ra2.set_undefined();
                            }
                        } else {
                            ra2.set_undefined();
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else if (mid_val.is_number() || mid_val.is_fastint()) {
                    // NUMBER intermediate: auto-box for hop 2.
                    if (key2_hstr != null && vm.heap.number_proto != null) {
                        TVal? result = vm.heap.number_proto.get_prop_proto((void*)key2_hstr);
                        if (try v = result) {
                            vm.heap.tval_copy_ref(ra2, &v);
                            track_heap_store(ds.act, ra2, dst2_reg);
                        } else {
                            ra2.set_undefined();
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else if (mid_val.is_boolean()) {
                    // BOOLEAN intermediate: auto-box for hop 2.
                    if (key2_hstr != null && vm.heap.bool_proto != null) {
                        TVal? result = vm.heap.bool_proto.get_prop_proto((void*)key2_hstr);
                        if (try v = result) {
                            vm.heap.tval_copy_ref(ra2, &v);
                            track_heap_store(ds.act, ra2, dst2_reg);
                        } else {
                            ra2.set_undefined();
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else {
                    ra2.set_undefined();
                }

                // Store intermediate result in ra (temp register)
                if (mid_val.is_heap_allocated()) {
                    vm.heap.tval_copy_ref(ra, &mid_val);
                    track_heap_store(ds.act, ra, (uint)insn.a);
                } else {
                    *ra = mid_val;
                }
            } else if (rb.is_number() || rb.is_fastint()) {
                // NUMBER source: auto-box via Number.prototype for hop 1.
                TVal mid_val;
                mid_val.set_undefined();
                if (key1_hstr != null && vm.heap.number_proto != null) {
                    TVal? result = vm.heap.number_proto.get_prop_proto((void*)key1_hstr);
                    if (try v = result) { mid_val = v; }
                }

                // Common hop 2 dispatch (simplified, no IC — same pattern as string source).
                if (mid_val.is_object()) {
                    HObject* hobj2 = (HObject*)mid_val.get_heapptr();
                    if (hobj2 != null && key2_hstr != null) {
                        if (hobj2.get_class() == hobject::ObjClass.ARRAY
                            && (void*)key2_hstr == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH]) {
                            ra2.set_fastint((long)*hobj2.array_len_ptr());
                        } else {
                            hobject::PropLookupResult r2 = hobj2.get_prop_or_accessor_proto((void*)key2_hstr, true);
                            if (r2.kind == hobject::PropLookupKind.PROP_DATA) {
                                vm.heap.tval_copy_ref(ra2, &r2.data_val);
                                track_heap_store(ds.act, ra2, dst2_reg);
                            } else {
                                ra2.set_undefined();
                            }
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else if (mid_val.is_lightfunc()) {
                    uint lf_fn_idx2 = (uint)(usz)mid_val.get_heapptr();
                    if (key2_hstr != null) {
                        if (key2_hstr.equals("name")) {
                            if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], lf_fn_idx2, 0)) {
                                builtins::BuiltinMeta lf_meta = builtins::builtin_get_metadata(lf_fn_idx2);
                                if (lf_meta.name.len > 0) {
                                    HString* name_str = intern_string(vm, lf_meta.name);
                                    vm.heap.set_reg_string(ra2, name_str);
                                } else { ra2.set_undefined(); }
                            } else if (vm.heap.function_proto != null) {
                                TVal? r = vm.heap.function_proto.get_prop_proto((void*)key2_hstr);
                                if (try v = r) { vm.heap.tval_copy_ref(ra2, &v); track_heap_store(ds.act, ra2, dst2_reg); }
                                else { ra2.set_undefined(); }
                            } else { ra2.set_undefined(); }
                        } else if (key2_hstr.equals("length")) {
                            if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], lf_fn_idx2, 1)) {
                                builtins::BuiltinMeta lf_meta = builtins::builtin_get_metadata(lf_fn_idx2);
                                if (lf_meta.arity >= 0) {
                                    ra2.set_number(lf_meta.arity);
                                } else { ra2.set_undefined(); }
                            } else if (vm.heap.function_proto != null) {
                                TVal? r = vm.heap.function_proto.get_prop_proto((void*)key2_hstr);
                                if (try v = r) { vm.heap.tval_copy_ref(ra2, &v); track_heap_store(ds.act, ra2, dst2_reg); }
                                else { ra2.set_undefined(); }
                            } else { ra2.set_undefined(); }
                        } else if (key2_hstr.equals("prototype")) {
                            if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], lf_fn_idx2, 2)) {
                                HObject* lf_proto = lightfunc_get_proto(vm, lf_fn_idx2);
                                if (lf_proto != null) {
                                    ra2.set_object(lf_proto);
                                    track_heap_store(ds.act, ra2, dst2_reg);
                                } else { ra2.set_undefined(); }
                            } else if (vm.heap.function_proto != null) {
                                TVal? r = vm.heap.function_proto.get_prop_proto((void*)key2_hstr);
                                if (try v = r) { vm.heap.tval_copy_ref(ra2, &v); track_heap_store(ds.act, ra2, dst2_reg); }
                                else { ra2.set_undefined(); }
                            } else { ra2.set_undefined(); }
                        } else if (vm.heap.function_proto != null) {
                            TVal? r = vm.heap.function_proto.get_prop_proto((void*)key2_hstr);
                            if (try v = r) { vm.heap.tval_copy_ref(ra2, &v); track_heap_store(ds.act, ra2, dst2_reg); }
                            else { ra2.set_undefined(); }
                        } else { ra2.set_undefined(); }
                    } else {
                        ra2.set_undefined();
                    }
                } else if (mid_val.is_string()) {
                    HString* mid_str = (HString*)mid_val.get_heapptr();
                    if (mid_str != null && key2_hstr != null) {
                        bool key2_is_length = ((void*)key2_hstr == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH])
                            || key2_hstr.equals("length");
                        if (key2_is_length) {
                            ra2.set_fastint((long)mid_str.char_length());
                        } else if (vm.heap.string_proto != null) {
                            TVal? result = vm.heap.string_proto.get_prop_proto((void*)key2_hstr);
                            if (try v = result) {
                                vm.heap.tval_copy_ref(ra2, &v);
                                track_heap_store(ds.act, ra2, dst2_reg);
                            } else {
                                ra2.set_undefined();
                            }
                        } else {
                            ra2.set_undefined();
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else if (mid_val.is_number() || mid_val.is_fastint()) {
                    if (key2_hstr != null && vm.heap.number_proto != null) {
                        TVal? result = vm.heap.number_proto.get_prop_proto((void*)key2_hstr);
                        if (try v = result) {
                            vm.heap.tval_copy_ref(ra2, &v);
                            track_heap_store(ds.act, ra2, dst2_reg);
                        } else {
                            ra2.set_undefined();
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else if (mid_val.is_boolean()) {
                    if (key2_hstr != null && vm.heap.bool_proto != null) {
                        TVal? result = vm.heap.bool_proto.get_prop_proto((void*)key2_hstr);
                        if (try v = result) {
                            vm.heap.tval_copy_ref(ra2, &v);
                            track_heap_store(ds.act, ra2, dst2_reg);
                        } else {
                            ra2.set_undefined();
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else {
                    ra2.set_undefined();
                }

                // Store mid_val in ra
                if (mid_val.is_heap_allocated()) {
                    vm.heap.tval_copy_ref(ra, &mid_val);
                    track_heap_store(ds.act, ra, (uint)insn.a);
                } else {
                    *ra = mid_val;
                }
            } else if (rb.is_boolean()) {
                // BOOLEAN source: auto-box via Boolean.prototype for hop 1.
                TVal mid_val;
                mid_val.set_undefined();
                if (key1_hstr != null && vm.heap.bool_proto != null) {
                    TVal? result = vm.heap.bool_proto.get_prop_proto((void*)key1_hstr);
                    if (try v = result) { mid_val = v; }
                }

                // Common hop 2 dispatch (simplified, no IC — same pattern as string source).
                if (mid_val.is_object()) {
                    HObject* hobj2 = (HObject*)mid_val.get_heapptr();
                    if (hobj2 != null && key2_hstr != null) {
                        if (hobj2.get_class() == hobject::ObjClass.ARRAY
                            && (void*)key2_hstr == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH]) {
                            ra2.set_fastint((long)*hobj2.array_len_ptr());
                        } else {
                            hobject::PropLookupResult r2 = hobj2.get_prop_or_accessor_proto((void*)key2_hstr, true);
                            if (r2.kind == hobject::PropLookupKind.PROP_DATA) {
                                vm.heap.tval_copy_ref(ra2, &r2.data_val);
                                track_heap_store(ds.act, ra2, dst2_reg);
                            } else {
                                ra2.set_undefined();
                            }
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else if (mid_val.is_lightfunc()) {
                    uint lf_fn_idx2 = (uint)(usz)mid_val.get_heapptr();
                    if (key2_hstr != null) {
                        if (key2_hstr.equals("name")) {
                            if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], lf_fn_idx2, 0)) {
                                builtins::BuiltinMeta lf_meta = builtins::builtin_get_metadata(lf_fn_idx2);
                                if (lf_meta.name.len > 0) {
                                    HString* name_str = intern_string(vm, lf_meta.name);
                                    vm.heap.set_reg_string(ra2, name_str);
                                } else { ra2.set_undefined(); }
                            } else if (vm.heap.function_proto != null) {
                                TVal? r = vm.heap.function_proto.get_prop_proto((void*)key2_hstr);
                                if (try v = r) { vm.heap.tval_copy_ref(ra2, &v); track_heap_store(ds.act, ra2, dst2_reg); }
                                else { ra2.set_undefined(); }
                            } else { ra2.set_undefined(); }
                        } else if (key2_hstr.equals("length")) {
                            if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], lf_fn_idx2, 1)) {
                                builtins::BuiltinMeta lf_meta = builtins::builtin_get_metadata(lf_fn_idx2);
                                if (lf_meta.arity >= 0) {
                                    ra2.set_number(lf_meta.arity);
                                } else { ra2.set_undefined(); }
                            } else if (vm.heap.function_proto != null) {
                                TVal? r = vm.heap.function_proto.get_prop_proto((void*)key2_hstr);
                                if (try v = r) { vm.heap.tval_copy_ref(ra2, &v); track_heap_store(ds.act, ra2, dst2_reg); }
                                else { ra2.set_undefined(); }
                            } else { ra2.set_undefined(); }
                        } else if (key2_hstr.equals("prototype")) {
                            if (!heap::lf_is_deleted(&vm.heap.lf_deleted_props[0], lf_fn_idx2, 2)) {
                                HObject* lf_proto = lightfunc_get_proto(vm, lf_fn_idx2);
                                if (lf_proto != null) {
                                    ra2.set_object(lf_proto);
                                    track_heap_store(ds.act, ra2, dst2_reg);
                                } else { ra2.set_undefined(); }
                            } else if (vm.heap.function_proto != null) {
                                TVal? r = vm.heap.function_proto.get_prop_proto((void*)key2_hstr);
                                if (try v = r) { vm.heap.tval_copy_ref(ra2, &v); track_heap_store(ds.act, ra2, dst2_reg); }
                                else { ra2.set_undefined(); }
                            } else { ra2.set_undefined(); }
                        } else if (vm.heap.function_proto != null) {
                            TVal? r = vm.heap.function_proto.get_prop_proto((void*)key2_hstr);
                            if (try v = r) { vm.heap.tval_copy_ref(ra2, &v); track_heap_store(ds.act, ra2, dst2_reg); }
                            else { ra2.set_undefined(); }
                        } else { ra2.set_undefined(); }
                    } else {
                        ra2.set_undefined();
                    }
                } else if (mid_val.is_string()) {
                    HString* mid_str = (HString*)mid_val.get_heapptr();
                    if (mid_str != null && key2_hstr != null) {
                        bool key2_is_length = ((void*)key2_hstr == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH])
                            || key2_hstr.equals("length");
                        if (key2_is_length) {
                            ra2.set_fastint((long)mid_str.char_length());
                        } else if (vm.heap.string_proto != null) {
                            TVal? result = vm.heap.string_proto.get_prop_proto((void*)key2_hstr);
                            if (try v = result) {
                                vm.heap.tval_copy_ref(ra2, &v);
                                track_heap_store(ds.act, ra2, dst2_reg);
                            } else {
                                ra2.set_undefined();
                            }
                        } else {
                            ra2.set_undefined();
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else if (mid_val.is_number() || mid_val.is_fastint()) {
                    if (key2_hstr != null && vm.heap.number_proto != null) {
                        TVal? result = vm.heap.number_proto.get_prop_proto((void*)key2_hstr);
                        if (try v = result) {
                            vm.heap.tval_copy_ref(ra2, &v);
                            track_heap_store(ds.act, ra2, dst2_reg);
                        } else {
                            ra2.set_undefined();
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else if (mid_val.is_boolean()) {
                    if (key2_hstr != null && vm.heap.bool_proto != null) {
                        TVal? result = vm.heap.bool_proto.get_prop_proto((void*)key2_hstr);
                        if (try v = result) {
                            vm.heap.tval_copy_ref(ra2, &v);
                            track_heap_store(ds.act, ra2, dst2_reg);
                        } else {
                            ra2.set_undefined();
                        }
                    } else {
                        ra2.set_undefined();
                    }
                } else {
                    ra2.set_undefined();
                }

                // Store mid_val in ra
                if (mid_val.is_heap_allocated()) {
                    vm.heap.tval_copy_ref(ra, &mid_val);
                    track_heap_store(ds.act, ra, (uint)insn.a);
                } else {
                    *ra = mid_val;
                }
            } else {
                // rb is not a recognised type — both hops fail
                ra.set_undefined();
                ra2.set_undefined();
            }
            return (TVal){};
        }

        case Opcode.PUTPROP:
            if (ra.is_object()) {
                HObject* hobj = (HObject*)ra.get_heapptr();

                // Fast path: dense array indexed store (a[i] = v where i is a valid array index)
                // ES5 §15.4: array index P satisfies ToString(ToUint32(P))===P && ToUint32(P)≠2^32−1
                // Cap at 2^24 to avoid insane allocations for sparse arrays with huge indices.
                // Guard with array_part() != null — after seal/freeze the array part is
                // abandoned and elements live as named properties with proper flags.
                if ((hobj.get_class() == hobject::ObjClass.ARRAY || hobj.get_class() == hobject::ObjClass.ARGUMENTS)
                    && hobj.array_part() != null
                    && (rb.is_fastint() || rb.is_number())) {
                    long idx_long = rb.is_fastint() ? rb.get_fastint() : (long)rb.get_number();
                    if (idx_long >= 0 && idx_long < 0xFFFFFFFFL && idx_long < 0x1000000L) {
                        uint idx = (uint)idx_long;
                        if (hobj.set_array_idx(idx, *rc)) {
                            // Update .length fast: use array_length field directly (ARRAY only)
                            if (hobj.get_class() == hobject::ObjClass.ARRAY && idx >= *hobj.array_len_ptr()) {
                                *hobj.array_len_ptr() = idx + 1;
                            }
                            return (TVal){};
                        }
                        // Dense write failed (index beyond capacity cap) — fall through to put_prop.
                    }
                }

                // Inline Cache fast path for own property writes (string keys only)
                if (ds.ic_base != null && rb.is_string()) {
                    uint pc_off = (uint)(ds.curr_pc - 1 - ds.code_base);
                    hobject::ICEntry* ic = ds.ic_base + pc_off;
                    void* wkey = rb.get_heapptr();
                    if (wkey != null && ic.key == wkey && ic.shape_id == hobj.shape_id && ic.proto == null) {
                        if (ic.cached_prop_alloc == (void*)hobj.prop_values()
                            && !ic.prop_flags.is_accessor
                            && ic.prop_flags.writable) {
                            vm.heap.tval_copy_ref(ic.prop_value_ptr, rc);
                            return (TVal){};
                        }
                    }
                }

                // ARRAY exotic: .length write fast path — update array_length directly
                if (hobj.get_class() == hobject::ObjClass.ARRAY && rb.is_string() && rb.get_heapptr() == (void*)vm.heap.strs[heap::BuiltinStr.LENGTH]) {
                    // ES5 §15.4.5.1 step 2 (ArraySetLength): validate the new length value
                    // before truncating. ToUint32(v) must equal ToNumber(v), and the result
                    // must be < 2^32. Otherwise throw RangeError.
                    bool length_valid = true;
                    uint new_len = 0;
                    if (rc.is_undefined()) {
                        // Step 2a: undefined value throws TypeError
                        length_valid = true; // signal to throw TypeError below
                        new_len = 0;
                    } else if (rc.is_fastint()) {
                        long v = rc.get_fastint();
                        if (v < 0L || v > 0xFFFFFFFFL) {
                            length_valid = false;
                        } else {
                            new_len = (uint)v;
                        }
                    } else if (rc.is_number()) {
                        double raw = rc.get_number();
                        // NaN, ±Infinity, or non-integer, or negative, or > 2^32-1
                        if (raw != raw || raw < 0.0 || raw > 4294967295.0 || raw != math::floor(raw)) {
                            length_valid = false;
                        } else {
                            new_len = (uint)raw;
                        }
                    } else {
                        // For non-numeric values, fall through to slow path (Put → DefineOwnProperty)
                        // so the regular [[Set]] machinery handles coercion.
                        // We can't throw from here without breaking object property writes.
                        length_valid = true;
                        new_len = 0; // placeholder, will be overwritten by put_prop
                    }
                    if (!length_valid) {
                        if (!vm_throw_error(vm, vm.heap.range_err_proto, "Invalid array length", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return VM_ERROR~;
                        }
                        return (TVal){};
                    }
                    if (rc.is_undefined()) {
                        // TypeError: undefined is not a valid length
                        if (!vm_throw_error(vm, vm.heap.type_err_proto, "Invalid array length: undefined", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return VM_ERROR~;
                        }
                        return (TVal){};
                    }
                    // Only update if the value is a valid number (skip if fell through)
                    if (rc.is_fastint() || rc.is_number()) {
                        // Use the array helper so shrinking length deletes stale
                        // dense slots and named properties.
                        builtins::array_set_length(hobj, new_len, vm.heap);
                    }
                    return (TVal){};
                }

                void* key = get_prop_key(vm, rb);
                if (key != null) {
                    // Save the value before ensure_valstack may reallocate
                    TVal put_val = *rc;

                    // Single find_prop_idx call for both existence check and accessor check
                    int exist_idx = hobj.find_prop_idx(key);
                    if (exist_idx >= 0) {
                        TVal* entry = &hobj.prop_values()[exist_idx];
                        hobject::PropFlags exist_flags = hobj.get_prop_flags((uint)exist_idx);
                        if (exist_flags.is_accessor) {
                            // Accessor property — invoke setter
                            TVal setter_fn = hobject::hobject_access_setter(*entry);
                            if (setter_fn.is_object() && setter_fn.get_heapptr() != null) {
                                HObject* setter_obj = (HObject*)setter_fn.get_heapptr();
                                if (setter_obj.is_callable() && (*setter_obj.extra_ptr()).func.comp_func != null) {
                                    CompiledFunction* target = (*setter_obj.extra_ptr()).func.comp_func;
                                    // Stage the call frame above the caller's live registers:
                                    // PUTPROP's A/B/C are arbitrary live locals, so A+1.. cannot
                                    // be used as scratch (unlike GETPROP where A is a fresh temp).
                                    // Note: vm.valstack_top is not reliable here (builtin calls
                                    // may leave it below bottom + num_regs), so use num_regs.
                                    uint callee_reg = ds.act.func != null
                                        ? ((CompiledFunction*)ds.act.func).num_regs
                                        : (uint)(vm.valstack_top - ds.act.bottom);
                                    uint frame_start = callee_reg + 2;
                                    TVal* new_bottom = ds.act.bottom + frame_start;
                                    uint needed = (uint)(new_bottom - vm.valstack) + target.num_regs;

                                    if (ensure_valstack(vm, needed) && vm.activation_count < MAX_CALLS) {
                                        new_bottom = ds.act.bottom + frame_start;
                                        TVal* caller_regs = ds.act.bottom;

                                        // Raw stores: these slots are above the initialized frame,
                                        // so tval_copy_ref would decref stale garbage. The setter fn
                                        // and object are kept alive by the property entry and ra.
                                        caller_regs[callee_reg] = setter_fn;
                                        TVal obj_tv;
                                        obj_tv.set_object(hobj);
                                        caller_regs[callee_reg + 1] = obj_tv;

                                        Activation* new_act = &vm.activations[vm.activation_count];
                                        vm.activation_count++;
                                        new_act.max_heap_reg = 0;
                                        new_act.caller_valstack_top = vm.valstack_top;

                                        EnvRecord* setter_var_env = (*setter_obj.extra_ptr()).func.var_env;
                                        if (try fv_s = env::env_create_function_scope(vm.heap, (*setter_obj.extra_ptr()).func.var_env)) { setter_var_env = fv_s; }
                                        new_act.parent = ds.act;
                                        new_act.func = target;
                                        new_act.var_env = setter_var_env;
                                        new_act.lex_env = resolve_call_lex_env(vm, setter_obj, target, setter_var_env);
                                        new_act.cat = null;
                                        new_act.curr_pc = target.code;
                                        new_act.bottom = new_bottom;
                                        new_act.retval = null;  // setter return value is discarded
                                        new_act.flags = 0;
                                        if (target.has_direct_eval()) {
                                            new_act.flags |= ACT_FLAG_DIRECT_EVAL;
                                        }
                                        vm.heap.tval_copy_ref(&new_act.this_binding, &obj_tv);

                                        TVal* new_regs = new_act.bottom;
                                        libc::memset(new_regs, 0, (usz)target.num_regs * TVal::size);
                                        vm.heap.tval_copy_ref(&new_regs[0], &put_val);

                                        vm.valstack_top = new_regs + target.num_regs;
                                        vm.valstack_bottom = new_act.bottom;

                                        ds.act.curr_pc = ds.curr_pc;

                                        ds.needs_restart = true;
                                        return (TVal){};
                                    }
                                }
                            }
                        } else if (!exist_flags.writable) {
                            // Strict-only engine: non-writable property assignment always throws.
                            if (!vm_throw_error(vm, vm.heap.type_err_proto, "Cannot assign to read only property", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                return VM_ERROR~;
                            }
                            return (TVal){};
                        } else {
                            // Update value, preserve existing flags
                            vm.heap.tval_copy_ref(entry, &put_val);
                        }
                    } else {
                        // Property doesn't exist: check prototype for accessors
                        hobject::AccessorResult acc = hobj.find_accessor_proto(key, false);
                        if (acc.found && acc.accessor_fn.is_object() && acc.accessor_fn.get_heapptr() != null) {
                            // Invoke setter from prototype
                            HObject* setter_obj = (HObject*)acc.accessor_fn.get_heapptr();
                            if (setter_obj.is_callable() && (*setter_obj.extra_ptr()).func.comp_func != null) {
                                CompiledFunction* target = (*setter_obj.extra_ptr()).func.comp_func;

                                // Stage the call frame above the caller's live registers
                                // (see own-property setter path above).
                                uint callee_reg = ds.act.func != null
                                    ? ((CompiledFunction*)ds.act.func).num_regs
                                    : (uint)(vm.valstack_top - ds.act.bottom);
                                uint frame_start = callee_reg + 2;
                                TVal* new_bottom = ds.act.bottom + frame_start;
                                uint needed = (uint)(new_bottom - vm.valstack) + target.num_regs;

                                if (ensure_valstack(vm, needed) && vm.activation_count < MAX_CALLS) {
                                    new_bottom = ds.act.bottom + frame_start;
                                    TVal* caller_regs = ds.act.bottom;

                                    caller_regs[callee_reg] = acc.accessor_fn;
                                    TVal obj_tv;
                                    obj_tv.set_object(acc.this_obj);
                                    caller_regs[callee_reg + 1] = obj_tv;

                                    Activation* new_act = &vm.activations[vm.activation_count];
                                    vm.activation_count++;
                                    new_act.max_heap_reg = 0;
                                    new_act.caller_valstack_top = vm.valstack_top;

                                    EnvRecord* setter_var_env = (*setter_obj.extra_ptr()).func.var_env;
                                    if (try fv_s = env::env_create_function_scope(vm.heap, (*setter_obj.extra_ptr()).func.var_env)) { setter_var_env = fv_s; }
                                    new_act.parent = ds.act;
                                    new_act.func = target;
                                    new_act.var_env = setter_var_env;
                                    new_act.lex_env = resolve_call_lex_env(vm, setter_obj, target, setter_var_env);
                                    new_act.cat = null;
                                    new_act.curr_pc = target.code;
                                    new_act.bottom = new_bottom;
                                    new_act.retval = null;  // setter return value is discarded
                                    new_act.flags = 0;
                                    if (target.has_direct_eval()) {
                                        new_act.flags |= ACT_FLAG_DIRECT_EVAL;
                                    }
                                    vm.heap.tval_copy_ref(&new_act.this_binding, &obj_tv);

                                    TVal* new_regs = new_act.bottom;
                                    libc::memset(new_regs, 0, (usz)target.num_regs * TVal::size);
                                    vm.heap.tval_copy_ref(&new_regs[0], &put_val);

                                    vm.valstack_top = new_regs + target.num_regs;
                                    vm.valstack_bottom = new_act.bottom;

                                    ds.act.curr_pc = ds.curr_pc;

                                    ds.needs_restart = true;
                                    return (TVal){};
                                }
                            }
                        } else {
                            // No accessor: insert new property
                            if (hobj.flags.extensible) {
                                hobj.put_prop(key, put_val, hobject::PROP_FLAGS_WEC);
                            } else {
                                // ES5 §9.1.2 step 5b: if O is not extensible, throw TypeError.
                                // Strict-only engine: always throws.
                                if (!vm_throw_error(vm, vm.heap.type_err_proto, "Cannot add property to non-extensible object", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                    return VM_ERROR~;
                                }
                            }
                        }
                    }
                }
            } else if (ra.is_null() || ra.is_undefined()) {
                // TypeError: Cannot set properties of null/undefined
                HString* name_hstr = null;
                if (rb.is_string()) {
                    name_hstr = (HString*)rb.get_heapptr();
                }
                char[types::ERROR_MSG_BUF] msg_buf;
                int msg_len;
                if (name_hstr != null) {
                    msg_len = libc::snprintf(&msg_buf, types::ERROR_MSG_BUF, "Cannot set properties of %s (setting '%s')",
                                              (ra.is_null() ? "null" : "undefined"),
                                              name_hstr.get_cstr());
                } else {
                    msg_len = libc::snprintf(&msg_buf, types::ERROR_MSG_BUF, "Cannot set properties of %s",
                                              (ra.is_null() ? "null" : "undefined"));
                }
                char[] msg_slice = (msg_len > 0 && msg_len < types::ERROR_MSG_BUF) ? msg_buf[:msg_len] : msg_buf[:0];
                if (!vm_throw_error(vm, vm.heap.type_err_proto, msg_slice, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return VM_ERROR~;
                }
            }
            return (TVal){};

        case Opcode.DELPROP: {
            // ES5 §11.4.1: delete operator
            // A = delete B[C], where B = object, C = property key
            // Returns boolean: true if deleted or not found,
            // false if the property exists and is non-configurable.

            // ES6 §12.5.3.2 step 5.b: ToObject(base) — throws TypeError
            // for null/undefined. This must run BEFORE the value check,
            // because the runtime semantics require ToObject on the base.
            if (rb.is_null() || rb.is_undefined()) {
                if (!vm_throw_error(vm, vm.heap.type_err_proto, "Cannot delete property of null or undefined", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return VM_ERROR~;
                }
                return (TVal){};
            }

            ra.set_boolean(true);

            if (rb.is_object()) {
                HObject* hobj = (HObject*)rb.get_heapptr();
                void* key = get_prop_key(vm, rc);
                if (key != null) {
                    if (!hobj.es_delete_prop(key)) {
                        ra.set_boolean(false);
                        // Strict-only engine: non-configurable delete always throws.
                        if (!vm_throw_error(vm, vm.heap.type_err_proto, "Delete failed: property is non-configurable", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return VM_ERROR~;
                        }
                        return (TVal){};
                    } else {
                        ra.set_boolean(true);
                    }
                }
            } else if (rb.is_lightfunc()) {
                // Handle deletion of virtual properties (name, length, prototype).
                // These are configurable:true per ES5 §15.3.5.1, so delete returns true.
                // Mark as deleted so subsequent GETPROP/hasOwn check the bitset.
                uint fn_idx = (uint)(usz)rb.get_heapptr();
                HString* key = get_prop_key(vm, rc);
                if (key != null) {
                    int bit = heap::lf_key_to_prop_bit(key);
                    if (bit >= 0) {
                        heap::lf_mark_deleted(&vm.heap.lf_deleted_props[0], fn_idx, (uint)bit);
                    }
                }
            }
            // For other primitives (number, string, boolean), the spec's
            // ToObject() would box them — but our base is already a primitive
            // TVal, so property deletion on it returns true (the property
            // simply doesn't exist on the boxed wrapper).
            return (TVal){};
        }

        default:
            return (TVal){};
    }
}


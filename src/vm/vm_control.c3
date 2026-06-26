module duktape::vm;

import duktape::types;
import duktape::bytecode;
import duktape::heap;
import duktape::hstring;
import duktape::hobject;
import duktape::env;
import duktape::builtins;
import libc;

// ============================================================================
// vm_control — return / variable access / closure / iterator / exceptions / misc
// ============================================================================

/// Sub-dispatch for RET/RETUNDEF/RET_GEN/RETUNDEF_GEN opcodes.
/// Handles the return path including finally unwinding, async promise
/// settlement, and the inline caller-state restoration.
fn TVal? dispatch_returns(Dispatch* ds, Opcode op, TVal* ra) {
    Vm* vm = ds.vm;
    switch (op) {
        case Opcode.RET: {
            // Safe point: run deferred GC before returning to caller
            if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); }
            // Check for active finally catchers: if we're returning through
            // a try-finally, save the return value and jump to the finally
            // handler.  After ENDFINALLY, the saved value will be used.
            Catcher* ret_cat = (Catcher*)ds.act.cat;
            if (ret_cat != null && ret_cat.finally_pc != null) {
                // Save return value
                ret_cat.return_val = *ra;
                // If PENDING_RETURN is already set, we're inside the finally
                // block that was entered due to an earlier return.  Just update
                // the return value and let execution continue normally —
                // ENDFINALLY at the end of the finally block will complete the
                // return with the new value.  Without this check, we'd loop
                // infinitely back to the same finally block.
                if (!(ret_cat.flags & CATCHER_FLAG_PENDING_RETURN)) {
                    ret_cat.flags |= CATCHER_FLAG_PENDING_RETURN;
                    // Jump to finally handler
                    ds.curr_pc = ret_cat.finally_pc;
                    ds.act.curr_pc = ds.curr_pc;
                }
                return (TVal){};
            }

            // Inline handle_return — eliminates function call overhead on every return.
            TVal val = *ra;
            Activation* callee_act = &vm.activations[vm.activation_count - 1];
            TVal* callee_result = callee_act.retval;

            // Protect the return value: if its only reference lives in a
            // callee register, decref_callee_regs below would free it.
            bool val_pinned = false;
            if (val.is_heap_allocated() && val.get_heapptr() != null) {
                ((HeapHeader*)val.get_heapptr()).incref();
                val_pinned = true;
            }

            // Decref callee registers before popping
            decref_callee_regs(vm, callee_act);

            vm.activation_count--;

            // Async function: settle promise with return value and return the promise
            if ((callee_act.flags & ACT_FLAG_ASYNC) != 0 && callee_act.async_promise != null) {
                builtins::promise_settle(callee_act.async_promise, 1, &val, vm.heap);
                builtins::promise_trigger_reactions(callee_act.async_promise, vm.heap, (void*)vm);
                // Release pin on original return value (promise now holds a ref)
                if (val_pinned) {
                    vm.heap.decref_tval(&val);
                }
                // Replace val with promise; its birth ref (refcount=1) acts as the pin
                val.set_object(callee_act.async_promise);
                val_pinned = true;
            }

            if (vm.activation_count == 0) {
                vm.heap.tval_copy_ref(&vm.return_val, &val);
                if (val_pinned) vm.heap.decref_tval(&val);
                return vm.return_val;
            }
            // Write return value to caller's result register
            if (callee_result != null) {
                // Constructor: if callee returned an object, use it; otherwise use 'this'
                if ((callee_act.flags & ACT_FLAG_CONSTRUCT) != 0) {
                    if (val.is_object()) {
                        vm.heap.tval_copy_ref(callee_result, &val);
                    } else {
                        vm.heap.tval_copy_ref(callee_result, &callee_act.this_binding);
                    }
                } else {
                    // Fast path: skip refcounting when return value is not a heap ref
                    if (!val.is_heap_allocated()) {
                        if (callee_result.is_heap_allocated()) {
                            vm.heap.decref_tval(callee_result);
                        }
                        *callee_result = val;
                    } else if (val_pinned) {
                        // Transfer the pin reference: decref dst, raw write.
                        vm.heap.decref_tval(callee_result);
                        *callee_result = val;
                        val_pinned = false;
                    } else {
                        vm.heap.tval_copy_ref(callee_result, &val);
                    }
                }
            }
            if (val_pinned) vm.heap.decref_tval(&val);
            // Restore caller state inline — skip outer loop restart.
            ds.act = &vm.activations[vm.activation_count - 1];
            vm.valstack_bottom = ds.act.bottom;
            vm.valstack_top = ds.act.caller_valstack_top;
            CompiledFunction* caller_func = (CompiledFunction*)ds.act.func;
            if (caller_func != vm.current_func) {
                vm.current_func = caller_func;
                ds.code_base = caller_func.code;
                ds.code_count = caller_func.code_count;
                ds.code_end = ds.code_base + ds.code_count;
                ds.constants = caller_func.constants;
                ds.ic_base = (hobject::ICEntry*)caller_func.ic_entries;
                ds.var_ic_base = (hobject::VarICEntry*)caller_func.var_ic_entries;
                ds.nregs = caller_func.num_regs;
            }
            ds.curr_pc = ds.act.curr_pc;
            ds.regs_base = ds.act.bottom;
            return (TVal){};
        }

        case Opcode.RETUNDEF: {
            // Safe point: run deferred GC before returning to caller
            if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); }
            // Check for active finally catchers (same as RET)
            Catcher* ret2_cat = (Catcher*)ds.act.cat;
            if (ret2_cat != null && ret2_cat.finally_pc != null) {
                ret2_cat.return_val.set_undefined();
                if (!(ret2_cat.flags & CATCHER_FLAG_PENDING_RETURN)) {
                    ret2_cat.flags |= CATCHER_FLAG_PENDING_RETURN;
                    ds.curr_pc = ret2_cat.finally_pc;
                    ds.act.curr_pc = ds.curr_pc;
                }
                return (TVal){};
            }

            TVal undef_val;
            undef_val.set_undefined();

            // Inline handle_return — eliminates function call overhead.
            Activation* callee_act = &vm.activations[vm.activation_count - 1];
            TVal* callee_result = callee_act.retval;

            // Decref callee registers before popping
            decref_callee_regs(vm, callee_act);

            vm.activation_count--;

            // Async function: settle promise with undefined, return promise
            bool async_ret = false;
            if ((callee_act.flags & ACT_FLAG_ASYNC) != 0 && callee_act.async_promise != null) {
                builtins::promise_settle(callee_act.async_promise, 1, &undef_val, vm.heap);
                builtins::promise_trigger_reactions(callee_act.async_promise, vm.heap, (void*)vm);
                undef_val.set_object(callee_act.async_promise);
                async_ret = true;
            }

            if (vm.activation_count == 0) {
                vm.heap.tval_copy_ref(&vm.return_val, &undef_val);
                if (async_ret) vm.heap.decref_tval(&undef_val);
                return vm.return_val;
            }
            // Write return value to caller's result register
            if (callee_result != null) {
                // Constructor: return 'this' (the newly created object)
                if ((callee_act.flags & ACT_FLAG_CONSTRUCT) != 0) {
                    vm.heap.tval_copy_ref(callee_result, &callee_act.this_binding);
                } else {
                    if (callee_result.is_heap_allocated()) {
                        vm.heap.decref_tval(callee_result);
                    }
                    *callee_result = undef_val;
                }
            }
            // Restore caller state inline — skip outer loop restart.
            ds.act = &vm.activations[vm.activation_count - 1];
            vm.valstack_bottom = ds.act.bottom;
            vm.valstack_top = ds.act.caller_valstack_top;
            CompiledFunction* caller_func = (CompiledFunction*)ds.act.func;
            if (caller_func != vm.current_func) {
                vm.current_func = caller_func;
                ds.code_base = caller_func.code;
                ds.code_count = caller_func.code_count;
                ds.code_end = ds.code_base + ds.code_count;
                ds.constants = caller_func.constants;
                ds.ic_base = (hobject::ICEntry*)caller_func.ic_entries;
                ds.var_ic_base = (hobject::VarICEntry*)caller_func.var_ic_entries;
                ds.nregs = caller_func.num_regs;
            }
            ds.curr_pc = ds.act.curr_pc;
            ds.regs_base = ds.act.bottom;
            return (TVal){};
        }

        case Opcode.RET_GEN: {
            // Generator return: mark completed, wrap in IteratorResult
            GeneratorState* gs = vm.heap.resume_gen;
            gs.state = GEN_COMPLETED;
            vm.heap.tval_copy_ref(&vm.heap.yield_value, &ra[0]);
            vm.heap.did_yield = false;
            vm.heap.resume_gen = null;

            HObject*? robj_raw = vm.heap.alloc_object(hobject::ObjClass.OBJECT);
            TVal wrapped_val;
            if (try robj = robj_raw) {
                robj.prototype = vm.heap.object_proto;
                HString* val_key = (HString*)vm.heap.strs[heap::BuiltinStr.VALUE];
                if (val_key != null) robj.put_prop(val_key, ra[0], hobject::PROP_FLAGS_WEC);
                HString* done_key = (HString*)vm.heap.strs[heap::BuiltinStr.DONE];
                TVal done_val;
                done_val.set_boolean(true);
                if (done_key != null) robj.put_prop(done_key, done_val, hobject::PROP_FLAGS_WEC);
                wrapped_val.set_object(robj);
            } else {
                wrapped_val = ra[0];
            }

            Activation* ret_act = &vm.activations[vm.activation_count - 1];
            TVal* ret_byteoff = ret_act.retval;
            TVal* ret_slot = ret_byteoff;
            vm.heap.tval_copy_ref(&ret_slot[0], &wrapped_val);

            vm.activation_count--;
            if (vm.activation_count > 0) {
                Activation* caller_act = &vm.activations[vm.activation_count - 1];
                vm.valstack_bottom = caller_act.bottom;
                if (caller_act.func != null) {
                    CompiledFunction* caller_func = (CompiledFunction*)caller_act.func;
                    vm.valstack_top = caller_act.bottom + caller_func.num_regs;
                }
            }
            ds.needs_restart = true;
            return (TVal){};
        }

        case Opcode.RETUNDEF_GEN: {
            // Generator return undefined: mark completed
            GeneratorState* gs2 = vm.heap.resume_gen;
            gs2.state = GEN_COMPLETED;
            vm.heap.did_yield = false;
            vm.heap.resume_gen = null;

            // Wrap in IteratorResult {value: undefined, done: true}
            HObject*? robj_raw2 = vm.heap.alloc_object(hobject::ObjClass.OBJECT);
            TVal wrapped_val2;
            if (try robj2 = robj_raw2) {
                robj2.prototype = vm.heap.object_proto;
                HString* val_key2 = (HString*)vm.heap.strs[heap::BuiltinStr.VALUE];
                TVal undef_val2;
                undef_val2.set_undefined();
                if (val_key2 != null) robj2.put_prop(val_key2, undef_val2, hobject::PROP_FLAGS_WEC);
                HString* done_key2 = (HString*)vm.heap.strs[heap::BuiltinStr.DONE];
                TVal done_val2;
                done_val2.set_boolean(true);
                if (done_key2 != null) robj2.put_prop(done_key2, done_val2, hobject::PROP_FLAGS_WEC);
                wrapped_val2.set_object(robj2);
            } else {
                TVal undef_val2;
                undef_val2.set_undefined();
                wrapped_val2 = undef_val2;
            }

            Activation* ret_act2 = &vm.activations[vm.activation_count - 1];
            TVal* ret_byteoff2 = ret_act2.retval;
            TVal* ret_slot2 = ret_byteoff2;
            vm.heap.tval_copy_ref(&ret_slot2[0], &wrapped_val2);

            vm.activation_count--;
            if (vm.activation_count > 0) {
                Activation* caller_act2 = &vm.activations[vm.activation_count - 1];
                vm.valstack_bottom = caller_act2.bottom;
                if (caller_act2.func != null) {
                    CompiledFunction* caller_func2 = (CompiledFunction*)caller_act2.func;
                    vm.valstack_top = caller_act2.bottom + caller_func2.num_regs;
                }
            }
            ds.needs_restart = true;
            return (TVal){};
        }
        default:
            return (TVal){};
    }
    return (TVal){};
}
/// Sub-dispatch for GETVAR, TYPEOFIDENT, PUTVAR, DECLVAR, PUTLEX, PUTLEX_C, INITTZ, DELVAR opcodes.
fn TVal? dispatch_var_access(Dispatch* ds, Opcode op, TVal* ra, TVal* rb, TVal* rc, Instruction insn) {
    Vm* vm = ds.vm;
    switch (op) {
        case Opcode.GETVAR: {
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                TVal name_val = ds.constants[bc];
                if (name_val.is_string()) {
                    void* key = name_val.get_heapptr();

                    // --- Variable IC fast path ---
                    if (ds.var_ic_base != null) {
                        uint pc_off = (uint)(ds.curr_pc - 1 - ds.code_base);
                        hobject::VarICEntry* vic = ds.var_ic_base + pc_off;
                        if (vic.env != null && vic.key == key && vic.search_head == (void*)ds.act.lex_env) {
                            HObject* b = (HObject*)vic.bindings;
                            if (b.shape_id == vic.shape_id
                                && vm.heap.shapes[b.shape_id].generation == vic.generation) {
                                if (b.get_prop_flags(vic.prop_idx).is_accessor) {
                                    // Accessor property: fall through to slow path which invokes getter
                                } else {
                                    TVal v = b.prop_values()[vic.prop_idx];
                                    if (!env::is_tdz_sentinel(&v)) {
                                        vm.heap.tval_copy_ref(ra, &v);
                                        track_heap_store(ds.act, ra, (uint)insn.a);
                                        break;
                                    }
                                    // TDZ: fall through to slow path (error)
                                }
                            }
                            vic.env = null;
                        }
                    }

                    // --- Slow path: full environment chain walk ---
                    bool found = false;
                    EnvRecord* ic_env = null;
                    int ic_prop_idx = -1;

                    // Search lexical environment first (for let/const bindings)
                    EnvRecord* cur = ds.act.lex_env;
                    while (cur != null) {
                        int idx = cur.bindings.find_prop_idx(key);
                        if (idx >= 0) {
                            TVal v_raw = cur.bindings.prop_values()[idx];
                            if (env::is_tdz_sentinel(&v_raw)) {
                                HString* name_hstr = (HString*)key;
                                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                                if (try err = err_raw) {
                                    err.prototype = vm.heap.ref_err_proto;
                                    char[types::ERROR_MSG_BUF] buf;
                                    int len = libc::snprintf(&buf, types::ERROR_MSG_BUF, "Cannot access '%s' before initialization",
                                                             name_hstr.get_cstr());
                                    if (len > 0 && len < types::ERROR_MSG_BUF) {
                                        HString* msg_str = intern_string(vm, buf[:len]);
                                        TVal msg_val;
                                        msg_val.set_string(msg_str);
                                        HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                                        err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                                    }
                                    TVal err_val;
                                    err_val.set_object(err);
                                    if (!vm_throw_value(vm, err_val, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                        return vm_uncaught_error(vm, &err_val);
                                    }
                                    found = true; // prevent duplicate error
                                } else {
                                    return VM_ERROR~;
                                }
                            } else if (cur.bindings.get_prop_flags((uint)idx).is_accessor) {
                                // Accessor property: invoke getter
                                TVal getter = hobject::hobject_access_getter(v_raw);
                                if (!getter.is_undefined() && !getter.is_null() && vm.heap.call_fn != null) {
                                    TVal this_tv;
                                    this_tv.set_object(cur.bindings);
                                    TVal getter_val = vm.heap.call_fn(vm, getter, null, 0, this_tv);
                                    if (vm.heap.has_error) {
                                        // Propagate error from getter
                                        vm.has_error = true;
                                        return VM_ERROR~;
                                    }
                                    vm.heap.tval_copy_ref(ra, &getter_val);
                                } else {
                                    ra.set_undefined();
                                }
                                track_heap_store(ds.act, ra, (uint)insn.a);
                                found = true;
                                ic_env = cur;
                                ic_prop_idx = idx;
                            } else {
                                vm.heap.tval_copy_ref(ra, &v_raw);
                                track_heap_store(ds.act, ra, (uint)insn.a);
                                found = true;
                                ic_env = cur;
                                ic_prop_idx = idx;
                            }
                            break;
                        }
                        cur = cur.parent;
                    }

                    if (!found && ds.act.lex_env != ds.act.var_env) {
                        // Not in lex_env — search var_env (only needed with `with` blocks)
                        EnvRecord* vcur = ds.act.var_env;
                        while (vcur != null) {
                            int vidx = vcur.bindings.find_prop_idx(key);
                            if (vidx >= 0) {
                                if (vcur.bindings.get_prop_flags((uint)vidx).is_accessor) {
                                    TVal gs_slot = vcur.bindings.prop_values()[vidx];
                                    TVal getter = hobject::hobject_access_getter(gs_slot);
                                    if (!getter.is_undefined() && !getter.is_null() && vm.heap.call_fn != null) {
                                        TVal this_tv;
                                        this_tv.set_object(vcur.bindings);
                                        TVal getter_val = vm.heap.call_fn(vm, getter, null, 0, this_tv);
                                        if (vm.heap.has_error) { vm.has_error = true; return VM_ERROR~; }
                                        vm.heap.tval_copy_ref(ra, &getter_val);
                                    } else {
                                        ra.set_undefined();
                                    }
                                } else {
                                    TVal v2 = vcur.bindings.prop_values()[vidx];
                                    vm.heap.tval_copy_ref(ra, &v2);
                                }
                                track_heap_store(ds.act, ra, (uint)insn.a);
                                found = true;
                                break;
                            }
                            vcur = vcur.parent;
                        }
                    }

                    if (found) {
                        // Populate IC
                        if (ds.var_ic_base != null && ic_env != null) {
                            uint pc_off = (uint)(ds.curr_pc - 1 - ds.code_base);
                            hobject::VarICEntry* vic = ds.var_ic_base + pc_off;
                            vic.env = ic_env;
                            vic.bindings = ic_env.bindings;
                            vic.shape_id = ic_env.bindings.shape_id;
                            vic.generation = vm.heap.shapes[ic_env.bindings.shape_id].generation;
                            vic.prop_idx = (ushort)ic_prop_idx;
                            if (vic.key != null) { vm.heap.decref((types::HeapHeader*)vic.key); }
                            vic.key = key;
                            if (key != null) { ((types::HeapHeader*)key).incref(); }
                            vic.search_head = (void*)ds.act.lex_env;
                        }
                    } else {
                        // ReferenceError: variable not declared
                        HString* name_hstr = (HString*)key;
                        HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                        if (try err = err_raw) {
                            err.prototype = vm.heap.ref_err_proto;
                            char[types::ERROR_MSG_BUF] buf;
                            int len = libc::snprintf(&buf, types::ERROR_MSG_BUF, "%s is not defined",
                                                     name_hstr.get_cstr());
                            if (len > 0 && len < types::ERROR_MSG_BUF) {
                                HString* msg_str = intern_string(vm, buf[:len]);
                                TVal msg_val;
                                msg_val.set_string(msg_str);
                                HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                                err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                            }
                            TVal err_val;
                            err_val.set_object(err);
                            if (!vm_throw_value(vm, err_val, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                return vm_uncaught_error(vm, &err_val);
                            }
                        } else {
                            return VM_ERROR~;
                        }
                    }
                } else {
                    ra.set_undefined();
                }
            } else {
                ra.set_undefined();
            }
            return (TVal){};
        }

        case Opcode.TYPEOFIDENT: {
            // ES5 §11.4.3: typeof on an unresolvable reference returns "undefined"
            // instead of throwing ReferenceError.
            // ES6: typeof on a TDZ variable THROWS ReferenceError.
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                TVal name_val = ds.constants[bc];
                if (name_val.is_string()) {
                    void* key = name_val.get_heapptr();

                    // --- Variable IC fast path ---
                    if (ds.var_ic_base != null) {
                        uint pc_off = (uint)(ds.curr_pc - 1 - ds.code_base);
                        hobject::VarICEntry* vic = ds.var_ic_base + pc_off;
                        if (vic.env != null && vic.key == key && vic.search_head == (void*)ds.act.lex_env) {
                            HObject* b = (HObject*)vic.bindings;
                            if (b.shape_id == vic.shape_id
                                && vm.heap.shapes[b.shape_id].generation == vic.generation) {
                                // Accessor properties store a getter/setter pair, not the
                                // actual value.  Fall through to slow path which invokes the getter.
                                if (b.get_prop_flags(vic.prop_idx).is_accessor) {
                                    // Invalidate IC — slow path will handle it.
                                } else {
                                    TVal v = b.prop_values()[vic.prop_idx];
                                    if (!env::is_tdz_sentinel(&v)) {
                                        HString* ts = typeof_string(vm, &v);
                                        vm.heap.set_reg_string(ra, ts);
                                        break;
                                    }
                                    // TDZ: fall through to slow path (error)
                                }
                            }
                            vic.env = null;
                        }
                    }

                    // --- Slow path ---
                    bool found = false;
                    EnvRecord* ic_env = null;
                    int ic_prop_idx = -1;

                    // Search lexical environment first (for let/const bindings)
                    EnvRecord* cur = ds.act.lex_env;
                    while (cur != null) {
                        int idx = cur.bindings.find_prop_idx(key);
                        if (idx >= 0) {
                            TVal v_raw = cur.bindings.prop_values()[idx];
                            if (env::is_tdz_sentinel(&v_raw)) {
                                // TDZ: throw ReferenceError (ES6 behavior)
                                HString* name_hstr = (HString*)key;
                                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                                if (try err = err_raw) {
                                    err.prototype = vm.heap.ref_err_proto;
                                    char[types::ERROR_MSG_BUF] buf;
                                    int len = libc::snprintf(&buf, types::ERROR_MSG_BUF, "Cannot access '%s' before initialization",
                                                             name_hstr.get_cstr());
                                    if (len > 0 && len < types::ERROR_MSG_BUF) {
                                        HString* msg_str = intern_string(vm, buf[:len]);
                                        TVal msg_val;
                                        msg_val.set_string(msg_str);
                                        HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                                        err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                                    }
                                    TVal err_val;
                                    err_val.set_object(err);
                                    if (!vm_throw_value(vm, err_val, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                        return vm_uncaught_error(vm, &err_val);
                                    }
                                } else {
                                    return VM_ERROR~;
                                }
                            } else if (cur.bindings.get_prop_flags((uint)idx).is_accessor) {
                                // Accessor property: invoke getter for typeof
                                TVal getter = hobject::hobject_access_getter(v_raw);
                                if (!getter.is_undefined() && !getter.is_null() && vm.heap.call_fn != null) {
                                    TVal this_tv;
                                    this_tv.set_object(cur.bindings);
                                    TVal getter_val = vm.heap.call_fn(vm, getter, null, 0, this_tv);
                                    if (vm.heap.has_error) {
                                        // Propagate error from getter
                                        vm.has_error = true;
                                        return VM_ERROR~;
                                    }
                                    HString* ts = typeof_string(vm, &getter_val);
                                    vm.heap.set_reg_string(ra, ts);
                                } else {
                                    // No getter → typeof returns "undefined"
                                    HString* ts = (HString*)vm.heap.strs[heap::BuiltinStr.UNDEFINED];
                                    vm.heap.set_reg_string(ra, ts);
                                }
                                found = true;
                                ic_env = cur;
                                ic_prop_idx = idx;
                            } else {
                                HString* ts = typeof_string(vm, &v_raw);
                                vm.heap.set_reg_string(ra, ts);
                                found = true;
                                ic_env = cur;
                                ic_prop_idx = idx;
                            }
                            break;
                        }
                        cur = cur.parent;
                    }

                    if (!found) {
                        // Not in lex_env — search var_env
                        EnvRecord* vcur2 = ds.act.var_env;
                        while (vcur2 != null) {
                            int vidx2 = vcur2.bindings.find_prop_idx(key);
                            if (vidx2 >= 0) {
                                if (vcur2.bindings.get_prop_flags((uint)vidx2).is_accessor) {
                                    TVal gs_slot2 = vcur2.bindings.prop_values()[vidx2];
                                    TVal getter2 = hobject::hobject_access_getter(gs_slot2);
                                    if (!getter2.is_undefined() && !getter2.is_null() && vm.heap.call_fn != null) {
                                        TVal this_tv2;
                                        this_tv2.set_object(vcur2.bindings);
                                        TVal getter_val2 = vm.heap.call_fn(vm, getter2, null, 0, this_tv2);
                                        if (vm.heap.has_error) { vm.has_error = true; return VM_ERROR~; }
                                        HString* ts2 = typeof_string(vm, &getter_val2);
                                        vm.heap.set_reg_string(ra, ts2);
                                    } else {
                                        HString* ts2 = (HString*)vm.heap.strs[heap::BuiltinStr.UNDEFINED];
                                        vm.heap.set_reg_string(ra, ts2);
                                    }
                                } else {
                                    TVal v2 = vcur2.bindings.prop_values()[vidx2];
                                    HString* ts = typeof_string(vm, &v2);
                                    vm.heap.set_reg_string(ra, ts);
                                }
                                found = true;
                                break;
                            }
                            vcur2 = vcur2.parent;
                        }
                        if (!found) {
                            // Unresolvable reference → "undefined" (no error)
                            HString* ts = (HString*)vm.heap.strs[heap::BuiltinStr.UNDEFINED];
                            vm.heap.set_reg_string(ra, ts);
                        }
                    }

                    // Populate IC (skip for unresolvable — no env to cache)
                    if (found && ds.var_ic_base != null && ic_env != null) {
                        uint pc_off = (uint)(ds.curr_pc - 1 - ds.code_base);
                        hobject::VarICEntry* vic = ds.var_ic_base + pc_off;
                        vic.env = ic_env;
                        vic.bindings = ic_env.bindings;
                        vic.shape_id = ic_env.bindings.shape_id;
                        vic.generation = vm.heap.shapes[ic_env.bindings.shape_id].generation;
                        vic.prop_idx = (ushort)ic_prop_idx;
                        if (vic.key != null) { vm.heap.decref((types::HeapHeader*)vic.key); }
                        vic.key = key;
                        if (key != null) { ((types::HeapHeader*)key).incref(); }
                        vic.search_head = (void*)ds.act.lex_env;
                    }
                } else {
                    ra.set_undefined();
                }
            } else {
                ra.set_undefined();
            }
            return (TVal){};
        }

        case Opcode.PUTVAR: {
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                TVal name_val = ds.constants[bc];
                if (name_val.is_string()) {
                    void* key = name_val.get_heapptr();
                    // Combined single-walk: check lex_env, writability, and update in one pass
                    int put_result = env::env_try_put_lex(ds.act.lex_env, key, *ra);
                    if (put_result == -1) {
                        // Const violation — throw TypeError
                        HString* name_hstr = (HString*)key;
                        HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                        if (try err = err_raw) {
                            err.prototype = vm.heap.type_err_proto;
                            char[types::ERROR_MSG_BUF] buf;
                            int len = libc::snprintf(&buf, types::ERROR_MSG_BUF, "Assignment to constant variable '%s'",
                                                     name_hstr.get_cstr());
                            if (len > 0 && len < types::ERROR_MSG_BUF) {
                                HString* msg_str = intern_string(vm, buf[:len]);
                                TVal msg_val;
                                msg_val.set_string(msg_str);
                                HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                                err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                            }
                            TVal err_val;
                            err_val.set_object(err);
                            if (!vm_throw_value(vm, err_val, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                return vm_uncaught_error(vm, &err_val);
                            }
                        } else {
                            return VM_ERROR~;
                        }
                        break;
                    } else if (put_result == 0) {
                        // Not in lex_env — fall through to var_env
                        env::env_put(ds.act.var_env, key, *ra);
                    }
                    // put_result == 1: already updated in lex_env
                    // Release ra's ref — the binding now owns the reference.
                    // Without this, ra holds a stale ref into the next iteration,
                    // causing strings to leak (not reach rc=0 on binding overwrite).
                    vm.heap.decref_tval(ra);
                    ra.set_undefined();
                }
            }
            return (TVal){};
        }

        case Opcode.DECLVAR: {
            // Declare a `var` binding in the immediate var_env only (no chain walk).
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                TVal name_val = ds.constants[bc];
                if (name_val.is_string()) {
                    void* key = name_val.get_heapptr();

                    // --- VarIC fast path: skip find_prop_idx on repeat calls ---
                    if (ds.var_ic_base != null) {
                        uint pc_off = (uint)(ds.curr_pc - 1 - ds.code_base);
                        hobject::VarICEntry* vic = ds.var_ic_base + pc_off;
                        if (vic.env == (void*)ds.act.var_env && vic.key == key) {
                            HObject* b = (HObject*)vic.bindings;
                            if (b != null && b.shape_id == vic.shape_id
                                && vm.heap.shapes[b.shape_id].generation == vic.generation) {
                                // Direct write — skip find_prop_idx + put_prop overhead
                                TVal* pv = &b.prop_values()[vic.prop_idx];
                                if (hobject::_active_heap != null && pv.is_string()) {
                                    ((heap::Heap*)hobject::_active_heap).decref_tval(pv);
                                }
                                *pv = *ra;
                                if (hobject::_active_heap != null && ra.is_string()) {
                                    void* ptr = ra.get_heapptr();
                                    if (ptr != null) ((types::HeapHeader*)ptr).incref();
                                }
                                break;
                            }
                            vic.env = null;
                        }
                    }

                    // --- Slow path: full env_declare ---
                    env::env_declare(ds.act.var_env, key, *ra);

                    // Populate VarIC for next time
                    if (ds.var_ic_base != null) {
                        uint pc_off = (uint)(ds.curr_pc - 1 - ds.code_base);
                        hobject::VarICEntry* vic = ds.var_ic_base + pc_off;
                        HObject* b = ds.act.var_env.bindings;
                        if (b != null) {
                            int idx = b.find_prop_idx(key);
                            if (idx >= 0) {
                                vic.env = (void*)ds.act.var_env;
                                vic.bindings = (void*)b;
                                vic.shape_id = b.shape_id;
                                vic.generation = vm.heap.shapes[b.shape_id].generation;
                                vic.prop_idx = (ushort)idx;
                                vic.key = key;
                                vic.search_head = null;
                            }
                        }
                    }
                }
            }
            return (TVal){};
        }

        case Opcode.PUTLEX: {
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                TVal name_val = ds.constants[bc];
                if (name_val.is_string()) {
                    void* key = name_val.get_heapptr();
                    env::env_declare_lex(ds.act.lex_env, key, *ra);
                }
            }
            return (TVal){};
        }

        case Opcode.PUTLEX_C: {
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                TVal name_val = ds.constants[bc];
                if (name_val.is_string()) {
                    void* key = name_val.get_heapptr();
                    ds.act.lex_env.bindings.put_prop(key, *ra, hobject::PROP_FLAGS_EC);
                }
            }
            return (TVal){};
        }

        case Opcode.INITTZ: {
            // Store the TDZ sentinel for a variable name in the current
            // lexical environment.  This marks the binding as uninitialized
            // so that GETVAR throws a ReferenceError (temporal dead zone)
            // if the variable is accessed before its PUTLEX/PUTLEX_C.
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                TVal name_val = ds.constants[bc];
                if (name_val.is_string()) {
                    void* key = name_val.get_heapptr();
                    TVal tdz = env::tdz_sentinel();
                    ds.act.lex_env.bindings.put_prop(key, tdz, hobject::PROP_FLAGS_WEC);
                }
            }
            return (TVal){};
        }

        case Opcode.DELVAR:
            ra.set_boolean(true);
            return (TVal){};

        default:
            return (TVal){};
    }
    return (TVal){};
}

/// Sub-dispatch for CLOSURE, GETBOUND opcodes.
fn TVal? dispatch_closures(Dispatch* ds, Opcode op, TVal* ra, TVal* rb, TVal* rc, Instruction insn) {
    Vm* vm = ds.vm;
    switch (op) {
        case Opcode.CLOSURE: {
            uint bc = insn.get_bc();
            if (bc < vm.current_func.inner_count) {
                CompiledFunction* template = vm.current_func.inner_funcs[bc];

                HObject*? func_obj_raw = vm.heap.alloc_object(hobject::ObjClass.FUNCTION);
                if (try func_obj = func_obj_raw) {
                    // Generator function objects inherit from GeneratorFunction.prototype,
                    // all other functions inherit from Function.prototype (ES6 §25.2.3).
                    if (template.is_generator() && vm.heap.generator_func_proto != null) {
                        func_obj.prototype = vm.heap.generator_func_proto;
                    } else {
                        func_obj.prototype = vm.heap.function_proto;
                    }
                    func_obj.flags.callable = true;
                    func_obj.flags.constructable = template.is_constructable();
                    (*func_obj.extra_ptr()).func.comp_func = template;
                    (*func_obj.extra_ptr()).func.var_env = ds.act.var_env;
                    (*func_obj.extra_ptr()).func.lex_env = ds.act.lex_env;

                    // Set .name property (ES6 §14.1.20: non-writable, non-enumerable, configurable)
                    // Always set name — anonymous functions get "" per spec
                    char[] name_data = template.get_name();
                    HString* name_hstr;
                    if (name_data.len > 0) {
                        name_hstr = intern_string(vm, name_data);
                    } else {
                        name_hstr = (HString*)vm.heap.strs[heap::BuiltinStr.EMPTY];
                    }
                    if (name_hstr != null) {
                        TVal name_tv;
                        name_tv.set_string(name_hstr);
                        func_obj.put_prop((HString*)vm.heap.strs[heap::BuiltinStr.NAME], name_tv, hobject::PROP_FLAGS_NWC);
                    }

                    // Set .length property (ES5 §15.3.5.1: non-writable, non-enumerable, configurable)
                    HString* len_key = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
                    TVal len_val;
                    len_val.set_fastint((long)template.num_formals);
                    func_obj.put_prop(len_key, len_val, hobject::PROP_FLAGS_NWC);

                    // Arrow functions don't get a .prototype property (ES6 §14.2.16)
                    if (!template.is_arrow()) {
                        // ES5 §13.2: create .prototype property (plain object with .constructor).
                        // For class constructors, ES2015 §14.5.14 step 25 requires the
                        // resulting constructor's .prototype to be non-configurable so
                        // that `class C { static ['prototype']() {} }` throws TypeError
                        // (the static-method-non-configurable-err test262 case).
                        hobject::PropFlags proto_pflags = template.is_class_ctor()
                            ? hobject::PROP_FLAGS_WENC
                            : hobject::PROP_FLAGS_WEC;
                        HObject*? proto_obj_raw = vm.heap.alloc_object(hobject::ObjClass.OBJECT);
                        if (try proto_obj = proto_obj_raw) {
                            if (template.is_generator() && vm.heap.generator_proto != null) {
                                // Generator function .prototype inherits from Generator.prototype
                                proto_obj.prototype = vm.heap.generator_proto;
                                // .constructor is inherited from Generator.prototype,
                                // no need to set it here.
                            } else {
                                proto_obj.prototype = vm.heap.object_proto;
                                // Set .constructor on the prototype object
                                HString* constr_key = (HString*)vm.heap.strs[heap::BuiltinStr.CONSTRUCTOR];
                                TVal constr_val;
                                constr_val.set_object(func_obj);
                                proto_obj.put_prop(constr_key, constr_val, hobject::PROP_FLAGS_WEC);
                            }
                            // Set .prototype on the function
                            HString* proto_key = (HString*)vm.heap.strs[heap::BuiltinStr.PROTOTYPE];
                            TVal proto_tv;
                            proto_tv.set_object(proto_obj);
                            func_obj.put_prop(proto_key, proto_tv, proto_pflags);
                        }
                    }

                    ra.set_object(func_obj);
                    track_heap_store(ds.act, ra, (uint)insn.a);
                } else {
                    ra.set_undefined();
                }
            } else {
                ra.set_undefined();
            }
            return (TVal){};
        }

        case Opcode.GETBOUND: {
            uint bc = insn.get_bc();
            // Constants[bc] = FASTINT depth, ds.constants[bc+1] = STRING name
            if (bc + 1 < vm.current_func.const_count) {
                TVal depth_val = ds.constants[bc];
                TVal name_val = ds.constants[bc + 1];
                if ((depth_val.is_fastint() || depth_val.is_number()) && name_val.is_string()) {
                    uint depth = (uint)(depth_val.is_fastint() ? depth_val.get_fastint() : (long)depth_val.get_number());
                    void* key = name_val.get_heapptr();
                    TVal? result = env::env_get_at_depth(ds.act.lex_env, depth, key);
                    if (try v = result) {
                        vm.heap.tval_copy_ref(ra, &v);
                        track_heap_store(ds.act, ra, (uint)insn.a);
                    } else {
                        // Also check var_env if different
                        if (ds.act.lex_env != ds.act.var_env) {
                            result = env::env_get_at_depth(ds.act.var_env, depth, key);
                            if (try v2 = result) {
                                vm.heap.tval_copy_ref(ra, &v2);
                                track_heap_store(ds.act, ra, (uint)insn.a);
                                break;
                            }
                        }
                        ra.set_undefined();
                    }
                } else {
                    ra.set_undefined();
                }
            } else {
                ra.set_undefined();
            }
            return (TVal){};
        }

        default:
            return (TVal){};
    }
    return (TVal){};
}

/// Sub-dispatch for INITFOR, NEXTFOR opcodes.
fn TVal? dispatch_iterator(Dispatch* ds, Opcode op, TVal* ra, TVal* rb, TVal* rc, Instruction insn) {
    Vm* vm = ds.vm;
    switch (op) {
        case Opcode.INITFOR: {
            // ra = object to enumerate, rb = iter_state (output)
            // null/undefined → skip loop (rb = null marker)
            if (ra.is_null() || ra.is_undefined()) {
                rb.set_null();
                break;
            }

            // Get the object (ToObject for primitives)
            HObject* obj;
            if (ra.is_object()) {
                obj = (HObject*)ra.get_heapptr();
            } else if (ra.is_boolean()) {
                HObject*? wrapped = vm.heap.alloc_object(hobject::ObjClass.BOOLEAN);
                if (catch _err = wrapped) { rb.set_null(); break; }
                obj = wrapped;
                obj.prototype = vm.heap.bool_proto;
                (*obj.extra_ptr()).prim.primitive_value.set_boolean(ra.get_boolean());
            } else if (ra.is_string()) {
                HObject*? wrapped = vm.heap.alloc_object(hobject::ObjClass.STRING);
                if (catch _err = wrapped) { rb.set_null(); break; }
                obj = wrapped;
                obj.flags.exotic_stringobj = true;
                obj.prototype = vm.heap.string_proto;
                HString* prim_str = (HString*)ra.get_heapptr();
                (*obj.extra_ptr()).prim.primitive_value.set_string(prim_str);
                // Set .length own property (ES5 §15.5.5.1) — non-writable, non-enumerable, non-configurable.
                // Indexed character properties are served lazily via exotic_stringobj during enumeration.
                HString* len_key = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
                TVal len_tv;
                len_tv.set_fastint((long)prim_str.char_length());
                obj.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NNC);
            } else if (ra.is_number() || ra.is_fastint()) {
                HObject*? wrapped = vm.heap.alloc_object(hobject::ObjClass.NUMBER);
                if (catch _err = wrapped) { rb.set_null(); break; }
                obj = wrapped;
                obj.prototype = vm.heap.number_proto;
                vm.heap.tval_copy_ref(&(*obj.extra_ptr()).prim.primitive_value, ra);
            } else {
                rb.set_null();
                break;
            }

            // Collect enumerable keys
            ForInState* state = collect_forin_keys(vm, obj);
            if (state == null) {
                rb.set_null();
                break;
            }
            rb.set_pointer(state);
            return (TVal){};
        }

        case Opcode.NEXTFOR: {
            // ra = iter_var (output key), rb = has_next (output bool)
            // rc = iter_state (input ForInState*)
            ForInState* state = (ForInState*)rc.get_heapptr();
            if (state == null || state.index >= state.count) {
                // No more keys — clean up and signal done
                if (state != null) {
                    vm.heap.free_func(vm.heap.heap_udata, state.keys);
                    vm.heap.free_func(vm.heap.heap_udata, state);
                }
                rb.set_boolean(false);
                ra.set_undefined();
                break;
            }

            // Return the next key
            vm.heap.set_reg_string(ra, state.keys[state.index]);
            state.index++;
            rb.set_boolean(true);
            return (TVal){};
        }

        default:
            return (TVal){};
    }
    return (TVal){};
}

/// Sub-dispatch for TRY, ENDTRY, THROW, CATCH, FINALLY, ENDFINALLY opcodes.
fn TVal? dispatch_exceptions(Dispatch* ds, Opcode op, TVal* ra, TVal* rb, TVal* rc, Instruction insn) {
    Vm* vm = ds.vm;
    switch (op) {
        case Opcode.TRY: {
            // Encoding: A = flags (bit0=catch, bit1=finally)
            //           BC = catch_offset (from TRY PC to CATCH instruction)
            // The next instruction word stores finally_offset in its BC field.
            uint flags = insn.a;
            uint catch_offset = insn.get_bc();

            // Read the jump slot (next instruction word) for finally_offset
            Instruction jump_slot = *ds.curr_pc;
            ds.curr_pc++;
            ds.act.curr_pc = ds.curr_pc;
            uint finally_offset = jump_slot.get_bc(); // BC field stores finally offset

            // Compute absolute handler PCs
            Instruction* base_pc = ds.curr_pc - 2; // back to TRY instruction
            Instruction* catch_pc = base_pc + (int)catch_offset;
            Instruction* finally_pc = (finally_offset != 0)
                ? (base_pc + (int)finally_offset)
                : null;

            // Allocate catcher
            Catcher* cat = (Catcher*)vm.heap.alloc_func(vm.heap.heap_udata, Catcher::size);
            if (cat == null) {
                // Out of memory — skip catcher creation, try block will run unprotected
                break;
            }
            cat.parent = (Catcher*)ds.act.cat;
            cat.flags = flags;
            cat.thrown_val.set_undefined();
            cat.catch_pc = catch_pc;
            cat.finally_pc = finally_pc;

            ds.act.cat = (void*)cat;
            return (TVal){};
        }

        case Opcode.ENDTRY: {
            // Pop the catcher (normal exit from try block)
            Catcher* cat = (Catcher*)ds.act.cat;
            if (cat != null) {
                ds.act.cat = (void*)cat.parent;
                vm.heap.free_func(vm.heap.heap_udata, cat);
            }
            return (TVal){};
        }

        case Opcode.THROW: {
            TVal thrown_val = *ra;
            if (!vm_throw_value(vm, thrown_val, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                vm.has_error = true;
                vm.heap.has_error = true;
                vm.heap.tval_copy_ref(&vm.heap.error_value, &thrown_val);
                vm.heap.tval_copy_ref(&vm.return_val, &thrown_val);
                return VM_ERROR~;
            }
            return (TVal){};
        }

        case Opcode.CATCH: {
            // Read the thrown exception from the nearest catcher
            Catcher* cat = (Catcher*)ds.act.cat;
            if (cat != null) {
                vm.heap.tval_copy_ref(ra, &cat.thrown_val);
                track_heap_store(ds.act, ra, (uint)insn.a);

                // Clear thrown value
                cat.thrown_val.set_undefined();

                // Clear VM-level error flags — the throw has been caught.
                // Without this, a phantom vm.has_error from a deep throw
                // persists and causes phantom errors in subsequent call_fn
                // invocations (e.g., ToPrimitive valueOf/toString).
                vm.has_error = false;
                vm.heap.has_error = false;

                // If no finally handler, pop the catcher now.
                // If there IS a finally, keep the catcher on the chain so that
                // re-throws in the catch block are handled by the finally handler.
                if (cat.finally_pc == null) {
                    ds.act.cat = (void*)cat.parent;
                    vm.heap.free_func(vm.heap.heap_udata, cat);
                }
            } else {
                ra.set_undefined();
            }
            return (TVal){};
        }

        case Opcode.FINALLY:
            // No-op marker — the catcher's finally_pc points here.
            // When entered via normal fall-through (after catch or via jump),
            // there may or may not be a catcher on the chain.
            // Mark the catcher as "in finally" so that vm_throw_value skips it
            // if a throw occurs inside the finally block (prevents infinite loop).
            {
                Catcher* fin_cat = (Catcher*)ds.act.cat;
                if (fin_cat != null) {
                    fin_cat.flags |= CATCHER_FLAG_IN_FINALLY;
                }
            }
            return (TVal){};

        case Opcode.ENDFINALLY: {
            Catcher* cat = (Catcher*)ds.act.cat;
            if (cat != null && (cat.flags & CATCHER_FLAG_FINALLY_ENABLED) != 0) {
                // Save pending state before freeing the catcher
                bool has_pending_exc = (!cat.thrown_val.is_undefined());
                TVal pending_exc_val = cat.thrown_val;
                bool has_pending_ret = (cat.flags & CATCHER_FLAG_PENDING_RETURN) != 0;
                TVal saved_ret_val = cat.return_val;
                bool has_pending_break = (cat.flags & CATCHER_FLAG_PENDING_BREAK) != 0;
                bool has_pending_continue = (cat.flags & CATCHER_FLAG_PENDING_CONTINUE) != 0;
                Instruction* saved_pending_pc = cat.pending_pc;
                Catcher* parent_cat = (Catcher*)cat.parent;

                // Pop the finally catcher
                ds.act.cat = (void*)parent_cat;
                vm.heap.free_func(vm.heap.heap_udata, cat);

                if (has_pending_ret) {
                    // Check if the parent catcher also has a finally — if so,
                    // propagate the pending return through it before completing.
                    if (parent_cat != null && parent_cat.finally_pc != null
                        && (parent_cat.flags & CATCHER_FLAG_FINALLY_ENABLED) != 0) {
                        parent_cat.return_val = saved_ret_val;
                        parent_cat.flags |= CATCHER_FLAG_PENDING_RETURN;
                        ds.curr_pc = parent_cat.finally_pc;
                        ds.act.curr_pc = ds.curr_pc;
                        break;
                    }
                    // Complete the return that was intercepted by the finally block.
                    TVal val = saved_ret_val;
                    Activation* callee_act = &vm.activations[vm.activation_count - 1];
                    TVal* callee_result = callee_act.retval;

                    bool val_pinned = false;
                    if (val.is_heap_allocated() && val.get_heapptr() != null) {
                        ((HeapHeader*)val.get_heapptr()).incref();
                        val_pinned = true;
                    }

                    decref_callee_regs(vm, callee_act);

                    vm.activation_count--;

                    if (vm.activation_count == 0) {
                        vm.heap.tval_copy_ref(&vm.return_val, &val);
                        if (val_pinned) vm.heap.decref_tval(&val);
                        return vm.return_val;
                    }
                    if (callee_result != null) {
                        if (!val.is_heap_allocated()) {
                            if (callee_result.is_heap_allocated()) {
                                vm.heap.decref_tval(callee_result);
                            }
                            *callee_result = val;
                        } else if (val_pinned) {
                            vm.heap.decref_tval(callee_result);
                            *callee_result = val;
                            val_pinned = false;
                        } else {
                            vm.heap.tval_copy_ref(callee_result, &val);
                        }
                    }
                    if (val_pinned) vm.heap.decref_tval(&val);
                    ds.act = &vm.activations[vm.activation_count - 1];
                    vm.valstack_bottom = ds.act.bottom;
                    vm.valstack_top = ds.act.caller_valstack_top;
                    CompiledFunction* caller_func = (CompiledFunction*)ds.act.func;
                    if (caller_func != vm.current_func) {
                        vm.current_func = caller_func;
                        ds.code_base = caller_func.code;
                        ds.code_count = caller_func.code_count;
                        ds.code_end = ds.code_base + ds.code_count;
                        ds.constants = caller_func.constants;
                        ds.ic_base = (hobject::ICEntry*)caller_func.ic_entries;
                        ds.var_ic_base = (hobject::VarICEntry*)caller_func.var_ic_entries;
                        ds.nregs = caller_func.num_regs;
                    }
                    ds.curr_pc = ds.act.curr_pc;
                    ds.regs_base = ds.act.bottom;
                    break;
                }

                if (has_pending_break || has_pending_continue) {
                    // Check if the parent catcher also has a finally — if so,
                    // propagate the pending break/continue through it first.
                    if (parent_cat != null && parent_cat.finally_pc != null
                        && (parent_cat.flags & CATCHER_FLAG_FINALLY_ENABLED) != 0) {
                        parent_cat.pending_pc = saved_pending_pc;
                        if (has_pending_break) {
                            parent_cat.flags |= CATCHER_FLAG_PENDING_BREAK;
                        } else {
                            parent_cat.flags |= CATCHER_FLAG_PENDING_CONTINUE;
                        }
                        ds.curr_pc = parent_cat.finally_pc;
                        ds.act.curr_pc = ds.curr_pc;
                        break;
                    }
                    // All finally blocks have run — complete the break/continue
                    // by jumping to the saved target.
                    ds.curr_pc = saved_pending_pc;
                    ds.act.curr_pc = ds.curr_pc;
                    break;
                }

                if (has_pending_exc) {
                    // Re-throw the pending exception
                    if (!vm_throw_value(vm, pending_exc_val, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return vm_uncaught_error(vm, &pending_exc_val);
                    }
                }
            }
            return (TVal){};
        }

        default:
            return (TVal){};
    }
    return (TVal){};
}

/// Sub-dispatch for NOP, DEBUGGER, BREAK, CONTINUE, INITGET, INITSET, INITSETI, CSVARI, PUSH_LEX, POP_LEX, REQUIRE_OBJ opcodes.
fn TVal? dispatch_misc(Dispatch* ds, Opcode op, TVal* ra, TVal* rb, TVal* rc, Instruction insn) {
    Vm* vm = ds.vm;
    switch (op) {
        case Opcode.NOP:
            return (TVal){};

        case Opcode.DEBUGGER:
            return (TVal){};

        case Opcode.BREAK:
        case Opcode.CONTINUE: {
            // Compute the jump target from the signed 24-bit offset
            int sabc = insn.get_sabc();
            int target = (int)((long)(ds.curr_pc - ds.code_base) + (long)sabc);
            Instruction* target_pc = ds.code_base + target;

            // Check if any active catcher has a finally handler that
            // would be bypassed by this jump.  If so, save the target
            // and redirect to the finally handler.
            Catcher* bc_cat = (Catcher*)ds.act.cat;
            if (bc_cat != null && bc_cat.finally_pc != null
                && (bc_cat.flags & CATCHER_FLAG_FINALLY_ENABLED) != 0) {
                // Save the pending jump target and flag on the catcher
                bc_cat.pending_pc = target_pc;
                if (insn.op == Opcode.BREAK) {
                    bc_cat.flags |= CATCHER_FLAG_PENDING_BREAK;
                } else {
                    bc_cat.flags |= CATCHER_FLAG_PENDING_CONTINUE;
                }
                // Jump to the finally handler
                ds.curr_pc = bc_cat.finally_pc;
                ds.act.curr_pc = ds.curr_pc;
                break;
            }
            // No active finally handler — jump directly to target
            if (target < (ds.curr_pc - ds.code_base)) {
                if (--vm.heap.bwd_gc_budget == 0) {
                    if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); }
                    vm.heap.bwd_gc_budget = heap::BWD_GC_INTERVAL;
                }
            }
            ds.curr_pc = target_pc;
            return (TVal){};
        }

        case Opcode.INITGET: {
            // A=object, B=key, C=getter_function
            // Define a getter accessor property on object A with key B.
            if (ra.is_object()) {
                HObject* hobj = (HObject*)ra.get_heapptr();
                void* key = get_prop_key(vm, rb);
                TVal getter_val = *rc;
                if (key != null && hobj != null) {
                    // Check if property already exists as accessor
                    int idx = hobj.find_prop_idx(key);
                    TVal* initget_props = hobj.prop_values();
                    if (idx >= 0 && hobj.get_prop_flags((uint)idx).is_accessor) {
                        // Update existing accessor's getter
                        hobject::hobject_set_access_getter(initget_props[idx], getter_val, vm.heap);
                    } else {
                        // Create new accessor property
                        TVal undef;
                        undef.set_undefined();
                        hobj.put_prop(key, hobject::hobject_create_accessors(vm.heap, getter_val, undef), hobject::PROP_FLAGS_ACCESSOR);
                    }
                }
            }
            return (TVal){};
        }

        case Opcode.INITSET: {
            // A=object, B=key, C=setter_function
            // Define a setter accessor property on object A with key B.
            if (ra.is_object()) {
                HObject* hobj = (HObject*)ra.get_heapptr();
                void* key = get_prop_key(vm, rb);
                TVal setter_val = *rc;
                if (key != null && hobj != null) {
                    // Check if property already exists as accessor
                    int idx = hobj.find_prop_idx(key);
                    TVal* initset_props = hobj.prop_values();
                    if (idx >= 0 && hobj.get_prop_flags((uint)idx).is_accessor) {
                        // Update existing accessor's setter
                        hobject::hobject_set_access_setter(initset_props[idx], setter_val, vm.heap);
                    } else {
                        // Create new accessor property
                        TVal undef;
                        undef.set_undefined();
                        hobj.put_prop(key, hobject::hobject_create_accessors(vm.heap, undef, setter_val), hobject::PROP_FLAGS_ACCESSOR);
                    }
                }
            }
            return (TVal){};
        }

        case Opcode.INITSETI:
            return (TVal){};

        case Opcode.CSVARI:
            return (TVal){};

        // === WITH STATEMENT REMOVED IN STRICT-ONLY MODE ===

        case Opcode.PUSH_LEX: {
            // Push a new declarative environment record onto ds.act.lex_env.
            EnvRecord*? env_raw = env::env_create_declarative(vm.heap, ds.act.lex_env);
            if (try new_env = env_raw) {
                ds.act.lex_env = new_env;
            } else {
                return VM_ERROR~;
            }
            return (TVal){};
        }

        case Opcode.POP_LEX: {
            // Pop the current lexical environment from the scope chain.
            if (ds.act.lex_env != null && ds.act.lex_env.parent != null) {
                ds.act.lex_env = ds.act.lex_env.parent;
            }
            return (TVal){};
        }

        case Opcode.REQUIRE_OBJ: {
            // Throw TypeError if the value in register A is null or undefined.
            // Used for object destructuring pattern null/undefined check.
            if (ra.is_null() || ra.is_undefined()) {
                HObject*? err_raw = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                if (try err = err_raw) {
                    err.prototype = vm.heap.type_err_proto;
                    char[types::ERROR_MSG_BUF] buf;
                    int len = libc::snprintf(&buf, types::ERROR_MSG_BUF,
                        "Cannot destructure '%s'",
                        (ra.is_null() ? "null" : "undefined"));
                    if (len > 0 && len < types::ERROR_MSG_BUF) {
                        HString* msg_str = intern_string(vm, buf[:len]);
                        TVal msg_val;
                        msg_val.set_string(msg_str);
                        HString* msg_key = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE];
                        err.put_prop(msg_key, msg_val, hobject::PROP_FLAGS_WEC);
                    }
                    TVal err_tv;
                    err_tv.set_object(err);
                    if (!vm_throw_value(vm, err_tv, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        return vm_uncaught_error(vm, &err_tv);
                    }
                }
            }
            return (TVal){};
        }

        default:
            return (TVal){};
    }
    return (TVal){};
}


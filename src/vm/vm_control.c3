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

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
// vm_generators — generator opcodes
// ============================================================================
/// Sub-dispatch for LOAD_RESUME, AWAIT, YIELD, YIELD_STAR opcodes.
fn TVal? dispatch_generators(Dispatch* ds, Opcode op, TVal* ra, TVal* rb, TVal* rc, Instruction insn) {
    Vm* vm = ds.vm;
    switch (op) {
        case Opcode.LOAD_RESUME: {
            // LOAD_RESUME A — load the value passed to .next(val) into A.
            // Emitted after YIELD so the yield expression evaluates to the
            // resume value. Also handles throw/return injection: for THROW,
            // call vm_throw_value to find the nearest catcher; for RETURN,
            // mark the generator complete and return to the caller.
            $if $feature(HEAP_VERIFY):
                vm.heap.verify_roots("before_load_resume");
                if (vm.heap.resume_gen != null) {
                    GeneratorState* gs_chk = vm.heap.resume_gen;
                    if (gs_chk.saved_regs != null) {
                        vm.heap.verify_tval_array(gs_chk.saved_regs, gs_chk.num_regs, "load_resume_saved_regs");
                    }
                }
            $endif
            if (vm.heap.resume_gen != null) {
                GeneratorState* gs_lr = vm.heap.resume_gen;
                ResumeKind rk = gs_lr.resume_kind;

                if (rk == THROW) {
                    // Inject exception: find catcher only within the generator activation.
                    // Use local_only=true so we don't mistakenly find the caller's catcher
                    // and then fail to complete the generator (ES6 §25.3.3.4 step 8).
                    TVal throw_val = gs_lr.throw_value;

                    if (!vm_throw_value(vm, throw_val, ds.act, &ds.curr_pc, &ds.needs_restart, true)) {
                        // No catcher in generator/async function.
                        vm.heap.resume_gen = null;
                        gs_lr.state = GEN_COMPLETED;

                        // For async functions: reject the async Promise and return
                        if (gs_lr.async_promise != null) {
                            HObject* async_prom = (HObject*)gs_lr.async_promise;
                            builtins::promise_settle(async_prom, builtins::PROMISE_REJECTED, &throw_val, vm.heap);
                            builtins::promise_trigger_reactions(async_prom, vm.heap, (void*)vm);
                            // Pop the single activation and return undefined
                            decref_callee_regs(vm, ds.act);
                            vm.activation_count--;
                            TVal undef_val;
                            undef_val.set_undefined();
                            vm.heap.tval_copy_ref(&vm.return_val, &undef_val);
                            ds.halt = true;
                            ds.halt_value = vm.return_val;
                            return (TVal){};
                        }

                        // Generator path: pop activation and propagate error
                        if (vm.activation_count > 0) {
                            vm.activation_count--;
                            if (vm.activation_count > 0) {
                                Activation* caller_act = &vm.activations[vm.activation_count - 1];
                                vm.valstack_bottom = caller_act.bottom;
                                if (caller_act.func != null) {
                                    CompiledFunction* caller_func = (CompiledFunction*)caller_act.func;
                                    vm.valstack_top = caller_act.bottom + caller_func.num_regs;
                                }

                                // Try to find a catcher in the caller's chain
                                if (!vm_throw_value(vm, throw_val, caller_act,
                                                    &caller_act.curr_pc, &ds.needs_restart)) {
                                    // Unhandled — set error for the VM to return
                                    vm.has_error = true;
                                    vm.heap.has_error = true;
                                    if (caller_act.retval != null) {
                                        vm.heap.tval_copy_ref(caller_act.retval, &throw_val);
                                    }
                                }
                            }
                        }
                    } else {
                        // Catcher found in generator — the exception will be caught.
                        // Keep resume_gen set but switch to NEXT so the next YIELD
                        // properly saves state and sets gs.state = GEN_SUSPENDED_YIELD.
                        gs_lr.resume_kind = NEXT;
                        gs_lr.resume_value.set_undefined();
                    }
                    ds.needs_restart = true;
                    return (TVal){};
                }

                if (rk == RETURN) {
                    // Inject return: mark generator complete, return to caller
                    TVal ret_val_raw = gs_lr.return_value;
                    gs_lr.state = GEN_COMPLETED;
                    gs_lr.resume_kind = NEXT;
                    vm.heap.resume_gen = null;

                    // Wrap in IteratorResult {value: ret_val, done: true}
                    HObject*? robj_raw2 = vm.heap.alloc_object(hobject::ObjClass.OBJECT);
                    TVal ret_val;
                    if (try robj2 = robj_raw2) {
                        robj2.prototype = vm.heap.object_proto;
                        HString* val_key2 = (HString*)vm.heap.strs[heap::BuiltinStr.VALUE];
                        if (val_key2 != null) robj2.put_prop(val_key2, ret_val_raw, hobject::PROP_FLAGS_WEC);
                        HString* done_key2 = (HString*)vm.heap.strs[heap::BuiltinStr.DONE];
                        TVal done_val2;
                        done_val2.set_boolean(true);
                        if (done_key2 != null) robj2.put_prop(done_key2, done_val2, hobject::PROP_FLAGS_WEC);
                        ret_val.set_object(robj2);
                    } else {
                        ret_val = ret_val_raw;
                    }

                    // Pop the generator activation
                    if (vm.activation_count > 0) {
                        Activation* gen_act = &vm.activations[vm.activation_count - 1];
                        TVal* ret_byteoff = gen_act.retval;
                        vm.activation_count--;
                        if (vm.activation_count > 0) {
                            Activation* caller_act = &vm.activations[vm.activation_count - 1];
                            vm.valstack_bottom = caller_act.bottom;
                            if (caller_act.func != null) {
                                CompiledFunction* caller_func = (CompiledFunction*)caller_act.func;
                                vm.valstack_top = caller_act.bottom + caller_func.num_regs;
                            }

                            if (ret_byteoff != null) {
                                vm.heap.tval_copy_ref(ret_byteoff, &ret_val);
                            }
                        }
                    }
                    ds.needs_restart = true;
                    return (TVal){};
                }

                // Normal NEXT — load resume value
                vm.heap.tval_copy_ref(&ra[0], &gs_lr.resume_value);
            }
            // If resume_gen is null (e.g., after AWAIT with non-thenable),
            // don't overwrite the register — the value is already correct.
            return (TVal){};
        }

        case Opcode.AWAIT: {
            // AWAIT A — await the value in register A.
            // If the value is not a thenable, continue (no-op).
            // If the value is a settled Promise, extract the result.
            // If the value is a pending Promise, suspend and resume later.
            TVal await_val = ra[0];

            // Not an object → not a thenable, continue
            if (!await_val.is_object() || await_val.get_heapptr() == null) {
                return (TVal){};
            }

            HObject* await_obj = (HObject*)await_val.get_heapptr();

            // Non-Promise thenable: wrap in a Promise via the thenable protocol
            if (await_obj.flags.obj_class != hobject::ObjClass.PROMISE) {
                HObject*? wrapper_raw = builtins::promise_coerce_thenable(vm.heap, await_val, (void*)vm);
                if (try HObject* wrapper = wrapper_raw) {
                    if (wrapper != null) {
                        await_val.set_object(wrapper);
                        await_obj = wrapper;
                    } else {
                        // Not a thenable: await is a no-op for plain objects
                        return (TVal){};
                    }
                } else {
                    // Not a thenable (fault)
                    return (TVal){};
                }
            }

            // Check if it's a Promise
            if (await_obj.flags.obj_class == hobject::ObjClass.PROMISE) {
                uint pstate = builtins::promise_get_state(await_obj, 0);
                if (pstate == builtins::PROMISE_FULFILLED) {
                    // Fulfilled: extract the value into the register
                    TVal result = builtins::promise_get_result(await_obj);
                    vm.heap.tval_copy_ref(&ra[0], &result);
                    return (TVal){};
                }
                if (pstate == builtins::PROMISE_REJECTED) {
                    // Rejected: throw the rejection reason.
                    // If caught by try/catch, execution continues; otherwise
                    // the error propagates (rejecting the async Promise if applicable).
                    TVal reason = builtins::promise_get_result(await_obj);
                    if (!vm_throw_value(vm, reason, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                        // No catcher — if async, reject the outer Promise
                        if ((ds.act.flags & ACT_FLAG_ASYNC) != 0 && ds.act.async_promise != null) {
                            builtins::promise_settle(ds.act.async_promise, builtins::PROMISE_REJECTED, &reason, vm.heap);
                            builtins::promise_trigger_reactions(ds.act.async_promise, vm.heap, (void*)vm);
                            decref_callee_regs(vm, ds.act);
                            vm.activation_count--;
                            if (vm.activation_count == 0) {
                                TVal undef_val;
                                undef_val.set_undefined();
                                vm.heap.tval_copy_ref(&vm.return_val, &undef_val);
                                ds.halt = true;
                                ds.halt_value = vm.return_val;
                                return (TVal){};
                            }
                            ds.act = &vm.activations[vm.activation_count - 1];
                            vm.valstack_bottom = ds.act.bottom;
                            vm.valstack_top = ds.act.caller_valstack_top;
                            CompiledFunction* caller_f = (CompiledFunction*)ds.act.func;
                            if (caller_f != vm.current_func) {
                                vm.current_func = caller_f;
                                ds.code_base = caller_f.code;
                                ds.code_count = caller_f.code_count;
                                ds.code_end = ds.code_base + ds.code_count;
                                ds.constants = caller_f.constants;
                                ds.ic_base = (hobject::ICEntry*)caller_f.ic_entries;
                                ds.var_ic_base = (hobject::VarICEntry*)caller_f.var_ic_entries;
                                ds.nregs = caller_f.num_regs;
                            }
                            ds.curr_pc = ds.act.curr_pc;
                            ds.regs_base = ds.act.bottom;
                        } else {
                            // Not async — propagate error to caller
                            vm.has_error = true;
                            vm.heap.has_error = true;
                        }
                    }
                    ds.needs_restart = true;
                    return (TVal){};
                }
                // Pending (pstate == 0): fall through to suspension below

                // Pending Promise: suspend the async function
                // 1. Allocate GeneratorState for saving execution state
                void* gs_raw = vm.heap.alloc_func(vm.heap.heap_udata, GeneratorState::size);
                if (gs_raw == null) break;
                GeneratorState* gs = (GeneratorState*)gs_raw;
                libc::memset(gs_raw, 0, GeneratorState::size);

                CompiledFunction* cur_func = (CompiledFunction*)ds.act.func;

                gs.state = GEN_SUSPENDED_YIELD;
                gs.func = ds.act.func;
                gs.num_regs = cur_func.num_regs;
                gs.saved_pc = ds.curr_pc; // PC after AWAIT (points to LOAD_RESUME)
                gs.var_env = ds.act.var_env;
                gs.lex_env = ds.act.lex_env;
                gs.cat = ds.act.cat;
                vm.heap.tval_copy_ref(&gs.this_binding, &ds.act.this_binding);
                gs.async_promise = (void*)ds.act.async_promise;
                usz regs_bytes = (usz)gs.num_regs * TVal::size;
                void* regs_mem = vm.heap.alloc_func(vm.heap.heap_udata, regs_bytes);
                if (regs_mem == null) {
                    vm.heap.free_func(vm.heap.heap_udata, gs_raw);
                    return (TVal){};
                }
                gs.saved_regs = (TVal*)regs_mem;
                libc::memset(regs_mem, 0, regs_bytes);
                TVal* regs_src = ds.act.bottom;
                for (uint i = 0; i < gs.num_regs; i++) {
                    vm.heap.tval_copy_ref(&gs.saved_regs[i], &regs_src[i]);
                }

                $if $feature(HEAP_VERIFY):
                    vm.heap.verify_roots("after_await_save");
                    vm.heap.verify_tval_array(gs.saved_regs, gs.num_regs, "await_saved_regs");
                $endif

                // 2. Create resume callback (builtin)
                HObject*? resume_raw = vm.heap.alloc_object(hobject::ObjClass.FUNCTION);
                if (catch _e1 = resume_raw) {
                    vm.heap.free_func(vm.heap.heap_udata, gs.saved_regs);
                    vm.heap.free_func(vm.heap.heap_udata, gs_raw);
                    return (TVal){};
                }
                HObject* resume_fn = resume_raw;
                (*resume_fn.extra_ptr()).func.builtin_fn_index = (int)builtins::BUILTIN_ASYNC_RESUME;
                (*resume_fn.extra_ptr()).func.var_env = (EnvRecord*)gs;
                TVal resume_tv;
                resume_tv.set_object(resume_fn);

                // 3. Create reject callback (builtin)
                HObject*? reject_raw = vm.heap.alloc_object(hobject::ObjClass.FUNCTION);
                if (catch _e2 = reject_raw) {
                    return (TVal){};
                }
                HObject* reject_fn = reject_raw;
                (*reject_fn.extra_ptr()).func.builtin_fn_index = (int)builtins::BUILTIN_ASYNC_REJECT;
                (*reject_fn.extra_ptr()).func.var_env = (EnvRecord*)gs;
                TVal reject_tv;
                reject_tv.set_object(reject_fn);

                // 4. Create reaction and add to the pending Promise
                HObject*? rxn_raw = vm.heap.alloc_object(hobject::ObjClass.OBJECT);
                if (catch _e3 = rxn_raw) {
                    return (TVal){};
                }
                HObject* rxn = rxn_raw;
                rxn.prototype = vm.heap.object_proto;
                HString* ff_key = builtins::builtin_intern_string(vm.heap, "onFulfilled");
                HString* rj_key = builtins::builtin_intern_string(vm.heap, "onRejected");
                if (ff_key != null) rxn.put_prop(ff_key, resume_tv, hobject::PROP_FLAGS_WEC);
                if (rj_key != null) rxn.put_prop(rj_key, reject_tv, hobject::PROP_FLAGS_WEC);
                builtins::promise_add_reaction(await_obj, rxn, vm.heap);

                // 5. Pop activation (suspend the async function)
                decref_callee_regs(vm, ds.act);
                vm.activation_count--;
                if (vm.activation_count == 0) {
                    TVal undef_val2;
                    undef_val2.set_undefined();
                    vm.heap.tval_copy_ref(&vm.return_val, &undef_val2);
                    ds.halt = true;
                    ds.halt_value = vm.return_val;
                    return (TVal){};
                }

                // Restore caller state
                if (vm.activation_count > 0) {
                    ds.act = &vm.activations[vm.activation_count - 1];
                    vm.valstack_bottom = ds.act.bottom;
                    vm.valstack_top = ds.act.caller_valstack_top;
                    CompiledFunction* caller_f = (CompiledFunction*)ds.act.func;
                    if (caller_f != vm.current_func) {
                        vm.current_func = caller_f;
                        ds.code_base = caller_f.code;
                        ds.code_count = caller_f.code_count;
                        ds.code_end = ds.code_base + ds.code_count;
                        ds.constants = caller_f.constants;
                        ds.ic_base = (hobject::ICEntry*)caller_f.ic_entries;
                        ds.var_ic_base = (hobject::VarICEntry*)caller_f.var_ic_entries;
                        ds.nregs = caller_f.num_regs;
                    }
                    ds.curr_pc = ds.act.curr_pc;
                    ds.regs_base = ds.act.bottom;
                }
                ds.needs_restart = true;
                return (TVal){};
            }
            // Non-Promise: continue as-is (TODO: thenable support)
            return (TVal){};
        }

        case Opcode.YIELD: {
            // YIELD A — suspend generator and return {value: A, done: false}
            // heap.resume_gen was set by the .next()/.throw()/.return() builtin
            if (vm.heap.resume_gen != null) {
                GeneratorState* gs = vm.heap.resume_gen;

                // Save current state
                TVal* regs_base_r = ds.act.bottom;
                for (uint i = 0; i < gs.num_regs; i++) {
                    vm.heap.tval_copy_ref(&gs.saved_regs[i], &regs_base_r[i]);
                }
                gs.saved_pc = ds.curr_pc;  // ds.curr_pc already points past YIELD
                gs.var_env = ds.act.var_env;
                gs.lex_env = ds.act.lex_env;
                gs.cat = ds.act.cat;
                vm.heap.tval_copy_ref(&gs.this_binding, &ds.act.this_binding);
                gs.state = GEN_SUSPENDED_YIELD;

                $if $feature(HEAP_VERIFY):
                    vm.heap.verify_roots("after_yield");
                    vm.heap.verify_tval_array(gs.saved_regs, gs.num_regs, "yield_saved_regs");
                $endif

                // Store the yielded value
                vm.heap.tval_copy_ref(&vm.heap.yield_value, &ra[0]);

                // Check resume kind for throw/return injection
                ResumeKind rkind = gs.resume_kind;

                if (rkind == THROW) {
                    // .throw() — inject exception at yield point
                    // Pop activation, set has_error so the outer loop
                    // re-enters the generator with an exception pending
                    vm.heap.resume_gen = null;
                    vm.heap.did_yield = true;

                    if (vm.activation_count > 0) {
                        Activation* yield_act = &vm.activations[vm.activation_count - 1];
                        TVal* ret_byteoff = yield_act.retval;

                        // Write the exception as the result (will be caught by try/catch inside generator)
                        TVal* ret_slot = ret_byteoff;
                        vm.heap.tval_copy_ref(&ret_slot[0], &gs.throw_value);

                        vm.activation_count--;
                        if (vm.activation_count > 0) {
                            Activation* caller_act2 = &vm.activations[vm.activation_count - 1];
                            vm.valstack_bottom = caller_act2.bottom;
                            if (caller_act2.func != null) {
                                CompiledFunction* caller_func2 = (CompiledFunction*)caller_act2.func;
                                vm.valstack_top = caller_act2.bottom + caller_func2.num_regs;
                            }
                        }
                    }
                    ds.needs_restart = true;
                    return (TVal){};
                }

                if (rkind == RETURN) {
                    // .return() — inject return at yield point
                    // Mark generator as completed, return {value: rv, done: true}
                    gs.state = GEN_COMPLETED;
                    vm.heap.resume_gen = null;
                    vm.heap.did_yield = false;

                    HObject*? robj_raw = vm.heap.alloc_object(hobject::ObjClass.OBJECT);
                    TVal wrapped_val;
                    if (try robj = robj_raw) {
                        robj.prototype = vm.heap.object_proto;
                        HString* val_key = (HString*)vm.heap.strs[heap::BuiltinStr.VALUE];
                        if (val_key != null) robj.put_prop(val_key, gs.return_value, hobject::PROP_FLAGS_WEC);
                        HString* done_key = (HString*)vm.heap.strs[heap::BuiltinStr.DONE];
                        TVal done_val;
                        done_val.set_boolean(true);
                        if (done_key != null) robj.put_prop(done_key, done_val, hobject::PROP_FLAGS_WEC);
                        wrapped_val.set_object(robj);
                    } else {
                        wrapped_val = gs.return_value;
                    }

                    if (vm.activation_count > 0) {
                        Activation* yield_act = &vm.activations[vm.activation_count - 1];
                        TVal* ret_byteoff = yield_act.retval;
                        TVal* ret_slot = ret_byteoff;
                        vm.heap.tval_copy_ref(ret_slot, &wrapped_val);

                        vm.activation_count--;
                        if (vm.activation_count > 0) {
                            Activation* caller_act2 = &vm.activations[vm.activation_count - 1];
                            vm.valstack_bottom = caller_act2.bottom;
                            if (caller_act2.func != null) {
                                CompiledFunction* caller_func2 = (CompiledFunction*)caller_act2.func;
                                vm.valstack_top = caller_act2.bottom + caller_func2.num_regs;
                            }
                        }
                    }
                    ds.needs_restart = true;
                    return (TVal){};
                }

                // Normal .next() — clear resume_gen so CALL handler doesn't try to resume again
                vm.heap.resume_gen = null;
            }

            vm.heap.did_yield = true;

            // Store the yielded value for IteratorResult creation below
            vm.heap.tval_copy_ref(&vm.heap.yield_value, &ra[0]);

            // Pop activation and return to caller (the .next() builtin's context)
            if (vm.activation_count > 0) {
                Activation* yield_act = &vm.activations[vm.activation_count - 1];
                TVal* ret_byteoff = yield_act.retval;

                // Create IteratorResult {value: yieldVal, done: false}
                HObject*? result_obj_raw = vm.heap.alloc_object(hobject::ObjClass.OBJECT);
                TVal wrapped_val;
                if (try robj = result_obj_raw) {
                    robj.prototype = vm.heap.object_proto;
                    HString* val_key = (HString*)vm.heap.strs[heap::BuiltinStr.VALUE];
                    if (val_key != null) robj.put_prop(val_key, vm.heap.yield_value, hobject::PROP_FLAGS_WEC);
                    HString* done_key = (HString*)vm.heap.strs[heap::BuiltinStr.DONE];
                    TVal done_val;
                    done_val.set_boolean(false);
                    if (done_key != null) robj.put_prop(done_key, done_val, hobject::PROP_FLAGS_WEC);
                    wrapped_val.set_object(robj);
                } else {
                    wrapped_val = vm.heap.yield_value;
                }

                // Write wrapped result to caller's frame
                TVal* ret_slot = ret_byteoff;
                vm.heap.tval_copy_ref(&ret_slot[0], &wrapped_val);

                vm.activation_count--;
                if (vm.activation_count > 0) {
                    Activation* caller_act2 = &vm.activations[vm.activation_count - 1];
                    vm.valstack_bottom = caller_act2.bottom;
                    if (caller_act2.func != null) {
                        CompiledFunction* caller_func2 = (CompiledFunction*)caller_act2.func;
                        vm.valstack_top = caller_act2.bottom + caller_func2.num_regs;
                    }
                }
            }
            ds.needs_restart = true;
            return (TVal){};
        }

        case Opcode.YIELD_STAR: {
            // yield* iterable — delegate to another iterable via the ES6 iterator protocol.
            // A = result_reg, B = iterable_reg, C = 0.
            TVal iterable_val = *rb;
            GeneratorState* gs = vm.heap.resume_gen;
            if (gs == null) { ra[0].set_undefined(); break; }

            HObject* iterator = null;
            TVal received_val;
            received_val.set_undefined();
            bool is_resuming = (gs.delegated_iter != null);

            // State machine: YS_CALL_NEXT → call iterator.next().
            // YS_YIELD → suspend and yield the value in `received_val`.
            const uint YS_CALL_NEXT = 0;
            const uint YS_YIELD     = 1;
            uint ys_state = YS_CALL_NEXT;

            if (is_resuming) {
                iterator = (HObject*)gs.delegated_iter;

                if (gs.resume_kind == THROW) {
                    // ES6 §25.3.2.4 step 3.b: call iterator.throw(exception)
                    HString* throw_key = intern_string(vm, "throw");
                    TVal? throw_opt = iterator.get_prop_proto(throw_key);
                    if (catch err = throw_opt) {
                        // No .throw() — propagate the exception
                        gs.resume_kind = NEXT; gs.resume_value.set_undefined();
                        if (!vm_throw_value(vm, gs.throw_value, ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            gs.delegated_iter = null; gs.state = GEN_COMPLETED;
                            if (vm.activation_count > 0) {
                                Activation* a2 = &vm.activations[vm.activation_count - 1];
                                vm.activation_count--;
                                if (vm.activation_count > 0) {
                                    Activation* ca = &vm.activations[vm.activation_count - 1];
                                    vm.valstack_bottom = ca.bottom;
                                    if (ca.func != null) { CompiledFunction* cf = (CompiledFunction*)ca.func; vm.valstack_top = ca.bottom + cf.num_regs; }
                                    TVal* rb2 = a2.retval;
                                    if (rb2 != null) vm.heap.tval_copy_ref(rb2, &gs.throw_value);
                                }
                            }
                            vm.heap.resume_gen = null;
                        }
                        ds.needs_restart = true; break;
                    }
                    TVal thr_method = throw_opt;
                    TVal itv; itv.set_object(iterator);
                    TVal[1] targs; targs[0] = gs.throw_value;
                    TVal tresult = vm.heap.call_fn(vm, thr_method, &targs, 1, itv);
                    if (vm_check_call_fn_error(vm)) return VM_ERROR~;
                    if (!tresult.is_object() || tresult.get_heapptr() == null) {
                        HObject*? er = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                        if (try e = er) {
                            e.prototype = vm.heap.type_err_proto;
                            HString* ms = intern_string(vm, "IteratorResult is not an object"); TVal mt; mt.set_string(ms);
                            HString* mk = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE]; e.put_prop(mk, mt, hobject::PROP_FLAGS_WEC);
                            TVal ev; ev.set_object(e);
                            if (!vm_throw_value(vm, ev, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &ev);
                        } else { return VM_ERROR~; }
                        ds.needs_restart = true; break;
                    }
                    HObject* tro = (HObject*)tresult.get_heapptr();
                    HString* dk = (HString*)vm.heap.strs[heap::BuiltinStr.DONE];
                    HString* vk = (HString*)vm.heap.strs[heap::BuiltinStr.VALUE];
                    TVal? do_ = tro.get_prop_proto(dk); bool td = false; TVal tv; tv.set_undefined();
                    if (try d = do_) td = builtins::builtin_to_boolean(&d);
                    if (try v = tro.get_prop_proto(vk)) tv = v;
                    gs.resume_kind = NEXT; gs.resume_value.set_undefined();
                    if (td) { gs.delegated_iter = null; vm.heap.tval_copy_ref(&ra[0], &tv); break; }
                    received_val = tv; ys_state = YS_YIELD;
                }
                else if (gs.resume_kind == RETURN) {
                    // ES6 §25.3.2.4 step 3.c: call iterator.return(value)
                    HString* ret_key = intern_string(vm, "return");
                    TVal? ret_opt = iterator.get_prop_proto(ret_key);
                    if (catch err = ret_opt) {
                        // No .return() — complete the generator
                        gs.delegated_iter = null; gs.state = GEN_COMPLETED; vm.heap.resume_gen = null;
                        HObject*? rro = vm.heap.alloc_object(hobject::ObjClass.OBJECT); TVal wrv;
                        if (try ro = rro) {
                            ro.prototype = vm.heap.object_proto;
                            HString* rvk = (HString*)vm.heap.strs[heap::BuiltinStr.VALUE];
                            if (rvk != null) ro.put_prop(rvk, gs.return_value, hobject::PROP_FLAGS_WEC);
                            HString* rdk = (HString*)vm.heap.strs[heap::BuiltinStr.DONE]; TVal rdt; rdt.set_boolean(true);
                            if (rdk != null) ro.put_prop(rdk, rdt, hobject::PROP_FLAGS_WEC); wrv.set_object(ro);
                        } else { wrv = gs.return_value; }
                        if (vm.activation_count > 0) {
                            Activation* ya = &vm.activations[vm.activation_count - 1];
                            vm.heap.tval_copy_ref(ya.retval, &wrv); vm.activation_count--;
                            if (vm.activation_count > 0) {
                                Activation* ca = &vm.activations[vm.activation_count - 1];
                                vm.valstack_bottom = ca.bottom;
                                if (ca.func != null) { CompiledFunction* cf = (CompiledFunction*)ca.func; vm.valstack_top = ca.bottom + cf.num_regs; }
                            }
                        }
                        ds.needs_restart = true; break;
                    }
                    TVal ret_method = ret_opt;
                    TVal itv2; itv2.set_object(iterator);
                    TVal[1] rargs; rargs[0] = gs.return_value;
                    TVal rresult = vm.heap.call_fn(vm, ret_method, &rargs, 1, itv2);
                    if (vm_check_call_fn_error(vm)) return VM_ERROR~;
                    if (!rresult.is_object() || rresult.get_heapptr() == null) {
                        HObject*? er2 = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                        if (try e2 = er2) {
                            e2.prototype = vm.heap.type_err_proto;
                            HString* ms2 = intern_string(vm, "IteratorResult is not an object"); TVal mt2; mt2.set_string(ms2);
                            HString* mk2 = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE]; e2.put_prop(mk2, mt2, hobject::PROP_FLAGS_WEC);
                            TVal ev2; ev2.set_object(e2);
                            if (!vm_throw_value(vm, ev2, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &ev2);
                        } else { return VM_ERROR~; }
                        ds.needs_restart = true; break;
                    }
                    HObject* rro2 = (HObject*)rresult.get_heapptr();
                    HString* dk2 = (HString*)vm.heap.strs[heap::BuiltinStr.DONE];
                    HString* vk2 = (HString*)vm.heap.strs[heap::BuiltinStr.VALUE];
                    TVal? do2 = rro2.get_prop_proto(dk2); bool rd = false; TVal rv; rv.set_undefined();
                    if (try d2 = do2) rd = builtins::builtin_to_boolean(&d2);
                    if (try v2 = rro2.get_prop_proto(vk2)) rv = v2;
                    gs.resume_kind = NEXT; gs.resume_value.set_undefined();
                    if (rd) { gs.delegated_iter = null; vm.heap.tval_copy_ref(&ra[0], &rv); break; }
                    received_val = rv; ys_state = YS_YIELD;
                }
                else {
                    // NEXT resume — use resume value for iterator.next()
                    received_val = gs.resume_value; gs.resume_kind = NEXT; gs.resume_value.set_undefined();
                }
            } else {
                // First entry: get iterator from iterable
                HString* iter_sym = vm.heap.iterator_symbol;
                if (iter_sym == null) iter_sym = builtins::ensure_iterator_symbol(vm.heap);
                if (iter_sym == null) {
                    HString* tstr = typeof_string(vm, &iterable_val);
                    HObject*? er3 = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                    if (try e3 = er3) {
                        e3.prototype = vm.heap.type_err_proto;
                        char[128] buf; int bl = libc::snprintf(&buf, 128, "%s is not iterable", tstr.get_cstr());
                        if (bl > 0 && bl < 128) {
                            HString* ms3 = intern_string(vm, buf[:bl]);
                            if (ms3 != null) {
                                TVal mt3; mt3.set_string(ms3);
                                HString* mk3 = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE]; e3.put_prop(mk3, mt3, hobject::PROP_FLAGS_WEC);
                            }
                        }
                        TVal ev3; ev3.set_object(e3);
                        if (!vm_throw_value(vm, ev3, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &ev3);
                    } else { return VM_ERROR~; }
                    ds.needs_restart = true; break;
                }
                TVal iter_method; bool has_method = false;
                {
                    TVal? mopt;
                    if (iterable_val.is_object() && iterable_val.get_heapptr() != null) {
                        mopt = ((HObject*)iterable_val.get_heapptr()).get_prop_proto(iter_sym);
                    } else if (iterable_val.is_string() && vm.heap.string_proto != null) {
                        mopt = vm.heap.string_proto.get_prop_proto(iter_sym);
                    }
                    if (try m = mopt) {
                        iter_method = m;
                        has_method = iter_method.is_lightfunc() ||
                            (iter_method.is_object() && iter_method.get_heapptr() != null &&
                             ((HObject*)iter_method.get_heapptr()).is_callable());
                    }
                }
                if (!has_method) {
                    HString* tstr2 = typeof_string(vm, &iterable_val);
                    HObject*? er4 = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                    if (try e4 = er4) {
                        e4.prototype = vm.heap.type_err_proto;
                        char[128] buf2; int bl2 = libc::snprintf(&buf2, 128, "%s is not iterable", tstr2.get_cstr());
                        if (bl2 > 0 && bl2 < 128) {
                            HString* ms4 = intern_string(vm, buf2[:bl2]);
                            if (ms4 != null) {
                                TVal mt4; mt4.set_string(ms4);
                                HString* mk4 = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE]; e4.put_prop(mk4, mt4, hobject::PROP_FLAGS_WEC);
                            }
                        }
                        TVal ev4; ev4.set_object(e4);
                        if (!vm_throw_value(vm, ev4, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &ev4);
                    } else { return VM_ERROR~; }
                    ds.needs_restart = true; break;
                }
                TVal itv3 = vm.heap.call_fn(vm, iter_method, null, 0, iterable_val);
                if (vm_check_call_fn_error(vm)) return VM_ERROR~;
                if (!itv3.is_object() || itv3.get_heapptr() == null) { ra[0].set_undefined(); break; }
                iterator = (HObject*)itv3.get_heapptr();
                gs.delegated_iter = iterator;
            }

            // State YS_CALL_NEXT: call iterator.next(received) and check done
            if (ys_state == YS_CALL_NEXT) {
                HString* nk = intern_string(vm, "next");
                TVal? no = iterator.get_prop_proto(nk);
                if (catch err = no) { ra[0].set_undefined(); break; }
                TVal nm = no;
                TVal itv4; itv4.set_object(iterator);
                TVal[1] nargs; nargs[0] = received_val;
                TVal nres = vm.heap.call_fn(vm, nm, &nargs, 1, itv4);
                if (vm_check_call_fn_error(vm)) return VM_ERROR~;
                if (!nres.is_object() || nres.get_heapptr() == null) {
                    HObject*? er5 = vm.heap.alloc_object(hobject::ObjClass.ERROR);
                    if (try e5 = er5) {
                        e5.prototype = vm.heap.type_err_proto;
                        HString* ms5 = intern_string(vm, "IteratorResult is not an object"); TVal mt5; mt5.set_string(ms5);
                        HString* mk5 = (HString*)vm.heap.strs[heap::BuiltinStr.MESSAGE]; e5.put_prop(mk5, mt5, hobject::PROP_FLAGS_WEC);
                        TVal ev5; ev5.set_object(e5);
                        if (!vm_throw_value(vm, ev5, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &ev5);
                    } else { return VM_ERROR~; }
                    ds.needs_restart = true; break;
                }
                HObject* nro = (HObject*)nres.get_heapptr();
                HString* dk3 = (HString*)vm.heap.strs[heap::BuiltinStr.DONE];
                HString* vk3 = (HString*)vm.heap.strs[heap::BuiltinStr.VALUE];
                TVal? do3 = nro.get_prop_proto(dk3); bool nd = false; TVal nv; nv.set_undefined();
                if (try d3 = do3) nd = builtins::builtin_to_boolean(&d3);
                if (try v3 = nro.get_prop_proto(vk3)) nv = v3;
                if (nd) {
                    gs.delegated_iter = null; gs.resume_kind = NEXT; gs.resume_value.set_undefined();
                    vm.heap.tval_copy_ref(&ra[0], &nv); break;
                }
                received_val = nv; ys_state = YS_YIELD;
            }

            // State YS_YIELD: suspend the generator and yield received_val
            if (ys_state == YS_YIELD) {
                for (uint i = 0; i < gs.num_regs; i++) {
                    vm.heap.tval_copy_ref(&gs.saved_regs[i], &ds.act.bottom[i]);
                }
                gs.saved_pc = ds.curr_pc - 1;
                gs.var_env = ds.act.var_env; gs.lex_env = ds.act.lex_env; gs.cat = ds.act.cat;
                vm.heap.tval_copy_ref(&gs.this_binding, &ds.act.this_binding);
                gs.state = GEN_SUSPENDED_YIELD;
                $if $feature(HEAP_VERIFY):
                    vm.heap.verify_roots("after_yield_star");
                    vm.heap.verify_tval_array(gs.saved_regs, gs.num_regs, "yield_star_saved_regs");
                $endif
                vm.heap.tval_copy_ref(&vm.heap.yield_value, &received_val);
                vm.heap.resume_gen = null; vm.heap.did_yield = true;
                if (vm.activation_count > 0) {
                    Activation* p_act = &vm.activations[vm.activation_count - 1];
                    TVal* p_ret = p_act.retval;
                    HObject*? p_robj_raw = vm.heap.alloc_object(hobject::ObjClass.OBJECT); TVal p_wrapped;
                    if (try p_robj = p_robj_raw) {
                        p_robj.prototype = vm.heap.object_proto;
                        HString* p_vk = (HString*)vm.heap.strs[heap::BuiltinStr.VALUE];
                        if (p_vk != null) p_robj.put_prop(p_vk, vm.heap.yield_value, hobject::PROP_FLAGS_WEC);
                        HString* p_dk = (HString*)vm.heap.strs[heap::BuiltinStr.DONE]; TVal p_dt; p_dt.set_boolean(false);
                        if (p_dk != null) p_robj.put_prop(p_dk, p_dt, hobject::PROP_FLAGS_WEC); p_wrapped.set_object(p_robj);
                    } else { p_wrapped = vm.heap.yield_value; }
                    vm.heap.tval_copy_ref(&p_ret[0], &p_wrapped);
                    vm.activation_count--;
                    if (vm.activation_count > 0) {
                        Activation* p_caller = &vm.activations[vm.activation_count - 1];
                        vm.valstack_bottom = p_caller.bottom;
                        if (p_caller.func != null) {
                            CompiledFunction* p_cfunc = (CompiledFunction*)p_caller.func;
                            vm.valstack_top = p_caller.bottom + p_cfunc.num_regs;
                        }
                    }
                }
                ds.needs_restart = true;
            }
            return (TVal){};
        }

        default:
            return (TVal){};
    }
    return (TVal){};
}


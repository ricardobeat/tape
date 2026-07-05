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
// vm_control — return / variable access / closure / iterator / exceptions / misc
// ============================================================================

/// Complete a generator's return: mark GEN_COMPLETED, wrap `val` in an
/// IteratorResult {value, done:true}, write it to the caller, and pop the
/// activation. Shared by RET_GEN/RETUNDEF_GEN and by ENDFINALLY's
/// generator-aware pending-return completion (a return that was deferred
/// through a try/finally in a generator body).
fn void vm_complete_generator_return(Dispatch* ds, TVal* val) {
    Vm* vm = ds.vm;
    GeneratorState* gs = vm.heap.resume_gen;
    if (gs != null) {
        gs.state = GEN_COMPLETED;
        vm.heap.tval_copy_ref(&vm.heap.yield_value, val);
        vm.heap.did_yield = false;
        vm.heap.resume_gen = null;
    }

    HObject*? robj_raw = vm.heap.alloc_object(hobject::ObjClass.OBJECT);
    TVal wrapped_val;
    if (try robj = robj_raw) {
        robj.prototype = vm.heap.object_proto;
        HString* val_key = (HString*)vm.heap.strs[heap::BuiltinStr.VALUE];
        if (val_key != null) robj.put_prop(val_key, *val, hobject::PROP_FLAGS_WEC);
        HString* done_key = (HString*)vm.heap.strs[heap::BuiltinStr.DONE];
        TVal done_val;
        done_val.set_boolean(true);
        if (done_key != null) robj.put_prop(done_key, done_val, hobject::PROP_FLAGS_WEC);
        wrapped_val.set_object(robj);
    } else {
        wrapped_val = *val;
    }

    Activation* ret_act = &vm.activations[vm.activation_count - 1];
    // retval is null when this activation was entered via the re-entrant
    // call_fn path (e.g. YIELD_STAR calling a delegated generator's .next()
    // directly) rather than the CALL opcode — the result is read back via
    // vm.return_val in that case instead.
    if (ret_act.retval != null) {
        vm.heap.tval_copy_ref(ret_act.retval, &wrapped_val);
    } else {
        vm.heap.tval_copy_ref(&vm.return_val, &wrapped_val);
    }

    vm.activation_count--;
    // activation_count can hit 0 here when this generator body was entered
    // via the re-entrant call_fn path (e.g. YIELD_STAR calling a delegated
    // generator's .next() directly) rather than the CALL opcode, so there is
    // no caller activation in *this* Vm.run invocation to fall back to —
    // halt like the plain RET path does.
    if (vm.activation_count == 0) {
        ds.halt = true;
        ds.halt_value = vm.return_val;
        return;
    }
    Activation* caller_act = &vm.activations[vm.activation_count - 1];
    vm.valstack_bottom = caller_act.bottom;
    if (caller_act.func != null) {
        CompiledFunction* caller_func = (CompiledFunction*)caller_act.func;
        vm.valstack_top = caller_act.bottom + caller_func.num_regs;
    }
    ds.needs_restart = true;
}

/// Sub-dispatch for the generator return opcodes RET_GEN/RETUNDEF_GEN.
/// The hot non-generator RET/RETUNDEF paths are inlined directly in Vm.run
/// (src/vm/vm_execute.c3) since they dominate recursion-heavy workloads.
fn TVal? dispatch_returns(Dispatch* ds, Opcode op, TVal* ra) {
    Vm* vm = ds.vm;
    switch (op) {
        case Opcode.RET_GEN: {
            // Check for active finally catchers: if we're returning through
            // a try-finally inside the generator body, save the return value,
            // mark it as a generator-return, and jump to the finally handler
            // instead of completing immediately (mirrors plain RET).
            Catcher* ret_cat = (Catcher*)ds.act.cat;
            if (ret_cat != null && ret_cat.finally_pc != null) {
                ret_cat.return_val = ra[0];
                if (!(ret_cat.flags & CATCHER_FLAG_PENDING_RETURN)) {
                    ret_cat.flags |= CATCHER_FLAG_PENDING_RETURN | CATCHER_FLAG_PENDING_RETURN_GEN;
                    ds.curr_pc = ret_cat.finally_pc;
                    ds.act.curr_pc = ds.curr_pc;
                }
                return (TVal){};
            }
            vm_complete_generator_return(ds, &ra[0]);
            return (TVal){};
        }

        case Opcode.RETUNDEF_GEN: {
            TVal undef_val;
            undef_val.set_undefined();
            Catcher* ret_cat2 = (Catcher*)ds.act.cat;
            if (ret_cat2 != null && ret_cat2.finally_pc != null) {
                ret_cat2.return_val = undef_val;
                if (!(ret_cat2.flags & CATCHER_FLAG_PENDING_RETURN)) {
                    ret_cat2.flags |= CATCHER_FLAG_PENDING_RETURN | CATCHER_FLAG_PENDING_RETURN_GEN;
                    ds.curr_pc = ret_cat2.finally_pc;
                    ds.act.curr_pc = ds.curr_pc;
                }
                return (TVal){};
            }
            vm_complete_generator_return(ds, &undef_val);
            return (TVal){};
        }
        default:
            return (TVal){};
    }
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
            // If the current catcher's own finally is what we're executing
            // right now (CATCHER_FLAG_IN_FINALLY), redirecting to it again
            // would loop forever — this break/continue overrides whatever
            // pending completion it was carrying, so pop and discard it; it
            // will never reach ENDFINALLY. The next catcher up the chain may
            // itself be IN_FINALLY too (nested try/finally within the first
            // one's finally block) — in that case the jump target already
            // lies inside its still-active finally, so we don't redirect at
            // all and just let the jump proceed there directly.
            Catcher* bc_cat = (Catcher*)ds.act.cat;
            bool bc_target_in_active_finally = false;
            if (bc_cat != null && (bc_cat.flags & CATCHER_FLAG_IN_FINALLY) != 0) {
                Catcher* bc_parent = (Catcher*)bc_cat.parent;
                ds.act.cat = (void*)bc_parent;
                vm.heap.free_func(vm.heap.heap_udata, bc_cat);
                bc_cat = bc_parent;
                if (bc_cat != null && (bc_cat.flags & CATCHER_FLAG_IN_FINALLY) != 0) {
                    bc_target_in_active_finally = true;
                }
            }
            if (!bc_target_in_active_finally && bc_cat != null && bc_cat.finally_pc != null
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


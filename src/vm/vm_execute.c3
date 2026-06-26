module duktape::vm;

import duktape::types;
import duktape::bytecode;
import duktape::heap;
import duktape::hstring;
import duktape::hobject;
import duktape::env;
import duktape::builtins;
import duktape::re_bindings;
import std::io;
import std::math;
import libc;

/// Set up a named-function-expression's lexical environment.
/// Returns a fresh declarative env with `name_hstr` bound immutably to
/// `func_obj`, or null on failure. The returned env's parent is `var_env`,
/// so lookups for everything else still walk through the function's normal
/// scope chain (per ES2015 §14.1.20 NamedEvaluation).
fn EnvRecord*? setup_named_function_expr_env(Vm* vm, EnvRecord* var_env,
                                              HString* name_hstr,
                                              HObject* func_obj) {
    EnvRecord*? lex_env_raw = env::env_create_declarative(vm.heap, var_env);
    if (catch err = lex_env_raw) return types::ALLOC_ERROR~;
    EnvRecord* lex_env = lex_env_raw;
    TVal func_tv; func_tv.set_object(func_obj);
    // Non-writable, enumerable, configurable — same flags PUTLEX_C uses for const.
    lex_env.bindings.put_prop((void*)name_hstr, func_tv, hobject::PROP_FLAGS_EC);
    return lex_env;
}

/// Implementation of Heap.call_fn — calls a JS function with N arguments through the VM.
fn TVal vm_call_fn_impl(void* vm_ptr, TVal func, TVal* args, uint nargs, TVal this_val) {
    Vm* vm = (Vm*)vm_ptr;
    TVal undef;
    undef.set_undefined();

    // Case 1: lightfunc — dispatch directly via BuiltinContext
    if (func.is_lightfunc()) {
        uint fn_idx = (uint)(usz)func.get_heapptr();

        // Temporary register layout: [this, arg0, arg1, ...]
        // Use stack-allocated array for up to 8 args
        uint total = 1 + nargs;
        if (total > 16) total = 16;

        TVal[16] temp_regs;
        temp_regs[0] = this_val;
        for (uint i = 0; i < nargs && i < 16; i++) {
            temp_regs[1 + i] = args[i];
        }

        builtins::BuiltinContext ctx;
        ctx.vm = vm;
        ctx.regs = &temp_regs;
        ctx.base_reg = 1;
        ctx.argc = (ushort)nargs;
        ctx.result = &temp_regs[0];
        ctx.heap = vm.heap;
        ctx.this_val = this_val;
        ctx.is_constructor = false;
        ctx.needs_re_dispatch = false;
        ctx.re_nargs = 0;
        ctx.global_env = vm.global_env;
        ctx.should_throw = false;
        ctx.callee_obj = null;

        builtins::dispatch_builtin(fn_idx, &ctx);
        return *ctx.result;
    }

    // Case 2: HObject with builtin_fn_index — dispatch via BuiltinContext
    if (func.is_object() && func.get_heapptr() != null) {
        HObject* hobj = (HObject*)func.get_heapptr();
        if (hobj != null && hobj.is_callable() && hobj.callable_kind() == hobject::CallableKind.BUILTIN_FN) {
            uint fn_idx = (uint)(*hobj.extra_ptr()).func.builtin_fn_index;

            // Builtins may modify callee/this via base_reg-2 and base_reg-1.
            // Layout: [callee, this, arg0, arg1, ...]
            uint total = 2 + nargs;
            if (total > 18) total = 18;

            TVal[18] temp_regs;
            temp_regs[0] = func;       // callee at index 0 (base_reg - 2)
            temp_regs[1] = this_val;   // this at index 1   (base_reg - 1)
            for (uint i = 0; i < nargs && i < 16; i++) {
                temp_regs[2 + i] = args[i];
            }

            builtins::BuiltinContext ctx;
            ctx.vm = vm;
            ctx.regs = &temp_regs;
            ctx.base_reg = 2;          // base_reg - 2 = 0 = callee, base_reg - 1 = 1 = this
            ctx.argc = (ushort)nargs;
            ctx.result = &temp_regs[0];
            ctx.heap = vm.heap;
            ctx.this_val = this_val;
            ctx.is_constructor = false;
            ctx.needs_re_dispatch = false;
            ctx.re_nargs = 0;
            ctx.global_env = vm.global_env;
            ctx.should_throw = false;
            ctx.callee_obj = hobj;

            builtins::dispatch_builtin(fn_idx, &ctx);

            if (ctx.should_throw) {
                vm.throw_pending = true;
                vm.heap.tval_copy_ref(&vm.throw_value, &ctx.throw_value);
                return undef;
            }

            if (ctx.needs_re_dispatch) {
                // Builtin (e.g., generator .next()) modified the callee/this and
                // expects the call to be re-dispatched.
                func = temp_regs[0];
                this_val = temp_regs[1];
                // Rebuild args from temp_regs[2..] with the re-dispatched nargs
                uint new_nargs = ctx.re_nargs;
                for (uint i = 0; i < new_nargs && i < 16; i++) {
                    if (2 + i < 18) args[i] = temp_regs[2 + i];
                }
                nargs = new_nargs;
                // Fall through to Case 3
            } else {
                return *ctx.result;
            }
        }
    }

    // Case 3: compiled function on HObject
    if (func.is_object() && func.get_heapptr() != null) {
        HObject* hobj = (HObject*)func.get_heapptr();
        if (hobj != null && hobj.is_callable() && (*hobj.extra_ptr()).func.comp_func != null) {
            CompiledFunction* target = (*hobj.extra_ptr()).func.comp_func;
            uint nregs = target.num_regs;

            // Grow the valstack first (while activation_count is still the
            // caller's, so ensure_valstack_grow relocates all live pointers).
            // The callback frame is placed at the current valstack_top, above
            // all live caller registers — they are never touched.
            if (!ensure_valstack(vm, nregs)) {
                return undef;
            }

            // Save current VM state (after potential realloc)
            uint saved_act_count = vm.activation_count;
            TVal* saved_valstack_bottom = vm.valstack_bottom;
            TVal* saved_valstack_top = vm.valstack_top;
            TVal* saved_valstack = vm.valstack;
            CompiledFunction* saved_current_func = vm.current_func;
            void* saved_resume_gen = vm.heap.resume_gen;  // preserve across nested generator calls

            Activation[MAX_CALLS] saved_acts;
            libc::memcpy(&saved_acts, &vm.activations, saved_act_count * Activation::size);

            TVal* frame = vm.valstack_top;

            // Set up activation[0] for the function
            Activation* act = &vm.activations[0];
            vm.activation_count = 1;
            EnvRecord* cfn_var_env = (*hobj.extra_ptr()).func.var_env;
            if (try fv_cfn = env::env_create_function_scope(vm.heap, (*hobj.extra_ptr()).func.var_env)) { cfn_var_env = fv_cfn; }
            act.func = target;
            act.parent = null;
            act.var_env = cfn_var_env;
            act.lex_env = cfn_var_env;
            act.cat = null;
            act.curr_pc = target.code;
            act.async_promise = null;
            act.async_gen_state = null;

            // Check for generator/async resume: if heap.resume_gen is set
            // and matches this function, restore the saved PC and registers.
            bool did_resume = false;
            if (vm.heap.resume_gen != null) {
                GeneratorState* gs_r = vm.heap.resume_gen;
                if ((CompiledFunction*)gs_r.func == target) {
                    did_resume = true;
                    act.curr_pc = (Instruction*)gs_r.saved_pc;
                    act.var_env = (EnvRecord*)gs_r.var_env;
                    act.lex_env = (EnvRecord*)gs_r.lex_env;
                    act.cat = gs_r.cat;
                    // Restore saved registers instead of initializing fresh
                    $if $feature(HEAP_VERIFY):
                        vm.heap.verify_roots("before_resume_restore");
                        if (gs_r.saved_regs != null) {
                            vm.heap.verify_tval_array(gs_r.saved_regs, gs_r.num_regs, "resume_saved_regs");
                        }
                    $endif
                    for (uint i = 0; i < nregs; i++) {
                        if (gs_r.saved_regs != null) {
                            vm.heap.tval_copy_ref(&frame[i], &gs_r.saved_regs[i]);
                        } else {
                            frame[i].set_undefined();
                        }
                    }
                    // Put the resume value into register 0 (LOAD_RESUME will read it)
                    // The resume value is read by LOAD_RESUME from gs_r.resume_value
                    // into the A operand register, so no need to pre-populate frame[0].
                    // vm.heap.tval_copy_ref(&frame[0], &gs_r.resume_value);
                    // Propagate async context so RET can settle the async Promise
                    if (gs_r.async_promise != null) {
                        act.flags |= ACT_FLAG_ASYNC;
                        act.async_promise = (hobject::HObject*)gs_r.async_promise;
                    }
                    $if $feature(HEAP_VERIFY):
                        vm.heap.verify_roots("after_resume_restore");
                    $endif
                }
            }

            act.bottom = frame;
            act.retval = null;
            // Preserve any flags already set (e.g. ACT_FLAG_ASYNC for resumed async fns)
            uint preserved_flags = act.flags;
            act.flags = (target.has_direct_eval() ? ACT_FLAG_DIRECT_EVAL : 0)
                      | preserved_flags;
            act.max_heap_reg = 0;
            act.caller_valstack_top = frame + nregs;
            // Raw assign: this_val is kept alive by the caller for the duration
            // of the call; the previous activation[0].this_binding bits are
            // restored verbatim below, so refcounts stay balanced.
            act.this_binding = this_val;

            if (!did_resume) {
                for (uint i = 0; i < nregs; i++) {
                    frame[i].set_undefined();
                }
                uint copy_n = nargs < nregs ? nargs : nregs;
                for (uint i = 0; i < copy_n; i++) {
                    vm.heap.tval_copy_ref(&frame[i], &args[i]);
                }
            }
            vm.valstack_top = frame + nregs;
            vm.valstack_bottom = frame;
            vm.current_func = target;

            // Create arguments object if the function references 'arguments'
            if (target.uses_arguments()) {
                HObject*? args_obj_raw = vm.heap.alloc_object(hobject::ObjClass.ARGUMENTS);
                if (try args_obj = args_obj_raw) {
                    // Store arguments in dense array_part (avoids O(argc) string key allocs)
                    for (uint ai = 0; ai < nargs; ai++) {
                        args_obj.set_array_idx(ai, frame[ai]);
                    }
                    // ES5 §10.6: [[Prototype]] is Object.prototype
                    args_obj.prototype = vm.heap.object_proto;
                    // ES5 §10.6: define 'callee' property (writable, non-enumerable, configurable)
                    HString* callee_key = (HString*)vm.heap.strs[heap::BuiltinStr.CALLEE];
                    if (callee_key != null) {
                        TVal callee_tv;
                        callee_tv.set_object(hobj);
                        args_obj.put_prop(callee_key, callee_tv, hobject::PROP_FLAGS_WC);
                    }
                    // ES5 §10.6: define 'length' property (writable, non-enumerable, configurable)
                    HString* length_key = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
                    if (length_key != null) {
                        TVal length_tv;
                        length_tv.set_fastint((long)nargs);
                        args_obj.put_prop(length_key, length_tv, hobject::PROP_FLAGS_WC);
                    }
                    // Declare 'arguments' in the function's var_env
                    HString* args_name = (HString*)vm.heap.strs[heap::BuiltinStr.ARGUMENTS];
                    if (args_name != null) {
                        TVal args_tv;
                        args_tv.set_object(args_obj);
                        env::env_declare(act.var_env, args_name, args_tv);
                    }
                }
            }

            // Run the function via Vm.run (skip Vm.execute init — we already set up state)
            TVal? result_opt = Vm.run(vm);
            TVal result;
            if (try r = result_opt) {
                result = r;
            } else {
                result = vm.return_val;
            }

            // If the nested run reallocated the valstack, relocate the saved
            // absolute pointers by the same delta (the saved snapshot was not
            // covered by ensure_valstack_grow's relocation pass).
            long reloc = (char*)vm.valstack - (char*)saved_valstack;
            if (reloc != 0) {
                saved_valstack_bottom = (TVal*)((char*)saved_valstack_bottom + reloc);
                saved_valstack_top = (TVal*)((char*)saved_valstack_top + reloc);
                for (uint i = 0; i < saved_act_count; i++) {
                    saved_acts[i].bottom = (TVal*)((char*)saved_acts[i].bottom + reloc);
                    if (saved_acts[i].retval != null) {
                        saved_acts[i].retval = (TVal*)((char*)saved_acts[i].retval + reloc);
                    }
                    if (saved_acts[i].caller_valstack_top != null) {
                        saved_acts[i].caller_valstack_top = (TVal*)((char*)saved_acts[i].caller_valstack_top + reloc);
                    }
                }
            }

            // Restore VM state (caller registers were never touched)
            vm.activation_count = saved_act_count;
            vm.current_func = saved_current_func;
            libc::memcpy(&vm.activations, &saved_acts, saved_act_count * Activation::size);
            vm.valstack_bottom = saved_valstack_bottom;
            vm.valstack_top = saved_valstack_top;
            vm.heap.resume_gen = (GeneratorState*)saved_resume_gen;  // restore after nested generator

            // Drain microtasks after callback execution
            vm.heap.drain_microtasks((void*)vm);

            return result;
        }
    }

    return undef;
}

// trace_print_tval and trace_instruction are now in vm_trace.c3.

/// Implementation of Heap.call_handler_fn — delegates to vm_call_fn_impl.
fn TVal vm_call_handler_fn_impl(void* vm_ptr, TVal handler, TVal* arg) {
    TVal undef;
    undef.set_undefined();
    return vm_call_fn_impl(vm_ptr, handler, arg, 1, undef);
}

fn TVal? Vm.execute(Vm* vm, CompiledFunction* func) {
    // Set up initial activation (matches outer executor setup)
    Activation* entry_act = &vm.activations[0];
    vm.activation_count = 1;

    entry_act.func = func;
    entry_act.parent = null;
    entry_act.var_env = vm.global_env;
    entry_act.lex_env = vm.global_env;
    entry_act.cat = null;
    entry_act.curr_pc = func.code;  // Points into bytecode
    entry_act.bottom = vm.valstack;
    entry_act.retval = null;
    // ES5 §10.4.1: at the top level of a script in strict mode, the global `this`
    // is `undefined` (strict-only engine: always undefined).
    entry_act.flags = 0;
    if (func.has_direct_eval()) {
        entry_act.flags |= ACT_FLAG_DIRECT_EVAL;
    }

    TVal this_val;
    this_val.set_undefined();
    vm.heap.tval_copy_ref(&entry_act.this_binding, &this_val);

    // Allocate value stack slots for the function (nregs = total register count)
    uint nregs = func.num_regs;
    if (!ensure_valstack(vm, nregs)) {
        return VM_ERROR~;
    }

    // Initialize registers to undefined
    for (uint i = 0; i < nregs; i++) {
        vm.valstack[i].set_undefined();
    }
    vm.valstack_top = (TVal*)((usz)vm.valstack + (usz)nregs * TVal::size);
    vm.valstack_bottom = vm.valstack;
    // The top-level activation has no caller, but caller_valstack_top must be
    // set to a valid value so that RET restoring back to this activation
    // (after a compiled callee returns) doesn't corrupt vm.valstack_top.
    entry_act.caller_valstack_top = vm.valstack_top;

    vm.current_func = func;

    TVal? result = Vm.run(vm);

    // Drain microtask queue after top-level script execution
    vm.heap.drain_microtasks((void*)vm);

    return result;
}

/// Execute a compiled function with a specific environment (for ESM modules).
/// Same as execute() but uses the provided env for var_env/lex_env instead
/// of the global environment.
fn TVal? Vm.execute_in_env(Vm* vm, CompiledFunction* func, EnvRecord* env) {
    Activation* entry_act = &vm.activations[0];
    vm.activation_count = 1;

    entry_act.func = func;
    entry_act.parent = null;
    entry_act.var_env = env;
    entry_act.lex_env = env;
    entry_act.cat = null;
    entry_act.curr_pc = func.code;
    entry_act.bottom = vm.valstack;
    entry_act.retval = null;
    entry_act.flags = 0;
    if (func.has_direct_eval()) {
        entry_act.flags |= ACT_FLAG_DIRECT_EVAL;
    }

    TVal this_val;
    this_val.set_undefined();
    vm.heap.tval_copy_ref(&entry_act.this_binding, &this_val);

    uint nregs = func.num_regs;
    if (!ensure_valstack(vm, nregs)) {
        return VM_ERROR~;
    }

    for (uint i = 0; i < nregs; i++) {
        vm.valstack[i].set_undefined();
    }
    vm.valstack_top = (TVal*)((usz)vm.valstack + (usz)nregs * TVal::size);
    vm.valstack_bottom = vm.valstack;
    entry_act.caller_valstack_top = vm.valstack_top;

    vm.current_func = func;

    TVal? result = Vm.run(vm);

    vm.heap.drain_microtasks((void*)vm);

    return result;
}

/// Execute the bytecode dispatch loop. Assumes activation stack and registers
/// are already set up by the caller.
fn TVal? Vm.run(Vm* vm) {
    Dispatch ds;
    ds.vm = vm;
    ds.needs_restart = true;

    // Outer restart loop: on ECMAScript-to-ECMAScript calls, reload state
    for (;;) {
        if (!ds.needs_restart) {
            break;
        }
        ds.needs_restart = false;

        ds.act = &vm.activations[vm.activation_count - 1];
        vm.current_func = (CompiledFunction*)ds.act.func;
        ds.code_base = vm.current_func.code;
        ds.code_count = vm.current_func.code_count;
        ds.constants = vm.current_func.constants;
        ds.ic_base = (hobject::ICEntry*)vm.current_func.ic_entries;
        ds.var_ic_base = (hobject::VarICEntry*)vm.current_func.var_ic_entries;
        ds.nregs = vm.current_func.num_regs;

        ds.curr_pc = ds.act.curr_pc;
        ds.code_end = ds.code_base + ds.code_count;

        ds.regs_base = ds.act.bottom;

        // Inner dispatch loop
        for (; !ds.needs_restart; ) {
            if (ds.curr_pc >= ds.code_end) {
                // Inline handle_return for fall-off-end — avoids function call overhead.
                Activation* callee_act = &vm.activations[vm.activation_count - 1];
                TVal* callee_result = callee_act.retval;

                // Decref callee registers before popping
                decref_callee_regs(vm, callee_act);

                vm.activation_count--;

                if (vm.activation_count == 0) {
                    TVal undef_val;
                    undef_val.set_undefined();
                    vm.heap.tval_copy_ref(&vm.return_val, &undef_val);
                    return vm.return_val;
                }

                Activation* caller_act = &vm.activations[vm.activation_count - 1];
                vm.valstack_bottom = caller_act.bottom;

                TVal undef_val;
                undef_val.set_undefined();
                TVal final_val = undef_val;
                if ((callee_act.flags & ACT_FLAG_CONSTRUCT) != 0) {
                    if (!final_val.is_object() || final_val.get_heapptr() == null) {
                        if (callee_act.this_binding.is_object() && callee_act.this_binding.get_heapptr() != null) {
                            final_val = callee_act.this_binding;
                        }
                    }
                }
                vm.heap.tval_copy_ref(callee_result, &final_val);

                CompiledFunction* caller_func = (CompiledFunction*)caller_act.func;

                ds.act = caller_act;
                vm.valstack_top = caller_act.caller_valstack_top;
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
                continue;
            }

            Instruction insn = *ds.curr_pc;
            ds.curr_pc++;

            Opcode op = insn.op;

            TVal* ra = ds.regs_base + ((uint)insn.a);
            TVal* rb = ds.regs_base + ((uint)insn.b);
            TVal* rc = ds.regs_base + ((uint)insn.c);

        if (@unlikely(vm.trace)) {
            trace_instruction(vm, ds.curr_pc - 1, (uint)((ds.curr_pc - 1) - ds.code_base),
                              ra, rb, rc, ds.regs_base, ds.act);
        }

        switch (op) {

        // === LOAD / STORE ===

        case Opcode.LDREG: {
            // Forward to dispatch_load_store function (handles all LOAD/STORE opcodes)
            if (catch err = dispatch_load_store(&ds, op, ra, rb, rc, insn)) { return err~; }
            continue;
        }
            continue;
        // === ARITHMETIC ===

        if (catch err = dispatch_arith(&ds, op, ra, rb, rc, insn)) { return err~; }
        continue;
        // === UNARY ===

        if (catch err = dispatch_unary(&ds, op, ra, rb, rc, insn)) { return err~; }
        continue;
        // === BITWISE ===

        if (catch err = dispatch_bitwise(&ds, op, ra, rb, rc, insn)) { return err~; }
        continue;
        // === COMPARISON ===

        if (catch err = dispatch_compare(&ds, op, ra, rb, rc, insn)) { return err~; }
        continue;
        // === CONTROL FLOW ===

        if (catch err = dispatch_control_flow(&ds, op, ra, rb, rc, insn)) { return err~; }
        continue;
        // === PROPERTY ACCESS ===

        if (catch err = dispatch_property(&ds, op, ra, rb, rc, insn)) { return err~; }
        continue;
        // === OBJECT / ARRAY CREATION ===

        if (catch err = dispatch_objects(&ds, op, ra, rb, rc, insn)) { return err~; }
        continue;
        // === FUNCTION CALLS ===

        if (catch err = dispatch_calls(&ds, op, ra, rb, rc, insn)) { return err~; }
        continue;
        // === GENERATORS ===

        if (catch err = dispatch_generators(&ds, op, ra, rb, rc, insn)) { return err~; }
        continue;
        // === RETURNS ===
        if (catch err = dispatch_returns(&ds, op, ra)) { return err~; }
        continue;

        // === VARIABLE ACCESS ===

        if (catch err = dispatch_var_access(&ds, op, ra, rb, rc, insn)) { return err~; }
        continue;
        // === CLOSURES ===

        if (catch err = dispatch_closures(&ds, op, ra, rb, rc, insn)) { return err~; }
        continue;
        // === ITEraTOR ===

        if (catch err = dispatch_iterator(&ds, op, ra, rb, rc, insn)) { return err~; }
        continue;
        // === EXCEPTION HANDLING ===

        if (catch err = dispatch_exceptions(&ds, op, ra, rb, rc, insn)) { return err~; }
        continue;
        // === MISC ===

        if (catch err = dispatch_misc(&ds, op, ra, rb, rc, insn)) { return err~; }
        continue;
        default:
            return VM_ERROR~;
        }
    }
    }
    return vm.return_val;
}
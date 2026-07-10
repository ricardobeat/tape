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

/// Resolve the lexical environment for entering a compiled-function call frame.
/// Closures created inside a PUSH_LEX block scope capture that declarative env
/// in func.lex_env; the frame must enter with it as lex_env so the block's
/// let/const bindings stay visible (GETVAR walks lex_env, then var_env).
/// Named function expressions additionally get a fresh declarative env binding
/// their own name (ES2015 §14.1.20), chained above the captured scope.
fn EnvRecord* resolve_call_lex_env(Vm* vm, HObject* func_obj,
                                   CompiledFunction* target, EnvRecord* var_env) {
    EnvRecord* base = var_env;
    EnvRecord* cap_lex = (*func_obj.extra_ptr()).func.lex_env;
    if (cap_lex != null && cap_lex != var_env && cap_lex.is_declarative) {
        base = cap_lex;
    }
    if (target.is_namebinding()) {
        char[] name_data = target.get_name();
        HString* name_hstr = intern_string(vm, name_data);
        if (name_hstr != null) {
            if (try name_lex = setup_named_function_expr_env(vm, base, name_hstr, func_obj)) {
                return name_lex;
            }
        }
    }
    return base;
}

/// Implementation of Heap.call_fn — calls a JS function with N arguments through the VM.
fn TVal vm_call_fn_impl(void* vm_ptr, TVal func, TVal* args, uint nargs, TVal this_val) {
    Vm* vm = (Vm*)vm_ptr;
    TVal undef;
    undef.set_undefined();

    // Save resume_gen before ANY dispatch below runs. Case 2 (builtin, e.g.
    // Generator.prototype.next) may itself set vm.heap.resume_gen for the
    // *callee's* generator before falling through to Case 3's re-dispatch —
    // capturing this after Case 2 runs would save the callee's resume_gen
    // instead of the caller's, corrupting the caller generator's resume
    // state once restored below (e.g. yield* losing track of the delegating
    // generator's own suspend/resume bookkeeping).
    void* saved_resume_gen_outer = vm.heap.resume_gen;

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

            // Compute the true top of the current activation's register file.
            // vm.valstack_top is NOT updated for inline JS-to-JS calls (CALL
            // opcode uses vm_setup_call which skips the update), so it may
            // point below the current function's full register space, causing
            // the callee frame to overlap live caller registers.
            TVal* true_top = vm.valstack_top;
            if (vm.activation_count > 0) {
                Activation* cur_act = &vm.activations[vm.activation_count - 1];
                CompiledFunction* cur_func = (CompiledFunction*)cur_act.func;
                if (cur_func != null) {
                    TVal* act_top = cur_act.bottom + cur_func.num_regs;
                    if (act_top > true_top) true_top = act_top;
                }
            }

            // Grow the valstack first (while activation_count is still the
            // caller's, so ensure_valstack_grow relocates all live pointers).
            // The callback frame is placed above all live caller registers.
            uint true_used = (uint)(true_top - vm.valstack);
            if (true_top + nregs > vm.valstack_end) {
                if (!ensure_valstack_grow(vm, true_used + nregs - (uint)(vm.valstack_top - vm.valstack))) {
                    return undef;
                }
                // Recompute true_top after potential realloc
                if (vm.activation_count > 0) {
                    Activation* cur_act2 = &vm.activations[vm.activation_count - 1];
                    CompiledFunction* cur_func2 = (CompiledFunction*)cur_act2.func;
                    if (cur_func2 != null) {
                        TVal* act_top2 = cur_act2.bottom + cur_func2.num_regs;
                        true_top = (act_top2 > vm.valstack_top) ? act_top2 : vm.valstack_top;
                    } else {
                        true_top = vm.valstack_top;
                    }
                } else {
                    true_top = vm.valstack_top;
                }
            }

            // Save current VM state (after potential realloc)
            uint saved_act_count = vm.activation_count;
            TVal* saved_valstack_bottom = vm.valstack_bottom;
            TVal* saved_valstack_top = vm.valstack_top;
            TVal* saved_valstack = vm.valstack;
            CompiledFunction* saved_current_func = vm.current_func;
            void* saved_resume_gen = saved_resume_gen_outer;  // captured before Case 1/2 could overwrite it

            Activation[MAX_CALLS] saved_acts;
            libc::memcpy(&saved_acts, &vm.activations, saved_act_count * Activation::size);

            TVal* frame = true_top;

            // Set up activation[0] for the function
            Activation* act = &vm.activations[0];
            vm.activation_count = 1;
            EnvRecord* cfn_var_env = (*hobj.extra_ptr()).func.var_env;
            if (try fv_cfn = env::env_create_function_scope(vm.heap, (*hobj.extra_ptr()).func.var_env)) { cfn_var_env = fv_cfn; }
            act.func = target;
            act.parent = null;
            act.var_env = cfn_var_env;
            act.lex_env = resolve_call_lex_env(vm, hobj, target, cfn_var_env);
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
                    act.async_gen_state = gs_r;
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
                if (target.has_rest()) {
                    // Copy the fixed (pre-rest) formals first.
                    uint copy_count = (uint)target.num_formals;
                    uint copy_n = nargs < copy_count ? nargs : copy_count;
                    for (uint i = 0; i < copy_n; i++) {
                        vm.heap.tval_copy_ref(&frame[i], &args[i]);
                    }
                    // Build the rest array from remaining args.
                    uint rest_idx = copy_count;
                    uint overflow = (nargs > copy_count) ? (nargs - copy_count) : 0;
                    HObject*? arr_raw = vm.heap.alloc_object(hobject::ObjClass.ARRAY);
                    if (try arr = arr_raw) {
                        arr.prototype = vm.heap.array_proto;
                        for (uint i = 0; i < overflow; i++) {
                            arr.set_array_idx(i, args[copy_count + i]);
                        }
                        HString* len_str = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
                        TVal len_tv;
                        len_tv.set_fastint((long)overflow);
                        if (len_str != null) arr.put_prop(len_str, len_tv, hobject::PROP_FLAGS_WEC);
                        frame[rest_idx].set_object(arr);
                    }
                } else {
                    uint copy_n = nargs < nregs ? nargs : nregs;
                    for (uint i = 0; i < copy_n; i++) {
                        vm.heap.tval_copy_ref(&frame[i], &args[i]);
                    }
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

/// Implementation of Heap.construct_fn — `new Fn(args)` semantics.
/// Allocates a fresh this, runs the constructor with ACT_FLAG_CONSTRUCT,
/// and returns the resulting instance.  Used by Promise combinators for
/// NewPromiseCapability(C).
fn TVal vm_construct_fn_impl(void* vm_ptr, TVal func, TVal* args, uint nargs) {
    Vm* vm = (Vm*)vm_ptr;
    TVal undef;
    undef.set_undefined();
    if (vm == null) return undef;
    Heap* heap = vm.heap;

    // Save resume_gen before any dispatch below runs — a builtin constructor
    // dispatched further down can itself set vm.heap.resume_gen for its own
    // callee before this function's own save point, corrupting the caller's
    // resume state once restored. See vm_call_fn_impl for the same fix.
    void* saved_resume_gen_outer2 = vm.heap.resume_gen;

    // Lightfuncs can't be constructors.
    if (func.is_lightfunc()) return undef;
    if (!func.is_object() || func.get_heapptr() == null) return undef;
    HObject* ctor = (HObject*)func.get_heapptr();
    if (ctor == null || !ctor.flags.callable) return undef;

    // Allocate a fresh plain object as `this`.
    // GetPrototypeFromConstructor(ctor, "%Object.prototype%") — ES2022
    // §9.1.14: read ctor.prototype; if it isn't an object, fall back to the
    // default intrinsic (heap.object_proto) rather than always using it.
    HObject*? new_this_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err_t = new_this_raw) return undef;
    HObject* new_this = new_this_raw;
    new_this.prototype = heap.object_proto;
    HString* ctor_proto_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    if (ctor_proto_key != null) {
        if (try proto_tv = ctor.get_prop_proto(ctor_proto_key)) {
            if (proto_tv.is_object() && proto_tv.get_heapptr() != null) {
                new_this.prototype = (HObject*)proto_tv.get_heapptr();
            }
        }
    }
    TVal this_tv;
    this_tv.set_object(new_this);

    CompiledFunction* target = (*ctor.extra_ptr()).func.comp_func;
    // Note: target == null is the correct signal for "not a compiled
    // function" (e.g. a built-in). A compiled function with num_regs == 0
    // (empty body, no locals/params referenced) is still a real constructor
    // and must run through the compiled-function activation path below —
    // routing it into the builtin-dispatch branch here would silently no-op
    // any user constructor with an empty or trivial body.
    if (target == null) {
        // Built-in constructor — dispatch directly.
        if (ctor.callable_kind() == hobject::CallableKind.BUILTIN_FN) {
            int builtin_idx = (*ctor.extra_ptr()).func.builtin_fn_index;
            // For Promise, allocate as PROMISE class so builtin_promise
            // initialises the right internal slots.
            if (builtin_idx == (int)builtins::BUILTIN_PROMISE) {
                HObject*? prom_this_raw = heap.alloc_object(hobject::ObjClass.PROMISE);
                if (catch err_p = prom_this_raw) return undef;
                HObject* prom_this = prom_this_raw;
                prom_this.prototype = heap.promise_proto;
                builtins::promise_init(prom_this);
                this_tv.set_object(prom_this);
                new_this = prom_this;
            }
            TVal[18] temp_regs;
            temp_regs[0] = func;
            temp_regs[1] = this_tv;
            for (uint i = 0; i < nargs && i < 16; i++) {
                temp_regs[2 + i] = args[i];
            }
            builtins::BuiltinContext bctx;
            bctx.vm = vm;
            bctx.regs = &temp_regs;
            bctx.base_reg = 2;
            bctx.argc = (ushort)nargs;
            bctx.result = &temp_regs[0];
            bctx.heap = heap;
            bctx.this_val = this_tv;
            bctx.is_constructor = true;
            bctx.needs_re_dispatch = false;
            bctx.re_nargs = 0;
            bctx.global_env = vm.global_env;
            bctx.should_throw = false;
            bctx.callee_obj = ctor;
            bctx.new_target = ctor;
            builtins::dispatch_builtin((uint)builtin_idx, &bctx);
            if (bctx.should_throw) {
                vm.throw_pending = true;
                vm.heap.tval_copy_ref(&vm.throw_value, &bctx.throw_value);
                return undef;
            }
            TVal result = *bctx.result;
            if (result.is_object()) return result;
            if (result.is_undefined()) return this_tv;
            return result;
        }
        return undef;
    }

    // Compiled user-defined function: set up a constructor activation.
    uint nregs = target.num_regs;
    if (vm.activation_count >= MAX_CALLS) return undef;
    if (!vm.valstack_top || !vm.valstack) return undef;
    uint needed_slots = (uint)((char*)vm.valstack_top - (char*)vm.valstack) / TVal::size + nregs;
    if (needed_slots > vm.valstack_size / TVal::size) {
        if (!ensure_valstack(vm, needed_slots)) return undef;
    }

    // Save current VM state for restoration after the constructor returns.
    uint saved_act_count = vm.activation_count;
    TVal* saved_valstack_bottom = vm.valstack_bottom;
    TVal* saved_valstack_top = vm.valstack_top;
    TVal* saved_valstack = vm.valstack;
    CompiledFunction* saved_current_func = vm.current_func;
    void* saved_resume_gen = saved_resume_gen_outer2;  // captured before the builtin-constructor dispatch above could overwrite it

    Activation[MAX_CALLS] saved_acts;
    libc::memcpy(&saved_acts, &vm.activations, saved_act_count * Activation::size);

    TVal* frame = vm.valstack_top;
    vm.activation_count = 1;
    Activation* act = &vm.activations[0];

    EnvRecord* cfn_var_env = (*ctor.extra_ptr()).func.var_env;
    if (try fv_cfn = env::env_create_function_scope(heap, (*ctor.extra_ptr()).func.var_env)) {
        cfn_var_env = fv_cfn;
    }
    act.func = target;
    act.parent = null;
    act.var_env = cfn_var_env;
    act.lex_env = resolve_call_lex_env(vm, ctor, target, cfn_var_env);
    act.cat = null;
    act.curr_pc = target.code;
    act.async_promise = null;
    act.async_gen_state = null;
    act.bottom = frame;
    act.retval = null;
    act.flags = ACT_FLAG_CONSTRUCT
              | (target.has_direct_eval() ? ACT_FLAG_DIRECT_EVAL : 0);
    act.max_heap_reg = 0;
    act.caller_valstack_top = frame + nregs;
    act.this_binding = this_tv;
    act.new_target = ctor;

    for (uint i = 0; i < nregs; i++) {
        frame[i].set_undefined();
    }
    uint copy_n = nargs < nregs ? nargs : nregs;
    for (uint i = 0; i < copy_n; i++) {
        vm.heap.tval_copy_ref(&frame[i], &args[i]);
    }
    if (target.uses_arguments()) {
        HObject*? args_obj_raw = vm.heap.alloc_object(hobject::ObjClass.ARGUMENTS);
        if (try args_obj = args_obj_raw) {
            for (uint ai = 0; ai < nargs; ai++) {
                args_obj.set_array_idx(ai, frame[ai]);
            }
            args_obj.prototype = vm.heap.object_proto;
            HString* length_key = (HString*)vm.heap.strs[heap::BuiltinStr.LENGTH];
            if (length_key != null) {
                TVal length_tv;
                length_tv.set_fastint((long)nargs);
                args_obj.put_prop(length_key, length_tv, hobject::PROP_FLAGS_WC);
            }
            // Declare `arguments` in the function's var_env so the body can access it.
            HString* args_name = (HString*)vm.heap.strs[heap::BuiltinStr.ARGUMENTS];
            if (args_name != null) {
                TVal args_tv;
                args_tv.set_object(args_obj);
                env::env_declare(cfn_var_env, args_name, args_tv);
            }
        }
    }

    vm.valstack_top = frame + nregs;
    vm.valstack_bottom = frame;
    vm.current_func = target;

    TVal? result_opt = Vm.run(vm);
    TVal result;
    if (try r = result_opt) {
        result = r;
    } else {
        result = vm.return_val;
    }

    // ES6 §12.3.5.2: if constructor returns an object, that's the new instance.
    TVal final_this = this_tv;
    if (result.is_object() && result.get_heapptr() != null) {
        final_this = result;
    }

    // Relocate saved pointers if valstack moved during the constructor run.
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

    // Restore VM state.
    vm.activation_count = saved_act_count;
    vm.current_func = saved_current_func;
    libc::memcpy(&vm.activations, &saved_acts, saved_act_count * Activation::size);
    vm.valstack_bottom = saved_valstack_bottom;
    vm.valstack_top = saved_valstack_top;
    vm.heap.resume_gen = (GeneratorState*)saved_resume_gen;

    vm.heap.drain_microtasks((void*)vm);
    return final_this;
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
    entry_act.flags = 0;
    if (func.has_direct_eval()) {
        entry_act.flags |= ACT_FLAG_DIRECT_EVAL;
    }

    // ES5 §10.4.1: global `this` is the global object for non-strict scripts.
    TVal this_val;
    if (vm.global_env != null && vm.global_env.bindings != null) {
        this_val.set_object(vm.global_env.bindings);
    } else {
        this_val.set_undefined();
    }
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
    if (vm.global_env != null && vm.global_env.bindings != null) {
        this_val.set_object(vm.global_env.bindings);
    } else {
        this_val.set_undefined();
    }
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
    ds.halt = false;

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
            if (ds.halt) {
                return ds.halt_value;
            }
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
                vm.valstack_top = callee_act.caller_valstack_top;
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

        $if $feature(TRACE_VM):
        if (@unlikely(vm.trace)) {
            trace_instruction(vm, ds.curr_pc - 1, (uint)((ds.curr_pc - 1) - ds.code_base),
                              ra, rb, rc, ds.regs_base, ds.act);
        }
        $endif

        switch (op) @jump {

        // === LOAD / STORE ===
        case Opcode.LDREG:
            // Fast path: if source is not a heap ref (fastint, undefined, etc.),
            // skip full refcounting — only decref dst if it held a heap pointer.
            if (!rb.is_heap_allocated()) {
                if (ra.is_heap_allocated()) {
                    vm.heap.decref_tval(ra);
                }
                *ra = *rb;
            } else {
                vm.heap.tval_copy_ref(ra, rb);
                track_heap_store(ds.act, ra, (uint)insn.a);
            }
            continue;

        case Opcode.LDCONST: {
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                vm.heap.tval_copy_ref(ra, &ds.constants[bc]);
            } else {
                ra.set_undefined();
            }
            continue;
        }

        case Opcode.LDINT:
            ra.set_fastint((long)insn.get_sbc());
            continue;

        case Opcode.LDINTX: {
            long ix_high = ra.get_fastint();
            ra.set_fastint((ix_high << 16) | (long)insn.get_bc());
            continue;
        }

        case Opcode.LDUNDEF:
            ra.set_undefined();
            continue;

        case Opcode.LDNULL:
            ra.set_null();
            continue;

        case Opcode.LDTRUE:
            ra.set_boolean(true);
            continue;

        case Opcode.LDFALSE:
            ra.set_boolean(false);
            continue;

        case Opcode.LDTHIS:
            vm.heap.tval_copy_ref(ra, &ds.act.this_binding);
            track_heap_store(ds.act, ra, (uint)insn.a);
            continue;

        // === ARITHMETIC ===
        case Opcode.ADD: {
            // ES5 §11.6.1: ToPrimitive both, then string concat or numeric add
            // Fast path: FASTINT + FASTINT — most common in arithmetic benchmarks.
            // Check this BEFORE OBJECT/STRING to avoid unnecessary tag dispatch.
            if (types::both_fastint(rb, rc)) {
                long sum = rb.get_fastint() + rc.get_fastint();
                if (sum >= types::FASTINT_MIN && sum <= types::FASTINT_MAX) {
                    ra.set_fastint(sum);
                } else {
                    ra.set_number((double)sum);
                }
                continue;
            }
            // Fast path: STRING + FASTINT or FASTINT + STRING
            // Format the integer directly into the concat buffer, avoiding
            // the intermediate HString allocation for the integer.
            if ((rb.is_string() && rc.is_fastint()) || (rb.is_fastint() && rc.is_string())) {
                HString* str;
                long int_val;
                if (rb.is_string()) {
                    str = (HString*)rb.get_heapptr();
                    int_val = rc.get_fastint();
                } else {
                    str = (HString*)rc.get_heapptr();
                    int_val = rb.get_fastint();
                }
                if (str != null) {
                    char[32] int_buf;
                    int int_len = hstring::int_to_buf(int_val, &int_buf, 32);
                    if (int_len > 0) {
                        uint s_len = str.blen;
                        uint total = s_len + (uint)int_len;
                        char[544] stack_buf;
                        char* buf;
                        bool heap_allocated = false;
                        if (total <= 544) {
                            buf = &stack_buf;
                        } else {
                            buf = (char*)vm.heap.alloc_func(vm.heap.heap_udata, total);
                            if (buf == null) { ra.set_undefined(); break; }
                            heap_allocated = true;
                        }
                        if (rb.is_string()) {
                            libc::memcpy(buf, str.get_cstr(), s_len);
                            libc::memcpy(buf + s_len, &int_buf, (usz)int_len);
                        } else {
                            libc::memcpy(buf, &int_buf, (usz)int_len);
                            libc::memcpy(buf + int_len, str.get_cstr(), s_len);
                        }
                        // Skip interning for accumulator (ra == source register),
                        // intern for new strings that may be used as property keys.
                        bool is_accum = (ra == rb || ra == rc);
                        if (is_accum) {
                            uint hash = vm.heap.hash_string(buf[:total]);
                            HString*? maybe_s = hstring::hstring_alloc((void*)vm.heap, buf[:total], hash);
                            if (heap_allocated) vm.heap.free_func(vm.heap.heap_udata, buf);
                            if (try s = maybe_s) {
                                vm.heap.set_reg_string(ra, s);
                            } else {
                                ra.set_undefined();
                            }
                        } else {
                            HString* interned = intern_string(vm, buf[:total]);
                            if (heap_allocated) vm.heap.free_func(vm.heap.heap_udata, buf);
                            vm.heap.set_reg_string(ra, interned);
                        }
                        continue;
                    }
                }
                // Fall through to generic path if str is null or int_to_buf failed
            }
            TVal prim_b = *rb;
            TVal prim_c = *rc;
            // ES5 §11.6.1: + operator uses ToPrimitive with no hint (default "number")
            if (rb.get_tag() == OBJECT) { prim_b = to_primitive_value(vm, rb, false); }
            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
            if (ds.needs_restart) break;
            if (rc.get_tag() == OBJECT) { prim_c = to_primitive_value(vm, rc, false); }
            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
            if (ds.needs_restart) break;
            TValTag pt_b = prim_b.get_tag();
            TValTag pt_c = prim_c.get_tag();
            if (pt_b == STRING || pt_c == STRING) {
                HString*? left_str = vm_to_string(vm, &prim_b);
                if (vm.throw_pending) {
                    if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                    continue;
                }
                HString*? right_str = vm_to_string(vm, &prim_c);
                if (vm.throw_pending) {
                    if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                    continue;
                }
                if (try ls = left_str && try rs = right_str) {
                    uint a_len = ls.blen;
                    uint b_len = rs.blen;
                    uint total = a_len + b_len;

                    // Use stack buffer for small strings, heap for large
                    char[512] stack_buf;
                    char* buf;
                    bool heap_allocated = false;
                    if (total <= 512) {
                        buf = &stack_buf;
                    } else {
                        buf = (char*)vm.heap.alloc_func(vm.heap.heap_udata, total);
                        if (buf == null) { ra.set_undefined(); break; }
                        heap_allocated = true;
                    }

                    // Copy both halves directly into buffer
                    if (a_len > 0) {
                        libc::memcpy(buf, ls.get_cstr(), a_len);
                    }
                    if (b_len > 0) {
                        libc::memcpy(buf + a_len, rs.get_cstr(), b_len);
                    }

                    // Skip interning for accumulator (ra == source register),
                    // intern for new strings that may be used as property keys.
                    bool is_accum = (ra == rb || ra == rc);
                    if (is_accum) {
                        uint hash = vm.heap.hash_string(buf[:total]);
                        HString*? maybe_s = hstring::hstring_alloc((void*)vm.heap, buf[:total], hash);
                        if (heap_allocated) vm.heap.free_func(vm.heap.heap_udata, buf);
                        if (try s = maybe_s) {
                            vm.heap.set_reg_string(ra, s);
                        } else {
                            ra.set_undefined();
                        }
                    } else {
                        HString* interned = intern_string(vm, buf[:total]);
                        if (heap_allocated) vm.heap.free_func(vm.heap.heap_udata, buf);
                        vm.heap.set_reg_string(ra, interned);
                    }
                } else {
                    ra.set_undefined();
                }
            } else {
                double add_b = vm_to_number(vm,&prim_b);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                double add_c = vm_to_number(vm,&prim_c);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                ra.set_number(add_b + add_c);
            }
        }

        case Opcode.SUB:
            if (types::both_fastint(rb, rc)) {
                long diff = rb.get_fastint() - rc.get_fastint();
                if (diff >= types::FASTINT_MIN && diff <= types::FASTINT_MAX) {
                    ra.set_fastint(diff);
                } else {
                    ra.set_number((double)diff);
                }
            } else {
                double sub_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                if (ds.needs_restart) break;
                double sub_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                ra.set_number(sub_b - sub_c);
            }
            continue;

        case Opcode.MUL:
            if (types::both_fastint(rb, rc)) {
                // 48-bit operands can overflow 64-bit signed long (2^47 * 2^47 = 2^94).
                // Guard: if both operands fit in 31 bits the product fits in 62 bits
                // and is safely range-checked; otherwise fall through to double path.
                long mul_b = rb.get_fastint();
                long mul_c = rc.get_fastint();
                if (mul_b >= -0x40000000L && mul_b <= 0x3FFFFFFFL &&
                    mul_c >= -0x40000000L && mul_c <= 0x3FFFFFFFL) {
                    long mul_result = mul_b * mul_c;
                    if (mul_result >= types::FASTINT_MIN && mul_result <= types::FASTINT_MAX) {
                        ra.set_fastint(mul_result);
                    } else {
                        ra.set_number((double)mul_result);
                    }
                } else {
                    ra.set_number((double)mul_b * (double)mul_c);
                }
            } else {
                double mul_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                if (ds.needs_restart) break;
                double mul_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                ra.set_number(mul_b * mul_c);
            }
            continue;

        case Opcode.DIV: {
            double div_b = vm_to_number(vm,rb);
            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
            if (ds.needs_restart) break;
            double div_c = vm_to_number(vm,rc);
            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
            ra.set_number(div_b / div_c);
            continue;
        }

        case Opcode.MOD:
            if (types::both_fastint(rb, rc) && rc.get_fastint() != 0) {
                long mod_result = rb.get_fastint() % rc.get_fastint();
                if (mod_result == 0 && rb.get_fastint() < 0) {
                    // -1 % 1 → -0: sign of zero matches dividend per ES5 §11.5.3
                    ra.set_number(-0.0);
                } else {
                    ra.set_fastint(mod_result);
                }
            } else {
                double mod_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                if (ds.needs_restart) break;
                double mod_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                ra.set_number((mod_b % mod_c));
            }
            continue;

        case Opcode.EXP: {
            double exp_b = vm_to_number(vm,rb);
            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
            if (ds.needs_restart) break;
            double exp_c = vm_to_number(vm,rc);
            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
            ra.set_number(math::pow(exp_b, exp_c));
            continue;
        }

        // === UNARY ===
        case Opcode.UNP:
        case Opcode.UNM:
        case Opcode.BNOT:
        case Opcode.LNOT:
        case Opcode.TYPEOF:
        case Opcode.VOID:
        case Opcode.INC:
        case Opcode.DEC:
        case Opcode.PUTARG:
        case Opcode.INC_VAR:
        case Opcode.DEC_VAR:
            if (catch err = dispatch_unary(&ds, op, ra, rb, rc, insn)) { return err~; }
            continue;

        // === BITWISE ===
        case Opcode.BAND:
            // Bitwise ops always produce Int32, always fit in FASTINT.
            // Fast path: FASTINTs are already integer-valued; cast directly to int
            // instead of round-tripping through double + toint32.
        {
            if (types::both_fastint(rb, rc)) {
                ra.set_fastint((long)((int)rb.get_fastint() & (int)rc.get_fastint()));
                continue;
            }
            int band_b = toint32(vm_to_number(vm,rb));
            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
            if (ds.needs_restart) break;
            int band_c = toint32(vm_to_number(vm,rc));
            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
            ra.set_fastint((long)(band_b & band_c));
            continue;
        }

        case Opcode.BOR:
        {
            if (types::both_fastint(rb, rc)) {
                ra.set_fastint((long)((int)rb.get_fastint() | (int)rc.get_fastint()));
                continue;
            }
            int bor_b = toint32(vm_to_number(vm,rb));
            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
            if (ds.needs_restart) break;
            int bor_c = toint32(vm_to_number(vm,rc));
            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
            ra.set_fastint((long)(bor_b | bor_c));
            continue;
        }

        case Opcode.BXOR:
        {
            if (types::both_fastint(rb, rc)) {
                ra.set_fastint((long)((int)rb.get_fastint() ^ (int)rc.get_fastint()));
                continue;
            }
            int bxor_b = toint32(vm_to_number(vm,rb));
            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
            if (ds.needs_restart) break;
            int bxor_c = toint32(vm_to_number(vm,rc));
            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
            ra.set_fastint((long)(bxor_b ^ bxor_c));
            continue;
        }

        case Opcode.SHL:
        {
            if (types::both_fastint(rb, rc)) {
                ra.set_fastint((long)((int)rb.get_fastint() << ((int)rc.get_fastint() & 0x1F)));
                continue;
            }
            int shl_b = toint32(vm_to_number(vm,rb));
            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
            if (ds.needs_restart) break;
            int shl_c = toint32(vm_to_number(vm,rc));
            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
            ra.set_fastint((long)(shl_b << (shl_c & 0x1F)));
            continue;
        }

        case Opcode.SHR:
        {
            if (types::both_fastint(rb, rc)) {
                ra.set_fastint((long)((int)rb.get_fastint() >> ((int)rc.get_fastint() & 0x1F)));
                continue;
            }
            int shr_b = toint32(vm_to_number(vm,rb));
            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
            if (ds.needs_restart) break;
            int shr_c = toint32(vm_to_number(vm,rc));
            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
            ra.set_fastint((long)(shr_b >> (shr_c & 0x1F)));
            continue;
        }

        case Opcode.USHR:
        {
            uint ushr_b = (uint)toint32(vm_to_number(vm,rb));
            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
            if (ds.needs_restart) break;
            int  ushr_c = toint32(vm_to_number(vm,rc));
            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
            ra.set_fastint((long)(ushr_b >> (ushr_c & 0x1F)));
            continue;
        }

        // === COMPARISON ===
        case Opcode.EQ:
            ra.set_boolean(abstract_eq(vm, rb, rc));
            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
            continue;

        case Opcode.NEQ:
            ra.set_boolean(!abstract_eq(vm, rb, rc));
            if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
            continue;

        case Opcode.SEQ: {
            // Fast path: FASTINT === FASTINT — most common in loop counters and
            // arithmetic benchmarks. Short-circuit before full tag dispatch.
            if (types::both_fastint(rb, rc)) {
                ra.set_boolean(rb.get_fastint() == rc.get_fastint());
                continue;
            }
            bool seq_r = false;
            TValTag tag_b = rb.get_tag();
            TValTag tag_c = rc.get_tag();
            if (tag_b == tag_c) {
                switch (tag_b) {
                    case UNDEFINED: seq_r = true; break;
                    case NULL_VAL:  seq_r = true; break;
                    case BOOLEAN:   seq_r = (rb.get_boolean() == rc.get_boolean()); break;
                    case NUMBER:
                        if (math::is_nan(rb.get_number()) || math::is_nan(rc.get_number())) {
                            seq_r = false;
                        } else {
                            seq_r = (rb.get_number() == rc.get_number());
                        }
                        break;
                    case FASTINT:   seq_r = (rb.get_fastint() == rc.get_fastint()); break;
                    case STRING: {
                        HString* sa = (HString*)rb.get_heapptr();
                        HString* sb = (HString*)rc.get_heapptr();
                        seq_r = sa != null && sb != null && sa.equals_hstring(sb);
                        break;
                    }
                    case OBJECT:    seq_r = (rb.get_heapptr() == rc.get_heapptr()); break;
                    case LIGHTFUNC: seq_r = (rb.get_heapptr() == rc.get_heapptr()); break;
                    case POINTER:   seq_r = (rb.get_heapptr() == rc.get_heapptr()); break;
                    case BUFFER:    seq_r = (rb.get_heapptr() == rc.get_heapptr()); break;
                    default: break;
                }
            } else if ((tag_b == NUMBER && tag_c == FASTINT) ||
                       (tag_b == FASTINT && tag_c == NUMBER)) {
                double nb = (tag_b == FASTINT) ? (double)rb.get_fastint() : rb.get_number();
                double nc = (tag_c == FASTINT) ? (double)rc.get_fastint() : rc.get_number();
                seq_r = (nb == nc);
            }
            ra.set_boolean(seq_r);
            continue;
        }

        case Opcode.SNEQ: {
            // Fast path: FASTINT !== FASTINT — short-circuit before full tag dispatch.
            if (rb.is_fastint() && rc.is_fastint()) {
                ra.set_boolean(rb.get_fastint() != rc.get_fastint());
                continue;
            }
            bool sneq_r = true;
            TValTag tag_b = rb.get_tag();
            TValTag tag_c = rc.get_tag();
            if (tag_b == tag_c) {
                switch (tag_b) {
                    case UNDEFINED: sneq_r = false; break;
                    case NULL_VAL:  sneq_r = false; break;
                    case BOOLEAN:   sneq_r = (rb.get_boolean() != rc.get_boolean()); break;
                    case NUMBER:
                        if (math::is_nan(rb.get_number()) || math::is_nan(rc.get_number())) {
                            sneq_r = true;
                        } else {
                            sneq_r = (rb.get_number() != rc.get_number());
                        }
                        break;
                    case FASTINT:   sneq_r = (rb.get_fastint() != rc.get_fastint()); break;
                    case STRING: {
                        HString* sa = (HString*)rb.get_heapptr();
                        HString* sb = (HString*)rc.get_heapptr();
                        sneq_r = !(sa != null && sb != null && sa.equals_hstring(sb));
                        break;
                    }
                    case OBJECT:    sneq_r = (rb.get_heapptr() != rc.get_heapptr()); break;
                    case LIGHTFUNC: sneq_r = (rb.get_heapptr() != rc.get_heapptr()); break;
                    case POINTER:   sneq_r = (rb.get_heapptr() != rc.get_heapptr()); break;
                    case BUFFER:    sneq_r = (rb.get_heapptr() != rc.get_heapptr()); break;
                    default: break;
                }
            } else if ((tag_b == NUMBER && tag_c == FASTINT) ||
                       (tag_b == FASTINT && tag_c == NUMBER)) {
                double nb = (tag_b == FASTINT) ? (double)rb.get_fastint() : rb.get_number();
                double nc = (tag_c == FASTINT) ? (double)rc.get_fastint() : rc.get_number();
                sneq_r = (nb != nc);
            }
            ra.set_boolean(sneq_r);
            continue;
        }

        case Opcode.LT: {
            bool result;
            if (types::both_fastint(rb, rc)) {
                result = rb.get_fastint() < rc.get_fastint();
            } else if ((rb.is_fastint() || rb.is_number()) && (rc.is_fastint() || rc.is_number())) {
                result = tval_numeric_to_double(rb) < tval_numeric_to_double(rc);
            } else if (rb.is_string() && rc.is_string()) {
                result = hstring::hstring_compare((HString*)rb.get_heapptr(), (HString*)rc.get_heapptr()) < 0;
            } else {
                double lt_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                if (ds.needs_restart) break;
                double lt_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                result = lt_b < lt_c;
            }
            ra.set_boolean(result);
            continue;
        }

        case Opcode.LE: {
            bool result;
            if (types::both_fastint(rb, rc)) {
                result = rb.get_fastint() <= rc.get_fastint();
            } else if ((rb.is_fastint() || rb.is_number()) && (rc.is_fastint() || rc.is_number())) {
                result = tval_numeric_to_double(rb) <= tval_numeric_to_double(rc);
            } else if (rb.is_string() && rc.is_string()) {
                result = hstring::hstring_compare((HString*)rb.get_heapptr(), (HString*)rc.get_heapptr()) <= 0;
            } else {
                double le_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                if (ds.needs_restart) break;
                double le_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                result = le_b <= le_c;
            }
            ra.set_boolean(result);
            continue;
        }

        case Opcode.GT: {
            bool result;
            if (types::both_fastint(rb, rc)) {
                result = rb.get_fastint() > rc.get_fastint();
            } else if ((rb.is_fastint() || rb.is_number()) && (rc.is_fastint() || rc.is_number())) {
                result = tval_numeric_to_double(rb) > tval_numeric_to_double(rc);
            } else if (rb.is_string() && rc.is_string()) {
                result = hstring::hstring_compare((HString*)rb.get_heapptr(), (HString*)rc.get_heapptr()) > 0;
            } else {
                double gt_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                if (ds.needs_restart) break;
                double gt_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                result = gt_b > gt_c;
            }
            ra.set_boolean(result);
            continue;
        }

        case Opcode.GE: {
            bool result;
            if (types::both_fastint(rb, rc)) {
                result = rb.get_fastint() >= rc.get_fastint();
            } else if ((rb.is_fastint() || rb.is_number()) && (rc.is_fastint() || rc.is_number())) {
                result = tval_numeric_to_double(rb) >= tval_numeric_to_double(rc);
            } else if (rb.is_string() && rc.is_string()) {
                result = hstring::hstring_compare((HString*)rb.get_heapptr(), (HString*)rc.get_heapptr()) >= 0;
            } else {
                double ge_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                if (ds.needs_restart) break;
                double ge_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                result = ge_b >= ge_c;
            }
            ra.set_boolean(result);
            continue;
        }

        // === FUSED COMPARE-AND-BRANCH ===
        // Each op replicates the corresponding compare's exact semantics, then
        // branches if the result is FALSE (i.e. branches when condition does NOT hold).
        // Offset in A (signed 8-bit, cast via char) is relative to the already-
        // incremented pc (same convention as IF_FALSE).
        // NaN: !(NaN op x) is always true, so the branch IS taken — correct because
        // we negate the same compare result that IF_FALSE would have tested.

        case Opcode.JMP_NLT: {
            bool jmp_result;
            if (types::both_fastint(rb, rc)) {
                jmp_result = rb.get_fastint() < rc.get_fastint();
            } else if ((rb.is_fastint() || rb.is_number()) && (rc.is_fastint() || rc.is_number())) {
                jmp_result = tval_numeric_to_double(rb) < tval_numeric_to_double(rc);
            } else if (rb.is_string() && rc.is_string()) {
                jmp_result = hstring::hstring_compare((HString*)rb.get_heapptr(), (HString*)rc.get_heapptr()) < 0;
            } else {
                double jnlt_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                if (ds.needs_restart) break;
                double jnlt_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                jmp_result = jnlt_b < jnlt_c;
            }
            if (!jmp_result) { if ((ichar)insn.a < 0) { if (--vm.heap.bwd_gc_budget == 0) { if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); } vm.heap.bwd_gc_budget = heap::BWD_GC_INTERVAL; } } ds.curr_pc += (int)(ichar)insn.a; }
            continue;
        }

        case Opcode.JMP_NLE: {
            bool jmp_result;
            if (types::both_fastint(rb, rc)) {
                jmp_result = rb.get_fastint() <= rc.get_fastint();
            } else if ((rb.is_fastint() || rb.is_number()) && (rc.is_fastint() || rc.is_number())) {
                jmp_result = tval_numeric_to_double(rb) <= tval_numeric_to_double(rc);
            } else if (rb.is_string() && rc.is_string()) {
                jmp_result = hstring::hstring_compare((HString*)rb.get_heapptr(), (HString*)rc.get_heapptr()) <= 0;
            } else {
                double jnle_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                if (ds.needs_restart) break;
                double jnle_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                jmp_result = jnle_b <= jnle_c;
            }
            if (!jmp_result) { if ((ichar)insn.a < 0) { if (--vm.heap.bwd_gc_budget == 0) { if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); } vm.heap.bwd_gc_budget = heap::BWD_GC_INTERVAL; } } ds.curr_pc += (int)(ichar)insn.a; }
            continue;
        }

        case Opcode.JMP_NGT: {
            bool jmp_result;
            if (types::both_fastint(rb, rc)) {
                jmp_result = rb.get_fastint() > rc.get_fastint();
            } else if ((rb.is_fastint() || rb.is_number()) && (rc.is_fastint() || rc.is_number())) {
                jmp_result = tval_numeric_to_double(rb) > tval_numeric_to_double(rc);
            } else if (rb.is_string() && rc.is_string()) {
                jmp_result = hstring::hstring_compare((HString*)rb.get_heapptr(), (HString*)rc.get_heapptr()) > 0;
            } else {
                double jngt_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                if (ds.needs_restart) break;
                double jngt_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                jmp_result = jngt_b > jngt_c;
            }
            if (!jmp_result) { if ((ichar)insn.a < 0) { if (--vm.heap.bwd_gc_budget == 0) { if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); } vm.heap.bwd_gc_budget = heap::BWD_GC_INTERVAL; } } ds.curr_pc += (int)(ichar)insn.a; }
            continue;
        }

        case Opcode.JMP_NGE: {
            bool jmp_result;
            if (types::both_fastint(rb, rc)) {
                jmp_result = rb.get_fastint() >= rc.get_fastint();
            } else if ((rb.is_fastint() || rb.is_number()) && (rc.is_fastint() || rc.is_number())) {
                jmp_result = tval_numeric_to_double(rb) >= tval_numeric_to_double(rc);
            } else if (rb.is_string() && rc.is_string()) {
                jmp_result = hstring::hstring_compare((HString*)rb.get_heapptr(), (HString*)rc.get_heapptr()) >= 0;
            } else {
                double jnge_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                if (ds.needs_restart) break;
                double jnge_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                jmp_result = jnge_b >= jnge_c;
            }
            if (!jmp_result) { if ((ichar)insn.a < 0) { if (--vm.heap.bwd_gc_budget == 0) { if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); } vm.heap.bwd_gc_budget = heap::BWD_GC_INTERVAL; } } ds.curr_pc += (int)(ichar)insn.a; }
            continue;
        }

        case Opcode.JMP_LT: {
            bool jmp_result;
            if (rb.is_fastint() && rc.is_fastint()) {
                jmp_result = rb.get_fastint() < rc.get_fastint();
            } else if ((rb.is_fastint() || rb.is_number()) && (rc.is_fastint() || rc.is_number())) {
                jmp_result = tval_numeric_to_double(rb) < tval_numeric_to_double(rc);
            } else if (rb.is_string() && rc.is_string()) {
                jmp_result = hstring::hstring_compare((HString*)rb.get_heapptr(), (HString*)rc.get_heapptr()) < 0;
            } else {
                double jlt_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                if (ds.needs_restart) break;
                double jlt_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                jmp_result = jlt_b < jlt_c;
            }
            if (jmp_result) { if ((ichar)insn.a < 0) { if (--vm.heap.bwd_gc_budget == 0) { if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); } vm.heap.bwd_gc_budget = heap::BWD_GC_INTERVAL; } } ds.curr_pc += (int)(ichar)insn.a; }
            continue;
        }

        case Opcode.JMP_LE: {
            bool jmp_result;
            if (rb.is_fastint() && rc.is_fastint()) {
                jmp_result = rb.get_fastint() <= rc.get_fastint();
            } else if ((rb.is_fastint() || rb.is_number()) && (rc.is_fastint() || rc.is_number())) {
                jmp_result = tval_numeric_to_double(rb) <= tval_numeric_to_double(rc);
            } else if (rb.is_string() && rc.is_string()) {
                jmp_result = hstring::hstring_compare((HString*)rb.get_heapptr(), (HString*)rc.get_heapptr()) <= 0;
            } else {
                double jle_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                if (ds.needs_restart) break;
                double jle_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                jmp_result = jle_b <= jle_c;
            }
            if (jmp_result) { if ((ichar)insn.a < 0) { if (--vm.heap.bwd_gc_budget == 0) { if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); } vm.heap.bwd_gc_budget = heap::BWD_GC_INTERVAL; } } ds.curr_pc += (int)(ichar)insn.a; }
            continue;
        }

        case Opcode.JMP_GT: {
            bool jmp_result;
            if (rb.is_fastint() && rc.is_fastint()) {
                jmp_result = rb.get_fastint() > rc.get_fastint();
            } else if ((rb.is_fastint() || rb.is_number()) && (rc.is_fastint() || rc.is_number())) {
                jmp_result = tval_numeric_to_double(rb) > tval_numeric_to_double(rc);
            } else if (rb.is_string() && rc.is_string()) {
                jmp_result = hstring::hstring_compare((HString*)rb.get_heapptr(), (HString*)rc.get_heapptr()) > 0;
            } else {
                double jgt_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                if (ds.needs_restart) break;
                double jgt_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                jmp_result = jgt_b > jgt_c;
            }
            if (jmp_result) { if ((ichar)insn.a < 0) { if (--vm.heap.bwd_gc_budget == 0) { if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); } vm.heap.bwd_gc_budget = heap::BWD_GC_INTERVAL; } } ds.curr_pc += (int)(ichar)insn.a; }
            continue;
        }

        case Opcode.JMP_GE: {
            bool jmp_result;
            if (rb.is_fastint() && rc.is_fastint()) {
                jmp_result = rb.get_fastint() >= rc.get_fastint();
            } else if ((rb.is_fastint() || rb.is_number()) && (rc.is_fastint() || rc.is_number())) {
                jmp_result = tval_numeric_to_double(rb) >= tval_numeric_to_double(rc);
            } else if (rb.is_string() && rc.is_string()) {
                jmp_result = hstring::hstring_compare((HString*)rb.get_heapptr(), (HString*)rc.get_heapptr()) >= 0;
            } else {
                double jge_b = vm_to_number(vm,rb);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                if (ds.needs_restart) break;
                double jge_c = vm_to_number(vm,rc);
                if (!vm_check_to_number_throw(vm, ds.act, &ds.curr_pc, &ds.needs_restart)) return vm_uncaught_error(vm, &vm.throw_value);
                jmp_result = jge_b >= jge_c;
            }
            if (jmp_result) { if ((ichar)insn.a < 0) { if (--vm.heap.bwd_gc_budget == 0) { if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); } vm.heap.bwd_gc_budget = heap::BWD_GC_INTERVAL; } } ds.curr_pc += (int)(ichar)insn.a; }
            continue;
        }

        case Opcode.INSTANCEOF: {
            // ES5 §11.8.6: RelationalExpression instanceof ShiftExpression
            // ra may alias rb (compiler optimization), so read rb before writing ra.
            TVal lval = *rb;
            TVal rval = *rc;
            ra.set_boolean(false);

            if (rval.is_lightfunc()) {
                // LIGHTFUNC builtins are callable; look up their prototype
                uint fn_idx = (uint)(usz)rval.get_heapptr();
                HObject* proto_obj = lightfunc_get_proto(vm, fn_idx);
                if (proto_obj != null && lval.is_object()) {
                    HObject* lbh = (HObject*)lval.get_heapptr();
                    if (lbh.is_prototype_of(proto_obj)) {
                        ra.set_boolean(true);
                    }
                }
                continue;
            }

            if (!rval.is_object()) {
                // TypeError: right-hand side must be an object
                if (!vm_throw_error(vm, vm.heap.type_err_proto, "Right-hand side of instanceof is not an object", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return VM_ERROR~;
                }
                continue;
            }

            HObject* rfunc = (HObject*)rval.get_heapptr();
            if (rfunc == null || !rfunc.is_callable()) {
                // TypeError: right-hand side must be callable
                if (!vm_throw_error(vm, vm.heap.type_err_proto, "Right-hand side of instanceof is not callable", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return VM_ERROR~;
                }
                continue;
            }

            // ES6 §12.10.4: Check Symbol.hasInstance on the constructor
            if (vm.heap.hasinstance_symbol != null) {
                HString* hasinst_key = vm.heap.hasinstance_symbol;
                TVal? hasinst_val = rfunc.get_prop_proto(hasinst_key);
                if (try hasinst_fn = hasinst_val) {
                    bool hasinst_callable = hasinst_fn.is_lightfunc() ||
                        (hasinst_fn.is_object() && hasinst_fn.get_heapptr() != null &&
                         ((HObject*)hasinst_fn.get_heapptr()).is_callable());
                    if (hasinst_callable) {
                        // Call @@hasInstance with this=rval, arg=lval
                        TVal result = vm.heap.call_fn(vm, hasinst_fn, &lval, 1, rval);
                        if (vm_check_call_fn_error(vm)) return VM_ERROR~;
                        ra.set_boolean(builtins::builtin_to_boolean(&result));
                        continue;
                    }
                }
            }

            // §15.3.5.3 step 1: If Type(lval) is not Object → false
            if (!lval.is_object()) {
                continue;
            }

            // Get rval.prototype — ES6 §7.3.19 OrdinaryHasInstance step 4: Let P be Get(C, "prototype").
            // Get() must invoke accessor getters (per ES6 §7.3.1), so we first
            // check for an accessor property in the prototype chain and call
            // its getter; otherwise fall back to the raw data-property value.
            HString* proto_key_str = (HString*)vm.heap.strs[heap::BuiltinStr.PROTOTYPE];
            TVal proto_val;
            AccessorResult acc = rfunc.find_accessor_proto(proto_key_str, true);
            if (acc.found) {
                // ES6 §7.3.1 Get(O, P) — if accessor has a getter, call it with
                // `this` bound to the original receiver (rfunc). The getter
                // may throw or return any value.
                TVal this_for_getter;
                this_for_getter.set_object(rfunc);
                proto_val = vm.heap.call_fn(vm, acc.accessor_fn, null, 0, this_for_getter);
                if (vm_check_call_fn_error(vm)) return VM_ERROR~;
            } else {
                proto_val = get_prop_with_proto(rfunc, proto_key_str);
            }
            if (!proto_val.is_object()) {
                // ES6 §7.3.19 OrdinaryHasInstance step 6: If Type(P) is not
                // Object, throw a TypeError exception. The spec does NOT
                // allow the silent-false fallback — the result must always
                // be defined (or an abrupt completion).
                if (!vm_throw_error(vm, vm.heap.type_err_proto, "'prototype' property is not an object", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return VM_ERROR~;
                }
                continue;
            }

            HObject* proto_obj = (HObject*)proto_val.get_heapptr();
            HObject* cur = (HObject*)lval.get_heapptr();
            if (cur.is_prototype_of(proto_obj)) {
                ra.set_boolean(true);
            }
            continue;
        }

        case Opcode.IN: {
            // ES5 §11.8.7: RelationalExpression in ShiftExpression
            // Right side must be an object; TypeError otherwise.
            // Returns true if the object has a property with the given name
            // (own or inherited — check via [[HasProperty]]).
            //
            // NOTE: Read rb (key) BEFORE writing ra, because ra may alias rb
            // (compiler can emit IN r3, r3, r4 when result overwrites the key).
            if (!rc.is_object()) {
                ra.set_boolean(false);
                if (!vm_throw_error(vm, vm.heap.type_err_proto, "in requires an object", ds.act, &ds.curr_pc, &ds.needs_restart)) {
                    return VM_ERROR~;
                }
                continue;
            }

            HObject* obj = (HObject*)rc.get_heapptr();

            // TypedArray: numeric index membership (0..length-1, not detached).
            if (obj.get_class() >= hobject::ObjClass.INT8ARRAY && obj.get_class() <= hobject::ObjClass.FLOAT64ARRAY) {
                long idx_long = -1;
                bool is_int_idx = false;
                if (rb.is_fastint()) { idx_long = rb.get_fastint(); is_int_idx = true; }
                else if (rb.is_number()) {
                    double d = rb.get_number();
                    idx_long = (long)d;
                    is_int_idx = (d == (double)idx_long);
                } else if (rb.is_string()) {
                    HString* skey = (HString*)rb.get_heapptr();
                    if (skey != null && skey.is_arridx()) { idx_long = (long)skey.array_index(); is_int_idx = true; }
                }
                if (is_int_idx) {
                    HObject* buf = (*obj.extra_ptr()).view.buffer;
                    uint shift = builtins::ta_elem_shift(obj.get_class());
                    uint elem_count = (*obj.extra_ptr()).view.byte_length >> shift;
                    ra.set_boolean(idx_long >= 0 && buf != null && (*buf.extra_ptr()).ab.data != null
                        && (ulong)idx_long < (ulong)elem_count);
                    continue;
                }
            }

            // Fast path: dense array / arguments indexed check (numeric keys)
            if ((obj.get_class() == hobject::ObjClass.ARRAY || obj.get_class() == hobject::ObjClass.ARGUMENTS) && obj.array_part() != null && (rb.is_fastint() || rb.is_number())) {
                long idx_long = rb.is_fastint() ? rb.get_fastint() : (long)rb.get_number();
                if (idx_long >= 0 && idx_long < (long)obj.array_size) {
                    TVal? av = obj.get_array_idx((uint)idx_long);
                    if (try v = av) {
                        ra.set_boolean(true);
                        continue;
                    }
                    // Array hole — fall through to prototype chain lookup
                } else {
                    // Index out of bounds — check prototype only
                    void* key = get_prop_key(vm, rb);
                    if (key != null) {
                        ra.set_boolean(obj.prototype != null && obj.prototype.has_prop_proto(key));
                    } else {
                        ra.set_boolean(false);
                    }
                    continue;
                }
            }

            // Fast path: dense array with string key that might be an index
            if ((obj.get_class() == hobject::ObjClass.ARRAY || obj.get_class() == hobject::ObjClass.ARGUMENTS) && obj.array_part() != null && rb.is_string()) {
                HString* skey = (HString*)rb.get_heapptr();
                uint skey_idx = skey.array_index();
                if (skey_idx != hstring::ARRIDX_NONE && skey_idx < (uint)obj.array_size) {
                    TVal? av = obj.get_array_idx(skey_idx);
                    if (try v = av) {
                        ra.set_boolean(true);
                        continue;
                    }
                }
            }

            void* key = get_prop_key(vm, rb);
            if (key != null) {
                // STRING exotic: integer index keys in [0, clen) are own properties served lazily.
                if (obj.flags.exotic_stringobj && (*obj.extra_ptr()).prim.primitive_value.is_string()) {
                    HString* key_hstr = (HString*)key;
                    if (key_hstr != null && key_hstr.is_arridx()) {
                        HString* prim_str = (HString*)(*obj.extra_ptr()).prim.primitive_value.get_heapptr();
                        if (prim_str != null && key_hstr.array_index() < prim_str.char_length()) {
                            ra.set_boolean(true);
                            continue;
                        }
                    }
                }
                ra.set_boolean(obj.has_prop_proto(key));
            } else {
                ra.set_boolean(false);
            }
            continue;
        }

        // === CONTROL FLOW ===
        case Opcode.JUMP: {
            int sabc = insn.get_sabc();
            int target = (int)((long)(ds.curr_pc - ds.code_base) + (long)sabc);
            if (target < (ds.curr_pc - ds.code_base)) { if (--vm.heap.bwd_gc_budget == 0) { if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); } vm.heap.bwd_gc_budget = heap::BWD_GC_INTERVAL; } }
            ds.curr_pc = ds.code_base + target;
            continue;
        }

        case Opcode.IF_TRUE:
            if (is_truthy(ra)) {
                int sbx = insn.get_sbc();
                int target = (int)((long)(ds.curr_pc - ds.code_base) + (long)sbx);
                if (target < (ds.curr_pc - ds.code_base)) { if (--vm.heap.bwd_gc_budget == 0) { if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); } vm.heap.bwd_gc_budget = heap::BWD_GC_INTERVAL; } }
                ds.curr_pc = ds.code_base + target;
            }
            continue;

        case Opcode.IF_FALSE:
            if (!is_truthy(ra)) {
                int sbx = insn.get_sbc();
                int target = (int)((long)(ds.curr_pc - ds.code_base) + (long)sbx);
                if (target < (ds.curr_pc - ds.code_base)) { if (--vm.heap.bwd_gc_budget == 0) { if (vm.heap.gc_pending) { vm.heap.safepoint_gc(); } vm.heap.bwd_gc_budget = heap::BWD_GC_INTERVAL; } }
                ds.curr_pc = ds.code_base + target;
            }
            continue;

        // === PROPERTY ACCESS ===
        // GETPROPC_CACHED is the warm monomorphic IC read — the single hottest
        // property op in tight loops (`p.x`). Inlined; all other property ops
        // (and the IC-miss downgrade path) go through dispatch_property.
        case Opcode.GETPROPC_CACHED: {
            // Specialized GETPROPC: IC is known warm. Only checks shape_id + prop_alloc.
            // Falls back to GETPROPC if the check fails (shape changed or props reallocated).
            // key_tval/key_hstr are only needed on miss; defer them to avoid wasted loads on hit.
            if (rb.is_object() && ds.ic_base != null) {
                HObject* hobj = (HObject*)rb.get_heapptr();
                uint pc_off = (uint)(ds.curr_pc - 1 - ds.code_base);
                hobject::ICEntry* ic = ds.ic_base + pc_off;
                if (ic.shape_id == hobj.shape_id) {
                    HObject* ic_owner;
                    if (ic.proto == null) {
                        // Own-property IC: owner is the receiver itself.
                        ic_owner = hobj;
                    } else if (hobj.prototype == (HObject*)ic.proto) {
                        // Proto IC: receiver's prototype still points to the cached owner.
                        // setPrototypeOf does not change shape_id, so we check explicitly.
                        ic_owner = (HObject*)ic.proto;
                    } else {
                        ic_owner = null;
                    }
                    if (ic_owner != null && ic.cached_prop_alloc == (void*)ic_owner.prop_values()) {
                        TVal ic_val = *ic.prop_value_ptr;
                        if (!ic_val.is_heap_allocated()) {
                            *ra = ic_val;
                        } else {
                            vm.heap.tval_copy_ref(ra, &ic_val);
                            track_heap_store(ds.act, ra, (uint)insn.a);
                        }
                        continue;
                    }
                }
            }
            // IC miss or ds.ic_base null: downgrade back to GETPROPC and re-execute
            ds.curr_pc[-1] = bytecode::make_abc(bytecode::Opcode.GETPROPC,
                                            (uint)insn.a, (uint)insn.b, (uint)insn.c);
            ds.curr_pc--;
            continue;
        }
        case Opcode.GETPROP:
        case Opcode.GETPROPC:
        case Opcode.GETPROPC2:
        case Opcode.PUTPROP:
        case Opcode.DELPROP:
            if (catch err = dispatch_property(&ds, op, ra, rb, rc, insn)) { return err~; }
            continue;

        // === OBJECT / ARRAY CREATION ===
        case Opcode.NEWOBJ:
        case Opcode.NEWARR:
        case Opcode.NEWREGEXP:
        case Opcode.SETALEN:
        case Opcode.ARRSPRD:
        case Opcode.OBJSPRD:
        case Opcode.SPREAD_ARG:
            if (catch err = dispatch_objects(&ds, op, ra, rb, rc, insn)) { return err~; }
            continue;

        // === FUNCTION CALLS ===
        case Opcode.CALL:
        case Opcode.CALL_S:
        case Opcode.CALL_PROP:
        case Opcode.SETPROTO:
        case Opcode.SUPER_CALL:
        case Opcode.SUPER_CALL_S:
        case Opcode.NEWTARGET:
        case Opcode.NEW_OBJ:
        case Opcode.NEW_OBJ_S:
        case Opcode.TAILCALL:
            if (catch err = dispatch_calls(&ds, op, ra, rb, rc, insn)) { return err~; }
            // Refresh regs_base after builtin calls that may have triggered valstack
            // reallocation via heap.call_fn (compiled-function paths set needs_restart
            // and reload via the outer loop; builtin paths return without setting it).
            if (!ds.needs_restart) { ds.regs_base = ds.act.bottom; }
            continue;

        // === GENERATORS ===
        case Opcode.LOAD_RESUME:
        case Opcode.AWAIT:
        case Opcode.YIELD:
        case Opcode.YIELD_STAR:
        case Opcode.GEN_START:
            if (catch err = dispatch_generators(&ds, op, ra, rb, rc, insn)) { return err~; }
            continue;

        // === RETURNS ===
        // RET / RETUNDEF are extremely hot in recursion; inline them here.
        // RET_GEN / RETUNDEF_GEN are generator-only and stay out-of-line.
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
                continue;
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
                ds.halt = true;
                ds.halt_value = vm.return_val;
                continue;
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
            vm.valstack_top = callee_act.caller_valstack_top;
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
            continue;
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
                continue;
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
                ds.halt = true;
                ds.halt_value = vm.return_val;
                continue;
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
            continue;
        }
        case Opcode.RET_GEN:
        case Opcode.RETUNDEF_GEN:
            if (catch err = dispatch_returns(&ds, op, ra)) { return err~; }
            continue;

        // === VARIABLE ACCESS (inlined: hot in var-heavy / recursive code) ===
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
                                        // ENV_STRICT: GETVAR read traps removed — for needs_env=false
                                        // lex_env == parent env, so a hit here is a legitimate parent
                                        // lookup, not own-local. Own-local leaks surface as 'not defined'
                                        // throws and are caught by test/test_register_locals.js.
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
                            // ENV_STRICT: GETVAR read traps removed — for needs_env=false
                            // lex_env == parent env, so a hit here is a legitimate parent
                            // lookup, not own-local. Own-local leaks surface as 'not defined'
                            // throws and are caught by test/test_register_locals.js.

                            TVal v_raw = cur.bindings.prop_values()[idx];
                            if (env::is_tdz_sentinel(&v_raw)) {
                                HString* name_hstr = (HString*)key;
                                if (!vm_throw_error_fmt(vm, vm.heap.ref_err_proto, "Cannot access '%s' before initialization", name_hstr.get_cstr(), ds.act, &ds.curr_pc, &ds.needs_restart)) {
                                    return VM_ERROR~;
                                }
                                found = true; // prevent duplicate error
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
                                // ENV_STRICT: no trap here. For needs_env=false
                                // functions ds.act.var_env IS the parent env (no
                                // own scope), so a binding found at this hop is a
                                // legitimate parent/global lookup, not an own-local
                                // access. A genuine own-local leak instead surfaces
                                // as a "not defined" throw (its DECLVAR was elided
                                // and nothing else defines it), caught by the corpus.

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
                        if (!vm_throw_error_fmt(vm, vm.heap.ref_err_proto, "%s is not defined", name_hstr.get_cstr(), ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return VM_ERROR~;
                        }
                    }
                } else {
                    ra.set_undefined();
                }
            } else {
                ra.set_undefined();
            }
            continue;
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
                                        // ENV_STRICT: TYPEOFIDENT read traps removed — for needs_env=false
                                        // lex_env == parent env, so a hit here is a legitimate parent
                                        // lookup, not own-local. Own-local leaks surface as 'not defined'
                                        // throws and are caught by test/test_register_locals.js.
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
                            // ENV_STRICT: TYPEOFIDENT read traps removed — for needs_env=false
                            // lex_env == parent env, so a hit here is a legitimate parent
                            // lookup, not own-local. Own-local leaks surface as 'not defined'
                            // throws and are caught by test/test_register_locals.js.

                            TVal v_raw = cur.bindings.prop_values()[idx];
                            if (env::is_tdz_sentinel(&v_raw)) {
                                // TDZ: throw ReferenceError (ES6 behavior)
                                HString* name_hstr = (HString*)key;
                                if (!vm_throw_error_fmt(vm, vm.heap.ref_err_proto, "Cannot access '%s' before initialization", name_hstr.get_cstr(), ds.act, &ds.curr_pc, &ds.needs_restart)) {
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
                                // ENV_STRICT: no trap here (var_env == parent env
                                // when needs_env=false; see GETVAR note above).

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
            continue;
        }

        case Opcode.PUTVAR: {
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                TVal name_val = ds.constants[bc];
                if (name_val.is_string()) {
                    void* key = name_val.get_heapptr();
                    // ENV_STRICT TODO: own-vs-parent check for lex_env and var_env walks.
                    // Would need to introspect env_try_put_lex or rewrite walk here.
                    // Combined single-walk: check lex_env, writability, and update in one pass
                    int put_result = env::env_try_put_lex(ds.act.lex_env, key, *ra);
                    if (put_result == -1) {
                        // Const violation — throw TypeError
                        HString* name_hstr = (HString*)key;
                        if (!vm_throw_error_fmt(vm, vm.heap.type_err_proto, "Assignment to constant variable '%s'", name_hstr.get_cstr(), ds.act, &ds.curr_pc, &ds.needs_restart)) {
                            return VM_ERROR~;
                        }
                        break;
                    } else if (put_result == -2) {
                        // TDZ: assignment before initialization — ReferenceError.
                        HString* name_hstr = (HString*)key;
                        if (!vm_throw_error_fmt(vm, vm.heap.ref_err_proto, "Cannot access '%s' before initialization", name_hstr.get_cstr(), ds.act, &ds.curr_pc, &ds.needs_restart)) {
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
            continue;
        }

        case Opcode.DECLVAR: {
            // Declare a `var` binding in the immediate var_env only (no chain walk).
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                TVal name_val = ds.constants[bc];
                if (name_val.is_string()) {
                    void* key = name_val.get_heapptr();

                    $if types::ENV_STRICT:
                    if (vm.current_func.needs_env() == false) { unreachable("ENV_STRICT: needs_env=false fn touched own env: DECLVAR"); }
                    $endif

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
            continue;
        }

        case Opcode.PUTLEX: {
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                TVal name_val = ds.constants[bc];
                if (name_val.is_string()) {
                    void* key = name_val.get_heapptr();

                    $if types::ENV_STRICT:
                    if (vm.current_func.needs_env() == false) { unreachable("ENV_STRICT: needs_env=false fn touched own env: PUTLEX"); }
                    $endif

                    env::env_declare_lex(ds.act.lex_env, key, *ra);
                }
            }
            continue;
        }

        case Opcode.PUTLEX_C: {
            uint bc = insn.get_bc();
            if (bc < vm.current_func.const_count) {
                TVal name_val = ds.constants[bc];
                if (name_val.is_string()) {
                    void* key = name_val.get_heapptr();

                    $if types::ENV_STRICT:
                    if (vm.current_func.needs_env() == false) { unreachable("ENV_STRICT: needs_env=false fn touched own env: PUTLEX_C"); }
                    $endif

                    ds.act.lex_env.bindings.put_prop(key, *ra, hobject::PROP_FLAGS_EC);
                }
            }
            continue;
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

                    // No ENV_STRICT trap here: INITTZ targets the innermost
                    // PUSH_LEX block environment, which exists even for
                    // needs_env=false functions — the elide pass keeps a
                    // sentinel alive when a TYPEOFIDENT references its name.

                    TVal tdz = env::tdz_sentinel();
                    ds.act.lex_env.bindings.put_prop(key, tdz, hobject::PROP_FLAGS_WEC);
                }
            }
            continue;
        }

        case Opcode.DELVAR:
            ra.set_boolean(true);
            continue;

        // === CLOSURES ===
        case Opcode.CLOSURE:
        case Opcode.GETBOUND:
            if (catch err = dispatch_closures(&ds, op, ra, rb, rc, insn)) { return err~; }
            continue;

        // === ITERATOR ===
        case Opcode.INITFOR:
        case Opcode.NEXTFOR:
            if (catch err = dispatch_iterator(&ds, op, ra, rb, rc, insn)) { return err~; }
            continue;

        // === EXCEPTION HANDLING ===
        case Opcode.TRY:
        case Opcode.ENDTRY:
        case Opcode.THROW:
        case Opcode.CATCH:
        case Opcode.FINALLY:
        case Opcode.ENDFINALLY:
            if (catch err = dispatch_exceptions(&ds, op, ra, rb, rc, insn)) { return err~; }
            continue;

        // === MISC ===
        case Opcode.NOP:
        case Opcode.DEBUGGER:
        case Opcode.BREAK:
        case Opcode.CONTINUE:
        case Opcode.INITGET:
        case Opcode.INITSET:
        case Opcode.INITSETI:
        case Opcode.INITPROP:
        case Opcode.CSVARI:
        case Opcode.PUSH_LEX:
        case Opcode.POP_LEX:
        case Opcode.REQUIRE_OBJ:
        case Opcode.ITER_CLOSE:
            if (catch err = dispatch_misc(&ds, op, ra, rb, rc, insn)) { return err~; }
            continue;

        default:
            return VM_ERROR~;
        }
    }
    }
    return vm.return_val;
}
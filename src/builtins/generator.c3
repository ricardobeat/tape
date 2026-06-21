/// GeneratorFunction and Generator.prototype methods.
module duktape::builtins;
import duktape::types;
import duktape::bytecode;
import duktape::hstring;
import duktape::env;

import duktape::heap;
import duktape::hobject;

// ============================================================================
// GeneratorFunction constructor (ES6 §25.2.1)
// ============================================================================

fn void builtin_generator_function(BuiltinContext* ctx) {
    // GeneratorFunction is not directly callable as a constructor.
    // The user creates generator functions via function* syntax.
    // This builtin exists as the GeneratorFunction constructor object
    // but doesn't actually compile generator functions from strings.
    ctx.result.set_undefined();
}

// ============================================================================
// Generator.prototype.next(value) — ES6 §25.3.1.2
// ============================================================================

fn void builtin_generator_proto_next(BuiltinContext* ctx) {
    if (!ctx.this_val.is_object()) {
        ctx.result.set_undefined();
        return;
    }
    HObject* gen_obj = (HObject*)ctx.this_val.get_heapptr();
    if (gen_obj == null || gen_obj.flags.obj_class != hobject::ObjClass.GENERATOR) {
        ctx.result.set_undefined();
        return;
    }

    Heap* vm_heap = ctx.heap;
    GeneratorState* gs = (GeneratorState*)(*gen_obj.extra_ptr()).gen.generator_data;
    if (gs == null) {
        ctx.result.set_undefined();
        return;
    }

    if (gs.state == GEN_EXECUTING) {
        // ES6 §25.3.1.2: throw TypeError if .next() called while executing
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_str = builtin_intern_string(ctx.heap, "Generator is executing");
            TVal msg_tv; msg_tv.set_string(msg_str);
            err.put_prop(builtin_intern_string(ctx.heap, "message"), msg_tv, hobject::PROP_FLAGS_WC);
            ctx.should_throw = true;
            ctx.throw_value.set_object(err);
        } else {
            ctx.result.set_undefined();
        }
        return;
    }

    if (gs.state == GEN_COMPLETED) {
        HObject*? result_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
        if (try r = result_raw) {
            r.prototype = ctx.heap.object_proto;
            HString* value_key = builtin_intern_string(ctx.heap, "value");
            TVal undef_val;
            undef_val.set_undefined();
            r.put_prop(value_key, undef_val, hobject::PROP_FLAGS_WEC);

            HString* done_key = builtin_intern_string(ctx.heap, "done");
            TVal done_val;
            done_val.set_boolean(true);
            r.put_prop(done_key, done_val, hobject::PROP_FLAGS_WEC);

            ctx.result.set_object(r);
        }
        return;
    }

    // Set the resume value
    if (ctx.argc >= 1) {
        gs.resume_value = ctx.regs[ctx.base_reg];
    } else {
        gs.resume_value.set_undefined();
    }

    // Set heap.resume_gen so the CALL handler knows to resume
    gs.resume_kind = NEXT;
    vm_heap.resume_gen = gs;
    vm_heap.did_yield = false;

    // Create a callable HObject wrapping the generator's compiled function
    HObject*? func_obj_raw = ctx.heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = func_obj_raw) {
        vm_heap.resume_gen = null;
        ctx.result.set_undefined();
        return;
    }
    HObject* func_obj = func_obj_raw;
    func_obj.flags.callable = true;
    (*func_obj.extra_ptr()).func.comp_func = (CompiledFunction*)gs.func;
    (*func_obj.extra_ptr()).func.var_env = (EnvRecord*)gs.var_env;
    (*func_obj.extra_ptr()).func.lex_env = (EnvRecord*)gs.lex_env;

    TVal func_tv;
    func_tv.set_object(func_obj);

    // Replace callee slot (base_reg - 2) and this slot (base_reg - 1)
    ctx.regs[ctx.base_reg - 2] = func_tv;
    ctx.regs[ctx.base_reg - 1] = gs.this_binding;

    // Signal re-dispatch with 0 args
    ctx.needs_re_dispatch = true;
    ctx.re_nargs = 0;
}

// ============================================================================
// Generator.prototype.throw(exception) — ES6 §25.3.1.4
// ============================================================================

fn void builtin_generator_proto_throw(BuiltinContext* ctx) {
    if (!ctx.this_val.is_object()) {
        ctx.result.set_undefined();
        return;
    }
    HObject* gen_obj = (HObject*)ctx.this_val.get_heapptr();
    if (gen_obj == null || gen_obj.flags.obj_class != hobject::ObjClass.GENERATOR) {
        ctx.result.set_undefined();
        return;
    }

    Heap* vm_heap = ctx.heap;
    GeneratorState* gs = (GeneratorState*)(*gen_obj.extra_ptr()).gen.generator_data;
    if (gs == null) {
        ctx.result.set_undefined();
        return;
    }

    if (gs.state == GEN_COMPLETED) {
        // Already completed — propagate the exception (ES6 §25.3.1.4.a)
        ctx.should_throw = true;
        if (ctx.argc >= 1) {
            ctx.throw_value = ctx.regs[ctx.base_reg];
        } else {
            ctx.throw_value.set_undefined();
        }
        return;
    }

    if (gs.state == GEN_EXECUTING) {
        // ES6 §25.3.1.4: throw TypeError if .throw() called while executing
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_str = builtin_intern_string(ctx.heap, "Generator is executing");
            TVal msg_tv; msg_tv.set_string(msg_str);
            err.put_prop(builtin_intern_string(ctx.heap, "message"), msg_tv, hobject::PROP_FLAGS_WC);
            ctx.should_throw = true;
            ctx.throw_value.set_object(err);
        } else {
            ctx.result.set_undefined();
        }
        return;
    }

    // Set the exception to inject
    if (ctx.argc >= 1) {
        gs.throw_value = ctx.regs[ctx.base_reg];
    } else {
        gs.throw_value.set_undefined();
    }
    gs.resume_kind = THROW;

    // Set heap.resume_gen so the CALL handler knows to resume
    vm_heap.resume_gen = gs;
    vm_heap.did_yield = false;

    // Create a callable HObject wrapping the generator's compiled function
    HObject*? func_obj_raw = ctx.heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = func_obj_raw) {
        vm_heap.resume_gen = null;
        gs.resume_kind = NEXT;
        ctx.result.set_undefined();
        return;
    }
    HObject* func_obj = func_obj_raw;
    func_obj.flags.callable = true;
    (*func_obj.extra_ptr()).func.comp_func = (CompiledFunction*)gs.func;
    (*func_obj.extra_ptr()).func.var_env = (EnvRecord*)gs.var_env;
    (*func_obj.extra_ptr()).func.lex_env = (EnvRecord*)gs.lex_env;

    TVal func_tv;
    func_tv.set_object(func_obj);

    // Replace callee slot and this slot
    ctx.regs[ctx.base_reg - 2] = func_tv;
    ctx.regs[ctx.base_reg - 1] = gs.this_binding;

    // Signal re-dispatch with 0 args
    ctx.needs_re_dispatch = true;
    ctx.re_nargs = 0;
}

// ============================================================================
// Generator.prototype.return(value) — ES6 §25.3.1.3
// ============================================================================

fn void builtin_generator_proto_return(BuiltinContext* ctx) {
    if (!ctx.this_val.is_object()) {
        ctx.result.set_undefined();
        return;
    }
    HObject* gen_obj = (HObject*)ctx.this_val.get_heapptr();
    if (gen_obj == null || gen_obj.flags.obj_class != hobject::ObjClass.GENERATOR) {
        ctx.result.set_undefined();
        return;
    }

    Heap* vm_heap = ctx.heap;
    GeneratorState* gs = (GeneratorState*)(*gen_obj.extra_ptr()).gen.generator_data;
    if (gs == null) {
        ctx.result.set_undefined();
        return;
    }

    if (gs.state == GEN_COMPLETED) {
        // Already completed — return {value: argument, done: true}
        HObject*? result_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
        if (try r = result_raw) {
            r.prototype = ctx.heap.object_proto;
            HString* value_key = builtin_intern_string(ctx.heap, "value");
            TVal arg_val;
            if (ctx.argc >= 1) {
                arg_val = ctx.regs[ctx.base_reg];
            } else {
                arg_val.set_undefined();
            }
            r.put_prop(value_key, arg_val, hobject::PROP_FLAGS_WEC);

            HString* done_key = builtin_intern_string(ctx.heap, "done");
            TVal done_val;
            done_val.set_boolean(true);
            r.put_prop(done_key, done_val, hobject::PROP_FLAGS_WEC);

            ctx.result.set_object(r);
        }
        return;
    }

    if (gs.state == GEN_EXECUTING) {
        // ES6 §25.3.1.3: throw TypeError if .return() called while executing
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = ctx.heap.type_err_proto;
            HString* msg_str = builtin_intern_string(ctx.heap, "Generator is executing");
            TVal msg_tv; msg_tv.set_string(msg_str);
            err.put_prop(builtin_intern_string(ctx.heap, "message"), msg_tv, hobject::PROP_FLAGS_WC);
            ctx.should_throw = true;
            ctx.throw_value.set_object(err);
        } else {
            ctx.result.set_undefined();
        }
        return;
    }

    if (gs.state == GEN_SUSPENDED_START) {
        // Generator has never executed — complete immediately without
        // executing any body code (ES6 §25.3.1.3, step 5).
        gs.state = GEN_COMPLETED;
        TVal arg_val;
        if (ctx.argc >= 1) {
            arg_val = ctx.regs[ctx.base_reg];
        } else {
            arg_val.set_undefined();
        }
        HObject*? result_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
        if (try r = result_raw) {
            r.prototype = ctx.heap.object_proto;
            HString* value_key = builtin_intern_string(ctx.heap, "value");
            r.put_prop(value_key, arg_val, hobject::PROP_FLAGS_WEC);
            HString* done_key = builtin_intern_string(ctx.heap, "done");
            TVal done_val;
            done_val.set_boolean(true);
            r.put_prop(done_key, done_val, hobject::PROP_FLAGS_WEC);
            ctx.result.set_object(r);
        }
        return;
    }

    // Set the return value to inject
    if (ctx.argc >= 1) {
        gs.return_value = ctx.regs[ctx.base_reg];
    } else {
        gs.return_value.set_undefined();
    }
    gs.resume_kind = RETURN;

    // Set heap.resume_gen so the CALL handler knows to resume
    vm_heap.resume_gen = gs;
    vm_heap.did_yield = false;

    // Create a callable HObject wrapping the generator's compiled function
    HObject*? func_obj_raw = ctx.heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = func_obj_raw) {
        vm_heap.resume_gen = null;
        gs.resume_kind = NEXT;
        ctx.result.set_undefined();
        return;
    }
    HObject* func_obj = func_obj_raw;
    func_obj.flags.callable = true;
    (*func_obj.extra_ptr()).func.comp_func = (CompiledFunction*)gs.func;
    (*func_obj.extra_ptr()).func.var_env = (EnvRecord*)gs.var_env;
    (*func_obj.extra_ptr()).func.lex_env = (EnvRecord*)gs.lex_env;

    TVal func_tv;
    func_tv.set_object(func_obj);

    // Replace callee slot and this slot
    ctx.regs[ctx.base_reg - 2] = func_tv;
    ctx.regs[ctx.base_reg - 1] = gs.this_binding;

    // Signal re-dispatch with 0 args
    ctx.needs_re_dispatch = true;
    ctx.re_nargs = 0;
}

// ============================================================================
// Generator constructor registration
// ============================================================================

fn bool register_generator_constructor(EnvRecord* global_env, Heap* heap) {
    // Create Generator.prototype
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = heap.object_proto;
    heap.generator_proto = proto;

    // Register prototype methods
    if (!register_string_proto_method(proto, heap, "next",   BUILTIN_GENERATOR_PROTO_NEXT))   return false;
    if (!register_string_proto_method(proto, heap, "throw",  BUILTIN_GENERATOR_PROTO_THROW))  return false;
    if (!register_string_proto_method(proto, heap, "return", BUILTIN_GENERATOR_PROTO_RETURN)) return false;

    // Add [Symbol.iterator]() → returns `this` (ES6 §25.3.1.12)
    {
        HString* iter_sym = ensure_iterator_symbol(heap);
        if (iter_sym != null) {
            HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
            if (catch err = fn_raw) return false;
            HObject* fn_obj = fn_raw;
            (*fn_obj.extra_ptr()).func.builtin_fn_index = (int)BUILTIN_ITERATOR_PROTO_SYMBOL_ITER;
            fn_obj.flags.callable = true;
            fn_obj.prototype = heap.function_proto;
            TVal iter_tv;
            iter_tv.set_object(fn_obj);
            proto.put_prop(iter_sym, iter_tv, hobject::PROP_FLAGS_WC);
        }
    }

    // Set @@toStringTag on Generator.prototype
    HString* tag_key = ensure_tostringtag_symbol(heap);
    if (tag_key != null) {
        TVal tag_tv;
        tag_tv.set_string(builtin_intern_string(heap, "Generator"));
        proto.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC);
    }

    // Create GeneratorFunction.prototype (ES6 §25.2.3)
    // This is the prototype of all generator function objects.
    // It inherits from Function.prototype.
    HObject*? gf_proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = gf_proto_raw) return false;
    HObject* gf_proto = gf_proto_raw;
    gf_proto.prototype = heap.function_proto;
    heap.generator_func_proto = gf_proto;

    // Set GeneratorFunction.prototype.constructor → GeneratorFunction
    // (will be filled in after creating the ctor object below)

    // Set @@toStringTag on GeneratorFunction.prototype
    {
        HString* gf_tag_key = ensure_tostringtag_symbol(heap);
        if (gf_tag_key != null) {
            TVal tag_tv;
            tag_tv.set_string(builtin_intern_string(heap, "GeneratorFunction"));
            gf_proto.put_prop(gf_tag_key, tag_tv, hobject::PROP_FLAGS_NWC);
        }
    }

    // Create GeneratorFunction constructor HObject (ES6 §25.2.2)
    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)BUILTIN_GENERATOR_FUNCTION;
    ctor.flags.callable = true;
    ctor.prototype = heap.function_proto;

    // Wire Generator.prototype.constructor → GeneratorFunction
    {
        HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
        TVal constructor_tv;
        constructor_tv.set_object(ctor);
        proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);
    }

    // Wire GeneratorFunction.prototype.constructor → GeneratorFunction
    {
        HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
        TVal constructor_tv;
        constructor_tv.set_object(ctor);
        gf_proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);
    }

    // Wire GeneratorFunction.prototype → GeneratorFunction.prototype object
    // (non-writable, non-enumerable, non-configurable per ES6 §19.2.4.3)
    {
        HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
        TVal gf_proto_tv;
        gf_proto_tv.set_object(gf_proto);
        PropFlags proto_pflags;
        proto_pflags.writable = false;
        proto_pflags.enumerable = false;
        proto_pflags.configurable = false;
        proto_pflags.is_accessor = false;
        ctor.put_prop(prototype_key, gf_proto_tv, proto_pflags);
    }

    // GeneratorFunction.length = 1 (ES6 §25.2.2)
    {
        HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
        TVal length_tv;
        length_tv.set_fastint(1);
        ctor.put_prop(length_key, length_tv, hobject::PROP_FLAGS_NWC);
    }

    // GeneratorFunction.name = "GeneratorFunction" (ES6 §25.2.2)
    set_func_ctor_name(ctor, heap, "GeneratorFunction");

    // Register GeneratorFunction as a global constructor
    {
        uint hash = heap.hash_string("GeneratorFunction");
        HString* existing = heap.str_table_lookup("GeneratorFunction", hash);
        HString* gf_key;
        if (existing != null) {
            gf_key = existing;
        } else {
            HString*? new_key = hstring::hstring_alloc(heap, "GeneratorFunction", hash);
            if (catch err = new_key) return false;
            heap.str_table_insert(new_key);
            gf_key = new_key;
        }
        TVal gf_tv;
        gf_tv.set_object(ctor);
        env::env_declare_nonenum(global_env, gf_key, gf_tv);
    }

    return true;
}

/// Async generators — `async function*` (ES2018 §27.4 / §27.6).
///
/// This module implements the object surface and request-queue machinery
/// (plan 060 Phase B):
///   - %AsyncIteratorPrototype%       (§27.1.3) — holds @@asyncIterator → this
///   - %AsyncGeneratorPrototype%      (§27.6.1) — next/return/throw + @@toStringTag
///   - %AsyncGeneratorFunction.prototype% (= %AsyncGenerator%, §27.4.3)
///   - %AsyncGeneratorFunction%       (§27.4.1) — the constructor
///
/// AsyncGeneratorEnqueue (§27.6.3.1): each next/return/throw call always
/// returns a *fresh* promise, pushes a request `{completion_kind, value,
/// capability}` onto a FIFO queue on the generator's GeneratorState, and — when
/// the generator is not EXECUTING/AWAITING_RETURN — drains the queue.
///
/// The drain reuses the synchronous generator resume machinery (the same body
/// the sync Generator.prototype.next drives) via `heap.call_fn`, which returns
/// the body's `{value, done}` IteratorResult (or sets heap.has_error on an
/// uncaught throw). That result is used to settle the request's promise. The
/// yield-vs-await resume-driver split (§27.6.3.8 AsyncGeneratorYield: await the
/// operand before settling) is Phase C — for now a `yield v` settles the
/// current request's promise with `{v, false}` synchronously, which is correct
/// for bodies without an `await` between the yield and the settle.
module duktape::builtins;
import duktape::types;
import duktape::hstring;
import duktape::heap;
import duktape::hobject;
import duktape::bytecode;
import duktape::env;

// ============================================================================
// Prototype-chain registration (heap init)
// ============================================================================

/// Create the async-generator prototype chain (ES2018 §27.1.3 / §27.4 / §27.6).
/// Called after register_generator_constructor (needs function_proto,
/// object_proto, generator machinery) and after the async-iterator symbol
/// helpers are available.
fn bool register_async_generator(EnvRecord* global_env, Heap* heap) {
    // ── %AsyncIteratorPrototype% (§27.1.3) ───────────────────────────────
    // A plain object inheriting from %Object.prototype% whose sole own member
    // is @@asyncIterator, an accessor-free method returning `this`.
    HObject*? ai_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = ai_raw) return false;
    HObject* ai_proto = ai_raw;
    ai_proto.prototype = heap.object_proto;
    heap.async_iterator_proto = ai_proto;
    {
        HString* asynciter_key = ensure_asynciterator_symbol(heap);
        if (asynciter_key != null) {
            HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
            if (catch err = fn_raw) return false;
            HObject* fn_obj = fn_raw;
            (*fn_obj.extra_ptr()).func.builtin_fn_index =
                (int)Builtin.ASYNC_ITERATOR_PROTO_SYMBOL_ASYNCITER.ordinal;
            fn_obj.flags.callable = true;
            fn_obj.prototype = heap.function_proto;
            // .length = 0, .name = "[Symbol.asyncIterator]" (ES2018 §27.1.3.1).
            {
                HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
                TVal len_tv; len_tv.set_fastint(0);
                fn_obj.put_prop(length_key, len_tv, hobject::PROP_FLAGS_NWC);
                HString* name_key = builtin_intern_string(heap, "name");
                HString* name_val = builtin_intern_string(heap, "[Symbol.asyncIterator]");
                if (name_key != null && name_val != null) {
                    TVal name_tv; name_tv.set_string(name_val);
                    fn_obj.put_prop(name_key, name_tv, hobject::PROP_FLAGS_NWC);
                }
            }
            TVal iter_tv;
            iter_tv.set_object(fn_obj);
            ai_proto.put_prop(asynciter_key, iter_tv, hobject::PROP_FLAGS_WC);
        }
    }

    // ── %AsyncGeneratorPrototype% (§27.6.1) ──────────────────────────────
    // Inherits from %AsyncIteratorPrototype%; next/return/throw + @@toStringTag.
    HObject*? ag_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = ag_raw) return false;
    HObject* ag_proto = ag_raw;
    ag_proto.prototype = ai_proto;
    heap.async_generator_proto = ag_proto;

    if (!register_string_proto_method(ag_proto, heap, "next",   Builtin.ASYNC_GENERATOR_PROTO_NEXT.ordinal))   return false;
    if (!register_string_proto_method(ag_proto, heap, "return", Builtin.ASYNC_GENERATOR_PROTO_RETURN.ordinal)) return false;
    if (!register_string_proto_method(ag_proto, heap, "throw",  Builtin.ASYNC_GENERATOR_PROTO_THROW.ordinal))  return false;

    {
        HString* tag_key = ensure_tostringtag_symbol(heap);
        if (tag_key != null) {
            TVal tag_tv;
            tag_tv.set_string(builtin_intern_string(heap, "AsyncGenerator"));
            ag_proto.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC);
        }
    }

    // ── %AsyncGeneratorFunction.prototype% (= %AsyncGenerator%, §27.4.3) ──
    // Inherits from %Function.prototype%; its own `.prototype` is
    // %AsyncGeneratorPrototype%, and @@toStringTag = "AsyncGeneratorFunction".
    HObject*? agf_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = agf_raw) return false;
    HObject* agf_proto = agf_raw;
    agf_proto.prototype = heap.function_proto;
    heap.async_generator_func_proto = agf_proto;

    {
        // %AsyncGenerator%.prototype → %AsyncGeneratorPrototype%
        // {writable:false, enumerable:false, configurable:true}.
        HString* proto_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
        TVal proto_tv;
        proto_tv.set_object(ag_proto);
        agf_proto.put_prop(proto_key, proto_tv, hobject::PROP_FLAGS_NWC);
    }
    {
        HString* tag_key = ensure_tostringtag_symbol(heap);
        if (tag_key != null) {
            TVal tag_tv;
            tag_tv.set_string(builtin_intern_string(heap, "AsyncGeneratorFunction"));
            agf_proto.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC);
        }
    }

    // ── %AsyncGeneratorFunction% constructor (§27.4.1) ───────────────────
    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)Builtin.ASYNC_GENERATOR_FUNCTION.ordinal;
    ctor.flags.callable = true;
    ctor.prototype = heap.function_proto;

    // %AsyncGenerator%.constructor → %AsyncGeneratorFunction%
    {
        HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
        TVal constructor_tv;
        constructor_tv.set_object(ctor);
        agf_proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);
    }
    // %AsyncGeneratorPrototype%.constructor → %AsyncGenerator% (§27.6.1.1).
    {
        HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
        TVal constructor_tv;
        constructor_tv.set_object(agf_proto);
        ag_proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);
    }
    // %AsyncGeneratorFunction%.prototype → %AsyncGenerator%
    // {writable:false, enumerable:false, configurable:false} (§27.4.2.2).
    {
        HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
        TVal agf_proto_tv;
        agf_proto_tv.set_object(agf_proto);
        ctor.put_prop(prototype_key, agf_proto_tv, hobject::PROP_FLAGS_NNC);
    }
    {
        HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
        TVal length_tv;
        length_tv.set_fastint(1);
        ctor.put_prop(length_key, length_tv, hobject::PROP_FLAGS_NWC);
    }
    set_func_ctor_name(ctor, heap, "AsyncGeneratorFunction");

    return true;
}

// ============================================================================
// %AsyncIteratorPrototype%[@@asyncIterator]() — ES2018 §27.1.3.1 → returns this
// ============================================================================

fn void builtin_async_iterator_proto_symbol_asynciter(BuiltinContext* ctx) {
    *ctx.result = ctx.this_val;
}

// ============================================================================
// AsyncGeneratorFunction constructor (ES2018 §27.4.1) — CreateDynamicFunction
// ============================================================================

fn void builtin_async_generator_function(BuiltinContext* ctx) {
    // is_gen=true, is_async=true → `async function*` dynamic source.
    builtin_dynamic_gen_function(ctx, true, true);
}

// ============================================================================
// AsyncGenerator request queue (ES2018 §27.6.3.1 AsyncGeneratorEnqueue)
// ============================================================================

/// Resolve `this` to the GeneratorState of an async generator, or null if
/// `this` isn't one (guards against `AsyncGenerator.prototype.next.call(x)`).
fn GeneratorState* async_gen_state_of(BuiltinContext* ctx) {
    if (!ctx.this_val.is_object()) return null;
    HObject* gen_obj = (HObject*)ctx.this_val.get_heapptr();
    if (gen_obj == null || gen_obj.flags.obj_class != hobject::ObjClass.GENERATOR) return null;
    GeneratorState* gs = (GeneratorState*)(*gen_obj.extra_ptr()).gen.generator_data;
    if (gs == null || !gs.is_async_gen) return null;
    return gs;
}

/// Build a rejected promise for a `this` that isn't an async generator: per
/// §27.6.1.2/.3/.4 the method returns a promise rejected with a TypeError
/// rather than throwing synchronously.
fn void async_gen_reject_bad_this(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    TVal te = async_gen_type_error(heap, "not an AsyncGenerator");
    HObject*? p_raw = promise_create(heap);
    if (catch err = p_raw) { ctx.result.set_undefined(); return; }
    HObject* p = p_raw;
    promise_settle(p, PROMISE_REJECTED, &te, heap);
    promise_trigger_reactions(p, heap, ctx.vm);
    ctx.result.set_object(p);
}

/// Build a TypeError value without touching heap.has_error.
fn TVal async_gen_type_error(Heap* heap, char[] msg) {
    TVal out;
    out.set_undefined();
    HObject*? err_raw = heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = heap.type_err_proto;
        HString* msg_str = builtin_intern_string(heap, msg);
        if (msg_str != null) {
            TVal msg_tv; msg_tv.set_string(msg_str);
            HString* msg_key = builtin_intern_string(heap, "message");
            if (msg_key != null) err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        }
        out.set_object(err);
    }
    return out;
}

/// Allocate an IteratorResult `{value, done}` object.
fn HObject* async_gen_iter_result(Heap* heap, TVal value, bool done) {
    HObject*? r_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = r_raw) return null;
    HObject* r = r_raw;
    r.prototype = heap.object_proto;
    HString* value_key = (HString*)heap.strs[heap::BuiltinStr.VALUE];
    r.put_prop(value_key, value, hobject::PROP_FLAGS_WEC);
    HString* done_key = (HString*)heap.strs[heap::BuiltinStr.DONE];
    TVal done_tv; done_tv.set_boolean(done);
    r.put_prop(done_key, done_tv, hobject::PROP_FLAGS_WEC);
    return r;
}

/// AsyncGeneratorEnqueue (§27.6.3.1): create a fresh promise, push a request,
/// and — if the generator is not currently running the body or awaiting a
/// return — drain the queue. Writes the promise into ctx.result.
fn void async_gen_enqueue(BuiltinContext* ctx, GeneratorState* gs, ResumeKind kind, TVal completion) {
    Heap* heap = ctx.heap;

    HObject*? p_raw = promise_create(heap);
    if (catch err = p_raw) { ctx.result.set_undefined(); return; }
    HObject* promise = p_raw;

    AsyncGenRequest* req = (AsyncGenRequest*)heap.alloc_func(heap.heap_udata, AsyncGenRequest::size);
    if (req == null) { ctx.result.set_undefined(); return; }
    mem::clear(req, (sz)(AsyncGenRequest::size));
    req.completion_kind = kind;
    req.value = completion;
    req.capability = promise;
    req.next = null;

    // FIFO append.
    if (gs.agr_tail != null) {
        gs.agr_tail.next = req;
        gs.agr_tail = req;
    } else {
        gs.agr_head = req;
        gs.agr_tail = req;
    }

    // Hand the promise back to the caller before draining (draining may settle
    // it synchronously in this Phase-B increment).
    ctx.result.set_object(promise);

    if (gs.state != GEN_EXECUTING && gs.state != GEN_AWAITING_RETURN) {
        async_gen_drain(ctx, gs);
    }
}

/// Pop the head request off the queue and free its node, returning the request
/// data by value (the promise is still referenced by the returned struct).
fn AsyncGenRequest async_gen_dequeue(Heap* heap, GeneratorState* gs) {
    AsyncGenRequest* head = gs.agr_head;
    AsyncGenRequest out = *head;
    gs.agr_head = head.next;
    if (gs.agr_head == null) gs.agr_tail = null;
    out.next = null;
    heap.free_func(heap.heap_udata, head);
    return out;
}

/// Settle a request's promise with an IteratorResult `{value, done}`.
fn void async_gen_settle_result(Heap* heap, void* vm, HObject* promise, TVal value, bool done) {
    HObject* r = async_gen_iter_result(heap, value, done);
    if (r == null) return;
    TVal r_tv; r_tv.set_object(r);
    promise_settle(promise, PROMISE_FULFILLED, &r_tv, heap);
    promise_trigger_reactions(promise, heap, vm);
}

/// Reject a request's promise with `reason`.
fn void async_gen_settle_reject(Heap* heap, void* vm, HObject* promise, TVal reason) {
    promise_settle(promise, PROMISE_REJECTED, &reason, heap);
    promise_trigger_reactions(promise, heap, vm);
}

/// AsyncGeneratorDrainQueue / AsyncGeneratorResume (§27.6.3.3/.4).
/// Processes queued requests FIFO until the queue is empty, the generator
/// suspends at a `yield`, or the body suspends internally on an `await` (in
/// which case a microtask ASYNC_GEN_AWAIT_RESUME reaction resumes the drain).
fn void async_gen_drain(BuiltinContext* ctx, GeneratorState* gs) {
    Heap* heap = ctx.heap;
    void* vm = ctx.vm;

    // If a request is already in flight (an internal await is outstanding),
    // don't start a new one — the await reaction will re-drive.
    if (gs.ag_current_request != null) return;

    while (gs.agr_head != null) {
        // COMPLETED-state fast answers (§27.6.3.7 AsyncGeneratorResume-style):
        //   next   → {undefined, true}
        //   return → {value, true}   (§27.6.3.7 AsyncGeneratorReturn — value awaited)
        //   throw  → reject(value)
        if (gs.state == GEN_COMPLETED) {
            AsyncGenRequest req = async_gen_dequeue(heap, gs);
            HObject* promise = (HObject*)req.capability;
            switch (req.completion_kind) {
                case NEXT: {
                    TVal undef; undef.set_undefined();
                    async_gen_settle_result(heap, vm, promise, undef, true);
                }
                case RETURN:
                    async_gen_settle_result(heap, vm, promise, req.value, true);
                case THROW:
                    async_gen_settle_reject(heap, vm, promise, req.value);
            }
            continue;
        }

        // SUSPENDED_START / SUSPENDED_YIELD: resume the body with the request's
        // completion. Reuses the synchronous generator resume path, which
        // returns the body's {value, done} IteratorResult (or sets
        // heap.has_error on an uncaught throw).
        AsyncGenRequest req = async_gen_dequeue(heap, gs);
        HObject* promise = (HObject*)req.capability;

        // A `.throw()` on SUSPENDED_START completes the generator without
        // running any body code (§27.6.3.7-style): reject and mark COMPLETED.
        if (gs.state == GEN_SUSPENDED_START && req.completion_kind == THROW) {
            gs.state = GEN_COMPLETED;
            async_gen_settle_reject(heap, vm, promise, req.value);
            continue;
        }
        // A `.return()` on SUSPENDED_START completes immediately with
        // {value, done:true} (no body code runs).
        if (gs.state == GEN_SUSPENDED_START && req.completion_kind == RETURN) {
            gs.state = GEN_COMPLETED;
            async_gen_settle_result(heap, vm, promise, req.value, true);
            continue;
        }

        // Hold the request across a possible internal await, then resume.
        gs.ag_current_request = (void*)promise;
        heap.ag_did_await = false;
        gs.ag_suspend_kind = AG_SUSPEND_NONE;
        TVal result = async_gen_resume_body(ctx, gs, req.completion_kind, req.value);

        // If the body suspended internally on an await, leave the current
        // request in flight; the ASYNC_GEN_AWAIT_RESUME reaction re-drives.
        if (heap.ag_did_await) {
            heap.ag_did_await = false;
            return;
        }

        // Body settled (yield / return / throw) — service the outcome.
        gs.ag_current_request = null;
        if (!async_gen_finish_body(ctx, gs, promise, result)) break;
    }
}

/// Service the outcome of a body resume that did NOT suspend on an internal
/// await: settle the current request's promise. Returns true to keep draining
/// (completed request), false to stop (the body yielded and is now suspended).
fn bool async_gen_finish_body(BuiltinContext* ctx, GeneratorState* gs, HObject* promise, TVal result) {
    Heap* heap = ctx.heap;
    void* vm = ctx.vm;

    if (heap.has_error) {
        TVal thrown = heap.error_value;
        heap.has_error = false;
        gs.state = GEN_COMPLETED;
        async_gen_settle_reject(heap, vm, promise, thrown);
        return true;
    }

    TVal value; value.set_undefined();
    bool done = false;
    if (result.is_object() && result.get_heapptr() != null) {
        HObject* robj = (HObject*)result.get_heapptr();
        HString* done_key = (HString*)heap.strs[heap::BuiltinStr.DONE];
        if (try dv = robj.get_prop(done_key)) { done = builtin_to_boolean(&dv); }
        HString* value_key = (HString*)heap.strs[heap::BuiltinStr.VALUE];
        if (try vv = robj.get_prop(value_key)) { value = vv; }
    }
    async_gen_settle_result(heap, vm, promise, value, done);
    // Continue draining regardless of done: AsyncGeneratorDrainQueue
    // (§27.6.3.4) resumes one queued request per step, so after a yield settles
    // the next queued request resumes the body again. The while-loop's
    // queue-empty test terminates the single-consumer (for-await) case.
    return true;
}

/// ASYNC_GEN_AWAIT_RESUME native reaction (§27.6): an internal `await` inside an
/// async-gen body fulfilled. Deliver the value as the resume completion, re-run
/// the body, and continue draining.
fn void builtin_async_gen_await_resume(BuiltinContext* ctx) {
    GeneratorState* gs = (GeneratorState*)(*ctx.callee_obj.extra_ptr()).func.var_env;
    if (gs == null) { ctx.result.set_undefined(); return; }
    TVal arg; arg.set_undefined();
    if (ctx.argc >= 1) arg = ctx.regs[ctx.base_reg];
    async_gen_await_reenter(ctx, gs, NEXT, arg);
}

/// ASYNC_GEN_AWAIT_REJECT native reaction (§27.6): an internal `await` rejected.
/// Inject the reason as a throw completion at the await point.
fn void builtin_async_gen_await_reject(BuiltinContext* ctx) {
    GeneratorState* gs = (GeneratorState*)(*ctx.callee_obj.extra_ptr()).func.var_env;
    if (gs == null) { ctx.result.set_undefined(); return; }
    TVal arg; arg.set_undefined();
    if (ctx.argc >= 1) arg = ctx.regs[ctx.base_reg];
    async_gen_await_reenter(ctx, gs, THROW, arg);
}

/// Re-enter a suspended async-gen body after an internal await settled, then
/// resume draining. Shared by the fulfill/reject reactions.
fn void async_gen_await_reenter(BuiltinContext* ctx, GeneratorState* gs, ResumeKind kind, TVal completion) {
    Heap* heap = ctx.heap;
    HObject* promise = (HObject*)gs.ag_current_request;

    heap.ag_did_await = false;
    gs.ag_suspend_kind = AG_SUSPEND_NONE;
    TVal result = async_gen_resume_body(ctx, gs, kind, completion);

    // Suspended again on another internal await — stay in flight.
    if (heap.ag_did_await) {
        heap.ag_did_await = false;
        ctx.result.set_undefined();
        return;
    }

    // The body settled. Finish the in-flight request, then drain the rest.
    gs.ag_current_request = null;
    if (promise != null) {
        if (async_gen_finish_body(ctx, gs, promise, result)) {
            async_gen_drain(ctx, gs);
        }
    }
    ctx.result.set_undefined();
}

/// Resume the async generator's body synchronously (reusing the sync generator
/// resume machinery) with the given completion, returning the body's
/// `{value, done}` IteratorResult. Sets heap.has_error on an uncaught throw.
fn TVal async_gen_resume_body(BuiltinContext* ctx, GeneratorState* gs, ResumeKind kind, TVal completion) {
    Heap* heap = ctx.heap;
    TVal out; out.set_undefined();

    // Install the resume completion, mirroring Generator.prototype.next/throw/
    // return but driving the body via heap.call_fn instead of re-dispatch.
    gs.resume_kind = kind;
    switch (kind) {
        case NEXT:   gs.resume_value = completion;
        case THROW:  gs.throw_value  = completion;
        case RETURN: gs.return_value = completion;
    }
    heap.resume_gen = gs;
    heap.did_yield = false;

    HObject*? wrapper_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = wrapper_raw) { heap.resume_gen = null; return out; }
    HObject* wrapper = wrapper_raw;
    wrapper.flags.callable = true;
    (*wrapper.extra_ptr()).func.comp_func = (CompiledFunction*)gs.func;
    (*wrapper.extra_ptr()).func.var_env = (EnvRecord*)gs.var_env;
    (*wrapper.extra_ptr()).func.lex_env = (EnvRecord*)gs.lex_env;

    TVal wrapper_tv; wrapper_tv.set_object(wrapper);
    TVal this_tv = gs.this_binding;
    out = heap.call_fn(ctx.vm, wrapper_tv, null, 0, this_tv);

    if (heap.resume_gen == gs) heap.resume_gen = null;
    return out;
}

// ============================================================================
// %AsyncGeneratorPrototype%.next / .return / .throw (§27.6.1.2/.3/.4)
// ============================================================================

fn void builtin_async_generator_proto_next(BuiltinContext* ctx) {
    GeneratorState* gs = async_gen_state_of(ctx);
    if (gs == null) { async_gen_reject_bad_this(ctx); return; }
    TVal arg; arg.set_undefined();
    if (ctx.argc >= 1) arg = ctx.regs[ctx.base_reg];
    async_gen_enqueue(ctx, gs, NEXT, arg);
}

fn void builtin_async_generator_proto_return(BuiltinContext* ctx) {
    GeneratorState* gs = async_gen_state_of(ctx);
    if (gs == null) { async_gen_reject_bad_this(ctx); return; }
    TVal arg; arg.set_undefined();
    if (ctx.argc >= 1) arg = ctx.regs[ctx.base_reg];
    async_gen_enqueue(ctx, gs, RETURN, arg);
}

fn void builtin_async_generator_proto_throw(BuiltinContext* ctx) {
    GeneratorState* gs = async_gen_state_of(ctx);
    if (gs == null) { async_gen_reject_bad_this(ctx); return; }
    TVal arg; arg.set_undefined();
    if (ctx.argc >= 1) arg = ctx.regs[ctx.base_reg];
    async_gen_enqueue(ctx, gs, THROW, arg);
}

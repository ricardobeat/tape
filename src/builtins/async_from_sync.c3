/// %AsyncFromSyncIteratorPrototype% — ES2018 §27.1.4.
///
/// Wraps a synchronous iterator so `for await` can drive it: `next`/`return`/
/// `throw` all return Promises, and per §27.1.4.4 AsyncFromSyncIteratorContinuation
/// the *value* half of the sync `{value, done}` result is itself Promise-resolved
/// (awaited) before the caller sees it, so a synchronously-thenable value
/// still gets unwrapped like it would from a real async iterator.
module duktape::builtins;
import duktape::types;
import duktape::hstring;
import duktape::heap;
import duktape::hobject;

/// Internal-slot key holding the wrapped [[SyncIteratorRecord]]'s iterator
/// object. There is no dedicated ObjClass/HObjectExtra member for this
/// adapter (it would need a new union member + GC-mark case for a single
/// TVal), so — following the same convention as Promise capability state
/// and Promise.all element callbacks (see promise.c3's "\xFFcap_*" /
/// "\xFFstate" hidden props) — the sync iterator is stashed as a TVal behind
/// a hidden, unprintable-prefixed property key that user code cannot spell.
const char[] ASYNC_FROM_SYNC_ITERATOR_SLOT = "\xFFsyncIterator";

/// Hidden-prop keys on the native value-unwrap/reject-forward reaction
/// closures (mirrors promise.c3's promise_create_element_callback pattern).
const char[] ASYNC_FROM_SYNC_DONE_SLOT  = "\xFFdone";
const char[] ASYNC_FROM_SYNC_OUTER_SLOT = "\xFFouter";

/// Create %AsyncFromSyncIteratorPrototype% (ES2018 §27.1.4): a plain object
/// (inherits directly from %ObjectPrototype%, not %IteratorPrototype%) with
/// next/return/throw methods.
fn bool register_async_from_sync_iterator_prototype(Heap* heap) {
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = heap.object_proto;
    heap.async_from_sync_iter_proto = proto;

    if (!register_string_proto_method(proto, heap, "next",   Builtin.ASYNC_FROM_SYNC_NEXT.ordinal))   return false;
    if (!register_string_proto_method(proto, heap, "return", Builtin.ASYNC_FROM_SYNC_RETURN.ordinal)) return false;
    if (!register_string_proto_method(proto, heap, "throw",  Builtin.ASYNC_FROM_SYNC_THROW.ordinal))  return false;

    return true;
}

/// Allocate an %AsyncFromSyncIteratorPrototype% instance wrapping `syncIter`
/// (ES2018 §27.1.4.1 CreateAsyncFromSyncIterator). Called from the
/// GET_ITER_ASYNC opcode handler once it has obtained a sync iterator via
/// @@iterator.
fn HObject*? async_from_sync_iterator(Heap* heap, HObject* syncIter, void* vm) {
    HObject*? adapter_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = adapter_raw) return null;
    HObject* adapter = adapter_raw;
    adapter.prototype = heap.async_from_sync_iter_proto;

    HString* slot_key = builtin_intern_string(heap, ASYNC_FROM_SYNC_ITERATOR_SLOT);
    if (slot_key == null) return null;
    TVal sync_tv;
    sync_tv.set_object(syncIter);
    adapter.put_prop(slot_key, sync_tv, hobject::PROP_FLAGS_WEC);

    return adapter;
}

/// Read the wrapped sync iterator off an adapter object, or null if `this`
/// isn't one (guards against `AsyncFromSyncIteratorPrototype.next.call(x)`).
fn HObject* async_from_sync_get_wrapped(BuiltinContext* ctx) {
    if (!ctx.this_val.is_object()) return null;
    HObject* adapter = (HObject*)ctx.this_val.get_heapptr();
    if (adapter == null) return null;
    HString* slot_key = builtin_intern_string(ctx.heap, ASYNC_FROM_SYNC_ITERATOR_SLOT);
    if (slot_key == null) return null;
    TVal? sync_opt = adapter.get_prop(slot_key);
    if (try sv = sync_opt) {
        if (sv.is_object() && sv.get_heapptr() != null) return (HObject*)sv.get_heapptr();
    }
    return null;
}

/// Build the promise-fulfill / promise-reject pair of native reaction
/// closures used to finish AsyncFromSyncIteratorContinuation, and attach
/// them to `value_promise`. `done` is baked into the fulfill closure so it
/// can build `{value, done}` once the (possibly-thenable) value settles.
/// Returns the outer promise the caller should hand back to `for await`.
fn HObject*? async_from_sync_continuation(Heap* heap, void* vm, TVal result_value, bool done) {
    HObject*? outer_raw = promise_create(heap);
    if (catch err = outer_raw) return null;
    HObject* outer = outer_raw;

    HObject*? value_promise_raw = promise_create(heap);
    if (catch err = value_promise_raw) return null;
    HObject* value_promise = value_promise_raw;
    // ES2018 §27.1.4.4 step 8: Perform ! Call(promiseCapability.[[Resolve]], undefined, « value »).
    // promise_resolve_with_value implements the full [[Resolve]] procedure
    // (ES6 §25.4.1.3.2 steps 7-13), including thenable coercion, so a
    // synchronously- or asynchronously-thenable result.value is genuinely
    // awaited rather than passed through unresolved.
    promise_resolve_with_value(value_promise, result_value, heap, vm);

    HObject*? fulfill_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = fulfill_raw) return null;
    HObject* fulfill_fn = fulfill_raw;
    (*fulfill_fn.extra_ptr()).func.builtin_fn_index = (int)Builtin.ASYNC_FROM_SYNC_VALUE_UNWRAP.ordinal;
    fulfill_fn.flags.callable = true;
    fulfill_fn.flags.constructable = false;
    fulfill_fn.prototype = heap.function_proto;

    HObject*? reject_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = reject_raw) return null;
    HObject* reject_fn = reject_raw;
    (*reject_fn.extra_ptr()).func.builtin_fn_index = (int)Builtin.ASYNC_FROM_SYNC_REJECT_FORWARD.ordinal;
    reject_fn.flags.callable = true;
    reject_fn.flags.constructable = false;
    reject_fn.prototype = heap.function_proto;

    HString* done_key  = builtin_intern_string(heap, ASYNC_FROM_SYNC_DONE_SLOT);
    HString* outer_key = builtin_intern_string(heap, ASYNC_FROM_SYNC_OUTER_SLOT);
    if (done_key == null || outer_key == null) return null;

    TVal done_tv; done_tv.set_boolean(done);
    fulfill_fn.put_prop(done_key, done_tv, hobject::PROP_FLAGS_WEC);
    TVal outer_tv; outer_tv.set_object(outer);
    fulfill_fn.put_prop(outer_key, outer_tv, hobject::PROP_FLAGS_WEC);
    reject_fn.put_prop(outer_key, outer_tv, hobject::PROP_FLAGS_WEC);

    promise_attach_element_callbacks(value_promise, fulfill_fn, reject_fn, heap, vm);

    return outer;
}

/// Native fulfill reaction for the internal value-promise: builds
/// `{value, done}` and fulfills the outer (returned) promise with it
/// (ES2018 §27.1.4.4 steps 9-11, "onFulfilled" closure).
fn void builtin_async_from_sync_value_unwrap(BuiltinContext* ctx) {
    ctx.result.set_undefined();
    if (ctx.callee_obj == null) return;
    Heap* heap = ctx.heap;

    HString* done_key  = builtin_intern_string(heap, ASYNC_FROM_SYNC_DONE_SLOT);
    HString* outer_key = builtin_intern_string(heap, ASYNC_FROM_SYNC_OUTER_SLOT);
    if (done_key == null || outer_key == null) return;

    bool done = false;
    if (try dv = ctx.callee_obj.get_prop(done_key)) {
        if (dv.is_boolean()) done = dv.get_boolean();
    }
    HObject* outer = null;
    if (try ov = ctx.callee_obj.get_prop(outer_key)) {
        if (ov.is_object() && ov.get_heapptr() != null) outer = (HObject*)ov.get_heapptr();
    }
    if (outer == null) return;

    TVal value;
    value.set_undefined();
    if (ctx.argc >= 1) value = ctx.regs[ctx.base_reg];

    HObject*? iter_result_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = iter_result_raw) {
        TVal err_tv = heap.error_value;
        heap.has_error = false;
        promise_settle(outer, PROMISE_REJECTED, &err_tv, heap);
        promise_trigger_reactions(outer, heap, ctx.vm);
        return;
    }
    HObject* iter_result = iter_result_raw;
    iter_result.prototype = heap.object_proto;

    HString* value_key = (HString*)heap.strs[heap::BuiltinStr.VALUE];
    iter_result.put_prop(value_key, value, hobject::PROP_FLAGS_WEC);
    HString* done_out_key = (HString*)heap.strs[heap::BuiltinStr.DONE];
    TVal done_tv; done_tv.set_boolean(done);
    iter_result.put_prop(done_out_key, done_tv, hobject::PROP_FLAGS_WEC);

    TVal iter_result_tv;
    iter_result_tv.set_object(iter_result);
    promise_settle(outer, PROMISE_FULFILLED, &iter_result_tv, heap);
    promise_trigger_reactions(outer, heap, ctx.vm);
}

/// Native reject reaction for the internal value-promise: forwards the
/// rejection reason straight to the outer promise (ES2018 §27.1.4.4 step 9,
/// "onRejected" is `promiseCapability.[[Reject]]`).
fn void builtin_async_from_sync_reject_forward(BuiltinContext* ctx) {
    ctx.result.set_undefined();
    if (ctx.callee_obj == null) return;
    Heap* heap = ctx.heap;

    HString* outer_key = builtin_intern_string(heap, ASYNC_FROM_SYNC_OUTER_SLOT);
    if (outer_key == null) return;
    HObject* outer = null;
    if (try ov = ctx.callee_obj.get_prop(outer_key)) {
        if (ov.is_object() && ov.get_heapptr() != null) outer = (HObject*)ov.get_heapptr();
    }
    if (outer == null) return;

    TVal reason;
    reason.set_undefined();
    if (ctx.argc >= 1) reason = ctx.regs[ctx.base_reg];

    promise_settle(outer, PROMISE_REJECTED, &reason, heap);
    promise_trigger_reactions(outer, heap, ctx.vm);
}

/// Build a TypeError value (without touching heap.has_error) for use as a
/// promise rejection reason — e.g. "Iterator result is not an object".
fn TVal async_from_sync_type_error(Heap* heap, char[] msg) {
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

/// Reject a freshly-created promise with `reason` and return it. Shared by
/// next/return/throw's early-exit error paths (e.g. sync method threw, or
/// its result wasn't an object).
fn HObject*? async_from_sync_rejected_promise(Heap* heap, void* vm, TVal reason) {
    HObject*? p_raw = promise_create(heap);
    if (catch err = p_raw) return null;
    HObject* p = p_raw;
    promise_settle(p, PROMISE_REJECTED, &reason, heap);
    promise_trigger_reactions(p, heap, vm);
    return p;
}

/// %AsyncFromSyncIteratorPrototype%.next(value) — ES2018 §27.1.4.2.
fn void builtin_async_from_sync_next(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    ctx.result.set_undefined();

    HObject* sync_iter = async_from_sync_get_wrapped(ctx);
    if (sync_iter == null) {
        builtin_throw(ctx, heap.type_err_proto, "not an AsyncFromSyncIterator");
        return;
    }

    HString* next_key = builtin_intern_string(heap, "next");
    TVal? next_method_opt = builtins_generic_get(sync_iter, next_key, ctx);
    if (ctx.should_throw) return;
    TVal next_method;
    if (try nm = next_method_opt) { next_method = nm; } else { next_method.set_undefined(); }
    if (!next_method.is_object() || !((HObject*)next_method.get_heapptr()).is_callable()) {
        builtin_throw(ctx, heap.type_err_proto, "iterator.next is not a function");
        return;
    }

    TVal arg;
    arg.set_undefined();
    if (ctx.argc >= 1) arg = ctx.regs[ctx.base_reg];
    TVal sync_this;
    sync_this.set_object(sync_iter);
    TVal step_result = heap.call_fn(ctx.vm, next_method, &arg, 1, sync_this);
    if (heap.has_error) {
        TVal thrown = heap.error_value;
        heap.has_error = false;
        HObject*? rej = async_from_sync_rejected_promise(heap, ctx.vm, thrown);
        if (catch err = rej) { return; }
        ctx.result.set_object(rej);
        return;
    }
    if (!step_result.is_object() || step_result.get_heapptr() == null) {
        TVal te = async_from_sync_type_error(heap, "Iterator result is not an object");
        HObject*? rej = async_from_sync_rejected_promise(heap, ctx.vm, te);
        if (catch err = rej) { return; }
        ctx.result.set_object(rej);
        return;
    }
    HObject* result_obj = (HObject*)step_result.get_heapptr();

    HString* done_key = (HString*)heap.strs[heap::BuiltinStr.DONE];
    TVal? done_opt = builtins_generic_get(result_obj, done_key, ctx);
    if (ctx.should_throw) return;
    bool done = false;
    if (try dv = done_opt) { done = builtin_to_boolean(&dv); }

    HString* value_key = (HString*)heap.strs[heap::BuiltinStr.VALUE];
    TVal? value_opt = builtins_generic_get(result_obj, value_key, ctx);
    if (ctx.should_throw) return;
    TVal value;
    value.set_undefined();
    if (try vv = value_opt) { value = vv; }

    HObject*? outer = async_from_sync_continuation(heap, ctx.vm, value, done);
    if (catch err = outer) { return; }
    ctx.result.set_object(outer);
}

/// %AsyncFromSyncIteratorPrototype%.return(value) — ES2018 §27.1.4.3.
fn void builtin_async_from_sync_return(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    ctx.result.set_undefined();

    HObject* sync_iter = async_from_sync_get_wrapped(ctx);
    if (sync_iter == null) {
        builtin_throw(ctx, heap.type_err_proto, "not an AsyncFromSyncIterator");
        return;
    }

    TVal arg;
    arg.set_undefined();
    if (ctx.argc >= 1) arg = ctx.regs[ctx.base_reg];

    HString* return_key = builtin_intern_string(heap, "return");
    TVal? return_method_opt = builtins_generic_get(sync_iter, return_key, ctx);
    if (ctx.should_throw) return;
    TVal return_method;
    if (try rm = return_method_opt) { return_method = rm; } else { return_method.set_undefined(); }

    if (return_method.is_nullish()) {
        // Step 3: no .return on the sync iterator — resolve with
        // {value: argument, done: true} directly (nothing to await-unwrap
        // per spec since AsyncFromSyncIteratorContinuation isn't invoked).
        HObject*? iter_result_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
        if (catch err = iter_result_raw) return;
        HObject* iter_result = iter_result_raw;
        iter_result.prototype = heap.object_proto;
        HString* value_key = (HString*)heap.strs[heap::BuiltinStr.VALUE];
        iter_result.put_prop(value_key, arg, hobject::PROP_FLAGS_WEC);
        HString* done_key = (HString*)heap.strs[heap::BuiltinStr.DONE];
        TVal done_tv; done_tv.set_boolean(true);
        iter_result.put_prop(done_key, done_tv, hobject::PROP_FLAGS_WEC);
        TVal iter_result_tv;
        iter_result_tv.set_object(iter_result);

        HObject*? p_raw = promise_create(heap);
        if (catch err = p_raw) return;
        HObject* p = p_raw;
        promise_settle(p, PROMISE_FULFILLED, &iter_result_tv, heap);
        promise_trigger_reactions(p, heap, ctx.vm);
        ctx.result.set_object(p);
        return;
    }

    if (!return_method.is_object() || !((HObject*)return_method.get_heapptr()).is_callable()) {
        builtin_throw(ctx, heap.type_err_proto, "iterator.return is not a function");
        return;
    }

    TVal sync_this;
    sync_this.set_object(sync_iter);
    TVal step_result = heap.call_fn(ctx.vm, return_method, &arg, 1, sync_this);
    if (heap.has_error) {
        TVal thrown = heap.error_value;
        heap.has_error = false;
        HObject*? rej = async_from_sync_rejected_promise(heap, ctx.vm, thrown);
        if (catch err = rej) { return; }
        ctx.result.set_object(rej);
        return;
    }
    if (!step_result.is_object() || step_result.get_heapptr() == null) {
        TVal te = async_from_sync_type_error(heap, "Iterator result is not an object");
        HObject*? rej = async_from_sync_rejected_promise(heap, ctx.vm, te);
        if (catch err = rej) { return; }
        ctx.result.set_object(rej);
        return;
    }
    HObject* result_obj = (HObject*)step_result.get_heapptr();

    HString* done_key = (HString*)heap.strs[heap::BuiltinStr.DONE];
    TVal? done_opt = builtins_generic_get(result_obj, done_key, ctx);
    if (ctx.should_throw) return;
    bool done = false;
    if (try dv = done_opt) { done = builtin_to_boolean(&dv); }

    HString* value_key = (HString*)heap.strs[heap::BuiltinStr.VALUE];
    TVal? value_opt = builtins_generic_get(result_obj, value_key, ctx);
    if (ctx.should_throw) return;
    TVal value;
    value.set_undefined();
    if (try vv = value_opt) { value = vv; }

    HObject*? outer = async_from_sync_continuation(heap, ctx.vm, value, done);
    if (catch err = outer) { return; }
    ctx.result.set_object(outer);
}

/// %AsyncFromSyncIteratorPrototype%.throw(value) — ES2018 §27.1.4.5.
fn void builtin_async_from_sync_throw(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    ctx.result.set_undefined();

    HObject* sync_iter = async_from_sync_get_wrapped(ctx);
    if (sync_iter == null) {
        builtin_throw(ctx, heap.type_err_proto, "not an AsyncFromSyncIterator");
        return;
    }

    TVal arg;
    arg.set_undefined();
    if (ctx.argc >= 1) arg = ctx.regs[ctx.base_reg];

    HString* throw_key = builtin_intern_string(heap, "throw");
    TVal? throw_method_opt = builtins_generic_get(sync_iter, throw_key, ctx);
    if (ctx.should_throw) return;
    TVal throw_method;
    if (try tm = throw_method_opt) { throw_method = tm; } else { throw_method.set_undefined(); }

    if (throw_method.is_nullish()) {
        // Step 3: no .throw on the sync iterator — per spec, close the sync
        // iterator (best-effort) and reject with a TypeError.
        TVal te = async_from_sync_type_error(heap, "iterator.throw is not a function");
        HObject*? rej = async_from_sync_rejected_promise(heap, ctx.vm, te);
        if (catch err = rej) { return; }
        ctx.result.set_object(rej);
        return;
    }

    if (!throw_method.is_object() || !((HObject*)throw_method.get_heapptr()).is_callable()) {
        builtin_throw(ctx, heap.type_err_proto, "iterator.throw is not a function");
        return;
    }

    TVal sync_this;
    sync_this.set_object(sync_iter);
    TVal step_result = heap.call_fn(ctx.vm, throw_method, &arg, 1, sync_this);
    if (heap.has_error) {
        TVal thrown = heap.error_value;
        heap.has_error = false;
        HObject*? rej = async_from_sync_rejected_promise(heap, ctx.vm, thrown);
        if (catch err = rej) { return; }
        ctx.result.set_object(rej);
        return;
    }
    if (!step_result.is_object() || step_result.get_heapptr() == null) {
        TVal te = async_from_sync_type_error(heap, "Iterator result is not an object");
        HObject*? rej = async_from_sync_rejected_promise(heap, ctx.vm, te);
        if (catch err = rej) { return; }
        ctx.result.set_object(rej);
        return;
    }
    HObject* result_obj = (HObject*)step_result.get_heapptr();

    HString* done_key = (HString*)heap.strs[heap::BuiltinStr.DONE];
    TVal? done_opt = builtins_generic_get(result_obj, done_key, ctx);
    if (ctx.should_throw) return;
    bool done = false;
    if (try dv = done_opt) { done = builtin_to_boolean(&dv); }

    HString* value_key = (HString*)heap.strs[heap::BuiltinStr.VALUE];
    TVal? value_opt = builtins_generic_get(result_obj, value_key, ctx);
    if (ctx.should_throw) return;
    TVal value;
    value.set_undefined();
    if (try vv = value_opt) { value = vv; }

    HObject*? outer = async_from_sync_continuation(heap, ctx.vm, value, done);
    if (catch err = outer) { return; }
    ctx.result.set_object(outer);
}

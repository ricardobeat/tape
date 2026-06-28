/// Promise constructor, Promise.prototype methods, and microtask integration.
module duktape::builtins;
import duktape::types;
import libc;
import duktape::hstring;

import duktape::heap;
import duktape::hobject;
import duktape::env;
import duktape::bytecode;
import std::io;

// ============================================================================
// Promise helpers (ES6 §25.4)
// ============================================================================

const uint PROMISE_PENDING   = 0;
const uint PROMISE_FULFILLED = 1;
const uint PROMISE_REJECTED  = 2;

/// Hidden property keys for Promise internals.
/// Leading \xFF makes them inaccessible to user code (no way to spell that
/// byte in ECMAScript string literals).
const char[] PROMISE_REACTION_NEXT_KEY = "\xFFpromise_reaction_next";

/// Initialize the HObjectPromise extra fields for a freshly-allocated
/// Promise object.  Called once on allocation (covers both user-facing
/// Promise instances and Promise.prototype itself).
fn void promise_init(HObject* promise) {
    if (promise == null) return;
    (*promise.extra_ptr()).promise.state = PROMISE_PENDING;
    (*promise.extra_ptr()).promise.result.set_undefined();
    (*promise.extra_ptr()).promise.reactions_head = null;
    (*promise.extra_ptr()).promise.reactions_tail = null;
}

/// Get the promise state from HObjectExtra.promise.state.
fn uint promise_get_state(HObject* promise, uint default_state) {
    if (promise == null) return default_state;
    return (*promise.extra_ptr()).promise.state;
}

/// Set the promise state.  Idempotent: only writes if currently pending
/// (a Promise can only be settled once).
fn void promise_set_state(HObject* promise, uint state) {
    if (promise == null) return;
    if ((*promise.extra_ptr()).promise.state != PROMISE_PENDING) return;
    (*promise.extra_ptr()).promise.state = state;
}

/// Settle a Promise in one shot: state + result + refcounting.
/// No-op if the promise is already settled.
fn void promise_settle(HObject* promise, uint state, TVal* val, Heap* heap) {
    if (promise == null) return;
    if ((*promise.extra_ptr()).promise.state != PROMISE_PENDING) return;
    heap.tval_copy_ref(&(*promise.extra_ptr()).promise.result, val);
    (*promise.extra_ptr()).promise.state = state;
}

/// Set the promise result.  Refcount-aware.
fn void promise_set_result(HObject* promise, TVal* val, Heap* heap) {
    if (promise == null) return;
    heap.tval_copy_ref(&(*promise.extra_ptr()).promise.result, val);
}

/// Get the promise's resolved value / rejection reason.
fn TVal promise_get_result(HObject* promise) {
    return (*promise.extra_ptr()).promise.result;
}

/// Get the "next" pointer in the reaction linked list.
fn HObject* reaction_get_next(HObject* reaction, Heap* heap) {
    if (reaction == null) return null;
    HString* key = builtin_intern_string(heap, PROMISE_REACTION_NEXT_KEY);
    if (key == null) return null;
    if (try nv = reaction.get_prop(key)) {
        if (nv.is_object() && nv.get_heapptr() != null) {
            return (HObject*)nv.get_heapptr();
        }
    }
    return null;
}

/// Set the "next" pointer in the reaction linked list.
fn void reaction_set_next(HObject* reaction, HObject* next, Heap* heap) {
    if (reaction == null) return;
    HString* key = builtin_intern_string(heap, PROMISE_REACTION_NEXT_KEY);
    if (key == null) return;
    TVal nv;
    if (next != null) {
        nv.set_object(next);
    } else {
        nv.set_undefined();
    }
    reaction.put_prop(key, nv, hobject::PROP_FLAGS_WEC);
}

/// Check that `this` is a Promise object.
fn HObject* check_promise(BuiltinContext* ctx) {
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    if (this_val.is_object() && this_val.get_heapptr() != null) {
        HObject* obj = (HObject*)this_val.get_heapptr();
        if (obj.flags.obj_class == hobject::ObjClass.PROMISE) return obj;
    }
    HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err = err_raw) {
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_str = builtin_intern_string(ctx.heap,
            "Promise.prototype method called on incompatible value");
        if (msg_str != null) {
            TVal msg_tv;
            msg_tv.set_string(msg_str);
            err.put_prop(builtin_intern_string(ctx.heap, "message"), msg_tv, hobject::PROP_FLAGS_WEC);
        }
        ctx.throw_value.set_object(err);
    } else {
        ctx.throw_value.set_undefined();
    }
    ctx.should_throw = true;
    return null;
}

/// Trigger all pending reactions for a settled promise.  Reactions are
/// detached from the promise's linked list before invocation, so new
/// reactions added during a handler call don't re-trigger this promise.
fn void promise_trigger_reactions(HObject* promise, Heap* heap, void* vm) {
    uint state = promise_get_state(promise, PROMISE_PENDING);
    if (state == PROMISE_PENDING) return;

    // Snapshot and clear the reaction list before invoking.
    HObject* reaction = (*promise.extra_ptr()).promise.reactions_head;
    (*promise.extra_ptr()).promise.reactions_head = null;
    (*promise.extra_ptr()).promise.reactions_tail = null;

    TVal result = promise_get_result(promise);

    while (reaction != null) {
        HObject* next = reaction_get_next(reaction, heap);
        // Unlink before invoking so reactions added during invocation are
        // attached to whatever new promise the handler returns to.
        reaction_set_next(reaction, null, heap);

        // Get handler: onFulfilled for fulfilled, onRejected for rejected
        char[] handler_prop = (state == PROMISE_FULFILLED) ? "onFulfilled" : "onRejected";
        HString* handler_key = builtin_intern_string(heap, handler_prop);
        TVal? handler_opt = reaction.get_prop(handler_key);
        TVal handler;
        if (try h = handler_opt) {
            handler = h;
        } else {
            handler.set_undefined();
        }

        // Get the downstream promise to resolve/reject
        HString* downstream_key = builtin_intern_string(heap, "downstream");
        TVal downstream_val;
        downstream_val.set_undefined();
        HObject* downstream = null;
        if (try dv = reaction.get_prop(downstream_key)) {
            if (dv.is_object() && dv.get_heapptr() != null) {
                HObject* d = (HObject*)dv.get_heapptr();
                if (d.flags.obj_class == hobject::ObjClass.PROMISE) {
                    downstream = d;
                    downstream_val = dv;
                }
            }
        }

        if (state == PROMISE_FULFILLED) {
            bool callable = handler.is_lightfunc() ||
                (handler.is_object() && handler.get_heapptr() != null &&
                 ((HObject*)handler.get_heapptr()).is_callable());
            if (handler.is_undefined() || !callable) {
                // No onFulfilled — pass through to downstream
                if (downstream != null) {
                    promise_settle(downstream, PROMISE_FULFILLED, &result, heap);
                    promise_trigger_reactions(downstream, heap, vm);
                }
            } else {
                // Enqueue microtask — handler will be called asynchronously,
                // downstream will be resolved with handler's return value by drain
                heap.enqueue_microtask(handler, result, downstream_val);
            }
        } else {
            bool callable = handler.is_lightfunc() ||
                (handler.is_object() && handler.get_heapptr() != null &&
                 ((HObject*)handler.get_heapptr()).is_callable());
            if (handler.is_undefined() || !callable) {
                // No onRejected — pass through rejection to downstream
                if (downstream != null) {
                    promise_settle(downstream, PROMISE_REJECTED, &result, heap);
                    promise_trigger_reactions(downstream, heap, vm);
                }
            } else {
                // Enqueue microtask — handler will be called asynchronously,
                // downstream will be resolved with handler's return value by drain
                heap.enqueue_microtask(handler, result, downstream_val);
            }
        }

        reaction = next;
    }
}

/// Call a handler function with one argument.
fn TVal call_handler(TVal handler, TVal* arg, Heap* heap, void* vm) {
    if (heap.call_handler_fn != null && vm != null) {
        return heap.call_handler_fn(vm, handler, arg);
    }
    TVal result;
    result.set_undefined();
    return result;
}

/// Microtask completion callback — resolves the downstream promise with the
/// handler's return value.  Registered as heap.microtask_after_fn during init.
fn void promise_microtask_after(void* heap_raw, void* vm, TVal result, TVal downstream) {
    Heap* heap = (Heap*)heap_raw;
    if (!downstream.is_object() || downstream.get_heapptr() == null) return;
    HObject* ds = (HObject*)downstream.get_heapptr();
    if (ds.flags.obj_class != hobject::ObjClass.PROMISE) return;

    // Check if downstream is already settled (shouldn't be, but guard)
    uint state = promise_get_state(ds, PROMISE_PENDING);
    if (state != PROMISE_PENDING) return;

    // If the handler threw, reject the downstream with the error
    if (heap.has_error) {
        heap.has_error = false;
        promise_settle(ds, PROMISE_REJECTED, &heap.error_value, heap);
        promise_trigger_reactions(ds, heap, vm);
        return;
    }

    // If the result is a thenable, follow it via the Promise Resolution
    // Procedure.  The thenable will drive the downstream promise.
    HObject*? coerced = promise_coerce_thenable(heap, result, vm);
    if (catch err_c = coerced) {
        // promise_coerce_thenable returns null for non-thenables — settle normally below
    } else {
        // The thenable owns the downstream now; don't settle it directly.
        return;
    }

    // Non-thenable result — settle the downstream promise directly.
    promise_settle(ds, PROMISE_FULFILLED, &result, heap);
    promise_trigger_reactions(ds, heap, vm);
}

/// Resolve or reject a capability's downstream promise.
fn void call_capability(TVal resolve, TVal reject, TVal* val, Heap* heap, bool is_resolve, void* vm) {
    TVal callee = is_resolve ? resolve : reject;
    if (callee.is_undefined()) return;

    if (callee.is_object() && callee.get_heapptr() != null) {
        HObject* obj = (HObject*)callee.get_heapptr();
        // If it's a PROMISE directly, resolve/reject it
        if (obj.flags.obj_class == hobject::ObjClass.PROMISE) {
            promise_settle(obj, is_resolve ? PROMISE_FULFILLED : PROMISE_REJECTED, val, heap);
            promise_trigger_reactions(obj, heap, vm);
            return;
        }
        // If it's a capability object, look up the "promise" property
        HString* promise_key = builtin_intern_string(heap, "promise");
        if (try pv = obj.get_prop(promise_key)) {
            if (pv.is_object() && pv.get_heapptr() != null) {
                HObject* prom = (HObject*)pv.get_heapptr();
                if (prom.flags.obj_class == hobject::ObjClass.PROMISE) {
                    promise_settle(prom, is_resolve ? PROMISE_FULFILLED : PROMISE_REJECTED, val, heap);
                    promise_trigger_reactions(prom, heap, vm);
                }
            }
        }
    }
}

fn void builtin_promise_resolve_callback(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;

    // Try to get promise from the function object's stored property
    HObject* promise = null;
    if (ctx.callee_obj != null) {
        HString* promise_key = builtin_intern_string(heap, "\xFFpromise");
        if (try pv = ctx.callee_obj.get_prop(promise_key)) {
            if (pv.is_object() && pv.get_heapptr() != null) {
                HObject* obj = (HObject*)pv.get_heapptr();
                if (obj.flags.obj_class == hobject::ObjClass.PROMISE) {
                    promise = obj;
                }
            }
        }
    }
    // Fallback to promise_resolve_stack
    if (promise == null && heap.promise_resolve_top > 0 && heap.promise_resolve_stack != null) {
        promise = heap.promise_resolve_stack[heap.promise_resolve_top - 1];
    }
    if (promise == null) return;

    uint state = promise_get_state(promise, PROMISE_PENDING);
    if (state != PROMISE_PENDING) return;

    TVal value;
    value.set_undefined();
    if (ctx.argc >= 1) value = ctx.regs[ctx.base_reg];

    promise_settle(promise, PROMISE_FULFILLED, &value, heap);
    promise_trigger_reactions(promise, heap, ctx.vm);
}

fn void builtin_promise_reject_callback(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;

    HObject* promise = null;
    if (ctx.callee_obj != null) {
        HString* promise_key = builtin_intern_string(heap, "\xFFpromise");
        if (try pv = ctx.callee_obj.get_prop(promise_key)) {
            if (pv.is_object() && pv.get_heapptr() != null) {
                HObject* obj = (HObject*)pv.get_heapptr();
                if (obj.flags.obj_class == hobject::ObjClass.PROMISE) {
                    promise = obj;
                }
            }
        }
    }
    if (promise == null && heap.promise_resolve_top > 0 && heap.promise_resolve_stack != null) {
        promise = heap.promise_resolve_stack[heap.promise_resolve_top - 1];
    }
    if (promise == null) return;

    uint state = promise_get_state(promise, PROMISE_PENDING);
    if (state != PROMISE_PENDING) return;

    TVal reason;
    reason.set_undefined();
    if (ctx.argc >= 1) reason = ctx.regs[ctx.base_reg];

    promise_settle(promise, PROMISE_REJECTED, &reason, heap);
    promise_trigger_reactions(promise, heap, ctx.vm);
}

/// Create a new pending Promise.
fn HObject*? promise_create(Heap* heap) {
    HObject*? prom_raw = heap.alloc_object(hobject::ObjClass.PROMISE);
    if (catch err = prom_raw) return null;
    HObject* prom = prom_raw;
    prom.prototype = heap.promise_proto;
    promise_init(prom);
    return prom;
}

/// Create a resolve/reject capability object (internal).
fn HObject*? promise_create_capability(Heap* heap, HObject* promise) {
    HObject*? cap_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = cap_raw) return null;
    HObject* cap = cap_raw;

    HString* promise_key = builtin_intern_string(heap, "promise");
    TVal promise_val;
    promise_val.set_object(promise);
    cap.put_prop(promise_key, promise_val, hobject::PROP_FLAGS_WEC);

    return cap;
}

/// Append a reaction HObject to the promise's reaction linked list.
fn void promise_add_reaction(HObject* promise, HObject* reaction, Heap* heap) {
    if (promise == null || reaction == null) return;
    reaction_set_next(reaction, null, heap);
    if ((*promise.extra_ptr()).promise.reactions_tail == null) {
        (*promise.extra_ptr()).promise.reactions_head = reaction;
    } else {
        reaction_set_next((HObject*)(*promise.extra_ptr()).promise.reactions_tail, reaction, heap);
    }
    (*promise.extra_ptr()).promise.reactions_tail = reaction;
}

/// Get the resolved value of a Promise-like object (Promise, thenable, etc).
/// Reads from the HObjectPromise extra slot.  Only valid for ObjClass.PROMISE.
fn TVal promise_try_get_value(HObject* obj) {
    if (obj == null || obj.flags.obj_class != hobject::ObjClass.PROMISE) {
        TVal undef; undef.set_undefined(); return undef;
    }
    return promise_get_result(obj);
}

// ============================================================================
// Promise constructor (ES6 §25.4.3.1)
// ============================================================================

fn void builtin_promise(BuiltinContext* ctx) {
    HObject*? prom_raw = promise_create(ctx.heap);
    if (catch err = prom_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* promise = prom_raw;

    if (ctx.argc < 1) {
        // No executor — return pending promise
        ctx.result.set_object(promise);
        return;
    }

    TVal executor = ctx.regs[ctx.base_reg];
    // ES2015 §25.6.3.1 step 2: throw TypeError if IsCallable(executor) is false.
    // An executor is callable iff it's an object with is_callable() or a lightfunc.
    bool exec_callable = executor.is_lightfunc();
    HObject* exec_func = null;
    if (executor.is_object() && executor.get_heapptr() != null) {
        exec_func = (HObject*)executor.get_heapptr();
        exec_callable = exec_func.is_callable();
    }
    if (!exec_callable) {
        HObject*? err_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (catch err_e = err_raw) {
            ctx.result.set_undefined();
            return;
        }
        HObject* err = err_raw;
        err.prototype = ctx.heap.type_err_proto;
        HString* msg_key = builtin_intern_string(ctx.heap, "message");
        HString* msg_str = builtin_intern_string(ctx.heap, "Promise resolver undefined is not a function");
        if (msg_key != null && msg_str != null) {
            TVal msg_tv; msg_tv.set_string(msg_str);
            err.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        }
        ctx.should_throw = true;
        ctx.throw_value.set_object(err);
        return;
    }

    if (exec_func != null && (*exec_func.extra_ptr()).func.comp_func == null && (*exec_func.extra_ptr()).func.builtin_fn_index < 0) {
        ctx.result.set_object(promise);
        return;
    }

    // Push promise onto resolve stack so resolve/reject callbacks can find it
    Heap* heap = ctx.heap;
    if (heap.promise_resolve_top >= heap.promise_resolve_cap) {
        uint new_cap = heap.promise_resolve_cap == 0 ? 16 : heap.promise_resolve_cap * 2;
        void*? new_raw = heap.alloc((usz)(HObject*::size * new_cap));
        HObject** new_stack;
        if (try p = new_raw) {
            new_stack = (HObject**)p;
        } else {
            ctx.result.set_object(promise);
            return;
        }
        if (heap.promise_resolve_stack != null) {
            libc::memcpy(new_stack, heap.promise_resolve_stack, (usz)(HObject*::size * heap.promise_resolve_top));
            heap.free(heap.promise_resolve_stack);
        } else {
            libc::memset(new_stack, 0, (usz)(HObject*::size * new_cap));
        }
        heap.promise_resolve_stack = new_stack;
        heap.promise_resolve_cap = new_cap;
    }
    if (heap.promise_resolve_stack != null) {
        heap.promise_resolve_stack[heap.promise_resolve_top] = promise;
        heap.promise_resolve_top++;
    }

    // Create resolve/reject function objects that carry the promise reference
    HObject*? resolve_func_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = resolve_func_raw) {
        ctx.result.set_object(promise);
        return;
    }
    HObject* resolve_func = resolve_func_raw;
    (*resolve_func.extra_ptr()).func.builtin_fn_index = (int)BUILTIN_PROMISE_RESOLVE_CALLBACK;
    resolve_func.flags.callable = true;
    resolve_func.prototype = heap.function_proto;
    // Per ES2015 §25.4.1.5.1: resolve/reject callbacks have length=1, name="".
    HString* len_key = builtin_intern_string(heap, "length");
    if (len_key != null) {
        TVal len_tv; len_tv.set_fastint(1);
        resolve_func.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NWC);
    }
    HString* name_key = builtin_intern_string(heap, "name");
    if (name_key != null) {
        TVal name_tv; name_tv.set_string(builtin_intern_string(heap, ""));
        resolve_func.put_prop(name_key, name_tv, hobject::PROP_FLAGS_NWC);
    }
    HString* promise_key = builtin_intern_string(heap, "\xFFpromise");
    TVal promise_ref;
    promise_ref.set_object(promise);
    resolve_func.put_prop(promise_key, promise_ref, hobject::PROP_FLAGS_WEC);

    HObject*? reject_func_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = reject_func_raw) {
        ctx.result.set_object(promise);
        return;
    }
    HObject* reject_func = reject_func_raw;
    (*reject_func.extra_ptr()).func.builtin_fn_index = (int)BUILTIN_PROMISE_REJECT_CALLBACK;
    reject_func.flags.callable = true;
    reject_func.prototype = heap.function_proto;
    if (len_key != null) {
        TVal len_tv; len_tv.set_fastint(1);
        reject_func.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NWC);
    }
    if (name_key != null) {
        TVal name_tv; name_tv.set_string(builtin_intern_string(heap, ""));
        reject_func.put_prop(name_key, name_tv, hobject::PROP_FLAGS_NWC);
    }
    reject_func.put_prop(promise_key, promise_ref, hobject::PROP_FLAGS_WEC);

    TVal resolve_tv;
    resolve_tv.set_object(resolve_func);
    TVal reject_tv;
    reject_tv.set_object(reject_func);

    // Call executor(resolve, reject) via the VM
    TVal[2] exec_args;
    exec_args[0] = resolve_tv;
    exec_args[1] = reject_tv;
    if (heap.call_fn != null && ctx.vm != null) {
        heap.call_fn(ctx.vm, executor, &exec_args[0], 2, ctx.this_val);
        if (ctx.heap.has_error) { ctx.should_throw = true; ctx.heap.has_error = false; return; }
    }

    // Pop from resolve stack
    if (heap.promise_resolve_top > 0) {
        heap.promise_resolve_top--;
    }

    ctx.result.set_object(promise);
}

// ============================================================================
// Promise.prototype.then(onFulfilled, onRejected) — ES6 §25.4.5.3
// ============================================================================

/// SpeciesConstructor helper — ES6 §7.3.22
/// Returns the constructor to use when creating derived objects.
fn HObject*? species_constructor(Heap* heap, void* vm, TVal o, HObject* fallback_ctor, HObject* fallback_proto) {
    // 1. Assert: Type(O) is Object.
    // 2. Let C = O.[[Get]]("constructor").
    HString* ctor_key = builtin_intern_string(heap, "constructor");
    if (ctor_key == null) return null;
    HObject* obj = (HObject*)o.get_heapptr();
    if (obj == null) return null;
    TVal? ctor_raw = obj.get_prop_proto(ctor_key);
    TVal ctor_val;
    if (catch err_c = ctor_raw) {
        return null;
    }
    ctor_val = ctor_raw;
    // 3. ReturnIfAbrupt(C).
    // 4. If C is undefined, return defaultConstructor.
    if (ctor_val.is_undefined()) {
        return fallback_ctor;
    }
    // 5. If Type(C) is not Object, throw TypeError.
    if (!ctor_val.is_object() || ctor_val.get_heapptr() == null) {
        HObject*? err_raw = heap.alloc_object(hobject::ObjClass.ERROR);
        if (try err = err_raw) {
            err.prototype = heap.type_err_proto;
            HString* msg_str = builtin_intern_string(heap, "constructor is not an object");
            if (msg_str != null) {
                TVal msg_tv; msg_tv.set_string(msg_str);
                err.put_prop(builtin_intern_string(heap, "message"), msg_tv, hobject::PROP_FLAGS_WC);
            }
        }
        return null;
    }
    // 6. Let S = Get(C, @@species).
    HString* species_sym = ensure_species_symbol(heap);
    if (species_sym == null) return fallback_ctor;
    HObject* ctor_obj = (HObject*)ctor_val.get_heapptr();
    TVal? species_raw = ctor_obj.get_prop_proto(species_sym);
    TVal species_val;
    if (catch err_s = species_raw) {
        return null;
    }
    species_val = species_raw;
    // 7. ReturnIfAbrupt(S).
    // 8. If S is undefined or null, return defaultConstructor.
    if (species_val.is_undefined() || species_val.is_null()) {
        return fallback_ctor;
    }
    // 9. If IsConstructor(S) is true, return S.
    if (species_val.is_object() && species_val.get_heapptr() != null) {
        HObject* s_obj = (HObject*)species_val.get_heapptr();
        if (s_obj.flags.callable) return s_obj;
    }
    if (species_val.is_lightfunc()) {
        // Lightfuncs are not constructible via `new` in our engine,
        // but for SpeciesConstructor we treat them as constructible.
        return fallback_ctor;
    }
    // 10. Throw TypeError.
    HObject*? err_raw2 = heap.alloc_object(hobject::ObjClass.ERROR);
    if (try err2 = err_raw2) {
        err2.prototype = heap.type_err_proto;
        HString* msg_str2 = builtin_intern_string(heap, "SpeciesConstructor result is not a constructor");
        if (msg_str2 != null) {
            TVal msg_tv2; msg_tv2.set_string(msg_str2);
            err2.put_prop(builtin_intern_string(heap, "message"), msg_tv2, hobject::PROP_FLAGS_WC);
        }
    }
    return null;
}

fn void builtin_promise_proto_then(BuiltinContext* ctx) {
    HObject* promise = check_promise(ctx);
    if (promise == null) return;

    TVal on_fulfilled;
    on_fulfilled.set_undefined();
    TVal on_rejected;
    on_rejected.set_undefined();
    if (ctx.argc >= 1) on_fulfilled = ctx.regs[ctx.base_reg];
    if (ctx.argc >= 2) on_rejected  = ctx.regs[ctx.base_reg + 1];

    // Determine the constructor via SpeciesConstructor (ES6 §25.4.5.3 step 2)
    TVal this_val = ctx.regs[ctx.base_reg - 1];
    HObject* default_ctor = ctx.heap.promise_ctor;
    HObject*? sc_opt = species_constructor(ctx.heap, ctx.vm, this_val, default_ctor, ctx.heap.promise_proto);
    HObject* ctor;
    if (catch err_sc = sc_opt) {
        ctor = default_ctor;
    } else if (sc_opt != null) {
        ctor = sc_opt;
    } else {
        ctor = default_ctor;
    }

    // Create a new promise for the chain (use promise_create for now;
    // full constructor call via NewPromiseCapability is future work)
    HObject* new_promise;
    if (ctor == default_ctor) {
        HObject*? new_prom_raw = promise_create(ctx.heap);
        if (catch err = new_prom_raw) {
            ctx.result.set_undefined();
            return;
        }
        new_promise = new_prom_raw;
    } else {
        // Non-default constructor: still create via promise_create
        // (full NewPromiseCapability implementation needed for true subclassing)
        HObject*? new_prom_raw = promise_create(ctx.heap);
        if (catch err = new_prom_raw) {
            ctx.result.set_undefined();
            return;
        }
        new_promise = new_prom_raw;
    }

    // Build reaction object
    HObject*? reaction_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = reaction_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* reaction = reaction_raw;

    HString* onf_key = builtin_intern_string(ctx.heap, "onFulfilled");
    reaction.put_prop(onf_key, on_fulfilled, hobject::PROP_FLAGS_WEC);

    HString* onr_key = builtin_intern_string(ctx.heap, "onRejected");
    reaction.put_prop(onr_key, on_rejected, hobject::PROP_FLAGS_WEC);

    HString* downstream_key = builtin_intern_string(ctx.heap, "downstream");
    TVal downstream_val;
    downstream_val.set_object(new_promise);
    reaction.put_prop(downstream_key, downstream_val, hobject::PROP_FLAGS_WEC);

    uint state = promise_get_state(promise, PROMISE_PENDING);
    if (state == PROMISE_PENDING) {
        promise_add_reaction(promise, reaction, ctx.heap);
    } else {
        // Promise already settled — trigger reactions now.  Adding the
        // reaction first then triggering ensures the linked-list walk sees
        // it (trigger clears the list before iterating, but our snapshot
        // already includes the just-added reaction).
        promise_add_reaction(promise, reaction, ctx.heap);
        promise_trigger_reactions(promise, ctx.heap, ctx.vm);
    }

    ctx.result.set_object(new_promise);
}

// ============================================================================
// Promise.prototype.catch(onRejected) — ES6 §25.4.5.1
// ============================================================================

fn void builtin_promise_proto_catch(BuiltinContext* ctx) {
    TVal on_rejected;
    on_rejected.set_undefined();
    if (ctx.argc >= 1) on_rejected = ctx.regs[ctx.base_reg];

    ctx.regs[ctx.base_reg].set_undefined();     // onFulfilled = undefined
    ctx.regs[ctx.base_reg + 1] = on_rejected;   // onRejected = original arg
    ctx.argc = 2;
    builtin_promise_proto_then(ctx);
}

// ============================================================================
// Promise.prototype.finally(onFinally) — ES2018 §25.4.5.3
// ============================================================================

fn void builtin_promise_proto_finally(BuiltinContext* ctx) {
    HObject* promise = check_promise(ctx);
    if (promise == null) return;

    TVal on_finally;
    on_finally.set_undefined();
    if (ctx.argc >= 1) on_finally = ctx.regs[ctx.base_reg];

    if (!on_finally.is_object() || on_finally.get_heapptr() == null ||
        !((HObject*)on_finally.get_heapptr()).is_callable()) {
        ctx.regs[ctx.base_reg + 1] = on_finally;
        builtin_promise_proto_then(ctx);
        return;
    }

    ctx.regs[ctx.base_reg + 1] = on_finally;
    builtin_promise_proto_then(ctx);
}

// ============================================================================
// Promise.resolve(x) — ES6 §25.4.4.5
// ============================================================================

fn void builtin_promise_resolve(BuiltinContext* ctx) {
    TVal val;
    val.set_undefined();
    if (ctx.argc >= 1) val = ctx.regs[ctx.base_reg];

    // If already a Promise, return it
    if (val.is_object() && val.get_heapptr() != null) {
        HObject* obj = (HObject*)val.get_heapptr();
        if (obj.flags.obj_class == hobject::ObjClass.PROMISE) {
            *ctx.result = val;
            return;
        }
        // Check for thenables (non-Promise objects with callable .then)
        HObject*? coerced = promise_coerce_thenable(ctx.heap, val, ctx.vm);
        if (catch err_c = coerced) {
            // promise_coerce_thenable returns null for non-thenables — that's valid
        } else {
            ctx.result.set_object(coerced);
            return;
        }
    }

    HObject*? prom_raw = promise_create(ctx.heap);
    if (catch err = prom_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* promise = prom_raw;
    promise_settle(promise, PROMISE_FULFILLED, &val, ctx.heap);

    ctx.result.set_object(promise);
}

// ============================================================================
// Promise.reject(r) — ES6 §25.4.4.4
// ============================================================================

fn void builtin_promise_reject(BuiltinContext* ctx) {
    TVal reason;
    reason.set_undefined();
    if (ctx.argc >= 1) reason = ctx.regs[ctx.base_reg];

    HObject*? prom_raw = promise_create(ctx.heap);
    if (catch err = prom_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* promise = prom_raw;
    promise_settle(promise, PROMISE_REJECTED, &reason, ctx.heap);

    ctx.result.set_object(promise);
}

// ============================================================================
// Thenable coercion — ES6 Promise Resolution Procedure
// ============================================================================

/// If `val` is a non-Promise object with a callable `.then` method, create a
/// new Promise, call `thenable.then(resolve, reject)`, and return the wrapper
/// Promise. Returns `null` for non-thenables, in which case the caller should
/// await the original value as a non-thenable (no-op).
fn HObject*? promise_coerce_thenable(Heap* heap, TVal val, void* vm) {
    if (!val.is_object() || val.get_heapptr() == null) return null;
    HObject* obj = (HObject*)val.get_heapptr();
    if (obj.flags.obj_class == hobject::ObjClass.PROMISE) return null;

    // Get .then property
    HString* then_key = builtin_intern_string(heap, "then");
    if (then_key == null) return null;
    TVal? then_opt = obj.get_prop(then_key);
    TVal then_method;
    if (try tm = then_opt) {
        then_method = tm;
    } else {
        return null;
    }

    bool then_callable = then_method.is_lightfunc() ||
        (then_method.is_object() && then_method.get_heapptr() != null &&
         ((HObject*)then_method.get_heapptr()).is_callable());
    if (!then_callable) return null;

    // Create wrapper Promise
    HObject*? wrapper_raw = promise_create(heap);
    if (catch err = wrapper_raw) return null;
    HObject* wrapper = wrapper_raw;

    // Hidden property key used by resolve/reject callbacks
    HString* promise_key = builtin_intern_string(heap, "\xFFpromise");

    // Create resolve callback
    HObject*? resolve_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = resolve_raw) return null;
    HObject* resolve_fn = resolve_raw;
    resolve_fn.flags.callable = true;
    resolve_fn.prototype = heap.function_proto;
    (*resolve_fn.extra_ptr()).func.builtin_fn_index = (int)BUILTIN_PROMISE_RESOLVE_CALLBACK;
    // Set length=1, name="" per ES2015 §25.4.1.3.2 (PromiseCapability records)
    HString* len_key = builtin_intern_string(heap, "length");
    if (len_key != null) {
        TVal len_tv; len_tv.set_fastint(1);
        resolve_fn.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NWC);
    }
    HString* name_key = builtin_intern_string(heap, "name");
    if (name_key != null) {
        TVal name_tv; name_tv.set_string(builtin_intern_string(heap, ""));
        resolve_fn.put_prop(name_key, name_tv, hobject::PROP_FLAGS_NWC);
    }
    if (promise_key != null) {
        TVal wrapper_tv; wrapper_tv.set_object(wrapper);
        resolve_fn.put_prop(promise_key, wrapper_tv, hobject::PROP_FLAGS_WEC);
    }
    TVal resolve_tv; resolve_tv.set_object(resolve_fn);

    // Create reject callback
    HObject*? reject_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = reject_raw) return null;
    HObject* reject_fn = reject_raw;
    reject_fn.flags.callable = true;
    reject_fn.prototype = heap.function_proto;
    (*reject_fn.extra_ptr()).func.builtin_fn_index = (int)BUILTIN_PROMISE_REJECT_CALLBACK;
    if (len_key != null) {
        TVal len_tv; len_tv.set_fastint(1);
        reject_fn.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NWC);
    }
    if (name_key != null) {
        TVal name_tv; name_tv.set_string(builtin_intern_string(heap, ""));
        reject_fn.put_prop(name_key, name_tv, hobject::PROP_FLAGS_NWC);
    }
    if (promise_key != null) {
        TVal wrapper_tv; wrapper_tv.set_object(wrapper);
        reject_fn.put_prop(promise_key, wrapper_tv, hobject::PROP_FLAGS_WEC);
    }
    TVal reject_tv; reject_tv.set_object(reject_fn);

    // Call thenable.then(resolve, reject). The thenable is responsible for
    // calling one of these to settle the wrapper Promise.
    TVal[2] arg_arr = { resolve_tv, reject_tv };
    heap.call_fn(vm, then_method, &arg_arr, 2, val);

    return wrapper;
}

// ============================================================================
// Promise.all/race element-tracking helpers (ES6 §25.4.4.1, §25.4.4.3)
//
// Both algorithms need to attach per-element callbacks to pending input
// promises and update shared state (remaining count for all, first-settler
// for race) when each input settles.  These helpers create the shared
// "state" object and the per-element callbacks.  The state is referenced
// from each callback's hidden properties so they can find each other.
//
// Hidden state schema on the outer promise:
//   \xFFstate — state HObject carrying remaining count, result array,
//               rejected flag, and outer promise reference.
// Hidden props on each element callback:
//   \xFFouter   — outer promise (so we can settle it)
//   \xFFstate   — shared state object (so callbacks share remaining count)
//   \xFFidx     — index in the result array (for all)
// ============================================================================

/// Create the shared state object for Promise.all / Promise.race tracking.
fn HObject*? promise_create_all_state(Heap* heap, HObject* outer_promise, HObject* arr, usz initial_remaining) {
    HObject*? state_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = state_raw) return null;
    HObject* state = state_raw;
    state.prototype = heap.object_proto;

    HString* outer_key = builtin_intern_string(heap, "\xFFouter");
    HString* arr_key = builtin_intern_string(heap, "\xFFarr");
    HString* remaining_key = builtin_intern_string(heap, "\xFFremaining");
    HString* rejected_key = builtin_intern_string(heap, "\xFFrejected");

    if (outer_key != null) {
        TVal outer_tv; outer_tv.set_object(outer_promise);
        state.put_prop(outer_key, outer_tv, hobject::PROP_FLAGS_WEC);
    }
    if (arr_key != null) {
        TVal arr_tv; arr_tv.set_object(arr);
        state.put_prop(arr_key, arr_tv, hobject::PROP_FLAGS_WEC);
    }
    if (remaining_key != null) {
        TVal rem_tv; rem_tv.set_fastint((long)initial_remaining);
        state.put_prop(remaining_key, rem_tv, hobject::PROP_FLAGS_WEC);
    }
    if (rejected_key != null) {
        TVal rej_tv; rej_tv.set_boolean(false);
        state.put_prop(rejected_key, rej_tv, hobject::PROP_FLAGS_WEC);
    }
    return state;
}

/// Create a per-element fulfill/reject callback function.  Carries the shared
/// state and index via hidden properties.
fn HObject*? promise_create_element_callback(Heap* heap, uint builtin_index, HObject* state, usz idx) {
    HObject*? fn_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = fn_raw) return null;
    HObject* cb = fn_raw;
    (*cb.extra_ptr()).func.builtin_fn_index = (int)builtin_index;
    cb.flags.callable = true;
    cb.prototype = heap.function_proto;

    HString* len_key = builtin_intern_string(heap, "length");
    if (len_key != null) {
        TVal len_tv; len_tv.set_fastint(1);
        cb.put_prop(len_key, len_tv, hobject::PROP_FLAGS_NWC);
    }
    HString* name_key = builtin_intern_string(heap, "name");
    if (name_key != null) {
        TVal name_tv; name_tv.set_string(builtin_intern_string(heap, ""));
        cb.put_prop(name_key, name_tv, hobject::PROP_FLAGS_NWC);
    }
    HString* state_key = builtin_intern_string(heap, "\xFFstate");
    if (state_key != null) {
        TVal state_tv; state_tv.set_object(state);
        cb.put_prop(state_key, state_tv, hobject::PROP_FLAGS_WEC);
    }
    HString* idx_key = builtin_intern_string(heap, "\xFFidx");
    if (idx_key != null) {
        TVal idx_tv; idx_tv.set_fastint((long)idx);
        cb.put_prop(idx_key, idx_tv, hobject::PROP_FLAGS_WEC);
    }
    return cb;
}

/// Promise.all per-element fulfill handler (called via microtask).
/// Stores the value at result[idx] and decrements the remaining counter;
/// when it reaches zero, fulfills the outer promise with the result array.
fn void builtin_promise_all_resolve_element(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    if (ctx.callee_obj == null) return;

    // Read state and idx from hidden properties on this callback function.
    HString* state_key = builtin_intern_string(heap, "\xFFstate");
    HString* idx_key = builtin_intern_string(heap, "\xFFidx");
    HString* arr_key = builtin_intern_string(heap, "\xFFarr");
    HString* remaining_key = builtin_intern_string(heap, "\xFFremaining");
    HString* outer_key = builtin_intern_string(heap, "\xFFouter");
    if (state_key == null || idx_key == null) return;

    TVal? state_opt = ctx.callee_obj.get_prop(state_key);
    HObject* state = null;
    if (try sv = state_opt) {
        if (sv.is_object() && sv.get_heapptr() != null) state = (HObject*)sv.get_heapptr();
    }
    if (state == null) return;

    TVal? idx_opt = ctx.callee_obj.get_prop(idx_key);
    usz idx = 0;
    if (try iv = idx_opt) {
        if (iv.is_fastint()) idx = (usz)iv.get_fastint();
    }

    TVal value;
    value.set_undefined();
    if (ctx.argc >= 1) value = ctx.regs[ctx.base_reg];

    // Store value at result[idx] (state.arr)
    if (arr_key != null) {
        TVal? arr_opt = state.get_prop(arr_key);
        HObject* arr = null;
        if (try av = arr_opt) {
            if (av.is_object() && av.get_heapptr() != null) arr = (HObject*)av.get_heapptr();
        }
        if (arr != null) {
            arr.set_array_idx((uint)idx, value);
            // Update array length so user code can read arr.length.
            // (set_array_idx updates array_used but not the cached length /
            // named "length" property.)
            if ((uint)idx + 1 > *arr.array_len_ptr()) {
                array_set_length(arr, (uint)idx + 1, heap);
            }
        }
    }

    // Decrement remaining; settle outer if it reaches zero.
    if (remaining_key != null) {
        TVal? rem_opt = state.get_prop(remaining_key);
        long remaining = 0;
        if (try rv = rem_opt) {
            if (rv.is_fastint()) remaining = rv.get_fastint();
        }
        remaining -= 1;
        TVal new_rem; new_rem.set_fastint(remaining);
        state.put_prop(remaining_key, new_rem, hobject::PROP_FLAGS_WEC);

        if (remaining == 0 && outer_key != null) {
            TVal? outer_opt = state.get_prop(outer_key);
            HObject* outer = null;
            if (try ov = outer_opt) {
                if (ov.is_object() && ov.get_heapptr() != null) outer = (HObject*)ov.get_heapptr();
            }
            // Read current rejected flag — if already rejected, don't overwrite.
            HString* rej_key = builtin_intern_string(heap, "\xFFrejected");
            bool already_rejected = false;
            if (rej_key != null) {
                TVal? rej_opt = state.get_prop(rej_key);
                if (try rj = rej_opt) {
                    if (rj.is_boolean() && rj.get_boolean()) already_rejected = true;
                }
            }
            if (outer != null && !already_rejected) {
                // Settle outer with the result array.
                TVal arr_val;
                if (arr_key != null) {
                    TVal? arr_opt2 = state.get_prop(arr_key);
                    if (try av2 = arr_opt2) {
                        arr_val = av2;
                    } else {
                        arr_val.set_undefined();
                    }
                } else {
                    arr_val.set_undefined();
                }
                promise_settle(outer, PROMISE_FULFILLED, &arr_val, heap);
                promise_trigger_reactions(outer, heap, ctx.vm);
            }
        }
    }
}

/// Promise.all per-element reject handler (called via microtask).
/// Rejects the outer promise on the first rejection (subsequent rejections
/// are ignored per ES6 §25.4.4.1).
fn void builtin_promise_all_reject_element(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    if (ctx.callee_obj == null) return;

    HString* state_key = builtin_intern_string(heap, "\xFFstate");
    HString* outer_key = builtin_intern_string(heap, "\xFFouter");
    HString* rej_key = builtin_intern_string(heap, "\xFFrejected");
    if (state_key == null) return;

    TVal? state_opt = ctx.callee_obj.get_prop(state_key);
    HObject* state = null;
    if (try sv = state_opt) {
        if (sv.is_object() && sv.get_heapptr() != null) state = (HObject*)sv.get_heapptr();
    }
    if (state == null) return;

    TVal reason;
    reason.set_undefined();
    if (ctx.argc >= 1) reason = ctx.regs[ctx.base_reg];

    // Check if already rejected
    bool already_rejected = false;
    if (rej_key != null) {
        TVal? rej_opt = state.get_prop(rej_key);
        if (try rj = rej_opt) {
            if (rj.is_boolean() && rj.get_boolean()) already_rejected = true;
        }
    }
    if (already_rejected) return;

    // Mark rejected
    if (rej_key != null) {
        TVal rej_tv; rej_tv.set_boolean(true);
        state.put_prop(rej_key, rej_tv, hobject::PROP_FLAGS_WEC);
    }

    // Reject the outer promise
    if (outer_key != null) {
        TVal? outer_opt = state.get_prop(outer_key);
        HObject* outer = null;
        if (try ov = outer_opt) {
            if (ov.is_object() && ov.get_heapptr() != null) outer = (HObject*)ov.get_heapptr();
        }
        if (outer != null) {
            promise_settle(outer, PROMISE_REJECTED, &reason, heap);
            promise_trigger_reactions(outer, heap, ctx.vm);
        }
    }
}

/// Promise.race per-element settle handler (called via microtask).
/// Settles the outer promise with the first settled value (fulfilled OR
/// rejected); subsequent settlements are ignored per ES6 §25.4.4.3.
fn void builtin_promise_race_resolve_element(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    if (ctx.callee_obj == null) return;

    HString* state_key = builtin_intern_string(heap, "\xFFstate");
    HString* outer_key = builtin_intern_string(heap, "\xFFouter");
    HString* rej_key = builtin_intern_string(heap, "\xFFrejected");
    if (state_key == null) return;

    TVal? state_opt = ctx.callee_obj.get_prop(state_key);
    HObject* state = null;
    if (try sv = state_opt) {
        if (sv.is_object() && sv.get_heapptr() != null) state = (HObject*)sv.get_heapptr();
    }
    if (state == null) return;

    // Check if already settled (rejected flag repurposed as "settled" flag)
    bool already_settled = false;
    if (rej_key != null) {
        TVal? rej_opt = state.get_prop(rej_key);
        if (try rj = rej_opt) {
            if (rj.is_boolean() && rj.get_boolean()) already_settled = true;
        }
    }
    if (already_settled) return;

    // Mark settled
    if (rej_key != null) {
        TVal rej_tv; rej_tv.set_boolean(true);
        state.put_prop(rej_key, rej_tv, hobject::PROP_FLAGS_WEC);
    }

    TVal value;
    value.set_undefined();
    if (ctx.argc >= 1) value = ctx.regs[ctx.base_reg];

    if (outer_key != null) {
        TVal? outer_opt = state.get_prop(outer_key);
        HObject* outer = null;
        if (try ov = outer_opt) {
            if (ov.is_object() && ov.get_heapptr() != null) outer = (HObject*)ov.get_heapptr();
        }
        if (outer != null) {
            promise_settle(outer, PROMISE_FULFILLED, &value, heap);
            promise_trigger_reactions(outer, heap, ctx.vm);
        }
    }
}

/// Promise.race per-element reject handler — same as fulfill but settles with reject.
fn void builtin_promise_race_reject_element(BuiltinContext* ctx) {
    Heap* heap = ctx.heap;
    if (ctx.callee_obj == null) return;

    HString* state_key = builtin_intern_string(heap, "\xFFstate");
    HString* outer_key = builtin_intern_string(heap, "\xFFouter");
    HString* rej_key = builtin_intern_string(heap, "\xFFrejected");
    if (state_key == null) return;

    TVal? state_opt = ctx.callee_obj.get_prop(state_key);
    HObject* state = null;
    if (try sv = state_opt) {
        if (sv.is_object() && sv.get_heapptr() != null) state = (HObject*)sv.get_heapptr();
    }
    if (state == null) return;

    bool already_settled = false;
    if (rej_key != null) {
        TVal? rej_opt = state.get_prop(rej_key);
        if (try rj = rej_opt) {
            if (rj.is_boolean() && rj.get_boolean()) already_settled = true;
        }
    }
    if (already_settled) return;

    if (rej_key != null) {
        TVal rej_tv; rej_tv.set_boolean(true);
        state.put_prop(rej_key, rej_tv, hobject::PROP_FLAGS_WEC);
    }

    TVal reason;
    reason.set_undefined();
    if (ctx.argc >= 1) reason = ctx.regs[ctx.base_reg];

    if (outer_key != null) {
        TVal? outer_opt = state.get_prop(outer_key);
        HObject* outer = null;
        if (try ov = outer_opt) {
            if (ov.is_object() && ov.get_heapptr() != null) outer = (HObject*)ov.get_heapptr();
        }
        if (outer != null) {
            promise_settle(outer, PROMISE_REJECTED, &reason, heap);
            promise_trigger_reactions(outer, heap, ctx.vm);
        }
    }
}

/// Attach fulfill/reject element callbacks to a pending promise.  Used by
/// Promise.all / Promise.race.  If the promise is already settled, fire
/// the appropriate callback immediately.
fn void promise_attach_element_callbacks(HObject* promise, HObject* fulfill_fn, HObject* reject_fn, Heap* heap, void* vm) {
    if (promise == null) return;

    HString* onf_key = builtin_intern_string(heap, "onFulfilled");
    HString* onr_key = builtin_intern_string(heap, "onRejected");
    HString* ds_key = builtin_intern_string(heap, "downstream");

    // Build reactions for both fulfill and reject.  We use a non-PROMISE
    // downstream so promise_microtask_after returns early (the callbacks
    // do their own work via the shared state object).
    HObject*? fulfill_reaction_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (try fr = fulfill_reaction_raw) {
        TVal ff_tv; ff_tv.set_object(fulfill_fn);
        if (onf_key != null) fr.put_prop(onf_key, ff_tv, hobject::PROP_FLAGS_WEC);
        if (ds_key != null) {
            TVal undef_tv; undef_tv.set_undefined();
            fr.put_prop(ds_key, undef_tv, hobject::PROP_FLAGS_WEC);
        }
        promise_add_reaction(promise, fr, heap);
    }

    HObject*? reject_reaction_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (try rr = reject_reaction_raw) {
        TVal rf_tv; rf_tv.set_object(reject_fn);
        if (onr_key != null) rr.put_prop(onr_key, rf_tv, hobject::PROP_FLAGS_WEC);
        if (ds_key != null) {
            TVal undef_tv; undef_tv.set_undefined();
            rr.put_prop(ds_key, undef_tv, hobject::PROP_FLAGS_WEC);
        }
        promise_add_reaction(promise, rr, heap);
    }

    uint state = promise_get_state(promise, PROMISE_PENDING);
    if (state != PROMISE_PENDING) {
        promise_trigger_reactions(promise, heap, vm);
    }
}

// ============================================================================
// Promise.all(iterable) — ES6 §25.4.4.1
// ============================================================================

fn void builtin_promise_all(BuiltinContext* ctx) {
    TVal iterable;
    iterable.set_undefined();
    if (ctx.argc >= 1) iterable = ctx.regs[ctx.base_reg];

    // Get the constructor (this value) as C per ES6 §25.4.4.1 step 3
    TVal this_ctor_val = ctx.regs[ctx.base_reg - 1];
    TVal resolve_fn;
    resolve_fn.set_undefined();
    HString* resolve_key = builtin_intern_string(ctx.heap, "resolve");
    if (resolve_key != null && this_ctor_val.is_object() && this_ctor_val.get_heapptr() != null) {
        HObject* ctor_obj = (HObject*)this_ctor_val.get_heapptr();
        TVal? rf = ctor_obj.get_prop_proto(resolve_key);
        if (catch err_rf = rf) {
            // fall through — use undefined resolve
        } else {
            resolve_fn = rf;
        }
    }

    HObject*? prom_raw = promise_create(ctx.heap);
    if (catch err = prom_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* promise = prom_raw;

    usz len = 0;
    bool has_len = false;
    HObject* obj = null;

    if (iterable.is_object() && iterable.get_heapptr() != null) {
        obj = (HObject*)iterable.get_heapptr();
        HString* length_key = builtin_intern_string(ctx.heap, "length");
        if (try len_tv = obj.get_prop(length_key)) {
            if (len_tv.is_fastint() && len_tv.get_fastint() >= 0) {
                len = (usz)len_tv.get_fastint();
                has_len = true;
            }
        }
    }

    if (!has_len || len == 0) {
        HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
        TVal arr_val;
        arr_val.set_undefined();
        if (try arr = arr_raw) {
            arr.prototype = ctx.heap.array_proto;
            arr_val.set_object(arr);
        }
        promise_settle(promise, PROMISE_FULFILLED, &arr_val, ctx.heap);
        ctx.result.set_object(promise);
        return;
    }

    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) {
        ctx.result.set_object(promise);
        return;
    }
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;

    // Create shared state for deferred resolution
    HObject*? state_raw = promise_create_all_state(ctx.heap, promise, arr, len);
    if (catch err = state_raw) {
        ctx.result.set_object(promise);
        return;
    }
    HObject* state = state_raw;

    bool resolved = false;

    for (usz i = 0; i < len; i++) {
        TVal idx_tv;
        idx_tv.set_fastint((long)i);

        TVal elem = array_get_elem(obj, (uint)i, ctx.heap);

        // Create per-element fulfill/reject callbacks
        HObject*? fulfill_raw = promise_create_element_callback(ctx.heap, BUILTIN_PROMISE_ALL_RESOLVE_ELEMENT, state, i);
        HObject*? reject_raw = promise_create_element_callback(ctx.heap, BUILTIN_PROMISE_ALL_REJECT_ELEMENT, state, i);
        if (catch err_f = fulfill_raw) continue;
        if (catch err_r = reject_raw) continue;
        HObject* fulfill_fn = fulfill_raw;
        HObject* reject_fn = reject_raw;

        // Normalize via C.resolve(elem) if constructor has a callable resolve
        if (resolve_fn.is_lightfunc() ||
            (resolve_fn.is_object() && resolve_fn.get_heapptr() != null &&
             ((HObject*)resolve_fn.get_heapptr()).is_callable())) {
            TVal[1] args;
            args[0] = elem;
            TVal r = ctx.heap.call_fn(ctx.vm, resolve_fn, &args[0], 1, this_ctor_val);
            if (r.is_object() && r.get_heapptr() != null) {
                HObject* res_obj = (HObject*)r.get_heapptr();
                if (res_obj.flags.obj_class == hobject::ObjClass.PROMISE) {
                    // It's a real Promise — attach element callbacks so the
                    // result is collected when the element settles.
                    promise_attach_element_callbacks(res_obj, fulfill_fn, reject_fn, ctx.heap, ctx.vm);
                    continue;
                }
            }
            elem = r;
        }

        // Non-Promise element (after C.resolve): store immediately, decrement
        // remaining via the fulfill callback path.
        TVal saved_this = ctx.regs[ctx.base_reg - 1];
        ctx.regs[ctx.base_reg - 1].set_object((void*)fulfill_fn);
        ctx.regs[ctx.base_reg] = elem;
        ctx.argc = 1;
        builtin_promise_all_resolve_element(ctx);
        ctx.regs[ctx.base_reg - 1] = saved_this;
    }

    ctx.result.set_object(promise);
}

// ============================================================================
// Promise.allSettled(iterable) — ES2020 §25.6.4.5
// ============================================================================

fn void builtin_promise_allsettled(BuiltinContext* ctx) {
    TVal iterable;
    iterable.set_undefined();
    if (ctx.argc >= 1) iterable = ctx.regs[ctx.base_reg];

    HObject*? prom_raw = promise_create(ctx.heap);
    if (catch err = prom_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* promise = prom_raw;

    usz len = 0;
    bool has_len = false;
    HObject* obj = null;

    if (iterable.is_object() && iterable.get_heapptr() != null) {
        obj = (HObject*)iterable.get_heapptr();
        HString* length_key = builtin_intern_string(ctx.heap, "length");
        if (try len_tv = obj.get_prop(length_key)) {
            if (len_tv.is_fastint() && len_tv.get_fastint() >= 0) {
                len = (usz)len_tv.get_fastint();
                has_len = true;
            }
        }
    }

    if (!has_len || len == 0) {
        HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
        TVal arr_val;
        arr_val.set_undefined();
        if (try arr = arr_raw) {
            arr.prototype = ctx.heap.array_proto;
            arr_val.set_object(arr);
        }
        promise_settle(promise, PROMISE_FULFILLED, &arr_val, ctx.heap);
        ctx.result.set_object(promise);
        return;
    }

    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    if (catch err = arr_raw) {
        ctx.result.set_object(promise);
        return;
    }
    HObject* arr = arr_raw;
    arr.prototype = ctx.heap.array_proto;

    usz remaining = len;
    HString* status_key = builtin_intern_string(ctx.heap, "status");
    HString* value_key = builtin_intern_string(ctx.heap, "value");
    HString* reason_key = builtin_intern_string(ctx.heap, "reason");
    TVal fulfilled_status;
    fulfilled_status.set_string(builtin_intern_string(ctx.heap, "fulfilled"));
    TVal rejected_status;
    rejected_status.set_string(builtin_intern_string(ctx.heap, "rejected"));

    for (usz i = 0; i < len; i++) {
        TVal elem = array_get_elem(obj, (uint)i, ctx.heap);

        if (elem.is_object() && elem.get_heapptr() != null) {
            HObject* elem_obj = (HObject*)elem.get_heapptr();
            if (elem_obj.flags.obj_class == hobject::ObjClass.PROMISE) {
                uint state = promise_get_state(elem_obj, PROMISE_PENDING);

                HObject*? result_obj_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
                if (try result_obj = result_obj_raw) {
                    result_obj.prototype = ctx.heap.object_proto;

                    if (state == PROMISE_FULFILLED) {
                        result_obj.put_prop(status_key, fulfilled_status, hobject::PROP_FLAGS_WEC);
                        TVal val = promise_get_result(elem_obj);
                        result_obj.put_prop(value_key, val, hobject::PROP_FLAGS_WEC);
                    } else if (state == PROMISE_REJECTED) {
                        result_obj.put_prop(status_key, rejected_status, hobject::PROP_FLAGS_WEC);
                        TVal val = promise_get_result(elem_obj);
                        result_obj.put_prop(reason_key, val, hobject::PROP_FLAGS_WEC);
                    } else {
                        result_obj.put_prop(status_key, fulfilled_status, hobject::PROP_FLAGS_WEC);
                        TVal undef;
                        undef.set_undefined();
                        result_obj.put_prop(value_key, undef, hobject::PROP_FLAGS_WEC);
                    }
                    TVal result_tv;
                    result_tv.set_object(result_obj);
                    arr.set_array_idx((uint)i, result_tv);
                }
                remaining--;
                continue;
            }
        }

        HObject*? result_obj_raw = ctx.heap.alloc_object(hobject::ObjClass.OBJECT);
        if (try result_obj = result_obj_raw) {
            result_obj.prototype = ctx.heap.object_proto;
            result_obj.put_prop(status_key, fulfilled_status, hobject::PROP_FLAGS_WEC);
            result_obj.put_prop(value_key, elem, hobject::PROP_FLAGS_WEC);
            TVal result_tv;
            result_tv.set_object(result_obj);
            arr.set_array_idx((uint)i, result_tv);
        }
        remaining--;
    }

    if (remaining == 0) {
        TVal arr_val;
        arr_val.set_object(arr);
        promise_settle(promise, PROMISE_FULFILLED, &arr_val, ctx.heap);
        promise_trigger_reactions(promise, ctx.heap, ctx.vm);
    }

    ctx.result.set_object(promise);
}

// ============================================================================
// Promise.any(iterable) — ES2021 §25.6.4.3
// ============================================================================

fn void builtin_promise_any(BuiltinContext* ctx) {
    TVal iterable;
    iterable.set_undefined();
    if (ctx.argc >= 1) iterable = ctx.regs[ctx.base_reg];

    HObject*? prom_raw = promise_create(ctx.heap);
    if (catch err = prom_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* promise = prom_raw;

    usz len = 0;
    bool has_len = false;
    HObject* obj = null;

    if (iterable.is_object() && iterable.get_heapptr() != null) {
        obj = (HObject*)iterable.get_heapptr();
        HString* length_key = builtin_intern_string(ctx.heap, "length");
        if (try len_tv = obj.get_prop(length_key)) {
            if (len_tv.is_fastint() && len_tv.get_fastint() >= 0) {
                len = (usz)len_tv.get_fastint();
                has_len = true;
            }
        }
    }

    if (!has_len || len == 0) {
        TVal errors_tv;
        errors_tv.set_undefined();
        HString* msg = builtin_intern_string(ctx.heap, "All promises were rejected");
        TVal msg_tv;
        msg_tv.set_string(msg);

        HObject*? agg_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        if (try agg = agg_raw) {
            agg.prototype = ctx.heap.aggregate_err_proto;
            HString* errors_key = builtin_intern_string(ctx.heap, "errors");
            HObject*? empty_arr = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
            if (try arr = empty_arr) {
                arr.prototype = ctx.heap.array_proto;
                TVal arr_tv;
                arr_tv.set_object(arr);
                agg.put_prop(errors_key, arr_tv, hobject::PROP_FLAGS_WEC);
            }
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            agg.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
        }

        TVal agg_tv;
        agg_tv.set_undefined();
        if (try agg2 = agg_raw) {
            agg_tv.set_object(agg2);
        }
        promise_settle(promise, PROMISE_REJECTED, &agg_tv, ctx.heap);
        ctx.result.set_object(promise);
        return;
    }

    usz remaining = len;
    usz rejected_count = 0;
    HObject*? errors_arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    HObject* errors_arr = null;
    if (try arr = errors_arr_raw) {
        arr.prototype = ctx.heap.array_proto;
        errors_arr = arr;
    }

    for (usz i = 0; i < len; i++) {
        TVal elem = array_get_elem(obj, (uint)i, ctx.heap);

        if (elem.is_object() && elem.get_heapptr() != null) {
            HObject* elem_obj = (HObject*)elem.get_heapptr();
            if (elem_obj.flags.obj_class == hobject::ObjClass.PROMISE) {
                uint state = promise_get_state(elem_obj, PROMISE_PENDING);
                if (state == PROMISE_FULFILLED) {
                    TVal val = promise_get_result(elem_obj);
                    promise_settle(promise, PROMISE_FULFILLED, &val, ctx.heap);
                    promise_trigger_reactions(promise, ctx.heap, ctx.vm);
                    ctx.result.set_object(promise);
                    return;
                } else if (state == PROMISE_REJECTED) {
                    if (errors_arr != null) {
                        TVal val = promise_get_result(elem_obj);
                        errors_arr.set_array_idx((uint)(rejected_count), val);
                    }
                    rejected_count++;
                } else {
                    if (errors_arr != null) {
                        TVal undef;
                        undef.set_undefined();
                        errors_arr.set_array_idx((uint)(rejected_count), undef);
                    }
                    rejected_count++;
                }
                remaining--;
                continue;
            }
        }

        promise_settle(promise, PROMISE_FULFILLED, &elem, ctx.heap);
        promise_trigger_reactions(promise, ctx.heap, ctx.vm);
        ctx.result.set_object(promise);
        return;
    }

    if (remaining == 0) {
        TVal errors_val;
        if (errors_arr != null) {
            errors_val.set_object(errors_arr);
        } else {
            errors_val.set_undefined();
        }

        HObject*? agg_raw = ctx.heap.alloc_object(hobject::ObjClass.ERROR);
        TVal agg_tv;
        agg_tv.set_undefined();
        if (try agg = agg_raw) {
            agg.prototype = ctx.heap.aggregate_err_proto;
            HString* errors_key = builtin_intern_string(ctx.heap, "errors");
            agg.put_prop(errors_key, errors_val, hobject::PROP_FLAGS_WEC);
            HString* msg = builtin_intern_string(ctx.heap, "All promises were rejected");
            TVal msg_tv;
            msg_tv.set_string(msg);
            HString* msg_key = builtin_intern_string(ctx.heap, "message");
            agg.put_prop(msg_key, msg_tv, hobject::PROP_FLAGS_WC);
            agg_tv.set_object(agg);
        }
        promise_settle(promise, PROMISE_REJECTED, &agg_tv, ctx.heap);
        promise_trigger_reactions(promise, ctx.heap, ctx.vm);
    }

    ctx.result.set_object(promise);
}

// ============================================================================
// Promise.race(iterable) — ES6 §25.4.4.3
// ============================================================================

fn void builtin_promise_race(BuiltinContext* ctx) {
    TVal iterable;
    iterable.set_undefined();
    if (ctx.argc >= 1) iterable = ctx.regs[ctx.base_reg];

    // Get the constructor (this value) as C
    TVal this_ctor_val = ctx.regs[ctx.base_reg - 1];
    TVal resolve_fn;
    resolve_fn.set_undefined();
    HString* resolve_key = builtin_intern_string(ctx.heap, "resolve");
    if (resolve_key != null && this_ctor_val.is_object() && this_ctor_val.get_heapptr() != null) {
        HObject* ctor_obj = (HObject*)this_ctor_val.get_heapptr();
        TVal? rf = ctor_obj.get_prop_proto(resolve_key);
        if (catch err_rf = rf) {
        } else {
            resolve_fn = rf;
        }
    }

    HObject*? prom_raw = promise_create(ctx.heap);
    if (catch err = prom_raw) {
        ctx.result.set_undefined();
        return;
    }
    HObject* promise = prom_raw;

    if (!iterable.is_object() || iterable.get_heapptr() == null) {
        ctx.result.set_object(promise);
        return;
    }

    HObject* obj = (HObject*)iterable.get_heapptr();
    HString* length_key = builtin_intern_string(ctx.heap, "length");
    usz len = 0;
    bool has_len = false;
    if (try len_tv = obj.get_prop(length_key)) {
        if (len_tv.is_fastint() && len_tv.get_fastint() >= 0) {
            len = (usz)len_tv.get_fastint();
            has_len = true;
        }
    }

    if (!has_len || len == 0) {
        // Empty iterable: outer promise stays pending forever.
        ctx.result.set_object(promise);
        return;
    }

    // Shared state — remaining tracks how many elements are still pending.
    // rejected flag repurposed as "settled" flag for first-wins semantics.
    HObject*? arr_raw = ctx.heap.alloc_object(hobject::ObjClass.ARRAY);
    HObject* arr = null;
    if (try a = arr_raw) {
        a.prototype = ctx.heap.array_proto;
        arr = a;
    }
    HObject*? state_raw = promise_create_all_state(ctx.heap, promise, arr, len);
    if (catch err = state_raw) {
        ctx.result.set_object(promise);
        return;
    }
    HObject* state = state_raw;

    for (usz i = 0; i < len; i++) {
        TVal elem = array_get_elem(obj, (uint)i, ctx.heap);

        // Create per-element callbacks
        HObject*? fulfill_raw = promise_create_element_callback(ctx.heap, BUILTIN_PROMISE_RACE_RESOLVE_ELEMENT, state, i);
        HObject*? reject_raw = promise_create_element_callback(ctx.heap, BUILTIN_PROMISE_RACE_REJECT_ELEMENT, state, i);
        if (catch err_f = fulfill_raw) continue;
        if (catch err_r = reject_raw) continue;
        HObject* fulfill_fn = fulfill_raw;
        HObject* reject_fn = reject_raw;

        // Normalize via C.resolve(elem)
        if (resolve_fn.is_lightfunc() ||
            (resolve_fn.is_object() && resolve_fn.get_heapptr() != null &&
             ((HObject*)resolve_fn.get_heapptr()).is_callable())) {
            TVal[1] args;
            args[0] = elem;
            TVal resolved = ctx.heap.call_fn(ctx.vm, resolve_fn, &args[0], 1, this_ctor_val);
            if (resolved.is_object() && resolved.get_heapptr() != null) {
                HObject* res_obj = (HObject*)resolved.get_heapptr();
                if (res_obj.flags.obj_class == hobject::ObjClass.PROMISE) {
                    // Attach callbacks so the first to settle wins.
                    promise_attach_element_callbacks(res_obj, fulfill_fn, reject_fn, ctx.heap, ctx.vm);
                    continue;
                }
                // Non-Promise resolved value: fire fulfill callback immediately.
                TVal saved_this = ctx.regs[ctx.base_reg - 1];
                ctx.regs[ctx.base_reg - 1].set_object((void*)fulfill_fn);
                ctx.regs[ctx.base_reg] = resolved;
                ctx.argc = 1;
                builtin_promise_race_resolve_element(ctx);
                ctx.regs[ctx.base_reg - 1] = saved_this;
                return;
            }
            // resolved wasn't a recognized object — use as value, fire fulfill.
            TVal saved_this = ctx.regs[ctx.base_reg - 1];
            ctx.regs[ctx.base_reg - 1].set_object((void*)fulfill_fn);
            ctx.regs[ctx.base_reg] = resolved;
            ctx.argc = 1;
            builtin_promise_race_resolve_element(ctx);
            ctx.regs[ctx.base_reg - 1] = saved_this;
            return;
        }

        // No resolve_fn — use elem directly, fire fulfill.
        TVal saved_this = ctx.regs[ctx.base_reg - 1];
        ctx.regs[ctx.base_reg - 1].set_object((void*)fulfill_fn);
        ctx.regs[ctx.base_reg] = elem;
        ctx.argc = 1;
        builtin_promise_race_resolve_element(ctx);
        ctx.regs[ctx.base_reg - 1] = saved_this;
        return;
    }

    ctx.result.set_object(promise);
}

// ============================================================================
// Promise constructor registration
// ============================================================================

fn bool register_promise_constructor(EnvRecord* global_env, Heap* heap) {
    // Create Promise.prototype. Per ES6 §25.4.5 the prototype is an
    // ordinary object (ObjClass.OBJECT) — it must NOT carry the
    // [[PromiseState]] internal slot that Promise instances have, or
    // Promise.prototype.then would pass the IsPromise check.
    HObject*? proto_raw = heap.alloc_object(hobject::ObjClass.OBJECT);
    if (catch err = proto_raw) return false;
    HObject* proto = proto_raw;
    proto.prototype = heap.object_proto;
    heap.promise_proto = proto;

    if (!register_string_proto_method(proto, heap, "then",    BUILTIN_PROMISE_PROTO_THEN))    return false;
    if (!register_string_proto_method(proto, heap, "catch",   BUILTIN_PROMISE_PROTO_CATCH))   return false;
    if (!register_string_proto_method(proto, heap, "finally", BUILTIN_PROMISE_PROTO_FINALLY)) return false;

    HString* tag_key = ensure_tostringtag_symbol(heap);
    if (tag_key != null) {
        TVal tag_tv;
        tag_tv.set_string(builtin_intern_string(heap, "Promise"));
        proto.put_prop(tag_key, tag_tv, hobject::PROP_FLAGS_NWC);
    }

    HObject*? ctor_raw = heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = ctor_raw) return false;
    HObject* ctor = ctor_raw;
    (*ctor.extra_ptr()).func.builtin_fn_index = (int)BUILTIN_PROMISE;
    heap.promise_ctor = ctor;

    HString* constructor_key = (HString*)heap.strs[heap::BuiltinStr.CONSTRUCTOR];
    TVal constructor_tv;
    constructor_tv.set_object(ctor);
    proto.put_prop(constructor_key, constructor_tv, hobject::PROP_FLAGS_WC);

    HString* prototype_key = (HString*)heap.strs[heap::BuiltinStr.PROTOTYPE];
    TVal proto_tv;
    proto_tv.set_object(proto);
    PropFlags proto_pflags;
    proto_pflags.writable = false;
    proto_pflags.enumerable = false;
    proto_pflags.configurable = false;
    proto_pflags.is_accessor = false;
    ctor.put_prop(prototype_key, proto_tv, proto_pflags);

    HString* length_key = (HString*)heap.strs[heap::BuiltinStr.LENGTH];
    TVal length_tv;
    length_tv.set_fastint(1);
    ctor.put_prop(length_key, length_tv, hobject::PROP_FLAGS_NWC);

    HString* resolve_key = builtin_intern_string(heap, "resolve");
    TVal resolve_tv;
    resolve_tv.set_lightfunc((void*)(usz)BUILTIN_PROMISE_RESOLVE);
    ctor.put_prop(resolve_key, resolve_tv, hobject::PROP_FLAGS_WC);

    HString* reject_key = builtin_intern_string(heap, "reject");
    TVal reject_tv;
    reject_tv.set_lightfunc((void*)(usz)BUILTIN_PROMISE_REJECT);
    ctor.put_prop(reject_key, reject_tv, hobject::PROP_FLAGS_WC);

    HString* all_key = builtin_intern_string(heap, "all");
    TVal all_tv;
    all_tv.set_lightfunc((void*)(usz)BUILTIN_PROMISE_ALL);
    ctor.put_prop(all_key, all_tv, hobject::PROP_FLAGS_WC);

    HString* race_key = builtin_intern_string(heap, "race");
    TVal race_tv;
    race_tv.set_lightfunc((void*)(usz)BUILTIN_PROMISE_RACE);
    ctor.put_prop(race_key, race_tv, hobject::PROP_FLAGS_WC);

    HString* allsettled_key = builtin_intern_string(heap, "allSettled");
    TVal allsettled_tv;
    allsettled_tv.set_lightfunc((void*)(usz)BUILTIN_PROMISE_ALLSETTLED);
    ctor.put_prop(allsettled_key, allsettled_tv, hobject::PROP_FLAGS_WC);

    HString* any_key = builtin_intern_string(heap, "any");
    TVal any_tv;
    any_tv.set_lightfunc((void*)(usz)BUILTIN_PROMISE_ANY);
    ctor.put_prop(any_key, any_tv, hobject::PROP_FLAGS_WC);

    uint hash = heap.hash_string("Promise");
    HString* existing = heap.str_table_lookup("Promise", hash);
    HString* promise_key;
    if (existing != null) {
        promise_key = existing;
    } else {
        HString*? new_key = hstring::hstring_alloc(heap, "Promise", hash);
        if (catch err = new_key) return false;
        heap.str_table_insert(new_key);
        promise_key = new_key;
    }
    TVal promise_val;
    promise_val.set_object(ctor);
    set_func_ctor_name_length(ctor, heap, "Promise", 1);
    env::env_declare_nonenum(global_env, promise_key, promise_val);

    return true;
}

// ============================================================================
// Async/await resume and reject callbacks
// ============================================================================

/// Resume callback for async/await. Called as a microtask when a pending
/// Promise settles with a fulfilled value.  Re-enters the suspended async
/// function at the AWAIT point via the generator resume mechanism.
fn void builtin_async_resume(BuiltinContext* ctx) {
    // The GeneratorState was stashed in the function object's var_env field
    // by the AWAIT opcode handler.
    GeneratorState* gs = (GeneratorState*)(*ctx.callee_obj.extra_ptr()).func.var_env;
    if (gs == null) { ctx.result.set_undefined(); return; }

    // Set the resume value from the settled Promise result
    if (ctx.argc >= 1) {
        gs.resume_value = ctx.regs[ctx.base_reg];
    } else {
        gs.resume_value.set_undefined();
    }
    gs.resume_kind = NEXT;

    // Signal the VM to resume from the saved state
    ctx.heap.resume_gen = gs;

    // Build a callable TVal for the compiled function and invoke it directly.
    // vm_call_fn_impl Case 3 checks resume_gen and restores the saved PC/regs.
    HObject*? func_raw = ctx.heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = func_raw) {
        ctx.heap.resume_gen = null;
        ctx.result.set_undefined();
        return;
    }
    HObject* func_obj = func_raw;
    func_obj.flags.callable = true;
    (*func_obj.extra_ptr()).func.comp_func = (CompiledFunction*)gs.func;
    (*func_obj.extra_ptr()).func.var_env = (EnvRecord*)gs.var_env;
    (*func_obj.extra_ptr()).func.lex_env = (EnvRecord*)gs.lex_env;

    TVal func_tv;
    func_tv.set_object(func_obj);

    // Call the compiled function directly — vm_call_fn_impl will detect
    // resume_gen and restore the saved PC + registers.
    TVal resume_arg;
    resume_arg = gs.resume_value;
    TVal result = ctx.heap.call_fn(ctx.vm, func_tv, &resume_arg, 1, gs.this_binding);

    ctx.heap.resume_gen = null;

    // If the function completed (returned a value), store it in ctx.result
    // so the downstream promise gets settled.
    *ctx.result = result;
}

/// Reject callback for async/await. Called when a pending Promise rejects.
/// Injects the rejection reason as an exception into the suspended async function.
fn void builtin_async_reject(BuiltinContext* ctx) {
    GeneratorState* gs = (GeneratorState*)(*ctx.callee_obj.extra_ptr()).func.var_env;
    if (gs == null) { ctx.result.set_undefined(); return; }

    // Set the throw value from the rejection reason
    if (ctx.argc >= 1) {
        gs.throw_value = ctx.regs[ctx.base_reg];
    } else {
        gs.throw_value.set_undefined();
    }
    gs.resume_kind = THROW;

    // Signal the VM to resume from the saved state
    ctx.heap.resume_gen = gs;

    // Build a callable TVal for the compiled function and invoke it directly.
    // vm_call_fn_impl Case 3 checks resume_gen and restores the saved PC/regs.
    // LOAD_RESUME will inject the throw via vm_throw_value.
    HObject*? func_raw = ctx.heap.alloc_object(hobject::ObjClass.FUNCTION);
    if (catch err = func_raw) {
        ctx.heap.resume_gen = null;
        ctx.result.set_undefined();
        return;
    }
    HObject* func_obj = func_raw;
    func_obj.flags.callable = true;
    (*func_obj.extra_ptr()).func.comp_func = (CompiledFunction*)gs.func;
    (*func_obj.extra_ptr()).func.var_env = (EnvRecord*)gs.var_env;
    (*func_obj.extra_ptr()).func.lex_env = (EnvRecord*)gs.lex_env;

    TVal func_tv;
    func_tv.set_object(func_obj);

    // Call the compiled function directly — vm_call_fn_impl will detect
    // resume_gen and restore the saved PC + registers.
    TVal throw_arg;
    throw_arg = gs.throw_value;
    TVal result = ctx.heap.call_fn(ctx.vm, func_tv, &throw_arg, 1, gs.this_binding);

    ctx.heap.resume_gen = null;

    // If the function completed (returned a value — e.g. catch handled the
    // rejection), store it in ctx.result so the downstream promise gets settled.
    *ctx.result = result;
}

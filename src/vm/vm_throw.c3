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

// ============================================================================
// Catcher chain — helper functions
// ============================================================================

/// Walk the catcher chain and throw a value.
/// Searches the full activation chain, unwinding intermediate activations
/// when a catcher is found in a parent activation.
///
/// If `local_only` is true, only searches the current activation (does not
/// walk parent activations). Used by generator LOAD_RESUME THROW to determine
/// whether the generator itself has a catcher without finding the caller's.
///
/// Returns true if a catcher was found (execution continues after restart).
/// Returns false if no catcher was found anywhere in the call stack
/// (caller should return VM_ERROR~).
fn bool vm_throw_value(Vm* vm, TVal thrown_val, Activation* act,
                       Instruction** curr_pc, bool* needs_restart,
                       bool local_only = false) {
    // Walk through current and parent activations
    Activation* search_act = act;
    for (;;) {
        Catcher* cat = (Catcher*)search_act.cat;
        while (cat != null) {
            if (cat.flags & CATCHER_FLAG_CATCH_ENABLED) {
                // If this is not the innermost catcher (i.e., we skipped
                // catchers with IN_FINALLY), pop the skipped catchers so
                // that the CATCH handler reads from the correct catcher.
                if (cat != (Catcher*)search_act.cat) {
                    // Pop catchers from the chain up to (but not including) this one.
                    while ((Catcher*)search_act.cat != cat) {
                        Catcher* skip = (Catcher*)search_act.cat;
                        search_act.cat = (void*)skip.parent;
                        vm.heap.free_func(vm.heap.heap_udata, skip);
                    }
                }
                vm.heap.tval_copy_ref(&cat.thrown_val, &thrown_val);
                cat.flags &= ~CATCHER_FLAG_CATCH_ENABLED;
                *curr_pc = cat.catch_pc;
                search_act.curr_pc = *curr_pc;
                *needs_restart = true;

                // If we found the catcher in a parent activation, unwind
                // intermediate activations so the VM resumes at the right level.
                if (search_act != act) {
                    // Pop all activations down to the one with the catcher
                    while (vm.activation_count > 0
                           && &vm.activations[vm.activation_count - 1] != search_act) {
                        vm.activation_count--;
                    }
                    // Restore the valstack_bottom for the target activation
                    vm.valstack_bottom = search_act.bottom;
                    // Restore valstack_top to match the target function's nregs
                    if (search_act.func != null) {
                        CompiledFunction* target_func = (CompiledFunction*)search_act.func;
                        uint target_nregs = target_func.num_regs;
                        vm.valstack_top = search_act.bottom + target_nregs;
                    }
                }
                return true;
            }
            if ((cat.flags & CATCHER_FLAG_FINALLY_ENABLED) != 0
                && (cat.flags & CATCHER_FLAG_IN_FINALLY) == 0) {
                // Skip catchers whose finally block is currently being executed
                // (CATCHER_FLAG_IN_FINALLY is set).  Without this, a throw
                // inside a finally block would re-enter the same finally block,
                // causing an infinite loop.
                vm.heap.tval_copy_ref(&cat.thrown_val, &thrown_val);
                *curr_pc = cat.finally_pc;
                search_act.curr_pc = *curr_pc;
                *needs_restart = true;

                if (search_act != act) {
                    while (vm.activation_count > 0
                           && &vm.activations[vm.activation_count - 1] != search_act) {
                        vm.activation_count--;
                    }
                    vm.valstack_bottom = search_act.bottom;
                    if (search_act.func != null) {
                        CompiledFunction* target_func = (CompiledFunction*)search_act.func;
                        uint target_nregs = target_func.num_regs;
                        vm.valstack_top = search_act.bottom + target_nregs;
                    }
                }
                return true;
            }
            // If this catcher has IN_FINALLY, it means we're inside its finally
            // block and a throw occurred.  Pop it and continue to the next handler.
            if (cat.flags & CATCHER_FLAG_IN_FINALLY) {
                Catcher* next = (Catcher*)cat.parent;
                search_act.cat = (void*)next;
                vm.heap.free_func(vm.heap.heap_udata, cat);
                cat = next;
                continue;
            }
            cat = cat.parent;
        }
        if (local_only) break;  // Don't walk parent activations
        search_act = search_act.parent;
        if (search_act == null) break;
    }
    return false;
}

/// Record an uncaught exception in the VM and return the VM_ERROR~ sentinel.
///
/// When an opcode allocates an error and calls vm_throw_value but no catcher
/// is found, the VM must surface the error to the embedder (CLI, batch
/// runner, host app) rather than silently swallowing it. This helper mirrors
/// the THROW opcode's uncaught-exception handling (vm.c3:8098-8107) so every
/// opcode that can fail vm_throw_value behaves consistently.
fn TVal? vm_uncaught_error(Vm* vm, TVal* err_val) {
    vm.has_error = true;
    vm.heap.has_error = true;
    vm.heap.tval_copy_ref(&vm.heap.error_value, err_val);
    vm.heap.tval_copy_ref(&vm.return_val, err_val);
    return VM_ERROR~;
}

/// Helper to get index from valstack base to a pointer
fn uint byte_offset(TVal* base, TVal* ptr) @inline {
    return (uint)(ptr - base);
}

/// Helper to get TVal* from valstack base and index.
fn TVal* ptr_from_byteoff(TVal* base, uint idx) @inline {
    return base + idx;
}

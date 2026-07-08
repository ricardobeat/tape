module duktape::compiler;

import duktape::types;
import duktape::lexer;
import duktape::bytecode;
import duktape::hstring;
import duktape::hobject;
import duktape::heap;
import libc;
import std::io;

// ============================================================================
// Register allocation
// ============================================================================

/// Allocate the next free register.
fn ushort CompilerContext.alloc_reg(&self) {
    ushort reg = self.next_reg;
    self.next_reg++;
    if (self.next_reg > self.max_reg) {
        self.max_reg = self.next_reg;
    }
    if (self.next_reg > MAX_REGISTERS) {
        io::printfn("COMPILE ERROR: register limit exceeded (next_reg=%d, max %d)", self.next_reg, MAX_REGISTERS - 1);
        libc::abort();
    }
    return reg;
}

/// Allocate multiple consecutive registers, returning the first.
fn ushort CompilerContext.alloc_regs(&self, ushort count) {
    ushort first = self.next_reg;
    self.next_reg += count;
    if (self.next_reg > self.max_reg) {
        self.max_reg = self.next_reg;
    }
    if (self.next_reg > MAX_REGISTERS) {
        io::printfn("COMPILE ERROR: register limit exceeded (next_reg=%d, max %d)", self.next_reg, MAX_REGISTERS - 1);
        libc::abort();
    }
    return first;
}

/// Free a register (only frees if it's the top of the stack).
fn void CompilerContext.free_reg(&self, ushort reg) {
    if (reg + 1 == self.next_reg) {
        self.next_reg--;
    }
}

/// Free registers back to a saved point.
fn void CompilerContext.free_regs_to(&self, ushort saved) {
    if (self.next_reg > saved) {
        self.next_reg = saved;
    }
}

/// Reserve the callee-frame region for an upcoming CALL whose callee value
/// sits at `callee_reg` (func at callee_reg, `this` at callee_reg+1, then
/// `nargs` argument registers at callee_reg+2 .. callee_reg+1+nargs).
///
/// The VM uses a sliding-window register model: on CALL it overlays the
/// callee's frame directly onto the caller's register array starting at
/// callee_reg+2 (see src/vm/vm_calls.c3 and plan 042). After this call
/// returns, the allocator's next_reg is at or above the first register past
/// the argument area, so no register the allocator later hands out can land
/// inside the callee frame the VM will overlay.
///
/// This is the single source of truth for that reservation. Every CALL
/// emission site must funnel through here instead of open-coding a next_reg
/// bump past `callee_reg + 2 + nargs`.
fn void CompilerContext.reserve_call_frame(&self, ushort callee_reg, ushort nargs) {
    ushort frame_top = callee_reg + 2 + nargs;   // first register past the args
    if (self.next_reg < frame_top) {
        self.next_reg = frame_top;
    }
    if (self.next_reg > self.max_reg) {
        self.max_reg = self.next_reg;
    }
}

/// Allocate a register intended to hold state that must survive one or more
/// CALLs (e.g. an accumulator built across a loop that calls `.next()`/`.push()`
/// each iteration).
///
/// In the sliding-window model a register survives a CALL iff its number is
/// below the `callee_reg` of every call made while it is live. This allocator
/// hands registers out in ascending order, so allocating such state *before*
/// any per-iteration call setup places it below those callee frames. This is a
/// thin, intent-documenting wrapper over `alloc_reg`; call it (rather than
/// `alloc_reg`) for cross-call live state so the requirement is greppable and
/// the ordering constraint is explicit at the call site. See plan 042/043.
fn ushort CompilerContext.alloc_persistent_reg(&self) {
    return self.alloc_reg();
}

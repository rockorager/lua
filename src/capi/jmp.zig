//! A protected call into C and the jump that aborts it: setjmp and
//! longjmp fused into a call, for x86-64 System V.
//!
//! `call(regs, f, a0, a1, a2)` saves the callee-saved registers, the
//! stack pointer, and its return address in `regs`, then calls
//! `f(a0, a1, a2)` and returns its `int` result zero-extended. `jump(regs)`
//! restores what `call` saved and resumes at its return address with
//! `aborted` in rax. To the Zig caller either way is an ordinary return
//! from an ordinary call, so nothing returns twice: no local can be stale
//! and the optimizer needs no `returns_twice`. C's setjmp cannot promise
//! that, which is why there is none here (docs/slop/c-api.md).
//!
//! The signal mask, the x87 control word, and MXCSR are not saved; C code
//! does not change them between a call and its error, as with glibc's
//! `_setjmp`.

const builtin = @import("builtin");

comptime {
    if (builtin.cpu.arch != .x86_64 or builtin.os.tag == .windows)
        @compileError("the C API's protected calls are written for x86-64 System V only");
}

/// What `call` saves: rbx, rbp, r12 to r15, the stack pointer after
/// `call` returns, and its return address.
pub const Regs = extern struct {
    gp: [6]usize = undefined,
    sp: usize = undefined,
    ip: usize = undefined,
};

/// `call`'s result when `jump` aborted the call. A C function's `int`
/// zero-extends below 2^32, so the two never meet.
pub const aborted: u64 = ~@as(u64, 0);

/// Calls `f(a0, a1, a2)`; returns its `int` result as an unsigned 32-bit
/// value, or `aborted` when a `jump` to `regs` ended the call.
pub inline fn call(regs: *Regs, f: *const anyopaque, a0: usize, a1: usize, a2: usize) u64 {
    const p: *const fn (*Regs, *const anyopaque, usize, usize, usize) callconv(.c) u64 = @ptrCast(&callNaked);
    return p(regs, f, a0, a1, a2);
}

/// Ends the `call` that saved `regs`, which returns `aborted`.
pub inline fn jump(regs: *const Regs) noreturn {
    const p: *const fn (*const Regs) callconv(.c) noreturn = @ptrCast(&jumpNaked);
    p(regs);
}

// Naked functions rather than module-level assembly, which Zig's own
// x86-64 backend (Debug builds) does not emit.
fn callNaked() callconv(.naked) void {
    asm volatile (
        \\  movq %%rbx, 0(%%rdi)
        \\  movq %%rbp, 8(%%rdi)
        \\  movq %%r12, 16(%%rdi)
        \\  movq %%r13, 24(%%rdi)
        \\  movq %%r14, 32(%%rdi)
        \\  movq %%r15, 40(%%rdi)
        \\  leaq 8(%%rsp), %%rax
        \\  movq %%rax, 48(%%rdi)
        \\  movq (%%rsp), %%rax
        \\  movq %%rax, 56(%%rdi)
        \\  movq %%rsi, %%rax
        \\  movq %%rdx, %%rdi
        \\  movq %%rcx, %%rsi
        \\  movq %%r8, %%rdx
        \\  subq $8, %%rsp
        \\  callq *%%rax
        \\  addq $8, %%rsp
        \\  movl %%eax, %%eax
        \\  retq
    );
}

fn jumpNaked() callconv(.naked) void {
    asm volatile (
        \\  movq 0(%%rdi), %%rbx
        \\  movq 8(%%rdi), %%rbp
        \\  movq 16(%%rdi), %%r12
        \\  movq 24(%%rdi), %%r13
        \\  movq 32(%%rdi), %%r14
        \\  movq 40(%%rdi), %%r15
        \\  movq 48(%%rdi), %%rsp
        \\  movq $-1, %%rax
        \\  jmpq *56(%%rdi)
    );
}

//! A protected call into C and the jump that aborts it: setjmp and
//! longjmp fused into a call, for x86-64 System V and for aarch64 (Linux's
//! AAPCS64 and Apple's arm64 ABI, which agree on everything used here).
//!
//! `call(regs, f, a0, a1, a2)` saves the callee-saved registers, the
//! stack pointer, and its return address in `regs`, then calls
//! `f(a0, a1, a2)` and returns its `int` result zero-extended. `jump(regs)`
//! restores what `call` saved and resumes at its return address with
//! `aborted` as the result. To the Zig caller either way is an ordinary
//! return from an ordinary call, so nothing returns twice: no local can be
//! stale and the optimizer needs no `returns_twice`. C's setjmp cannot
//! promise that, which is why there is none here (docs/slop/c-api.md).
//!
//! The signal mask and the floating-point control and status registers
//! (x87 control word and MXCSR; FPCR and FPSR) are not saved; C code does
//! not change them between a call and its error, as with glibc's
//! `_setjmp`.

const std = @import("std");
const builtin = @import("builtin");

const arch = builtin.cpu.arch;

comptime {
    const ok = switch (arch) {
        .x86_64 => builtin.os.tag != .windows,
        .aarch64 => builtin.os.tag == .linux or builtin.os.tag.isDarwin(),
        else => false,
    };
    if (!ok) @compileError("the C API's protected calls are written for x86-64 System V " ++
        "and aarch64 Linux and Apple only");
}

/// What `call` saves. x86-64: rbx, rbp, r12 to r15, the stack pointer
/// after `call` returns, and its return address. aarch64: x19 to x28, the
/// frame pointer x29, the return address x30, the stack pointer at entry,
/// and d8 to d15 (the low halves of v8 to v15, which AAPCS64 has the
/// callee keep).
pub const Regs = switch (arch) {
    .x86_64 => extern struct {
        gp: [6]usize = undefined,
        sp: usize = undefined,
        ip: usize = undefined,
    },
    else => extern struct {
        gp: [12]usize = undefined,
        sp: usize = undefined,
        fp: [8]u64 = undefined,
    },
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
    switch (arch) {
        .x86_64 => asm volatile (
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
        ),
        // x0 = regs, x1 = f, x2..x4 = its arguments. The frame record
        // pushed before the call keeps x29 a valid chain, as Apple's ABI
        // requires at every call and unwinders expect; x18, the platform
        // register on Apple, is not touched.
        else => asm volatile (
            \\  stp x19, x20, [x0, #0]
            \\  stp x21, x22, [x0, #16]
            \\  stp x23, x24, [x0, #32]
            \\  stp x25, x26, [x0, #48]
            \\  stp x27, x28, [x0, #64]
            \\  stp x29, x30, [x0, #80]
            \\  mov x9, sp
            \\  str x9, [x0, #96]
            \\  stp d8, d9, [x0, #104]
            \\  stp d10, d11, [x0, #120]
            \\  stp d12, d13, [x0, #136]
            \\  stp d14, d15, [x0, #152]
            \\  stp x29, x30, [sp, #-16]!
            \\  mov x29, sp
            \\  mov x9, x1
            \\  mov x0, x2
            \\  mov x1, x3
            \\  mov x2, x4
            \\  blr x9
            \\  ldp x29, x30, [sp], #16
            \\  mov w0, w0
            \\  ret
        ),
    }
}

fn jumpNaked() callconv(.naked) void {
    switch (arch) {
        .x86_64 => asm volatile (
            \\  movq 0(%%rdi), %%rbx
            \\  movq 8(%%rdi), %%rbp
            \\  movq 16(%%rdi), %%r12
            \\  movq 24(%%rdi), %%r13
            \\  movq 32(%%rdi), %%r14
            \\  movq 40(%%rdi), %%r15
            \\  movq 48(%%rdi), %%rsp
            \\  movq $-1, %%rax
            \\  jmpq *56(%%rdi)
        ),
        // Back to `call`'s caller with `call`'s own registers and stack,
        // as its `ret` would.
        else => asm volatile (
            \\  ldp x19, x20, [x0, #0]
            \\  ldp x21, x22, [x0, #16]
            \\  ldp x23, x24, [x0, #32]
            \\  ldp x25, x26, [x0, #48]
            \\  ldp x27, x28, [x0, #64]
            \\  ldp x29, x30, [x0, #80]
            \\  ldr x9, [x0, #96]
            \\  mov sp, x9
            \\  ldp d8, d9, [x0, #104]
            \\  ldp d10, d11, [x0, #120]
            \\  ldp d12, d13, [x0, #136]
            \\  ldp d14, d15, [x0, #152]
            \\  mov x0, #-1
            \\  ret
        ),
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// The `Regs` the clobbering function jumps to.
var test_regs: Regs = .{};

/// Overwrites every callee-saved register, then jumps to `test_regs`
/// without returning, so only `jump` can give the caller its registers
/// back.
fn clobberAndJump(_: usize, _: usize, _: usize) callconv(.c) c_int {
    switch (arch) {
        .x86_64 => asm volatile (
            \\  movq $-1, %%rbx
            \\  movq $-1, %%r12
            \\  movq $-1, %%r13
            \\  movq $-1, %%r14
            \\  movq $-1, %%r15
            ::: .{ .rbx = true, .r12 = true, .r13 = true, .r14 = true, .r15 = true }),
        else => asm volatile (
            \\  mov x9, #-1
            \\  mov x19, x9
            \\  mov x20, x9
            \\  mov x21, x9
            \\  mov x22, x9
            \\  mov x23, x9
            \\  mov x24, x9
            \\  mov x25, x9
            \\  mov x26, x9
            \\  mov x27, x9
            \\  mov x28, x9
            \\  fmov d8, x9
            \\  fmov d9, x9
            \\  fmov d10, x9
            \\  fmov d11, x9
            \\  fmov d12, x9
            \\  fmov d13, x9
            \\  fmov d14, x9
            \\  fmov d15, x9
            ::: .{
                .x9 = true,
                .x19 = true,
                .x20 = true,
                .x21 = true,
                .x22 = true,
                .x23 = true,
                .x24 = true,
                .x25 = true,
                .x26 = true,
                .x27 = true,
                .x28 = true,
                .d8 = true,
                .d9 = true,
                .d10 = true,
                .d11 = true,
                .d12 = true,
                .d13 = true,
                .d14 = true,
                .d15 = true,
            }),
    }
    jump(&test_regs);
}

/// `probe(out, &test_regs, clobberAndJump, callNaked)` puts `100 + n` in
/// callee-saved register n, makes the protected call
/// `call(&test_regs, clobberAndJump, 0, 0, 0)`, and writes the registers
/// and the call's result to `out`: rbx, rbp, r12 to r15, the result; or
/// x19 to x28, d8 to d15, the result.
fn probe() callconv(.naked) void {
    switch (arch) {
        .x86_64 => asm volatile (
            \\  pushq %%rbx
            \\  pushq %%rbp
            \\  pushq %%r12
            \\  pushq %%r13
            \\  pushq %%r14
            \\  pushq %%r15
            \\  pushq %%rdi
            \\  movq $100, %%rbx
            \\  movq $101, %%rbp
            \\  movq $102, %%r12
            \\  movq $103, %%r13
            \\  movq $104, %%r14
            \\  movq $105, %%r15
            \\  movq %%rcx, %%rax
            \\  movq %%rsi, %%rdi
            \\  movq %%rdx, %%rsi
            \\  xorl %%edx, %%edx
            \\  xorl %%ecx, %%ecx
            \\  xorl %%r8d, %%r8d
            \\  callq *%%rax
            \\  popq %%rdi
            \\  movq %%rbx, 0(%%rdi)
            \\  movq %%rbp, 8(%%rdi)
            \\  movq %%r12, 16(%%rdi)
            \\  movq %%r13, 24(%%rdi)
            \\  movq %%r14, 32(%%rdi)
            \\  movq %%r15, 40(%%rdi)
            \\  movq %%rax, 48(%%rdi)
            \\  popq %%r15
            \\  popq %%r14
            \\  popq %%r13
            \\  popq %%r12
            \\  popq %%rbp
            \\  popq %%rbx
            \\  retq
        ),
        else => asm volatile (
            \\  stp x29, x30, [sp, #-16]!
            \\  mov x29, sp
            \\  sub sp, sp, #160
            \\  stp x19, x20, [sp, #0]
            \\  stp x21, x22, [sp, #16]
            \\  stp x23, x24, [sp, #32]
            \\  stp x25, x26, [sp, #48]
            \\  stp x27, x28, [sp, #64]
            \\  stp d8, d9, [sp, #80]
            \\  stp d10, d11, [sp, #96]
            \\  stp d12, d13, [sp, #112]
            \\  stp d14, d15, [sp, #128]
            \\  str x0, [sp, #144]
            \\  mov x19, #100
            \\  mov x20, #101
            \\  mov x21, #102
            \\  mov x22, #103
            \\  mov x23, #104
            \\  mov x24, #105
            \\  mov x25, #106
            \\  mov x26, #107
            \\  mov x27, #108
            \\  mov x28, #109
            \\  mov x10, #110
            \\  fmov d8, x10
            \\  mov x10, #111
            \\  fmov d9, x10
            \\  mov x10, #112
            \\  fmov d10, x10
            \\  mov x10, #113
            \\  fmov d11, x10
            \\  mov x10, #114
            \\  fmov d12, x10
            \\  mov x10, #115
            \\  fmov d13, x10
            \\  mov x10, #116
            \\  fmov d14, x10
            \\  mov x10, #117
            \\  fmov d15, x10
            \\  mov x9, x3
            \\  mov x0, x1
            \\  mov x1, x2
            \\  mov x2, #0
            \\  mov x3, #0
            \\  mov x4, #0
            \\  blr x9
            \\  ldr x9, [sp, #144]
            \\  stp x19, x20, [x9, #0]
            \\  stp x21, x22, [x9, #16]
            \\  stp x23, x24, [x9, #32]
            \\  stp x25, x26, [x9, #48]
            \\  stp x27, x28, [x9, #64]
            \\  stp d8, d9, [x9, #80]
            \\  stp d10, d11, [x9, #96]
            \\  stp d12, d13, [x9, #112]
            \\  stp d14, d15, [x9, #128]
            \\  str x0, [x9, #144]
            \\  ldp x19, x20, [sp, #0]
            \\  ldp x21, x22, [sp, #16]
            \\  ldp x23, x24, [sp, #32]
            \\  ldp x25, x26, [sp, #48]
            \\  ldp x27, x28, [sp, #64]
            \\  ldp d8, d9, [sp, #80]
            \\  ldp d10, d11, [sp, #96]
            \\  ldp d12, d13, [sp, #112]
            \\  ldp d14, d15, [sp, #128]
            \\  add sp, sp, #160
            \\  ldp x29, x30, [sp], #16
            \\  ret
        ),
    }
}

test "a jump gives the protected call's caller back its registers" {
    const n = switch (arch) {
        .x86_64 => 6,
        else => 18,
    };
    var out: [n + 1]u64 = @splat(0);
    const P = fn (*[n + 1]u64, *Regs, *const anyopaque, *const anyopaque) callconv(.c) void;
    const p: *const P = @ptrCast(&probe);
    p(&out, &test_regs, @ptrCast(&clobberAndJump), @ptrCast(&callNaked));
    for (out[0..n], 0..) |v, i| try std.testing.expectEqual(100 + i, v);
    try std.testing.expectEqual(aborted, out[n]);
}

//! A protected call into C and the jump that aborts it: setjmp and
//! longjmp fused into a call, for x86-64 System V and for aarch64 (Linux's
//! AAPCS64 and Apple's arm64 ABI, which agree on everything used here).
//!
//! `call(regs, f, a0, a1, a2)` is inline assembly in its caller: it notes
//! the stack pointer and the frame pointer in `regs` (and on aarch64 where
//! to resume), calls `f(a0, a1, a2)`, and gives its `int` result
//! zero-extended. `jump(regs)` puts back the stack and frame pointers and
//! resumes right after that call with `aborted` as the result. The
//! assembly tells the compiler that the call clobbers every register but
//! the frame and stack pointers, callee-saved ones included, so the
//! caller keeps nothing in them across it, and nothing needs restoring
//! but those two: two stores a call, where saving the callee-saved
//! registers took eight and a function of its own
//! (docs/slop/results/capi-perf-20261101.md). To the Zig caller either
//! way is one pass through one piece of assembly, so nothing returns
//! twice: no local can be stale and the optimizer needs no
//! `returns_twice`. C's setjmp cannot promise that, which is why there is
//! none here (docs/slop/c-api.md).
//!
//! The jump is sound because between a protected call and its jump sit
//! only C frames and the one API function that throws (`unwind.zig`
//! checks it): the return address the call pushed (x86-64) is still in
//! place, as the C function has not returned.
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

/// What `call` notes: the stack pointer and the frame pointer (rbp, x29)
/// at the call, and on aarch64 where to resume, as `bl` keeps the return
/// address in a register.
pub const Regs = switch (arch) {
    .x86_64 => extern struct {
        sp: usize = undefined,
        fp: usize = undefined,
    },
    else => extern struct {
        sp: usize = undefined,
        fp: usize = undefined,
        ip: usize = undefined,
    },
};

/// `call`'s result when `jump` aborted the call. A C function's `int`
/// zero-extends below 2^32, so the two never meet.
pub const aborted: u64 = ~@as(u64, 0);

/// Calls `f(a0, a1, a2)`; returns its `int` result as an unsigned 32-bit
/// value, or `aborted` when a `jump` to `regs` ended the call.
///
/// The compiler does not see the call, so a function holding one must
/// keep nothing below the stack pointer: C-API builds have no red zone
/// (`build.zig`). x86-64: the call is 16-byte aligned whatever the
/// caller's frame, the stack pointer before it stays in r12 (a C
/// function keeps it, and `jump` sets it), and the result's zero
/// extension is the two bytes `jump` skips. aarch64 keeps the stack
/// pointer 16-byte aligned always; `jump` resumes at the label.
pub inline fn call(regs: *Regs, f: *const anyopaque, a0: usize, a1: usize, a2: usize) u64 {
    var r: u64 = undefined;
    var d0: usize = undefined;
    var d1: usize = undefined;
    var d2: usize = undefined;
    var d3: usize = undefined;
    switch (arch) {
        .x86_64 => asm volatile (
            \\  movq %%rsp, %%r12
            \\  movq %%rsp, 0(%%rcx)
            \\  movq %%rbp, 8(%%rcx)
            \\  andq $-16, %%rsp
            \\  callq *%%rax
            \\  movl %%eax, %%eax
            \\  movq %%r12, %%rsp
            : [r] "={rax}" (r),
              [d0] "={rdi}" (d0),
              [d1] "={rsi}" (d1),
              [d2] "={rdx}" (d2),
              [d3] "={rcx}" (d3),
            : [f] "{rax}" (f),
              [a0] "{rdi}" (a0),
              [a1] "{rsi}" (a1),
              [a2] "{rdx}" (a2),
              [regs] "{rcx}" (regs),
            : x86_clobbers),
        // The resume address is the instruction after the zero
        // extension.
        else => asm volatile (
            \\  mov x16, sp
            \\  str x16, [x3, #0]
            \\  str x29, [x3, #8]
            \\  adr x17, 1f
            \\  str x17, [x3, #16]
            \\  blr x4
            \\  mov w0, w0
            \\1:
            : [r] "={x0}" (r),
              [d0] "={x1}" (d0),
              [d1] "={x2}" (d1),
              [d2] "={x3}" (d2),
              [d3] "={x4}" (d3),
            : [a0] "{x0}" (a0),
              [a1] "{x1}" (a1),
              [a2] "{x2}" (a2),
              [regs] "{x3}" (regs),
              [f] "{x4}" (f),
            : aarch64_clobbers),
    }
    return r;
}

/// Every register a C call may change or the call sequence uses, but the
/// operands, the frame pointer, and the stack pointer. LLVM drops a
/// clobber whose register class the target lacks, so each vector register
/// is named at every width: without AVX-512 the zmm names do nothing and
/// the xmm ones carry the clobber. The AVX-512 mask registers and the x87
/// stack have no names here; the code around a call holds nothing in
/// them.
const x86_clobbers: std.lang.assembly.Clobbers = if (arch == .x86_64) .{
    .memory = true,
    .cc = true,
    .dirflag = true,
    .fpsr = true,
    .rbx = true,
    .r8 = true,
    .r9 = true,
    .r10 = true,
    .r11 = true,
    .r12 = true,
    .r13 = true,
    .r14 = true,
    .r15 = true,
    .xmm0 = true,
    .xmm1 = true,
    .xmm2 = true,
    .xmm3 = true,
    .xmm4 = true,
    .xmm5 = true,
    .xmm6 = true,
    .xmm7 = true,
    .xmm8 = true,
    .xmm9 = true,
    .xmm10 = true,
    .xmm11 = true,
    .xmm12 = true,
    .xmm13 = true,
    .xmm14 = true,
    .xmm15 = true,
    .ymm0 = true,
    .ymm1 = true,
    .ymm2 = true,
    .ymm3 = true,
    .ymm4 = true,
    .ymm5 = true,
    .ymm6 = true,
    .ymm7 = true,
    .ymm8 = true,
    .ymm9 = true,
    .ymm10 = true,
    .ymm11 = true,
    .ymm12 = true,
    .ymm13 = true,
    .ymm14 = true,
    .ymm15 = true,
    .zmm0 = true,
    .zmm1 = true,
    .zmm2 = true,
    .zmm3 = true,
    .zmm4 = true,
    .zmm5 = true,
    .zmm6 = true,
    .zmm7 = true,
    .zmm8 = true,
    .zmm9 = true,
    .zmm10 = true,
    .zmm11 = true,
    .zmm12 = true,
    .zmm13 = true,
    .zmm14 = true,
    .zmm15 = true,
    .zmm16 = true,
    .zmm17 = true,
    .zmm18 = true,
    .zmm19 = true,
    .zmm20 = true,
    .zmm21 = true,
    .zmm22 = true,
    .zmm23 = true,
    .zmm24 = true,
    .zmm25 = true,
    .zmm26 = true,
    .zmm27 = true,
    .zmm28 = true,
    .zmm29 = true,
    .zmm30 = true,
    .zmm31 = true,
} else undefined;

/// x18 is Apple's platform register, which nothing may touch, and a
/// temporary on Linux. The v names cover the whole vector registers.
const aarch64_clobbers: std.lang.assembly.Clobbers = if (arch == .aarch64) .{
    .memory = true,
    .nzcv = true,
    .fpsr = true,
    .x5 = true,
    .x6 = true,
    .x7 = true,
    .x8 = true,
    .x9 = true,
    .x10 = true,
    .x11 = true,
    .x12 = true,
    .x13 = true,
    .x14 = true,
    .x15 = true,
    .x16 = true,
    .x17 = true,
    .x18 = !builtin.os.tag.isDarwin(),
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
    // x30 by LLVM's name for it; `.x30` alone does not reach it.
    .lr = true,
    .v0 = true,
    .v1 = true,
    .v2 = true,
    .v3 = true,
    .v4 = true,
    .v5 = true,
    .v6 = true,
    .v7 = true,
    .v8 = true,
    .v9 = true,
    .v10 = true,
    .v11 = true,
    .v12 = true,
    .v13 = true,
    .v14 = true,
    .v15 = true,
    .v16 = true,
    .v17 = true,
    .v18 = true,
    .v19 = true,
    .v20 = true,
    .v21 = true,
    .v22 = true,
    .v23 = true,
    .v24 = true,
    .v25 = true,
    .v26 = true,
    .v27 = true,
    .v28 = true,
    .v29 = true,
    .v30 = true,
    .v31 = true,
} else undefined;

/// Ends the `call` that noted `regs`, which returns `aborted`.
pub inline fn jump(regs: *const Regs) noreturn {
    const p: *const fn (*const Regs) callconv(.c) noreturn = @ptrCast(&jumpNaked);
    p(regs);
}

// A naked function rather than module-level assembly, which Zig's own
// x86-64 backend (Debug builds) does not emit.
fn jumpNaked() callconv(.naked) void {
    switch (arch) {
        // The stack pointer `call` aligned its call at, then the return
        // address that call pushed, two bytes past which is the end of
        // `call`'s zero extension. The stack pointer moves up to that
        // address's slot only after it is read.
        .x86_64 => asm volatile (
            \\  movq 8(%%rdi), %%rbp
            \\  movq 0(%%rdi), %%r12
            \\  movq %%r12, %%rax
            \\  andq $-16, %%rax
            \\  movq -8(%%rax), %%rcx
            \\  movq %%rax, %%rsp
            \\  addq $2, %%rcx
            \\  movq $-1, %%rax
            \\  jmpq *%%rcx
        ),
        else => asm volatile (
            \\  ldr x29, [x0, #8]
            \\  ldr x16, [x0, #0]
            \\  mov sp, x16
            \\  ldr x17, [x0, #16]
            \\  mov x0, #-1
            \\  br x17
        ),
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// The `Regs` the clobbering function jumps to.
var test_regs: Regs = .{};

/// Overwrites every callee-saved register and the frame pointer, then
/// jumps to `regs` (its first argument) through `j` (its second,
/// `jumpNaked`) without returning, so only `jump` can give the caller its
/// frame back.
fn clobberAndJump() callconv(.naked) void {
    switch (arch) {
        .x86_64 => asm volatile (
            \\  movq %%rsi, %%rax
            \\  movq $-1, %%rbx
            \\  movq $-1, %%rbp
            \\  movq $-1, %%r12
            \\  movq $-1, %%r13
            \\  movq $-1, %%r14
            \\  movq $-1, %%r15
            \\  movq $-1, %%rsi
            \\  subq $256, %%rsp
            \\  jmpq *%%rax
        ),
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
            \\  mov x29, x9
            \\  fmov d8, x9
            \\  fmov d9, x9
            \\  fmov d10, x9
            \\  fmov d11, x9
            \\  fmov d12, x9
            \\  fmov d13, x9
            \\  fmov d14, x9
            \\  fmov d15, x9
            \\  sub sp, sp, #256
            \\  br x1
        ),
    }
}

fn returnMinusOne(_: usize, _: usize, _: usize) callconv(.c) c_int {
    return -1;
}

/// Values live across a protected call: more than there are registers,
/// so the compiler keeps some in the frame and, where it can, one in the
/// frame pointer, which only `jump` can give back.
noinline fn liveAcross(seed: u64, f: *const anyopaque) [24]u64 {
    var v: [24]u64 = undefined;
    inline for (&v, 0..) |*x, i| x.* = seed *% (i + 3) +% i;
    const r = call(&test_regs, f, @intFromPtr(&test_regs), @intFromPtr(&jumpNaked), 0);
    var out: [24]u64 = undefined;
    inline for (&out, v) |*o, x| o.* = x +% r;
    return out;
}

test "a jump gives the protected call's caller back its frame and values" {
    var seed: u64 = 0x1234_5678_9abc;
    std.mem.doNotOptimizeAway(&seed);
    const out = liveAcross(seed, @ptrCast(&clobberAndJump));
    for (out, 0..) |o, i| try std.testing.expectEqual((seed *% (i + 3) +% i) +% aborted, o);
}

test "a protected call that returns zero-extends the int" {
    var seed: u64 = 99;
    std.mem.doNotOptimizeAway(&seed);
    const out = liveAcross(seed, @ptrCast(&returnMinusOne));
    for (out, 0..) |o, i| try std.testing.expectEqual((seed *% (i + 3) +% i) +% 0xffff_ffff, o);
}

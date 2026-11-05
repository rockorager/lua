//! C's variable arguments for the C API's `...` and `va_list` functions
//! (`lua_pushfstring`, `lua_pushvfstring`, `luaL_error`).
//!
//! Zig's `@cVaStart`, `@cVaArg`, and `std.lang.VaList` serve every
//! target the C API builds for but aarch64 Linux, where Zig 0.16 refuses
//! them with LLVM ("disabled due to miscompilations"). There this file is
//! AAPCS64's `va_list` (its §B.3): a variadic function's entry, written in
//! assembly, saves the argument registers and builds the list, and `arg`
//! reads it as `va_arg` does. Apple's arm64 ABI passes variable arguments
//! on the stack with a plain pointer for `va_list`, which Zig handles.

const std = @import("std");
const builtin = @import("builtin");

/// Whether Zig's own variable arguments work here.
pub const native = !(builtin.cpu.arch == .aarch64 and builtin.os.tag == .linux);

/// What a `va_list` parameter points to.
pub const List = if (native) std.lang.VaList else Aapcs64;

/// AAPCS64's `va_list`: the next argument on the stack, the ends of the
/// saved general and vector registers, and the negative offsets of the
/// next unread one in each (0 or more when they are used up).
const Aapcs64 = extern struct {
    stack: usize,
    gr_top: usize,
    vr_top: usize,
    gr_offs: i32,
    vr_offs: i32,
};

/// `va_arg(*ap, T)` for the integer, pointer, and `double` arguments the
/// API's formats take.
pub inline fn arg(ap: *List, comptime T: type) T {
    if (native) return @cVaArg(ap, T);
    comptime std.debug.assert(@sizeOf(T) <= 8);
    const float = @typeInfo(T) == .float;
    const offs = if (float) &ap.vr_offs else &ap.gr_offs;
    const top = if (float) ap.vr_top else ap.gr_top;
    const at: usize = blk: {
        const o = offs.*;
        if (o < 0) {
            offs.* = o + if (float) 16 else 8;
            if (offs.* <= 0) break :blk top -% @as(usize, @intCast(-o));
        }
        const a = ap.stack;
        ap.stack += 8;
        break :blk a;
    };
    return @as(*align(1) const T, @ptrFromInt(at)).*;
}

/// aarch64 Linux: the entry of a C function `f(a0, a1, ...)`, which calls
/// `target(a0, a1, ap)` with `ap` the list of the variable arguments and
/// returns its result. It saves x2 to x7 and q0 to q7, where the first
/// variable arguments arrive, in its frame.
pub fn Entry(comptime target: anytype) type {
    return struct {
        pub fn entry() callconv(.naked) void {
            // Frame: the list at sp, the general registers at sp+32 (to
            // gr_top, sp+96), the vector registers at sp+96 (to vr_top,
            // sp+224). Two named arguments leave six general registers.
            asm volatile (
                \\  stp x29, x30, [sp, #-16]!
                \\  mov x29, sp
                \\  sub sp, sp, #224
                \\  stp x0, x1, [sp, #32]
                \\  stp x2, x3, [sp, #48]
                \\  stp x4, x5, [sp, #64]
                \\  stp x6, x7, [sp, #80]
                \\  stp q0, q1, [sp, #96]
                \\  stp q2, q3, [sp, #128]
                \\  stp q4, q5, [sp, #160]
                \\  stp q6, q7, [sp, #192]
                \\  add x9, x29, #16
                \\  str x9, [sp, #0]
                \\  add x9, sp, #96
                \\  str x9, [sp, #8]
                \\  add x9, sp, #224
                \\  str x9, [sp, #16]
                \\  mov w9, #-48
                \\  str w9, [sp, #24]
                \\  mov w9, #-128
                \\  str w9, [sp, #28]
                \\  mov x2, sp
                \\  bl %[target]
                \\  mov sp, x29
                \\  ldp x29, x30, [sp], #16
                \\  ret
                :
                : [target] "X" (target),
            );
        }
    };
}

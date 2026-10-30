//! The bytecode: 32-bit instructions in Lua 5.5's formats and Lua 5.5.1's
//! opcode set, numbered and encoded exactly as PUC-Rio's `lopcodes.h`. A
//! compiler targeting this VM emits what `luac -l -l` lists for the same
//! source (the dev shell's `luac` is the reference), with the operand
//! meanings documented on each opcode below.
//!
//! Formats, most significant bit on the left:
//!
//! ```
//!   iABC    C(8)  | B(8)  | k(1) | A(8) | op(7)
//!   ivABC   vC(10) | vB(6) | k(1) | A(8) | op(7)
//!   iABx    Bx(17)               | A(8) | op(7)
//!   iAsBx   sBx(17)              | A(8) | op(7)
//!   iAx     Ax(25)                      | op(7)
//!   isJ     sJ(25)                      | op(7)
//! ```
//!
//! Signed operands are stored excess-K: sBx = Bx - 65535, sJ = field -
//! 16777215, and the 8-bit immediates sB and sC = field - 127.
//!
//! Notation: R[x] is register x (stack slot `func + 1 + x`), K[x] constant
//! x, UpValue[x] upvalue x of the running closure, and RK(x) is K[x] when
//! the k bit is set and R[x] otherwise. "pc++" skips the next instruction.
//!
//! Conventions the compiler must keep:
//!
//! - Every arithmetic and bitwise opcode (`ADDI` .. `SHR`) is followed by
//!   `MMBIN`, `MMBINI`, or `MMBINK` naming the same operands and the event.
//!   The fast path skips it; when the operands are not numbers the VM runs
//!   it to call the metamethod.
//! - Every comparison and test (`EQ` .. `TESTSET`) is followed by a `JMP`.
//!   The VM skips the jump when the condition differs from k and takes it
//!   otherwise.
//! - `LOADKX` and `NEWTABLE` are always followed by `EXTRAARG`; `SETLIST`
//!   is when k is set.
//! - A B (or vB, or C for results) of 0 means "up to the stack top", which
//!   the previous instruction (`CALL` with C = 0, `VARARG` with C = 0) set.
//! - A vararg function starts with `VARARGPREP`.
//! - `GETTABUP`, `GETFIELD`, `SELF`, `SETTABUP`, and `SETFIELD` take only
//!   short-string constant keys; other constant keys use `GETTABLE` and
//!   `SETTABLE` with the key in a register, or `SETTABLE` with k for the
//!   value only.

const std = @import("std");

pub const Instruction = u32;

pub const OpCode = enum(u7) {
    /// iABC: R[A] := R[B]
    move,
    /// iAsBx: R[A] := sBx (an integer)
    loadi,
    /// iAsBx: R[A] := float(sBx)
    loadf,
    /// iABx: R[A] := K[Bx]
    loadk,
    /// iABx: R[A] := K[Ax of the next EXTRAARG]
    loadkx,
    /// iABC: R[A] := false
    loadfalse,
    /// iABC: R[A] := false; pc++. Turns a condition into a boolean.
    lfalseskip,
    /// iABC: R[A] := true
    loadtrue,
    /// iABC: R[A], R[A+1], ..., R[A+B] := nil (B+1 registers)
    loadnil,
    /// iABC: R[A] := UpValue[B]
    getupval,
    /// iABC: UpValue[B] := R[A]
    setupval,
    /// iABC: R[A] := UpValue[B][K[C]], K[C] a short string
    gettabup,
    /// iABC: R[A] := R[B][R[C]]
    gettable,
    /// iABC: R[A] := R[B][C], C an unsigned integer key
    geti,
    /// iABC: R[A] := R[B][K[C]], K[C] a short string
    getfield,
    /// iABC: UpValue[A][K[B]] := RK(C), K[B] a short string
    settabup,
    /// iABC: R[A][R[B]] := RK(C)
    settable,
    /// iABC: R[A][B] := RK(C), B an unsigned integer key
    seti,
    /// iABC: R[A][K[B]] := RK(C), K[B] a short string
    setfield,
    /// ivABC: R[A] := {}. vB is log2(hash size) + 1, or 0 for no hash
    /// part; the array size is vC, or with k, EXTRAARG's Ax * 1024 + vC.
    /// Always followed by EXTRAARG.
    newtable,
    /// iABC: R[A+1] := R[B]; R[A] := R[B][K[C]], K[C] a short string
    self,
    /// iABC: R[A] := R[B] + sC
    addi,
    /// iABC: R[A] := R[B] + K[C], K[C] a number
    addk,
    /// iABC: R[A] := R[B] - K[C]
    subk,
    /// iABC: R[A] := R[B] * K[C]
    mulk,
    /// iABC: R[A] := R[B] % K[C]
    modk,
    /// iABC: R[A] := R[B] ^ K[C]
    powk,
    /// iABC: R[A] := R[B] / K[C]
    divk,
    /// iABC: R[A] := R[B] // K[C]
    idivk,
    /// iABC: R[A] := R[B] & K[C], K[C] an integer
    bandk,
    /// iABC: R[A] := R[B] | K[C], K[C] an integer
    bork,
    /// iABC: R[A] := R[B] ~ K[C], K[C] an integer
    bxork,
    /// iABC: R[A] := sC << R[B]
    shli,
    /// iABC: R[A] := R[B] >> sC
    shri,
    /// iABC: R[A] := R[B] + R[C]
    add,
    /// iABC: R[A] := R[B] - R[C]
    sub,
    /// iABC: R[A] := R[B] * R[C]
    mul,
    /// iABC: R[A] := R[B] % R[C]
    mod,
    /// iABC: R[A] := R[B] ^ R[C]
    pow,
    /// iABC: R[A] := R[B] / R[C]
    div,
    /// iABC: R[A] := R[B] // R[C]
    idiv,
    /// iABC: R[A] := R[B] & R[C]
    band,
    /// iABC: R[A] := R[B] | R[C]
    bor,
    /// iABC: R[A] := R[B] ~ R[C]
    bxor,
    /// iABC: R[A] := R[B] << R[C]
    shl,
    /// iABC: R[A] := R[B] >> R[C]
    shr,
    /// iABC: call metamethod C (a `State.Tm`) over R[A] and R[B]; the
    /// result goes to the previous instruction's A.
    mmbin,
    /// iABC: call metamethod C over R[A] and sB; k means the operands were
    /// swapped (the immediate is the first operand).
    mmbini,
    /// iABC: call metamethod C over R[A] and K[B]; k as for MMBINI.
    mmbink,
    /// iABC: R[A] := -R[B]
    unm,
    /// iABC: R[A] := ~R[B]
    bnot,
    /// iABC: R[A] := not R[B]
    not,
    /// iABC: R[A] := #R[B]
    len,
    /// iABC: R[A] := R[A] .. ... .. R[A+B-1]
    concat,
    /// iABC: close upvalues and to-be-closed variables >= R[A]
    close,
    /// iABC: mark R[A] to be closed
    tbc,
    /// isJ: pc += sJ
    jmp,
    /// iABC: if ((R[A] == R[B]) ~= k) then pc++
    eq,
    /// iABC: if ((R[A] < R[B]) ~= k) then pc++
    lt,
    /// iABC: if ((R[A] <= R[B]) ~= k) then pc++
    le,
    /// iABC: if ((R[A] == K[B]) ~= k) then pc++
    eqk,
    /// iABC: if ((R[A] == sB) ~= k) then pc++; C is 1 when the source
    /// operand was a float (for error messages and metamethods).
    eqi,
    /// iABC: if ((R[A] < sB) ~= k) then pc++; C as for EQI
    lti,
    /// iABC: if ((R[A] <= sB) ~= k) then pc++; C as for EQI
    lei,
    /// iABC: if ((R[A] > sB) ~= k) then pc++; C as for EQI
    gti,
    /// iABC: if ((R[A] >= sB) ~= k) then pc++; C as for EQI
    gei,
    /// iABC: if (not R[A] == k) then pc++
    @"test",
    /// iABC: if (not R[B] == k) then pc++ else R[A] := R[B]
    testset,
    /// iABC: R[A], ..., R[A+C-2] := R[A](R[A+1], ..., R[A+B-1]).
    /// B = 0: arguments up to top. C = 0: all results, and top is set
    /// after the last.
    call,
    /// iABC: return R[A](R[A+1], ..., R[A+B-1]). k: close upvalues first.
    /// C > 0: the function is vararg with C-1 fixed parameters.
    tailcall,
    /// iABC: return R[A], ..., R[A+B-2]. B = 0: up to top. k and C as for
    /// TAILCALL.
    @"return",
    /// iABC: return (no values)
    return0,
    /// iABC: return R[A]
    return1,
    /// iABx: numeric loop step. Integer loop (R[A+1] the step, R[A] the
    /// remaining count): if count > 0 then count--, R[A+2] += step, pc -=
    /// Bx. Float loop (R[A] the limit): R[A+2] += R[A+1]; if still within
    /// the limit then pc -= Bx.
    forloop,
    /// iABx: before the loop, R[A] = initial value, R[A+1] = limit,
    /// R[A+2] = step. Checks them, raises "'for' step is zero" and the
    /// like, and rewrites them: an integer loop to (count, step, index), a
    /// float loop to (limit, step, index). If the loop runs zero times then
    /// pc += Bx + 1. R[A+2] is the loop variable the body sees.
    forprep,
    /// iABx: R[A] iterator, R[A+1] state, R[A+2] initial control value,
    /// R[A+3] closing value. Swaps R[A+2] and R[A+3], marks R[A+2] to be
    /// closed, and pc += Bx (to the TFORCALL).
    tforprep,
    /// iABC: R[A+3], ..., R[A+2+C] := R[A](R[A+1], R[A+3]). The control
    /// variable R[A+3] is the first loop variable. Followed by TFORLOOP.
    tforcall,
    /// iABx: if R[A+3] ~= nil then pc -= Bx
    tforloop,
    /// ivABC: R[A][vC+i] := R[A+i], 1 <= i <= vB. vB = 0: up to top. k:
    /// the real vC is EXTRAARG's Ax * 1024 + vC.
    setlist,
    /// iABx: R[A] := closure(KPROTO[Bx])
    closure,
    /// iABC: R[A], ..., R[A+C-2] := the extra arguments. C = 0: all of
    /// them, and top is set. k: they come from the vararg table in R[B].
    vararg,
    /// iABC: R[A] := R[B][R[C]] where R[B] is the vararg parameter: the
    /// extra argument R[C], or their count for the key "n".
    getvarg,
    /// iABx: raise an error if R[A] ~= nil; K[Bx-1] is the global's name
    /// (Bx = 0: unknown). For `global` declarations.
    errnnil,
    /// iABC: adjust the extra arguments of a vararg function (first
    /// instruction of every vararg function).
    varargprep,
    /// iAx: extra operand for the previous instruction
    extraarg,
};

pub const Mode = enum { iABC, ivABC, iABx, iAsBx, iAx, isJ };

/// What the compiler and the debug library need to know about an opcode,
/// `luaP_opmodes`.
pub const Props = struct {
    mode: Mode,
    /// Sets R[A].
    sets_a: bool = false,
    /// A test: the next instruction is a jump.
    is_test: bool = false,
    /// Uses top from the previous instruction when B (vB) is 0.
    in_top: bool = false,
    /// Sets top for the next instruction when C is 0.
    out_top: bool = false,
    /// A metamethod instruction following an arithmetic one.
    is_mm: bool = false,
};

pub const props: [std.enums.values(OpCode).len]Props = blk: {
    var p: [std.enums.values(OpCode).len]Props = undefined;
    for (std.enums.values(OpCode)) |o| {
        const i = @intFromEnum(o);
        p[i] = switch (o) {
            .loadi, .loadf => .{ .mode = .iAsBx, .sets_a = true },
            .loadk, .loadkx, .forloop, .forprep, .tforloop, .closure => .{ .mode = .iABx, .sets_a = true },
            .tforprep, .errnnil => .{ .mode = .iABx },
            .newtable => .{ .mode = .ivABC, .sets_a = true },
            .setlist => .{ .mode = .ivABC, .in_top = true },
            .setupval,
            .settabup,
            .settable,
            .seti,
            .setfield,
            .close,
            .tbc,
            .tforcall,
            .varargprep,
            .return0,
            .return1,
            => .{ .mode = .iABC },
            .mmbin, .mmbini, .mmbink => .{ .mode = .iABC, .is_mm = true },
            .jmp => .{ .mode = .isJ },
            .eq, .lt, .le, .eqk, .eqi, .lti, .lei, .gti, .gei, .@"test" => .{ .mode = .iABC, .is_test = true },
            .testset => .{ .mode = .iABC, .is_test = true, .sets_a = true },
            .call, .tailcall => .{ .mode = .iABC, .sets_a = true, .in_top = true, .out_top = true },
            .@"return" => .{ .mode = .iABC, .in_top = true },
            .vararg => .{ .mode = .iABC, .sets_a = true, .out_top = true },
            .extraarg => .{ .mode = .iAx },
            else => .{ .mode = .iABC, .sets_a = true },
        };
    }
    break :blk p;
};

pub const max_a = (1 << 8) - 1;
pub const max_b = (1 << 8) - 1;
pub const max_c = (1 << 8) - 1;
pub const max_vb = (1 << 6) - 1;
pub const max_vc = (1 << 10) - 1;
pub const max_bx = (1 << 17) - 1;
pub const max_ax = (1 << 25) - 1;
pub const max_sj = (1 << 25) - 1;
pub const offset_sbx = max_bx >> 1;
pub const offset_sj = max_sj >> 1;
pub const offset_sc = max_c >> 1;
/// Registers a function may use, `MAX_FSTACK`.
pub const max_registers = max_a;
/// Items `SETLIST` stores per instruction when the compiler flushes a
/// constructor, `LFIELDS_PER_FLUSH`.
pub const fields_per_flush = 50;

// Decoding.

pub inline fn op(i: Instruction) OpCode {
    return @enumFromInt(@as(u7, @truncate(i)));
}
pub inline fn a(i: Instruction) u8 {
    return @truncate(i >> 7);
}
pub inline fn k(i: Instruction) bool {
    return (i >> 15) & 1 != 0;
}
pub inline fn b(i: Instruction) u8 {
    return @truncate(i >> 16);
}
pub inline fn c(i: Instruction) u8 {
    return @truncate(i >> 24);
}
pub inline fn sb(i: Instruction) i32 {
    return @as(i32, b(i)) - offset_sc;
}
pub inline fn sc(i: Instruction) i32 {
    return @as(i32, c(i)) - offset_sc;
}
pub inline fn vb(i: Instruction) u6 {
    return @truncate(i >> 16);
}
pub inline fn vc(i: Instruction) u10 {
    return @truncate(i >> 22);
}
pub inline fn bx(i: Instruction) u17 {
    return @truncate(i >> 15);
}
pub inline fn sbx(i: Instruction) i32 {
    return @as(i32, bx(i)) - offset_sbx;
}
pub inline fn ax(i: Instruction) u25 {
    return @truncate(i >> 7);
}
pub inline fn sj(i: Instruction) i32 {
    return @as(i32, ax(i)) - offset_sj;
}

// Encoding.

pub fn abc(o: OpCode, a_: u8, b_: u8, c_: u8, k_: bool) Instruction {
    return @as(u32, @intFromEnum(o)) | @as(u32, a_) << 7 | @as(u32, @intFromBool(k_)) << 15 |
        @as(u32, b_) << 16 | @as(u32, c_) << 24;
}

pub fn vabc(o: OpCode, a_: u8, vb_: u6, vc_: u10, k_: bool) Instruction {
    return @as(u32, @intFromEnum(o)) | @as(u32, a_) << 7 | @as(u32, @intFromBool(k_)) << 15 |
        @as(u32, vb_) << 16 | @as(u32, vc_) << 22;
}

pub fn abx(o: OpCode, a_: u8, bx_: u17) Instruction {
    return @as(u32, @intFromEnum(o)) | @as(u32, a_) << 7 | @as(u32, bx_) << 15;
}

pub fn asbx(o: OpCode, a_: u8, sbx_: i32) Instruction {
    return abx(o, a_, @intCast(sbx_ + offset_sbx));
}

pub fn iax(o: OpCode, ax_: u25) Instruction {
    return @as(u32, @intFromEnum(o)) | @as(u32, ax_) << 7;
}

pub fn isj(o: OpCode, sj_: i32) Instruction {
    return @as(u32, @intFromEnum(o)) | @as(u32, @as(u25, @intCast(sj_ + offset_sj))) << 7;
}

/// An 8-bit signed immediate (sB, sC) as its stored field.
pub fn int2sc(i: i32) u8 {
    return @intCast(i + offset_sc);
}

const testing = std.testing;

test "opcode numbers match Lua 5.5.1's" {
    // Spot checks against lopcodes.h's enum order.
    try testing.expectEqual(0, @intFromEnum(OpCode.move));
    try testing.expectEqual(11, @intFromEnum(OpCode.gettabup));
    try testing.expectEqual(19, @intFromEnum(OpCode.newtable));
    try testing.expectEqual(34, @intFromEnum(OpCode.add));
    try testing.expectEqual(46, @intFromEnum(OpCode.mmbin));
    try testing.expectEqual(57, @intFromEnum(OpCode.eq));
    try testing.expectEqual(68, @intFromEnum(OpCode.call));
    try testing.expectEqual(73, @intFromEnum(OpCode.forloop));
    try testing.expectEqual(84, @intFromEnum(OpCode.extraarg));
    try testing.expectEqual(85, std.enums.values(OpCode).len);
}

test "encoding round-trips every field" {
    const i = abc(.add, 200, 17, 255, true);
    try testing.expectEqual(OpCode.add, op(i));
    try testing.expectEqual(@as(u8, 200), a(i));
    try testing.expectEqual(@as(u8, 17), b(i));
    try testing.expectEqual(@as(u8, 255), c(i));
    try testing.expect(k(i));
    try testing.expectEqual(@as(i32, -65535), sbx(asbx(.loadi, 3, -65535)));
    try testing.expectEqual(@as(i32, 65536), sbx(asbx(.loadi, 3, 65536)));
    try testing.expectEqual(@as(i32, -5), sj(isj(.jmp, -5)));
    try testing.expectEqual(@as(i32, -1), sc(abc(.addi, 0, 0, int2sc(-1), false)));
    const n = vabc(.newtable, 9, 63, 1023, true);
    try testing.expectEqual(@as(u6, 63), vb(n));
    try testing.expectEqual(@as(u10, 1023), vc(n));
    try testing.expectEqual(@as(u8, 9), a(n));
}

test "encodings match luac's for the same instructions" {
    // Words found in Lua 5.5.1 `luac -o` output for instructions `luac -l`
    // lists as ADDI 2 0 -1, LTI 0 2 0, JMP 1, and FORPREP 0 0.
    try testing.expectEqual(@as(u32, 0x7e000115), abc(.addi, 2, 0, int2sc(-1), false));
    try testing.expectEqual(@as(u32, 0x0081003e), abc(.lti, 0, int2sc(2), 0, false));
    try testing.expectEqual(@as(u32, 0x80000038), isj(.jmp, 1));
    try testing.expectEqual(@as(u32, 0x0000004a), abx(.forprep, 0, 0));
}

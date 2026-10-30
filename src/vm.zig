//! The interpreter: one loop runs a thread's Lua frames (plan decisions 3,
//! 4, and 5).
//!
//! Dispatch is a labeled `switch` with `continue :dispatch`, which Zig
//! compiles to one indirect jump per opcode. The loop keeps `pc`, `base`
//! (a pointer to the running frame's registers), and the constant array in
//! locals, and reloads `base` after anything that can grow the stack: calls,
//! metamethods, and vararg handling.
//!
//! A Lua-to-Lua call pushes a frame and continues the same loop, so Lua
//! recursion costs heap, not Zig stack. A metamethod written in Lua that an
//! instruction calls (`__index`, arithmetic, comparisons) gets a frame
//! flagged `finish_op`; when it returns, `finishOp` completes the
//! interrupted instruction, as PUC-Rio's `luaV_finishOp` does. Native
//! metamethods run directly and the instruction completes inline.
//!
//! Errors are `error.LuaError` with the error object in `Thread.err`; they
//! unwind through ordinary Zig error returns to the nearest `pcall`.

const std = @import("std");
const Value = @import("Value.zig");
const String = @import("String.zig");
const Table = @import("Table.zig");
const Proto = @import("Proto.zig");
const Thread = @import("Thread.zig");
const State = @import("State.zig");
const opcodes = @import("opcodes.zig");

const Error = Value.Error;
const Frame = Thread.Frame;
const Tm = State.Tm;
const LuaClosure = Proto.LuaClosure;
const Instruction = opcodes.Instruction;

const op = opcodes.op;
const getK = opcodes.k;

// Register operands widened, so `a + n` cannot wrap at 255.
inline fn getA(i: Instruction) u32 {
    return opcodes.a(i);
}
inline fn getB(i: Instruction) u32 {
    return opcodes.b(i);
}
inline fn getC(i: Instruction) u32 {
    return opcodes.c(i);
}

/// Longest `__index`/`__newindex` chain, `MAXTAGLOOP`.
const max_tag_loop = 2000;

/// Calls the value at stack slot `func` with the arguments above it, up to
/// `top`. The results replace the function and arguments: `nresults` of
/// them, or all of them with `top` after the last when `nresults` is -1.
pub fn call(th: *Thread, func: u32, nresults: i16) Error!void {
    if (th.native_calls >= Thread.max_native_calls) return th.runError("C stack overflow", .{});
    th.native_calls += 1;
    defer th.native_calls -= 1;
    if (try preCall(th, func, nresults)) {
        th.frame().flags.fresh = true;
        try execute(th);
    }
}

/// `call` in protected mode. On an error the stack is unwound to `func`,
/// the error object is left at `func`, `top` is `func + 1`, and the result
/// is false. Allocation failure leaves the "not enough memory" string.
pub fn pcall(th: *Thread, func: u32, nresults: i16) bool {
    const frames = th.frames.items.len;
    call(th, func, nresults) catch |e| {
        const err: Value = switch (e) {
            error.LuaError => th.err,
            error.OutOfMemory => .string(th.state.memerr),
        };
        th.closeUpvals(func);
        th.frames.shrinkRetainingCapacity(frames);
        th.err = .nil;
        th.stack[func] = err;
        th.top = func + 1;
        return false;
    };
    return true;
}

/// A closure for a main chunk's prototype, with its one upvalue (`_ENV`)
/// set to the globals table, as `load` does.
pub fn mainClosure(state: *State, p: *Proto) error{OutOfMemory}!*LuaClosure {
    const c = try LuaClosure.create(&state.heap, p, @intCast(p.upvalues.len));
    for (0..c.nupvalues) |i| c.setUpval(&state.heap, i, try Proto.Upval.createClosed(&state.heap, .nil));
    if (c.nupvalues > 0) c.upvals()[0].set(&state.heap, .table(state.globals));
    return c;
}

/// Starts a call of the value at `func`. For a Lua function, pushes its
/// frame and returns true; the caller runs it. A native function runs to
/// completion here, its results placed, and the result is false.
fn preCall(th: *Thread, func: u32, nresults: i16) Error!bool {
    var loops: u32 = 0;
    while (true) : (loops += 1) {
        const f = th.stack[func];
        switch (f.tag) {
            .lua_closure => {
                try pushLuaFrame(th, func, f.asLuaClosure().proto, nresults);
                return true;
            },
            .native_fn => {
                try callNative(th, func, nresults, f.asNative());
                return false;
            },
            .native_closure => {
                try callNative(th, func, nresults, f.asNativeClosure().f);
                return false;
            },
            else => {
                // `__call`: the handler becomes the function and the called
                // value its first argument.
                const h = th.state.tmOf(f, .call) orelse return typeError(th, f, "call");
                if (loops >= max_tag_loop) return th.runError("'__call' chain too long; possible loop", .{});
                try th.ensureStack(1);
                @memmove(th.stack[func + 1 .. th.top + 1], th.stack[func..th.top]);
                th.top += 1;
                th.stack[func] = h;
            },
        }
    }
}

/// Pushes the frame for a call of Lua function `p` at `func`, with its
/// arguments up to `top`; missing parameters become nil.
inline fn pushLuaFrame(th: *Thread, func: u32, p: *const Proto, nresults: i16) Error!void {
    const nargs = th.top - func - 1;
    const fsize: u32 = p.maxstacksize;
    const frame_top = func + 1 + fsize;
    if (frame_top + Thread.extra_stack > th.stack.len) try th.growStack(frame_top);
    var n = nargs;
    while (n < p.numparams) : (n += 1) th.stack[func + 1 + n] = .nil;
    th.top = func + 1 + n;
    if (th.frames.items.len == th.frames.capacity) try th.frames.ensureUnusedCapacity(th.heap().allocator(), 1);
    th.frames.appendAssumeCapacity(.{
        .func = func,
        .top = frame_top,
        .pc = p.code.ptr,
        .nresults = nresults,
        .flags = .{ .lua = true },
    });
}

fn callNative(th: *Thread, func: u32, nresults: i16, f: Value.NativeFn) Error!void {
    try th.ensureStack(Thread.min_stack);
    try th.frames.append(th.heap().allocator(), .{
        .func = func,
        .top = th.top + Thread.min_stack,
        .nresults = nresults,
        .flags = .{},
    });
    const n = try f(th, func + 1);
    std.debug.assert(n <= th.top - func - 1);
    moveResults(th, func, th.top - n, n, nresults);
    th.frames.items.len -= 1;
}

/// Moves `n` results from `first` to `dest`, adjusted to `wanted`, and sets
/// `top` after them.
inline fn moveResults(th: *Thread, dest: u32, first: u32, n: u32, wanted: i16) void {
    const s = th.stack;
    switch (wanted) {
        0 => th.top = dest,
        1 => {
            s[dest] = if (n == 0) .nil else s[first];
            th.top = dest + 1;
        },
        -1 => {
            for (0..n) |j| s[dest + j] = s[first + j];
            th.top = dest + n;
        },
        else => {
            const w: u32 = @intCast(wanted);
            const m = @min(n, w);
            for (0..m) |j| s[dest + j] = s[first + j];
            for (m..w) |j| s[dest + j] = .nil;
            th.top = dest + w;
        },
    }
}

inline fn fetch(pc: *[*]const u32, i: *Instruction) opcodes.OpCode {
    i.* = pc.*[0];
    pc.* += 1;
    return op(i.*);
}

/// Runs Lua frames from the current one until a frame flagged `fresh`
/// returns.
fn execute(th: *Thread) Error!void {
    // The inline prongs instantiate many inline calls at compile time.
    @setEvalBranchQuota(10_000);
    const heap = th.heap();
    var ci: *Frame = th.frame();
    newframe: while (true) {
        const cl = th.stack[ci.func].asLuaClosure();
        const k: [*]const Value = cl.proto.k.ptr;
        var base: [*]Value = th.stack.ptr + ci.base();
        var pc: [*]const u32 = ci.pc;
        var i: Instruction = undefined;
        dispatch: switch (fetch(&pc, &i)) {
            .move => {
                base[getA(i)] = base[getB(i)];
                continue :dispatch fetch(&pc, &i);
            },
            .loadi => {
                base[getA(i)] = .int(opcodes.sbx(i));
                continue :dispatch fetch(&pc, &i);
            },
            .loadf => {
                base[getA(i)] = .float(@floatFromInt(opcodes.sbx(i)));
                continue :dispatch fetch(&pc, &i);
            },
            .loadk => {
                base[getA(i)] = k[opcodes.bx(i)];
                continue :dispatch fetch(&pc, &i);
            },
            .loadkx => {
                base[getA(i)] = k[opcodes.ax(pc[0])];
                pc += 1;
                continue :dispatch fetch(&pc, &i);
            },
            .loadfalse => {
                base[getA(i)] = .false;
                continue :dispatch fetch(&pc, &i);
            },
            .lfalseskip => {
                base[getA(i)] = .false;
                pc += 1;
                continue :dispatch fetch(&pc, &i);
            },
            .loadtrue => {
                base[getA(i)] = .true;
                continue :dispatch fetch(&pc, &i);
            },
            .loadnil => {
                const a = getA(i);
                for (0..@as(usize, getB(i)) + 1) |j| base[a + j] = .nil;
                continue :dispatch fetch(&pc, &i);
            },
            .getupval => {
                base[getA(i)] = cl.upvals()[getB(i)].v.*;
                continue :dispatch fetch(&pc, &i);
            },
            .setupval => {
                cl.upvals()[getB(i)].set(heap, base[getA(i)]);
                continue :dispatch fetch(&pc, &i);
            },
            .gettabup => {
                const t = cl.upvals()[getB(i)].v.*;
                const key = k[getC(i)];
                if (t.tag == .table) {
                    const h = t.asTable();
                    const v = h.getShortStr(key.asString());
                    if (!v.isNil() or th.state.fastTm(h.metatable, .index) == null) {
                        base[getA(i)] = v;
                        continue :dispatch fetch(&pc, &i);
                    }
                }
                ci.pc = pc;
                if (try getSlow(th, ci, t, key, ci.base() + getA(i))) {
                    ci = th.frame();
                    continue :newframe;
                }
                base = th.stack.ptr + ci.base();
                continue :dispatch fetch(&pc, &i);
            },
            .gettable => {
                const t = base[getB(i)];
                const key = base[getC(i)];
                if (t.tag == .table) {
                    const h = t.asTable();
                    const v = if (key.tag == .int) h.getInt(key.payload.int) else h.get(key);
                    if (!v.isNil() or th.state.fastTm(h.metatable, .index) == null) {
                        base[getA(i)] = v;
                        continue :dispatch fetch(&pc, &i);
                    }
                }
                ci.pc = pc;
                if (try getSlow(th, ci, t, key, ci.base() + getA(i))) {
                    ci = th.frame();
                    continue :newframe;
                }
                base = th.stack.ptr + ci.base();
                continue :dispatch fetch(&pc, &i);
            },
            .geti => {
                const t = base[getB(i)];
                if (t.tag == .table) {
                    const h = t.asTable();
                    const v = h.getInt(getC(i));
                    if (!v.isNil() or th.state.fastTm(h.metatable, .index) == null) {
                        base[getA(i)] = v;
                        continue :dispatch fetch(&pc, &i);
                    }
                }
                ci.pc = pc;
                if (try getSlow(th, ci, t, .int(getC(i)), ci.base() + getA(i))) {
                    ci = th.frame();
                    continue :newframe;
                }
                base = th.stack.ptr + ci.base();
                continue :dispatch fetch(&pc, &i);
            },
            .getfield, .self => {
                const t = base[getB(i)];
                const key = k[getC(i)];
                if (op(i) == .self) base[getA(i) + 1] = t;
                if (t.tag == .table) {
                    const h = t.asTable();
                    const v = h.getShortStr(key.asString());
                    if (!v.isNil() or th.state.fastTm(h.metatable, .index) == null) {
                        base[getA(i)] = v;
                        continue :dispatch fetch(&pc, &i);
                    }
                }
                ci.pc = pc;
                if (try getSlow(th, ci, t, key, ci.base() + getA(i))) {
                    ci = th.frame();
                    continue :newframe;
                }
                base = th.stack.ptr + ci.base();
                continue :dispatch fetch(&pc, &i);
            },
            .settabup => {
                const t = cl.upvals()[getA(i)].v.*;
                const key = k[getB(i)];
                const v = if (getK(i)) k[getC(i)] else base[getC(i)];
                if (t.tag == .table and t.asTable().metatable == null) {
                    try t.asTable().setShortStr(heap, key.asString(), v);
                    continue :dispatch fetch(&pc, &i);
                }
                ci.pc = pc;
                if (try setSlow(th, ci, t, key, v)) {
                    ci = th.frame();
                    continue :newframe;
                }
                base = th.stack.ptr + ci.base();
                continue :dispatch fetch(&pc, &i);
            },
            .settable => {
                const t = base[getA(i)];
                const key = base[getB(i)];
                const v = if (getK(i)) k[getC(i)] else base[getC(i)];
                if (t.tag == .table and t.asTable().metatable == null) {
                    if (key.tag == .int) {
                        try t.asTable().setInt(heap, key.payload.int, v);
                        continue :dispatch fetch(&pc, &i);
                    }
                    ci.pc = pc;
                    t.asTable().set(heap, key, v) catch |e| return setError(th, e);
                    continue :dispatch fetch(&pc, &i);
                }
                ci.pc = pc;
                if (try setSlow(th, ci, t, key, v)) {
                    ci = th.frame();
                    continue :newframe;
                }
                base = th.stack.ptr + ci.base();
                continue :dispatch fetch(&pc, &i);
            },
            .seti => {
                const t = base[getA(i)];
                const v = if (getK(i)) k[getC(i)] else base[getC(i)];
                if (t.tag == .table and t.asTable().metatable == null) {
                    try t.asTable().setInt(heap, getB(i), v);
                    continue :dispatch fetch(&pc, &i);
                }
                ci.pc = pc;
                if (try setSlow(th, ci, t, .int(getB(i)), v)) {
                    ci = th.frame();
                    continue :newframe;
                }
                base = th.stack.ptr + ci.base();
                continue :dispatch fetch(&pc, &i);
            },
            .setfield => {
                const t = base[getA(i)];
                const key = k[getB(i)];
                const v = if (getK(i)) k[getC(i)] else base[getC(i)];
                if (t.tag == .table and t.asTable().metatable == null) {
                    try t.asTable().setShortStr(heap, key.asString(), v);
                    continue :dispatch fetch(&pc, &i);
                }
                ci.pc = pc;
                if (try setSlow(th, ci, t, key, v)) {
                    ci = th.frame();
                    continue :newframe;
                }
                base = th.stack.ptr + ci.base();
                continue :dispatch fetch(&pc, &i);
            },
            .newtable => {
                const vb = opcodes.vb(i);
                var narray: u32 = opcodes.vc(i);
                if (getK(i)) narray += @as(u32, opcodes.ax(pc[0])) * (opcodes.max_vc + 1);
                pc += 1;
                const nhash: u32 = if (vb > 0) @as(u32, 1) << @intCast(vb - 1) else 0;
                base[getA(i)] = .table(try Table.create(heap, narray, nhash));
                ci.pc = pc;
                th.state.checkGc();
                continue :dispatch fetch(&pc, &i);
            },
            inline .addi,
            .addk,
            .subk,
            .mulk,
            .modk,
            .powk,
            .divk,
            .idivk,
            .add,
            .sub,
            .mul,
            .mod,
            .pow,
            .div,
            .idiv,
            => |o| {
                const rb = base[getB(i)];
                const rc = switch (o) {
                    .addi => Value.int(opcodes.sc(i)),
                    .addk, .subk, .mulk, .modk, .powk, .divk, .idivk => k[getC(i)],
                    else => base[getC(i)],
                };
                const arith: Arith = comptime arithOf(o);
                if (rb.tag == .int and rc.tag == .int and arith.intOp()) {
                    const x = rb.payload.int;
                    const y = rc.payload.int;
                    switch (arith) {
                        .add => base[getA(i)] = .int(x +% y),
                        .sub => base[getA(i)] = .int(x -% y),
                        .mul => base[getA(i)] = .int(x *% y),
                        .mod, .idiv => {
                            if (y == 0) {
                                ci.pc = pc;
                                if (arith == .mod) return th.runError("attempt to perform 'n%%0'", .{});
                                return th.runError("attempt to perform 'n//0'", .{});
                            }
                            base[getA(i)] = .int(if (arith == .mod) intMod(x, y) else intFloorDiv(x, y));
                        },
                        else => unreachable,
                    }
                    pc += 1;
                } else if (rb.isNumber() and rc.isNumber()) {
                    base[getA(i)] = .float(floatArith(arith, rb.asNumber(), rc.asNumber()));
                    pc += 1;
                }
                // Otherwise the next instruction, an MMBIN, handles it.
                continue :dispatch fetch(&pc, &i);
            },
            inline .bandk, .bork, .bxork, .shli, .shri, .band, .bor, .bxor, .shl, .shr => |o| {
                const rb = base[getB(i)];
                const rc = switch (o) {
                    .bandk, .bork, .bxork => k[getC(i)],
                    .shli, .shri => Value.int(opcodes.sc(i)),
                    else => base[getC(i)],
                };
                const x_opt = toIntStrict(rb);
                const y_opt = toIntStrict(rc);
                if (x_opt != null and y_opt != null) {
                    const x = x_opt.?;
                    const y = y_opt.?;
                    base[getA(i)] = .int(switch (o) {
                        .band, .bandk => x & y,
                        .bor, .bork => x | y,
                        .bxor, .bxork => x ^ y,
                        .shl => shiftLeft(x, y),
                        .shr, .shri => shiftLeft(x, 0 -% y),
                        .shli => shiftLeft(y, x),
                        else => unreachable,
                    });
                    pc += 1;
                }
                continue :dispatch fetch(&pc, &i);
            },
            .mmbin, .mmbini, .mmbink => {
                const ra = base[getA(i)];
                var rb: Value = switch (op(i)) {
                    .mmbin => base[getB(i)],
                    .mmbini => .int(opcodes.sb(i)),
                    else => k[getB(i)],
                };
                var first = ra;
                if (op(i) != .mmbin and getK(i)) {
                    first = rb;
                    rb = ra;
                }
                const event: Tm = @enumFromInt(getC(i));
                const dest = ci.base() + getA((pc - 2)[0]);
                ci.pc = pc;
                if (try arithSlow(th, ci, first, rb, event, dest)) {
                    ci = th.frame();
                    continue :newframe;
                }
                base = th.stack.ptr + ci.base();
                continue :dispatch fetch(&pc, &i);
            },
            .unm => {
                const rb = base[getB(i)];
                if (rb.tag == .int) {
                    base[getA(i)] = .int(0 -% rb.payload.int);
                } else if (rb.tag == .float) {
                    base[getA(i)] = .float(-rb.payload.float);
                } else {
                    ci.pc = pc;
                    if (try arithSlow(th, ci, rb, rb, .unm, ci.base() + getA(i))) {
                        ci = th.frame();
                        continue :newframe;
                    }
                    base = th.stack.ptr + ci.base();
                }
                continue :dispatch fetch(&pc, &i);
            },
            .bnot => {
                const rb = base[getB(i)];
                if (toIntStrict(rb)) |x| {
                    base[getA(i)] = .int(~x);
                } else {
                    ci.pc = pc;
                    if (try arithSlow(th, ci, rb, rb, .bnot, ci.base() + getA(i))) {
                        ci = th.frame();
                        continue :newframe;
                    }
                    base = th.stack.ptr + ci.base();
                }
                continue :dispatch fetch(&pc, &i);
            },
            .not => {
                base[getA(i)] = .boolean(base[getB(i)].isFalsy());
                continue :dispatch fetch(&pc, &i);
            },
            .len => {
                const rb = base[getB(i)];
                switch (rb.tag) {
                    .short_string, .long_string => base[getA(i)] = .int(@intCast(rb.asString().len)),
                    .table => if (th.state.fastTm(rb.asTable().metatable, .len) == null) {
                        base[getA(i)] = .int(@bitCast(rb.asTable().length()));
                        continue :dispatch fetch(&pc, &i);
                    } else {
                        ci.pc = pc;
                        if (try lenSlow(th, ci, rb, ci.base() + getA(i))) {
                            ci = th.frame();
                            continue :newframe;
                        }
                        base = th.stack.ptr + ci.base();
                    },
                    else => {
                        ci.pc = pc;
                        if (try lenSlow(th, ci, rb, ci.base() + getA(i))) {
                            ci = th.frame();
                            continue :newframe;
                        }
                        base = th.stack.ptr + ci.base();
                    },
                }
                continue :dispatch fetch(&pc, &i);
            },
            .concat => {
                ci.pc = pc;
                try concat(th, ci.base() + getA(i), getB(i));
                th.state.checkGc();
                base = th.stack.ptr + ci.base();
                continue :dispatch fetch(&pc, &i);
            },
            .close => {
                th.closeUpvals(ci.base() + getA(i));
                continue :dispatch fetch(&pc, &i);
            },
            .tbc => {
                ci.pc = pc;
                return th.runError("to-be-closed variables are not implemented yet", .{});
            },
            .jmp => {
                pc += @as(usize, @bitCast(@as(isize, opcodes.sj(i))));
                continue :dispatch fetch(&pc, &i);
            },
            inline .eq, .lt, .le => |o| {
                const ra = base[getA(i)];
                const rb = base[getB(i)];
                var cond: bool = undefined;
                if (ra.tag == .int and rb.tag == .int) {
                    cond = switch (o) {
                        .eq => ra.payload.int == rb.payload.int,
                        .lt => ra.payload.int < rb.payload.int,
                        else => ra.payload.int <= rb.payload.int,
                    };
                } else if (ra.isNumber() and rb.isNumber()) {
                    cond = switch (o) {
                        .eq => Value.rawEquals(ra, rb),
                        .lt => lessThanNum(ra, rb),
                        else => lessEqualNum(ra, rb),
                    };
                } else {
                    ci.pc = pc;
                    const r = switch (o) {
                        .eq => try equalSlow(th, ci, ra, rb),
                        .lt => try orderSlow(th, ci, ra, rb, .lt),
                        else => try orderSlow(th, ci, ra, rb, .le),
                    };
                    cond = r orelse {
                        ci = th.frame();
                        continue :newframe;
                    };
                    base = th.stack.ptr + ci.base();
                }
                if (cond != getK(i)) pc += 1 else pc += jumpOffset(pc[0]);
                continue :dispatch fetch(&pc, &i);
            },
            .eqk => {
                const cond = Value.rawEquals(base[getA(i)], k[getB(i)]);
                if (cond != getK(i)) pc += 1 else pc += jumpOffset(pc[0]);
                continue :dispatch fetch(&pc, &i);
            },
            inline .eqi, .lti, .lei, .gti, .gei => |o| {
                const ra = base[getA(i)];
                const im = opcodes.sb(i);
                var cond: bool = undefined;
                if (ra.tag == .int) {
                    const x = ra.payload.int;
                    cond = switch (o) {
                        .eqi => x == im,
                        .lti => x < im,
                        .lei => x <= im,
                        .gti => x > im,
                        else => x >= im,
                    };
                } else if (ra.tag == .float) {
                    const x = ra.payload.float;
                    const y: f64 = @floatFromInt(im);
                    cond = switch (o) {
                        .eqi => x == y,
                        .lti => x < y,
                        .lei => x <= y,
                        .gti => x > y,
                        else => x >= y,
                    };
                } else if (o == .eqi) {
                    cond = false;
                } else {
                    ci.pc = pc;
                    const imv: Value = if (getC(i) != 0) .float(@floatFromInt(im)) else .int(im);
                    const r = switch (o) {
                        .lti => try orderSlow(th, ci, ra, imv, .lt),
                        .lei => try orderSlow(th, ci, ra, imv, .le),
                        .gti => try orderSlow(th, ci, imv, ra, .lt),
                        else => try orderSlow(th, ci, imv, ra, .le),
                    };
                    cond = r orelse {
                        ci = th.frame();
                        continue :newframe;
                    };
                    base = th.stack.ptr + ci.base();
                }
                if (cond != getK(i)) pc += 1 else pc += jumpOffset(pc[0]);
                continue :dispatch fetch(&pc, &i);
            },
            .@"test" => {
                const cond = !base[getA(i)].isFalsy();
                if (cond != getK(i)) pc += 1 else pc += jumpOffset(pc[0]);
                continue :dispatch fetch(&pc, &i);
            },
            .testset => {
                const rb = base[getB(i)];
                if (rb.isFalsy() == getK(i)) {
                    pc += 1;
                } else {
                    base[getA(i)] = rb;
                    pc += jumpOffset(pc[0]);
                }
                continue :dispatch fetch(&pc, &i);
            },
            .call => {
                const func = ci.base() + getA(i);
                const b = getB(i);
                if (b != 0) th.top = func + b;
                ci.pc = pc;
                const nres = @as(i16, @intCast(getC(i))) - 1;
                const callee = th.stack[func];
                if (callee.tag == .lua_closure) {
                    try pushLuaFrame(th, func, callee.asLuaClosure().proto, nres);
                    ci = th.frame();
                    continue :newframe;
                }
                const lua = try preCall(th, func, nres);
                ci = th.frame();
                if (lua) continue :newframe;
                base = th.stack.ptr + ci.base();
                continue :dispatch fetch(&pc, &i);
            },
            .tailcall => {
                const func = ci.base() + getA(i);
                const b = getB(i);
                if (b != 0) th.top = func + b;
                const nparams1 = getC(i);
                const delta: u32 = if (nparams1 != 0) ci.extra_args + nparams1 else 0;
                ci.pc = pc;
                if (getK(i)) th.closeUpvals(ci.base());
                // Resolve `__call` in place, before moving down.
                while (!th.stack[func].isFunction()) {
                    const f = th.stack[func];
                    const h = th.state.tmOf(f, .call) orelse return typeError(th, f, "call");
                    try th.ensureStack(1);
                    @memmove(th.stack[func + 1 .. th.top + 1], th.stack[func..th.top]);
                    th.top += 1;
                    th.stack[func] = h;
                }
                if (th.stack[func].tag == .lua_closure) {
                    const p = th.stack[func].asLuaClosure().proto;
                    const nargs = th.top - func - 1;
                    const dest = ci.func - delta;
                    const fsize: u32 = p.maxstacksize;
                    try th.growStack(@as(usize, dest) + 1 + @max(fsize, nargs));
                    for (0..nargs + 1) |j| th.stack[dest + j] = th.stack[func + j];
                    var n = nargs;
                    while (n < p.numparams) : (n += 1) th.stack[dest + 1 + n] = .nil;
                    th.top = dest + 1 + n;
                    ci.func = dest;
                    ci.top = dest + 1 + fsize;
                    ci.pc = p.code.ptr;
                    ci.extra_args = 0;
                    continue :newframe;
                }
                // A native function: call it where it is, then return its
                // results from this frame.
                const callee = th.stack[func];
                const f = if (callee.tag == .native_fn) callee.asNative() else callee.asNativeClosure().f;
                try callNative(th, func, -1, f);
                ci = th.frame();
                ci.func -= delta;
                if (try doReturn(th, func, th.top - func)) return;
                ci = th.frame();
                continue :newframe;
            },
            .@"return" => {
                const first = ci.base() + getA(i);
                const n: u32 = if (getB(i) != 0) getB(i) - 1 else th.top - first;
                ci.pc = pc;
                if (getK(i)) th.closeUpvals(ci.base());
                if (getC(i) != 0) ci.func -= ci.extra_args + getC(i);
                if (try doReturn(th, first, n)) return;
                ci = th.frame();
                continue :newframe;
            },
            .return0 => {
                if (try doReturn(th, ci.base() + getA(i), 0)) return;
                ci = th.frame();
                continue :newframe;
            },
            .return1 => {
                if (try doReturn(th, ci.base() + getA(i), 1)) return;
                ci = th.frame();
                continue :newframe;
            },
            .forloop => {
                const a = getA(i);
                if (base[a + 2].tag == .int) {
                    const count: u64 = @bitCast(base[a].payload.int);
                    if (count > 0) {
                        base[a].payload.int = @bitCast(count - 1);
                        base[a + 2].payload.int +%= base[a + 1].payload.int;
                        pc -= opcodes.bx(i);
                    }
                } else {
                    const step = base[a + 1].payload.float;
                    const limit = base[a].payload.float;
                    const idx = base[a + 2].payload.float + step;
                    if (if (step > 0) idx <= limit else limit <= idx) {
                        base[a + 2].payload.float = idx;
                        pc -= opcodes.bx(i);
                    }
                }
                continue :dispatch fetch(&pc, &i);
            },
            .forprep => {
                ci.pc = pc;
                if (try forPrep(th, base + getA(i))) pc += @as(usize, opcodes.bx(i)) + 1;
                continue :dispatch fetch(&pc, &i);
            },
            .tforprep => {
                const a = getA(i);
                const closing = base[a + 3];
                base[a + 3] = base[a + 2];
                base[a + 2] = closing;
                if (!closing.isFalsy()) {
                    ci.pc = pc;
                    return th.runError("to-be-closed variables are not implemented yet", .{});
                }
                pc += opcodes.bx(i);
                continue :dispatch fetch(&pc, &i);
            },
            .tforcall => {
                const a = getA(i);
                base[a + 5] = base[a + 3];
                base[a + 4] = base[a + 1];
                base[a + 3] = base[a];
                const func = ci.base() + a + 3;
                th.top = func + 3;
                ci.pc = pc;
                const lua = try preCall(th, func, @intCast(getC(i)));
                ci = th.frame();
                if (lua) continue :newframe;
                base = th.stack.ptr + ci.base();
                continue :dispatch fetch(&pc, &i);
            },
            .tforloop => {
                if (!base[getA(i) + 3].isNil()) pc -= opcodes.bx(i);
                continue :dispatch fetch(&pc, &i);
            },
            .setlist => {
                const a = getA(i);
                var n: u32 = opcodes.vb(i);
                var last: u32 = opcodes.vc(i);
                const t = base[a].asTable();
                if (n == 0) n = th.top - (ci.base() + a) - 1 else th.top = ci.top;
                last += n;
                if (getK(i)) {
                    last += @as(u32, opcodes.ax(pc[0])) * (opcodes.max_vc + 1);
                    pc += 1;
                }
                if (last > t.asize) try t.resize(heap, last, if (t.isDummy()) 0 else t.nodeCount());
                while (n > 0) : (n -= 1) {
                    try t.setInt(heap, last, base[a + n]);
                    last -= 1;
                }
                continue :dispatch fetch(&pc, &i);
            },
            .closure => {
                const p = cl.proto.p[opcodes.bx(i)];
                const ncl = try LuaClosure.create(heap, p, @intCast(p.upvalues.len));
                for (p.upvalues, 0..) |u, j| {
                    const uv = if (u.instack) try th.findUpval(ci.base() + u.idx) else cl.upvals()[u.idx];
                    ncl.setUpval(heap, j, uv);
                }
                base[getA(i)] = .luaClosure(ncl);
                ci.pc = pc;
                th.state.checkGc();
                continue :dispatch fetch(&pc, &i);
            },
            .vararg => {
                ci.pc = pc;
                if (getK(i)) return th.runError("vararg tables are not implemented yet", .{});
                const dest = ci.base() + getA(i);
                const nargs = ci.extra_args;
                var wanted: i32 = @as(i32, @intCast(getC(i))) - 1;
                if (wanted < 0) {
                    wanted = @intCast(nargs);
                    try th.growStack(@as(usize, dest) + nargs);
                    th.top = dest + nargs;
                }
                const w: u32 = @intCast(wanted);
                const use = @min(w, nargs);
                for (0..use) |j| th.stack[dest + j] = th.stack[ci.func - nargs + j];
                for (use..w) |j| th.stack[dest + j] = .nil;
                base = th.stack.ptr + ci.base();
                continue :dispatch fetch(&pc, &i);
            },
            .getvarg => {
                const rc = base[getC(i)];
                const nextra = ci.extra_args;
                var result: Value = .nil;
                const key: ?i64 = switch (rc.tag) {
                    .int => rc.payload.int,
                    .float => Value.floatToInt(rc.payload.float),
                    else => null,
                };
                if (key) |n| {
                    const u: u64 = @bitCast(n -% 1);
                    if (u < nextra) result = th.stack[ci.func - nextra + @as(u32, @intCast(u))];
                } else if (rc.isString() and std.mem.eql(u8, rc.asString().bytes(), "n")) {
                    result = .int(nextra);
                }
                base[getA(i)] = result;
                continue :dispatch fetch(&pc, &i);
            },
            .errnnil => {
                if (!base[getA(i)].isNil()) {
                    ci.pc = pc;
                    const bx = opcodes.bx(i);
                    const name = if (bx > 0 and k[bx - 1].isString()) k[bx - 1].asString().bytes() else "?";
                    return th.runError("global '{s}' already defined", .{name});
                }
                continue :dispatch fetch(&pc, &i);
            },
            .varargprep => {
                ci.pc = pc;
                try adjustVarargs(th, ci, cl.proto);
                base = th.stack.ptr + ci.base();
                continue :dispatch fetch(&pc, &i);
            },
            .extraarg => unreachable,
        }
    }
}

/// The offset `pc` moves by to take the jump instruction `j` that follows a
/// test, counting the jump itself.
inline fn jumpOffset(j: Instruction) usize {
    return @bitCast(@as(isize, opcodes.sj(j)) + 1);
}

/// Returns from the running Lua frame with `n` results at `first`. True
/// when the frame was the fresh one and the loop must exit.
inline fn doReturn(th: *Thread, first: u32, n: u32) Error!bool {
    const ret = th.frame();
    moveResults(th, ret.func, first, n, ret.nresults);
    const flags = ret.flags;
    th.frames.items.len -= 1;
    if (flags.fresh) return true;
    if (flags.finish_op) try finishOp(th, th.frame());
    return false;
}

/// Completes the instruction of Lua frame `ci` that a Lua metamethod
/// interrupted, with the metamethod's one result at `top - 1`. The
/// interrupted instruction is the one before `ci.pc`.
fn finishOp(th: *Thread, ci: *Frame) Error!void {
    const inst = (ci.pc - 1)[0];
    const base = ci.base();
    switch (op(inst)) {
        .mmbin, .mmbini, .mmbink => {
            th.top -= 1;
            th.stack[base + getA((ci.pc - 2)[0])] = th.stack[th.top];
        },
        .unm, .bnot, .len, .gettabup, .gettable, .geti, .getfield, .self => {
            th.top -= 1;
            th.stack[base + getA(inst)] = th.stack[th.top];
        },
        .eq, .lt, .le, .lti, .lei, .gti, .gei => {
            th.top -= 1;
            const res = !th.stack[th.top].isFalsy();
            // The next instruction is the jump; skip it when the condition
            // failed.
            if (res != getK(inst)) ci.pc += 1;
        },
        .settabup, .settable, .seti, .setfield => {},
        else => unreachable,
    }
    th.top = ci.top;
}

/// Calls metamethod `f` with two arguments for one result, above the Lua
/// frame `ci`. A native handler runs now and its result is returned. A Lua
/// handler gets a frame flagged `finish_op` and the result is null.
fn callTm(th: *Thread, ci: *Frame, f: Value, a1: Value, a2: Value) Error!?Value {
    return callTm3(th, ci, f, a1, a2, null, 1);
}

fn callTm3(th: *Thread, ci: *Frame, f: Value, a1: Value, a2: Value, a3: ?Value, nresults: i16) Error!?Value {
    th.top = ci.top;
    const func = th.top;
    th.push(f);
    th.push(a1);
    th.push(a2);
    if (a3) |v| th.push(v);
    if (try preCall(th, func, nresults)) {
        th.frame().flags.finish_op = true;
        return null;
    }
    const r = if (nresults > 0) th.stack[func] else Value.nil;
    th.top = th.frame().top;
    return r;
}

/// `t[key]` with `__index`, into stack slot `dest`. True when a Lua
/// metamethod frame was pushed.
fn getSlow(th: *Thread, ci: *Frame, t_in: Value, key: Value, dest: u32) Error!bool {
    var t = t_in;
    for (0..max_tag_loop) |_| {
        var h: Value = undefined;
        if (t.tag == .table) {
            const tbl = t.asTable();
            const v = tbl.get(key);
            if (!v.isNil()) {
                th.stack[dest] = v;
                return false;
            }
            h = th.state.fastTm(tbl.metatable, .index) orelse {
                th.stack[dest] = .nil;
                return false;
            };
        } else {
            h = th.state.tmOf(t, .index) orelse return typeError(th, t, "index");
        }
        if (h.isFunction()) {
            const r = try callTm(th, ci, h, t, key) orelse return true;
            th.stack[dest] = r;
            return false;
        }
        t = h;
    }
    return th.runError("'__index' chain too long; possible loop", .{});
}

/// `t[key] = v` with `__newindex`. True when a Lua metamethod frame was
/// pushed.
fn setSlow(th: *Thread, ci: *Frame, t_in: Value, key: Value, v: Value) Error!bool {
    var t = t_in;
    for (0..max_tag_loop) |_| {
        var h: Value = undefined;
        if (t.tag == .table) {
            const tbl = t.asTable();
            const present = !tbl.get(key).isNil();
            if (present) {
                tbl.set(th.heap(), key, v) catch |e| return setError(th, e);
                return false;
            }
            h = th.state.fastTm(tbl.metatable, .newindex) orelse {
                tbl.set(th.heap(), key, v) catch |e| return setError(th, e);
                return false;
            };
        } else {
            h = th.state.tmOf(t, .newindex) orelse return typeError(th, t, "index");
        }
        if (h.isFunction()) {
            _ = try callTm3(th, ci, h, t, key, v, 0) orelse return true;
            return false;
        }
        t = h;
    }
    return th.runError("'__newindex' chain too long; possible loop", .{});
}

fn setError(th: *Thread, e: Table.SetError) Error {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.IndexIsNil => th.runError("index is nil", .{}),
        error.IndexIsNaN => th.runError("index is NaN", .{}),
    };
}

/// A binary or unary metamethod for `event` over `a` and `b`, into `dest`,
/// or the error the manual gives when neither operand has one.
fn arithSlow(th: *Thread, ci: *Frame, a: Value, b: Value, event: Tm, dest: u32) Error!bool {
    const h = th.state.tmOf(a, event) orelse th.state.tmOf(b, event) orelse {
        switch (event) {
            .band, .bor, .bxor, .shl, .shr, .bnot => {
                if (a.isNumber() and b.isNumber()) return th.runError("number has no integer representation", .{});
                return typeError(th, if (a.isNumber()) b else a, "perform bitwise operation on");
            },
            .concat => return typeError(th, if (a.isString() or a.isNumber()) b else a, "concatenate"),
            else => return typeError(th, if (a.isNumber()) b else a, "perform arithmetic on"),
        }
    };
    const r = try callTm(th, ci, h, a, b) orelse return true;
    th.stack[dest] = r;
    return false;
}

fn lenSlow(th: *Thread, ci: *Frame, v: Value, dest: u32) Error!bool {
    const h = th.state.tmOf(v, .len) orelse {
        if (v.tag == .table) {
            th.stack[dest] = .int(@bitCast(v.asTable().length()));
            return false;
        }
        return typeError(th, v, "get length of");
    };
    const r = try callTm(th, ci, h, v, v) orelse return true;
    th.stack[dest] = r;
    return false;
}

/// `a == b` for operands not both numbers; null when a Lua `__eq` frame
/// was pushed.
fn equalSlow(th: *Thread, ci: *Frame, a: Value, b: Value) Error!?bool {
    if (Value.rawEquals(a, b)) return true;
    if (a.tag != b.tag or (a.tag != .table and a.tag != .userdata)) return false;
    const h = th.state.fastTm(th.state.metatableOf(a), .eq) orelse
        th.state.fastTm(th.state.metatableOf(b), .eq) orelse return false;
    const r = try callTm(th, ci, h, a, b) orelse return null;
    return !r.isFalsy();
}

/// `a < b` or `a <= b` for operands not both numbers; null when a Lua
/// metamethod frame was pushed.
fn orderSlow(th: *Thread, ci: *Frame, a: Value, b: Value, event: Tm) Error!?bool {
    if (a.isNumber() and b.isNumber()) return if (event == .lt) lessThanNum(a, b) else lessEqualNum(a, b);
    if (a.isString() and b.isString()) {
        const ord = std.mem.order(u8, a.asString().bytes(), b.asString().bytes());
        return if (event == .lt) ord == .lt else ord != .gt;
    }
    const h = th.state.tmOf(a, event) orelse th.state.tmOf(b, event) orelse {
        const ta = a.typeOf().name();
        const tb = b.typeOf().name();
        if (std.mem.eql(u8, ta, tb)) return th.runError("attempt to compare two {s} values", .{ta});
        return th.runError("attempt to compare {s} with {s}", .{ ta, tb });
    };
    const r = try callTm(th, ci, h, a, b) orelse return null;
    return !r.isFalsy();
}

fn typeError(th: *Thread, v: Value, comptime what: []const u8) Error {
    // TODO(wave 2): name the variable, as PUC-Rio's varinfo does.
    return th.runError("attempt to " ++ what ++ " a {s} value", .{v.typeOf().name()});
}

/// R[a] := R[a] .. ... .. R[a+n-1], for strings and numbers.
/// TODO(wave 2): `__concat`, finished through `finishOp`.
fn concat(th: *Thread, first: u32, n: u32) Error!void {
    const vals = th.stack[first .. first + n];
    var total: usize = 0;
    var numbuf: [64]u8 = undefined;
    for (vals) |v| {
        if (v.isString()) {
            total += v.asString().len;
        } else if (v.isNumber()) {
            total += numberToString(v, &numbuf).len;
        } else {
            for (vals) |w| if (!w.isString() and !w.isNumber()) return typeError(th, w, "concatenate");
        }
    }
    const state = th.state;
    if (total <= String.max_short_len) {
        var buf: [String.max_short_len]u8 = undefined;
        var len: usize = 0;
        for (vals) |v| {
            const s = if (v.isString()) v.asString().bytes() else numberToString(v, &numbuf);
            @memcpy(buf[len..][0..s.len], s);
            len += s.len;
        }
        th.stack[first] = .string(try state.newString(buf[0..len]));
        return;
    }
    const out = try String.createLong(&state.heap, state.seed, total);
    const bytes = out.mutableBytes();
    var len: usize = 0;
    for (vals) |v| {
        const s = if (v.isString()) v.asString().bytes() else numberToString(v, &numbuf);
        @memcpy(bytes[len..][0..s.len], s);
        len += s.len;
    }
    th.stack[first] = .string(out);
}

/// Adjusts a vararg call (`VARARGPREP`): copies the function and fixed
/// parameters above the extra arguments, so the extra arguments sit below
/// the frame, and nils the vararg parameter.
fn adjustVarargs(th: *Thread, ci: *Frame, p: *const Proto) Error!void {
    if (p.flags.vararg_table) return th.runError("vararg tables are not implemented yet", .{});
    const nfix = p.numparams;
    const total = th.top - ci.func - 1;
    const nextra = total - nfix;
    ci.extra_args = nextra;
    try th.growStack(@as(usize, th.top) + p.maxstacksize + 1);
    th.push(th.stack[ci.func]);
    for (1..@as(usize, nfix) + 1) |j| {
        th.push(th.stack[ci.func + j]);
        th.stack[ci.func + j] = .nil;
    }
    ci.func += total + 1;
    ci.top += total + 1;
    th.stack[ci.func + nfix + 1] = .nil;
}

/// Prepares a numeric for loop at `ra` (`FORPREP`). True when the loop
/// runs zero times.
fn forPrep(th: *Thread, ra: [*]Value) Error!bool {
    const init = ra[0];
    const limit = ra[1];
    const step = ra[2];
    if (init.tag == .int and step.tag == .int) {
        const start = init.payload.int;
        const s = step.payload.int;
        if (s == 0) return th.runError("'for' step is zero", .{});
        var lim: i64 = undefined;
        if (limit.tag == .int) {
            lim = limit.payload.int;
        } else if (limit.tag == .float) {
            const f = limit.payload.float;
            if (floatToIntMode(f, if (s < 0) .ceil else .floor)) |l| {
                lim = l;
            } else if (std.math.isNan(f)) {
                return true;
            } else if (f > 0) {
                if (s < 0) return true;
                lim = std.math.maxInt(i64);
            } else {
                if (s > 0) return true;
                lim = std.math.minInt(i64);
            }
        } else {
            return forError(th, limit, "limit");
        }
        if (if (s > 0) start > lim else start < lim) return true;
        var count: u64 = undefined;
        if (s > 0) {
            count = @as(u64, @bitCast(lim)) -% @as(u64, @bitCast(start));
            if (s != 1) count /= @as(u64, @bitCast(s));
        } else {
            count = @as(u64, @bitCast(start)) -% @as(u64, @bitCast(lim));
            count /= @as(u64, @bitCast(-(s + 1))) + 1;
        }
        ra[0] = .int(@bitCast(count));
        ra[1] = .int(s);
        ra[2] = .int(start);
        return false;
    }
    if (!limit.isNumber()) return forError(th, limit, "limit");
    if (!step.isNumber()) return forError(th, step, "step");
    if (!init.isNumber()) return forError(th, init, "initial value");
    const fl = limit.asNumber();
    const fs = step.asNumber();
    const fi = init.asNumber();
    if (fs == 0) return th.runError("'for' step is zero", .{});
    if (if (0 < fs) fl < fi else fi < fl) return true;
    ra[0] = .float(fl);
    ra[1] = .float(fs);
    ra[2] = .float(fi);
    return false;
}

fn forError(th: *Thread, v: Value, comptime what: []const u8) Error {
    return th.runError("bad 'for' " ++ what ++ " (number expected, got {s})", .{v.typeOf().name()});
}

// Numbers. TODO(number.zig): replace these with number.zig's helpers once
// that lands; they follow the manual's §3.4 but are minimal.

const Arith = enum {
    add,
    sub,
    mul,
    mod,
    pow,
    div,
    idiv,

    fn intOp(a: Arith) bool {
        return a != .pow and a != .div;
    }
};

fn arithOf(comptime o: opcodes.OpCode) Arith {
    return switch (o) {
        .addi, .addk, .add => .add,
        .subk, .sub => .sub,
        .mulk, .mul => .mul,
        .modk, .mod => .mod,
        .powk, .pow => .pow,
        .divk, .div => .div,
        .idivk, .idiv => .idiv,
        else => unreachable,
    };
}

inline fn floatArith(a: Arith, x: f64, y: f64) f64 {
    return switch (a) {
        .add => x + y,
        .sub => x - y,
        .mul => x * y,
        .div => x / y,
        .pow => if (y == 2) x * x else std.math.pow(f64, x, y),
        .idiv => @floor(x / y),
        .mod => floatMod(x, y),
    };
}

/// Lua's float modulo: the result has the divisor's sign.
fn floatMod(x: f64, y: f64) f64 {
    const m = @rem(x, y);
    if (if (m > 0) y < 0 else (m < 0 and y != m)) return m + y;
    return m;
}

/// Floor division; `y` is not zero.
fn intFloorDiv(x: i64, y: i64) i64 {
    if (y == -1) return 0 -% x;
    var q = @divTrunc(x, y);
    if (@rem(x, y) != 0 and (x ^ y) < 0) q -= 1;
    return q;
}

/// Modulo with the divisor's sign; `y` is not zero.
fn intMod(x: i64, y: i64) i64 {
    if (y == -1) return 0;
    const r = @rem(x, y);
    return if (r != 0 and (r ^ y) < 0) r + y else r;
}

/// `x << y`, logical, with negative `y` shifting right; 64 or more shifts
/// everything out.
fn shiftLeft(x: i64, y: i64) i64 {
    const ux: u64 = @bitCast(x);
    if (y <= -64 or y >= 64) return 0;
    if (y >= 0) return @bitCast(ux << @intCast(y));
    return @bitCast(ux >> @intCast(-y));
}

/// An integer, or a float with an exact integer value, as an integer.
inline fn toIntStrict(v: Value) ?i64 {
    return switch (v.tag) {
        .int => v.payload.int,
        .float => Value.floatToInt(v.payload.float),
        else => null,
    };
}

const Rounding = enum { floor, ceil };

fn floatToIntMode(f: f64, mode: Rounding) ?i64 {
    return Value.floatToInt(switch (mode) {
        .floor => @floor(f),
        .ceil => @ceil(f),
    });
}

/// Whether an integer converts to a float exactly (|i| <= 2^53).
inline fn intFitsFloat(i: i64) bool {
    const m: u64 = 1 << 53;
    return @as(u64, @bitCast(i)) +% m <= 2 * m;
}

fn lessThanNum(a: Value, b: Value) bool {
    if (a.tag == .int and b.tag == .int) return a.payload.int < b.payload.int;
    if (a.tag == .float and b.tag == .float) return a.payload.float < b.payload.float;
    if (a.tag == .int) {
        const i = a.payload.int;
        const f = b.payload.float;
        if (intFitsFloat(i)) return @as(f64, @floatFromInt(i)) < f;
        if (floatToIntMode(f, .ceil)) |c| return i < c;
        return f > 0;
    }
    const f = a.payload.float;
    const i = b.payload.int;
    if (intFitsFloat(i)) return f < @as(f64, @floatFromInt(i));
    if (floatToIntMode(f, .floor)) |fl| return fl < i;
    return f < 0;
}

fn lessEqualNum(a: Value, b: Value) bool {
    if (a.tag == .int and b.tag == .int) return a.payload.int <= b.payload.int;
    if (a.tag == .float and b.tag == .float) return a.payload.float <= b.payload.float;
    if (a.tag == .int) {
        const i = a.payload.int;
        const f = b.payload.float;
        if (intFitsFloat(i)) return @as(f64, @floatFromInt(i)) <= f;
        if (floatToIntMode(f, .floor)) |fl| return i <= fl;
        return f > 0;
    }
    const f = a.payload.float;
    const i = b.payload.int;
    if (intFitsFloat(i)) return f <= @as(f64, @floatFromInt(i));
    if (floatToIntMode(f, .ceil)) |c| return c <= i;
    return f < 0;
}

/// A number as `tostring` writes it. Floats use the shortest form that
/// reads back exactly, with ".0" on integral values; PUC-Rio's exponent
/// formatting differs ("1e+100").
fn numberToString(v: Value, buf: *[64]u8) []const u8 {
    if (v.tag == .int) return std.fmt.bufPrint(buf, "{d}", .{v.payload.int}) catch unreachable;
    const f = v.payload.float;
    if (std.math.isNan(f)) return if (std.math.signbit(f)) "-nan" else "nan";
    if (std.math.isInf(f)) return if (f > 0) "inf" else "-inf";
    const s = std.fmt.bufPrint(buf, "{d}", .{f}) catch unreachable;
    if (std.mem.findAny(u8, s, ".eEn") == null) {
        buf[s.len] = '.';
        buf[s.len + 1] = '0';
        return buf[0 .. s.len + 2];
    }
    return s;
}

// Tests: hand-assembled programs, each transcribed from `luac -l -l` (Lua
// 5.5.1) on the Lua source in its comment, with the reference `lua`'s
// output as the expected results. Each runs twice: normally, and with the
// collector running at every safe point.

const testing = std.testing;

fn abc(o: opcodes.OpCode, a: u8, b: u8, c: u8) u32 {
    return opcodes.abc(o, a, b, c, false);
}

fn abck(o: opcodes.OpCode, a: u8, b: u8, c: u8) u32 {
    return opcodes.abc(o, a, b, c, true);
}

fn asbx(o: opcodes.OpCode, a: u8, sbx: i32) u32 {
    return opcodes.asbx(o, a, sbx);
}

fn abx(o: opcodes.OpCode, a: u8, bx: u17) u32 {
    return opcodes.abx(o, a, bx);
}

fn jmp(sj: i32) u32 {
    return opcodes.isj(.jmp, sj);
}

const sC = opcodes.int2sc;

const ProtoSpec = struct {
    code: []const u32,
    k: []const Value = &.{},
    p: []const *Proto = &.{},
    upvalues: []const Proto.UpvalDesc = &.{},
    lineinfo: []const u32 = &.{},
    numparams: u8 = 0,
    vararg: bool = false,
    maxstack: u8,
};

const env_upval: Proto.UpvalDesc = .{ .instack = true, .idx = 0 };

fn makeProto(state: *State, s: ProtoSpec) !*Proto {
    const p = try Proto.create(&state.heap);
    const a = state.heap.allocator();
    p.code = try a.dupe(u32, s.code);
    p.k = try a.dupe(Value, s.k);
    p.p = try a.dupe(*Proto, s.p);
    p.upvalues = try a.dupe(Proto.UpvalDesc, s.upvalues);
    p.lineinfo = try a.dupe(u32, s.lineinfo);
    p.numparams = s.numparams;
    p.flags.vararg = s.vararg;
    p.maxstacksize = s.maxstack;
    return p;
}

/// Runs a main chunk and returns its results, which stay on the main
/// thread's stack until the next run.
fn run(state: *State, p: *Proto) ![]Value {
    const th = state.main;
    const cl = try mainClosure(state, p);
    try th.ensureStack(1);
    const func = th.top;
    th.push(.luaClosure(cl));
    try call(th, func, -1);
    return th.stack[func..th.top];
}

fn newState(stress: bool) !*State {
    const state = try State.create(testing.allocator, .{});
    if (stress) {
        state.heap.stress = true;
        state.heap.threshold = 0;
    }
    return state;
}

fn str(state: *State, b: []const u8) !Value {
    return .string(try state.newString(b));
}

fn expectInts(expected: []const i64, got: []const Value) !void {
    try testing.expectEqual(expected.len, got.len);
    for (expected, got) |e, g| try testing.expectEqual(e, g.asInt());
}

test "fib(20) through recursive Lua calls" {
    // local function fib(n) if n < 2 then return n end return fib(n-1) + fib(n-2) end
    // return fib(20)
    for ([_]bool{ false, true }) |stress| {
        const state = try newState(stress);
        defer state.destroy();
        const fib = try makeProto(state, .{
            .numparams = 1,
            .maxstack = 4,
            .upvalues = &.{.{ .instack = true, .idx = 0 }},
            .code = &.{
                abc(.lti, 0, sC(2), 0),
                jmp(1),
                abc(.return1, 0, 0, 0),
                abc(.getupval, 1, 0, 0),
                abc(.addi, 2, 0, sC(-1)),
                abc(.mmbini, 0, sC(1), 7),
                abc(.call, 1, 2, 2),
                abc(.getupval, 2, 0, 0),
                abc(.addi, 3, 0, sC(-2)),
                abc(.mmbini, 0, sC(2), 7),
                abc(.call, 2, 2, 2),
                abc(.add, 1, 1, 2),
                abc(.mmbin, 1, 2, 6),
                abc(.return1, 1, 0, 0),
                abc(.return0, 0, 0, 0),
            },
        });
        const main = try makeProto(state, .{
            .vararg = true,
            .maxstack = 3,
            .upvalues = &.{env_upval},
            .p = &.{fib},
            .code = &.{
                abc(.varargprep, 0, 0, 0),
                abx(.closure, 0, 0),
                abc(.move, 1, 0, 0),
                asbx(.loadi, 2, 20),
                abck(.tailcall, 1, 2, 1),
                abck(.@"return", 1, 0, 1),
                abck(.@"return", 1, 1, 1),
            },
        });
        try expectInts(&.{6765}, try run(state, main));
        // The tail call left nothing behind.
        try testing.expectEqual(@as(usize, 1), state.main.frames.items.len);
        try testing.expect(state.main.open_upvals == null);
    }
}

test "closure counters keep independent upvalues" {
    // local function counter() local c = 0 return function() c = c + 1 return c end end
    // local f = counter()
    // f() f()
    // local g = counter()
    // g()
    // return f(), g()
    for ([_]bool{ false, true }) |stress| {
        const state = try newState(stress);
        defer state.destroy();
        const inc = try makeProto(state, .{
            .maxstack = 2,
            .upvalues = &.{.{ .instack = true, .idx = 0 }},
            .code = &.{
                abc(.getupval, 0, 0, 0),
                abc(.addi, 0, 0, sC(1)),
                abc(.mmbini, 0, sC(1), 6),
                abc(.setupval, 0, 0, 0),
                abc(.getupval, 0, 0, 0),
                abc(.return1, 0, 0, 0),
                abc(.return0, 0, 0, 0),
            },
        });
        const counter = try makeProto(state, .{
            .maxstack = 2,
            .p = &.{inc},
            .code = &.{
                asbx(.loadi, 0, 0),
                abx(.closure, 1, 0),
                abck(.@"return", 1, 2, 0),
                abck(.@"return", 1, 1, 0),
            },
        });
        const main = try makeProto(state, .{
            .vararg = true,
            .maxstack = 5,
            .upvalues = &.{env_upval},
            .p = &.{counter},
            .code = &.{
                abc(.varargprep, 0, 0, 0),
                abx(.closure, 0, 0),
                abc(.move, 1, 0, 0),
                abc(.call, 1, 1, 2),
                abc(.move, 2, 1, 0),
                abc(.call, 2, 1, 1),
                abc(.move, 2, 1, 0),
                abc(.call, 2, 1, 1),
                abc(.move, 2, 0, 0),
                abc(.call, 2, 1, 2),
                abc(.move, 3, 2, 0),
                abc(.call, 3, 1, 1),
                abc(.move, 3, 1, 0),
                abc(.call, 3, 1, 2),
                abc(.move, 4, 2, 0),
                abc(.call, 4, 1, 0),
                abc(.@"return", 3, 0, 1),
                abc(.@"return", 3, 1, 1),
            },
        });
        try expectInts(&.{ 3, 2 }, try run(state, main));
    }
}

test "numeric for loops: integer, float, and descending" {
    // local s = 0
    // for i = 1, 100 do s = s + i end
    // local f = 0.0
    // for x = 1, 2, 0.25 do f = f + x end
    // local n = 0
    // for i = 10, 1, -3 do n = n + i end
    // return s, f, n          --> 5050  7.5  22
    const state = try newState(false);
    defer state.destroy();
    const main = try makeProto(state, .{
        .vararg = true,
        .maxstack = 6,
        .upvalues = &.{env_upval},
        .k = &.{.float(0.25)},
        .code = &.{
            abc(.varargprep, 0, 0, 0),
            asbx(.loadi, 0, 0),
            asbx(.loadi, 1, 1),
            asbx(.loadi, 2, 100),
            asbx(.loadi, 3, 1),
            abx(.forprep, 1, 2),
            abc(.add, 0, 0, 3),
            abc(.mmbin, 0, 3, 6),
            abx(.forloop, 1, 3),
            asbx(.loadf, 1, 0),
            asbx(.loadi, 2, 1),
            asbx(.loadi, 3, 2),
            abx(.loadk, 4, 0),
            abx(.forprep, 2, 2),
            abc(.add, 1, 1, 4),
            abc(.mmbin, 1, 4, 6),
            abx(.forloop, 2, 3),
            asbx(.loadi, 2, 0),
            asbx(.loadi, 3, 10),
            asbx(.loadi, 4, 1),
            asbx(.loadi, 5, -3),
            abx(.forprep, 3, 2),
            abc(.add, 2, 2, 5),
            abc(.mmbin, 2, 5, 6),
            abx(.forloop, 3, 3),
            abc(.move, 3, 0, 0),
            abc(.move, 4, 1, 0),
            abc(.move, 5, 2, 0),
            abc(.@"return", 3, 4, 1),
            abc(.@"return", 3, 1, 1),
        },
    });
    const r = try run(state, main);
    try testing.expectEqual(@as(usize, 3), r.len);
    try testing.expectEqual(@as(i64, 5050), r[0].asInt());
    try testing.expectEqual(@as(f64, 7.5), r[1].asFloat());
    try testing.expectEqual(@as(i64, 22), r[2].asInt());
}

test "for loop edge cases: overflow-free counts, empty ranges, float limits" {
    // for i = math.maxinteger - 2, math.maxinteger do n = n + 1 end  --> 3 iterations
    // for i = 1, 0 do n = n + 100 end                                --> none
    // for i = 1, 3.5 do n = n + 10 end                               --> 3 iterations
    // return n                                                       --> 33
    const state = try newState(false);
    defer state.destroy();
    const main = try makeProto(state, .{
        .maxstack = 5,
        .k = &.{ .int(std.math.maxInt(i64) - 2), .int(std.math.maxInt(i64)), .float(3.5) },
        .code = &.{
            asbx(.loadi, 0, 0),
            abx(.loadk, 1, 0),
            abx(.loadk, 2, 1),
            asbx(.loadi, 3, 1),
            abx(.forprep, 1, 2),
            abc(.addi, 0, 0, sC(1)),
            abc(.mmbini, 0, sC(1), 6),
            abx(.forloop, 1, 3),
            asbx(.loadi, 1, 1),
            asbx(.loadi, 2, 0),
            asbx(.loadi, 3, 1),
            abx(.forprep, 1, 2),
            abc(.addi, 0, 0, sC(100)),
            abc(.mmbini, 0, sC(100), 6),
            abx(.forloop, 1, 3),
            asbx(.loadi, 1, 1),
            abx(.loadk, 2, 2),
            asbx(.loadi, 3, 1),
            abx(.forprep, 1, 2),
            abc(.addi, 0, 0, sC(10)),
            abc(.mmbini, 0, sC(10), 6),
            abx(.forloop, 1, 3),
            abc(.return1, 0, 0, 0),
        },
    });
    try expectInts(&.{33}, try run(state, main));
}

test "table fill, length, field, and missing index" {
    // local t = {}
    // for i = 1, 100 do t[i] = i * 2 end
    // t.name = "x"
    // local s = 0
    // for i = 1, #t do s = s + t[i] end
    // return s, #t, t.name, t[101]   --> 10100  100  x  nil
    for ([_]bool{ false, true }) |stress| {
        const state = try newState(stress);
        defer state.destroy();
        const main = try makeProto(state, .{
            .vararg = true,
            .maxstack = 6,
            .upvalues = &.{env_upval},
            .k = &.{ .int(2), try str(state, "name"), try str(state, "x") },
            .code = &.{
                abc(.varargprep, 0, 0, 0),
                opcodes.vabc(.newtable, 0, 0, 0, false),
                opcodes.iax(.extraarg, 0),
                asbx(.loadi, 1, 1),
                asbx(.loadi, 2, 100),
                asbx(.loadi, 3, 1),
                abx(.forprep, 1, 3),
                abc(.mulk, 4, 3, 0),
                abc(.mmbink, 3, 0, 8),
                abc(.settable, 0, 3, 4),
                abx(.forloop, 1, 4),
                abck(.setfield, 0, 1, 2),
                asbx(.loadi, 1, 0),
                asbx(.loadi, 2, 1),
                abc(.len, 3, 0, 0),
                asbx(.loadi, 4, 1),
                abx(.forprep, 2, 3),
                abc(.gettable, 5, 0, 4),
                abc(.add, 1, 1, 5),
                abc(.mmbin, 1, 5, 6),
                abx(.forloop, 2, 4),
                abc(.move, 2, 1, 0),
                abc(.len, 3, 0, 0),
                abc(.getfield, 4, 0, 1),
                abc(.geti, 5, 0, 101),
                abc(.@"return", 2, 5, 1),
                abc(.@"return", 2, 1, 1),
            },
        });
        const r = try run(state, main);
        try testing.expectEqual(@as(usize, 4), r.len);
        try testing.expectEqual(@as(i64, 10100), r[0].asInt());
        try testing.expectEqual(@as(i64, 100), r[1].asInt());
        try testing.expectEqualStrings("x", r[2].asString().bytes());
        try testing.expect(r[3].isNil());
    }
}

fn nativePair(th: *Thread, base: u32) Error!u32 {
    const x = th.stack[base].asInt();
    th.push(.int(x));
    th.push(.int(x * 2));
    return 2;
}

test "calling a native function, with fixed and all results" {
    // local a, b = pair(4)
    // return a + b, pair(10)      --> 12  10  20
    const state = try newState(false);
    defer state.destroy();
    try state.globals.setStr(&state.heap, try state.newString("pair"), .native(&nativePair));
    const main = try makeProto(state, .{
        .vararg = true,
        .maxstack = 5,
        .upvalues = &.{env_upval},
        .k = &.{try str(state, "pair")},
        .code = &.{
            abc(.varargprep, 0, 0, 0),
            abc(.gettabup, 0, 0, 0),
            asbx(.loadi, 1, 4),
            abc(.call, 0, 2, 3),
            abc(.add, 2, 0, 1),
            abc(.mmbin, 0, 1, 6),
            abc(.gettabup, 3, 0, 0),
            asbx(.loadi, 4, 10),
            abc(.call, 3, 2, 0),
            abc(.@"return", 2, 0, 1),
            abc(.@"return", 2, 1, 1),
        },
    });
    try expectInts(&.{ 12, 10, 20 }, try run(state, main));
}

test "varargs: VARARGPREP, VARARG with fixed and all results, and a vararg call" {
    // local function va(...) local a, b = ... return b, ... end
    // return va(1, 2, 3)          --> 2  1  2  3
    const state = try newState(false);
    defer state.destroy();
    const va = try makeProto(state, .{
        .vararg = true,
        .maxstack = 5,
        .code = &.{
            abc(.varargprep, 0, 0, 0),
            abc(.vararg, 1, 0, 3),
            abc(.move, 3, 2, 0),
            abc(.vararg, 4, 0, 0),
            abc(.@"return", 3, 0, 1),
            abc(.@"return", 3, 1, 1),
        },
    });
    const main = try makeProto(state, .{
        .vararg = true,
        .maxstack = 5,
        .upvalues = &.{env_upval},
        .p = &.{va},
        .code = &.{
            abc(.varargprep, 0, 0, 0),
            abx(.closure, 0, 0),
            abc(.move, 1, 0, 0),
            asbx(.loadi, 2, 1),
            asbx(.loadi, 3, 2),
            asbx(.loadi, 4, 3),
            abc(.call, 1, 4, 0),
            abc(.@"return", 1, 0, 1),
            abc(.@"return", 1, 1, 1),
        },
    });
    try expectInts(&.{ 2, 1, 2, 3 }, try run(state, main));
}

test "comparisons and jumps across types" {
    // local a, b = "abc", "abd"
    // return a < b, a == "abc", 1 == 1.0, 2 < 1.5, 3 <= 3.0, not nil
    //   --> true  true  true  false  true  true
    const state = try newState(false);
    defer state.destroy();
    const main = try makeProto(state, .{
        .maxstack = 9,
        .k = &.{ try str(state, "abc"), try str(state, "abd"), .float(1.0), .float(1.5), .float(3.0) },
        .code = &.{
            abx(.loadk, 0, 0),
            abx(.loadk, 1, 1),
            // R2 = a < b
            abck(.lt, 0, 1, 0),
            jmp(1),
            abc(.lfalseskip, 2, 0, 0),
            abc(.loadtrue, 2, 0, 0),
            // R3 = a == "abc"
            abck(.eqk, 0, 0, 0),
            jmp(1),
            abc(.lfalseskip, 3, 0, 0),
            abc(.loadtrue, 3, 0, 0),
            // R4 = 1 == 1.0
            asbx(.loadi, 8, 1),
            abck(.eqk, 8, 2, 0),
            jmp(1),
            abc(.lfalseskip, 4, 0, 0),
            abc(.loadtrue, 4, 0, 0),
            // R5 = 2 < 1.5
            abx(.loadk, 8, 3),
            abck(.gti, 8, sC(2), 0),
            jmp(1),
            abc(.lfalseskip, 5, 0, 0),
            abc(.loadtrue, 5, 0, 0),
            // R6 = 3 <= 3.0
            asbx(.loadi, 7, 3),
            abx(.loadk, 8, 4),
            abck(.le, 7, 8, 0),
            jmp(1),
            abc(.lfalseskip, 6, 0, 0),
            abc(.loadtrue, 6, 0, 0),
            // R7 = not nil
            abc(.loadnil, 8, 0, 0),
            abc(.not, 7, 8, 0),
            abc(.@"return", 2, 7, 0),
        },
    });
    const r = try run(state, main);
    const want = [_]bool{ true, true, true, false, true, true };
    try testing.expectEqual(want.len, r.len);
    for (want, r) |w, g| try testing.expectEqual(w, !g.isFalsy());
}

test "runtime errors carry position and unwind to pcall" {
    // local t = nil
    // return t.x                  --> test:2: attempt to index a nil value
    const state = try newState(false);
    defer state.destroy();
    const p = try makeProto(state, .{
        .maxstack = 2,
        .k = &.{try str(state, "x")},
        .lineinfo = &.{ 1, 2, 2 },
        .code = &.{
            abc(.loadnil, 0, 0, 0),
            abc(.getfield, 1, 0, 0),
            abc(.return1, 1, 0, 0),
        },
    });
    p.source = try state.newString("=test");
    const th = state.main;
    const func = th.top;
    th.push(.luaClosure(try mainClosure(state, p)));
    try testing.expect(!pcall(th, func, -1));
    try testing.expectEqualStrings("test:2: attempt to index a nil value", th.stack[func].asString().bytes());
    try testing.expectEqual(func + 1, th.top);
    try testing.expectEqual(@as(usize, 1), th.frames.items.len);

    // 1 // 0 and 1 % 0 raise; 1.0 // 0 is a float infinity.
    const q = try makeProto(state, .{
        .maxstack = 3,
        .code = &.{
            asbx(.loadi, 0, 1),
            asbx(.loadi, 1, 0),
            abc(.idiv, 2, 0, 1),
            abc(.mmbin, 0, 1, 12),
            abc(.return1, 2, 0, 0),
        },
    });
    th.top = func;
    th.push(.luaClosure(try mainClosure(state, q)));
    try testing.expect(!pcall(th, func, -1));
    try testing.expectEqualStrings("attempt to perform 'n//0'", th.stack[func].asString().bytes());

    // Calling nil, and arithmetic on a table.
    const r = try makeProto(state, .{
        .maxstack = 2,
        .code = &.{ abc(.loadnil, 0, 0, 0), abc(.call, 0, 1, 1), abc(.return0, 0, 0, 0) },
    });
    th.top = func;
    th.push(.luaClosure(try mainClosure(state, r)));
    try testing.expect(!pcall(th, func, -1));
    try testing.expectEqualStrings("attempt to call a nil value", th.stack[func].asString().bytes());
}

test "Lua metamethods finish their instructions: __index, __add, __lt" {
    // t = setmetatable({present = 7}, {
    //   __index = function(t, k) return 42 end,
    //   __add = function(a, b) return b + 1000 end,
    //   __lt = function(a, b) return true end })
    // local x = t
    // local v = 1
    // if x < x then v = 1 else v = 2 end
    // return x.missing, x.present, x + 1, v       --> 42  7  1001  1
    for ([_]bool{ false, true }) |stress| {
        const state = try newState(stress);
        defer state.destroy();
        const heap = &state.heap;
        const index_fn = try makeProto(state, .{ .numparams = 2, .maxstack = 3, .code = &.{
            asbx(.loadi, 2, 42),
            abc(.return1, 2, 0, 0),
        } });
        const add_fn = try makeProto(state, .{ .numparams = 2, .maxstack = 3, .k = &.{.int(1000)}, .code = &.{
            abc(.addk, 2, 1, 0),
            abc(.mmbink, 1, 0, 6),
            abc(.return1, 2, 0, 0),
        } });
        const lt_fn = try makeProto(state, .{ .numparams = 2, .maxstack = 3, .code = &.{
            abc(.loadtrue, 2, 0, 0),
            abc(.return1, 2, 0, 0),
        } });
        const t = try state.newTable(0, 1);
        try state.globals.setStr(heap, try state.newString("t"), .table(t));
        try t.setStr(heap, try state.newString("present"), .int(7));
        const mt = try state.newTable(0, 4);
        t.metatable = mt;
        try mt.setStr(heap, try state.newString("__index"), .luaClosure(try LuaClosure.create(heap, index_fn, 0)));
        try mt.setStr(heap, try state.newString("__add"), .luaClosure(try LuaClosure.create(heap, add_fn, 0)));
        try mt.setStr(heap, try state.newString("__lt"), .luaClosure(try LuaClosure.create(heap, lt_fn, 0)));
        const main = try makeProto(state, .{
            .maxstack = 5,
            .upvalues = &.{env_upval},
            .k = &.{ try str(state, "t"), try str(state, "missing"), try str(state, "present") },
            .code = &.{
                abc(.gettabup, 0, 0, 0),
                abc(.getfield, 1, 0, 1),
                abc(.getfield, 2, 0, 2),
                abc(.addi, 3, 0, sC(1)),
                abc(.mmbini, 0, sC(1), 6),
                abck(.lt, 0, 0, 0),
                jmp(2),
                asbx(.loadi, 4, 2),
                jmp(1),
                asbx(.loadi, 4, 1),
                abc(.@"return", 1, 5, 0),
            },
        });
        try expectInts(&.{ 42, 7, 1001, 1 }, try run(state, main));
        // The __lt result was cached as present; __eq's absence is cached
        // after a miss.
        try testing.expectEqual(@as(?Value, null), state.fastTm(mt, .eq));
        try testing.expect(mt.flags & (1 << @intFromEnum(Tm.eq)) != 0);
    }
}

test "deep Lua recursion uses heap, and overflow is a catchable error" {
    // local function f(n) if n == 0 then return 0 end return 1 + f(n - 1) end
    // return f(100000)           --> 100000, then f(-1) overflows the stack
    const state = try newState(false);
    defer state.destroy();
    const f = try makeProto(state, .{
        .numparams = 1,
        .maxstack = 3,
        .upvalues = &.{.{ .instack = true, .idx = 0 }},
        .code = &.{
            abc(.eqi, 0, sC(0), 0),
            jmp(2),
            asbx(.loadi, 1, 0),
            abc(.return1, 1, 0, 0),
            abc(.getupval, 1, 0, 0),
            abc(.addi, 2, 0, sC(-1)),
            abc(.mmbini, 0, sC(1), 7),
            abc(.call, 1, 2, 2),
            abc(.addi, 1, 1, sC(1)),
            abck(.mmbini, 1, sC(1), 6),
            abc(.return1, 1, 0, 0),
            abc(.return0, 0, 0, 0),
        },
    });
    const main = try makeProto(state, .{
        .maxstack = 3,
        .k = &.{.int(100_000)},
        .p = &.{f},
        .code = &.{
            abx(.closure, 0, 0),
            abc(.move, 1, 0, 0),
            abx(.loadk, 2, 0),
            abc(.call, 1, 2, 0),
            abc(.@"return", 1, 0, 0),
        },
    });
    try expectInts(&.{100_000}, try run(state, main));

    main.k[0] = .int(-1);
    const th = state.main;
    const func = th.top;
    th.push(.luaClosure(try mainClosure(state, main)));
    try testing.expect(!pcall(th, func, -1));
    try testing.expectEqualStrings("stack overflow", th.stack[func].asString().bytes());
}

test "concatenation of strings and numbers, short and long results" {
    // local s = "a" .. 1 .. "b" .. 2.5
    // return s, s .. string.rep("x", 40)
    const state = try newState(true);
    defer state.destroy();
    const main = try makeProto(state, .{
        .maxstack = 6,
        .k = &.{ try str(state, "a"), try str(state, "b"), .float(2.5), try str(state, "x" ** 40) },
        .code = &.{
            abx(.loadk, 0, 0),
            asbx(.loadi, 1, 1),
            abx(.loadk, 2, 1),
            abx(.loadk, 3, 2),
            abc(.concat, 0, 4, 0),
            abc(.move, 1, 0, 0),
            abc(.move, 2, 0, 0),
            abx(.loadk, 3, 3),
            abc(.concat, 2, 2, 0),
            abc(.@"return", 1, 3, 0),
        },
    });
    const r = try run(state, main);
    try testing.expectEqualStrings("a1b2.5", r[0].asString().bytes());
    try testing.expect(r[0].asString().isShort());
    try testing.expectEqualStrings("a1b2.5" ++ "x" ** 40, r[1].asString().bytes());
    try testing.expect(!r[1].asString().isShort());
}

test "the collector frees garbage made in a loop and keeps live values" {
    // for i = 1, 20000 do local t = {} t[1] = i end
    // local keep = {}
    // keep.x = "kept string, long enough to be a long string"
    // return keep
    const state = try newState(false);
    defer state.destroy();
    const kept = "kept string, long enough to be a long string";
    const main = try makeProto(state, .{
        .maxstack = 5,
        .k = &.{ .int(20000), try str(state, "x"), try str(state, kept) },
        .code = &.{
            asbx(.loadi, 0, 1),
            abx(.loadk, 1, 0),
            asbx(.loadi, 2, 1),
            abx(.forprep, 0, 3),
            opcodes.vabc(.newtable, 3, 0, 0, false),
            opcodes.iax(.extraarg, 0),
            abc(.seti, 3, 1, 2),
            abx(.forloop, 0, 4),
            opcodes.vabc(.newtable, 0, 0, 0, false),
            opcodes.iax(.extraarg, 0),
            abck(.setfield, 0, 1, 2),
            abc(.return1, 0, 0, 0),
        },
    });
    const r = try run(state, main);
    try testing.expect(state.heap.cycles > 0);
    // 20000 tables with an array part each would need over a megabyte.
    try testing.expect(state.heap.bytes < 1024 * 1024);
    const keep = r[0].asTable();
    state.collect();
    try testing.expectEqualStrings(kept, keep.get(try str(state, "x")).asString().bytes());
}

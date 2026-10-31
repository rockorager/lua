//! The interpreter: one loop runs a thread's Lua frames (plan decisions 3
//! through 6), plus calls, coroutines, to-be-closed variables, and the
//! operations with metamethods that native code calls.
//!
//! Dispatch is a labeled `switch` with `continue :dispatch`, which Zig
//! compiles to one indirect jump per opcode. The loop keeps `pc`, `base`
//! (a pointer to the running frame's registers), and the constant array in
//! locals, and reloads `base` after anything that can grow the stack: calls,
//! metamethods, and vararg handling.
//!
//! A Lua-to-Lua call pushes a frame and continues the same loop, so Lua
//! recursion costs heap, not Zig stack. A metamethod written in Lua that an
//! instruction calls (`__index`, arithmetic, comparisons, `__concat`) gets
//! a frame flagged `finish_op`; when it returns, `finishOp` completes the
//! interrupted instruction, as PUC-Rio's `luaV_finishOp` does. Native
//! metamethods run directly and the instruction completes inline.
//!
//! Errors are `error.LuaError` with the error object in `Thread.err`; they
//! unwind through ordinary Zig error returns to the nearest protected call.
//! A yield is `error.LuaError` too, with the thread's status `.yield`: it
//! unwinds every Zig frame up to `resumeThread` and leaves the Lua frames
//! in place. Resuming runs the rest from the frames alone (`unroll`): a
//! Lua frame continues at its saved `pc` after `finishOp`, and a native
//! frame that called through `callk` or `pcallk` runs its continuation.
//! A native that called through `call` cannot be continued, so `call`
//! marks the thread non-yieldable while it runs.

const std = @import("std");
const Value = @import("Value.zig");
const String = @import("String.zig");
const Table = @import("Table.zig");
const Proto = @import("Proto.zig");
const Thread = @import("Thread.zig");
const State = @import("State.zig");
const gc = @import("gc.zig");
const opcodes = @import("opcodes.zig");
const number = @import("number.zig");
// The reference's `pow`, so results match it bit for bit.
const libm = @import("lib/libm.zig");
const debuginfo = @import("debuginfo.zig");

const Error = Value.Error;
const KFn = Value.KFn;
const KStatus = Value.KStatus;
const Frame = Thread.Frame;
const Tm = State.Tm;
const LuaClosure = Proto.LuaClosure;
const Instruction = opcodes.Instruction;
const Origin = debuginfo.Origin;

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

/// Copies the value at `src` to `dst` field by field, as PUC-Rio's
/// `setobj` does. A plain struct copy is one 16-byte load, and when the
/// source was just written by two narrower stores (a payload and a tag, as
/// every arithmetic result is), store forwarding cannot serve that load:
/// it waits for both stores to retire.
inline fn put(dst: *Value, src: *const Value) void {
    dst.payload = src.payload;
    dst.tag = src.tag;
}

/// Stores `v` at `dst` field by field; see `put`.
inline fn setv(dst: *Value, v: Value) void {
    dst.payload = v.payload;
    dst.tag = v.tag;
}

/// Longest `__index`/`__newindex` chain, `MAXTAGLOOP`.
const max_tag_loop = 2000;
/// Longest `__call` chain, `MAX_CCMT`.
const max_call_chain = 15;

// ---------------------------------------------------------------------------
// Calls
// ---------------------------------------------------------------------------

/// Calls the value at stack slot `func` with the arguments above it, up to
/// `top`. The results replace the function and arguments: `nresults` of
/// them, or all of them with `top` after the last when `nresults` is -1.
/// The call cannot yield (`lua_call`); see `callk` for one that can.
pub fn call(th: *Thread, func: u32, nresults: i16) Error!void {
    th.nny += 1;
    defer th.nny -= 1;
    return callYieldable(th, func, nresults);
}

/// `call` from a native function that can be suspended inside the call
/// (`lua_callk`). If the coroutine yields inside it, the native's Zig frame
/// is gone when it resumes: once the call returns, `k` runs with status
/// `.yield` and `ctx`, and its result is the native's. When the call
/// returns without yielding, `callk` returns and the native goes on (it
/// usually calls `k` itself with `.ok`). Outside a coroutine, or under a
/// native that used `call`, this is `call`.
pub fn callk(th: *Thread, func: u32, nresults: i16, ctx: u32, k: KFn) Error!void {
    if (th.nny > 0) return call(th, func, nresults);
    th.frame().setK(k, ctx);
    return callYieldable(th, func, nresults);
}

/// How a protected call ended, the reference's `LUA_OK`, `LUA_ERRRUN`,
/// `LUA_ERRMEM`, and `LUA_ERRERR`: by the kind of failure, not by the
/// error object, so a Lua `error("not enough memory")` is `.runtime`.
pub const Status = enum {
    ok,
    /// An error raised by code or by the engine.
    runtime,
    /// An allocation failed; the error object is the fixed "not enough
    /// memory" string, and no message handler ran.
    memory,
    /// "error in error handling": the message handler failed, or handling
    /// an error kept nesting.
    handler,
};

/// `call` in protected mode. On an error the stack is unwound to `func`,
/// pending to-be-closed variables are closed, the error object is left at
/// `func`, `top` is `func + 1`, and the result is false. Allocation failure
/// leaves the "not enough memory" string. `pcallMsgh` says which error.
pub fn pcall(th: *Thread, func: u32, nresults: i16) bool {
    return pcallMsgh(th, func, nresults, 0) == .ok;
}

/// `pcall` with a message handler and its status (`lua_pcall`): `msgh` is
/// the stack index of a function, or 0 for none. An error raised inside
/// the call (but not a memory error) is passed to the handler before the
/// stack unwinds, and the handler's result becomes the error object.
pub fn pcallMsgh(th: *Thread, func: u32, nresults: i16, msgh: u32) Status {
    // `closeSelf` refuses to unwind past this call, which cannot pass the
    // unwinding on, so nothing else gets through.
    th.npcall += 1;
    defer th.npcall -= 1;
    return protectedCall(th, func, nresults, msgh) catch .runtime;
}

/// `pcallMsgh`, except that the unwinding `closeSelf` starts passes
/// through as `error.LuaError`.
fn protectedCall(th: *Thread, func: u32, nresults: i16, msgh: u32) Error!Status {
    const frames = th.frames.items.len;
    const old_errfunc = th.errfunc;
    const old_allowhook = th.allowhook;
    th.errfunc = msgh;
    defer th.errfunc = old_errfunc;
    call(th, func, nresults) catch |e| {
        if (th.closed_self) return e;
        var status = errorStatus(th, e);
        const err = errorObject(th, e);
        th.frames.items.len = frames;
        th.allowhook = old_allowhook;
        th.stack[func] = closeProtected(th, func, err, &status) orelse err;
        if (th.closed_self) return error.LuaError;
        th.top = func + 1;
        th.shrinkStack();
        return status;
    };
    return .ok;
}

/// `pcallMsgh` from a native function that can be suspended inside the
/// call (`lua_pcallk`). Returns the status; after an error the error
/// object sits at `func` as for `pcall`. Inside a
/// coroutine it may instead return `error.LuaError`, for a yield or for an
/// error; propagate it with `try`. The coroutine then finishes the call
/// later, and calls `k` with `ctx` and status `.yield` (success) or `.err`
/// (the error object on top) in place of the rest of the native.
pub fn pcallk(th: *Thread, func: u32, nresults: i16, msgh: u32, ctx: u32, k: KFn) Error!Status {
    if (th.nny > 0) return protectedCall(th, func, nresults, msgh);
    const idx = th.frames.items.len - 1;
    {
        const f = &th.frames.items[idx];
        f.setK(k, ctx);
        f.aux = func;
        f.old_errfunc = th.errfunc;
        f.flags.ypcall = true;
        f.flags.oah = th.allowhook;
    }
    th.errfunc = msgh;
    // An error unwinds past here to `resumeThread`, which finds this frame
    // by its `ypcall` flag and finishes the call there.
    try callYieldable(th, func, nresults);
    const f = &th.frames.items[idx];
    f.flags.ypcall = false;
    th.errfunc = f.old_errfunc;
    return .ok;
}

/// `luaD_call`: a call from Zig that may yield if the thread can.
fn callYieldable(th: *Thread, func: u32, nresults: i16) Error!void {
    try enterNative(th);
    defer th.native_calls -= 1;
    if (try preCall(th, func, nresults)) {
        th.frame().flags.fresh = true;
        try execute(th);
    }
}

/// Counts one more entry into the interpreter from Zig, `ccall`'s check:
/// "C stack overflow" at the limit, and "error in error handling" when
/// handling that error keeps nesting.
inline fn enterNative(th: *Thread) Error!void {
    th.native_calls += 1;
    if (th.native_calls >= Thread.max_native_calls) try nativeOverflow(th);
}

fn nativeOverflow(th: *Thread) Error!void {
    if (th.native_calls == Thread.max_native_calls) {
        // The count stays at the limit while a message handler runs.
        const e = th.runError("C stack overflow", .{});
        th.native_calls -= 1;
        return e;
    }
    if (th.native_calls >= Thread.max_native_calls / 10 * 11) {
        th.native_calls -= 1;
        return th.errorInErrorHandling();
    }
}

/// The error object a failed call left: `Thread.err`, or the memory error
/// message. Clears `Thread.err`; take `errorStatus` first.
fn errorObject(th: *Thread, e: Error) Value {
    const v: Value = switch (e) {
        error.LuaError => th.err,
        error.OutOfMemory => .string(th.state.memerr),
    };
    th.err = .nil;
    th.errerr = false;
    return v;
}

/// Which kind of error a failed call raised.
fn errorStatus(th: *const Thread, e: Error) Status {
    return switch (e) {
        error.LuaError => if (th.errerr) .handler else .runtime,
        error.OutOfMemory => .memory,
    };
}

/// Calls the running protected call's message handler on `Thread.err`
/// and makes its result the error object (`luaG_errormsg`).
pub fn callMessageHandler(th: *Thread) Error!void {
    const f = th.frame();
    if (f.flags.lua and th.top < f.top) th.top = f.top;
    try th.ensureStack(2);
    const func = th.top;
    th.push(th.stack[th.errfunc]);
    th.push(th.err);
    try call(th, func, 1);
    th.err = th.stack[func];
    th.top = func;
}

/// Whether `n` more slots fit on the stack without passing its limit
/// (`lua_checkstack`); grows it when they do.
pub fn checkStack(th: *Thread, n: u32) error{OutOfMemory}!bool {
    if (th.stack.len - th.top >= @as(usize, n) + Thread.extra_stack) return true;
    if (@as(usize, th.top) + n > Thread.max_stack) return false;
    th.growStack(@as(usize, th.top) + n) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.LuaError => return false,
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
noinline fn preCall(th: *Thread, func: u32, nresults: i16) Error!bool {
    var chain: u32 = 0;
    while (true) {
        const f = th.stack[func];
        switch (f.tag) {
            .lua_closure => {
                try pushLuaFrame(th, func, f.asLuaClosure().proto, nresults);
                if (chain > 0) th.frame().flags.ncallmt = @intCast(chain);
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
            else => try insertCallTm(th, func, &chain),
        }
    }
}

/// Replaces a called value that is not a function with its `__call`
/// handler, shifting the value up to be the first argument (`tryfuncTM`).
noinline fn insertCallTm(th: *Thread, func: u32, chain: *u32) Error!void {
    @branchHint(.cold);
    const f = th.stack[func];
    const h = th.state.tmOf(f, .call) orelse return callError(th, func);
    try th.ensureStack(1);
    @memmove(th.stack[func + 1 .. th.top + 1], th.stack[func..th.top]);
    th.top += 1;
    th.stack[func] = h;
    if (chain.* == max_call_chain) return th.runError("'__call' chain too long", .{});
    chain.* += 1;
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

noinline fn callNative(th: *Thread, func: u32, nresults: i16, f: Value.NativeFn) Error!void {
    try th.ensureStack(Thread.min_stack);
    if (th.frames.items.len == th.frames.capacity) try th.frames.ensureUnusedCapacity(th.heap().allocator(), 1);
    th.frames.appendAssumeCapacity(.{
        .func = func,
        .top = th.top + Thread.min_stack,
        .nresults = nresults,
        .flags = .{},
    });
    if (th.hookmask & Thread.HookMask.call != 0) try callHook(th, .call, -1, 1, th.top - func - 1);
    const bytes = th.state.heap.bytes;
    const n = try f(th, func + 1);
    std.debug.assert(n <= th.top - func - 1);
    if (th.hookmask != 0) try retHook(th, th.top - n, n);
    moveResults(th, func, th.top - n, n, nresults);
    th.frames.items.len -= 1;
    // Back between two instructions of a Lua function: a safe point for
    // what the native allocated, as the reference's API functions that
    // allocate check the collector and the others do not.
    if (th.state.heap.bytes > bytes and th.frame().flags.lua) _ = th.state.checkGc(th);
}

/// Finishes the running frame, a native one, with `n` results on top
/// (`luaD_poscall`).
fn posCall(th: *Thread, n: u32) Error!void {
    if (th.hookmask != 0) try retHook(th, th.top - n, n);
    const f = th.frame();
    moveResults(th, f.func, th.top - n, n, f.nresults);
    th.frames.items.len -= 1;
}

/// Moves `n` results from `first` to `dest`, adjusted to `wanted`, and sets
/// `top` after them.
inline fn moveResults(th: *Thread, dest: u32, first: u32, n: u32, wanted: i16) void {
    const s = th.stack;
    switch (wanted) {
        0 => th.top = dest,
        1 => {
            if (n == 0) s[dest] = .nil else put(&s[dest], &s[first]);
            th.top = dest + 1;
        },
        -1 => {
            for (0..n) |j| put(&s[dest + j], &s[first + j]);
            th.top = dest + n;
        },
        else => {
            const w: u32 = @intCast(wanted);
            const m = @min(n, w);
            for (0..m) |j| put(&s[dest + j], &s[first + j]);
            for (m..w) |j| s[dest + j] = .nil;
            th.top = dest + w;
        },
    }
}

// ---------------------------------------------------------------------------
// Coroutines
// ---------------------------------------------------------------------------

/// Whether the running code of `th` may yield (`lua_isyieldable`).
pub fn isYieldable(th: *const Thread) bool {
    return th.nny == 0;
}

/// Suspends the coroutine from a native function, passing the `nresults`
/// values on top to the resumer (`lua_yield`). Return its result from the
/// native: `return vm.yield(th, n)`. When the coroutine resumes, the
/// native returns the values passed to `resume`.
pub fn yield(th: *Thread, nresults: u32) Error {
    return yieldk(th, nresults, 0, null);
}

/// `yield` with a continuation (`lua_yieldk`): when the coroutine resumes,
/// `k` runs with status `.yield`, `ctx`, and the resume's values on top,
/// and its result is the native's.
pub fn yieldk(th: *Thread, nresults: u32, ctx: u32, k: ?KFn) Error {
    if (th.nny > 0) {
        if (th == th.state.main) return th.runError("attempt to yield from outside a coroutine", .{});
        return th.runError("attempt to yield across a C-call boundary", .{});
    }
    const f = th.frame();
    f.aux = nresults;
    if (k) |kf| f.setK(kf, ctx) else f.flags.has_k = false;
    th.status = .yield;
    return error.LuaError;
}

pub const ResumeStatus = enum { ok, yield, err };

pub const Resumed = struct {
    status: ResumeStatus,
    /// Values on top of the coroutine's stack: the body's results, the
    /// yielded values, or 1, the error object.
    nres: u32,
    /// With `.err`, which kind (`lua_resume`'s error statuses).
    err: Status = .ok,
};

/// Starts or continues coroutine `co` with the `nargs` values on top of
/// its stack (`lua_resume`); `from` is the resuming thread, whose nesting
/// counts against the coroutine's. Returns when the body returns, yields,
/// or fails with an error no protected call inside it catches; the last
/// marks the coroutine dead, and its stack keeps the frames and a second
/// copy of the error object below the one returned, for `closeThread`.
/// Resuming a coroutine that is running, normal, or dead returns `.err`
/// with a message and changes nothing.
pub fn resumeThread(co: *Thread, from: ?*Thread, nargs: u32) Error!Resumed {
    switch (co.status) {
        .ok => {
            if (co.frames.items.len > 1) return resumeError(co, "cannot resume non-suspended coroutine", nargs);
            if (co.top - 1 == nargs) return resumeError(co, "cannot resume dead coroutine", nargs);
        },
        .yield => {},
        .dead => return resumeError(co, "cannot resume dead coroutine", nargs),
    }
    co.native_calls = if (from) |f| f.native_calls else 0;
    if (co.native_calls >= Thread.max_native_calls) return resumeError(co, "C stack overflow", nargs);
    co.native_calls += 1;
    const base_calls = co.native_calls;
    co.nny = 0;
    var outcome = outcomeOf(co, resumeBody(co, nargs));
    // Errors inside a yieldable protected call unwound to here; finish
    // each such call and go on (`precover`).
    while (outcome == .err and !co.closed_self) {
        const level = findPcall(co) orelse break;
        recoverAt(co, level, outcome.err.v);
        co.native_calls = base_calls;
        co.nny = 0;
        outcome = outcomeOf(co, unroll(co));
    }
    if (co.closed_self) {
        co.closed_self = false;
        outcome = if (co.top == 2) .{ .err = .{ .v = co.stack[1], .status = .runtime } } else .ok;
    }
    switch (outcome) {
        .ok => return .{ .status = .ok, .nres = co.top - 1 },
        .yield => return .{ .status = .yield, .nres = co.frame().aux },
        .err => |e| {
            co.status = .dead;
            const f = co.frame();
            if (f.flags.lua and co.top < f.top) co.top = f.top;
            try co.ensureStack(2);
            co.push(e.v);
            co.push(e.v);
            f.top = co.top;
            return .{ .status = .err, .nres = 1, .err = e.status };
        },
    }
}

const Outcome = union(enum) { ok, yield, err: struct { v: Value, status: Status } };

fn outcomeOf(co: *Thread, r: Error!void) Outcome {
    r catch |e| {
        if (e == error.LuaError and co.status == .yield) return .yield;
        const status = errorStatus(co, e);
        return .{ .err = .{ .v = errorObject(co, e), .status = status } };
    };
    return .ok;
}

fn resumeError(co: *Thread, msg: []const u8, nargs: u32) Error!Resumed {
    co.top -= nargs;
    co.push(.string(try co.state.newString(msg)));
    return .{ .status = .err, .nres = 1, .err = .runtime };
}

fn resumeBody(co: *Thread, nargs: u32) Error!void {
    if (co.status == .ok) {
        if (try preCall(co, co.top - nargs - 1, -1)) {
            co.frame().flags.fresh = true;
            try execute(co);
        }
        return;
    }
    // The innermost frame is the native that yielded: its results are the
    // resume's values, or what its continuation makes of them.
    co.status = .ok;
    var n = nargs;
    const f = co.frame();
    if (f.k()) |k| n = try k(co, f.base(), .yield, f.extra_args);
    try posCall(co, n);
    try unroll(co);
}

/// Runs the rest of a resumed coroutine from its frames, down to the base
/// frame (`unroll`).
fn unroll(th: *Thread) Error!void {
    while (th.frames.items.len > 1) {
        const f = th.frame();
        if (f.flags.lua) {
            try finishOp(th, f);
            try execute(th);
        } else {
            try finishNative(th);
        }
    }
}

/// Finishes a native frame whose call through `callk` or `pcallk`
/// returned: its continuation completes it (`finishCcall`).
fn finishNative(th: *Thread) Error!void {
    const idx = th.frames.items.len - 1;
    var status: KStatus = .yield;
    if (th.frames.items[idx].flags.ypcall) status = try finishPcallk(th, idx);
    const f = &th.frames.items[idx];
    if (f.top < th.top) f.top = th.top;
    const k = f.k() orelse unreachable;
    const n = try k(th, f.base(), status, f.extra_args);
    try posCall(th, n);
}

/// Completes the protected call of the native frame at `idx` after it was
/// interrupted by a yield or an error (`finishpcallk`). After an error,
/// closes the call's pending to-be-closed variables (which may yield or
/// fail again; then this runs again with what is left) and leaves the
/// error object at the call's function slot.
fn finishPcallk(th: *Thread, idx: usize) Error!KStatus {
    var status: KStatus = .yield;
    if (th.frames.items[idx].flags.recover) {
        const func = th.frames.items[idx].aux;
        // The error object is on top, where `recoverAt` put it and where
        // each `__close` call leaves it.
        try closeLevel(th, func, .{ .err = th.stack[th.top - 1] }, true);
        th.stack[func] = th.stack[th.top - 1];
        th.top = func + 1;
        th.shrinkStack();
        th.frames.items[idx].flags.recover = false;
        th.allowhook = th.frames.items[idx].flags.oah;
        status = .err;
    }
    const f = &th.frames.items[idx];
    f.flags.ypcall = false;
    th.errfunc = f.old_errfunc;
    return status;
}

/// The innermost native frame in a yieldable protected call, `findpcall`.
fn findPcall(th: *Thread) ?usize {
    var i = th.frames.items.len;
    while (i > 1) {
        i -= 1;
        if (th.frames.items[i].flags.ypcall) return i;
    }
    return null;
}

/// Unwinds to the protected call at frame `level` after error `err`, with
/// the error object on top above every slot the unwound frames used.
fn recoverAt(th: *Thread, level: usize, err: Value) void {
    var top = th.top;
    for (th.frames.items[level..]) |f| top = @max(top, f.top);
    th.frames.items.len = level + 1;
    th.top = top;
    th.push(err);
    th.frames.items[level].flags.recover = true;
}

/// Closes coroutine `co`: unwinds its frames, closes its pending
/// to-be-closed variables, and empties its stack (`lua_closethread`).
/// A dead coroutine passes its error object to the `__close` handlers.
/// Returns true when it ends without an error; otherwise the error (the
/// coroutine's or one a handler raised) is on top of `co`'s stack.
pub fn closeThread(co: *Thread, from: ?*Thread) bool {
    co.native_calls = if (from) |f| f.native_calls else 0;
    const err: ?Value = if (co.status == .dead) co.stack[co.top - 1] else null;
    co.resetFrames();
    const result = closeProtected(co, 1, err, null);
    // Closing from inside a handler ended this close too, unless this is
    // that inner close itself.
    if (from != co) co.closed_self = false;
    if (result) |e| {
        co.stack[1] = e;
        co.top = 2;
    } else {
        co.top = 1;
    }
    co.shrinkStack();
    return result == null;
}

/// What `lua_close` does before freeing the state, for a native that ends
/// the program (`os.exit(code, true)`) and for `State.destroy`: closes the
/// main thread's pending to-be-closed variables from the base frame up,
/// in protected mode, with errors dropped, then calls every pending
/// finalizer. The memory stays for `State.destroy` or process exit, and
/// the caller must not return into Lua afterwards. Runs once.
pub fn closeState(state: *State) void {
    if (state.heap.stopped & gc.stop.closing != 0) return;
    const th = state.main;
    th.resetFrames();
    th.native_calls = 0;
    _ = closeProtected(th, 1, null, null);
    gc.callAllFinalizers(state);
}

/// `coroutine.close` on the running coroutine: closes it and ends the
/// resume that runs it, which returns what closing it returned.
pub fn closeSelf(th: *Thread) Error {
    // The error unwinds to the resume or the outer close
    // (`luaD_throwbaselevel`); a `pcallMsgh` on the way cannot pass it on.
    if (th.npcall > 0) return th.runError("attempt to yield across a C-call boundary", .{});
    _ = closeThread(th, th);
    th.closed_self = true;
    return error.LuaError;
}

// ---------------------------------------------------------------------------
// To-be-closed variables
// ---------------------------------------------------------------------------

/// Makes the variable at stack slot `level` to-be-closed (`luaF_newtbcupval`).
/// False and nil need no closing; any other value needs a `__close`.
noinline fn newTbc(th: *Thread, level: u32) Error!void {
    @branchHint(.cold);
    const v = th.stack[level];
    if (v.isFalsy()) return;
    if (th.state.tmOf(v, .close) == null) {
        const f = th.frame();
        const p = th.stack[f.func].asLuaClosure().proto;
        const name = debuginfo.localName(p, level - f.func, Thread.currentPc(p, f)) orelse "?";
        return th.runError("variable '{s}' got a non-closable value", .{name});
    }
    try th.tbc.append(th.heap().allocator(), level);
}

const CloseMode = union(enum) {
    /// `CLOSE`: each `__close` call goes right above its variable.
    normal,
    /// `RETURN`: the calls go on top, above the results.
    ktop,
    /// Unwinding an error: each call gets the error object.
    err: Value,
};

/// Closes the upvalues and to-be-closed variables at stack slot `level`
/// and above, innermost first (`luaF_close`). Each `__close` handler gets
/// the variable's value and, with `.err`, the error object.
noinline fn closeLevel(th: *Thread, level: u32, mode: CloseMode, comptime yieldable: bool) Error!void {
    @branchHint(.cold);
    th.closeUpvals(level);
    while (th.tbc.items.len > 0) {
        const tbc = th.tbc.items[th.tbc.items.len - 1];
        if (tbc < level) break;
        th.tbc.items.len -= 1;
        const obj = th.stack[tbc];
        switch (mode) {
            .normal => th.top = tbc + 1,
            .ktop => {},
            // The error object stays in the stack, rooted, below the call.
            .err => |e| {
                th.stack[tbc + 1] = e;
                th.top = tbc + 2;
            },
        }
        try th.ensureStack(3);
        const func = th.top;
        th.push(th.state.tmOf(obj, .close) orelse .nil);
        th.push(obj);
        if (mode == .err) th.push(mode.err);
        if (yieldable) try callYieldable(th, func, 0) else try call(th, func, 0);
    }
}

/// Closes from `level` in protected mode after an error, `luaD_closeprotected`:
/// an error in a `__close` handler replaces the error object, and its kind
/// `status` when given, and closing goes on. Returns the final error
/// object, or null when there was none.
fn closeProtected(th: *Thread, level: u32, err_in: ?Value, status: ?*Status) ?Value {
    var err = err_in;
    const frames = th.frames.items.len;
    const old_allowhook = th.allowhook;
    while (true) {
        const mode: CloseMode = if (err) |e| .{ .err = e } else .normal;
        closeLevel(th, level, mode, false) catch |e| {
            // `closeSelf` from a handler closed the rest and left its result.
            if (th.closed_self) return if (th.top == 2) th.stack[1] else null;
            if (status) |p| p.* = errorStatus(th, e);
            err = errorObject(th, e);
            th.frames.items.len = frames;
            th.allowhook = old_allowhook;
            continue;
        };
        return err;
    }
}

// ---------------------------------------------------------------------------
// Hooks
// ---------------------------------------------------------------------------

/// Sets the debug hook of `th` (`lua_sethook`): `mask` is `HookMask`
/// bits, and `count` the instructions between count events. A null hook
/// or an empty mask turns hooks off. The interpreter notices the change
/// when the native that made it returns.
pub fn setHook(th: *Thread, hook: ?Thread.Hook, mask: u8, count: i32) void {
    const off = hook == null or mask == 0;
    th.hook = if (off) null else hook;
    th.hookmask = if (off) 0 else mask;
    th.basehookcount = count;
    th.hookcount = count;
}

/// Calls the hook for `event` in the running frame (`luaD_hook`), unless
/// a hook is running already. The hook runs above the frame's registers,
/// with `Thread.min_stack` free slots, and the frame flagged `hooked`.
noinline fn callHook(th: *Thread, event: Thread.HookEvent, line: i32, ftransfer: u32, ntransfer: u32) Error!void {
    @branchHint(.cold);
    const hook = th.hook orelse return;
    if (!th.allowhook) return;
    const idx = th.frames.items.len - 1;
    const top = th.top;
    const ci_top = th.frames.items[idx].top;
    th.ftransfer = @intCast(ftransfer);
    th.ntransfer = @intCast(ntransfer);
    {
        const ci = &th.frames.items[idx];
        if (ci.flags.lua and th.top < ci.top) th.top = ci.top;
    }
    try th.ensureStack(Thread.min_stack);
    const ci = &th.frames.items[idx];
    if (ci.top < th.top + Thread.min_stack) ci.top = th.top + Thread.min_stack;
    th.allowhook = false;
    ci.flags.hooked = true;
    // An error leaves the frame to be unwound, and the protected call
    // that catches it restores `allowhook`.
    try hook(th, event, line, idx);
    th.allowhook = true;
    const after = &th.frames.items[idx];
    after.top = ci_top;
    th.top = top;
    after.flags.hooked = false;
}

/// The call hook of the running Lua frame, about to run its first
/// instruction (`luaD_hookcall`). A tail call reports "tail call".
noinline fn hookCall(th: *Thread) Error!void {
    @branchHint(.cold);
    th.oldpc = 0;
    if (th.hookmask & Thread.HookMask.call == 0) return;
    const ci = th.frame();
    const event: Thread.HookEvent = if (ci.flags.tail) .tail_call else .call;
    const p = th.stack[ci.func].asLuaClosure().proto;
    const idx = th.frames.items.len - 1;
    // Hooks see the pc past the instruction, as everywhere else.
    ci.pc += 1;
    try callHook(th, event, -1, 1, p.numparams);
    th.frames.items[idx].pc -= 1;
}

/// The return hook of the running frame, whose `nres` results start at
/// stack slot `first` (`rethook`). It also sets `oldpc` for the line hook
/// of a Lua caller, which goes on after its call instruction.
noinline fn retHook(th: *Thread, first: u32, nres: u32) Error!void {
    @branchHint(.cold);
    const idx = th.frames.items.len - 1;
    if (th.hookmask & Thread.HookMask.ret != 0) {
        const ci = &th.frames.items[idx];
        // A vararg function's results count from where its function sat
        // while it ran, above the extra arguments.
        var delta: u32 = 0;
        if (ci.flags.lua) {
            const p = th.stack[ci.func].asLuaClosure().proto;
            if (p.flags.vararg) delta = ci.extra_args + p.numparams + 1;
        }
        ci.func += delta;
        const ftransfer = first - ci.func;
        defer th.frames.items[idx].func -= delta;
        try callHook(th, .ret, -1, ftransfer, nres);
    }
    if (idx > 0) {
        const prev = &th.frames.items[idx - 1];
        if (prev.flags.lua) th.oldpc = @intCast(Thread.currentPc(th.stack[prev.func].asLuaClosure().proto, prev));
    }
}

/// The count and line hooks before the instruction at `pc` of the running
/// Lua frame (`luaG_traceexec`). A line event fires on entering a new line,
/// and on a jump back to an instruction at or before the last one traced,
/// which repeats a loop's line each time around.
noinline fn traceExec(th: *Thread, pc: [*]const u32) Error!void {
    @branchHint(.cold);
    const mask = th.hookmask;
    if (mask & (Thread.HookMask.line | Thread.HookMask.count) == 0) return;
    const ci = th.frame();
    ci.pc = pc + 1;
    var counthook = false;
    if (mask & Thread.HookMask.count != 0) {
        th.hookcount -%= 1;
        if (th.hookcount == 0) {
            th.hookcount = th.basehookcount;
            counthook = true;
        }
    }
    if (!counthook and mask & Thread.HookMask.line == 0) return;
    // An instruction that takes its operands up to `top` keeps it.
    if (!usesTop(pc[0])) th.top = ci.top;
    const p = th.stack[ci.func].asLuaClosure().proto;
    const npci: u32 = @intCast((@intFromPtr(pc) - @intFromPtr(p.code.ptr)) / 4);
    if (counthook) try callHook(th, .count, -1, 0, 0);
    if (mask & Thread.HookMask.line != 0) {
        // `oldpc` may be stale; any valid value costs at most one extra
        // event.
        const oldpc = if (th.oldpc < p.code.len) th.oldpc else 0;
        if (npci <= oldpc or p.lineAt(oldpc) != p.lineAt(npci)) {
            const line: i32 = if (p.lineAt(npci)) |l| @intCast(l) else -1;
            try callHook(th, .line, line, 0, 0);
        }
        th.oldpc = npci;
    }
}

/// Whether instruction `i` takes its operands up to `top`, as set by the
/// instruction before it (`luaP_isIT`).
fn usesTop(i: Instruction) bool {
    const o = op(i);
    if (!opcodes.props[@intFromEnum(o)].in_top) return false;
    return if (o == .setlist) opcodes.vb(i) == 0 else getB(i) == 0;
}

// ---------------------------------------------------------------------------
// The interpreter loop
// ---------------------------------------------------------------------------

inline fn fetch(pc: *[*]const u32, i: *Instruction) Dispatch {
    i.* = pc.*[0];
    pc.* += 1;
    return dispatchOp(i.*);
}

/// `fetch` past the next instruction: an arithmetic fast path skipping its
/// `MMBIN`.
inline fn fetchSkip(pc: *[*]const u32, i: *Instruction) Dispatch {
    i.* = pc.*[1];
    pc.* += 2;
    return dispatchOp(i.*);
}

/// `OpCode` as the loop's switch sees it: the same tags, non-exhaustive, so
/// safe builds do not check before every dispatch that the opcode is one
/// of the set. It always is: every instruction the loop runs comes from
/// the compiler, whose encoders take an `OpCode`, or from `undump`, which
/// rejects any other; a new source of code must check the same
/// (`results/opcode-check-20261031.md`).
const Dispatch = @Enum(u7, .nonexhaustive, std.meta.fieldNames(opcodes.OpCode), &std.simd.iota(u7, opcodes.props.len));

inline fn dispatchOp(i: Instruction) Dispatch {
    return @enumFromInt(@as(u7, @truncate(i)));
}

/// Runs Lua frames from the current one until a frame flagged `fresh`
/// returns (`luaV_execute`). The loop has two instances: one without
/// hooks, whose dispatch checks nothing, and one that runs the hooks
/// before each instruction and at calls and returns. Each switches to the
/// other when the thread's hook mask changes, which only code the loop
/// calls out to can do.
fn execute(th: *Thread) Error!void {
    while (if (th.hookmask != 0) try runLoop(th, true) else try runLoop(th, false)) {}
}

/// Whether the loop instance `hooked` must hand over to the other one.
inline fn hookSwitch(comptime hooked: bool, th: *const Thread) bool {
    return (th.hookmask != 0) != hooked;
}

/// The next instruction, after the hooks for it when `hooked`
/// (`vmfetch`). A hook may grow the stack and move the frames, so `ci`
/// and `base` are reloaded.
inline fn nextOp(
    comptime hooked: bool,
    th: *Thread,
    ci: **Frame,
    pc: *[*]const u32,
    i: *Instruction,
    base: *[*]Value,
) Error!Dispatch {
    if (hooked) {
        try traceExec(th, pc.*);
        ci.* = th.frame();
        base.* = th.stack.ptr + ci.*.base();
    }
    return fetch(pc, i);
}

/// `nextOp` past the next instruction: an arithmetic fast path skipping
/// its `MMBIN`.
inline fn nextSkip(
    comptime hooked: bool,
    th: *Thread,
    ci: **Frame,
    pc: *[*]const u32,
    i: *Instruction,
    base: *[*]Value,
) Error!Dispatch {
    if (hooked) {
        pc.* += 1;
        return nextOp(true, th, ci, pc, i, base);
    }
    return fetchSkip(pc, i);
}

/// One instance of the loop. Returns false when the frame flagged
/// `fresh` returned, and true to switch instances, with the running
/// frame's `pc` saved at the next instruction.
fn runLoop(th: *Thread, comptime hooked: bool) Error!bool {
    // The inline prongs instantiate many inline calls at compile time.
    @setEvalBranchQuota(10_000);
    var ci: *Frame = th.frame();
    newframe: while (true) {
        const cl = th.stack[ci.func].asLuaClosure();
        const k: [*]const Value = cl.proto.k.ptr;
        var base: [*]Value = th.stack.ptr + ci.base();
        var pc: [*]const u32 = ci.pc;
        var i: Instruction = undefined;
        // A function's first instruction gets the call hook first
        // (`luaG_tracecall`); a vararg function's comes after
        // `VARARGPREP`, which is not traced.
        const starting = hooked and pc == cl.proto.code.ptr;
        const vararg = cl.proto.flags.vararg or cl.proto.flags.vararg_table;
        if (starting and !vararg) {
            try hookCall(th);
            ci = th.frame();
            base = th.stack.ptr + ci.base();
        }
        const first_op = if (hooked and !(starting and vararg))
            try nextOp(true, th, &ci, &pc, &i, &base)
        else
            fetch(&pc, &i);
        dispatch: switch (first_op) {
            .move => {
                put(&base[getA(i)], &base[getB(i)]);
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
            },
            .loadi => {
                base[getA(i)] = .int(opcodes.sbx(i));
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
            },
            .loadf => {
                base[getA(i)] = .float(@floatFromInt(opcodes.sbx(i)));
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
            },
            .loadk => {
                base[getA(i)] = k[opcodes.bx(i)];
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
            },
            .loadkx => {
                base[getA(i)] = k[opcodes.ax(pc[0])];
                pc += 1;
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
            },
            .loadfalse => {
                base[getA(i)] = .false;
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
            },
            .lfalseskip => {
                base[getA(i)] = .false;
                pc += 1;
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
            },
            .loadtrue => {
                base[getA(i)] = .true;
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
            },
            .loadnil => {
                const a = getA(i);
                for (0..@as(usize, getB(i)) + 1) |j| base[a + j] = .nil;
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
            },
            .getupval => {
                put(&base[getA(i)], cl.upvals()[getB(i)].v);
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
            },
            .setupval => {
                cl.upvals()[getB(i)].set(th.heap(), base[getA(i)]);
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
            },
            .gettabup => {
                const t = cl.upvals()[getB(i)].v.*;
                const key = k[getC(i)];
                if (t.tag == .table) {
                    const h = t.asTable();
                    const v = h.getShortStrCached(key.asString(), &cl.proto.kslot[getC(i)]);
                    if (!v.isNil() or th.state.fastTm(h.metatable, .index) == null) {
                        setv(&base[getA(i)], v);
                        continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
                    }
                }
                ci.pc = pc;
                const done = try getSlow(
                    th,
                    .vm,
                    ci,
                    cl.upvals()[getB(i)].v,
                    &k[getC(i)],
                    .{ .upval = getB(i) },
                    ci.base() + getA(i),
                );
                ci = th.frame();
                if (!done) continue :newframe;
                if (hookSwitch(hooked, th)) return true;
                base = th.stack.ptr + ci.base();
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
            },
            .gettable => {
                const t = base[getB(i)];
                const keyp = &base[getC(i)];
                const key = keyp.*;
                // Integer and short string keys inline; any other key goes
                // to `getSlow`, which takes it by pointer.
                if (t.tag == .table and (key.tag == .int or key.tag == .short_string)) {
                    const h = t.asTable();
                    const v = if (key.tag == .int) h.getInt(key.payload.int) else h.getShortStr(key.asString());
                    if (!v.isNil() or th.state.fastTm(h.metatable, .index) == null) {
                        setv(&base[getA(i)], v);
                        continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
                    }
                }
                ci.pc = pc;
                const done = try getSlow(
                    th,
                    .vm,
                    ci,
                    &base[getB(i)],
                    keyp,
                    .{ .slot = ci.base() + getB(i) },
                    ci.base() + getA(i),
                );
                ci = th.frame();
                if (!done) continue :newframe;
                if (hookSwitch(hooked, th)) return true;
                base = th.stack.ptr + ci.base();
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
            },
            .geti => {
                const t = base[getB(i)];
                if (t.tag == .table) {
                    const h = t.asTable();
                    const v = h.getInt(getC(i));
                    if (!v.isNil() or th.state.fastTm(h.metatable, .index) == null) {
                        setv(&base[getA(i)], v);
                        continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
                    }
                }
                ci.pc = pc;
                const origin: Origin = .{ .slot = ci.base() + getB(i) };
                const done = try getSlow(th, .vm, ci, &base[getB(i)], &Value.int(getC(i)), origin, ci.base() + getA(i));
                ci = th.frame();
                if (!done) continue :newframe;
                if (hookSwitch(hooked, th)) return true;
                base = th.stack.ptr + ci.base();
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
            },
            .getfield, .self => {
                const t = base[getB(i)];
                const keyp = &k[getC(i)];
                const key = keyp.*;
                if (op(i) == .self) setv(&base[getA(i) + 1], t);
                if (t.tag == .table) {
                    const h = t.asTable();
                    const v = h.getShortStr(key.asString());
                    if (!v.isNil()) {
                        setv(&base[getA(i)], v);
                        continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
                    }
                    const tm = th.state.fastTm(h.metatable, .index) orelse {
                        base[getA(i)] = .nil;
                        continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
                    };
                    // A class table as `__index`, the usual method lookup.
                    if (tm.tag == .table) {
                        const v2 = tm.asTable().getShortStr(key.asString());
                        if (!v2.isNil()) {
                            setv(&base[getA(i)], v2);
                            continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
                        }
                    }
                }
                ci.pc = pc;
                const done = try getSlow(
                    th,
                    .vm,
                    ci,
                    &base[getB(i)],
                    keyp,
                    .{ .slot = ci.base() + getB(i) },
                    ci.base() + getA(i),
                );
                ci = th.frame();
                if (!done) continue :newframe;
                if (hookSwitch(hooked, th)) return true;
                base = th.stack.ptr + ci.base();
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
            },
            .settabup => {
                const t = cl.upvals()[getA(i)].v.*;
                const key = k[getB(i)];
                const vp = if (getK(i)) &k[getC(i)] else &base[getC(i)];
                if (t.tag == .table) {
                    const h = t.asTable();
                    if (h.replaceShortStrCached(th.heap(), key.asString(), &cl.proto.kslot[getB(i)], vp.*))
                        continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
                    if (h.metatable == null) {
                        try setShortStrAt(th, h, key.asString(), vp);
                        continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
                    }
                }
                ci.pc = pc;
                const done = try setSlow(th, .vm, ci, cl.upvals()[getA(i)].v, &k[getB(i)], vp, .{ .upval = getA(i) });
                ci = th.frame();
                if (!done) continue :newframe;
                if (hookSwitch(hooked, th)) return true;
                base = th.stack.ptr + ci.base();
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
            },
            .settable => {
                const t = base[getA(i)];
                const keyp = &base[getB(i)];
                const key = keyp.*;
                const vp = if (getK(i)) &k[getC(i)] else &base[getC(i)];
                const v = vp.*;
                if (t.tag == .table) {
                    const h = t.asTable();
                    if (key.tag == .short_string) {
                        // A present key takes the value in place, metatable
                        // or not (`luaV_fastset`).
                        if (h.replaceShortStr(th.heap(), key.asString(), v))
                            continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
                        if (h.metatable == null) {
                            try setShortStrAt(th, h, key.asString(), vp);
                            continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
                        }
                    } else if (key.tag == .int and h.metatable == null) {
                        try h.setInt(th.heap(), key.payload.int, v);
                        continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
                    }
                }
                ci.pc = pc;
                const done = try setSlow(th, .vm, ci, &base[getA(i)], keyp, vp, .{ .slot = ci.base() + getA(i) });
                ci = th.frame();
                if (!done) continue :newframe;
                if (hookSwitch(hooked, th)) return true;
                base = th.stack.ptr + ci.base();
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
            },
            .seti => {
                const t = base[getA(i)];
                const vp = if (getK(i)) &k[getC(i)] else &base[getC(i)];
                const v = vp.*;
                if (t.tag == .table and t.asTable().metatable == null) {
                    try t.asTable().setInt(th.heap(), getB(i), v);
                    continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
                }
                ci.pc = pc;
                const done = try setSlow(
                    th,
                    .vm,
                    ci,
                    &base[getA(i)],
                    &Value.int(getB(i)),
                    vp,
                    .{ .slot = ci.base() + getA(i) },
                );
                ci = th.frame();
                if (!done) continue :newframe;
                if (hookSwitch(hooked, th)) return true;
                base = th.stack.ptr + ci.base();
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
            },
            .setfield => {
                const t = base[getA(i)];
                const keyp = &k[getB(i)];
                const key = keyp.*;
                const vp = if (getK(i)) &k[getC(i)] else &base[getC(i)];
                const v = vp.*;
                if (t.tag == .table) {
                    const h = t.asTable();
                    // A present key takes the value in place, metatable or
                    // not (`luaV_fastset`); a new key goes through the table.
                    if (h.replaceShortStr(th.heap(), key.asString(), v))
                        continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
                    if (h.metatable == null) {
                        try setShortStrAt(th, h, key.asString(), vp);
                        continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
                    }
                }
                ci.pc = pc;
                const done = try setSlow(th, .vm, ci, &base[getA(i)], keyp, vp, .{ .slot = ci.base() + getA(i) });
                ci = th.frame();
                if (!done) continue :newframe;
                if (hookSwitch(hooked, th)) return true;
                base = th.stack.ptr + ci.base();
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
            },
            .newtable => {
                const vb = opcodes.vb(i);
                var narray: u32 = opcodes.vc(i);
                if (getK(i)) narray += @as(u32, opcodes.ax(pc[0])) * (opcodes.max_vc + 1);
                pc += 1;
                const nhash: u32 = if (vb > 0) @as(u32, 1) << @intCast(vb - 1) else 0;
                base[getA(i)] = .table(try Table.create(th.heap(), narray, nhash));
                ci.pc = pc;
                if (th.state.gcDue()) {
                    // Registers above the new value are dead (`checkGC`).
                    th.top = ci.base() + getA(i) + 1;
                    gc.step(th);
                    ci = th.frame();
                    base = th.stack.ptr + ci.base();
                }
                if (hookSwitch(hooked, th)) return true;
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
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
                const ao: ArithOp = comptime arithOf(@enumFromInt(@intFromEnum(o)));
                if (rb.tag == .int and rc.tag == .int and ao.intOp()) {
                    const x = rb.payload.int;
                    const y = rc.payload.int;
                    switch (ao) {
                        .add => base[getA(i)] = .int(x +% y),
                        .sub => base[getA(i)] = .int(x -% y),
                        .mul => base[getA(i)] = .int(x *% y),
                        .mod, .idiv => {
                            if (y == 0) {
                                ci.pc = pc;
                                return zeroDivision(th, ao);
                            }
                            base[getA(i)] = .int(if (ao == .mod)
                                number.modInt(x, y) catch unreachable
                            else
                                number.divFloorInt(x, y) catch unreachable);
                        },
                        else => unreachable,
                    }
                    continue :dispatch try nextSkip(hooked, th, &ci, &pc, &i, &base);
                }
                if (rb.tag == .float and rc.tag == .float) {
                    base[getA(i)] = .float(floatArith(ao, rb.payload.float, rc.payload.float));
                    continue :dispatch try nextSkip(hooked, th, &ci, &pc, &i, &base);
                }
                if (rb.isNumber() and rc.isNumber()) {
                    base[getA(i)] = .float(floatArith(ao, rb.asNumber(), rc.asNumber()));
                    continue :dispatch try nextSkip(hooked, th, &ci, &pc, &i, &base);
                }
                // Otherwise the next instruction, an MMBIN, handles it.
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
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
                        .shl => number.shiftLeft(x, y),
                        .shr, .shri => number.shiftRight(x, y),
                        // R[A] := sC << R[B]
                        .shli => number.shiftLeft(y, x),
                        else => unreachable,
                    });
                    continue :dispatch try nextSkip(hooked, th, &ci, &pc, &i, &base);
                }
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
            },
            .mmbin, .mmbini, .mmbink => {
                const ra = base[getA(i)];
                var rb: Value = switch (op(i)) {
                    .mmbin => base[getB(i)],
                    .mmbini => .int(opcodes.sb(i)),
                    else => k[getB(i)],
                };
                var first = ra;
                var o1: Origin = .{ .slot = ci.base() + getA(i) };
                var o2: Origin = if (op(i) == .mmbin) .{ .slot = ci.base() + getB(i) } else .none;
                if (op(i) != .mmbin and getK(i)) {
                    first = rb;
                    rb = ra;
                    o2 = o1;
                    o1 = .none;
                }
                const event: Tm = @enumFromInt(getC(i));
                const dest = ci.base() + getA((pc - 2)[0]);
                ci.pc = pc;
                const done = try arithSlow(th, .vm, ci, &first, &rb, event, o1, o2, dest);
                ci = th.frame();
                if (!done) continue :newframe;
                if (hookSwitch(hooked, th)) return true;
                base = th.stack.ptr + ci.base();
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
            },
            .unm => {
                const rb = base[getB(i)];
                if (rb.tag == .int) {
                    base[getA(i)] = .int(0 -% rb.payload.int);
                } else if (rb.tag == .float) {
                    base[getA(i)] = .float(-rb.payload.float);
                } else {
                    ci.pc = pc;
                    const o: Origin = .{ .slot = ci.base() + getB(i) };
                    const done = try arithSlow(
                        th,
                        .vm,
                        ci,
                        &base[getB(i)],
                        &base[getB(i)],
                        .unm,
                        o,
                        o,
                        ci.base() + getA(i),
                    );
                    ci = th.frame();
                    if (!done) continue :newframe;
                    if (hookSwitch(hooked, th)) return true;
                    base = th.stack.ptr + ci.base();
                }
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
            },
            .bnot => {
                const rb = base[getB(i)];
                if (toIntStrict(rb)) |x| {
                    base[getA(i)] = .int(~x);
                } else {
                    ci.pc = pc;
                    const o: Origin = .{ .slot = ci.base() + getB(i) };
                    const done = try arithSlow(
                        th,
                        .vm,
                        ci,
                        &base[getB(i)],
                        &base[getB(i)],
                        .bnot,
                        o,
                        o,
                        ci.base() + getA(i),
                    );
                    ci = th.frame();
                    if (!done) continue :newframe;
                    if (hookSwitch(hooked, th)) return true;
                    base = th.stack.ptr + ci.base();
                }
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
            },
            .not => {
                base[getA(i)] = .boolean(base[getB(i)].isFalsy());
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
            },
            .len => {
                const rb = base[getB(i)];
                switch (rb.tag) {
                    .short_string, .long_string => base[getA(i)] = .int(@intCast(rb.asString().len())),
                    .table => if (th.state.fastTm(rb.asTable().metatable, .len) == null) {
                        base[getA(i)] = .int(@bitCast(rb.asTable().length()));
                    } else {
                        ci.pc = pc;
                        const origin: Origin = .{ .slot = ci.base() + getB(i) };
                        const done = try lenSlow(th, .vm, ci, &base[getB(i)], origin, ci.base() + getA(i));
                        ci = th.frame();
                        if (!done) continue :newframe;
                        if (hookSwitch(hooked, th)) return true;
                        base = th.stack.ptr + ci.base();
                    },
                    else => {
                        ci.pc = pc;
                        const origin: Origin = .{ .slot = ci.base() + getB(i) };
                        const done = try lenSlow(th, .vm, ci, &base[getB(i)], origin, ci.base() + getA(i));
                        ci = th.frame();
                        if (!done) continue :newframe;
                        if (hookSwitch(hooked, th)) return true;
                        base = th.stack.ptr + ci.base();
                    },
                }
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
            },
            .concat => {
                th.top = ci.base() + getA(i) + getB(i);
                ci.pc = pc;
                const done = try concatValues(th, .vm, getB(i));
                ci = th.frame();
                if (!done) continue :newframe;
                if (th.state.checkGc(th)) ci = th.frame();
                if (hookSwitch(hooked, th)) return true;
                base = th.stack.ptr + ci.base();
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
            },
            .close => {
                const level = ci.base() + getA(i);
                if (th.tbc.items.len == 0 or th.tbc.items[th.tbc.items.len - 1] < level) {
                    th.closeUpvals(level);
                    continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
                }
                ci.pc = pc;
                try closeLevel(th, level, .normal, true);
                ci = th.frame();
                if (hookSwitch(hooked, th)) return true;
                base = th.stack.ptr + ci.base();
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
            },
            .tbc => {
                ci.pc = pc;
                try newTbc(th, ci.base() + getA(i));
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
            },
            .jmp => {
                pc += @as(usize, @bitCast(@as(isize, opcodes.sj(i))));
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
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
                } else if (ra.tag == .float and rb.tag == .float) {
                    cond = switch (o) {
                        .eq => ra.payload.float == rb.payload.float,
                        .lt => ra.payload.float < rb.payload.float,
                        else => ra.payload.float <= rb.payload.float,
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
                        .eq => try equalSlow(th, .vm, ci, &base[getA(i)], &base[getB(i)]),
                        .lt => try orderSlow(th, .vm, ci, &base[getA(i)], &base[getB(i)], .lt),
                        else => try orderSlow(th, .vm, ci, &base[getA(i)], &base[getB(i)], .le),
                    };
                    ci = th.frame();
                    cond = r orelse continue :newframe;
                    base = th.stack.ptr + ci.base();
                    if (hookSwitch(hooked, th)) {
                        ci.pc = if (cond != getK(i)) pc + 1 else pc + jumpOffset(pc[0]);
                        return true;
                    }
                }
                if (cond != getK(i)) pc += 1 else pc += jumpOffset(pc[0]);
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
            },
            .eqk => {
                const cond = Value.rawEquals(base[getA(i)], k[getB(i)]);
                if (cond != getK(i)) pc += 1 else pc += jumpOffset(pc[0]);
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
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
                        .lti => try orderSlow(th, .vm, ci, &base[getA(i)], &imv, .lt),
                        .lei => try orderSlow(th, .vm, ci, &base[getA(i)], &imv, .le),
                        .gti => try orderSlow(th, .vm, ci, &imv, &base[getA(i)], .lt),
                        else => try orderSlow(th, .vm, ci, &imv, &base[getA(i)], .le),
                    };
                    ci = th.frame();
                    cond = r orelse continue :newframe;
                    base = th.stack.ptr + ci.base();
                    if (hookSwitch(hooked, th)) {
                        ci.pc = if (cond != getK(i)) pc + 1 else pc + jumpOffset(pc[0]);
                        return true;
                    }
                }
                if (cond != getK(i)) pc += 1 else pc += jumpOffset(pc[0]);
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
            },
            .@"test" => {
                const cond = !base[getA(i)].isFalsy();
                if (cond != getK(i)) pc += 1 else pc += jumpOffset(pc[0]);
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
            },
            .testset => {
                const rb = base[getB(i)];
                if (rb.isFalsy() == getK(i)) {
                    pc += 1;
                } else {
                    setv(&base[getA(i)], rb);
                    pc += jumpOffset(pc[0]);
                }
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
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
                if (callee.tag == .native_fn) {
                    try callNative(th, func, nres, callee.asNative());
                } else if (try preCall(th, func, nres)) {
                    ci = th.frame();
                    continue :newframe;
                }
                ci = th.frame();
                if (hookSwitch(hooked, th)) return true;
                base = th.stack.ptr + ci.base();
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
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
                var chain: u32 = 0;
                while (!th.stack[func].isFunction()) try insertCallTm(th, func, &chain);
                ci = th.frame();
                if (th.stack[func].tag == .lua_closure) {
                    const p = th.stack[func].asLuaClosure().proto;
                    const nargs = th.top - func - 1;
                    const dest = ci.func - delta;
                    const fsize: u32 = p.maxstacksize;
                    try th.growStack(@as(usize, dest) + 1 + @max(fsize, nargs));
                    for (0..nargs + 1) |j| put(&th.stack[dest + j], &th.stack[func + j]);
                    var n = nargs;
                    while (n < p.numparams) : (n += 1) th.stack[dest + 1 + n] = .nil;
                    th.top = dest + 1 + n;
                    ci.func = dest;
                    ci.top = dest + 1 + fsize;
                    ci.pc = p.code.ptr;
                    ci.extra_args = 0;
                    ci.flags.ncallmt = @intCast(chain);
                    ci.flags.tail = true;
                    continue :newframe;
                }
                // A native function: call it where it is, then return its
                // results from this frame.
                const callee = th.stack[func];
                const f = if (callee.tag == .native_fn) callee.asNative() else callee.asNativeClosure().f;
                try callNative(th, func, -1, f);
                ci = th.frame();
                ci.func -= delta;
                // The native may have set a hook: check the mask.
                if (try doReturn(th, true, func, th.top - func) == .exit) return false;
                if (hookSwitch(hooked, th)) return true;
                ci = th.frame();
                continue :newframe;
            },
            .@"return" => {
                const first = ci.base() + getA(i);
                const n: u32 = if (getB(i) != 0) getB(i) - 1 else th.top - first;
                ci.pc = pc;
                if (getK(i)) {
                    ci.aux = n;
                    if (th.top < ci.top) th.top = ci.top;
                    try closeLevel(th, ci.base(), .ktop, true);
                    ci = th.frame();
                }
                if (getC(i) != 0) ci.func -= ci.extra_args + getC(i);
                // A `__close` handler may have set a hook: check the mask.
                if (try doReturn(th, true, first, n) == .exit) return false;
                if (hookSwitch(hooked, th)) return true;
                ci = th.frame();
                continue :newframe;
            },
            .return0 => {
                if (hooked) {
                    ci.pc = pc;
                    switch (try doReturn(th, true, ci.base() + getA(i), 0)) {
                        .exit => return false,
                        .next => {},
                        .finished => if (hookSwitch(true, th)) return true,
                    }
                    ci = th.frame();
                    continue :newframe;
                }
                switch (try popFrame(th, ci, ci.base() + getA(i), 0)) {
                    .exit => return false,
                    // The caller's frame is the one below.
                    .next => ci = @ptrCast(@as([*]Frame, @ptrCast(ci)) - 1),
                    .finished => {
                        if (hookSwitch(false, th)) return true;
                        ci = th.frame();
                    },
                }
                continue :newframe;
            },
            .return1 => {
                if (hooked) {
                    ci.pc = pc;
                    switch (try doReturn(th, true, ci.base() + getA(i), 1)) {
                        .exit => return false,
                        .next => {},
                        .finished => if (hookSwitch(true, th)) return true,
                    }
                    ci = th.frame();
                    continue :newframe;
                }
                switch (try popFrame(th, ci, ci.base() + getA(i), 1)) {
                    .exit => return false,
                    // The caller's frame is the one below.
                    .next => ci = @ptrCast(@as([*]Frame, @ptrCast(ci)) - 1),
                    .finished => {
                        if (hookSwitch(false, th)) return true;
                        ci = th.frame();
                    },
                }
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
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
            },
            .forprep => {
                ci.pc = pc;
                if (try forPrep(th, base + getA(i))) pc += @as(usize, opcodes.bx(i)) + 1;
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
            },
            .tforprep => {
                const a = getA(i);
                const closing = base[a + 3];
                base[a + 3] = base[a + 2];
                base[a + 2] = closing;
                if (!closing.isFalsy()) {
                    ci.pc = pc;
                    try newTbc(th, ci.base() + a + 2);
                }
                pc += opcodes.bx(i);
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
            },
            .tforcall => {
                const a = getA(i);
                base[a + 5] = base[a + 3];
                base[a + 4] = base[a + 1];
                base[a + 3] = base[a];
                const func = ci.base() + a + 3;
                th.top = func + 3;
                ci.pc = pc;
                const callee = th.stack[func];
                if (callee.tag == .native_fn) {
                    try callNative(th, func, @intCast(getC(i)), callee.asNative());
                } else if (try preCall(th, func, @intCast(getC(i)))) {
                    ci = th.frame();
                    continue :newframe;
                }
                ci = th.frame();
                if (hookSwitch(hooked, th)) return true;
                base = th.stack.ptr + ci.base();
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
            },
            .tforloop => {
                if (!base[getA(i) + 3].isNil()) pc -= opcodes.bx(i);
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
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
                if (last > t.asize) try t.resize(th.heap(), last, if (t.isDummy()) 0 else t.nodeCount());
                while (n > 0) : (n -= 1) {
                    try t.setInt(th.heap(), last, base[a + n]);
                    last -= 1;
                }
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
            },
            .closure => {
                const p = cl.proto.p[opcodes.bx(i)];
                const ncl = try LuaClosure.create(th.heap(), p, @intCast(p.upvalues.len));
                for (p.upvalues, 0..) |u, j| {
                    const uv = if (u.instack) try th.findUpval(ci.base() + u.idx) else cl.upvals()[u.idx];
                    ncl.setUpval(th.heap(), j, uv);
                }
                base[getA(i)] = .luaClosure(ncl);
                ci.pc = pc;
                if (th.state.gcDue()) {
                    // Registers above the new value are dead (`checkGC`).
                    th.top = ci.base() + getA(i) + 1;
                    gc.step(th);
                    ci = th.frame();
                    base = th.stack.ptr + ci.base();
                }
                if (hookSwitch(hooked, th)) return true;
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
            },
            .vararg => {
                ci.pc = pc;
                const vatab: ?u32 = if (getK(i)) getB(i) else null;
                try getVarargs(th, ci, ci.base() + getA(i), @as(i32, @intCast(getC(i))) - 1, vatab);
                base = th.stack.ptr + ci.base();
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
            },
            .getvarg => {
                const rc = base[getC(i)];
                const nextra = ci.extra_args;
                var result: Value = .nil;
                if (toIntStrict(rc)) |n| {
                    const u: u64 = @bitCast(n -% 1);
                    if (u < nextra) result = th.stack[ci.func - nextra + @as(u32, @intCast(u))];
                } else if (rc.isString() and std.mem.eql(u8, rc.asString().bytes(), "n")) {
                    result = .int(nextra);
                }
                base[getA(i)] = result;
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
            },
            .errnnil => {
                if (!base[getA(i)].isNil()) {
                    ci.pc = pc;
                    const bx = opcodes.bx(i);
                    const name = if (bx > 0 and k[bx - 1].isString()) k[bx - 1].asString().bytes() else "?";
                    return th.runError("global '{s}' already defined", .{name});
                }
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
            },
            .varargprep => {
                ci.pc = pc;
                try adjustVarargs(th, ci, cl.proto);
                if (cl.proto.flags.vararg_table and th.state.gcDue()) {
                    // The parameters and the vararg table above them.
                    th.top = ci.base() + cl.proto.numparams + 1;
                    gc.step(th);
                    ci = th.frame();
                }
                if (hooked) {
                    try hookCall(th);
                    // The next instruction counts as a new line.
                    th.oldpc = 1;
                    ci = th.frame();
                }
                base = th.stack.ptr + ci.base();
                continue :dispatch try nextOp(hooked, th, &ci, &pc, &i, &base);
            },
            .extraarg => unreachable,
            // No opcode outside the set reaches the loop (`Dispatch`); a
            // checked `unreachable` here would put the check back.
            _ => {
                @setRuntimeSafety(false);
                unreachable;
            },
        }
    }
}

/// `Table.setShortStr` with the value by pointer: a `Value` argument
/// would make the interpreter loop copy the operand to a temporary on
/// every store, not only on the ones that add a key.
noinline fn setShortStrAt(th: *Thread, t: *Table, key: *String, vp: *const Value) error{OutOfMemory}!void {
    return t.setShortStr(th.heap(), key, vp.*);
}

/// The offset `pc` moves by to take the jump instruction `j` that follows a
/// test, counting the jump itself.
inline fn jumpOffset(j: Instruction) usize {
    return @bitCast(@as(isize, opcodes.sj(j)) + 1);
}

const Returned = enum {
    /// The frame was the fresh one: the loop exits.
    exit,
    /// Back in the calling Lua frame.
    next,
    /// Back in the calling Lua frame after `finishOp` completed the
    /// instruction that called a metamethod, which may have run anything.
    finished,
};

/// Returns from the running Lua frame with `n` results at `first`
/// (`luaD_poscall`). With `hooks`, runs the return hook when the thread
/// has a hook.
inline fn doReturn(th: *Thread, comptime hooks: bool, first: u32, n: u32) Error!Returned {
    if (hooks and th.hookmask != 0) {
        th.top = first + n;
        try retHook(th, first, n);
    }
    return popFrame(th, th.frame(), first, n);
}

/// `doReturn` without hooks, for the running frame `ret`.
inline fn popFrame(th: *Thread, ret: *Frame, first: u32, n: u32) Error!Returned {
    moveResults(th, ret.func, first, n, ret.nresults);
    const flags = ret.flags;
    th.frames.items.len -= 1;
    if (flags.fresh) return .exit;
    if (flags.finish_op) {
        try finishOp(th, th.frame());
        return .finished;
    }
    return .next;
}

/// Completes the instruction of Lua frame `ci` that a metamethod or a
/// yield interrupted, `luaV_finishOp`. The interrupted instruction is the
/// one before `ci.pc`; a metamethod's one result is at `top - 1`. It may
/// push a new metamethod frame (`__concat` with more to concatenate).
noinline fn finishOp(th: *Thread, ci: *Frame) Error!void {
    @branchHint(.cold);
    const inst = (ci.pc - 1)[0];
    const base = ci.base();
    switch (op(inst)) {
        .mmbin, .mmbini, .mmbink => {
            th.top -= 1;
            th.stack[base + getA((ci.pc - 2)[0])] = th.stack[th.top];
            th.top = ci.top;
        },
        .unm, .bnot, .len, .gettabup, .gettable, .geti, .getfield, .self => {
            th.top -= 1;
            th.stack[base + getA(inst)] = th.stack[th.top];
            th.top = ci.top;
        },
        .eq, .lt, .le, .lti, .lei, .gti, .gei => {
            th.top -= 1;
            const res = !th.stack[th.top].isFalsy();
            // The next instruction is the jump; skip it when the condition
            // failed.
            if (res != getK(inst)) ci.pc += 1;
            th.top = ci.top;
        },
        .concat => {
            // The handler was called with `top` one past the operands, and
            // its result sits there.
            const top = th.top - 1;
            const total = top - 1 - (base + getA(inst));
            th.stack[top - 2] = th.stack[top];
            th.top = top - 1;
            _ = try concatValues(th, .vm, total);
        },
        // Yielded while closing variables: run the instruction again to
        // close the rest (and, for RETURN, to return).
        .close => ci.pc -= 1,
        .@"return" => {
            th.top = base + getA(inst) + ci.aux;
            ci.pc -= 1;
        },
        // Calls, and stores through `__newindex`, have nothing to finish.
        else => {},
    }
}

// ---------------------------------------------------------------------------
// Metamethods
//
// Each slow path serves an instruction of the running Lua frame `ci`
// (`.vm`) or native code through the API below (`.native`). For an
// instruction, a handler written in Lua gets its own frame flagged
// `finish_op` and the slow path returns false: the interpreter runs the
// handler, and `finishOp` completes the instruction. For native code the
// handler runs to completion through `call`.
// ---------------------------------------------------------------------------

/// Who asks for a metamethod: an instruction of a Lua frame, or native
/// code through the API below.
const Caller = enum { vm, native };

/// Calls metamethod `f` with two or three arguments for `nresults` (0 or 1)
/// results; see above for `caller`. `ci` is the running Lua frame for
/// `.vm`.
inline fn callTm(
    th: *Thread,
    comptime caller: Caller,
    ci: *Frame,
    f: Value,
    a1: Value,
    a2: Value,
    a3: ?Value,
    nresults: i16,
) Error!?Value {
    if (caller == .vm) th.top = ci.top else try th.ensureStack(4);
    const func = th.top;
    th.push(f);
    th.push(a1);
    th.push(a2);
    if (a3) |v| th.push(v);
    if (caller == .vm) {
        if (try preCall(th, func, nresults)) {
            th.frame().flags.finish_op = true;
            return null;
        }
    } else {
        try call(th, func, nresults);
    }
    const r = if (nresults > 0) th.stack[func] else Value.nil;
    th.top = if (caller == .vm) th.frame().top else func;
    return r;
}

/// `t[key]` with `__index` (`luaV_finishget`) into stack slot `dest`.
/// False when a Lua metamethod frame was pushed. `origin` names `t` in a
/// type error.
noinline fn getSlow(
    th: *Thread,
    comptime caller: Caller,
    ci: *Frame,
    t_ptr: *const Value,
    key_ptr: *const Value,
    origin: Origin,
    dest: u32,
) Error!bool {
    @branchHint(.cold);
    var t = t_ptr.*;
    const key = key_ptr.*;
    var org = origin;
    for (0..max_tag_loop) |_| {
        var h: Value = undefined;
        if (t.tag == .table) {
            const tbl = t.asTable();
            const v = tbl.get(key);
            if (!v.isNil()) {
                th.stack[dest] = v;
                return true;
            }
            h = th.state.fastTm(tbl.metatable, .index) orelse {
                th.stack[dest] = .nil;
                return true;
            };
        } else {
            h = th.state.tmOf(t, .index) orelse return typeError(th, t, "index", org);
        }
        if (h.isFunction()) {
            th.stack[dest] = try callTm(th, caller, ci, h, t, key, null, 1) orelse return false;
            return true;
        }
        t = h;
        org = .none;
    }
    return th.runError("'__index' chain too long; possible loop", .{});
}

/// `t[key] = v` with `__newindex` (`luaV_finishset`). False when a Lua
/// metamethod frame was pushed.
noinline fn setSlow(
    th: *Thread,
    comptime caller: Caller,
    ci: *Frame,
    t_ptr: *const Value,
    key_ptr: *const Value,
    v_ptr: *const Value,
    origin: Origin,
) Error!bool {
    @branchHint(.cold);
    var t = t_ptr.*;
    const key = key_ptr.*;
    const v = v_ptr.*;
    var org = origin;
    for (0..max_tag_loop) |_| {
        var h: Value = undefined;
        if (t.tag == .table) {
            const tbl = t.asTable();
            if (!tbl.get(key).isNil()) {
                tbl.set(th.heap(), key, v) catch |e| return setError(th, e);
                return true;
            }
            h = th.state.fastTm(tbl.metatable, .newindex) orelse {
                tbl.set(th.heap(), key, v) catch |e| return setError(th, e);
                return true;
            };
        } else {
            h = th.state.tmOf(t, .newindex) orelse return typeError(th, t, "index", org);
        }
        if (h.isFunction()) {
            _ = try callTm(th, caller, ci, h, t, key, v, 0) orelse return false;
            return true;
        }
        t = h;
        org = .none;
    }
    return th.runError("'__newindex' chain too long; possible loop", .{});
}

fn setError(th: *Thread, e: Table.SetError) Error {
    @branchHint(.cold);
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.IndexIsNil => th.runError("table index is nil", .{}),
        error.IndexIsNaN => th.runError("table index is NaN", .{}),
    };
}

/// A binary or unary metamethod for `event` over `a` and `b` into stack
/// slot `dest`, or the error the manual gives when neither operand has one
/// (`luaT_trybinTM`). False when a Lua metamethod frame was pushed.
noinline fn arithSlow(
    th: *Thread,
    comptime caller: Caller,
    ci: *Frame,
    a_ptr: *const Value,
    b_ptr: *const Value,
    event: Tm,
    oa: Origin,
    ob: Origin,
    dest: u32,
) Error!bool {
    @branchHint(.cold);
    const a = a_ptr.*;
    const b = b_ptr.*;
    const h = th.state.tmOf(a, event) orelse th.state.tmOf(b, event) orelse {
        switch (event) {
            .band, .bor, .bxor, .shl, .shr, .bnot => {
                if (a.isNumber() and b.isNumber()) {
                    var buf: [128]u8 = undefined;
                    const o = if (toIntStrict(a) == null) oa else ob;
                    return th.runError("number{s} has no integer representation", .{debuginfo.varInfo(th, o, &buf)});
                }
                if (!a.isNumber()) return typeError(th, a, "perform bitwise operation on", oa);
                return typeError(th, b, "perform bitwise operation on", ob);
            },
            else => {
                if (!a.isNumber()) return typeError(th, a, "perform arithmetic on", oa);
                return typeError(th, b, "perform arithmetic on", ob);
            },
        }
    };
    th.stack[dest] = try callTm(th, caller, ci, h, a, b, null, 1) orelse return false;
    return true;
}

noinline fn lenSlow(
    th: *Thread,
    comptime caller: Caller,
    ci: *Frame,
    v_ptr: *const Value,
    origin: Origin,
    dest: u32,
) Error!bool {
    @branchHint(.cold);
    const v = v_ptr.*;
    const h = th.state.tmOf(v, .len) orelse {
        if (v.tag == .table) {
            th.stack[dest] = .int(@bitCast(v.asTable().length()));
            return true;
        }
        return typeError(th, v, "get length of", origin);
    };
    th.stack[dest] = try callTm(th, caller, ci, h, v, v, null, 1) orelse return false;
    return true;
}

/// `a == b` for operands not both numbers; null when a Lua `__eq` frame
/// was pushed.
noinline fn equalSlow(
    th: *Thread,
    comptime caller: Caller,
    ci: *Frame,
    a_ptr: *const Value,
    b_ptr: *const Value,
) Error!?bool {
    @branchHint(.cold);
    const a = a_ptr.*;
    const b = b_ptr.*;
    if (Value.rawEquals(a, b)) return true;
    if (a.tag != b.tag or (a.tag != .table and a.tag != .userdata)) return false;
    const h = th.state.fastTm(th.state.metatableOf(a), .eq) orelse
        th.state.fastTm(th.state.metatableOf(b), .eq) orelse return false;
    const r = try callTm(th, caller, ci, h, a, b, null, 1) orelse return null;
    return !r.isFalsy();
}

/// `a < b` or `a <= b` for operands not both numbers; null when a Lua
/// metamethod frame was pushed.
noinline fn orderSlow(
    th: *Thread,
    comptime caller: Caller,
    ci: *Frame,
    a_ptr: *const Value,
    b_ptr: *const Value,
    event: Tm,
) Error!?bool {
    @branchHint(.cold);
    const a = a_ptr.*;
    const b = b_ptr.*;
    if (a.isNumber() and b.isNumber()) return if (event == .lt) lessThanNum(a, b) else lessEqualNum(a, b);
    if (a.isString() and b.isString()) {
        const ord = std.mem.order(u8, a.asString().bytes(), b.asString().bytes());
        return if (event == .lt) ord == .lt else ord != .gt;
    }
    const h = th.state.tmOf(a, event) orelse th.state.tmOf(b, event) orelse {
        const ta = th.state.typeName(a);
        const tb = th.state.typeName(b);
        if (std.mem.eql(u8, ta, tb)) return th.runError("attempt to compare two {s} values", .{ta});
        return th.runError("attempt to compare {s} with {s}", .{ ta, tb });
    };
    const r = try callTm(th, caller, ci, h, a, b, null, 1) orelse return null;
    return !r.isFalsy();
}

/// Longest string a concatenation may build, PUC-Rio's `MAX_SIZE` less the
/// header.
const max_string_len: usize = std.math.maxInt(i64) - 64;

inline fn isConcatable(v: Value) bool {
    return v.isString() or v.isNumber();
}

/// Concatenates the `total` values below `top` into one at `top - total`
/// (`luaV_concat`), strings and numbers directly and anything else through
/// `__concat`, right to left. False when a Lua `__concat` frame was pushed
/// (only for `.vm`); `finishOp` continues from there.
noinline fn concatValues(th: *Thread, comptime caller: Caller, total_in: u32) Error!bool {
    var total = total_in;
    while (total > 1) {
        const top = th.top;
        const a = th.stack[top - 2];
        const b = th.stack[top - 1];
        if (!isConcatable(a) or !isConcatable(b)) {
            const h = th.state.tmOf(a, .concat) orelse th.state.tmOf(b, .concat) orelse {
                if (isConcatable(a)) return typeError(th, b, "concatenate", .{ .slot = top - 1 });
                return typeError(th, a, "concatenate", .{ .slot = top - 2 });
            };
            // The handler goes on top, so `top` still marks the operands.
            try th.ensureStack(3);
            th.push(h);
            th.push(a);
            th.push(b);
            if (caller == .vm) {
                if (try preCall(th, top, 1)) {
                    th.frame().flags.finish_op = true;
                    return false;
                }
            } else {
                try call(th, top, 1);
            }
            th.stack[top - 2] = th.stack[top];
            th.top = top - 1;
            total -= 1;
            continue;
        }
        // As many strings and numbers as there are below the top. A short
        // result is built in one pass, formatting each number once.
        var n: u32 = 1;
        while (n < total and isConcatable(th.stack[top - n - 1])) : (n += 1) {}
        const parts = th.stack[top - n .. top];
        var numbuf: [number.max_len]u8 = undefined;
        var short: [String.max_short_len]u8 = undefined;
        var len: usize = 0;
        var fits = true;
        for (parts) |v| {
            const piece = toStringBuf(v, &numbuf);
            if (piece.len >= max_string_len - len) {
                th.top = top - total;
                return th.runError("string length overflow", .{});
            }
            if (fits and len + piece.len <= short.len) {
                @memcpy(short[len..][0..piece.len], piece);
            } else fits = false;
            len += piece.len;
        }
        const s = if (fits) try th.state.newString(short[0..len]) else blk: {
            const out = try String.createLong(&th.state.heap, th.state.seed, len);
            copyParts(parts, out.mutableBytes());
            break :blk out;
        };
        th.stack[top - n] = .string(s);
        total -= n - 1;
        th.top -= n - 1;
    }
    return true;
}

fn copyParts(parts: []const Value, out: []u8) void {
    var numbuf: [number.max_len]u8 = undefined;
    var len: usize = 0;
    for (parts) |v| {
        const s = toStringBuf(v, &numbuf);
        @memcpy(out[len..][0..s.len], s);
        len += s.len;
    }
}

/// A string's bytes, or a number formatted into `buf`.
inline fn toStringBuf(v: Value, buf: *[number.max_len]u8) []const u8 {
    return switch (v.tag) {
        .int => number.formatInt(buf, v.payload.int),
        .float => number.formatFloat(buf, v.payload.float),
        else => v.asString().bytes(),
    };
}

// ---------------------------------------------------------------------------
// Operations for native code. Each may call metamethods, through `call`,
// so none can yield.
// ---------------------------------------------------------------------------

/// `t[key]` with `__index` (`lua_gettable`).
pub inline fn get(th: *Thread, t: Value, key: Value) Error!Value {
    if (t.tag == .table) {
        const v = if (key.tag == .int) t.asTable().getInt(key.payload.int) else t.asTable().get(key);
        if (!v.isNil() or th.state.fastTm(t.asTable().metatable, .index) == null) return v;
    }
    return getNative(th, t, key);
}

noinline fn getNative(th: *Thread, t: Value, key: Value) Error!Value {
    try th.ensureStack(1);
    const dest = th.top;
    th.top += 1;
    _ = try getSlow(th, .native, th.frame(), &t, &key, .none, dest);
    th.top = dest;
    return th.stack[dest];
}

/// `t[key] = v` with `__newindex` (`lua_settable`).
pub fn set(th: *Thread, t: Value, key: Value, v: Value) Error!void {
    _ = try setSlow(th, .native, th.frame(), &t, &key, &v, .none);
}

/// The arithmetic and bitwise operators, in `lua_arith`'s order.
pub const ArithOp = enum(u8) {
    add,
    sub,
    mul,
    mod,
    pow,
    div,
    idiv,
    band,
    bor,
    bxor,
    shl,
    shr,
    unm,
    bnot,

    fn intOp(a: ArithOp) bool {
        return a != .pow and a != .div;
    }

    fn event(a: ArithOp) Tm {
        return @enumFromInt(@intFromEnum(Tm.add) + @intFromEnum(a));
    }
};

comptime {
    std.debug.assert(ArithOp.bnot.event() == .bnot);
    std.debug.assert(ArithOp.shr.event() == .shr);
}

/// `a op b` with Lua's semantics and metamethods (`lua_arith`); for the
/// unary operators `b` is ignored. Numbers only: strings convert through
/// their metatable's handlers, as in Lua 5.5.
pub fn arith(th: *Thread, o: ArithOp, a: Value, b_in: Value) Error!Value {
    const b = if (o == .unm or o == .bnot) a else b_in;
    if (try rawArith(th, o, a, b)) |v| return v;
    try th.ensureStack(1);
    const dest = th.top;
    th.top += 1;
    _ = try arithSlow(th, .native, th.frame(), &a, &b, o.event(), .none, .none, dest);
    th.top = dest;
    return th.stack[dest];
}

/// `a op b` when both are numbers (and integers, for the bitwise
/// operators), else null (`luaO_rawarith`).
pub fn rawArith(th: *Thread, o: ArithOp, a: Value, b: Value) Error!?Value {
    switch (o) {
        .band, .bor, .bxor, .shl, .shr, .bnot => {
            const x = toIntStrict(a) orelse return null;
            const y = toIntStrict(b) orelse return null;
            return .int(switch (o) {
                .band => x & y,
                .bor => x | y,
                .bxor => x ^ y,
                .shl => number.shiftLeft(x, y),
                .shr => number.shiftRight(x, y),
                .bnot => ~x,
                else => unreachable,
            });
        },
        else => {
            if (a.tag == .int and b.tag == .int and o.intOp()) {
                const x = a.payload.int;
                const y = b.payload.int;
                return .int(switch (o) {
                    .add => x +% y,
                    .sub => x -% y,
                    .mul => x *% y,
                    .unm => 0 -% x,
                    .mod => number.modInt(x, y) catch return zeroDivision(th, o),
                    .idiv => number.divFloorInt(x, y) catch return zeroDivision(th, o),
                    else => unreachable,
                });
            }
            if (!a.isNumber() or !b.isNumber()) return null;
            if (o == .unm) return .float(-a.asNumber());
            return .float(floatArith(o, a.asNumber(), b.asNumber()));
        },
    }
}

/// `a == b` with `__eq` (`lua_compare` with `LUA_OPEQ`).
pub fn equal(th: *Thread, a: Value, b: Value) Error!bool {
    if (a.isNumber() and b.isNumber()) return Value.rawEquals(a, b);
    return (try equalSlow(th, .native, th.frame(), &a, &b)).?;
}

/// `a < b` with `__lt` (`lua_compare` with `LUA_OPLT`).
pub fn lessThan(th: *Thread, a: Value, b: Value) Error!bool {
    return (try orderSlow(th, .native, th.frame(), &a, &b, .lt)).?;
}

/// `a <= b` with `__le` (`lua_compare` with `LUA_OPLE`).
pub fn lessEqual(th: *Thread, a: Value, b: Value) Error!bool {
    return (try orderSlow(th, .native, th.frame(), &a, &b, .le)).?;
}

/// `#v` with `__len` (`lua_len`).
pub fn length(th: *Thread, v: Value) Error!Value {
    switch (v.tag) {
        .short_string, .long_string => return .int(@intCast(v.asString().len())),
        else => {
            try th.ensureStack(1);
            const dest = th.top;
            th.top += 1;
            _ = try lenSlow(th, .native, th.frame(), &v, .none, dest);
            th.top = dest;
            return th.stack[dest];
        },
    }
}

/// Replaces the `n` values on top with their concatenation, with
/// `__concat` (`lua_concat`); for `n` 0 pushes the empty string.
pub fn concat(th: *Thread, n: u32) Error!void {
    if (n == 0) {
        try th.ensureStack(1);
        th.push(.string(try th.state.newString("")));
        return;
    }
    _ = try concatValues(th, .native, n);
}

/// A number, or a string that converts to one by the manual's rules
/// (§3.4.3), as a number; else null. `tonumber` and the string library's
/// arithmetic metamethods use it.
pub inline fn toNumber(v: Value) ?Value {
    return switch (v.tag) {
        .int, .float => v,
        .short_string, .long_string => stringToNumber(v.asString().bytes()),
        else => null,
    };
}

/// A numeral as a number, or null (`luaO_str2num`).
pub fn stringToNumber(s: []const u8) ?Value {
    return switch (number.parse(s) orelse return null) {
        .int => |x| .int(x),
        .float => |x| .float(x),
    };
}

/// A number or numeric string with an exact integer value, as an integer
/// (`lua_tointeger`).
pub inline fn toInteger(v: Value) ?i64 {
    return toIntStrict(toNumber(v) orelse return null);
}

/// A string as is, or a number converted to one, else null
/// (`lua_tolstring` without the conversion in place).
pub fn toLString(state: *State, v: Value) error{OutOfMemory}!?*String {
    if (v.isString()) return v.asString();
    if (v.isNumber()) {
        const converted = try numberToString(state, v);
        return converted;
    }
    return null;
}

/// A number as `tostring` writes it, into `buf` (`luaO_tostringbuff`).
pub fn formatNumber(v: Value, buf: *[number.max_len]u8) []const u8 {
    return if (v.tag == .int) number.formatInt(buf, v.payload.int) else number.formatFloat(buf, v.asFloat());
}

/// A number converted to a string (`luaO_tostring`).
pub fn numberToString(state: *State, v: Value) error{OutOfMemory}!*String {
    var buf: [number.max_len]u8 = undefined;
    return state.newString(formatNumber(v, &buf));
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// "attempt to <what> a <type> value", with the variable's name when
/// `origin` has one, as `luaG_typeerror` does.
noinline fn typeError(th: *Thread, v: Value, comptime what: []const u8, origin: Origin) Error {
    @branchHint(.cold);
    var buf: [128]u8 = undefined;
    return th.runError("attempt to " ++ what ++ " a {s} value{s}", .{
        th.state.typeName(v),
        debuginfo.varInfo(th, origin, &buf),
    });
}

/// Calling a value with no `__call`: named by the calling instruction when
/// a Lua frame called it, else by its variable (`luaG_callerror`).
noinline fn callError(th: *Thread, func: u32) Error {
    @branchHint(.cold);
    var buf: [128]u8 = undefined;
    const info = if (debuginfo.callerName(th, th.frames.items.len - 1)) |n|
        debuginfo.format(n, &buf)
    else
        debuginfo.varInfo(th, .{ .slot = func }, &buf);
    return th.runError("attempt to call a {s} value{s}", .{ th.state.typeName(th.stack[func]), info });
}

noinline fn zeroDivision(th: *Thread, o: ArithOp) Error {
    @branchHint(.cold);
    if (o == .mod) return th.runError("attempt to perform 'n%0'", .{});
    return th.runError("attempt to divide by zero", .{});
}

fn forError(th: *Thread, v: Value, comptime what: []const u8) Error {
    @branchHint(.cold);
    return th.runError("bad 'for' " ++ what ++ " (number expected, got {s})", .{th.state.typeName(v)});
}

// ---------------------------------------------------------------------------
// Varargs and loops
// ---------------------------------------------------------------------------

/// Adjusts a vararg call (`VARARGPREP`, `luaT_adjustvarargs`). Without a
/// vararg table, copies the function and fixed parameters above the extra
/// arguments, so the extra arguments sit below the frame, and nils the
/// vararg parameter. With one, packs the extra arguments into a table
/// with their count in `n`, in the vararg parameter.
noinline fn adjustVarargs(th: *Thread, ci: *Frame, p: *const Proto) Error!void {
    const nfix = p.numparams;
    const total = th.top - ci.func - 1;
    const nextra = total - nfix;
    if (p.flags.vararg_table) {
        const heap = th.heap();
        const t = try Table.create(heap, nextra, 1);
        try t.setShortStr(heap, th.state.n_key, .int(nextra));
        const first = ci.func + 1 + nfix;
        for (0..nextra) |j| try t.setInt(heap, @intCast(j + 1), th.stack[first + j]);
        th.stack[first] = .table(t);
        return;
    }
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

/// Copies `wanted` extra arguments (all of them for -1, setting `top`) to
/// stack slot `where` (`VARARG`, `luaT_getvarargs`), from below the frame
/// or, when `vatab` names its register, from the vararg table.
noinline fn getVarargs(th: *Thread, ci: *Frame, where: u32, wanted_in: i32, vatab: ?u32) Error!void {
    var h: ?*Table = null;
    var nargs: u32 = ci.extra_args;
    if (vatab) |r| {
        const tv = th.stack[ci.base() + r];
        const nv: Value = if (tv.tag == .table) tv.asTable().getShortStr(th.state.n_key) else .nil;
        if (nv.tag != .int or @as(u64, @bitCast(nv.payload.int)) > std.math.maxInt(i32) / 2)
            return th.runError("vararg table has no proper 'n'", .{});
        h = tv.asTable();
        nargs = @intCast(nv.payload.int);
    }
    var wanted: u32 = undefined;
    var touse: u32 = undefined;
    if (wanted_in < 0) {
        wanted = nargs;
        touse = nargs;
        try th.growStack(@as(usize, where) + nargs);
        th.top = where + nargs;
    } else {
        wanted = @intCast(wanted_in);
        touse = @min(nargs, wanted);
    }
    if (h) |t| {
        for (0..touse) |j| th.stack[where + j] = t.getInt(@intCast(j + 1));
    } else {
        const first = ci.func - nargs;
        for (0..touse) |j| th.stack[where + j] = th.stack[first + j];
    }
    for (touse..wanted) |j| th.stack[where + j] = .nil;
}

/// Prepares a numeric for loop at `ra` (`FORPREP`, `forprep`). True when
/// the loop runs zero times. Strings convert, as everywhere a number is
/// expected.
noinline fn forPrep(th: *Thread, ra: [*]Value) Error!bool {
    @branchHint(.cold);
    const init = ra[0];
    const limit = ra[1];
    const step = ra[2];
    if (init.tag == .int and step.tag == .int) {
        const start = init.payload.int;
        const s = step.payload.int;
        if (s == 0) return th.runError("'for' step is zero", .{});
        var lim: i64 = undefined;
        if (toIntegerRounded(limit, if (s < 0) .ceil else .floor)) |l| {
            lim = l;
        } else {
            const f = toFloatCoerce(limit) orelse return forError(th, limit, "limit");
            // A float out of the integer range, or NaN.
            if (f > 0) {
                if (s < 0) return true;
                lim = std.math.maxInt(i64);
            } else {
                if (s > 0) return true;
                lim = std.math.minInt(i64);
            }
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
    const fl = toFloatCoerce(limit) orelse return forError(th, limit, "limit");
    const fs = toFloatCoerce(step) orelse return forError(th, step, "step");
    const fi = toFloatCoerce(init) orelse return forError(th, init, "initial value");
    if (fs == 0) return th.runError("'for' step is zero", .{});
    if (if (0 < fs) fl < fi else fi < fl) return true;
    ra[0] = .float(fl);
    ra[1] = .float(fs);
    ra[2] = .float(fi);
    return false;
}

// ---------------------------------------------------------------------------
// Numbers
// ---------------------------------------------------------------------------

fn arithOf(comptime o: opcodes.OpCode) ArithOp {
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

inline fn floatArith(a: ArithOp, x: f64, y: f64) f64 {
    return switch (a) {
        .add => x + y,
        .sub => x - y,
        .mul => x * y,
        .div => x / y,
        .pow => if (y == 2) x * x else libm.pow(x, y),
        .idiv => number.divFloorFloat(x, y),
        .mod => number.modFloat(x, y),
        else => unreachable,
    };
}

/// An integer, or a float with an exact integer value, as an integer; no
/// string conversion (`tointegerns`).
inline fn toIntStrict(v: Value) ?i64 {
    return switch (v.tag) {
        .int => v.payload.int,
        .float => number.floatToInt(v.payload.float, .exact),
        else => null,
    };
}

/// A number or numeric string as an integer, rounding a float as `mode`
/// says (`luaV_tointeger`).
fn toIntegerRounded(v: Value, mode: number.Rounding) ?i64 {
    const n = toNumber(v) orelse return null;
    return if (n.tag == .int) n.payload.int else number.floatToInt(n.payload.float, mode);
}

/// A number or numeric string as a float (`luaV_tonumber_`).
fn toFloatCoerce(v: Value) ?f64 {
    const n = toNumber(v) orelse return null;
    return n.asNumber();
}

fn lessThanNum(a: Value, b: Value) bool {
    if (a.tag == .int) {
        if (b.tag == .int) return a.payload.int < b.payload.int;
        return number.ltIntFloat(a.payload.int, b.payload.float);
    }
    if (b.tag == .float) return a.payload.float < b.payload.float;
    return number.ltFloatInt(a.payload.float, b.payload.int);
}

fn lessEqualNum(a: Value, b: Value) bool {
    if (a.tag == .int) {
        if (b.tag == .int) return a.payload.int <= b.payload.int;
        return number.leIntFloat(a.payload.int, b.payload.float);
    }
    if (b.tag == .float) return a.payload.float <= b.payload.float;
    return number.leFloatInt(a.payload.float, b.payload.int);
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
    try p.initSlots(a);
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

    // 1 // 0 raises. Without a source name the position is "?:?:", as for
    // a stripped chunk.
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
    try testing.expectEqualStrings("?:?: attempt to divide by zero", th.stack[func].asString().bytes());

    // Calling nil.
    const r = try makeProto(state, .{
        .maxstack = 2,
        .code = &.{ abc(.loadnil, 0, 0, 0), abc(.call, 0, 1, 1), abc(.return0, 0, 0, 0) },
    });
    th.top = func;
    th.push(.luaClosure(try mainClosure(state, r)));
    try testing.expect(!pcall(th, func, -1));
    try testing.expectEqualStrings("?:?: attempt to call a nil value", th.stack[func].asString().bytes());
}

fn raiseMemoryMessage(th: *Thread, _: u32) Error!u32 {
    return th.throw(.string(th.state.memerr));
}

fn failAllocation(_: *Thread, _: u32) Error!u32 {
    return error.OutOfMemory;
}

fn raiseAgain(th: *Thread, b: u32) Error!u32 {
    return th.throw(th.stack[b]);
}

test "a protected call's status says which kind of error ended it" {
    const state = try newState(false);
    defer state.destroy();
    const th = state.main;
    const func = th.top;
    try th.ensureStack(3);
    // A raised "not enough memory" is an ordinary error; an allocation
    // failure is a memory error, with the same object.
    th.push(.native(&raiseMemoryMessage));
    try testing.expectEqual(Status.runtime, pcallMsgh(th, func, 0, 0));
    th.top = func;
    th.push(.native(&failAllocation));
    try testing.expectEqual(Status.memory, pcallMsgh(th, func, 0, 0));
    try testing.expectEqual(state.memerr, th.stack[func].asString());
    // A message handler that raises again nests until the engine gives up.
    th.top = func;
    th.push(.native(&raiseAgain));
    th.push(.native(&raiseMemoryMessage));
    try testing.expectEqual(Status.handler, pcallMsgh(th, func + 1, 0, func));
    try testing.expectEqualStrings("error in error handling", th.stack[func + 1].asString().bytes());
    th.top = func;
    th.push(.native(&raiseMemoryMessage));
    try testing.expectEqual(Status.runtime, pcallMsgh(th, func, 0, 0));
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
    try testing.expectEqualStrings("?:?: stack overflow", th.stack[func].asString().bytes());
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

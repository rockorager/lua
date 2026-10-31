//! A Lua thread, one coroutine's value stack and call frames; not an OS thread.
//!
//! The stack is one growable array of values. Frames refer to it by index,
//! never by pointer, because it moves when it grows; open upvalues are the
//! one exception, and `reallocStack` repoints them. The interpreter caches a
//! pointer to the running frame's registers and reloads it after anything
//! that can grow the stack.

const Thread = @This();

const std = @import("std");
const builtin = @import("builtin");
const gc = @import("gc.zig");
const Value = @import("Value.zig");
const Proto = @import("Proto.zig");
const State = @import("State.zig");
const vm = @import("vm.zig");
const lua_options = @import("lua_options");
const capi = @import("capi/capi.zig");

const Error = Value.Error;

/// C-API builds keep 16 bytes in front of every thread: the C API's data
/// for it, then `lua_getextraspace`'s `LUA_EXTRASPACE`
/// (docs/slop/c-api.md). Other builds keep none.
pub const prefix_len: usize = if (lua_options.c_api) 16 else 0;
const Upval = Proto.Upval;

header: gc.Header,
gclist: ?*gc.Header = null,
state: *State,
stack: []Value,
/// The first free slot.
top: u32,
/// The call frames, innermost last. `frames.items[0]` is the base frame
/// for calls from Zig.
frames: std.ArrayList(Frame) = .empty,
/// Open upvalues, highest stack level first.
open_upvals: ?*Upval = null,
/// The next thread in the collector's list of threads with open upvalues
/// (`gc.Heap.twups`); the thread itself when it is not on the list.
twups: ?*Thread = null,
/// Stack levels of the pending to-be-closed variables, lowest first.
tbc: std.ArrayList(u32) = .empty,
/// The error object while an `error.LuaError` unwinds.
err: Value = .nil,
/// `.yield` while the coroutine is suspended, and while a yield unwinds
/// as `error.LuaError`; `.dead` once an error ended it.
status: Status = .ok,
/// With `status` `.dead`, which kind of error ended the coroutine, as a
/// dead coroutine's `lua_status` says; `vm.closeThread` starts from it.
died: vm.Status = .ok,
/// Nested entries into the interpreter from native code, which each use
/// Zig stack (PUC-Rio's C calls): `vm.call` from a native function, and a
/// coroutine resumed from this one counts its resumer's.
native_calls: u16 = 0,
/// Calls in progress that cannot be suspended: a yield inside one raises
/// "attempt to yield across a C-call boundary". The main thread always
/// has one.
nny: u16 = 0,
/// Stack index of the running protected call's message handler, or 0.
errfunc: u32 = 0,
/// Set by `vm.closeSelf` while the error it raises unwinds to the resume
/// or the `coroutine.close` that runs this thread.
closed_self: bool = false,
/// `vm.pcallMsgh` calls in progress, which catch every error. 32 bits,
/// unlike `native_calls`: two adjacent 16-bit counts let LLVM increment
/// both with one 32-bit load across the 16-bit stores of their separate
/// decrements, a store forwarding stall on every protected call from the
/// host (`results/lean-20261031.md`).
npcall: u32 = 0,
/// Set while the error unwinding is "error in error handling", so the
/// protected call that catches it reports `vm.Status.handler`
/// (`LUA_ERRERR`); every other raise clears it.
errerr: bool = false,
/// The debug hook (`lua_Hook`), called for the events in `hookmask`.
hook: ?Hook = null,
/// The events the hook gets, `HookMask` bits; 0 when there is no hook.
hookmask: u8 = 0,
/// False while a hook runs: hooks do not nest (`allowhook`).
allowhook: bool = true,
/// Instructions between count events, and the ones left before the next.
basehookcount: i32 = 0,
hookcount: i32 = 0,
/// The instruction of the last line event, to tell a new line or a jump
/// back from the next instruction (`L->oldpc`).
oldpc: u32 = 0,
/// The values a call or return event transfers: the first one's stack
/// offset from the function, and how many (`transferinfo`).
ftransfer: u16 = 0,
ntransfer: u16 = 0,

pub const Status = enum(u8) { ok, yield, dead };

/// The events a hook can ask for, `LUA_MASK*`.
pub const HookMask = struct {
    pub const call: u8 = 1;
    pub const ret: u8 = 2;
    pub const line: u8 = 4;
    pub const count: u8 = 8;
};

/// A hook event, `LUA_HOOK*`, in the order of their names.
pub const HookEvent = enum(u8) { call, ret, line, count, tail_call };

/// A debug hook (`lua_Hook`): runs on the thread with `frame` (an index
/// into `frames`) the frame the event happened in, and `line` the new
/// line for a line event, else -1.
pub const Hook = *const fn (th: *Thread, event: HookEvent, line: i32, frame: usize) Error!void;

/// Slots a native function may use without checking, `LUA_MINSTACK`.
pub const min_stack = 20;
/// Largest stack in slots, `LUAI_MAXSTACK`.
pub const max_stack = 1_000_000;
/// Slots past `max_stack` kept for handling a stack overflow,
/// `STACKERRSPACE`.
const error_space = 200;
/// Slots kept free above every frame's top, so a metamethod call (the
/// function and up to three arguments) needs no stack check.
pub const extra_stack = 5;
/// Deepest nesting of native-to-Lua calls, `LUAI_MAXCCALLS`.
pub const max_native_calls = 200;
/// Native stack that nested native-to-Lua calls, and the compiler's
/// nesting, may use below the host's call into Lua before "C stack
/// overflow", whatever the count of levels: with it a host thread of
/// 256 KiB runs any script, where some natives (`string.gsub` with a
/// function, as in the reference) need more than 1 KiB a level. Debug
/// builds' frames are several times larger, so they get more
/// (`results/stack-20261031.md`).
pub const max_native_stack: usize = if (builtin.mode == .Debug) 4 << 20 else 192 << 10;

const initial_stack = 2 * min_stack;

/// One active call.
pub const Frame = struct {
    /// Stack index of the function; its arguments and registers start at
    /// `func + 1`, and its results go to `func` and up.
    func: u32,
    /// One past the last slot the frame may use.
    top: u32,
    /// Lua frames: the next instruction. Saved here while the frame calls
    /// out, and before anything that can raise an error, so line numbers
    /// and `finishOp` see it. Native frames with `has_k`: the continuation,
    /// a `Value.KFn`.
    pc: [*]const u32 = undefined,
    /// Results the caller wants, or -1 for all of them.
    nresults: i16,
    flags: Flags,
    /// Lua vararg frames: how many extra arguments sit below `func`.
    /// Native frames: the continuation's context. Frames without one
    /// (the base frame, Zig functions): where the results the embedding
    /// API keeps for its caller start, or 0.
    extra_args: u32 = 0,
    /// Lua frames: the result count a `RETURN` saved while closing
    /// variables (PUC-Rio's `nres`). Native frames: the values a yield
    /// passes (`nyield`), or the protected call's function slot.
    aux: u32 = 0,
    /// Native frames in a yieldable protected call: the message handler to
    /// restore. With `extra_args` as the API's kept results: where they end.
    old_errfunc: u32 = 0,

    pub const Flags = packed struct(u16) {
        /// A Lua function, run by the interpreter.
        lua: bool = false,
        /// The interpreter loop was entered for this frame from Zig, so its
        /// return leaves the loop.
        fresh: bool = false,
        /// A metamethod called from an instruction of the frame below; its
        /// return finishes that instruction (`vm.finishOp`).
        finish_op: bool = false,
        /// A native frame inside `vm.pcallk` that may be suspended.
        ypcall: bool = false,
        /// A native frame with a continuation in `pc`.
        has_k: bool = false,
        /// Reused by a tail call.
        tail: bool = false,
        /// Native frames in a yieldable protected call: set when a resume
        /// unwound an error to this frame, so its continuation sees it.
        recover: bool = false,
        /// Running a hook for an event in this frame (`CIST_HOOKED`).
        hooked: bool = false,
        /// Native frames in a yieldable protected call: `allowhook` when
        /// the call started, restored after an error (`CIST_OAH`).
        oah: bool = false,
        /// `__call` handlers the call went through, each adding the
        /// called value as an extra first argument (`debug.getinfo`'s
        /// `extraargs`), at most `vm.max_call_chain`.
        ncallmt: u4 = 0,
        /// Calling a finalizer (`CIST_FIN`), which the debug library then
        /// names "__gc".
        fin: bool = false,
        _: u2 = 0,
    };

    pub inline fn base(f: *const Frame) u32 {
        return f.func + 1;
    }

    /// The continuation of a native frame, if it has one. Native frames
    /// keep it in the storage of `pc`, which only Lua frames use.
    pub inline fn k(f: *const Frame) ?Value.KFn {
        if (!f.flags.has_k) return null;
        const slot: *const Value.KFn = @ptrCast(&f.pc);
        return slot.*;
    }

    pub inline fn setK(f: *Frame, kf: Value.KFn, ctx: u32) void {
        const slot: *Value.KFn = @ptrCast(&f.pc);
        slot.* = kf;
        f.flags.has_k = true;
        f.extra_args = ctx;
    }
};

/// A new thread with an empty stack, linked into the state's heap.
pub fn create(state: *State) error{OutOfMemory}!*Thread {
    const gpa = state.heap.allocator();
    const raw = state.heap.raw();
    const stack = try raw.alloc(Value, initial_stack + extra_stack);
    errdefer raw.free(stack);
    @memset(stack, Value.nil);
    var frames: std.ArrayList(Frame) = .empty;
    try frames.append(gpa, baseFrame());
    errdefer frames.deinit(gpa);
    const th: *Thread = if (prefix_len == 0) try raw.create(Thread) else blk: {
        const mem = try raw.alignedAlloc(u8, .of(Thread), prefix_len + @sizeOf(Thread));
        @memset(mem[0..prefix_len], 0);
        break :blk @ptrCast(@alignCast(mem.ptr + prefix_len));
    };
    th.* = .{ .header = undefined, .state = state, .stack = stack, .top = 1, .frames = frames };
    th.twups = th;
    state.heap.link(&th.header, .thread);
    return th;
}

fn baseFrame() Frame {
    return .{ .func = 0, .top = 1 + min_stack, .nresults = 0, .flags = .{} };
}

/// Gives a new coroutine the hook of the thread that creates it, as
/// `lua_newthread` does.
pub fn inheritHook(th: *Thread, from: *const Thread) void {
    th.hook = from.hook;
    th.hookmask = from.hookmask;
    th.basehookcount = from.basehookcount;
    th.hookcount = from.basehookcount;
}

pub fn destroy(h: *gc.Heap, th: *Thread) void {
    closeAllUpvals(th);
    const gpa = h.allocator();
    h.raw().free(th.stack);
    th.frames.deinit(gpa);
    th.tbc.deinit(gpa);
    if (prefix_len == 0) return h.raw().destroy(th);
    capi.deinitThread(h, th);
    const p: [*]align(@alignOf(Thread)) u8 = @ptrCast(th);
    h.raw().free((p - prefix_len)[0 .. prefix_len + @sizeOf(Thread)]);
}

pub fn closeAllUpvals(th: *Thread) void {
    th.closeUpvals(0);
}

pub inline fn heap(th: *Thread) *gc.Heap {
    return &th.state.heap;
}

/// The running frame.
pub inline fn frame(th: *Thread) *Frame {
    return &th.frames.items[th.frames.items.len - 1];
}

/// Pushes a value; the caller made room.
pub inline fn push(th: *Thread, v: Value) void {
    th.stack[th.top] = v;
    th.top += 1;
}

/// Makes room for `n` more slots above `top`.
pub inline fn ensureStack(th: *Thread, n: u32) Error!void {
    if (th.stack.len - th.top < @as(usize, n) + extra_stack) try th.growStack(@as(usize, th.top) + n);
}

/// Grows the stack so slots below `needed` exist, plus `extra_stack`.
/// Past `max_stack` it raises "stack overflow", leaving `error_space` slots
/// to handle it; asking for more while handling one raises "error in error
/// handling".
pub fn growStack(th: *Thread, needed: usize) Error!void {
    if (needed + extra_stack <= th.stack.len) return;
    if (th.stack.len > max_stack + extra_stack) return th.errorInErrorHandling();
    if (needed > max_stack) {
        try th.reallocStack(max_stack + error_space + extra_stack);
        return th.runError("stack overflow", .{});
    }
    const want = @max(th.stack.len * 2, needed + extra_stack);
    try th.reallocStack(@min(want, max_stack + extra_stack));
}

/// Shrinks a stack that is much larger than its use, as after a stack
/// overflow, `luaD_shrinkstack`.
pub fn shrinkStack(th: *Thread) void {
    var inuse: usize = th.top;
    for (th.frames.items) |f| inuse = @max(inuse, f.top);
    inuse = @max(inuse + 1, min_stack);
    const size = th.stack.len - extra_stack;
    const max: usize = if (inuse > max_stack / 3) max_stack else inuse * 3;
    if (inuse <= max_stack and size > max) {
        const new_size: usize = if (inuse > max_stack / 2) max_stack else inuse * 2;
        // Shrinking is an optimization; keep the larger stack if it fails.
        th.reallocStack(new_size + extra_stack) catch return;
    }
}

fn reallocStack(th: *Thread, new_len: usize) error{OutOfMemory}!void {
    const old_len = th.stack.len;
    th.stack = try th.heap().raw().realloc(th.stack, new_len);
    if (new_len > old_len) @memset(th.stack[old_len..], Value.nil);
    var it = th.open_upvals;
    while (it) |uv| : (it = uv.open.next) uv.v = &th.stack[uv.open.level];
}

/// The open upvalue for stack slot `level`, created if needed.
pub fn findUpval(th: *Thread, level: u32) error{OutOfMemory}!*Upval {
    var link: *?*Upval = &th.open_upvals;
    while (link.*) |uv| {
        if (uv.open.level < level) break;
        if (uv.open.level == level) return uv;
        link = &uv.open.next;
    }
    const uv = try th.heap().raw().create(Upval);
    uv.* = .{
        .header = undefined,
        .v = &th.stack[level],
        .open = .{ .next = link.*, .prev = link, .level = level },
    };
    if (link.*) |n| n.open.prev = &uv.open.next;
    link.* = uv;
    th.heap().link(&uv.header, .upval);
    gc.linkTwups(th.heap(), th);
    return uv;
}

/// Closes every open upvalue at stack slot `level` or above.
pub fn closeUpvals(th: *Thread, level: u32) void {
    while (th.open_upvals) |uv| {
        if (uv.open.level < level) break;
        uv.unlink();
        uv.closed = uv.v.*;
        uv.v = &uv.closed;
        gc.closeUpval(th.heap(), uv);
    }
}

/// Puts the thread back to its base frame with an empty stack, for
/// `coroutine.close` and errors that escape every protected call.
pub fn resetFrames(th: *Thread) void {
    th.frames.items.len = 1;
    th.frames.items[0] = baseFrame();
    th.stack[0] = .nil;
    th.status = .ok;
    th.errfunc = 0;
}

/// Raises `v` as the error object. A message handler set by the running
/// protected call sees it first and its result is raised instead; a nil
/// object becomes "<no error object>", as `luaG_errormsg` does.
pub fn throw(th: *Thread, v: Value) Error {
    th.err = v;
    th.errerr = false;
    if (th.errfunc != 0) try vm.callMessageHandler(th);
    if (th.err.isNil()) th.err = .string(try th.state.newString("<no error object>"));
    return error.LuaError;
}

/// Raises `v` without the message handler, as `luaD_throw` does: for the
/// errors loading a chunk returns instead of raising (syntax errors, bad
/// binary chunks, unreadable files), which no handler sees.
pub fn throwRaw(th: *Thread, v: Value) Error {
    th.err = v;
    th.errerr = false;
    return error.LuaError;
}

/// Raises "error in error handling", without the message handler: a
/// stack overflow while handling one, or runaway nesting of handlers.
pub noinline fn errorInErrorHandling(th: *Thread) Error {
    @branchHint(.cold);
    th.err = .string(try th.state.newString("error in error handling"));
    th.errerr = true;
    return error.LuaError;
}

/// Raises a formatted error message, prefixed with the chunk and line of
/// the running Lua function as `error` with level 1 does.
pub noinline fn runError(th: *Thread, comptime fmt: []const u8, args: anytype) Error {
    @branchHint(.cold);
    return runErrorArgs(th, fmt, &FormatArg.list(fmt, args));
}

noinline fn runErrorArgs(th: *Thread, fmt: []const u8, args: []const FormatArg) Error {
    @branchHint(.cold);
    var aw: std.Io.Writer.Allocating = .init(th.heap().allocator());
    defer aw.deinit();
    const w = &aw.writer;
    const f = th.frame();
    if (f.flags.lua) writePosition(w, th, f) catch return error.OutOfMemory;
    FormatArg.write(w, fmt, args) catch return error.OutOfMemory;
    const s = try th.state.newString(aw.written());
    return th.throw(.string(s));
}

/// An argument of an error message's format. The functions that raise
/// formatted errors are generic in their format and arguments, and with
/// `std.fmt` each instance carried its own copy of the formatting, about
/// a kilobyte each over a hundred instances; they convert their arguments
/// to a list of these and share one formatter that reads the format at
/// run time (`docs/slop/results/lean-20261031.md`). It takes `{s}`, `{d}`,
/// `{c}`, and `{}` for a string or an integer, and `{d}` for a float as
/// `std.fmt` writes it.
pub const FormatArg = union(enum) {
    s: []const u8,
    d: i64,
    u: u64,
    c: u8,
    f: f64,

    /// The arguments of `fmt` in the tuple `args`.
    pub inline fn list(comptime fmt: []const u8, args: anytype) [fieldsOf(@TypeOf(args)).len]FormatArg {
        const specs = comptime parse(fmt);
        const fields = comptime fieldsOf(@TypeOf(args));
        if (specs.len != fields.len) @compileError("format \"" ++ fmt ++ "\" does not match its arguments");
        var out: [fields.len]FormatArg = undefined;
        inline for (fields, 0..) |field, i| out[i] = from(specs[i], @field(args, field.name));
        return out;
    }

    fn fieldsOf(T: type) []const std.builtin.Type.StructField {
        return @typeInfo(T).@"struct".fields;
    }

    fn from(comptime spec: u8, x: anytype) FormatArg {
        const T = @TypeOf(x);
        switch (@typeInfo(T)) {
            .int, .comptime_int => {
                if (spec == 'c') return .{ .c = x };
                if (spec == 's') @compileError("{s} for an integer");
                if (T != comptime_int and @typeInfo(T).int.bits >= 64 and
                    @typeInfo(T).int.signedness == .unsigned) return .{ .u = x };
                return .{ .d = x };
            },
            .float => {
                if (spec != 'd') @compileError("{d} for a float");
                return .{ .f = x };
            },
            else => {
                if (spec != 's' and spec != 0) @compileError("{" ++ &[_]u8{spec} ++ "} for a " ++ @typeName(T));
                const s: []const u8 = x;
                return .{ .s = s };
            },
        }
    }

    /// The specifier of each placeholder in `fmt`: 's', 'd', 'c', or 0 for
    /// `{}`.
    fn parse(comptime fmt: []const u8) []const u8 {
        comptime {
            var specs: []const u8 = "";
            var i: usize = 0;
            while (i < fmt.len) : (i += 1) {
                if (fmt[i] == '{' and i + 1 < fmt.len and fmt[i + 1] == '{') {
                    i += 1;
                } else if (fmt[i] == '{') {
                    if (fmt[i + 1] == '}') {
                        specs = specs ++ &[_]u8{0};
                        i += 1;
                    } else if (i + 2 < fmt.len and fmt[i + 2] == '}' and isSpec(fmt[i + 1])) {
                        specs = specs ++ &[_]u8{fmt[i + 1]};
                        i += 2;
                    } else @compileError("unsupported placeholder in \"" ++ fmt ++ "\"");
                }
            }
            return specs;
        }
    }

    fn isSpec(c: u8) bool {
        return c == 's' or c == 'd' or c == 'c';
    }

    /// Writes `fmt` with its placeholders replaced by `args` in order.
    pub fn write(w: *std.Io.Writer, fmt: []const u8, args: []const FormatArg) std.Io.Writer.Error!void {
        var start: usize = 0;
        var i: usize = 0;
        var n: usize = 0;
        while (i < fmt.len) : (i += 1) {
            const c = fmt[i];
            if (c != '{' and c != '}') continue;
            try w.writeAll(fmt[start..i]);
            if (i + 1 < fmt.len and fmt[i + 1] == c) {
                try w.writeByte(c);
                i += 1;
            } else {
                while (fmt[i] != '}') i += 1;
                switch (args[n]) {
                    .s => |s| try w.writeAll(s),
                    .d => |d| try w.printInt(d, 10, .lower, .{}),
                    .u => |u| try w.printInt(u, 10, .lower, .{}),
                    .c => |b| try w.writeByte(b),
                    .f => |f| try w.print("{d}", .{f}),
                }
                n += 1;
            }
            start = i + 1;
        }
        try w.writeAll(fmt[start..]);
    }
};

test "FormatArg formats as std.fmt does" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const fmt = "{{a}} {s}:{d} {} {c}{} {d}}}";
    const u: u64 = std.math.maxInt(u64);
    const args = .{ "x", @as(i32, -7), "y", @as(u8, 'z'), @as(usize, 3), u };
    try FormatArg.write(&w, fmt, &FormatArg.list(fmt, args));
    try std.testing.expectEqualStrings("{a} x:-7 y z3 18446744073709551615}", w.buffered());
}

/// "chunk:line: " for the instruction Lua frame `f` is running, as
/// `luaG_addinfo` writes it.
pub fn writePosition(w: *std.Io.Writer, th: *Thread, f: *const Frame) std.Io.Writer.Error!void {
    const p = th.stack[f.func].asLuaClosure().proto;
    const src = p.source orelse return w.writeAll("?:?: ");
    try writeChunkId(w, src.bytes());
    if (p.lineAt(currentPc(p, f))) |line| {
        try w.print(":{d}: ", .{line});
    } else {
        try w.writeAll(":-1: ");
    }
}

/// The index of the instruction Lua frame `f` is running.
pub fn currentPc(p: *const Proto, f: *const Frame) usize {
    return ((@intFromPtr(f.pc) - @intFromPtr(p.code.ptr)) / 4) -| 1;
}

/// The chunk name as messages show it, PUC-Rio's `luaO_chunkid`: "=name"
/// as is, "@file" as the file name, and source text as `[string "..."]`.
pub fn writeChunkId(w: *std.Io.Writer, source: []const u8) std.Io.Writer.Error!void {
    const id_size = 60;
    if (source.len > 0 and source[0] == '=') {
        try w.writeAll(source[1..@min(source.len, id_size)]);
    } else if (source.len > 0 and source[0] == '@') {
        const name = source[1..];
        if (name.len < id_size) {
            try w.writeAll(name);
        } else {
            try w.writeAll("...");
            try w.writeAll(name[name.len - (id_size - 4) ..]);
        }
    } else {
        const line_end = std.mem.findScalar(u8, source, '\n') orelse source.len;
        const room = id_size - "[string \"...\"]".len - 1;
        try w.writeAll("[string \"");
        if (line_end < source.len or source.len >= room) {
            try w.writeAll(source[0..@min(line_end, room)]);
            try w.writeAll("...");
        } else {
            try w.writeAll(source);
        }
        try w.writeAll("\"]");
    }
}

const testing = std.testing;

test "open upvalues follow their slots when the stack moves" {
    const state = try State.create(testing.allocator, .{});
    defer state.destroy();
    const th = state.main;
    th.push(.int(10));
    th.push(.int(20));
    const a = try th.findUpval(1);
    const b = try th.findUpval(2);
    try testing.expectEqual(a, try th.findUpval(1));
    const old = th.stack.ptr;
    try th.ensureStack(10_000);
    try testing.expect(th.stack.ptr != old);
    try testing.expectEqual(@as(i64, 10), a.v.asInt());
    th.stack[2] = .int(21);
    try testing.expectEqual(@as(i64, 21), b.v.asInt());
    th.closeUpvals(2);
    try testing.expect(!b.isOpen());
    try testing.expect(a.isOpen());
    th.stack[2] = .int(99);
    try testing.expectEqual(@as(i64, 21), b.v.asInt());
    th.closeUpvals(0);
    try testing.expect(th.open_upvals == null);
    try testing.expectEqual(@as(i64, 10), a.v.asInt());
}

test "chunk ids" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeChunkId(&w, "=stdin");
    try w.writeAll("|");
    try writeChunkId(&w, "@main.lua");
    try w.writeAll("|");
    try writeChunkId(&w, "return 1\nreturn 2");
    try testing.expectEqualStrings("stdin|main.lua|[string \"return 1...\"]", w.buffered());
}

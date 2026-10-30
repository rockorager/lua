//! A Lua thread, one coroutine's value stack and call frames; not an OS thread.
//!
//! The stack is one growable array of values. Frames refer to it by index,
//! never by pointer, because it moves when it grows; open upvalues are the
//! one exception, and `growStack` repoints them. The interpreter caches a
//! pointer to the running frame's registers and reloads it after anything
//! that can grow the stack.

const Thread = @This();

const std = @import("std");
const gc = @import("gc.zig");
const Value = @import("Value.zig");
const Proto = @import("Proto.zig");
const State = @import("State.zig");

const Error = Value.Error;
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
/// The error object while an `error.LuaError` unwinds.
err: Value = .nil,
status: Status = .ok,
/// Nested entries into the interpreter from native code, which each use
/// Zig stack: `vm.call` from a native function, metamethods called from
/// native code.
native_calls: u16 = 0,

pub const Status = enum(u8) { ok, yield, dead };

/// Slots a native function may use without checking, `LUA_MINSTACK`.
pub const min_stack = 20;
/// Largest stack in slots, `LUAI_MAXSTACK`.
pub const max_stack = 1_000_000;
/// Slots kept free above every frame's top, so a metamethod call (the
/// function and up to three arguments) needs no stack check.
pub const extra_stack = 5;
/// Deepest nesting of native-to-Lua calls, `LUAI_MAXCCALLS`.
pub const max_native_calls = 200;

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
    /// and `finishOp` see it.
    pc: [*]const u32 = undefined,
    /// Results the caller wants, or -1 for all of them.
    nresults: i16,
    /// Vararg Lua functions: how many extra arguments sit below `func`.
    extra_args: u32 = 0,
    flags: Flags,

    pub const Flags = packed struct(u8) {
        /// A Lua function, run by the interpreter.
        lua: bool = false,
        /// The interpreter loop was entered for this frame from Zig, so its
        /// return leaves the loop.
        fresh: bool = false,
        /// A metamethod called from an instruction of the frame below; its
        /// return finishes that instruction (`vm.finishOp`).
        finish_op: bool = false,
        _: u5 = 0,
    };

    pub inline fn base(f: *const Frame) u32 {
        return f.func + 1;
    }
};

/// A new thread with an empty stack, linked into the state's heap.
pub fn create(state: *State) error{OutOfMemory}!*Thread {
    const gpa = state.heap.allocator();
    const stack = try gpa.alloc(Value, initial_stack + extra_stack);
    errdefer gpa.free(stack);
    @memset(stack, Value.nil);
    var frames: std.ArrayList(Frame) = .empty;
    try frames.append(gpa, .{ .func = 0, .top = 1 + min_stack, .nresults = 0, .flags = .{} });
    errdefer frames.deinit(gpa);
    const th = try gpa.create(Thread);
    th.* = .{ .header = undefined, .state = state, .stack = stack, .top = 1, .frames = frames };
    state.heap.link(&th.header, .thread);
    return th;
}

pub fn destroy(h: *gc.Heap, th: *Thread) void {
    closeAllUpvals(th);
    const gpa = h.allocator();
    gpa.free(th.stack);
    th.frames.deinit(gpa);
    gpa.destroy(th);
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
/// Raises "stack overflow" past `max_stack`.
pub fn growStack(th: *Thread, needed: usize) Error!void {
    if (needed + extra_stack <= th.stack.len) return;
    if (needed > max_stack) {
        // Leave room to build and handle the error, as PUC-Rio does.
        if (th.stack.len < max_stack + 200) try th.reallocStack(max_stack + 200 + extra_stack);
        return th.runError("stack overflow", .{});
    }
    const want = @max(th.stack.len * 2, needed + extra_stack);
    try th.reallocStack(@min(want, max_stack + extra_stack));
}

fn reallocStack(th: *Thread, new_len: usize) error{OutOfMemory}!void {
    const old_len = th.stack.len;
    th.stack = try th.heap().allocator().realloc(th.stack, new_len);
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
    const uv = try th.heap().allocator().create(Upval);
    uv.* = .{
        .header = undefined,
        .v = &th.stack[level],
        .open = .{ .next = link.*, .prev = link, .level = level },
    };
    if (link.*) |n| n.open.prev = &uv.open.next;
    link.* = uv;
    th.heap().link(&uv.header, .upval);
    return uv;
}

/// Closes every open upvalue at stack slot `level` or above.
pub fn closeUpvals(th: *Thread, level: u32) void {
    while (th.open_upvals) |uv| {
        if (uv.open.level < level) break;
        uv.unlink();
        uv.closed = uv.v.*;
        uv.v = &uv.closed;
    }
}

/// Raises `v` as the error object.
pub fn throw(th: *Thread, v: Value) Error {
    th.err = v;
    return error.LuaError;
}

/// Raises a formatted error message, prefixed with the chunk and line of
/// the running Lua function as `error` with level 1 does.
pub fn runError(th: *Thread, comptime fmt: []const u8, args: anytype) Error {
    var aw: std.Io.Writer.Allocating = .init(th.heap().allocator());
    defer aw.deinit();
    const w = &aw.writer;
    const f = th.frame();
    if (f.flags.lua) {
        const p = th.stack[f.func].asLuaClosure().proto;
        const pc = @intFromPtr(f.pc) - @intFromPtr(p.code.ptr);
        if (p.lineAt(pc / 4 -| 1)) |line| {
            writeChunkId(w, if (p.source) |s| s.bytes() else "?") catch return error.OutOfMemory;
            w.print(":{d}: ", .{line}) catch return error.OutOfMemory;
        }
    }
    w.print(fmt, args) catch return error.OutOfMemory;
    const s = try th.state.newString(aw.written());
    return th.throw(.string(s));
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
        if (line_end < source.len or source.len > room) {
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

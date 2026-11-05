//! What the standard libraries share, the counterpart of the reference's
//! lauxlib.c and of the lapi.c calls its libraries make: argument checks with
//! the reference's messages, errors positioned at the calling Lua function, a
//! string buffer that starts on the Zig stack, and the metamethod-aware
//! indexing, length, comparison, and `tostring` that natives need.
//!
//! The core does the work: `debuginfo` positions and names errors, and
//! `vm` does conversions and metamethod-aware operations; these are the
//! names the libraries call them by.

const std = @import("std");
const Writer = std.Io.Writer;
const Value = @import("../Value.zig");
const String = @import("../String.zig");
const Table = @import("../Table.zig");
const Thread = @import("../Thread.zig");
const State = @import("../State.zig");
const gc = @import("../gc.zig");
const vm = @import("../vm.zig");
const Proto = @import("../Proto.zig");
const opcodes = @import("../opcodes.zig");
const number = @import("../number.zig");

pub const Error = Value.Error;

const debuginfo = @import("../debuginfo.zig");

/// Raises a message as `luaL_error` does: prefixed with "chunk:line:" when
/// the function that called the running native is a Lua function.
pub const raise = debuginfo.raise;

/// `luaL_checkstack`: room for `n` more values, or "stack overflow (msg)".
pub fn checkStack(th: *Thread, n: usize, comptime msg: []const u8) Error!void {
    if (th.top + n + Thread.extra_stack > Thread.max_stack) return raise(th, "stack overflow (" ++ msg ++ ")", .{});
    try th.ensureStack(@intCast(n));
}

/// A native's arguments, `stack[base..top]`, and the name its messages use
/// when neither the call site nor the loaded modules name the function.
/// Argument numbers are Lua's, from 1. The checks that do not inline take
/// `*const Args`: by value, each call site copied the 40 bytes to a stack
/// slot of its own in the native's frame (`results/stack-20261031.md`).
pub const Args = struct {
    th: *Thread,
    base: u32,
    /// One past the last argument, as it was on entry, so values the native
    /// pushes later are not taken for arguments.
    top: u32,
    name: []const u8,

    pub inline fn init(th: *Thread, base: u32, name: []const u8) Args {
        return .{ .th = th, .base = base, .top = th.top, .name = name };
    }

    /// The number of arguments.
    pub inline fn count(a: Args) u32 {
        return a.top - a.base;
    }

    /// The stack slot of argument `n`.
    pub inline fn slot(a: Args, n: u32) u32 {
        return a.base + n - 1;
    }

    /// Argument `n`, or nil when it is absent. One return of a variable:
    /// an `if` choosing between two values makes LLVM choose between
    /// their addresses, which keeps both in stack slots of the caller
    /// (`results/stack-20261031.md`).
    pub inline fn get(a: Args, n: u32) Value {
        const i = a.slot(n);
        var v: Value = .nil;
        if (i < a.top) v = a.th.stack[i];
        return v;
    }

    pub inline fn isNone(a: Args, n: u32) bool {
        return a.slot(n) >= a.top;
    }

    pub inline fn isNoneOrNil(a: Args, n: u32) bool {
        return a.get(n).isNil();
    }

    /// `luaL_argerror`: "bad argument #n to 'name' (msg)".
    pub noinline fn argError(a: *const Args, n: u32, comptime fmt: []const u8, args: anytype) Error {
        @branchHint(.cold);
        var buf: [256]u8 = undefined;
        const msg = std.mem.print(&buf, fmt, args) catch buf[0..];
        return debuginfo.argError(a.th, n, a.name, msg);
    }

    /// `luaL_typeerror`: "bad argument #n to 'name' (T expected, got U)".
    pub noinline fn typeError(a: *const Args, n: u32, expected: []const u8) Error {
        @branchHint(.cold);
        const got = if (a.isNone(n)) "no value" else typeName(a.th.state, a.get(n));
        return a.argError(n, "{s} expected, got {s}", .{ expected, got });
    }

    /// `luaL_checkany`.
    pub fn checkAny(a: *const Args, n: u32) Error!void {
        if (a.isNone(n)) return a.argError(n, "value expected", .{});
    }

    /// `luaL_checkinteger`.
    pub fn checkInteger(a: *const Args, n: u32) Error!i64 {
        const v = a.get(n);
        if (v.tag == .int) return v.payload.int;
        if (toInteger(v)) |i| return i;
        if (toNumber(v) != null) return a.argError(n, "number has no integer representation", .{});
        return a.typeError(n, "number");
    }

    /// `luaL_optinteger`.
    pub fn optInteger(a: *const Args, n: u32, def: i64) Error!i64 {
        return if (a.isNoneOrNil(n)) def else a.checkInteger(n);
    }

    /// `luaL_checknumber`.
    pub fn checkNumber(a: *const Args, n: u32) Error!f64 {
        const v = a.get(n);
        if (v.tag == .float) return v.payload.float;
        return toNumber(v) orelse a.typeError(n, "number");
    }

    /// `luaL_optnumber`.
    pub fn optNumber(a: *const Args, n: u32, def: f64) Error!f64 {
        return if (a.isNoneOrNil(n)) def else a.checkNumber(n);
    }

    /// `luaL_checklstring`: a string argument, or a number converted to one
    /// in place, as `lua_tolstring` does.
    pub fn checkString(a: *const Args, n: u32) Error!*String {
        const v = a.get(n);
        if (v.isString()) return v.asString();
        if (v.isNumber()) {
            const s = try numberToString(a.th.state, v);
            a.th.stack[a.slot(n)] = .string(s);
            return s;
        }
        return a.typeError(n, "string");
    }

    /// `luaL_optlstring`.
    pub fn optString(a: *const Args, n: u32, def: []const u8) Error![]const u8 {
        return if (a.isNoneOrNil(n)) def else (try a.checkString(n)).bytes();
    }

    /// `luaL_checktype(L, n, LUA_TTABLE)`.
    pub fn checkTable(a: *const Args, n: u32) Error!*Table {
        const v = a.get(n);
        if (v.tag != .table) return a.typeError(n, "table");
        return v.asTable();
    }
};

/// The type name messages use for `v`: its metatable's `__name` when that is
/// a string (`luaL_typeerror`), "light userdata", or the basic type's name.
pub fn typeName(state: *State, v: Value) []const u8 {
    if (metafield(state, v, "__name")) |n| {
        if (n.isString()) return n.asString().bytes();
    }
    if (v.tag == .light_userdata) return "light userdata";
    return v.typeOf().name();
}

/// Field `name` of `v`'s metatable, raw, or null (`luaL_getmetafield`).
pub fn metafield(state: *State, v: Value, name: []const u8) ?Value {
    const mt = state.metatableOf(v) orelse return null;
    // Looking the name up interns it; that allocation failing means no
    // table can hold the key either.
    const key = state.newString(name) catch return null;
    const r = mt.getShortStr(key);
    return if (r.isNil()) null else r;
}

// ---------------------------------------------------------------------------
// Conversions (§3.4.3)
// ---------------------------------------------------------------------------

/// `lua_tointegerx`: an integer, a float with an exact integer value, or a
/// string that converts to one of those.
pub const toInteger = vm.toInteger;

/// `lua_tonumberx`: a number, or a string that converts to one.
pub fn toNumber(v: Value) ?f64 {
    return (vm.toNumber(v) orelse return null).asNumber();
}

/// A number value for `v`: itself, or the number a string converts to
/// (`luaV_tonumber_` keeping the subtype).
pub const toNumberValue = vm.toNumber;

/// The decimal text of a number, as `tostring` writes it.
pub fn formatNumber(buf: *[number.max_len]u8, v: Value) []const u8 {
    return vm.formatNumber(v, buf);
}

/// A number as a new string.
pub const numberToString = vm.numberToString;

/// `luaL_tolstring`: `__tostring`'s result, or the default text for `v`.
/// The result is not anchored; store it before anything that can collect.
pub fn tolstring(th: *Thread, v: Value) Error!*String {
    const state = th.state;
    if (metafield(state, v, "__tostring")) |h| {
        const r = try call1(th, h, &.{v});
        if (r.isString()) return r.asString();
        if (r.isNumber()) return numberToString(state, r);
        return raise(th, "'__tostring' must return a string", .{});
    }
    switch (v.tag) {
        .int, .float => return numberToString(state, v),
        .short_string, .long_string => return v.asString(),
        .nil => return state.newString("nil"),
        .bool_false => return state.newString("false"),
        .bool_true => return state.newString("true"),
        else => {
            const kind = if (metafield(state, v, "__name")) |n|
                (if (n.isString()) n.asString().bytes() else v.typeOf().name())
            else
                v.typeOf().name();
            var out: Writer.Allocating = .init(state.heap.allocator());
            defer out.deinit();
            out.writer.print("{s}: ", .{kind}) catch return error.OutOfMemory;
            writePointer(&out.writer, toPointer(v)) catch return error.OutOfMemory;
            return state.newString(out.written());
        },
    }
}

/// `lua_topointer`: the address behind a function, userdata, or other
/// object, or null for values that have none.
pub fn toPointer(v: Value) ?usize {
    return switch (v.tag) {
        .native_fn, .light_userdata => if (v.payload.ptr) |p| @intFromPtr(p) else null,
        .userdata => @intFromPtr(v.asUserdata().bytes().ptr),
        else => if (v.isCollectable()) @intFromPtr(v.payload.gc) else null,
    };
}

/// A pointer as glibc's `%p` writes it.
fn writePointer(w: *Writer, p: ?usize) Writer.Error!void {
    if (p) |addr| try w.print("0x{x}", .{addr}) else try w.writeAll("(nil)");
}

// ---------------------------------------------------------------------------
// Operations with metamethods, for natives (lapi.c)
// ---------------------------------------------------------------------------

/// Calls `f` with `args` for one result, which is returned unanchored.
pub fn call1(th: *Thread, f: Value, args: []const Value) Error!Value {
    try th.ensureStack(@intCast(args.len + 1));
    const func = th.top;
    th.push(f);
    for (args) |v| th.push(v);
    try vm.call(th, func, 1);
    const r = th.stack[func];
    th.top = func;
    return r;
}

/// `lua_gettable`: `t[k]` with `__index`.
pub const index = vm.get;

/// `lua_settable`: `t[k] = v` with `__newindex`.
pub const setIndex = vm.set;

/// `lua_geti`: `t[i]`, raw when the slot is present or `t` has no
/// `__index`.
pub inline fn getI(th: *Thread, t: Value, i: i64) Error!Value {
    if (t.tag == .table) {
        const tbl = t.asTable();
        const v = tbl.getInt(i);
        if (!v.isNil() or tbl.metatable == null) return v;
    }
    return index(th, t, .int(i));
}

/// `lua_seti`: `t[i] = v`, raw when the slot is present or `t` has no
/// `__newindex`.
pub inline fn setI(th: *Thread, t: Value, i: i64, v: Value) Error!void {
    if (t.tag == .table) {
        const tbl = t.asTable();
        if (tbl.metatable == null or !tbl.getInt(i).isNil()) return tbl.setInt(th.heap(), i, v);
    }
    return setIndex(th, t, .int(i), v);
}

/// `lua_len`: `#v` with `__len`.
pub const len = vm.length;

/// `luaL_len`: `#v` as an integer.
pub fn lenInt(th: *Thread, v: Value) Error!i64 {
    if (v.tag == .table and v.asTable().metatable == null) return @bitCast(v.asTable().length());
    return toInteger(try len(th, v)) orelse raise(th, "object length is not an integer", .{});
}

/// `lua_compare(L, a, b, LUA_OPLT)`: `a < b` with `__lt`.
pub const lessThan = vm.lessThan;

/// `lua_compare(L, a, b, LUA_OPEQ)`: `a == b` with `__eq`.
pub const equal = vm.equal;

// ---------------------------------------------------------------------------
// Building strings
// ---------------------------------------------------------------------------

/// A string buffer, `luaL_Buffer`: a writer whose first `inline_len` bytes
/// live in the struct, so short results never touch the heap, and which
/// grows through the state's allocator past that. Declare it with
/// `var b: Buffer = .init(state)`; it must not move once written to.
pub const Buffer = struct {
    writer: Writer,
    gpa: gc.Raw,
    on_heap: bool,
    /// Past `inline_len`: room for a `String` header, the bytes, and a
    /// trailing zero, so a long result becomes its string in place.
    block: []align(String.alignment.toByteUnits()) u8 = undefined,
    small: [inline_len]u8 = undefined,

    /// `LUAL_BUFFERSIZE` on a 64-bit build.
    pub const inline_len = 1024;

    const header_len = @sizeOf(String);

    const vtable: Writer.VTable = .{ .drain = drain, .rebase = rebase };

    /// An empty buffer. The writer starts with no buffer and takes `small`
    /// on its first write, so the value can be returned and copied until
    /// then. Initializing the fields one by one, with `small` left to its
    /// default, keeps safe builds from writing 0xAA over the 1 KiB that
    /// `var b: Buffer = undefined` would (`results/buffer-init-20261031.md`).
    pub fn init(state: *State) Buffer {
        return .{
            .writer = .{ .vtable = &vtable, .buffer = &.{} },
            .gpa = state.heap.rawStrings(),
            .on_heap = false,
        };
    }

    /// `init` in place, for a buffer that does not live on the stack: the
    /// fields one by one, so `small` is not copied or filled.
    pub fn initIn(b: *Buffer, state: *State) void {
        b.writer = .{ .vtable = &vtable, .buffer = &.{} };
        b.gpa = state.heap.rawStrings();
        b.on_heap = false;
    }

    // No `b.* = undefined`: a safe build would write 0xAA over the 1 KiB
    // again wherever the store outlives inlining (`package`, `io`).
    // ziglint-ignore: Z030
    pub fn deinit(b: *Buffer) void {
        if (b.on_heap) b.gpa.free(b.block);
    }

    pub fn written(b: *Buffer) []const u8 {
        return b.writer.buffered();
    }

    /// The contents as a Lua string. A long result on the heap becomes the
    /// string without a copy (`luaL_pushresult` with an external string),
    /// and the buffer starts over empty.
    pub fn toString(b: *Buffer, state: *State) error{OutOfMemory}!*String {
        const n = b.writer.end;
        if (!b.on_heap or n <= String.max_short_len) return state.newString(b.written());
        const block = try b.gpa.realloc(b.block, String.allocSize(n));
        b.on_heap = false;
        b.writer = .{ .vtable = &vtable, .buffer = &b.small };
        return String.adoptLong(&state.heap, state.seed, block, n);
    }

    fn ensureUnused(b: *Buffer, n: usize) error{WriteFailed}!void {
        const w = &b.writer;
        if (w.buffer.len - w.end >= n) return;
        if (w.buffer.len == 0 and n <= inline_len) {
            w.buffer = &b.small;
            return;
        }
        const need = std.math.add(usize, w.end, n) catch return error.WriteFailed;
        // Half again as much, as `luaL_Buffer` grows.
        const cap = @max(need, w.buffer.len / 2 * 3);
        const size = std.math.add(usize, cap, header_len + 1) catch return error.WriteFailed;
        if (b.on_heap) {
            b.block = b.gpa.realloc(b.block, size) catch return error.WriteFailed;
        } else {
            b.block = b.gpa.alignedAlloc(u8, String.alignment, size) catch return error.WriteFailed;
            @memcpy(b.block[header_len..][0..w.end], w.buffer[0..w.end]);
            b.on_heap = true;
        }
        w.buffer = b.block[header_len .. size - 1];
    }

    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const b: *Buffer = @fieldParentPtr("writer", w);
        const pattern = data[data.len - 1];
        var total: usize = 0;
        for (data[0 .. data.len - 1]) |d| total += d.len;
        const splat_len = std.math.mul(usize, pattern.len, splat) catch return error.WriteFailed;
        try b.ensureUnused(std.math.add(usize, total, splat_len) catch return error.WriteFailed);
        const start = w.end;
        for (data[0 .. data.len - 1]) |d| {
            @memcpy(w.buffer[w.end..][0..d.len], d);
            w.end += d.len;
        }
        for (0..splat) |_| {
            @memcpy(w.buffer[w.end..][0..pattern.len], pattern);
            w.end += pattern.len;
        }
        return w.end - start;
    }

    fn rebase(w: *Writer, preserve: usize, capacity: usize) Writer.Error!void {
        _ = preserve;
        const b: *Buffer = @fieldParentPtr("writer", w);
        try b.ensureUnused(capacity);
    }
};

/// A string of a length known in advance, filled in place: short ones in
/// the struct and then interned, long ones directly in the new string.
pub const Sized = struct {
    short: [String.max_short_len]u8,
    long: ?*String,
    len: usize,

    /// The bytes to fill. The struct must not move until `finish`.
    pub fn init(sb: *Sized, state: *State, n: usize) error{OutOfMemory}![]u8 {
        sb.len = n;
        if (n <= String.max_short_len) {
            sb.long = null;
            return sb.short[0..n];
        }
        const s = try String.createLong(&state.heap, state.seed, n);
        sb.long = s;
        return s.mutableBytes();
    }

    pub fn finish(sb: *Sized, state: *State) error{OutOfMemory}!*String {
        return sb.long orelse state.newString(sb.short[0..sb.len]);
    }
};

/// A library table with these natives, by name.
pub fn newLib(state: *State, comptime funcs: anytype) error{OutOfMemory}!*Table {
    const list = comptime blk: {
        var l: [funcs.len]Reg = undefined;
        for (funcs, &l) |f, *r| r.* = .{ .name = f[0], .f = f[1] };
        break :blk l;
    };
    return newLibFrom(state, &list);
}

/// A library function's name and code, as `luaL_Reg`. A list of them in
/// read-only data is smaller than a call per function unrolled into each
/// library's `open` (`results/lean-20261031.md`).
const Reg = struct { name: []const u8, f: Value.NativeFn };

fn newLibFrom(state: *State, list: []const Reg) error{OutOfMemory}!*Table {
    const t = try state.newTable(0, @intCast(list.len));
    for (list) |r| try setField(state, t, r.name, .native(r.f));
    return t;
}

/// `t[name] = v`, raw.
pub fn setField(state: *State, t: *Table, name: []const u8, v: Value) error{OutOfMemory}!void {
    try t.setStr(&state.heap, try state.newString(name), v);
}

// ---------------------------------------------------------------------------
// Test harness
// ---------------------------------------------------------------------------

/// Helpers for the libraries' tests: call a native the way Lua would, from
/// the base frame, in protected mode.
pub const testing = struct {
    const t = std.testing;

    pub fn newState() !*State {
        return State.create(t.allocator, .{ .seed = 1 });
    }

    pub fn str(state: *State, b: []const u8) !Value {
        return .string(try state.newString(b));
    }

    pub const Outcome = union(enum) {
        ok: []Value,
        err: Value,
    };

    /// Calls `f` with `args` from the main thread's base frame. The results
    /// stay on the stack until the next call.
    pub fn call(state: *State, f: Value, args: []const Value) !Outcome {
        const th = state.main;
        th.top = 1;
        try th.ensureStack(@intCast(args.len + 1));
        th.push(f);
        for (args) |v| th.push(v);
        if (vm.pcall(th, 1, -1) != .ok) return .{ .err = th.stack[1] };
        return .{ .ok = th.stack[1..th.top] };
    }

    /// Calls `f` with `args` through a Lua function, `function(f, ...)
    /// return f(...) end` from chunk "=test", all on line 7, so errors that
    /// natives raise get the caller's position.
    pub fn callFromLua(state: *State, f: Value, args: []const Value) !Outcome {
        const p = try Proto.create(&state.heap);
        const gpa = state.heap.allocator();
        p.code = try gpa.dupe(u32, &.{
            opcodes.abc(.varargprep, 1, 0, 0, false),
            opcodes.abc(.move, 1, 0, 0, false),
            opcodes.abc(.vararg, 2, 0, 0, false),
            opcodes.abc(.call, 1, 0, 0, false),
            opcodes.abc(.@"return", 1, 0, 2, false),
        });
        p.lineinfo = try gpa.dupe(i8, &.{ 7, 0, 0, 0, 0 });
        p.numparams = 1;
        p.flags.vararg = true;
        p.maxstacksize = 4;
        p.source = try state.newString("=test");
        const cl = try Proto.LuaClosure.create(&state.heap, p, 0);
        var all: [16]Value = undefined;
        all[0] = f;
        @memcpy(all[1..][0..args.len], args);
        return call(state, .luaClosure(cl), all[0 .. args.len + 1]);
    }

    /// Like `call`, expecting success.
    pub fn ok(state: *State, f: Value, args: []const Value) ![]Value {
        switch (try call(state, f, args)) {
            .ok => |r| return r,
            .err => |e| {
                std.debug.print("unexpected error: {s}\n", .{if (e.isString()) e.asString().bytes() else "?"});
                return error.TestUnexpectedResult;
            },
        }
    }

    /// Like `call`, expecting an error with exactly this message.
    pub fn expectError(state: *State, want: []const u8, f: Value, args: []const Value) !void {
        switch (try call(state, f, args)) {
            .ok => return error.TestExpectedError,
            .err => |e| try t.expectEqualStrings(want, e.asString().bytes()),
        }
    }

    /// The results as `print` would show them, tab-separated, for comparing
    /// with the reference's output. Tables and functions show their type.
    pub fn show(state: *State, f: Value, args: []const Value) ![]const u8 {
        const S = struct {
            var buf: [8192]u8 = undefined;
        };
        var w: Writer = .fixed(&S.buf);
        switch (try call(state, f, args)) {
            .ok => |r| for (r, 0..) |v, i| {
                if (i > 0) try w.writeByte('\t');
                try showValue(&w, v);
            },
            .err => |e| {
                try w.writeAll("error: ");
                try showValue(&w, e);
            },
        }
        return w.buffered();
    }

    pub fn showValue(w: *Writer, v: Value) !void {
        var nb: [number.max_len]u8 = undefined;
        switch (v.tag) {
            .int, .float => try w.writeAll(formatNumber(&nb, v)),
            .short_string, .long_string => try w.writeAll(v.asString().bytes()),
            .nil => try w.writeAll("nil"),
            .bool_false => try w.writeAll("false"),
            .bool_true => try w.writeAll("true"),
            else => try w.writeAll(v.typeOf().name()),
        }
    }

    /// Calls `f` and expects `show` to give `want`.
    pub fn expectShow(state: *State, want: []const u8, f: Value, args: []const Value) !void {
        try t.expectEqualStrings(want, try show(state, f, args));
    }

    /// Lua values for a tuple of Zig ones: integers, floats, booleans, null
    /// for nil, string literals, `Value`s, `.{ .kv = .{ .{ k, v }, ... } }`
    /// for a new table, `.empty_table`, and `.native_function` for a native
    /// function. The slice is reused by
    /// the next call.
    pub fn vals(state: *State, args: anytype) ![]Value {
        const S = struct {
            var buf: [64]Value = undefined;
        };
        inline for (args, 0..) |x, i| S.buf[i] = try toValue(state, x);
        return S.buf[0..args.len];
    }

    fn toValue(state: *State, x: anytype) !Value {
        const T = @TypeOf(x);
        if (T == Value) return x;
        return switch (@typeInfo(T)) {
            .comptime_int, .int => .int(x),
            .comptime_float, .float => .float(x),
            .bool => .boolean(x),
            .null => .nil,
            .pointer => str(state, x),
            .@"struct" => blk: {
                // `.{ .kv = .{ .{ key, value }, ... } }`: a table.
                const tbl = try state.newTable(0, 0);
                inline for (x.kv) |pair| {
                    try tbl.set(&state.heap, try toValue(state, pair[0]), try toValue(state, pair[1]));
                }
                break :blk .table(tbl);
            },
            .enum_literal => switch (x) {
                .empty_table => .table(try state.newTable(0, 0)),
                .native_function => .native(&nop),
                else => @compileError("unknown test value"),
            },
            else => @compileError("unsupported test value type " ++ @typeName(T)),
        };
    }

    fn nop(_: *Thread, _: u32) Error!u32 {
        return 0;
    }

    /// Runs generated cases `.{ "lib.name", .{ args... }, "expected" }`,
    /// where the expected text is what `show` gives for the reference's
    /// results.
    pub fn expectCases(state: *State, comptime cases: anytype) !void {
        @setEvalBranchQuota(100_000);
        var failed: usize = 0;
        inline for (cases, 0..) |c, i| {
            const got = try show(state, try global(state, c[0]), try vals(state, c[1]));
            if (!std.mem.eql(u8, got, c[2])) {
                std.debug.print("case {d}, {s}: expected \"{f}\", got \"{f}\"\n", .{
                    i,
                    c[0],
                    std.zig.fmtString(c[2]),
                    std.zig.fmtString(got),
                });
                failed += 1;
            }
        }
        try t.expectEqual(@as(usize, 0), failed);
    }

    /// A Lua global or library field, by dotted name ("string.rep").
    pub fn global(state: *State, comptime path: []const u8) !Value {
        var v: Value = .table(state.globals);
        var it = std.mem.splitScalar(u8, path, '.');
        while (it.next()) |part| v = v.asTable().getStr(try state.newString(part));
        return v;
    }
};

test "Buffer keeps short output inline and grows on the heap" {
    const state = try testing.newState();
    defer state.destroy();
    var b: Buffer = .init(state);
    defer b.deinit();
    try b.writer.writeAll("abc");
    try std.testing.expect(!b.on_heap);
    try b.writer.splatByteAll('x', 3000);
    try b.writer.print("{d}", .{42});
    try std.testing.expect(b.on_heap);
    try std.testing.expectEqual(@as(usize, 3005), b.written().len);
    try std.testing.expectEqualStrings("abcxx", b.written()[0..5]);
    try std.testing.expectEqualStrings("x42", b.written()[3002..]);
}

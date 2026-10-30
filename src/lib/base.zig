//! The basic library (manual §6.1), after reference Lua 5.5.1's lbaselib.c,
//! plus the auxiliary helpers its functions share with the other libraries
//! (argument checks and the "bad argument" errors of lauxlib.c, `tostring`
//! conversion, metafields, indexing with `__index` from native code), and
//! `Host`, the I/O context the embedder provides.
//!
//! Native functions take the thread and the stack index of their first
//! argument; arguments run up to `th.top`, results go on top, and the
//! return value counts them (plan decision 12). Argument numbers in
//! messages are Lua's, from 1.

const std = @import("std");
const Value = @import("../Value.zig");
const String = @import("../String.zig");
const Table = @import("../Table.zig");
const State = @import("../State.zig");
const Thread = @import("../Thread.zig");
const Parser = @import("../Parser.zig");
const vm = @import("../vm.zig");
const gc = @import("../gc.zig");
const number = @import("../number.zig");
const root = @import("../root.zig");
const lib = @import("init.zig");

const Error = Value.Error;
const Writer = std.Io.Writer;

/// What the libraries need from the program around them: I/O and the
/// standard streams, and state the reference keeps in its `global_State`
/// that `State` does not have yet (warnings, the collector's mode and
/// parameters). The embedder owns it; it must outlive the Lua state.
pub const Host = struct {
    io: std.Io,
    stdout: std.Io.File.Writer,
    stdout_buf: [4096]u8 = undefined,
    warn: enum { off, on, cont } = .off,
    gc_mode: enum { incremental, generational } = .incremental,
    gc_stopped: bool = false,
    /// `collectgarbage("param")` values, PUC-Rio's encoded bytes.
    gc_params: [6]u8 = .{
        codeParam(20), codeParam(50), codeParam(70), codeParam(250), codeParam(200), codeParam(200 * 56),
    },

    /// A host on the process's standard streams. Call `init` in place: the
    /// stdout writer points into the struct.
    pub fn init(host: *Host, io: std.Io) void {
        host.* = .{ .io = io, .stdout = undefined };
        host.stdout = std.Io.File.stdout().writerStreaming(io, &host.stdout_buf);
    }

    /// Writes to standard error, unbuffered, ignoring failures as C's
    /// `fprintf(stderr, ...)` does.
    pub fn writeStderr(host: *Host, bytes: []const u8) void {
        std.Io.File.stderr().writeStreamingAll(host.io, bytes) catch return;
    }

    /// Writes to the buffered standard output, ignoring failures as C's
    /// `lua_writestring` does.
    pub fn writeStdout(host: *Host, bytes: []const u8) void {
        host.stdout.interface.writeAll(bytes) catch return;
    }

    pub fn flushStdout(host: *Host) void {
        host.stdout.interface.flush() catch return;
    }
};

const host_key = "_LUA_HOST";

/// Stores `host` in the registry for the libraries.
pub fn setHost(th: *Thread, host: *Host) Error!void {
    const state = th.state;
    try state.registry.setStr(&state.heap, try state.newString(host_key), .lightUserdata(host));
}

/// The host `setHost` stored.
pub fn getHost(th: *Thread) *Host {
    const state = th.state;
    const s = state.newString(host_key) catch unreachable; // interned at setHost
    return @ptrCast(@alignCast(state.registry.getStr(s).asLightUserdata().?));
}

// ---------------------------------------------------------------------------
// Auxiliary functions: errors and argument checks (lauxlib.c)
// ---------------------------------------------------------------------------

/// The line a Lua frame is running, from its saved `pc`.
fn currentLine(th: *Thread, f: *const Thread.Frame) ?u32 {
    if (!f.flags.lua) return null;
    const p = th.stack[f.func].asLuaClosure().proto;
    const pc = (@intFromPtr(f.pc) - @intFromPtr(p.code.ptr)) / @sizeOf(u32);
    return p.lineAt(pc -| 1);
}

/// "chunk:line: " for the function `level` calls up from the running
/// native function (1 is its caller), or nothing when that is not a Lua
/// function; `luaL_where`.
pub fn where(th: *Thread, level: usize, w: *Writer) Writer.Error!void {
    const n = th.frames.items.len;
    if (level >= n - 1) return;
    const f = &th.frames.items[n - 1 - level];
    const line = currentLine(th, f) orelse return;
    const p = th.stack[f.func].asLuaClosure().proto;
    try Thread.writeChunkId(w, if (p.source) |s| s.bytes() else "?");
    try w.print(":{d}: ", .{line});
}

/// Raises a formatted error with the caller's position, `luaL_error`.
pub fn raise(th: *Thread, comptime fmt: []const u8, args: anytype) Error {
    var aw: Writer.Allocating = .init(th.heap().allocator());
    defer aw.deinit();
    where(th, 1, &aw.writer) catch return error.OutOfMemory;
    aw.writer.print(fmt, args) catch return error.OutOfMemory;
    return th.throw(.string(try th.state.newString(aw.written())));
}

/// "bad argument #arg to 'fname' (msg)", `luaL_argerror`. The function's
/// name is given; PUC-Rio finds it from the calling instruction, which
/// needs the debug information work.
pub fn argError(th: *Thread, arg: u32, fname: []const u8, msg: []const u8) Error {
    return raise(th, "bad argument #{d} to '{s}' ({s})", .{ arg, fname, msg });
}

/// The argument, or null when the call passed fewer.
pub inline fn opt(th: *Thread, base: u32, arg: u32) ?Value {
    const i = base + arg - 1;
    return if (i < th.top) th.stack[i] else null;
}

/// The argument, or nil when the call passed fewer.
pub inline fn get(th: *Thread, base: u32, arg: u32) Value {
    return opt(th, base, arg) orelse .nil;
}

/// The name of an argument's type for messages: its `__name` metafield, or
/// "light userdata", or the type name, or "no value".
fn typeNameForError(th: *Thread, v: ?Value) []const u8 {
    const val = v orelse return "no value";
    if (getMetafield(th, val, "__name")) |n| {
        if (n.isString()) return n.asString().bytes();
    }
    if (val.tag == .light_userdata) return "light userdata";
    return val.typeOf().name();
}

/// "bad argument #arg to 'fname' (expected expected, got type)",
/// `luaL_typeerror`.
pub fn typeError(th: *Thread, base: u32, arg: u32, fname: []const u8, expected: []const u8) Error {
    var buf: [128]u8 = undefined;
    const got = typeNameForError(th, opt(th, base, arg));
    const msg = std.fmt.bufPrint(&buf, "{s} expected, got {s}", .{ expected, got }) catch &buf;
    return argError(th, arg, fname, msg);
}

/// `luaL_checkany`.
pub fn checkAny(th: *Thread, base: u32, arg: u32, fname: []const u8) Error!Value {
    return opt(th, base, arg) orelse argError(th, arg, fname, "value expected");
}

pub fn checkTable(th: *Thread, base: u32, arg: u32, fname: []const u8) Error!*Table {
    const v = get(th, base, arg);
    if (v.tag != .table) return typeError(th, base, arg, fname, "table");
    return v.asTable();
}

/// A number or a string that converts to one, `lua_tonumberx`.
pub fn toNumber(v: Value) ?number.Number {
    return switch (v.tag) {
        .int => .{ .int = v.asInt() },
        .float => .{ .float = v.asFloat() },
        .short_string, .long_string => number.parse(v.asString().bytes()),
        else => null,
    };
}

/// An integer, an integral float, or a string that converts to one,
/// `lua_tointegerx`.
pub fn toInteger(v: Value) ?i64 {
    return switch (toNumber(v) orelse return null) {
        .int => |i| i,
        .float => |f| number.floatToInt(f, .exact),
    };
}

/// `luaL_checkinteger`.
pub fn checkInteger(th: *Thread, base: u32, arg: u32, fname: []const u8) Error!i64 {
    const v = get(th, base, arg);
    return toInteger(v) orelse {
        if (toNumber(v) != null) return argError(th, arg, fname, "number has no integer representation");
        return typeError(th, base, arg, fname, "number");
    };
}

/// `luaL_optinteger`.
pub fn optInteger(th: *Thread, base: u32, arg: u32, fname: []const u8, default: i64) Error!i64 {
    const v = opt(th, base, arg) orelse return default;
    if (v.isNil()) return default;
    return checkInteger(th, base, arg, fname);
}

/// A string argument, converting a number in place as `lua_tolstring`
/// does; null for other types.
pub fn toLString(th: *Thread, base: u32, arg: u32) Error!?*String {
    const i = base + arg - 1;
    if (i >= th.top) return null;
    const v = th.stack[i];
    if (v.isString()) return v.asString();
    if (!v.isNumber()) return null;
    const s = try numberToString(th.state, v);
    th.stack[i] = .string(s);
    return s;
}

/// `luaL_checklstring`.
pub fn checkString(th: *Thread, base: u32, arg: u32, fname: []const u8) Error!*String {
    return try toLString(th, base, arg) orelse typeError(th, base, arg, fname, "string");
}

/// `luaL_optlstring`: null for none or nil.
pub fn optString(th: *Thread, base: u32, arg: u32, fname: []const u8) Error!?*String {
    const v = opt(th, base, arg) orelse return null;
    if (v.isNil()) return null;
    const s = try checkString(th, base, arg, fname);
    return s;
}

/// The index of the argument in `options`, `luaL_checkoption`.
pub fn checkOption(
    th: *Thread,
    base: u32,
    arg: u32,
    fname: []const u8,
    default: ?[]const u8,
    options: []const []const u8,
) Error!usize {
    const name = if (default) |d|
        (if (try optString(th, base, arg, fname)) |s| s.bytes() else d)
    else
        (try checkString(th, base, arg, fname)).bytes();
    for (options, 0..) |o, i| if (std.mem.eql(u8, o, name)) return i;
    var buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "invalid option '{s}'", .{name[0..@min(name.len, 80)]}) catch &buf;
    return argError(th, arg, fname, msg);
}

/// The raw field `name` of the value's metatable, `luaL_getmetafield`.
pub fn getMetafield(th: *Thread, v: Value, name: []const u8) ?Value {
    const mt = th.state.metatableOf(v) orelse return null;
    const key = th.state.newString(name) catch return null;
    const f = mt.getStr(key);
    return if (f.isNil()) null else f;
}

/// Pushes `f` and `args`, calls with `nresults` results, and leaves them
/// on top. The caller made room.
fn callValue(th: *Thread, f: Value, args: []const Value, nresults: i16) Error!u32 {
    try th.ensureStack(@intCast(args.len + 1));
    const func = th.top;
    th.push(f);
    for (args) |a| th.push(a);
    try vm.call(th, func, nresults);
    return func;
}

/// `t[k]` with `__index`, as `lua_gettable` from native code.
pub fn index(th: *Thread, t_in: Value, k: Value) Error!Value {
    var t = t_in;
    for (0..2000) |_| {
        var h: Value = undefined;
        if (t.tag == .table) {
            const tbl = t.asTable();
            const v = tbl.get(k);
            if (!v.isNil()) return v;
            h = th.state.fastTm(tbl.metatable, .index) orelse return .nil;
        } else {
            h = th.state.tmOf(t, .index) orelse
                return th.runError("attempt to index a {s} value", .{t.typeOf().name()});
        }
        if (h.isFunction()) {
            const func = try callValue(th, h, &.{ t, k }, 1);
            const r = th.stack[func];
            th.top = func;
            return r;
        }
        t = h;
    }
    return th.runError("'__index' chain too long; possible loop", .{});
}

/// A number as `tostring` writes it, as a new string.
pub fn numberToString(state: *State, v: Value) error{OutOfMemory}!*String {
    var buf: [number.max_len]u8 = undefined;
    return state.newString(formatNumber(&buf, v));
}

fn formatNumber(buf: *[number.max_len]u8, v: Value) []const u8 {
    return if (v.tag == .int) number.formatInt(buf, v.asInt()) else number.formatFloat(buf, v.asFloat());
}

/// The address `%p` prints for a value, `lua_topointer`; null for values
/// that are not objects.
pub fn toPointer(v: Value) ?usize {
    return switch (v.tag) {
        .light_userdata, .native_fn => @intFromPtr(v.payload.ptr),
        else => if (v.isCollectable()) @intFromPtr(v.payload.gc) else null,
    };
}

/// The string `tostring` makes of a value, `luaL_tolstring`: `__tostring`
/// when present (it must return a string or a number), otherwise the
/// value's default form.
pub fn toStringValue(th: *Thread, v: Value) Error!Value {
    if (getMetafield(th, v, "__tostring")) |h| {
        const func = try callValue(th, h, &.{v}, 1);
        const r = th.stack[func];
        th.top = func;
        if (r.isString()) return r;
        if (r.isNumber()) return .string(try numberToString(th.state, r));
        return raise(th, "'__tostring' must return a string", .{});
    }
    switch (v.tag) {
        .short_string, .long_string => return v,
        .int, .float => return .string(try numberToString(th.state, v)),
        .nil => return .string(try th.state.newString("nil")),
        .bool_false => return .string(try th.state.newString("false")),
        .bool_true => return .string(try th.state.newString("true")),
        else => {
            const kind = if (getMetafield(th, v, "__name")) |n|
                (if (n.isString()) n.asString().bytes() else v.typeOf().name())
            else
                v.typeOf().name();
            var buf: [128]u8 = undefined;
            const s = if (toPointer(v)) |p|
                std.fmt.bufPrint(&buf, "{s}: 0x{x}", .{ kind[0..@min(kind.len, 80)], p }) catch unreachable
            else
                std.fmt.bufPrint(&buf, "{s}: (nil)", .{kind[0..@min(kind.len, 80)]}) catch unreachable;
            return .string(try th.state.newString(s));
        },
    }
}

/// Pushes a value and returns 1, for the common one-result case.
inline fn ret1(th: *Thread, v: Value) u32 {
    th.push(v);
    return 1;
}

// ---------------------------------------------------------------------------
// Loading chunks
// ---------------------------------------------------------------------------

/// Compiles a chunk into a function whose `_ENV` is the globals table,
/// `lua_load`. `mode` holds 'b' and/or 't'. Raises the syntax error.
pub fn loadChunk(th: *Thread, src: [:0]const u8, chunkname: []const u8, mode: []const u8) Error!Value {
    const binary = src.len > 0 and src[0] == 0x1b;
    if (binary and std.mem.findScalar(u8, mode, 'b') == null)
        return throwFmt(th, "attempt to load a binary chunk (mode is '{s}')", .{mode});
    if (!binary and std.mem.findScalar(u8, mode, 't') == null)
        return throwFmt(th, "attempt to load a text chunk (mode is '{s}')", .{mode});
    if (binary) return throwFmt(th, "{s}: bad binary format (binary chunks are not supported yet)", .{chunkname});
    const p = try Parser.compile(th, src, chunkname);
    return .luaClosure(try vm.mainClosure(th.state, p));
}

fn throwFmt(th: *Thread, comptime fmt: []const u8, args: anytype) Error {
    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch &buf;
    return th.throw(.string(try th.state.newString(s)));
}

/// The error object of a failed protected operation, clearing it.
fn takeError(th: *Thread, e: Error) Value {
    const v: Value = switch (e) {
        error.LuaError => th.err,
        error.OutOfMemory => .string(th.state.memerr),
    };
    th.err = .nil;
    return v;
}

/// A source file's contents, ready to compile: read whole, with a UTF-8
/// byte-order mark dropped and a first line starting with '#' replaced by
/// its newline, as `luaL_loadfilex` does. Null `path` reads stdin. A
/// failure raises "cannot open name: reason".
pub fn readSourceFile(th: *Thread, path: ?[]const u8) Error![:0]u8 {
    const host = getHost(th);
    const gpa = th.heap().allocator();
    const raw = readAll(host, gpa, path) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        const what = if (e == error.IsDir) "read" else "open";
        return throwFmt(th, "cannot {s} {s}: {s}", .{ what, path orelse "stdin", errorText(e) });
    };
    var start: usize = 0;
    if (std.mem.startsWith(u8, raw, "\xEF\xBB\xBF")) start = 3;
    if (start < raw.len and raw[start] == '#') {
        start = std.mem.findScalarPos(u8, raw, start, '\n') orelse raw.len;
        // The newline stays unless the chunk turns out to be binary.
        if (start + 1 < raw.len and raw[start + 1] == 0x1b) start += 1;
    }
    if (start == 0) return raw;
    defer gpa.free(raw);
    return gpa.dupeZ(u8, raw[start..]);
}

fn readAll(host: *Host, gpa: std.mem.Allocator, path: ?[]const u8) ![:0]u8 {
    const io = host.io;
    if (path) |p| return std.Io.Dir.cwd().readFileAllocOptions(io, p, gpa, .unlimited, .of(u8), 0);
    var buf: [4096]u8 = undefined;
    var r = std.Io.File.stdin().readerStreaming(io, &buf);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    try r.interface.appendRemainingUnlimited(gpa, &list);
    return list.toOwnedSliceSentinel(gpa, 0);
}

/// C's `strerror` text for the file errors a script meets.
fn errorText(e: anyerror) []const u8 {
    return switch (e) {
        error.FileNotFound => "No such file or directory",
        error.AccessDenied, error.PermissionDenied => "Permission denied",
        error.IsDir => "Is a directory",
        error.NotDir => "Not a directory",
        error.NameTooLong => "File name too long",
        error.SymLinkLoop => "Too many levels of symbolic links",
        error.FileTooBig => "File too large",
        else => @errorName(e),
    };
}

/// `luaL_loadfilex`: a function for the file, or the error raised.
pub fn loadFile(th: *Thread, path: ?[]const u8, mode: []const u8) Error!Value {
    const gpa = th.heap().allocator();
    const src = try readSourceFile(th, path);
    defer gpa.free(src);
    var name_buf: std.ArrayList(u8) = .empty;
    defer name_buf.deinit(gpa);
    if (path) |p| {
        try name_buf.append(gpa, '@');
        try name_buf.appendSlice(gpa, p);
    } else {
        try name_buf.appendSlice(gpa, "=stdin");
    }
    return loadChunk(th, src, name_buf.items, mode);
}

// ---------------------------------------------------------------------------
// The library
// ---------------------------------------------------------------------------

fn print(th: *Thread, base: u32) Error!u32 {
    const host = getHost(th);
    const n = th.top - base;
    for (0..n) |i| {
        if (i > 0) host.writeStdout("\t");
        const v = th.stack[base + i];
        switch (v.tag) {
            .short_string, .long_string => host.writeStdout(v.asString().bytes()),
            .int, .float => {
                var buf: [number.max_len]u8 = undefined;
                host.writeStdout(formatNumber(&buf, v));
            },
            else => host.writeStdout((try toStringValue(th, v)).asString().bytes()),
        }
    }
    host.writeStdout("\n");
    host.flushStdout();
    return 0;
}

fn warn(th: *Thread, base: u32) Error!u32 {
    const n = th.top - base;
    _ = try checkString(th, base, 1, "warn");
    for (2..n + 1) |i| _ = try checkString(th, base, @intCast(i), "warn");
    const host = getHost(th);
    for (0..n) |i| warnf(host, th.stack[base + i].asString().bytes(), i + 1 < n);
    return 0;
}

/// The standard warning function of lauxlib.c: off until "@on", each
/// message prefixed and ended with a newline, pieces joined.
pub fn warnf(host: *Host, msg: []const u8, tocont: bool) void {
    if (host.warn != .cont and !tocont and msg.len > 0 and msg[0] == '@') {
        if (std.mem.eql(u8, msg, "@off")) host.warn = .off else if (std.mem.eql(u8, msg, "@on")) host.warn = .on;
        return;
    }
    switch (host.warn) {
        .off => return,
        .on => host.writeStderr("Lua warning: "),
        .cont => {},
    }
    host.writeStderr(msg);
    if (tocont) {
        host.warn = .cont;
    } else {
        host.writeStderr("\n");
        host.warn = .on;
    }
}

/// `b_str2int`: a numeral in `base`, with surrounding spaces and a sign.
fn strToIntBase(s: []const u8, b: u8) ?i64 {
    const spaces = " \x0c\n\r\t\x0b";
    var i: usize = 0;
    while (i < s.len and std.mem.findScalar(u8, spaces, s[i]) != null) i += 1;
    var neg = false;
    if (i < s.len and s[i] == '-') {
        neg = true;
        i += 1;
    } else if (i < s.len and s[i] == '+') i += 1;
    if (i >= s.len or !std.ascii.isAlphanumeric(s[i])) return null;
    var n: u64 = 0;
    while (i < s.len and std.ascii.isAlphanumeric(s[i])) : (i += 1) {
        const c = s[i];
        const digit: u8 = if (std.ascii.isDigit(c)) c - '0' else std.ascii.toUpper(c) - 'A' + 10;
        if (digit >= b) return null;
        n = n *% b +% digit;
    }
    while (i < s.len and std.mem.findScalar(u8, spaces, s[i]) != null) i += 1;
    if (i != s.len) return null;
    return @bitCast(if (neg) 0 -% n else n);
}

fn tonumber(th: *Thread, base: u32) Error!u32 {
    const b = get(th, base, 2);
    if (b.isNil()) {
        const v = get(th, base, 1);
        if (v.isNumber()) return ret1(th, v);
        if (v.isString()) {
            if (number.parse(v.asString().bytes())) |n| return ret1(th, switch (n) {
                .int => |i| .int(i),
                .float => |f| .float(f),
            });
        } else {
            _ = try checkAny(th, base, 1, "tonumber");
        }
    } else {
        const nb = try checkInteger(th, base, 2, "tonumber");
        const s = get(th, base, 1);
        if (!s.isString()) return typeError(th, base, 1, "tonumber", "string");
        if (!(2 <= nb and nb <= 36)) return argError(th, 2, "tonumber", "base out of range");
        if (strToIntBase(s.asString().bytes(), @intCast(nb))) |n| return ret1(th, .int(n));
    }
    return ret1(th, .nil);
}

fn @"error"(th: *Thread, base: u32) Error!u32 {
    const level = try optInteger(th, base, 2, "error", 1);
    var v = get(th, base, 1);
    if (v.isString() and level > 0) {
        var aw: Writer.Allocating = .init(th.heap().allocator());
        defer aw.deinit();
        where(th, @intCast(level), &aw.writer) catch return error.OutOfMemory;
        if (aw.written().len > 0) {
            aw.writer.writeAll(v.asString().bytes()) catch return error.OutOfMemory;
            v = .string(try th.state.newString(aw.written()));
        }
    }
    // A nil error object reaches xpcall's handler as nil; pcall and
    // xpcall turn it into "<no error object>" after, as luaG_errormsg does.
    return th.throw(v);
}

/// The error object `pcall` and `xpcall` return: nil becomes a message.
fn errorObject(th: *Thread, v: Value) Error!Value {
    return if (v.isNil()) .string(try th.state.newString("<no error object>")) else v;
}

fn getmetatable(th: *Thread, base: u32) Error!u32 {
    const v = try checkAny(th, base, 1, "getmetatable");
    const mt = th.state.metatableOf(v) orelse return ret1(th, .nil);
    if (getMetafield(th, v, "__metatable")) |protected| return ret1(th, protected);
    return ret1(th, .table(mt));
}

fn setmetatable(th: *Thread, base: u32) Error!u32 {
    const mtv = get(th, base, 2);
    const t = try checkTable(th, base, 1, "setmetatable");
    if (mtv.tag != .nil and mtv.tag != .table) return typeError(th, base, 2, "setmetatable", "nil or table");
    if (getMetafield(th, .table(t), "__metatable") != null)
        return raise(th, "cannot change a protected metatable", .{});
    t.metatable = if (mtv.isNil()) null else mtv.asTable();
    gc.barrier(th.heap(), &t.header, mtv);
    return ret1(th, .table(t));
}

fn rawequal(th: *Thread, base: u32) Error!u32 {
    const a = try checkAny(th, base, 1, "rawequal");
    const b = try checkAny(th, base, 2, "rawequal");
    return ret1(th, .boolean(Value.rawEquals(a, b)));
}

fn rawlen(th: *Thread, base: u32) Error!u32 {
    const v = get(th, base, 1);
    return switch (v.tag) {
        .table => ret1(th, .int(@bitCast(v.asTable().length()))),
        .short_string, .long_string => ret1(th, .int(@intCast(v.asString().len))),
        else => typeError(th, base, 1, "rawlen", "table or string"),
    };
}

fn rawget(th: *Thread, base: u32) Error!u32 {
    const t = try checkTable(th, base, 1, "rawget");
    const k = try checkAny(th, base, 2, "rawget");
    return ret1(th, t.get(k));
}

fn rawset(th: *Thread, base: u32) Error!u32 {
    const t = try checkTable(th, base, 1, "rawset");
    const k = try checkAny(th, base, 2, "rawset");
    const v = try checkAny(th, base, 3, "rawset");
    t.set(th.heap(), k, v) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.IndexIsNil => th.runError("table index is nil", .{}),
        error.IndexIsNaN => th.runError("table index is NaN", .{}),
    };
    return ret1(th, .table(t));
}

/// `luaO_codeparam`: a percentage as PUC-Rio's floating-point byte.
fn codeParam(p_in: u32) u8 {
    if (p_in >= (@as(u64, 0x1F) << (0xF - 7 - 1)) * 100) return 0xFF;
    const p: u32 = @intCast((@as(u64, p_in) * 128 + 99) / 100);
    if (p < 0x10) return @intCast(p);
    const log: u5 = @intCast(32 - @clz(p) - 5);
    return @intCast(((p >> log) - 0x10) | (@as(u32, log) + 1) << 4);
}

/// `luaO_applyparam(p, 100)`: the percentage a coded byte stands for.
fn applyParam(p: u8) i64 {
    var m: i64 = p & 0xF;
    var e: i32 = p >> 4;
    if (e > 0) {
        e -= 1;
        m += 0x10;
    }
    e -= 7;
    return if (e >= 0) (100 * m) << @intCast(e) else (100 * m) >> @intCast(-e);
}

fn collectgarbage(th: *Thread, base: u32) Error!u32 {
    const opts = [_][]const u8{
        "stop", "restart", "collect", "count", "step", "isrunning", "generational", "incremental", "param",
    };
    const o = try checkOption(th, base, 1, "collectgarbage", "collect", &opts);
    const host = getHost(th);
    const heap = th.heap();
    switch (o) {
        0 => {
            host.gc_stopped = true;
            heap.threshold = std.math.maxInt(usize);
            return ret1(th, .int(0));
        },
        1 => {
            host.gc_stopped = false;
            heap.threshold = @max(heap.bytes, gc.Heap.initial_threshold);
            return ret1(th, .int(0));
        },
        2, 4 => {
            if (o == 4) _ = try optInteger(th, base, 2, "collectgarbage", 0);
            th.state.collect();
            if (host.gc_stopped) heap.threshold = std.math.maxInt(usize);
            return ret1(th, if (o == 2) Value.int(0) else Value.true);
        },
        3 => return ret1(th, .float(@as(f64, @floatFromInt(heap.bytes)) / 1024.0)),
        5 => return ret1(th, .boolean(!host.gc_stopped)),
        6, 7 => {
            const old = host.gc_mode;
            host.gc_mode = if (o == 6) .generational else .incremental;
            return ret1(th, .string(try th.state.newString(@tagName(old))));
        },
        else => {
            const params = [_][]const u8{ "minormul", "majorminor", "minormajor", "pause", "stepmul", "stepsize" };
            const p = try checkOption(th, base, 2, "collectgarbage", null, &params);
            const value = try optInteger(th, base, 3, "collectgarbage", -1);
            const old = applyParam(host.gc_params[p]);
            if (value >= 0) host.gc_params[p] = codeParam(@intCast(@min(value, std.math.maxInt(i32))));
            return ret1(th, .int(old));
        },
    }
}

fn @"type"(th: *Thread, base: u32) Error!u32 {
    const v = opt(th, base, 1) orelse return argError(th, 1, "type", "value expected");
    return ret1(th, .string(try th.state.newString(v.typeOf().name())));
}

fn next(th: *Thread, base: u32) Error!u32 {
    const t = try checkTable(th, base, 1, "next");
    const e = t.next(get(th, base, 2)) catch return th.runError("invalid key to 'next'", .{});
    if (e) |entry| {
        th.push(entry.key);
        th.push(entry.value);
        return 2;
    }
    return ret1(th, .nil);
}

fn pairs(th: *Thread, base: u32) Error!u32 {
    const v = try checkAny(th, base, 1, "pairs");
    if (getMetafield(th, v, "__pairs")) |h| {
        _ = try callValue(th, h, &.{v}, 4);
        return 4;
    }
    th.push(.native(&next));
    th.push(v);
    th.push(.nil);
    th.push(.nil);
    return 4;
}

fn ipairsAux(th: *Thread, base: u32) Error!u32 {
    const i = (try checkInteger(th, base, 2, "ipairs")) +% 1;
    th.push(.int(i));
    const v = try index(th, get(th, base, 1), .int(i));
    th.push(v);
    return if (v.isNil()) 1 else 2;
}

fn ipairs(th: *Thread, base: u32) Error!u32 {
    const v = try checkAny(th, base, 1, "ipairs");
    th.push(.native(&ipairsAux));
    th.push(v);
    th.push(.int(0));
    return 3;
}

/// The mode argument of `load` and `loadfile`; 'B' is for fixed buffers,
/// which Lua code cannot use.
fn getMode(th: *Thread, base: u32, arg: u32, fname: []const u8) Error![]const u8 {
    const m = try optString(th, base, arg, fname) orelse return "bt";
    if (std.mem.findScalar(u8, m.bytes(), 'B') != null) return argError(th, arg, fname, "invalid mode");
    return m.bytes();
}

/// Finishes `load` and `loadfile`: the function, with `env` as its first
/// upvalue when given, or nil and the message.
fn loadResult(th: *Thread, result: Error!Value, env: ?Value) Error!u32 {
    const f = result catch |e| {
        const msg = takeError(th, e);
        th.push(.nil);
        th.push(msg);
        return 2;
    };
    if (env) |e| {
        const cl = f.asLuaClosure();
        if (cl.nupvalues > 0) cl.upvals()[0].set(th.heap(), e);
    }
    return ret1(th, f);
}

fn loadfile(th: *Thread, base: u32) Error!u32 {
    const fname = try optString(th, base, 1, "loadfile");
    const mode = try getMode(th, base, 2, "loadfile");
    const env = opt(th, base, 3);
    return loadResult(th, loadFile(th, if (fname) |s| s.bytes() else null, mode), env);
}

fn load(th: *Thread, base: u32) Error!u32 {
    const mode = try getMode(th, base, 3, "load");
    const env = opt(th, base, 4);
    if (try toLString(th, base, 1)) |s| {
        const name = if (try optString(th, base, 2, "load")) |n| n.bytes() else s.bytes();
        return loadResult(th, loadChunk(th, s.bytesZ(), name, mode), env);
    }
    const name = if (try optString(th, base, 2, "load")) |n| n.bytes() else "=(load)";
    const reader = get(th, base, 1);
    if (!reader.isFunction()) return typeError(th, base, 1, "load", "function");
    return loadResult(th, loadFromReader(th, reader, name, mode), env);
}

/// Calls the reader until it returns nil or an empty string, then
/// compiles the pieces. The reader's errors are load's errors.
fn loadFromReader(th: *Thread, reader: Value, name: []const u8, mode: []const u8) Error!Value {
    const gpa = th.heap().allocator();
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    while (true) {
        try th.ensureStack(1);
        const func = th.top;
        th.push(reader);
        if (!vm.pcall(th, func, 1)) {
            const e = th.stack[func];
            th.top = func;
            return th.throw(e);
        }
        const piece = th.stack[func];
        th.top = func;
        if (piece.isNil()) break;
        if (piece.isString()) {
            if (piece.asString().len == 0) break;
            try src.appendSlice(gpa, piece.asString().bytes());
        } else if (piece.isNumber()) {
            var buf: [number.max_len]u8 = undefined;
            try src.appendSlice(gpa, formatNumber(&buf, piece));
        } else {
            return raise(th, "reader function must return a string", .{});
        }
    }
    try src.append(gpa, 0);
    return loadChunk(th, src.items[0 .. src.items.len - 1 :0], name, mode);
}

fn dofile(th: *Thread, base: u32) Error!u32 {
    const fname = try optString(th, base, 1, "dofile");
    const f = try loadFile(th, if (fname) |s| s.bytes() else null, "bt");
    const func = th.top;
    th.push(f);
    try vm.call(th, func, -1);
    return th.top - func;
}

fn assert(th: *Thread, base: u32) Error!u32 {
    const v = get(th, base, 1);
    if (!v.isFalsy()) return th.top - base;
    _ = try checkAny(th, base, 1, "assert");
    var msg = get(th, base, 2);
    if (opt(th, base, 2) == null) msg = .string(try th.state.newString("assertion failed!"));
    th.top = base;
    th.push(msg);
    return @"error"(th, base);
}

fn select(th: *Thread, base: u32) Error!u32 {
    const n: i64 = th.top - base;
    const first = get(th, base, 1);
    if (first.isString() and first.asString().len > 0 and first.asString().bytes()[0] == '#')
        return ret1(th, .int(n - 1));
    var i = try checkInteger(th, base, 1, "select");
    if (i < 0) i = n + i else if (i > n) i = n;
    if (i < 1) return argError(th, 1, "select", "index out of range");
    return @intCast(n - i);
}

fn pcall(th: *Thread, base: u32) Error!u32 {
    _ = try checkAny(th, base, 1, "pcall");
    // true, then the function and its arguments.
    try th.ensureStack(1);
    @memmove(th.stack[base + 1 .. th.top + 1], th.stack[base..th.top]);
    th.stack[base] = .true;
    th.top += 1;
    if (vm.pcall(th, base + 1, -1)) return th.top - base;
    th.stack[base] = .false;
    th.stack[base + 1] = try errorObject(th, th.stack[base + 1]);
    return 2;
}

fn xpcall(th: *Thread, base: u32) Error!u32 {
    const n = th.top - base;
    const handler = get(th, base, 2);
    if (!handler.isFunction()) return typeError(th, base, 2, "xpcall", "function");
    // handler, true, the function, its arguments.
    try th.ensureStack(1);
    @memmove(th.stack[base + 3 .. th.top + 1], th.stack[base + 2 .. th.top]);
    th.stack[base + 2] = th.stack[base];
    th.stack[base] = handler;
    th.stack[base + 1] = .true;
    th.top = base + n + 1;
    if (vm.pcall(th, base + 2, -1)) return th.top - base - 1;
    // TODO(vm): PUC-Rio runs the handler where the error happened, before
    // unwinding; here it runs after, with the error object.
    const err = th.stack[base + 2];
    th.top = base + 2;
    th.push(handler);
    th.push(err);
    _ = vm.pcall(th, base + 2, 1);
    th.stack[base + 1] = .false;
    th.stack[base + 2] = try errorObject(th, th.stack[base + 2]);
    th.top = base + 3;
    return 2;
}

fn tostring(th: *Thread, base: u32) Error!u32 {
    const v = try checkAny(th, base, 1, "tostring");
    return ret1(th, try toStringValue(th, v));
}

const funcs = [_]struct { []const u8, Value.NativeFn }{
    .{ "assert", &assert },
    .{ "collectgarbage", &collectgarbage },
    .{ "dofile", &dofile },
    .{ "error", &@"error" },
    .{ "getmetatable", &getmetatable },
    .{ "ipairs", &ipairs },
    .{ "loadfile", &loadfile },
    .{ "load", &load },
    .{ "next", &next },
    .{ "pairs", &pairs },
    .{ "pcall", &pcall },
    .{ "print", &print },
    .{ "warn", &warn },
    .{ "rawequal", &rawequal },
    .{ "rawlen", &rawlen },
    .{ "rawget", &rawget },
    .{ "rawset", &rawset },
    .{ "select", &select },
    .{ "setmetatable", &setmetatable },
    .{ "tonumber", &tonumber },
    .{ "tostring", &tostring },
    .{ "type", &@"type" },
    .{ "xpcall", &xpcall },
};

/// Opens the library into the globals: the functions, `_G`, and
/// `_VERSION`.
pub fn open(th: *Thread) Error!void {
    const state = th.state;
    const g = state.globals;
    for (funcs) |f| try g.setStr(&state.heap, try state.newString(f[0]), .native(f[1]));
    try g.setStr(&state.heap, try state.newString("_G"), .table(g));
    try g.setStr(&state.heap, try state.newString("_VERSION"), .string(try state.newString(root.version)));
}

const testing = std.testing;

test "a chunk compiles and runs end to end with the base library" {
    const state = try State.create(testing.allocator, .{});
    defer state.destroy();
    var host: Host = undefined;
    host.init(testing.io);
    const th = state.main;
    try lib.openLibs(th, &host);
    const src =
        \\local acc = {}
        \\for i = 1, 3 do acc[#acc + 1] = function() return i * 10 end end
        \\local t = setmetatable({}, {__index = function(_, k) return k .. "?" end})
        \\local ok, err = pcall(error, {code = 7})
        \\local s = 0
        \\do local i = 0 ::top:: i = i + 1 s = s + i if i < 4 then goto top end end
        \\return acc[1]() + acc[3](), t.x, ok, err.code, select("#", 1, nil, nil), s,
        \\  tostring(nil), tonumber("ff", 16), (load("return ...", "c", "t", {}))(5)
    ;
    const func = th.top;
    th.push(try loadChunk(th, src, "=test", "t"));
    try vm.call(th, func, -1);
    const r = th.stack[func..th.top];
    try testing.expectEqual(9, r.len);
    try testing.expectEqual(40, r[0].asInt());
    try testing.expectEqualStrings("x?", r[1].asString().bytes());
    try testing.expect(r[2].isFalsy());
    try testing.expectEqual(7, r[3].asInt());
    try testing.expectEqual(3, r[4].asInt());
    try testing.expectEqual(10, r[5].asInt());
    try testing.expectEqualStrings("nil", r[6].asString().bytes());
    try testing.expectEqual(255, r[7].asInt());
    try testing.expectEqual(5, r[8].asInt());
}

//! Lua 5.5.1's auxiliary library, `lauxlib.h`, for C modules, after
//! lauxlib.c and with its messages. The checks reuse the standard
//! library's (`lib/auxlib.zig`, `debuginfo.zig`), so a C module's
//! "bad argument" errors read as the built-in functions' do.

const std = @import("std");
const Value = @import("../Value.zig");
const String = @import("../String.zig");
const Thread = @import("../Thread.zig");
const debuginfo = @import("../debuginfo.zig");
const aux = @import("../lib/auxlib.zig");
const base = @import("../lib/base.zig");
const capi = @import("capi.zig");
const va = @import("va.zig");
const liolib = @import("liolib.zig");

const Error = Value.Error;
// The headers' type names, as in capi.zig.
const lua_State = capi.lua_State; // ziglint-ignore: Z006
const lua_CFunction = capi.lua_CFunction; // ziglint-ignore: Z006
const lua_Integer = capi.lua_Integer; // ziglint-ignore: Z006
const lua_Number = capi.lua_Number; // ziglint-ignore: Z006
const throw = capi.throw;
const span = capi.span;
const registry_index = capi.registry_index;

extern "c" fn strerror(errnum: c_int) [*:0]const u8;

const lua_tnil = 0;
const lua_tstring = 4;
const lua_ttable = 5;
const lua_tlightuserdata = 2;
const lua_tnone = -1;

/// The value at a valid stack index.
fn value(th: *Thread, idx: c_int) Value {
    if (idx > 0) return th.stack[th.frame().func + @as(u32, @intCast(idx))];
    return th.stack[th.top - @as(u32, @intCast(-idx))];
}

fn argNone(th: *Thread, arg: c_int) bool {
    return th.frame().func + @as(i64, arg) >= th.top;
}

/// `luaL_argerror`'s message for argument `arg` of the running C
/// function, raised.
fn argError(th: *Thread, arg: c_int, msg: []const u8) noreturn {
    throw(th, debuginfo.argError(th, @intCast(arg), "?", msg));
}

fn typeError(th: *Thread, arg: c_int, tname: []const u8) noreturn {
    const got = if (argNone(th, arg)) "no value" else aux.typeName(th.state, value(th, arg));
    var buf: [256]u8 = undefined;
    const msg = std.mem.print(&buf, "{s} expected, got {s}", .{ tname, got }) catch buf[0..];
    argError(th, arg, msg);
}

fn lauxCheckversion(L: *lua_State, ver: lua_Number, sz: usize) callconv(.c) void {
    if (sz != @sizeOf(lua_Integer) * 16 + @sizeOf(lua_Number))
        throw(L, aux.raise(L, "core and library have incompatible numeric types", .{}));
    if (ver != 505) throw(L, aux.raise(L, "version mismatch: app. needs {d}, Lua core provides 505", .{ver}));
}

fn lauxGetmetafield(L: *lua_State, obj: c_int, e: [*:0]const u8) callconv(.c) c_int {
    if (capi.luaGetmetatable(L, obj) == 0) return lua_tnil;
    _ = capi.luaPushstring(L, e);
    const mt = value(L, -2).asTable();
    const v = mt.get(value(L, -1));
    if (v.isNil()) {
        L.top -= 2;
        return lua_tnil;
    }
    L.top -= 1;
    L.stack[L.top - 1] = v;
    return @backingInt(v.typeOf());
}

fn lauxCallmeta(L: *lua_State, obj_in: c_int, e: [*:0]const u8) callconv(.c) c_int {
    const obj = capi.luaAbsindex(L, obj_in);
    if (lauxGetmetafield(L, obj, e) == lua_tnil) return 0;
    capi.luaPushvalue(L, obj);
    capi.luaCallk(L, 1, 1, 0, null);
    return 1;
}

fn lauxTolstring(L: *lua_State, idx: c_int, len: ?*usize) callconv(.c) [*:0]const u8 {
    const v = if (idx > registry_index) value(L, idx) else blk: {
        capi.luaPushvalue(L, idx);
        const x = value(L, -1);
        L.top -= 1;
        break :blk x;
    };
    const s = capi.check(L, aux.tolstring(L, v));
    L.stack[L.top] = .string(s);
    L.top += 1;
    if (len) |p| p.* = s.len();
    return s.bytesZ().ptr;
}

fn lauxArgerror(L: *lua_State, arg: c_int, extramsg: [*:0]const u8) callconv(.c) c_int {
    argError(L, arg, span(extramsg));
}

fn lauxTypeerror(L: *lua_State, arg: c_int, tname: [*:0]const u8) callconv(.c) c_int {
    typeError(L, arg, span(tname));
}

fn lauxChecklstring(L: *lua_State, arg: c_int, len: ?*usize) callconv(.c) [*:0]const u8 {
    return capi.luaTolstring(L, arg, len) orelse typeError(L, arg, "string");
}

fn lauxOptlstring(L: *lua_State, arg: c_int, def: ?[*:0]const u8, len: ?*usize) callconv(.c) ?[*:0]const u8 {
    if (capi.luaType(L, arg) <= 0) {
        if (len) |p| p.* = if (def) |d| span(d).len else 0;
        return def;
    }
    return lauxChecklstring(L, arg, len);
}

fn lauxChecknumber(L: *lua_State, arg: c_int) callconv(.c) lua_Number {
    var isnum: c_int = 0;
    const d = capi.luaTonumberx(L, arg, &isnum);
    if (isnum == 0) typeError(L, arg, "number");
    return d;
}

fn lauxOptnumber(L: *lua_State, arg: c_int, def: lua_Number) callconv(.c) lua_Number {
    return if (capi.luaType(L, arg) <= 0) def else lauxChecknumber(L, arg);
}

fn lauxCheckinteger(L: *lua_State, arg: c_int) callconv(.c) lua_Integer {
    var isnum: c_int = 0;
    const d = capi.luaTointegerx(L, arg, &isnum);
    if (isnum == 0) {
        if (capi.luaIsnumber(L, arg) != 0) argError(L, arg, "number has no integer representation");
        typeError(L, arg, "number");
    }
    return d;
}

fn lauxOptinteger(L: *lua_State, arg: c_int, def: lua_Integer) callconv(.c) lua_Integer {
    return if (capi.luaType(L, arg) <= 0) def else lauxCheckinteger(L, arg);
}

fn lauxCheckstack(L: *lua_State, sz: c_int, msg: ?[*:0]const u8) callconv(.c) void {
    if (capi.luaCheckstack(L, sz) != 0) return;
    if (msg) |m| throw(L, aux.raise(L, "stack overflow ({s})", .{span(m)}));
    throw(L, aux.raise(L, "stack overflow", .{}));
}

fn lauxChecktype(L: *lua_State, arg: c_int, t: c_int) callconv(.c) void {
    if (capi.luaType(L, arg) != t) typeError(L, arg, span(capi.luaTypename(L, t)));
}

fn lauxCheckany(L: *lua_State, arg: c_int) callconv(.c) void {
    if (capi.luaType(L, arg) == lua_tnone) argError(L, arg, "value expected");
}

fn lauxNewmetatable(L: *lua_State, tname: [*:0]const u8) callconv(.c) c_int {
    if (capi.luaGetfield(L, registry_index, tname) != lua_tnil) return 0;
    L.top -= 1;
    capi.luaCreatetable(L, 0, 2);
    _ = capi.luaPushstring(L, tname);
    capi.luaSetfield(L, -2, "__name");
    capi.luaPushvalue(L, -1);
    capi.luaSetfield(L, registry_index, tname);
    return 1;
}

fn lauxSetmetatable(L: *lua_State, tname: [*:0]const u8) callconv(.c) void {
    _ = capi.luaGetfield(L, registry_index, tname);
    _ = capi.luaSetmetatable(L, -2);
}

fn lauxTestudata(L: *lua_State, ud: c_int, tname: [*:0]const u8) callconv(.c) ?*anyopaque {
    const v = capi.luaTouserdata(L, ud) orelse return null;
    if (value(L, ud).tag != .userdata) return null;
    const mt = value(L, ud).asUserdata().metatable orelse return null;
    const want = L.state.registry.getStr(capi.check(L, L.state.newString(span(tname))));
    if (want.tag != .table or want.asTable() != mt) return null;
    return v;
}

fn lauxCheckudata(L: *lua_State, ud: c_int, tname: [*:0]const u8) callconv(.c) *anyopaque {
    return lauxTestudata(L, ud, tname) orelse typeError(L, ud, span(tname));
}

fn lauxWhere(L: *lua_State, lvl: c_int) callconv(.c) void {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    // A chunk id (60 bytes at most), a line number, and two colons fit.
    debuginfo.where(L, @intCast(lvl), &w) catch unreachable;
    _ = capi.luaPushlstring(L, &buf, w.end);
}

fn lauxError(L: *lua_State, fmt: [*:0]const u8, ...) callconv(.c) c_int {
    var ap = @cVaStart();
    const r = capi.pushVfString(L, fmt, &ap);
    @cVaEnd(&ap);
    _ = capi.check(L, r);
    raiseMessage(L);
}

/// `luaL_error` past its `...`, for aarch64 Linux (`va.zig`).
fn lauxErrorv(L: *lua_State, fmt: [*:0]const u8, ap: *va.List) callconv(.c) c_int {
    _ = capi.check(L, capi.pushVfString(L, fmt, ap));
    raiseMessage(L);
}

/// Raises the message `luaL_error` formatted, which is on top.
fn raiseMessage(L: *lua_State) noreturn {
    const msg = L.stack[L.top - 1].asString();
    var aw: std.Io.Writer.Allocating = .init(L.heap().allocator());
    const s = errorMessage(L, &aw, msg.bytes());
    aw.deinit();
    throw(L, L.throw(.string(capi.check(L, s))));
}

fn errorMessage(L: *lua_State, aw: *std.Io.Writer.Allocating, msg: []const u8) Error!*String {
    debuginfo.where(L, 1, &aw.writer) catch return error.OutOfMemory;
    aw.writer.writeAll(msg) catch return error.OutOfMemory;
    return L.state.newString(aw.written());
}

fn lauxCheckoption(
    L: *lua_State,
    arg: c_int,
    def: ?[*:0]const u8,
    lst: [*:null]const ?[*:0]const u8,
) callconv(.c) c_int {
    const name = if (def) |d| lauxOptlstring(L, arg, d, null).? else lauxChecklstring(L, arg, null);
    var i: usize = 0;
    while (lst[i]) |opt| : (i += 1) {
        if (std.mem.orderZ(u8, opt, name) == .eq) return @intCast(i);
    }
    var buf: [256]u8 = undefined;
    const msg = std.mem.print(&buf, "invalid option '{s}'", .{span(name)}) catch buf[0..];
    argError(L, arg, msg);
}

fn lauxFileresult(L: *lua_State, stat: c_int, fname: ?[*:0]const u8) callconv(.c) c_int {
    const en = std.c._errno().*;
    if (stat != 0) {
        capi.luaPushboolean(L, 1);
        return 1;
    }
    capi.luaPushnil(L);
    const msg = if (en != 0) span(strerror(en)) else "(no extra info)";
    if (fname) |f| {
        // `lua_pushfstring(L, "%s: %s", fname, msg)`, whatever the length.
        _ = capi.luaPushstring(L, f);
        _ = capi.luaPushlstring(L, ": ", 2);
        _ = capi.luaPushlstring(L, msg.ptr, msg.len);
        capi.luaConcat(L, 3);
    } else {
        _ = capi.luaPushlstring(L, msg.ptr, msg.len);
    }
    capi.luaPushinteger(L, en);
    return 3;
}

fn lauxRef(L: *lua_State, t_in: c_int) callconv(.c) c_int {
    if (capi.luaType(L, -1) == lua_tnil) {
        L.top -= 1;
        return -1;
    }
    const t = capi.luaAbsindex(L, t_in);
    var ref: lua_Integer = 0;
    if (capi.luaRawgeti(L, t, 1) == 3) {
        ref = capi.luaTointegerx(L, -1, null);
    } else {
        capi.luaPushinteger(L, 0);
        capi.luaRawseti(L, t, 1);
    }
    L.top -= 1;
    if (ref != 0) {
        _ = capi.luaRawgeti(L, t, ref);
        capi.luaRawseti(L, t, 1);
    } else {
        ref = @intCast(capi.luaRawlen(L, t) + 1);
    }
    capi.luaRawseti(L, t, ref);
    return @intCast(ref);
}

fn lauxUnref(L: *lua_State, t_in: c_int, ref: c_int) callconv(.c) void {
    if (ref < 0) return;
    const t = capi.luaAbsindex(L, t_in);
    _ = capi.luaRawgeti(L, t, 1);
    capi.luaRawseti(L, t, ref);
    capi.luaPushinteger(L, ref);
    capi.luaRawseti(L, t, 1);
}

/// The status of a failed load, with its error object pushed.
fn loadFailed(L: *lua_State, e: Error) c_int {
    switch (e) {
        error.OutOfMemory => {
            L.stack[L.top] = .string(L.state.memerr);
            L.top += 1;
            return capi.lua_errmem;
        },
        error.LuaError => {
            L.stack[L.top] = L.err;
            L.top += 1;
            L.err = .nil;
            return capi.lua_errsyntax;
        },
    }
}

fn lauxLoadfilex(L: *lua_State, filename: ?[*:0]const u8, mode: ?[*:0]const u8) callconv(.c) c_int {
    const f = base.loadFile(L, if (filename) |n| span(n) else null, if (mode) |m| span(m) else "bt") catch |e| {
        const st = loadFailed(L, e);
        // lauxlib's `errfile`: a file that cannot be read is LUA_ERRFILE.
        const v = L.stack[L.top - 1];
        if (st == capi.lua_errsyntax and v.isString() and std.mem.startsWith(u8, v.asString().bytes(), "cannot "))
            return capi.lua_errerr + 1;
        return st;
    };
    L.ensureStack(1) catch |e| return loadFailed(L, e);
    L.stack[L.top] = f;
    L.top += 1;
    return capi.lua_ok;
}

fn lauxLoadbufferx(
    L: *lua_State,
    buff: [*]const u8,
    sz: usize,
    name: [*:0]const u8,
    mode: ?[*:0]const u8,
) callconv(.c) c_int {
    // The loader wants a terminating zero; the copy lives in a box on the
    // stack, which the collector frees.
    // Never raises, as `lua_load`.
    L.ensureStack(2) catch |e| return loadFailed(L, e);
    const slot = L.top;
    L.stack[slot] = .nil;
    L.top += 1;
    const b = capi.Box.grow(L, slot, buff[0..sz], sz + 1) catch |e| {
        L.top = slot;
        return loadFailed(L, e);
    };
    b[sz] = 0;
    const f = base.loadChunk(L, b[0..sz :0], span(name), if (mode) |m| span(m) else "bt") catch |e| {
        capi.Box.release(L, slot);
        L.top = slot;
        return loadFailed(L, e);
    };
    capi.Box.release(L, slot);
    L.stack[slot] = f;
    return capi.lua_ok;
}

fn lauxLoadstring(L: *lua_State, s: [*:0]const u8) callconv(.c) c_int {
    return lauxLoadbufferx(L, s, span(s).len, s, null);
}

fn lauxLen(L: *lua_State, idx: c_int) callconv(.c) lua_Integer {
    capi.luaPushvalue(L, idx);
    const v = value(L, -1);
    L.top -= 1;
    return capi.check(L, aux.lenInt(L, v));
}

fn lauxAddgsub(B: *Buffer, s: [*:0]const u8, p: [*:0]const u8, r: [*:0]const u8) callconv(.c) void {
    var rest = span(s);
    const pat = span(p);
    const rep = span(r);
    while (std.mem.find(u8, rest, pat)) |i| {
        lauxAddlstring(B, rest.ptr, i);
        lauxAddlstring(B, rep.ptr, rep.len);
        rest = rest[i + pat.len ..];
    }
    lauxAddlstring(B, rest.ptr, rest.len);
}

fn lauxGsub(L: *lua_State, s: [*:0]const u8, p: [*:0]const u8, r: [*:0]const u8) callconv(.c) [*:0]const u8 {
    var b: Buffer = undefined;
    lauxBuffinit(L, &b);
    lauxAddgsub(&b, s, p, r);
    lauxPushresult(&b);
    return capi.luaTolstring(L, -1, null).?;
}

/// lauxlib.h's `luaL_Reg`.
pub const Reg = extern struct { name: ?[*:0]const u8, func: ?lua_CFunction };

fn lauxSetfuncs(L: *lua_State, l: [*]const Reg, nup: c_int) callconv(.c) void {
    lauxCheckstack(L, nup, "too many upvalues");
    var i: usize = 0;
    while (l[i].name) |name| : (i += 1) {
        if (l[i].func) |f| {
            var j: c_int = 0;
            while (j < nup) : (j += 1) capi.luaPushvalue(L, -nup);
            capi.luaPushcclosure(L, f, nup);
        } else {
            capi.luaPushboolean(L, 0);
        }
        capi.luaSetfield(L, -(nup + 2), name);
    }
    capi.luaSettop(L, -nup - 1);
}

pub fn lauxGetsubtable(L: *lua_State, idx_in: c_int, fname: [*:0]const u8) callconv(.c) c_int {
    if (capi.luaGetfield(L, idx_in, fname) == lua_ttable) return 1;
    L.top -= 1;
    const idx = capi.luaAbsindex(L, idx_in);
    capi.luaCreatetable(L, 0, 0);
    capi.luaPushvalue(L, -1);
    capi.luaSetfield(L, idx, fname);
    return 0;
}

fn lauxTraceback(L: *lua_State, L1: *lua_State, msg: ?[*:0]const u8, level: c_int) callconv(.c) void {
    var aw: std.Io.Writer.Allocating = .init(L.heap().allocator());
    const r = traceback(L, L1, &aw, if (msg) |m| span(m) else null, level);
    aw.deinit();
    capi.check(L, r);
}

fn traceback(L: *lua_State, L1: *lua_State, aw: *std.Io.Writer.Allocating, msg: ?[]const u8, level: c_int) Error!void {
    debuginfo.traceback(&aw.writer, L1, msg, level) catch return error.OutOfMemory;
    const s = try L.state.newString(aw.written());
    L.stack[L.top] = .string(s);
    L.top += 1;
}

pub fn lauxRequiref(L: *lua_State, modname: [*:0]const u8, openf: lua_CFunction, glb: c_int) callconv(.c) void {
    _ = lauxGetsubtable(L, registry_index, "_LOADED");
    _ = capi.luaGetfield(L, -1, modname);
    if (capi.luaToboolean(L, -1) == 0) {
        L.top -= 1;
        capi.luaPushcclosure(L, openf, 0);
        _ = capi.luaPushstring(L, modname);
        capi.luaCallk(L, 1, 1, 0, null);
        capi.luaPushvalue(L, -1);
        capi.luaSetfield(L, -3, modname);
    }
    capi.luaRotate(L, -2, -1);
    L.top -= 1;
    if (glb != 0) {
        capi.luaPushvalue(L, -1);
        capi.luaSetglobal(L, modname);
    }
}

pub fn lauxMakeseed(L: ?*lua_State) callconv(.c) c_uint {
    _ = L;
    var local: u8 = 0;
    const bits = [_]usize{ @intFromPtr(&local), @intFromPtr(&lauxMakeseed) };
    return @truncate(std.hash.Wyhash.hash(0, std.mem.asBytes(&bits)));
}

pub fn lauxAlloc(ud: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.c) ?*anyopaque {
    _ = ud;
    _ = osize;
    if (nsize == 0) {
        std.c.free(ptr);
        return null;
    }
    return std.c.realloc(ptr, nsize);
}

// ---------------------------------------------------------------------------
// Buffers
// ---------------------------------------------------------------------------

/// lauxlib.h's `luaL_Buffer`. `b` points at `init` until the contents
/// outgrow it; then they live in a box, a full userdata in the stack slot
/// that held the placeholder (`capi.Box`).
pub const Buffer = extern struct {
    b: [*]u8,
    size: usize,
    n: usize,
    L: *lua_State,
    init: extern union {
        align_: c_longdouble,
        b: [buffer_size]u8,
    },
};

/// `LUAL_BUFFERSIZE`.
const buffer_size = 16 * @sizeOf(?*anyopaque) * @sizeOf(lua_Number);

comptime {
    std.debug.assert(@sizeOf(Buffer) == 32 + buffer_size);
    std.debug.assert(@offsetOf(Buffer, "init") == 32);
}

/// `prepbuffsize`: room for `sz` more bytes, with the box or placeholder
/// at stack index `boxidx`.
fn prepBuffSize(B: *Buffer, sz: usize, boxidx: c_int) [*]u8 {
    if (B.size - B.n >= sz) return B.b + B.n;
    const L = B.L;
    if (sz >= std.math.maxInt(usize) / 2 - B.n) throw(L, aux.raise(L, "resulting string too large", .{}));
    var newsize = B.size + (B.size >> 1);
    if (newsize < B.n + sz + 1) newsize = B.n + sz + 1;
    const slot = L.top - @as(u32, @intCast(-boxidx));
    const b = capi.check(L, capi.Box.grow(L, slot, B.b[0..B.n], newsize));
    B.b = b.ptr;
    B.size = newsize;
    return B.b + B.n;
}

fn lauxBuffinit(L: *lua_State, B: *Buffer) callconv(.c) void {
    B.L = L;
    B.b = &B.init.b;
    B.n = 0;
    B.size = buffer_size;
    capi.luaPushlightuserdata(L, B);
}

fn lauxPrepbuffsize(B: *Buffer, sz: usize) callconv(.c) [*]u8 {
    return prepBuffSize(B, sz, -1);
}

fn lauxAddlstring(B: *Buffer, s: [*]const u8, l: usize) callconv(.c) void {
    if (l == 0) return;
    const b = prepBuffSize(B, l, -1);
    @memcpy(b[0..l], s[0..l]);
    B.n += l;
}

fn lauxAddstring(B: *Buffer, s: [*:0]const u8) callconv(.c) void {
    lauxAddlstring(B, s, span(s).len);
}

fn lauxAddvalue(B: *Buffer) callconv(.c) void {
    const L = B.L;
    var len: usize = 0;
    const s = capi.luaTolstring(L, -1, &len).?;
    const b = prepBuffSize(B, len, -2);
    @memcpy(b[0..len], s[0..len]);
    B.n += len;
    L.top -= 1;
}

fn lauxPushresult(B: *Buffer) callconv(.c) void {
    const L = B.L;
    // A long result in a box becomes its string in place, as 5.5.1's
    // `luaL_pushresult` makes its box an external string: no copy, and
    // no second block (results/capi-perf-20261101.md).
    if (B.b != &B.init.b) if (capi.check(L, capi.Box.toString(L, L.top - 1, B.n))) |s| {
        L.stack[L.top - 1] = .string(s);
        return;
    };
    _ = capi.luaPushlstring(L, B.b, B.n);
    if (B.b != &B.init.b) capi.Box.release(L, L.top - 2);
    capi.luaRotate(L, -2, -1);
    L.top -= 1;
}

fn lauxPushresultsize(B: *Buffer, sz: usize) callconv(.c) void {
    B.n += sz;
    lauxPushresult(B);
}

fn lauxBuffinitsize(L: *lua_State, B: *Buffer, sz: usize) callconv(.c) [*]u8 {
    lauxBuffinit(L, B);
    return prepBuffSize(B, sz, -1);
}

// The C names of this file's functions, as the headers declare them.
comptime {
    @export(&lauxCheckversion, .{ .name = "luaL_checkversion_" });
    @export(&lauxGetmetafield, .{ .name = "luaL_getmetafield" });
    @export(&lauxCallmeta, .{ .name = "luaL_callmeta" });
    @export(&lauxTolstring, .{ .name = "luaL_tolstring" });
    @export(&lauxArgerror, .{ .name = "luaL_argerror" });
    @export(&lauxTypeerror, .{ .name = "luaL_typeerror" });
    @export(&lauxChecklstring, .{ .name = "luaL_checklstring" });
    @export(&lauxOptlstring, .{ .name = "luaL_optlstring" });
    @export(&lauxChecknumber, .{ .name = "luaL_checknumber" });
    @export(&lauxOptnumber, .{ .name = "luaL_optnumber" });
    @export(&lauxCheckinteger, .{ .name = "luaL_checkinteger" });
    @export(&lauxOptinteger, .{ .name = "luaL_optinteger" });
    @export(&lauxCheckstack, .{ .name = "luaL_checkstack" });
    @export(&lauxChecktype, .{ .name = "luaL_checktype" });
    @export(&lauxCheckany, .{ .name = "luaL_checkany" });
    @export(&lauxNewmetatable, .{ .name = "luaL_newmetatable" });
    @export(&lauxSetmetatable, .{ .name = "luaL_setmetatable" });
    @export(&lauxTestudata, .{ .name = "luaL_testudata" });
    @export(&lauxCheckudata, .{ .name = "luaL_checkudata" });
    @export(&lauxWhere, .{ .name = "luaL_where" });
    @export(if (va.native) &lauxError else &va.Entry(&lauxErrorv).entry, .{ .name = "luaL_error" });
    @export(&lauxCheckoption, .{ .name = "luaL_checkoption" });
    @export(&lauxFileresult, .{ .name = "luaL_fileresult" });
    // io's, which `pclose` uses: one `luaL_execresult` for both.
    @export(&liolib.execResult, .{ .name = "luaL_execresult" });
    @export(&lauxRef, .{ .name = "luaL_ref" });
    @export(&lauxUnref, .{ .name = "luaL_unref" });
    @export(&lauxLoadfilex, .{ .name = "luaL_loadfilex" });
    @export(&lauxLoadbufferx, .{ .name = "luaL_loadbufferx" });
    @export(&lauxLoadstring, .{ .name = "luaL_loadstring" });
    @export(&lauxLen, .{ .name = "luaL_len" });
    @export(&lauxAddgsub, .{ .name = "luaL_addgsub" });
    @export(&lauxGsub, .{ .name = "luaL_gsub" });
    @export(&lauxSetfuncs, .{ .name = "luaL_setfuncs" });
    @export(&lauxGetsubtable, .{ .name = "luaL_getsubtable" });
    @export(&lauxTraceback, .{ .name = "luaL_traceback" });
    @export(&lauxRequiref, .{ .name = "luaL_requiref" });
    @export(&lauxMakeseed, .{ .name = "luaL_makeseed" });
    @export(&lauxAlloc, .{ .name = "luaL_alloc" });
    @export(&lauxBuffinit, .{ .name = "luaL_buffinit" });
    @export(&lauxPrepbuffsize, .{ .name = "luaL_prepbuffsize" });
    @export(&lauxAddlstring, .{ .name = "luaL_addlstring" });
    @export(&lauxAddstring, .{ .name = "luaL_addstring" });
    @export(&lauxAddvalue, .{ .name = "luaL_addvalue" });
    @export(&lauxPushresult, .{ .name = "luaL_pushresult" });
    @export(&lauxPushresultsize, .{ .name = "luaL_pushresultsize" });
    @export(&lauxBuffinitsize, .{ .name = "luaL_buffinitsize" });
}

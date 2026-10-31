//! C libraries for the package library in a C-API build, after
//! loadlib.c's `LUA_USE_DLOPEN` part: `dlopen` with `RTLD_NOW`, global
//! symbols only for `loadlib(path, "*")`, handles kept in the registry's
//! `_CLIBS` by path and in load order, and `luaopen_` names with `.` as
//! `_` and the part before a `-` tried first. `closeLibs` closes them when
//! the state closes.

const std = @import("std");
const Value = @import("../Value.zig");
const String = @import("../String.zig");
const Thread = @import("../Thread.zig");
const State = @import("../State.zig");
const package = @import("../lib/package.zig");
const capi = @import("capi.zig");

const Error = Value.Error;

/// What `lookforfunc` found: the function (or true, for `"*"`), or the
/// system's message for a library that would not load (`open`) or a
/// missing symbol (`init`).
pub const Look = union(enum) { ok: Value, open: []const u8, init: []const u8 };

fn dlerror() []const u8 {
    return if (std.c.dlerror()) |m| std.mem.span(m) else "unknown error";
}

var libm_loaded = false;

/// Opens library `path`. Modules may call libm without linking it
/// (lua-cjson's `floor`), because the reference's lua links it; this one
/// has its own math and does not. So a library that fails to open is
/// tried once more after libm's symbols are made global, which only such
/// a library pays for (libm adds 400 KiB of RSS).
fn open(path: [*:0]const u8, global: bool) ?*anyopaque {
    const flags: std.c.RTLD = .{ .NOW = true, .GLOBAL = global };
    if (std.c.dlopen(path, flags)) |h| return h;
    if (libm_loaded) return null;
    libm_loaded = true;
    _ = std.c.dlopen("libm.so.6", .{ .NOW = true, .GLOBAL = true }) orelse return null;
    return std.c.dlopen(path, flags);
}

/// `lookforfunc`: symbol `sym` of library `path`, loading the library
/// first if no earlier call did.
pub fn lookForFunc(th: *Thread, path_in: []const u8, sym_in: []const u8) Error!Look {
    const state = th.state;
    const path = std.mem.sliceTo(path_in, 0);
    const sym = std.mem.sliceTo(sym_in, 0);
    const clibs = try package.registryTable(state, "_CLIBS");
    const key = try state.newString(path);
    var handle: ?*anyopaque = null;
    const known = clibs.getStr(key);
    if (known.tag == .light_userdata) handle = known.asLightUserdata();
    if (handle == null) {
        // `key`'s bytes end in a zero, as dlopen needs.
        handle = open(key.bytesZ().ptr, sym.len > 0 and sym[0] == '*') orelse return .{ .open = dlerror() };
        const n: i64 = @intCast(clibs.length() + 1);
        // On a memory error the handle stays open until the process ends.
        try clibs.setStr(&state.heap, key, .lightUserdata(handle));
        try clibs.setInt(&state.heap, n, .lightUserdata(handle));
    }
    if (sym.len > 0 and sym[0] == '*') return .{ .ok = .true };
    var buf: [256]u8 = undefined;
    if (sym.len >= buf.len) return .{ .init = "symbol name too long" };
    @memcpy(buf[0..sym.len], sym);
    buf[sym.len] = 0;
    // dlsym reads its caller's return address; keep it a real call.
    const f = @call(.never_tail, std.c.dlsym, .{ handle, buf[0..sym.len :0].ptr }) orelse return .{ .init = dlerror() };
    // Not `lua_pushcclosure`: a C API function raises by jumping to the
    // innermost C function, and this runs inside a Zig one.
    return .{ .ok = try capi.lightCFunction(th, @ptrCast(@alignCast(f))) };
}

/// `loadfunc`: module `modname`'s open function in library `filename`.
pub fn loadFunc(th: *Thread, filename: *String, modname_in: []const u8) Error!Look {
    var buf: [256]u8 = undefined;
    const modname = std.mem.sliceTo(modname_in, 0);
    if (modname.len + "luaopen_".len >= buf.len) return .{ .init = "module name too long" };
    @memcpy(buf[0.."luaopen_".len], "luaopen_");
    const name = buf["luaopen_".len..][0..modname.len];
    for (name, modname) |*d, c| d.* = if (c == '.') '_' else c;
    if (std.mem.findScalar(u8, name, '-')) |mark| {
        const r = try lookForFunc(th, filename.bytes(), buf[0 .. "luaopen_".len + mark]);
        if (r != .init) return r;
        const rest = name[mark + 1 ..];
        @memmove(buf["luaopen_".len..][0..rest.len], rest);
        return lookForFunc(th, filename.bytes(), buf[0 .. "luaopen_".len + rest.len]);
    }
    return lookForFunc(th, filename.bytes(), buf[0 .. "luaopen_".len + name.len]);
}

/// Closes the libraries `lookForFunc` opened, the last opened first, as
/// the reference does when `lua_close` frees each library's string: after
/// every finalizer has run, so no `__gc` of a module runs after its code
/// is unmapped. `State.destroy` calls it.
pub fn closeLibs(state: *State) void {
    const key = state.newString("_CLIBS") catch return;
    const v = state.registry.getStr(key);
    if (v.tag != .table) return;
    const clibs = v.asTable();
    var n: i64 = @intCast(clibs.length());
    while (n >= 1) : (n -= 1) {
        const h = clibs.get(.int(n));
        if (h.tag == .light_userdata) _ = std.c.dlclose(h.asLightUserdata().?);
    }
}

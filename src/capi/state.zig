//! States for C hosts, after lstate.c, linit.c, and lauxlib.c's state
//! functions: `lua_newstate` with the host's `lua_Alloc`, `lua_close`,
//! `luaL_newstate`, `luaL_openselectedlibs`, and the `luaopen_*`
//! functions, which `liblua.a` and `liblua.so` export
//! (docs/slop/c-api.md).
//!
//! A state from `lua_newstate` allocates every byte through the host's
//! function: its heap's backing allocator is an adapter over it, whose
//! context, `CState`, also holds what the libraries need from a host
//! (`base.Host`). States the Zig API makes keep their own allocator and
//! host.

const std = @import("std");
const Value = @import("../Value.zig");
const Thread = @import("../Thread.zig");
const State = @import("../State.zig");
const vm = @import("../vm.zig");
const lib = @import("../lib/init.zig");
const api = @import("../api.zig");
const capi = @import("capi.zig");
const lauxlib = @import("lauxlib.zig");

const Error = Value.Error;
// The headers' type names, as in capi.zig.
const lua_State = capi.lua_State; // ziglint-ignore: Z006
const lua_Alloc = capi.lua_Alloc; // ziglint-ignore: Z006
const check = capi.check;

/// What a state from `lua_newstate` keeps beside the engine's state,
/// allocated through its `lua_Alloc`.
pub const CState = struct {
    f: lua_Alloc,
    ud: ?*anyopaque,
    host: lib.base.Host,
    /// The process environment for `os.getenv` and `package`'s paths,
    /// read when one of those libraries opens.
    environ: ?std.process.Environ.Map = null,

    fn allocator(cs: *CState) std.mem.Allocator {
        return .{ .ptr = cs, .vtable = &vtable };
    }

    /// The environment, read from libc's `environ` the first time.
    fn readEnviron(cs: *CState) error{OutOfMemory}!void {
        if (cs.environ != null) return;
        cs.environ = std.process.Environ.createMap(processEnviron(), cs.allocator()) catch return error.OutOfMemory;
        cs.host.environ = &cs.environ.?;
    }
};

/// The C-API data of `state` if `lua_newstate` made it, else null.
pub fn of(state: *const State) ?*CState {
    if (state.heap.backing.vtable != &vtable) return null;
    return @ptrCast(@alignCast(state.heap.backing.ptr));
}

// ---------------------------------------------------------------------------
// The allocator over a lua_Alloc
// ---------------------------------------------------------------------------

/// A `lua_Alloc` returns memory aligned as malloc's: 16 bytes here.
const max_align: std.mem.Alignment = .@"16";

const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, _: usize) ?[*]u8 {
    const cs: *CState = @ptrCast(@alignCast(ctx));
    if (a.compare(.gt, max_align)) return null;
    return @ptrCast(cs.f(cs.ud, null, 0, len));
}

/// In place only: a `lua_Alloc` may move a block it resizes.
fn resize(_: *anyopaque, mem: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
    return new_len == mem.len;
}

fn remap(ctx: *anyopaque, mem: []u8, _: std.mem.Alignment, new_len: usize, _: usize) ?[*]u8 {
    const cs: *CState = @ptrCast(@alignCast(ctx));
    return @ptrCast(cs.f(cs.ud, mem.ptr, mem.len, new_len));
}

fn free(ctx: *anyopaque, mem: []u8, _: std.mem.Alignment, _: usize) void {
    const cs: *CState = @ptrCast(@alignCast(ctx));
    _ = cs.f(cs.ud, mem.ptr, mem.len, 0);
}

// ---------------------------------------------------------------------------
// I/O for the libraries
// ---------------------------------------------------------------------------

fn processEnviron() std.process.Environ {
    const env: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
    return .{ .block = .{ .slice = std.mem.span(env) } };
}

/// One `std.Io` for every state of the process, on libc's allocator and
/// environment, which child processes inherit.
var threaded: std.Io.Threaded = .init_single_threaded;
var threaded_ready: std.atomic.Value(bool) = .init(false);

/// `std.Io.Threaded`'s functions minus the ones no library calls, as
/// `main.zig`'s table for `lua`: the full table keeps every one of them
/// in the binary (`docs/slop/results/lean-20261031.md`). An entry left
/// out panics with its name.
const io_vtable: std.Io.VTable = blk: {
    const full = std.Io.Threaded.global_single_threaded.io().vtable.*;
    const unused = [_][]const u8{
        "async",                   "concurrent",            "await",                 "cancel",
        "groupAsync",              "groupConcurrent",       "groupAwait",            "groupCancel",
        "dirCreateDirPath",        "dirCreateDirPathOpen",  "dirCreateFileAtomic",   "dirRenamePreserve",
        "dirSymLink",              "dirReadLink",           "dirSetOwner",           "dirSetFileOwner",
        "dirSetPermissions",       "dirSetFilePermissions", "dirSetTimestamps",      "dirHardLink",
        "fileWriteFilePositional", "fileSetOwner",          "fileSetPermissions",    "fileSetTimestamps",
        "fileLock",                "fileTryLock",           "fileUnlock",            "fileDowngradeLock",
        "fileRealPath",            "fileHardLink",          "fileMemoryMapCreate",   "fileMemoryMapDestroy",
        "fileMemoryMapSetLength",  "fileMemoryMapRead",     "fileMemoryMapWrite",    "processExecutableOpen",
        "processExecutablePath",   "processSetCurrentDir",  "processSetCurrentPath", "processReplace",
        "processReplacePath",      "progressParentFile",    "netListenIp",           "netAccept",
        "netBindIp",               "netConnectIp",          "netListenUnix",         "netConnectUnix",
        "netSocketCreatePair",     "netSend",               "netRead",               "netWrite",
        "netWriteFile",            "netClose",              "netShutdown",           "netInterfaceNameResolve",
        "netInterfaceName",        "netLookup",             "lockStderr",            "tryLockStderr",
        "unlockStderr",
    };
    var v = full;
    for (unused) |name| @field(v, name) = @ptrCast(&Unsupported(name).f);
    break :blk v;
};

fn Unsupported(comptime name: []const u8) type {
    return struct {
        fn f() noreturn {
            @panic("std.Io." ++ name ++ " is not in liblua's table");
        }
    };
}

fn libIo() std.Io {
    if (!threaded_ready.load(.acquire)) {
        threaded.allocator = std.heap.c_allocator;
        threaded.environ = .{ .process_environ = processEnviron() };
        threaded.environ_initialized = false;
        threaded_ready.store(true, .release);
    }
    return .{ .userdata = &threaded, .vtable = &io_vtable };
}

// ---------------------------------------------------------------------------
// lstate.c
// ---------------------------------------------------------------------------

fn luaNewstate(f: lua_Alloc, ud: ?*anyopaque, seed: c_uint) callconv(.c) ?*lua_State {
    const cs: *CState = @ptrCast(@alignCast(f(ud, null, 0, @sizeOf(CState)) orelse return null));
    cs.* = .{ .f = f, .ud = ud, .host = undefined };
    cs.host.init(libIo());
    const state = State.create(cs.allocator(), .{ .seed = seed }) catch {
        _ = f(ud, cs, @sizeOf(CState), 0);
        return null;
    };
    // The state's C data now, so the functions that set it never fail.
    _ = capi.threadData(state.main) catch {
        state.destroy();
        _ = f(ud, cs, @sizeOf(CState), 0);
        return null;
    };
    // The libraries' host, and no warning function until one is set.
    lib.base.setHost(state.main, &cs.host) catch unreachable;
    state.warnf = null;
    return state.main;
}

fn luaClose(L: *lua_State) callconv(.c) void {
    const state = L.state;
    const cs = of(state) orelse return api.State.close(@ptrCast(state.main));
    // Pending to-be-closed variables and finalizers may still write.
    vm.closeState(state);
    lib.io.flushAll(state.main);
    cs.host.flushStdout();
    if (cs.environ) |*m| m.deinit();
    state.destroy();
    _ = cs.f(cs.ud, cs, @sizeOf(CState), 0);
}

// ---------------------------------------------------------------------------
// lauxlib.c
// ---------------------------------------------------------------------------

/// lauxlib.c's `panic`: says why the program aborts.
fn panicf(L: *lua_State) callconv(.c) c_int {
    const v = L.stack[L.top - 1];
    const msg = if (v.isString()) v.asString().bytes() else "error object is not a string";
    const prefix = "PANIC: unprotected error in call to Lua API (";
    _ = std.c.write(2, prefix, prefix.len);
    _ = std.c.write(2, msg.ptr, msg.len);
    _ = std.c.write(2, ")\n", 2);
    return 0;
}

fn lauxNewstate() callconv(.c) ?*lua_State {
    const th = luaNewstate(&lauxlib.lauxAlloc, null, lauxlib.lauxMakeseed(null)) orelse return null;
    // The panic function and lauxlib's warnings, on until "@off". The
    // state's C data exists already.
    (capi.threadData(th) catch unreachable).panicf = &panicf;
    const cs = of(th.state).?;
    cs.host.warn = .on;
    lib.base.setHost(th, &cs.host) catch unreachable;
    return th;
}

// ---------------------------------------------------------------------------
// linit.c and the luaopen_ functions
// ---------------------------------------------------------------------------

/// The global each library's `open` sets, by `lib.Lib`.
const lib_names = [_][:0]const u8{
    "_G", "package", "coroutine", "debug", "io", "math", "os", "string", "table", "utf8",
};

/// Opens library `which` and pushes its table, as its `luaopen_` does.
/// Our libraries' `open` set their global, which `luaopen_` must not (a
/// host's `luaL_requiref` decides), so the global's old value comes back.
fn openLib(L: *Thread, comptime which: lib.Lib) Error!void {
    const state = L.state;
    if (which == .os or which == .package) if (of(state)) |cs| try cs.readEnviron();
    if (which == .base) {
        try lib.base.open(L);
        L.push(.table(state.globals));
        return;
    }
    const name = try state.newString(lib_names[@intFromEnum(which)]);
    const old = state.globals.getStr(name);
    switch (which) {
        .package => try lib.package.open(L),
        .io => try lib.io.open(L),
        .os => try lib.os.open(L),
        .coroutine => try lib.coroutine.open(state),
        .debug => try lib.debug.open(state),
        .math => try lib.math.open(state),
        .string => try lib.string.open(state),
        .table => try lib.table.open(state),
        .utf8 => try lib.utf8.open(state),
        .base => unreachable,
    }
    const t = state.globals.getStr(name);
    try state.globals.setStr(&state.heap, name, old);
    L.push(t);
}

fn Opener(comptime which: lib.Lib) type {
    return struct {
        fn f(L: *lua_State) callconv(.c) c_int {
            check(L, openLib(L, which));
            return 1;
        }
    };
}

/// `luaL_openselectedlibs`: requires the libraries whose `LUA_*LIBK` bit
/// is in `load`, and puts those in `preload` in `package.preload`.
fn lauxOpenselectedlibs(L: *lua_State, load: c_int, preload: c_int) callconv(.c) void {
    _ = lauxlib.lauxGetsubtable(L, capi.registry_index, "_PRELOAD");
    inline for (lib_names, 0..) |name, i| {
        const mask = @as(c_int, 1) << i;
        const f = &Opener(@enumFromInt(i)).f;
        if (load & mask != 0) {
            lauxlib.lauxRequiref(L, name, f, 1);
            capi.luaSettop(L, -2);
        } else if (preload & mask != 0) {
            capi.luaPushcclosure(L, f, 0);
            capi.luaSetfield(L, -2, name);
        }
    }
    capi.luaSettop(L, -2);
}

comptime {
    @export(&luaNewstate, .{ .name = "lua_newstate" });
    @export(&luaClose, .{ .name = "lua_close" });
    @export(&lauxNewstate, .{ .name = "luaL_newstate" });
    @export(&lauxOpenselectedlibs, .{ .name = "luaL_openselectedlibs" });
    for (lib_names, 0..) |name, i| {
        const sym = if (i == 0) "luaopen_base" else "luaopen_" ++ name;
        @export(&Opener(@enumFromInt(i)).f, .{ .name = sym });
    }
}

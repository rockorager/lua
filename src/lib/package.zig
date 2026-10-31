//! The package library (manual §6.3), after reference Lua 5.5.1's loadlib.c
//! built without dynamic libraries: `require`, `package.loaded`,
//! `package.preload`, `package.path` and `package.cpath` (from `LUA_PATH_5_5`,
//! `LUA_PATH`, `LUA_CPATH_5_5`, and `LUA_CPATH`, with `;;` replaced by the
//! default), `package.searchers`, `package.searchpath`, `package.config`, and
//! `package.loadlib`.
//!
//! The default build has no C, so no C library ever loads. The C searchers
//! still search `package.cpath` and report the files they did not find, as
//! the reference's stub build does, and a file they do find fails with its
//! "dynamic libraries not enabled" message; `loadlib` returns that message
//! with "absent". A C-API build (`-Dc-api=true`) loads them with `dlopen`,
//! as the reference's `LUA_USE_DLOPEN` build does (`../capi/loadlib.zig`).

const std = @import("std");
const Value = @import("../Value.zig");
const String = @import("../String.zig");
const Table = @import("../Table.zig");
const State = @import("../State.zig");
const Thread = @import("../Thread.zig");
const Proto = @import("../Proto.zig");
const vm = @import("../vm.zig");
const aux = @import("auxlib.zig");
const base = @import("base.zig");
const os = @import("os.zig");
const lib = @import("init.zig");
const lua_options = @import("lua_options");
const dynlib = @import("../capi/loadlib.zig");

const Error = Value.Error;
const Args = aux.Args;

/// `LUA_PATH_DEFAULT` for `LUA_ROOT` "/usr/local/".
pub const path_default = "/usr/local/share/lua/5.5/?.lua;/usr/local/share/lua/5.5/?/init.lua;" ++
    "/usr/local/lib/lua/5.5/?.lua;/usr/local/lib/lua/5.5/?/init.lua;./?.lua;./?/init.lua";
/// `LUA_CPATH_DEFAULT` for `LUA_ROOT` "/usr/local/".
pub const cpath_default = "/usr/local/lib/lua/5.5/?.so;/usr/local/lib/lua/5.5/loadall.so;./?.so";

/// The directory separator, path separator, substitution mark, executable
/// directory mark, and the mark that cuts a module name's prefix.
const config = "/\n;\n?\n!\n-\n";
const dirsep = "/";
const dl_msg = "dynamic libraries not enabled; check your Lua installation";

/// The registry's `LUA_LOADED_TABLE`, `package.loaded`.
pub const loaded_key = "_LOADED";
/// The registry's `LUA_PRELOAD_TABLE`, `package.preload`.
pub const preload_key = "_PRELOAD";

/// `luaL_getsubtable(L, LUA_REGISTRYINDEX, name)`: the registry's table
/// under `name`, created when absent.
pub fn registryTable(state: *State, name: []const u8) error{OutOfMemory}!*Table {
    const key = try state.newString(name);
    const v = state.registry.getStr(key);
    if (v.tag == .table) return v.asTable();
    const t = try state.newTable(0, 0);
    try state.registry.setStr(&state.heap, key, .table(t));
    return t;
}

/// The bytes of `s` up to its first zero, as C sees a string.
fn cstr(s: []const u8) []const u8 {
    return s[0 .. std.mem.findScalar(u8, s, 0) orelse s.len];
}

/// The package table, upvalue 1 of `require` and of the searchers.
fn packageTable(th: *Thread, b: u32) Value {
    return th.stack[b - 1].asNativeClosure().upvalues()[0];
}

/// A native closure over the package table.
fn closure(state: *State, f: Value.NativeFn, pkg: *Table) error{OutOfMemory}!Value {
    const c = try Proto.NativeClosure.create(&state.heap, f, 1);
    c.setUpvalue(&state.heap, 0, .table(pkg));
    return .nativeClosure(c);
}

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

/// `noenv`: `base.Host.noenv`, which `lua -E` sets.
fn noEnv(state: *State) bool {
    const host = base.hostOf(state) orelse return false;
    return host.noenv;
}

/// `setpath`: `package[field]` from the environment variable `envname`
/// (its `_5_5` version first), with a `;;` replaced by the default, or the
/// default alone.
fn setPath(state: *State, pkg: *Table, field: []const u8, comptime envname: []const u8, dft: []const u8) Error!void {
    const path = os.getenv(state, envname ++ "_5_5") orelse os.getenv(state, envname);
    const value: *String = blk: {
        const p = path orelse break :blk try state.newString(dft);
        if (noEnv(state)) break :blk try state.newString(dft);
        const mark = std.mem.find(u8, p, ";;") orelse break :blk try state.newString(p);
        var b: aux.Buffer = .init(state);
        defer b.deinit();
        const w = &b.writer;
        if (mark > 0) {
            w.writeAll(p[0..mark]) catch return error.OutOfMemory;
            w.writeByte(';') catch return error.OutOfMemory;
        }
        w.writeAll(dft) catch return error.OutOfMemory;
        if (mark + 2 < p.len) {
            w.writeByte(';') catch return error.OutOfMemory;
            w.writeAll(p[mark + 2 ..]) catch return error.OutOfMemory;
        }
        break :blk try b.toString(state);
    };
    try aux.setField(state, pkg, field, .string(value));
}

/// `readable`: whether `fopen(name, "r")` would succeed.
fn readable(th: *Thread, name: []const u8) bool {
    if (name.len == 0) return false;
    const io = base.getHost(th).io;
    const f = std.Io.Dir.cwd().openFile(io, name, .{}) catch return false;
    f.close(io);
    return true;
}

/// Writes `s` with every `pat` replaced by `rep`, `luaL_addgsub`.
fn writeGsub(w: *std.Io.Writer, s: []const u8, pat: []const u8, rep: []const u8) error{OutOfMemory}!void {
    var rest = s;
    while (std.mem.find(u8, rest, pat)) |i| {
        w.writeAll(rest[0..i]) catch return error.OutOfMemory;
        w.writeAll(rep) catch return error.OutOfMemory;
        rest = rest[i + pat.len ..];
    }
    w.writeAll(rest) catch return error.OutOfMemory;
}

/// `searchpath`: the first readable file among `path`'s templates with
/// `name` in place of each '?', after replacing `sep` in `name` with `rep`.
/// The file name, or the "no file" lines for every template tried.
const Search = union(enum) { found: *String, not_found: *String };

fn searchPath(
    th: *Thread,
    name_in: []const u8,
    path_in: []const u8,
    sep_in: []const u8,
    rep_in: []const u8,
) Error!Search {
    const state = th.state;
    const sep = cstr(sep_in);
    const rep = cstr(rep_in);
    const path = cstr(path_in);
    var name = cstr(name_in);
    var nb: aux.Buffer = .init(state);
    defer nb.deinit();
    if (sep.len > 0 and std.mem.findScalar(u8, name, sep[0]) != null) {
        try writeGsub(&nb.writer, name, sep, rep);
        name = nb.written();
    }
    var pb: aux.Buffer = .init(state);
    defer pb.deinit();
    try writeGsub(&pb.writer, path, "?", name);
    const names = pb.written();
    var it = std.mem.splitScalar(u8, names, ';');
    while (it.next()) |file| {
        if (readable(th, file)) return .{ .found = try state.newString(file) };
    }
    var eb: aux.Buffer = .init(state);
    defer eb.deinit();
    eb.writer.writeAll("no file '") catch return error.OutOfMemory;
    try writeGsub(&eb.writer, names, ";", "'\n\tno file '");
    eb.writer.writeAll("'") catch return error.OutOfMemory;
    return .{ .not_found = try eb.toString(state) };
}

fn searchpath(th: *Thread, b: u32) Error!u32 {
    const a = Args.init(th, b, "searchpath");
    const name = (try a.checkString(1)).bytes();
    const path = (try a.checkString(2)).bytes();
    const sep = try a.optString(3, ".");
    const rep = try a.optString(4, dirsep);
    switch (try searchPath(th, name, path, sep, rep)) {
        .found => |f| th.push(.string(f)),
        .not_found => |msg| {
            th.push(.nil);
            th.push(.string(msg));
            return 2;
        },
    }
    return 1;
}

/// `findfile`: searches `package[pname]` for `name`.
fn findFile(th: *Thread, b: u32, name: []const u8, comptime pname: []const u8) Error!Search {
    const path = try aux.index(th, packageTable(th, b), .string(try th.state.newString(pname)));
    const p: []const u8 = if (path.isString())
        path.asString().bytes()
    else if (path.isNumber())
        (try aux.numberToString(th.state, path)).bytes()
    else
        return aux.raise(th, "'package.{s}' must be a string", .{pname});
    return searchPath(th, name, p, ".", dirsep);
}

// ---------------------------------------------------------------------------
// Searchers
// ---------------------------------------------------------------------------

fn searcherPreload(th: *Thread, b: u32) Error!u32 {
    const a = Args.init(th, b, "searcher");
    const name = try a.checkString(1);
    const preload = try registryTable(th.state, preload_key);
    const v = try aux.index(th, .table(preload), .string(name));
    if (v.isNil()) {
        var buf: aux.Buffer = .init(th.state);
        defer buf.deinit();
        buf.writer.print("no field package.preload['{s}']", .{cstr(name.bytes())}) catch return error.OutOfMemory;
        th.push(.string(try buf.toString(th.state)));
        return 1;
    }
    th.push(v);
    th.push(.string(try th.state.newString(":preload:")));
    return 2;
}

/// `checkload`: the loader and its file name, or "error loading module".
fn checkLoad(th: *Thread, b: u32, loaded: ?Value, filename: *String, msg: []const u8) Error!u32 {
    if (loaded) |f| {
        th.push(f);
        th.push(.string(filename));
        return 2;
    }
    const name = th.stack[b].asString().bytes();
    const fmt = "error loading module '{s}' from file '{s}':\n\t{s}";
    return aux.raise(th, fmt, .{ cstr(name), cstr(filename.bytes()), msg });
}

fn searcherLua(th: *Thread, b: u32) Error!u32 {
    const a = Args.init(th, b, "searcher");
    const name = try a.checkString(1);
    const filename = switch (try findFile(th, b, name.bytes(), "path")) {
        .found => |f| f,
        .not_found => |msg| {
            th.push(.string(msg));
            return 1;
        },
    };
    th.push(.string(filename));
    const f = base.loadFile(th, filename.bytes(), "bt") catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.LuaError => {
            const err = th.err;
            th.err = .nil;
            th.push(err);
            const text: []const u8 = if (err.isString()) err.asString().bytes() else if (err.isNumber())
                (try aux.numberToString(th.state, err)).bytes()
            else
                "(null)";
            return checkLoad(th, b, null, filename, text);
        },
    };
    th.top -= 1;
    return checkLoad(th, b, f, filename, "");
}

fn searcherC(th: *Thread, b: u32) Error!u32 {
    const a = Args.init(th, b, "searcher");
    const name = try a.checkString(1);
    const filename = switch (try findFile(th, b, name.bytes(), "cpath")) {
        .found => |f| f,
        .not_found => |msg| {
            th.push(.string(msg));
            return 1;
        },
    };
    if (comptime !lua_options.c_api) return checkLoad(th, b, null, filename, dl_msg);
    return switch (try dynlib.loadFunc(th, filename, name.bytes())) {
        .ok => |f| checkLoad(th, b, f, filename, ""),
        .open, .init => |msg| checkLoad(th, b, null, filename, msg),
    };
}

fn searcherCroot(th: *Thread, b: u32) Error!u32 {
    const a = Args.init(th, b, "searcher");
    const name = cstr((try a.checkString(1)).bytes());
    const dot = std.mem.findScalar(u8, name, '.') orelse return 0;
    const filename = switch (try findFile(th, b, name[0..dot], "cpath")) {
        .found => |f| f,
        .not_found => |msg| {
            th.push(.string(msg));
            return 1;
        },
    };
    if (comptime !lua_options.c_api) return checkLoad(th, b, null, filename, dl_msg);
    switch (try dynlib.loadFunc(th, filename, name)) {
        .ok => |f| {
            th.push(f);
            th.push(.string(filename));
            return 2;
        },
        .open => |msg| return checkLoad(th, b, null, filename, msg),
        .init => {
            var buf: aux.Buffer = .init(th.state);
            defer buf.deinit();
            const args = .{ name, cstr(filename.bytes()) };
            buf.writer.print("no module '{s}' in file '{s}'", args) catch return error.OutOfMemory;
            th.push(.string(try buf.toString(th.state)));
            return 1;
        },
    }
}

// ---------------------------------------------------------------------------
// require
// ---------------------------------------------------------------------------

/// `findloader`: calls each searcher with the name until one returns a
/// function; leaves the loader and its data on top. Raises "module 'name'
/// not found:" with every searcher's message.
fn findLoader(th: *Thread, b: u32, name: *String) Error!void {
    const state = th.state;
    const searchers = try aux.index(th, packageTable(th, b), .string(try state.newString("searchers")));
    if (searchers.tag != .table) return aux.raise(th, "'package.searchers' must be a table", .{});
    try th.ensureStack(3);
    th.push(searchers);
    const searchers_slot = th.top - 1;
    var msg: aux.Buffer = .init(state);
    defer msg.deinit();
    const w = &msg.writer;
    w.writeAll("\n\t") catch return error.OutOfMemory;
    var i: i64 = 1;
    while (true) : (i += 1) {
        const s = th.stack[searchers_slot].asTable().getInt(i);
        if (s.isNil()) {
            msg.writer.end -= 2;
            return aux.raise(th, "module '{s}' not found:{s}", .{ cstr(name.bytes()), msg.written() });
        }
        const func = th.top;
        th.push(s);
        th.push(.string(name));
        try vm.call(th, func, 2);
        const r = th.stack[func];
        if (r.isFunction()) return;
        if (r.isString() or r.isNumber()) {
            const text = if (r.isString()) r.asString().bytes() else (try aux.numberToString(state, r)).bytes();
            w.writeAll(text) catch return error.OutOfMemory;
            w.writeAll("\n\t") catch return error.OutOfMemory;
        }
        th.top = func;
    }
}

fn require(th: *Thread, b: u32) Error!u32 {
    const a = Args.init(th, b, "require");
    const name = try a.checkString(1);
    const state = th.state;
    th.top = b + 1;
    const loaded = try registryTable(state, loaded_key);
    try th.ensureStack(4);
    th.push(.table(loaded)); // b + 1
    const v = try aux.index(th, .table(loaded), .string(name));
    if (!v.isFalsy()) {
        th.push(v);
        return 1;
    }
    try findLoader(th, b, name);
    // loader at top - 2, its data at top - 1; call loader(name, data).
    const func = th.top - 2;
    const data = th.stack[func + 1];
    th.push(.string(name));
    th.push(data);
    // Keep the data below the call: [loader, data] becomes [data, loader, name, data].
    th.stack[func + 1] = th.stack[func];
    th.stack[func] = data;
    try vm.call(th, func + 1, 1);
    const res = th.stack[func + 1];
    const loaded_v = th.stack[b + 1];
    if (!res.isNil()) try aux.setIndex(th, loaded_v, .string(name), res);
    var result = try aux.index(th, loaded_v, .string(name));
    if (result.isNil()) {
        result = .true;
        try aux.setIndex(th, loaded_v, .string(name), .true);
    }
    th.stack[func + 1] = data;
    th.stack[func] = result;
    th.top = func + 2;
    return 2;
}

fn loadlib(th: *Thread, b: u32) Error!u32 {
    const a = Args.init(th, b, "loadlib");
    const path = try a.checkString(1);
    const init = try a.checkString(2);
    if (comptime lua_options.c_api) {
        const msg, const when = switch (try dynlib.lookForFunc(th, path.bytes(), init.bytes())) {
            .ok => |f| {
                th.push(f);
                return 1;
            },
            .open => |msg| .{ msg, "open" },
            .init => |msg| .{ msg, "init" },
        };
        th.push(.nil);
        th.push(.string(try th.state.newString(msg)));
        th.push(.string(try th.state.newString(when)));
        return 3;
    }
    th.push(.nil);
    th.push(.string(try th.state.newString(dl_msg)));
    th.push(.string(try th.state.newString("absent")));
    return 3;
}

/// Opens the library: the `package` table and the global `require`.
pub fn open(th: *Thread) Error!void {
    const state = th.state;
    _ = try registryTable(state, "_CLIBS");
    const pkg = try aux.newLib(state, .{
        .{ "loadlib", &loadlib },
        .{ "searchpath", &searchpath },
    });
    const searchers = try state.newTable(4, 0);
    inline for (.{ &searcherPreload, &searcherLua, &searcherC, &searcherCroot }, 1..) |f, i| {
        try searchers.setInt(&state.heap, i, try closure(state, f, pkg));
    }
    try aux.setField(state, pkg, "searchers", .table(searchers));
    try setPath(state, pkg, "path", "LUA_PATH", path_default);
    try setPath(state, pkg, "cpath", "LUA_CPATH", cpath_default);
    try aux.setField(state, pkg, "config", .string(try state.newString(config)));
    try aux.setField(state, pkg, "loaded", .table(try registryTable(state, loaded_key)));
    try aux.setField(state, pkg, "preload", .table(try registryTable(state, preload_key)));
    try aux.setField(state, state.globals, "require", try closure(state, &require, pkg));
    try aux.setField(state, state.globals, "package", .table(pkg));
}

pub const testing = struct {
    /// Runs `src` with every library open and `env` as the environment, and
    /// expects it to return true.
    pub fn expectChunk(env: []const [2][]const u8, src: [:0]const u8) !void {
        const t = std.testing;
        const state = try State.create(t.allocator, .{});
        defer state.destroy();
        var host: base.Host = undefined;
        host.init(t.io);
        var map = std.process.Environ.Map.init(t.allocator);
        defer map.deinit();
        for (env) |kv| try map.put(kv[0], kv[1]);
        const th = state.main;
        host.environ = &map;
        try lib.openLibs(th, &host);
        const func = th.top;
        th.push(try base.loadChunk(th, src, "=test", "t"));
        if (vm.pcall(th, func, 1) != .ok) {
            const e = th.stack[func];
            std.debug.print("error: {s}\n", .{if (e.isString()) e.asString().bytes() else "?"});
            return error.TestUnexpectedResult;
        }
        try t.expect(th.stack[func].tag == .bool_true);
    }
};

test "require, the searchers, and the paths from the environment" {
    // Expected values from the reference, run with this environment.
    try testing.expectChunk(&.{ .{ "LUA_PATH", "a;;b" }, .{ "LUA_CPATH_5_5", "c" }, .{ "LUA_CPATH", "ignored" } },
        \\-- LUA_PATH=a;;b LUA_CPATH_5_5=c LUA_CPATH=ignored
        \\local default = "/usr/local/share/lua/5.5/?.lua;/usr/local/share/lua/5.5/?/init.lua;" ..
        \\  "/usr/local/lib/lua/5.5/?.lua;/usr/local/lib/lua/5.5/?/init.lua;./?.lua;./?/init.lua"
        \\assert(package.path == "a;" .. default .. ";b")
        \\assert(package.cpath == "c")
        \\assert(package.config == "/\n;\n?\n!\n-\n")
        \\for _, n in ipairs{"_G", "package", "io", "os", "string", "table", "math", "utf8"} do
        \\  assert(package.loaded[n] == _G[n] and require(n) == _G[n])
        \\end
        \\local name = os.tmpname()
        \\local f = io.open(name .. ".lua", "w") f:write("local n, p = ... return {name = n, path = p}") f:close()
        \\package.path = "/nonexistent/?.lua;" .. name:gsub("[^/]*$", "?.lua")
        \\local mod = name:match("[^/]*$")
        \\local m, p = require(mod)
        \\assert(m.name == mod and m.path == name .. ".lua" and p == name .. ".lua")
        \\assert(require(mod) == m and package.loaded[mod] == m)
        \\assert(package.searchpath(mod, package.path) == name .. ".lua")
        \\local s, err = package.searchpath("a.b", "x/?.lua;;?")
        \\assert(s == nil and err == "no file 'x/a/b.lua'\n\tno file ''\n\tno file 'a/b'")
        \\assert(package.searchpath("a_b", "./?.x", "_", "/") == nil)
        \\os.remove(name .. ".lua")
        \\-- preload, and the loader's second argument
        \\package.preload.pl = function(...) return {...} end
        \\local pl, ext = require"pl"
        \\assert(pl[1] == "pl" and pl[2] == ":preload:" and ext == ":preload:")
        \\package.preload.none = function() end
        \\assert(require"none" == true and package.loaded.none == true)
        \\package.preload.self = function(n) package.loaded[n] = 25 end
        \\assert(require"self" == 25)
        \\-- the message lists every searcher's attempts
        \\package.path = "?.lua;?/?"
        \\package.cpath = "?.so;?/init"
        \\local st, msg = pcall(require, "XXX")
        \\assert(msg == "module 'XXX' not found:\n\tno field package.preload['XXX']\n\tno file 'XXX.lua'" ..
        \\  "\n\tno file 'XXX/XXX'\n\tno file 'XXX.so'\n\tno file 'XXX/init'")
        \\package.path = {}
        \\assert(select(2, pcall(require, "no-such")):find("'package.path' must be a string", 1, true))
        \\local searchers = package.searchers
        \\package.searchers = 3
        \\assert(select(2, pcall(require, "a")):find("'package.searchers' must be a table", 1, true))
        \\package.searchers = searchers
        \\local fn, lmsg, when = package.loadlib("x.so", "f")
        \\assert(fn == nil and type(lmsg) == "string" and when ~= nil)
        \\return true
    );
}

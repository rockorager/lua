//! An example host: a Zig program that uses Lua for its configuration and
//! for plugins, through the embedding API. The script (`init.lua` unless a
//! path is given) sets `config`, which the host reads into a Zig struct,
//! and registers key handlers through the `host` module of Zig functions.
//! The host then sends key presses to the handlers, and a handler that
//! fails is reported without stopping the others.
//!
//! zig build example -- [script.lua]

const std = @import("std");
const lua = @import("lua");

/// What the script configures; fields it leaves out keep their defaults.
pub const Config = struct {
    font_size: f64 = 12,
    theme: enum { light, dark } = .dark,
    keybinds: []const Keybind = &.{},

    pub const Keybind = struct { key: []const u8, action: []const u8 };
};

/// The host's own state, which its Zig functions reach through
/// `State.context`.
pub const Host = struct {
    gpa: std.mem.Allocator,
    out: *std.Io.Writer,
    /// The key handlers the script registered, held across collections.
    handlers: std.ArrayList(lua.Ref) = .empty,

    fn of(state: *lua.State) *Host {
        return state.context(Host);
    }
};

/// A window, which Lua sees as a userdata with methods.
const Window = struct {
    width: u32,
    height: u32,

    pub const lua_userdata = .{
        .name = "Window",
        .methods = .{ .size = size, .resize = resize },
        .meta = .{ .__tostring = toString },
    };

    fn size(w: *const Window) struct { u32, u32 } {
        return .{ w.width, w.height };
    }

    fn resize(state: *lua.State, w: *Window, width: u32, height: u32) !void {
        if (width == 0 or height == 0) return state.raise("window size must be positive", .{});
        w.width = width;
        w.height = height;
    }

    fn toString(w: *const Window) []const u8 {
        return if (w.width > w.height) "Window(wide)" else "Window(tall)";
    }
};

fn newWindow(state: *lua.State, width: u32, height: u32) !*Window {
    return state.newUserdata(Window, .{ .width = width, .height = height });
}

fn log(state: *lua.State, msg: []const u8) !void {
    try Host.of(state).out.print("[lua] {s}\n", .{msg});
}

fn onKey(state: *lua.State, handler: lua.Function) !void {
    const host = Host.of(state);
    try host.handlers.append(host.gpa, try state.ref(handler));
}

/// A state with the script run and the host's functions in `host`.
pub fn start(host: *Host, io: ?std.Io, source: []const u8, name: []const u8) !*lua.State {
    const state = try lua.State.init(host.gpa, .{ .io = io, .libs = lua.safe_libs, .context = host });
    errdefer state.close();
    try state.setGlobal("host", .{ .log = log, .on_key = onKey, .window = newWindow });
    state.doString(void, source, .{ .name = name }) catch |e| return report(state, e);
    return state;
}

/// The script's `config`, with its strings and lists copied into `arena`.
pub fn readConfig(state: *lua.State, arena: std.mem.Allocator) !Config {
    const v = state.getGlobal(lua.Value, "config") catch |e| return report(state, e);
    if (v.isNil()) return .{};
    return state.decodeAlloc(Config, arena, v, .{ .unknown_keys = .reject }) catch |e| report(state, e);
}

/// Sends a key press to every handler and returns the first answer. A
/// handler that fails is reported, and the others still run.
pub fn press(state: *lua.State, key: []const u8) !?[]const u8 {
    const host = Host.of(state);
    var answer: ?[]const u8 = null;
    for (host.handlers.items) |handler| {
        const r = state.call(?[]const u8, handler, .{key}) catch |e| switch (e) {
            error.Runtime => {
                try host.out.print("handler failed: {s}\n", .{state.errorMessage()});
                continue;
            },
            else => return e,
        };
        if (answer == null) answer = r;
    }
    return answer;
}

pub fn stop(state: *lua.State) void {
    const host = Host.of(state);
    for (host.handlers.items) |r| state.unref(r);
    host.handlers.deinit(host.gpa);
    state.close();
}

fn report(state: *lua.State, e: lua.Error) lua.Error {
    if (e != error.OutOfMemory) {
        const out = Host.of(state).out;
        out.print("lua: {s}\n", .{state.errorTraceback() orelse state.errorMessage()}) catch return e;
    }
    return e;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const path: ?[]const u8 = if (args.len > 1) args[1] else null;
    const source = if (path) |p|
        try std.Io.Dir.cwd().readFileAlloc(io, p, init.arena.allocator(), .limited(1 << 20))
    else
        @embedFile("init.lua");

    var host: Host = .{ .gpa = gpa, .out = &stdout.interface };
    const state = start(&host, io, source, if (path != null) "@script" else "@init.lua") catch
        return stdout.interface.flush();
    defer stop(state);
    const config = readConfig(state, init.arena.allocator()) catch return stdout.interface.flush();
    try stdout.interface.print("font_size={d} theme={t} keybinds={d}\n", .{
        config.font_size,
        config.theme,
        config.keybinds.len,
    });
    for ([_][]const u8{ "ctrl+plus", "boom", "x" }) |key| {
        const answer = try press(state, key);
        try stdout.interface.print("{s} -> {s}\n", .{ key, answer orelse "(none)" });
    }
    try stdout.interface.flush();
}

const testing = std.testing;

/// Runs `source` as the script, with the host's output in `out`.
fn testHost(out: *std.Io.Writer.Allocating, source: []const u8) !*lua.State {
    const host = try testing.allocator.create(Host);
    host.* = .{ .gpa = testing.allocator, .out = &out.writer };
    errdefer testing.allocator.destroy(host);
    return start(host, null, source, "=init.lua");
}

fn stopTest(state: *lua.State) void {
    const host = Host.of(state);
    stop(state);
    testing.allocator.destroy(host);
}

test "the example script configures the host" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const state = try testHost(&out, @embedFile("init.lua"));
    defer stopTest(state);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const config = try readConfig(state, arena.allocator());
    try testing.expectEqual(14, config.font_size);
    try testing.expectEqual(.light, config.theme);
    try testing.expectEqual(2, config.keybinds.len);
    try testing.expectEqualStrings("ctrl+w", config.keybinds[1].key);
    try testing.expectEqualStrings("close_tab", config.keybinds[1].action);
    try testing.expectEqualStrings("[lua] opened Window(wide)\n", out.written());
}

test "key presses reach the plugin's handlers, and a failing one is reported" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const state = try testHost(&out, @embedFile("init.lua"));
    defer stopTest(state);
    out.clearRetainingCapacity();
    try testing.expectEqualStrings("resized to 90x24", (try press(state, "ctrl+plus")).?);
    try testing.expectEqualStrings("resized to 100x24", (try press(state, "ctrl+plus")).?);
    try testing.expectEqual(null, try press(state, "boom"));
    try testing.expectEqualStrings("handler failed: init.lua:26: plugin failed on boom\n", out.written());
    out.clearRetainingCapacity();
    try testing.expectEqual(null, try press(state, "shrink"));
    try testing.expectEqualStrings("handler failed: init.lua:21: window size must be positive\n", out.written());
}

test "a misspelled key in the config is reported by its path" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const state = try testHost(&out,
        \\config = { keybinds = { { key = "a", action = "x" }, { key = "b", acton = "y" } } }
    );
    defer stopTest(state);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.Runtime, readConfig(state, arena.allocator()));
    try testing.expectEqualStrings("lua: unknown key 'keybinds[2].acton'\n", out.written());
}

test "a script that does not run is reported with its traceback" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try testing.expectError(error.Syntax, testHost(&out, "config = {"));
    try testing.expectEqualStrings("lua: init.lua:1: unexpected symbol near <eof>\n", out.written());
    out.clearRetainingCapacity();
    try testing.expectError(error.Runtime, testHost(&out, "host.window(0)"));
    try testing.expectEqualStrings("lua: init.lua:1: bad argument #2 to 'window' (number expected, got no value)\n" ++
        "stack traceback:\n\t[C]: in field 'window'\n\tinit.lua:1: in main chunk\n", out.written());
}

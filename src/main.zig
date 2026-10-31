//! The standalone interpreter, `lua`, as reference Lua 5.5.1's lua.c
//! behaves: a script with its `arg` table, `-e`, `-l`, `-i`, `-v`, `-E`,
//! `-W`, `--`, `-` for stdin, `LUA_INIT`, and an interactive loop when
//! stdin is a terminal. Everything runs inside a Zig function called in
//! protected mode, as lua.c's `pmain`, so a traceback ends in its
//! "[C]: in ?". Errors print as "lua: message" and a traceback on stderr,
//! and the exit status is 1.
//!
//! It is written against the embedding API alone, as a test of it.

const std = @import("std");
const builtin = @import("builtin");
const lua = @import("lua");
const build_options = @import("build_options");

const copyright = "Lua 5.5.1  Copyright (C) 1994-2026 Lua.org, PUC-Rio";

/// The most slots a Lua stack holds, the engine's `LUAI_MAXSTACK`: past
/// it, lua.c's `luaL_checkstack` refuses the script's arguments.
const max_stack = 1_000_000;

const Interp = struct {
    io: std.Io,
    environ: *const std.process.Environ.Map,
    args: []const [:0]const u8,
    /// Null in interactive mode, where messages have no program name.
    progname: ?[]const u8,
    flags: u8 = 0,
    /// The index of the script in `args`, or 0 for none.
    script: usize = 0,
    stdin: ?std.Io.File.Reader = null,
    stdin_buf: [512]u8 = undefined,

    fn writeStderr(it: *Interp, bytes: []const u8) void {
        std.Io.File.stderr().writeStreamingAll(it.io, bytes) catch return;
    }

    fn message(it: *Interp, msg: []const u8) void {
        if (it.progname) |p| {
            it.writeStderr(p);
            it.writeStderr(": ");
        }
        it.writeStderr(msg);
        it.writeStderr("\n");
    }

    /// Prints a failure as `report` does: the message handler's text for
    /// a chunk that ran, or the error message.
    fn report(it: *Interp, state: *lua.State, e: lua.Error) void {
        it.message(switch (e) {
            error.OutOfMemory => "not enough memory",
            error.Runtime => state.errorTraceback() orelse state.errorMessage(),
            error.Syntax => state.errorMessage(),
        });
    }

    /// Runs `f` with no arguments in protected mode, with the traceback
    /// handler, and reports a failure.
    fn docall(it: *Interp, state: *lua.State, f: lua.Function) bool {
        state.pcall(void, f, .{}) catch |e| {
            it.report(state, e);
            return false;
        };
        return true;
    }

    fn dofile(it: *Interp, state: *lua.State, name: ?[]const u8) bool {
        const f = state.loadFile(name, .any) catch |e| {
            it.report(state, e);
            return false;
        };
        return it.docall(state, f);
    }

    fn dostring(it: *Interp, state: *lua.State, s: []const u8, name: []const u8) bool {
        const f = state.load(s, .{ .name = name }) catch |e| {
            it.report(state, e);
            return false;
        };
        return it.docall(state, f);
    }

    /// `globname = require(modname)` for `-l globname[=modname]`; without
    /// `=`, a suffix after '-' is cut from the global name.
    fn dolibrary(it: *Interp, state: *lua.State, spec: []const u8) lua.Error!bool {
        var globname = spec;
        var modname = spec;
        if (std.mem.findScalar(u8, spec, '=')) |eq| {
            globname = spec[0..eq];
            modname = spec[eq + 1 ..];
        } else if (std.mem.findScalar(u8, spec, '-')) |dash| {
            globname = spec[0..dash];
        }
        const require = try state.getGlobal(lua.Value, "require");
        const v = state.pcall(lua.Value, require, .{modname}) catch |e| {
            it.report(state, e);
            return false;
        };
        try state.setGlobal(globname, v);
        return true;
    }

    fn handleScript(it: *Interp, state: *lua.State) lua.Error!bool {
        const args = it.args;
        var fname: ?[]const u8 = args[it.script];
        if (std.mem.eql(u8, args[it.script], "-") and !std.mem.eql(u8, args[it.script - 1], "--")) fname = null;
        const f = state.loadFile(fname, .any) catch |e| {
            it.report(state, e);
            return false;
        };
        // Reading `arg` may run a metamethod.
        const chunk = try state.ref(f);
        defer state.unref(chunk);
        // The script's arguments: arg[1] .. arg[#arg]. These failures are
        // raised, as lua.c's `pushargs` raises them.
        const argv = try state.getGlobal(lua.Value, "arg");
        if (argv.typeOf() != .table) return state.raise("'arg' is not a table", .{});
        const t = try state.decode(lua.Table, argv, .{});
        // `#arg` with `__len`, truncated to a C int as lua.c's is; a
        // negative count passes nothing.
        const n: i32 = @truncate(try state.len(t));
        if (n > max_stack - 3) return state.raise("stack overflow (too many arguments to script)", .{});
        const gpa = std.heap.smp_allocator;
        const vals = gpa.alloc(lua.Value, @intCast(@max(n, 0))) catch return error.OutOfMemory;
        defer gpa.free(vals);
        for (vals, 1..) |*v, i| v.* = try t.rawGet(state, lua.Value, i);
        state.pcall(void, chunk, @as(lua.Values, vals)) catch |e| {
            it.report(state, e);
            return false;
        };
        return true;
    }

    fn getenv(it: *Interp, name: []const u8) ?[]const u8 {
        if (it.flags & Flags.has_upper_e != 0) return null;
        return it.environ.get(name);
    }

    fn handleLuaInit(it: *Interp, state: *lua.State) bool {
        var name: []const u8 = "=LUA_INIT_5_5";
        const init = it.getenv(name[1..]) orelse blk: {
            name = "=LUA_INIT";
            break :blk it.getenv(name[1..]) orelse return true;
        };
        if (init.len > 0 and init[0] == '@') return it.dofile(state, init[1..]);
        return it.dostring(state, init, name);
    }

    // The interactive loop.

    /// Writes the prompt (`_PROMPT` or `_PROMPT2` through `tostring`, or
    /// the default), then reads a line as `fgets` would into lua.c's
    /// 512-byte buffer, without its newline. Null at the end of input.
    fn readLine(it: *Interp, state: *lua.State, firstline: bool, line: *std.ArrayList(u8)) lua.Error!?void {
        const pv = try state.getGlobal(lua.Value, if (firstline) "_PROMPT" else "_PROMPT2");
        writeOut(state, if (pv.isNil()) (if (firstline) "> " else ">> ") else try state.toString(pv));
        if (it.stdin == null) it.stdin = std.Io.File.stdin().readerStreaming(it.io, &it.stdin_buf);
        const r = &it.stdin.?.interface;
        line.clearRetainingCapacity();
        const gpa = std.heap.smp_allocator;
        while (line.items.len < 511) {
            const c = r.takeByte() catch break;
            line.append(gpa, c) catch return error.OutOfMemory;
            if (c == '\n') break;
        }
        if (line.items.len == 0) return null;
        if (line.items[line.items.len - 1] == '\n') line.items.len -= 1;
    }

    /// Whether a failed load is a syntax error for an incomplete
    /// statement, ending in "<eof>".
    fn incomplete(state: *lua.State, e: lua.Error) bool {
        return e == error.Syntax and std.mem.endsWith(u8, state.errorMessage(), "<eof>");
    }

    const Loaded = union(enum) { ok: lua.Function, err: lua.Error };

    /// Reads and compiles one statement: first as "return line;", then as
    /// a statement, reading more lines while it is incomplete. Null at the
    /// end of input.
    fn loadLine(it: *Interp, state: *lua.State, line: *std.ArrayList(u8)) lua.Error!?Loaded {
        const gpa = std.heap.smp_allocator;
        try it.readLine(state, true, line) orelse return null;
        var ret: std.ArrayList(u8) = .empty;
        defer ret.deinit(gpa);
        ret.print(gpa, "return {s};", .{line.items}) catch return error.OutOfMemory;
        if (state.load(ret.items, .{ .name = "=stdin" })) |f| return .{ .ok = f } else |_| {}
        const trimmed = std.mem.trimStart(u8, line.items, " \t");
        if (std.mem.startsWith(u8, trimmed, "local") and trimmed.len > 5 and (trimmed[5] == ' ' or trimmed[5] == '\t'))
            it.writeStderr("warning: locals do not survive across lines in interactive mode\n");
        var more: std.ArrayList(u8) = .empty;
        defer more.deinit(gpa);
        while (true) {
            const e = if (state.load(line.items, .{ .name = "=stdin" })) |f| return .{ .ok = f } else |e| e;
            if (!incomplete(state, e)) return .{ .err = e };
            try it.readLine(state, false, &more) orelse return .{ .err = e };
            line.append(gpa, '\n') catch return error.OutOfMemory;
            line.appendSlice(gpa, more.items) catch return error.OutOfMemory;
        }
    }

    fn doRepl(it: *Interp, state: *lua.State) lua.Error!void {
        const old = it.progname;
        it.progname = null;
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(std.heap.smp_allocator);
        while (try it.loadLine(state, &line)) |loaded| {
            const f = switch (loaded) {
                .ok => |f| f,
                .err => |e| {
                    it.report(state, e);
                    continue;
                },
            };
            const results = state.pcall(lua.Values, f, .{}) catch |e| {
                it.report(state, e);
                continue;
            };
            try it.printResults(state, results);
        }
        writeOut(state, "\n");
        it.progname = old;
    }

    /// Prints a line's results with the global `print`, `l_print`.
    fn printResults(it: *Interp, state: *lua.State, results: lua.Values) lua.Error!void {
        if (results.len == 0) return;
        const print = try state.getGlobal(lua.Value, "print");
        state.pcall(void, print, results) catch |e| {
            if (e == error.OutOfMemory) return e;
            // lua.c formats `lua_tostring`'s NULL for an error object
            // that is not a string or number.
            var msg: [512]u8 = undefined;
            const t = state.errorValue().typeOf();
            const text = if (t == .string or t == .number) state.errorMessage() else "(null)";
            const shown = text[0..@min(text.len, 400)];
            it.message(std.fmt.bufPrint(&msg, "error calling 'print' ({s})", .{shown}) catch text);
        };
    }
};

const Flags = struct {
    const has_error = 1;
    const has_i = 2;
    const has_v = 4;
    const has_e = 8;
    const has_upper_e = 16;
};

/// Scans the options before running anything, as `collectargs`. Returns
/// the flags, and in `first` the index of the script (0 for none) or of
/// the bad option.
fn collectArgs(args: []const [:0]const u8, first: *usize) u8 {
    var flags: u8 = 0;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        first.* = i;
        const a = args[i];
        if (a[0] != '-') return flags;
        switch (if (a.len > 1) a[1] else 0) {
            '-' => {
                if (a.len > 2) return Flags.has_error;
                first.* = if (i + 1 < args.len) i + 1 else 0;
                return flags;
            },
            0 => return flags,
            'E' => {
                if (a.len > 2) return Flags.has_error;
                flags |= Flags.has_upper_e;
            },
            'W' => if (a.len > 2) return Flags.has_error,
            'i', 'v' => {
                if (a[1] == 'i') flags |= Flags.has_i;
                if (a.len > 2) return Flags.has_error;
                flags |= Flags.has_v;
            },
            'e', 'l' => {
                if (a[1] == 'e') flags |= Flags.has_e;
                if (a.len == 2) {
                    i += 1;
                    if (i >= args.len or args[i][0] == '-') return Flags.has_error;
                }
            },
            else => return Flags.has_error,
        }
    }
    first.* = 0;
    return flags;
}

fn printUsage(it: *Interp, badoption: []const u8) void {
    it.writeStderr(it.progname.?);
    it.writeStderr(": ");
    if (badoption.len > 1 and (badoption[1] == 'e' or badoption[1] == 'l')) {
        it.writeStderr("'");
        it.writeStderr(badoption);
        it.writeStderr("' needs argument\n");
    } else {
        it.writeStderr("unrecognized option '");
        it.writeStderr(badoption);
        it.writeStderr("'\n");
    }
    it.writeStderr("usage: ");
    it.writeStderr(it.progname.?);
    it.writeStderr(
        \\ [options] [script [args]]
        \\Available options are:
        \\  -e stat   execute string 'stat'
        \\  -i        enter interactive mode after executing 'script'
        \\  -l mod    require library 'mod' into global 'mod'
        \\  -l g=mod  require library 'mod' into global 'g'
        \\  -v        show version information
        \\  -E        ignore environment variables
        \\  -W        turn warnings on
        \\  --        stop handling options
        \\  -         stop handling options and execute stdin
        \\
    );
}

/// Runs `-e`, `-l`, and `-W` in order, up to `n`. False when a chunk
/// fails.
fn runArgs(it: *Interp, state: *lua.State, n: usize) lua.Error!bool {
    const args = it.args;
    var i: usize = 1;
    while (i < n) : (i += 1) {
        const a = args[i];
        switch (a[1]) {
            'e', 'l' => {
                var extra: []const u8 = a[2..];
                if (extra.len == 0) {
                    i += 1;
                    extra = args[i];
                }
                const ok = if (a[1] == 'e')
                    it.dostring(state, extra, "=(command line)")
                else
                    try it.dolibrary(state, extra);
                if (!ok) return false;
            },
            'W' => state.warn("@on", false),
            else => {},
        }
    }
    return true;
}

fn createArgTable(state: *lua.State, args: []const [:0]const u8, script: usize) lua.Error!void {
    const t = try state.newTable();
    for (args, 0..) |a, i| try t.rawSet(state, @as(i64, @intCast(i)) - @as(i64, @intCast(script)), a);
    try state.setGlobal("arg", t);
}

/// Writes to the state's standard output and flushes, ignoring failures
/// as lua.c's `lua_writestring` and `fflush` do.
fn writeOut(state: *lua.State, bytes: []const u8) void {
    const out = state.stdout();
    out.writeAll(bytes) catch return;
    out.flush() catch return;
}

/// The body of the interpreter, `pmain`, run in protected mode. False
/// when something failed and was reported.
fn pmain(it: *Interp, state: *lua.State) lua.Error!bool {
    const optlim = if (it.script > 0) it.script else it.args.len;
    if (it.flags & Flags.has_v != 0) writeOut(state, copyright ++ "\n");
    try createArgTable(state, it.args, it.script);
    if (!it.handleLuaInit(state)) return false;
    if (!try runArgs(it, state, optlim)) return false;
    if (it.script > 0 and !try it.handleScript(state)) return false;
    if (it.flags & Flags.has_i != 0) {
        try it.doRepl(state);
    } else if (it.script < 1 and it.flags & (Flags.has_e | Flags.has_v) == 0) {
        if (std.Io.File.stdin().isTty(it.io) catch false) {
            writeOut(state, copyright ++ "\n");
            try it.doRepl(state);
        } else {
            _ = it.dofile(state, null);
        }
    }
    return true;
}

pub fn main(init: std.process.Init) u8 {
    // Debug builds keep the leak-checking allocator; the others use a fast
    // general-purpose one.
    const gpa = if (builtin.mode == .Debug) init.gpa else std.heap.smp_allocator;
    const io = init.io;
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch {
        std.Io.File.stderr().writeStreamingAll(io, "lua: not enough memory\n") catch return 1;
        return 1;
    };
    const progname: []const u8 = if (args.len > 0 and args[0].len > 0) args[0] else "lua";
    var it: Interp = .{ .io = io, .environ = init.environ_map, .args = args, .progname = progname };
    it.flags = collectArgs(args, &it.script);
    if (it.flags == Flags.has_error) {
        printUsage(&it, args[it.script]);
        return 1;
    }
    // One state on one thread: strings get an allocator without locks and
    // with size classes 8 bytes apart. lua.c's pmain runs the collector in
    // generational mode.
    var small: lua.SmallAllocator = .init(gpa);
    defer small.deinit();
    const state = lua.State.init(gpa, .{
        .io = io,
        .environ = init.environ_map,
        .noenv = it.flags & Flags.has_upper_e != 0,
        .strings = small.allocator(),
        .gc_mode = .generational,
        .gc_stress = std.meta.stringToEnum(@FieldType(lua.Options, "gc_stress"), build_options.gc_stress).?,
    }) catch {
        it.message("cannot create state: not enough memory");
        return 1;
    };
    // `lua_close` runs pending to-be-closed variables and finalizers,
    // which may still write, then flushes, as C's `exit` flushes every
    // stream.
    defer state.close();
    const ok = blk: {
        const body = state.function(&it, pmain) catch |e| {
            it.report(state, e);
            break :blk false;
        };
        // lua.c passes `argc` and `argv`, and with the traceback handler
        // below this occupies as many stack slots, so a stack overflow
        // counts the same levels.
        break :blk state.call(bool, body, .{args.len}) catch |e| {
            // An error `pmain` raised rather than reported: lua.c's `main`
            // prints the error object, with no traceback.
            const v = state.errorValue();
            const t = v.typeOf();
            it.message(if (e == error.OutOfMemory)
                "not enough memory"
            else if (t == .string or t == .number)
                state.errorMessage()
            else
                "(error message not a string)");
            break :blk false;
        };
    };
    return if (ok) 0 else 1;
}

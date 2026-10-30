//! The standalone interpreter, `lua`, as reference Lua 5.5.1's lua.c
//! behaves: a script with its `arg` table, `-e`, `-l`, `-i`, `-v`, `-E`,
//! `-W`, `--`, `-` for stdin, `LUA_INIT`, and an interactive loop when
//! stdin is a terminal. Errors print as "lua: message" on stderr, without
//! the reference's traceback, and the exit status is 1.

const std = @import("std");
const builtin = @import("builtin");
const lua = @import("lua");

const Value = lua.Value;
const State = lua.State;
const Thread = lua.Thread;
const vm = lua.vm;
const base = lua.lib.base;

const copyright = "Lua 5.5.1  Copyright (C) 1994-2026 Lua.org, PUC-Rio";

const Interp = struct {
    th: *Thread,
    host: *base.Host,
    environ: *std.process.Environ.Map,
    /// Null in interactive mode, where messages have no program name.
    progname: ?[]const u8,
    use_env: bool = true,
    stdin: ?std.Io.File.Reader = null,
    stdin_buf: [512]u8 = undefined,

    fn message(it: *Interp, msg: []const u8) void {
        if (it.progname) |p| {
            it.host.writeStderr(p);
            it.host.writeStderr(": ");
        }
        it.host.writeStderr(msg);
        it.host.writeStderr("\n");
    }

    /// Prints the error object on top of the stack, as `report` does, and
    /// pops it.
    fn report(it: *Interp) void {
        const th = it.th;
        const v = th.stack[th.top - 1];
        th.top -= 1;
        var buf: [number_len]u8 = undefined;
        it.message(it.errorText(v, &buf));
    }

    /// The text of an error object: a string or number as is, a `__tostring`
    /// result, or a description of its type, as lua.c's message handler.
    fn errorText(it: *Interp, v: Value, buf: *[number_len]u8) []const u8 {
        if (v.isString()) return v.asString().bytes();
        if (v.isNumber()) {
            const s = base.numberToString(it.th.state, v) catch return "not enough memory";
            return s.bytes();
        }
        if (base.getMetafield(it.th, v, "__tostring") != null) {
            const s = base.toStringValue(it.th, v) catch null;
            if (s) |sv| return sv.asString().bytes();
        }
        return std.fmt.bufPrint(buf, "(error object is a {s} value)", .{v.typeOf().name()}) catch unreachable;
    }

    /// Calls the function below `narg` arguments on top in protected
    /// mode. On failure the error object is left on top.
    fn docall(it: *Interp, narg: u32, nres: i16) bool {
        const th = it.th;
        return vm.pcall(th, th.top - narg - 1, nres);
    }

    /// Pushes the result of a load, or its error object, and says which.
    fn pushLoad(it: *Interp, result: Value.Error!Value) bool {
        const th = it.th;
        th.ensureStack(1) catch return false;
        const f = result catch |e| {
            th.push(switch (e) {
                error.LuaError => th.err,
                error.OutOfMemory => .string(th.state.memerr),
            });
            th.err = .nil;
            return false;
        };
        th.push(f);
        return true;
    }

    fn dochunk(it: *Interp, loaded: bool) bool {
        if (loaded and it.docall(0, 0)) return true;
        it.report();
        return false;
    }

    fn dofile(it: *Interp, name: ?[]const u8) bool {
        return it.dochunk(it.pushLoad(base.loadFile(it.th, name, "bt")));
    }

    fn dostring(it: *Interp, s: []const u8, name: []const u8) bool {
        const gpa = it.th.heap().allocator();
        const z = gpa.dupeZ(u8, s) catch return it.dochunk(it.pushLoad(error.OutOfMemory));
        defer gpa.free(z);
        return it.dochunk(it.pushLoad(base.loadChunk(it.th, z, name, "t")));
    }

    /// `globname = require(modname)` for `-l globname[=modname]`; without
    /// `=`, a suffix after '-' is cut from the global name.
    fn dolibrary(it: *Interp, spec: []const u8) bool {
        const th = it.th;
        const state = th.state;
        var globname = spec;
        var modname = spec;
        if (std.mem.findScalar(u8, spec, '=')) |eq| {
            globname = spec[0..eq];
            modname = spec[eq + 1 ..];
        } else if (std.mem.findScalar(u8, spec, '-')) |dash| {
            globname = spec[0..dash];
        }
        const ok = blk: {
            th.ensureStack(2) catch break :blk false;
            const req = state.newString("require") catch break :blk false;
            th.push(state.globals.getStr(req));
            th.push(.string(state.newString(modname) catch break :blk false));
            break :blk it.docall(1, 1);
        };
        if (!ok) {
            it.report();
            return false;
        }
        th.top -= 1;
        const name = state.newString(globname) catch return false;
        state.globals.setStr(&state.heap, name, th.stack[th.top]) catch return false;
        return true;
    }

    fn handleScript(it: *Interp, args: []const [:0]const u8, script: usize) bool {
        const th = it.th;
        var fname: ?[]const u8 = args[script];
        if (std.mem.eql(u8, args[script], "-") and !std.mem.eql(u8, args[script - 1], "--")) fname = null;
        if (!it.pushLoad(base.loadFile(th, fname, "bt"))) {
            it.report();
            return false;
        }
        // The script's arguments: arg[1] .. arg[#arg].
        const state = th.state;
        const argname = state.newString("arg") catch return false;
        const argv = state.globals.getStr(argname);
        if (argv.tag != .table) {
            th.push(.string(state.newString("'arg' is not a table") catch return false));
            it.report();
            return false;
        }
        const n: u32 = @intCast(argv.asTable().length());
        th.ensureStack(n + 3) catch return false;
        for (1..n + 1) |i| th.push(argv.asTable().getInt(@intCast(i)));
        if (it.docall(n, -1)) return true;
        it.report();
        return false;
    }

    fn getenv(it: *Interp, name: []const u8) ?[]const u8 {
        if (!it.use_env) return null;
        return it.environ.get(name);
    }

    fn handleLuaInit(it: *Interp) bool {
        var name: []const u8 = "=LUA_INIT_5_5";
        const init = it.getenv(name[1..]) orelse blk: {
            name = "=LUA_INIT";
            break :blk it.getenv(name[1..]) orelse return true;
        };
        if (init.len > 0 and init[0] == '@') return it.dofile(init[1..]);
        return it.dostring(init, name);
    }

    // The interactive loop.

    /// Writes the prompt (`_PROMPT` or `_PROMPT2` through `tostring`, or
    /// the default), then reads a line as `fgets` would into lua.c's
    /// 512-byte buffer, without its newline. Null at the end of input.
    fn readLine(it: *Interp, firstline: bool, line: *std.ArrayList(u8)) ?void {
        const th = it.th;
        const state = th.state;
        const pname = state.newString(if (firstline) "_PROMPT" else "_PROMPT2") catch return null;
        const pv = state.globals.getStr(pname);
        if (pv.isNil()) {
            it.host.writeStdout(if (firstline) "> " else ">> ");
        } else if (base.toStringValue(th, pv)) |s| {
            it.host.writeStdout(s.asString().bytes());
        } else |_| {
            th.err = .nil;
        }
        it.host.flushStdout();
        if (it.stdin == null) it.stdin = std.Io.File.stdin().readerStreaming(it.host.io, &it.stdin_buf);
        const r = &it.stdin.?.interface;
        line.clearRetainingCapacity();
        const gpa = th.heap().allocator();
        while (line.items.len < 511) {
            const c = r.takeByte() catch break;
            line.append(gpa, c) catch return null;
            if (c == '\n') break;
        }
        if (line.items.len == 0) return null;
        if (line.items[line.items.len - 1] == '\n') line.items.len -= 1;
    }

    /// Whether the error object on top is a syntax error for an incomplete
    /// statement, ending in "<eof>".
    fn incomplete(it: *Interp) bool {
        const v = it.th.stack[it.th.top - 1];
        return v.isString() and std.mem.endsWith(u8, v.asString().bytes(), "<eof>");
    }

    fn loadText(it: *Interp, text: []const u8) bool {
        const gpa = it.th.heap().allocator();
        const z = gpa.dupeZ(u8, text) catch return it.pushLoad(error.OutOfMemory);
        defer gpa.free(z);
        return it.pushLoad(base.loadChunk(it.th, z, "=stdin", "t"));
    }

    /// Reads and compiles one statement: first as "return line;", then as
    /// a statement, reading more lines while it is incomplete. Null at the
    /// end of input; otherwise the function or the error is on top.
    fn loadLine(it: *Interp, line: *std.ArrayList(u8)) ?bool {
        const gpa = it.th.heap().allocator();
        it.readLine(true, line) orelse return null;
        var ret: std.ArrayList(u8) = .empty;
        defer ret.deinit(gpa);
        ret.print(gpa, "return {s};", .{line.items}) catch return null;
        if (it.loadText(ret.items)) return true;
        it.th.top -= 1;
        const trimmed = std.mem.trimStart(u8, line.items, " \t");
        if (std.mem.startsWith(u8, trimmed, "local") and trimmed.len > 5 and (trimmed[5] == ' ' or trimmed[5] == '\t'))
            it.host.writeStderr("warning: locals do not survive across lines in interactive mode\n");
        var more: std.ArrayList(u8) = .empty;
        defer more.deinit(gpa);
        while (true) {
            if (it.loadText(line.items)) return true;
            if (!it.incomplete()) return false;
            it.readLine(false, &more) orelse return false;
            it.th.top -= 1;
            line.append(gpa, '\n') catch return null;
            line.appendSlice(gpa, more.items) catch return null;
        }
    }

    fn doRepl(it: *Interp) void {
        const th = it.th;
        const old = it.progname;
        it.progname = null;
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(th.heap().allocator());
        const bottom = th.top;
        while (it.loadLine(&line)) |loaded| {
            if (loaded and it.docall(0, -1)) {
                it.printResults(bottom);
            } else {
                it.report();
            }
            th.top = bottom;
        }
        th.top = bottom;
        it.host.writeStdout("\n");
        it.host.flushStdout();
        it.progname = old;
    }

    /// Prints the values above `bottom` with the global `print`.
    fn printResults(it: *Interp, bottom: u32) void {
        const th = it.th;
        const n = th.top - bottom;
        if (n == 0) return;
        th.ensureStack(1) catch return;
        const pname = th.state.newString("print") catch return;
        @memmove(th.stack[bottom + 1 .. th.top + 1], th.stack[bottom..th.top]);
        th.stack[bottom] = th.state.globals.getStr(pname);
        th.top += 1;
        if (!vm.pcall(th, bottom, 0)) {
            var buf: [number_len]u8 = undefined;
            const text = it.errorText(th.stack[th.top - 1], &buf);
            var msg: [512]u8 = undefined;
            const shown = text[0..@min(text.len, 400)];
            it.message(std.fmt.bufPrint(&msg, "error calling 'print' ({s})", .{shown}) catch text);
        }
    }
};

const number_len = 128;

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
    const h = it.host;
    h.writeStderr(it.progname.?);
    h.writeStderr(": ");
    if (badoption.len > 1 and (badoption[1] == 'e' or badoption[1] == 'l')) {
        h.writeStderr("'");
        h.writeStderr(badoption);
        h.writeStderr("' needs argument\n");
    } else {
        h.writeStderr("unrecognized option '");
        h.writeStderr(badoption);
        h.writeStderr("'\n");
    }
    h.writeStderr("usage: ");
    h.writeStderr(it.progname.?);
    h.writeStderr(
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

/// Runs `-e`, `-l`, and `-W` in order. False when a chunk fails.
fn runArgs(it: *Interp, args: []const [:0]const u8, n: usize) bool {
    base.warnf(it.host, "@off", false);
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
                const ok = if (a[1] == 'e') it.dostring(extra, "=(command line)") else it.dolibrary(extra);
                if (!ok) return false;
            },
            'W' => base.warnf(it.host, "@on", false),
            else => {},
        }
    }
    return true;
}

fn createArgTable(th: *Thread, args: []const [:0]const u8, script: usize) Value.Error!void {
    const state = th.state;
    const narg = args.len - (script + 1);
    const t = try state.newTable(@intCast(narg), @intCast(script + 1));
    for (args, 0..) |a, i| {
        try t.setInt(&state.heap, @as(i64, @intCast(i)) - @as(i64, @intCast(script)), .string(try state.newString(a)));
    }
    try state.globals.setStr(&state.heap, try state.newString("arg"), .table(t));
}

fn writeVersion(host: *base.Host) void {
    host.writeStdout(copyright ++ "\n");
    host.flushStdout();
}

/// The body of the interpreter, `pmain`. False when something failed.
fn pmain(it: *Interp, args: []const [:0]const u8) Value.Error!bool {
    var script: usize = 0;
    const flags = collectArgs(args, &script);
    const optlim = if (script > 0) script else args.len;
    if (flags == Flags.has_error) {
        printUsage(it, args[script]);
        return false;
    }
    if (flags & Flags.has_v != 0) writeVersion(it.host);
    const state = it.th.state;
    if (flags & Flags.has_upper_e != 0) {
        it.use_env = false;
        try state.registry.setStr(&state.heap, try state.newString("LUA_NOENV"), .true);
    }
    try lua.lib.os.setEnviron(it.th, it.environ);
    try lua.lib.openLibs(it.th, it.host);
    try createArgTable(it.th, args, script);
    it.host.gc_mode = .generational;
    if (!it.handleLuaInit()) return false;
    if (!runArgs(it, args, optlim)) return false;
    if (script > 0 and !it.handleScript(args, script)) return false;
    if (flags & Flags.has_i != 0) {
        it.doRepl();
    } else if (script < 1 and flags & (Flags.has_e | Flags.has_v) == 0) {
        if (std.Io.File.stdin().isTty(it.host.io) catch false) {
            writeVersion(it.host);
            it.doRepl();
        } else {
            _ = it.dofile(null);
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
    var host: base.Host = undefined;
    host.init(io);
    const progname: []const u8 = if (args.len > 0 and args[0].len > 0) args[0] else "lua";
    const state = State.create(gpa, .{}) catch {
        host.writeStderr(progname);
        host.writeStderr(": cannot create state: not enough memory\n");
        return 1;
    };
    defer state.destroy();
    var it: Interp = .{ .th = state.main, .host = &host, .environ = init.environ_map, .progname = progname };
    const ok = pmain(&it, args) catch |e| blk: {
        // Opening the libraries or building `arg` failed.
        it.th.err = .nil;
        it.message(switch (e) {
            error.OutOfMemory => "not enough memory",
            error.LuaError => "error opening the libraries",
        });
        break :blk false;
    };
    // Open files flush at exit, as C's `exit` flushes every stream.
    lua.lib.io.flushAll(it.th);
    host.flushStdout();
    return if (ok) 0 else 1;
}

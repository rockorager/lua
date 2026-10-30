//! The debug library (§6.10): `getinfo`, `getlocal`, `setlocal`,
//! `getupvalue`, `setupvalue`, `upvalueid`, `upvaluejoin`, `traceback`,
//! `getmetatable`, `setmetatable`, `getregistry`, `getuservalue`,
//! `setuservalue`, `sethook`, and `gethook`, as ldblib.c has them. A
//! thread's Lua hook function lives in `registry._HOOKKEY`, a table with
//! weak keys from threads to functions, and `hookf` is the `Thread.Hook`
//! that calls it.

const std = @import("std");
const Value = @import("../Value.zig");
const Table = @import("../Table.zig");
const Thread = @import("../Thread.zig");
const State = @import("../State.zig");
const Proto = @import("../Proto.zig");
const vm = @import("../vm.zig");
const debuginfo = @import("../debuginfo.zig");

const Error = Value.Error;

/// The library's functions, by name.
const functions = [_]struct { []const u8, Value.NativeFn }{
    .{ "getinfo", &getinfo },
    .{ "getlocal", &getlocal },
    .{ "setlocal", &setlocal },
    .{ "getupvalue", &getupvalue },
    .{ "setupvalue", &setupvalue },
    .{ "upvalueid", &upvalueid },
    .{ "upvaluejoin", &upvaluejoin },
    .{ "traceback", &traceback },
    .{ "getmetatable", &getmetatable },
    .{ "setmetatable", &setmetatable },
    .{ "getregistry", &getregistry },
    .{ "getuservalue", &getuservalue },
    .{ "setuservalue", &setuservalue },
    .{ "sethook", &sethook },
    .{ "gethook", &gethook },
};

/// Creates the `debug` table and sets the global.
pub fn open(state: *State) Error!void {
    const t = try state.newTable(0, functions.len);
    for (functions) |f| try t.setStr(&state.heap, try state.newString(f[0]), .native(f[1]));
    try state.globals.setStr(&state.heap, try state.newString("debug"), .table(t));
}

// ---------------------------------------------------------------------------
// Arguments
// ---------------------------------------------------------------------------

fn arg(th: *Thread, base: u32, n: u32) Value {
    return if (base + n - 1 < th.top) th.stack[base + n - 1] else .nil;
}

fn isNone(th: *Thread, base: u32, n: u32) bool {
    return base + n - 1 >= th.top;
}

fn argError(th: *Thread, n: u32, msg: []const u8) Error {
    return debuginfo.argError(th, n, "?", msg);
}

fn typeError(th: *Thread, base: u32, n: u32, expected: []const u8) Error {
    var buf: [128]u8 = undefined;
    const v = arg(th, base, n);
    const got = if (isNone(th, base, n))
        "no value"
    else if (v.tag == .light_userdata)
        "light userdata"
    else
        th.state.typeName(v);
    const msg = std.fmt.bufPrint(&buf, "{s} expected, got {s}", .{ expected, got }) catch "?";
    return argError(th, n, msg);
}

fn checkInteger(th: *Thread, base: u32, n: u32) Error!i64 {
    const v = arg(th, base, n);
    if (vm.toInteger(v)) |i| return i;
    if (vm.toNumber(v) != null) return argError(th, n, "number has no integer representation");
    return typeError(th, base, n, "number");
}

fn optInteger(th: *Thread, base: u32, n: u32, def: i64) Error!i64 {
    return if (arg(th, base, n).isNil()) def else checkInteger(th, base, n);
}

fn checkFunction(th: *Thread, base: u32, n: u32) Error!Value {
    const v = arg(th, base, n);
    if (!v.isFunction()) return typeError(th, base, n, "function");
    return v;
}

/// The thread a function works on: the first argument when it is a
/// thread, with the rest of the arguments after it, else the running
/// one (`getthread`). Returns the thread and the argument offset.
fn getThread(th: *Thread, base: u32) struct { *Thread, u32 } {
    const v = arg(th, base, 1);
    if (v.tag == .thread) return .{ v.asThread(), 1 };
    return .{ th, 0 };
}

/// Index into `t.frames` of call level `level` (0 is the running
/// function), or null past the outermost call (`lua_getstack`).
fn frameAt(t: *Thread, level: i64) ?usize {
    if (level < 0) return null;
    const n = t.frames.items.len;
    if (level >= n - 1) return null;
    return n - 1 - @as(usize, @intCast(level));
}

fn pushString(th: *Thread, s: []const u8) Error!void {
    th.push(.string(try th.state.newString(s)));
}

fn setField(th: *Thread, t: *Table, name: []const u8, v: Value) Error!void {
    try t.setStr(th.heap(), try th.state.newString(name), v);
}

// ---------------------------------------------------------------------------
// getinfo
// ---------------------------------------------------------------------------

fn getinfo(th: *Thread, base: u32) Error!u32 {
    const t1, const off = getThread(th, base);
    const opt_v = arg(th, base, off + 2);
    const options = if (opt_v.isNil()) "flnSrtu" else if (opt_v.isString() or opt_v.isNumber())
        (try vm.toLString(th.state, opt_v)).?.bytes()
    else
        return typeError(th, base, off + 2, "string");
    if (options.len > 0 and options[0] == '>') return argError(th, off + 2, "invalid option '>'");
    for (options) |c| {
        if (std.mem.findScalar(u8, "SlnrtuLf", c) == null) return argError(th, off + 2, "invalid option");
    }
    const target = arg(th, base, off + 1);
    var func: Value = undefined;
    var frame: ?usize = null;
    if (target.isFunction()) {
        func = target;
    } else {
        const level = try checkInteger(th, base, off + 1);
        frame = frameAt(t1, level) orelse {
            th.push(.nil);
            return 1;
        };
        func = t1.stack[t1.frames.items[frame.?].func];
    }
    try th.ensureStack(3);
    const r = try th.state.newTable(0, 16);
    th.push(.table(r));
    const has = struct {
        fn f(o: []const u8, c: u8) bool {
            return std.mem.findScalar(u8, o, c) != null;
        }
    }.f;
    const lua: ?*Proto = if (func.tag == .lua_closure) func.asLuaClosure().proto else null;
    if (has(options, 'S')) {
        var src: []const u8 = "=[C]";
        if (lua) |p| src = if (p.source) |s| s.bytes() else "=?";
        try setField(th, r, "source", .string(try th.state.newString(src)));
        var aw: std.Io.Writer.Allocating = .init(th.heap().allocator());
        defer aw.deinit();
        Thread.writeChunkId(&aw.writer, src) catch return error.OutOfMemory;
        try setField(th, r, "short_src", .string(try th.state.newString(aw.written())));
        try setField(th, r, "linedefined", .int(if (lua) |p| p.linedefined else -1));
        try setField(th, r, "lastlinedefined", .int(if (lua) |p| p.lastlinedefined else -1));
        const what = if (lua) |p| (if (p.linedefined == 0) "main" else "Lua") else "C";
        try setField(th, r, "what", .string(try th.state.newString(what)));
    }
    if (has(options, 'l')) {
        try setField(th, r, "currentline", .int(if (frame) |i| currentLine(t1, i) else -1));
    }
    if (has(options, 'u')) {
        const nups: usize = switch (func.tag) {
            .lua_closure => func.asLuaClosure().upvals().len,
            .native_closure => func.asNativeClosure().upvalues().len,
            else => 0,
        };
        try setField(th, r, "nups", .int(@intCast(nups)));
        try setField(th, r, "nparams", .int(if (lua) |p| p.numparams else 0));
        try setField(th, r, "isvararg", .boolean(if (lua) |p| p.flags.vararg or p.flags.vararg_table else true));
    }
    if (has(options, 'n')) {
        const n = if (frame) |i| debuginfo.funcName(t1, i) else null;
        if (n) |v| try setField(th, r, "name", .string(try th.state.newString(v.name)));
        try setField(th, r, "namewhat", .string(try th.state.newString(if (n) |v| v.kind else "")));
    }
    if (has(options, 'r')) {
        // Only a frame that is running a hook has transfer information.
        const hooked = if (frame) |i| t1.frames.items[i].flags.hooked else false;
        try setField(th, r, "ftransfer", .int(if (hooked) t1.ftransfer else 0));
        try setField(th, r, "ntransfer", .int(if (hooked) t1.ntransfer else 0));
    }
    if (has(options, 't')) {
        const f = if (frame) |i| &t1.frames.items[i] else null;
        try setField(th, r, "istailcall", .boolean(if (f) |x| x.flags.tail else false));
        try setField(th, r, "extraargs", .int(if (f) |x| x.flags.ncallmt else 0));
    }
    if (has(options, 'L')) {
        if (lua) |p| {
            const lines = try th.state.newTable(0, 0);
            try setField(th, r, "activelines", .table(lines));
            // A vararg function's first instruction, `VARARGPREP`, has no
            // line of its own.
            const first: usize = if (p.flags.vararg or p.flags.vararg_table) 1 else 0;
            if (p.lineinfo.len > first) {
                for (p.lineinfo[first..]) |line| try lines.setInt(th.heap(), line, .true);
            }
        }
    }
    if (has(options, 'f')) try setField(th, r, "func", func);
    return 1;
}

fn currentLine(t: *Thread, i: usize) i64 {
    const f = &t.frames.items[i];
    if (!f.flags.lua) return -1;
    const p = t.stack[f.func].asLuaClosure().proto;
    return p.lineAt(Thread.currentPc(p, f)) orelse -1;
}

// ---------------------------------------------------------------------------
// Locals
// ---------------------------------------------------------------------------

/// The name and stack slot of local `n` of the frame at `i`, as
/// `luaG_findlocal` finds them: a named local, a vararg (negative `n`),
/// or a temporary.
fn findLocal(t: *Thread, i: usize, n: i64) ?struct { []const u8, u32 } {
    const f = &t.frames.items[i];
    const base = f.func + 1;
    var name: ?[]const u8 = null;
    if (f.flags.lua) {
        if (n < 0) {
            if (-n > f.extra_args) return null;
            return .{ "(vararg)", f.func - f.extra_args + @as(u32, @intCast(-n - 1)) };
        }
        const p = t.stack[f.func].asLuaClosure().proto;
        if (n > 0) name = debuginfo.localName(p, @intCast(n), Thread.currentPc(p, f));
    }
    if (name == null) {
        const limit = if (i == t.frames.items.len - 1) t.top else t.frames.items[i + 1].func;
        if (n > 0 and limit - base >= n) {
            name = if (f.flags.lua) "(temporary)" else "(C temporary)";
        } else return null;
    }
    return .{ name.?, base + @as(u32, @intCast(n - 1)) };
}

fn getlocal(th: *Thread, base: u32) Error!u32 {
    const t1, const off = getThread(th, base);
    const n = try checkInteger(th, base, off + 2);
    const target = arg(th, base, off + 1);
    try th.ensureStack(2);
    if (target.isFunction()) {
        // Parameters, the locals alive at the function's start.
        const name = if (target.tag == .lua_closure and n > 0)
            debuginfo.localName(target.asLuaClosure().proto, @intCast(n), 0)
        else
            null;
        if (name) |s| try pushString(th, s) else th.push(.nil);
        return 1;
    }
    const level = try checkInteger(th, base, off + 1);
    const i = frameAt(t1, level) orelse return argError(th, off + 1, "level out of range");
    const loc = findLocal(t1, i, n) orelse {
        th.push(.nil);
        return 1;
    };
    const v = t1.stack[loc[1]];
    try pushString(th, loc[0]);
    th.push(v);
    return 2;
}

fn setlocal(th: *Thread, base: u32) Error!u32 {
    const t1, const off = getThread(th, base);
    const level = try checkInteger(th, base, off + 1);
    const i = frameAt(t1, level) orelse return argError(th, off + 1, "level out of range");
    const n = try checkInteger(th, base, off + 2);
    if (isNone(th, base, off + 3)) return argError(th, off + 3, "value expected");
    const v = arg(th, base, off + 3);
    const loc = findLocal(t1, i, n) orelse {
        th.push(.nil);
        return 1;
    };
    t1.stack[loc[1]] = v;
    try pushString(th, loc[0]);
    return 1;
}

// ---------------------------------------------------------------------------
// Upvalues
// ---------------------------------------------------------------------------

/// Upvalue `n` (from 1) of closure `f`: its name ("" for a native
/// closure's) and value, or null when there is none (`aux_upvalue`).
fn upvalue(f: Value, n: i64) ?struct { []const u8, *Value } {
    switch (f.tag) {
        .lua_closure => {
            const c = f.asLuaClosure();
            if (n < 1 or n > c.upvals().len) return null;
            const i: usize = @intCast(n - 1);
            const p = c.proto;
            const uname = if (i < p.upvalues.len) p.upvalues[i].name else null;
            const name = if (uname) |s| s.bytes() else "(no name)";
            return .{ name, c.upvals()[i].v };
        },
        .native_closure => {
            const c = f.asNativeClosure();
            if (n < 1 or n > c.upvalues().len) return null;
            return .{ "", &c.upvalues()[@intCast(n - 1)] };
        },
        else => return null,
    }
}

fn getupvalue(th: *Thread, base: u32) Error!u32 {
    const n = try checkInteger(th, base, 2);
    const f = try checkFunction(th, base, 1);
    const u = upvalue(f, n) orelse return 0;
    try th.ensureStack(2);
    const v = u[1].*;
    try pushString(th, u[0]);
    th.push(v);
    return 2;
}

fn setupvalue(th: *Thread, base: u32) Error!u32 {
    if (isNone(th, base, 3)) return argError(th, 3, "value expected");
    const n = try checkInteger(th, base, 2);
    const f = try checkFunction(th, base, 1);
    const v = arg(th, base, 3);
    const u = upvalue(f, n) orelse return 0;
    switch (f.tag) {
        .lua_closure => f.asLuaClosure().upvals()[@intCast(n - 1)].set(th.heap(), v),
        else => f.asNativeClosure().setUpvalue(th.heap(), @intCast(n - 1), v),
    }
    try pushString(th, u[0]);
    return 1;
}

/// The identity of upvalue `n` of closure `f`, or null (`lua_upvalueid`).
fn upvalueId(f: Value, n: i64) ?*anyopaque {
    switch (f.tag) {
        .lua_closure => {
            const c = f.asLuaClosure();
            if (n < 1 or n > c.upvals().len) return null;
            return c.upvals()[@intCast(n - 1)];
        },
        .native_closure => {
            const c = f.asNativeClosure();
            if (n < 1 or n > c.upvalues().len) return null;
            return &c.upvalues()[@intCast(n - 1)];
        },
        else => return null,
    }
}

fn upvalueid(th: *Thread, base: u32) Error!u32 {
    const n = try checkInteger(th, base, 2);
    const f = try checkFunction(th, base, 1);
    th.push(if (upvalueId(f, n)) |p| Value.lightUserdata(p) else .nil);
    return 1;
}

fn upvaluejoin(th: *Thread, base: u32) Error!u32 {
    const n1 = try checkInteger(th, base, 2);
    const f1 = try checkFunction(th, base, 1);
    if (upvalueId(f1, n1) == null) return argError(th, 2, "invalid upvalue index");
    const n2 = try checkInteger(th, base, 4);
    const f2 = try checkFunction(th, base, 3);
    if (upvalueId(f2, n2) == null) return argError(th, 4, "invalid upvalue index");
    if (f1.tag != .lua_closure) return argError(th, 1, "Lua function expected");
    if (f2.tag != .lua_closure) return argError(th, 3, "Lua function expected");
    const c1 = f1.asLuaClosure();
    c1.setUpval(th.heap(), @intCast(n1 - 1), f2.asLuaClosure().upvals()[@intCast(n2 - 1)]);
    return 0;
}

// ---------------------------------------------------------------------------
// The rest
// ---------------------------------------------------------------------------

fn traceback(th: *Thread, base: u32) Error!u32 {
    const t1, const off = getThread(th, base);
    const msg_v = arg(th, base, off + 1);
    if (!msg_v.isNil() and !msg_v.isString() and !msg_v.isNumber()) {
        th.push(msg_v);
        return 1;
    }
    const msg: ?[]const u8 = if (msg_v.isNil()) null else (try vm.toLString(th.state, msg_v)).?.bytes();
    const level = try optInteger(th, base, off + 2, if (t1 == th) 1 else 0);
    var aw: std.Io.Writer.Allocating = .init(th.heap().allocator());
    defer aw.deinit();
    debuginfo.traceback(&aw.writer, t1, msg, level) catch return error.OutOfMemory;
    th.push(.string(try th.state.newString(aw.written())));
    return 1;
}

fn getmetatable(th: *Thread, base: u32) Error!u32 {
    if (isNone(th, base, 1)) return argError(th, 1, "value expected");
    th.push(if (th.state.metatableOf(arg(th, base, 1))) |mt| .table(mt) else .nil);
    return 1;
}

fn setmetatable(th: *Thread, base: u32) Error!u32 {
    const mt = arg(th, base, 2);
    if (mt.tag != .nil and mt.tag != .table) return typeError(th, base, 2, "nil or table");
    th.state.setMetatable(arg(th, base, 1), if (mt.tag == .table) mt.asTable() else null);
    th.top = base + 1;
    return 1;
}

fn getregistry(th: *Thread, base: u32) Error!u32 {
    _ = base;
    th.push(.table(th.state.registry));
    return 1;
}

fn getuservalue(th: *Thread, base: u32) Error!u32 {
    const n = try optInteger(th, base, 2, 1);
    const u = arg(th, base, 1);
    if (u.tag != .userdata) {
        th.push(.nil);
        return 1;
    }
    const vals = u.asUserdata().userValues();
    if (n < 1 or n > vals.len) {
        th.push(.nil);
        th.push(.false);
        return 2;
    }
    th.push(vals[@intCast(n - 1)]);
    th.push(.true);
    return 2;
}

fn setuservalue(th: *Thread, base: u32) Error!u32 {
    const u = arg(th, base, 1);
    if (u.tag != .userdata) return typeError(th, base, 1, "userdata");
    if (isNone(th, base, 2)) return argError(th, 2, "value expected");
    const n = try optInteger(th, base, 3, 1);
    const ud = u.asUserdata();
    if (n < 1 or n > ud.userValues().len) {
        th.push(.nil);
        return 1;
    }
    ud.setUserValue(th.heap(), @intCast(n - 1), arg(th, base, 2));
    th.top = base + 1;
    return 1;
}

// ---------------------------------------------------------------------------
// Hooks
// ---------------------------------------------------------------------------

const hook_names = [_][]const u8{ "call", "return", "line", "count", "tail call" };

/// `registry._HOOKKEY`, or null before the first `sethook`.
fn hookTable(state: *State) Error!?*Table {
    const v = state.registry.getStr(try state.newString("_HOOKKEY"));
    return if (v.tag == .table) v.asTable() else null;
}

/// The hook `sethook` installs: calls the thread's function in the hook
/// table with the event's name and, for a line event, the line (`hookf`).
fn hookf(th: *Thread, event: Thread.HookEvent, line: i32, frame: usize) Error!void {
    _ = frame;
    const hooks = try hookTable(th.state) orelse return;
    const f = hooks.get(.thread(th));
    if (!f.isFunction()) return;
    try th.ensureStack(3);
    const func = th.top;
    th.push(f);
    try pushString(th, hook_names[@intFromEnum(event)]);
    th.push(if (line >= 0) .int(line) else .nil);
    try vm.call(th, func, 0);
}

fn sethook(th: *Thread, base: u32) Error!u32 {
    const t1, const off = getThread(th, base);
    var mask: u8 = 0;
    var count: i64 = 0;
    const f = arg(th, base, off + 1);
    if (!f.isNil()) {
        const smask_v = arg(th, base, off + 2);
        if (!smask_v.isString() and !smask_v.isNumber()) return typeError(th, base, off + 2, "string");
        const smask = (try vm.toLString(th.state, smask_v)).?.bytes();
        if (!f.isFunction()) return typeError(th, base, off + 1, "function");
        count = try optInteger(th, base, off + 3, 0);
        const has = std.mem.findScalar;
        if (has(u8, smask, 'c') != null) mask |= Thread.HookMask.call;
        if (has(u8, smask, 'r') != null) mask |= Thread.HookMask.ret;
        if (has(u8, smask, 'l') != null) mask |= Thread.HookMask.line;
        if (count > 0) mask |= Thread.HookMask.count;
    }
    const hooks = try hookTable(th.state) orelse blk: {
        // hooks.__mode = "k", and hooks is its own metatable.
        const t = try th.state.newTable(0, 1);
        try th.state.registry.setStr(th.heap(), try th.state.newString("_HOOKKEY"), .table(t));
        try setField(th, t, "__mode", .string(try th.state.newString("k")));
        th.state.setMetatable(.table(t), t);
        break :blk t;
    };
    hooks.set(th.heap(), .thread(t1), f) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        // The key is a thread.
        error.IndexIsNil, error.IndexIsNaN => unreachable,
    };
    // lua_sethook takes an int; ldblib passes the integer through a cast.
    const c: i32 = @truncate(count);
    vm.setHook(t1, if (f.isNil()) null else &hookf, mask, c);
    return 0;
}

fn gethook(th: *Thread, base: u32) Error!u32 {
    const t1, _ = getThread(th, base);
    try th.ensureStack(3);
    if (t1.hook == null) {
        th.push(.nil);
        return 1;
    }
    const hooks = try hookTable(th.state);
    th.push(if (hooks) |t| t.get(.thread(t1)) else .nil);
    var buf: [3]u8 = undefined;
    var n: usize = 0;
    if (t1.hookmask & Thread.HookMask.call != 0) {
        buf[n] = 'c';
        n += 1;
    }
    if (t1.hookmask & Thread.HookMask.ret != 0) {
        buf[n] = 'r';
        n += 1;
    }
    if (t1.hookmask & Thread.HookMask.line != 0) {
        buf[n] = 'l';
        n += 1;
    }
    try pushString(th, buf[0..n]);
    th.push(.int(t1.basehookcount));
    return 3;
}

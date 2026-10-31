//! What a call through the embedding API costs against the engine's own
//! path. `bench-api ARM SCENARIO [N]` runs one scenario N times on one
//! arm and prints a benchstat line with the time per operation; `just
//! bench-api` interleaves the arms on one core and adds peak memory.
//!
//! The `internal` arm is written the way the standard library and the
//! standalone `lua` are: natives on `stack[base..top]` with `auxlib.Args`,
//! `vm.pcall` from the top level, raw table operations. The `api` arm does
//! the same work through `lua.State`.

const std = @import("std");
const lua = @import("lua");
const internal = lua.internal;
const IValue = internal.Value;
const Thread = internal.Thread;
const Args = internal.auxlib.Args;

const Scenario = enum {
    /// Lua calls a Zig function of two integers in a loop.
    lua_calls_zig,
    /// The host calls a Lua function of two integers from the top level.
    zig_calls_lua,
    /// The same, without the traceback handler (`Options.traceback`).
    zig_calls_lua_notb,
    /// Lua calls a Zig function that calls a Lua function back.
    callback,
    /// The host sets and reads an integer global.
    globals,
    /// Lua calls a method on a userdata in a loop.
    userdata_method,
    /// The host reads a table of four fields into a struct.
    decode_struct,

    fn defaultN(s: Scenario) u32 {
        return switch (s) {
            .lua_calls_zig, .userdata_method => 20_000_000,
            .callback => 5_000_000,
            .zig_calls_lua, .zig_calls_lua_notb => 10_000_000,
            .globals, .decode_struct => 10_000_000,
        };
    }
};

const Arm = enum { internal, api };

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) return error.Usage;
    const arm = std.meta.stringToEnum(Arm, args[1]) orelse return error.Usage;
    const scenario = std.meta.stringToEnum(Scenario, args[2]) orelse return error.Usage;
    const n = if (args.len > 3) try std.fmt.parseInt(u32, args[3], 10) else scenario.defaultN();
    const io = init.io;
    const state = try lua.State.init(std.heap.smp_allocator, .{
        .seed = 1,
        .traceback = scenario != .zig_calls_lua_notb,
    });
    defer state.close();
    const start = std.Io.Timestamp.now(io, .awake);
    const check = switch (arm) {
        .internal => try runInternal(state, scenario, n),
        .api => try runApi(state, scenario, n),
    };
    const ns = start.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds;
    var buf: [256]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &buf);
    const per: f64 = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(n));
    try out.interface.print("BenchmarkAPI/{t}\t{d}\t{d:.2} ns/op\n", .{ scenario, n, per });
    try out.interface.flush();
    // The work done, which must be the same on both arms.
    var ebuf: [64]u8 = undefined;
    var err = std.Io.File.stderr().writer(io, &ebuf);
    try err.interface.print("{d}\n", .{check});
    try err.interface.flush();
}

// ---------------------------------------------------------------------------
// The API arm
// ---------------------------------------------------------------------------

fn add(a: i64, b: i64) i64 {
    return a +% b;
}

fn apply(state: *lua.State, f: lua.Function, x: i64) !i64 {
    return state.call(i64, f, .{x});
}

const Counter = struct {
    n: i64,

    pub const lua_userdata = .{ .methods = .{ .incr = incr } };

    fn incr(c: *Counter) i64 {
        c.n += 1;
        return c.n;
    }
};

fn newCounter(state: *lua.State) !*Counter {
    return state.newUserdata(Counter, .{ .n = 0 });
}

const Fields = struct { a: i64, b: f64, c: []const u8, d: bool };

fn runApi(state: *lua.State, scenario: Scenario, n: u32) !i64 {
    switch (scenario) {
        .lua_calls_zig => {
            try state.setGlobal("add", add);
            return state.call(i64, try state.load(loop_add, .{}), .{n});
        },
        .zig_calls_lua, .zig_calls_lua_notb => {
            const f = try state.ref(try state.doString(lua.Function, "return function(a, b) return a + b end", .{}));
            var acc: i64 = 0;
            for (0..n) |i| acc = try state.call(i64, f, .{ acc, @as(i64, @intCast(i)) });
            return acc;
        },
        .callback => {
            try state.setGlobal("apply", apply);
            return state.call(i64, try state.load(loop_apply, .{}), .{n});
        },
        .globals => {
            var acc: i64 = 0;
            for (0..n) |i| {
                try state.setGlobal("counter", @as(i64, @intCast(i)));
                acc +%= try state.getGlobal(i64, "counter");
            }
            return acc;
        },
        .userdata_method => {
            try state.setGlobal("Counter", newCounter);
            return state.call(i64, try state.load(loop_method, .{}), .{n});
        },
        .decode_struct => {
            const t = try state.ref(try state.doString(lua.Value, fields_table, .{}));
            var acc: i64 = 0;
            for (0..n) |_| {
                const f = try state.decode(Fields, t);
                acc +%= f.a + @as(i64, @intFromFloat(f.b)) + @as(i64, @intCast(f.c.len)) + @intFromBool(f.d);
            }
            return acc;
        },
    }
}

const loop_add = "local n = ... local add = add local s = 0 for i = 1, n do s = add(s, i) end return s";
const loop_apply =
    "local n = ... local apply = apply local f = function(x) return x + 1 end " ++
    "local s = 0 for i = 1, n do s = s + apply(f, i) end return s";
const loop_method = "local n = ... local c = Counter() local s = 0 for i = 1, n do s = c:incr() end return s";
const fields_table = "return { a = 1, b = 2.5, c = 'three', d = true }";

// ---------------------------------------------------------------------------
// The internal arm
// ---------------------------------------------------------------------------

const Error = IValue.Error;

fn thread(state: *lua.State) *Thread {
    return @ptrCast(@alignCast(state));
}

fn addInternal(th: *Thread, b: u32) Error!u32 {
    const a = Args.init(th, b, "add");
    const x = try a.checkInteger(1);
    const y = try a.checkInteger(2);
    th.push(.int(x +% y));
    return 1;
}

fn applyInternal(th: *Thread, b: u32) Error!u32 {
    const a = Args.init(th, b, "apply");
    if (!a.get(1).isFunction()) return a.typeError(1, "function");
    const x = try a.checkInteger(2);
    try th.ensureStack(2);
    const func = th.top;
    th.push(a.get(1));
    th.push(.int(x));
    try internal.vm.call(th, func, 1);
    const r = internal.auxlib.toInteger(th.stack[func]) orelse return a.typeError(1, "number");
    th.top = func;
    th.push(.int(r));
    return 1;
}

const counter_key = "bench.Counter";

fn counterMeta(th: *Thread) ?*internal.Table {
    const v = th.state.registry.getStr(th.state.newString(counter_key) catch return null);
    return if (v.isTable()) v.asTable() else null;
}

fn newCounterInternal(th: *Thread, b: u32) Error!u32 {
    _ = b;
    const s = th.state;
    const u = try internal.Userdata.create(&s.heap, @sizeOf(i64), 0);
    @as(*i64, @ptrCast(@alignCast(u.bytes().ptr))).* = 0;
    s.setMetatable(.userdata(u), counterMeta(th));
    th.push(.userdata(u));
    return 1;
}

fn incrInternal(th: *Thread, b: u32) Error!u32 {
    const a = Args.init(th, b, "incr");
    const v = a.get(1);
    if (v.typeOf() != .userdata or v.asUserdata().metatable != counterMeta(th)) return a.typeError(1, "Counter");
    const p: *i64 = @ptrCast(@alignCast(v.asUserdata().bytes().ptr));
    p.* += 1;
    th.push(.int(p.*));
    return 1;
}

/// Runs `src` with `n` as its argument, as the standalone `lua` runs a
/// chunk: loaded, then called in protected mode.
fn runChunk(th: *Thread, src: [:0]const u8, n: u32) Error!i64 {
    const f = try internal.lib.base.loadChunk(th, src, "=bench", "t");
    try th.ensureStack(2);
    const func = th.top;
    th.push(f);
    th.push(.int(n));
    if (!internal.vm.pcall(th, func, 1)) return error.LuaError;
    const r = th.stack[func].asInt();
    th.top = func;
    return r;
}

fn setGlobal(th: *Thread, name: []const u8, v: IValue) Error!void {
    const s = th.state;
    try s.globals.setStr(&s.heap, try s.newString(name), v);
}

fn runInternal(state: *lua.State, scenario: Scenario, n: u32) !i64 {
    const th = thread(state);
    const s = th.state;
    switch (scenario) {
        .lua_calls_zig => {
            try setGlobal(th, "add", .native(&addInternal));
            return runChunk(th, loop_add, n);
        },
        .zig_calls_lua, .zig_calls_lua_notb => {
            // The function stays in a registry reference, as a host keeps it.
            const r = try state.ref(try state.doString(lua.Function, "return function(a, b) return a + b end", .{}));
            var acc: i64 = 0;
            for (0..n) |i| {
                try th.ensureStack(3);
                const func = th.top;
                th.push(s.registry.getInt(@intFromEnum(r)));
                th.push(.int(acc));
                th.push(.int(@intCast(i)));
                if (!internal.vm.pcall(th, func, 1)) return error.LuaError;
                const v = th.stack[func];
                acc = if (v.isInt()) v.asInt() else internal.auxlib.toInteger(v) orelse return error.LuaError;
                th.top = func;
            }
            return acc;
        },
        .callback => {
            try setGlobal(th, "apply", .native(&applyInternal));
            return runChunk(th, loop_apply, n);
        },
        .globals => {
            var acc: i64 = 0;
            for (0..n) |i| {
                try s.globals.setStr(&s.heap, try s.newString("counter"), .int(@intCast(i)));
                const v = s.globals.getStr(try s.newString("counter"));
                acc +%= if (v.isInt()) v.asInt() else internal.auxlib.toInteger(v) orelse return error.LuaError;
            }
            return acc;
        },
        .userdata_method => {
            const mt = try s.newTable(0, 2);
            const methods = try s.newTable(0, 1);
            try methods.setStr(&s.heap, try s.newString("incr"), .native(&incrInternal));
            try mt.setStr(&s.heap, try s.newString("__index"), .table(methods));
            try s.registry.setStr(&s.heap, try s.newString(counter_key), .table(mt));
            try setGlobal(th, "Counter", .native(&newCounterInternal));
            return runChunk(th, loop_method, n);
        },
        .decode_struct => {
            const r = try state.ref(try state.doString(lua.Value, fields_table, .{}));
            var acc: i64 = 0;
            for (0..n) |_| {
                const t = s.registry.getInt(@intFromEnum(r)).asTable();
                const a = t.getStr(try s.newString("a"));
                const b = t.getStr(try s.newString("b"));
                const c = t.getStr(try s.newString("c"));
                const d = t.getStr(try s.newString("d"));
                if (!a.isInt() or !b.isNumber() or !c.isString()) return error.LuaError;
                const f: Fields = .{ .a = a.asInt(), .b = b.asNumber(), .c = c.asString().bytes(), .d = !d.isFalsy() };
                acc +%= f.a + @as(i64, @intFromFloat(f.b)) + @as(i64, @intCast(f.c.len)) + @intFromBool(f.d);
            }
            return acc;
        },
    }
}

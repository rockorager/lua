//! The embedding API: how a Zig program hosts Lua. `State` is a Lua
//! universe, or, inside a Zig function Lua calls, the coroutine running
//! it. Zig values convert to Lua values and back by their types, Zig
//! functions become Lua functions with the reference's argument checks,
//! and Zig types become userdata with metatables.
//!
//! The engine's value layout, call frames, and collector barriers stay
//! behind this file; `docs/slop/api.md` records the design.
//!
//! Values the API hands back that point into Lua's heap (string slices,
//! `Value`, `Table`, `Function`, userdata pointers) are borrowed: each
//! stays valid while Lua can reach it, and in any case until the
//! collector next runs. The collector runs only inside Lua code (a
//! call, a chunk, a metamethod) and in `collect`, never inside an
//! allocation. To keep a value longer, hold a `Ref`.

const std = @import("std");
const IValue = @import("Value.zig");
const IState = @import("State.zig");
const Thread = @import("Thread.zig");
const ITable = @import("Table.zig");
const Userdata = @import("Userdata.zig");
const Proto = @import("Proto.zig");
const vm = @import("vm.zig");
const gc = @import("gc.zig");
const debuginfo = @import("debuginfo.zig");
const lib = @import("lib/init.zig");
const base = lib.base;
const auxlib = @import("lib/auxlib.zig");
const number = @import("number.zig");

const IError = IValue.Error;

/// What can go wrong. After `Runtime` or `Syntax`, `State.errorMessage`
/// has the message and `State.errorValue` the error object.
pub const Error = error{
    /// A Lua error: one raised by Lua code or a Zig function, or a value
    /// that does not convert to the requested Zig type.
    Runtime,
    /// A chunk did not compile, or a binary chunk did not load.
    Syntax,
    OutOfMemory,
};

/// The standard libraries, by the global each one sets (`base` sets the
/// functions of §6.1 and `_G`).
pub const Lib = lib.Lib;
pub const Libs = std.EnumSet(Lib);

/// The libraries that reach nothing outside the state: no files, no
/// processes, no environment, no `debug`. `base` still has `dofile`,
/// `loadfile`, and `print`, which use `Options.io`.
pub const safe_libs: Libs = .initMany(&.{ .base, .coroutine, .math, .string, .table, .utf8 });

/// Lua's basic types.
pub const Type = enum(u8) {
    nil,
    boolean,
    light_userdata,
    number,
    string,
    table,
    function,
    userdata,
    thread,

    /// The name `type()` returns.
    pub fn name(t: Type) []const u8 {
        return @as(IValue.Type, @fromBackingInt(@intCast(@backingInt(t)))).name();
    }
};

comptime {
    const a = @typeInfo(Type).@"enum";
    const b = @typeInfo(IValue.Type).@"enum";
    for (a.field_names, a.field_values, b.field_names, b.field_values) |a_name, a_value, b_name, b_value| {
        std.debug.assert(std.mem.eql(u8, a_name, b_name) and a_value == b_value);
    }
}

/// Any Lua value, borrowed (see the file's comment). Convert it with
/// `State.decode`.
pub const Value = struct {
    /// The engine's representation; not part of the API.
    raw: IValue,

    pub const nil: Value = .{ .raw = .nil };

    pub inline fn typeOf(v: Value) Type {
        return @fromBackingInt(@intCast(@backingInt(v.raw.typeOf())));
    }

    pub inline fn isNil(v: Value) bool {
        return v.raw.isNil();
    }

    /// Lua's truth: false for `nil` and `false`, true for everything else.
    pub inline fn toBool(v: Value) bool {
        return !v.raw.isFalsy();
    }
};

comptime {
    // `Values` reinterprets the engine's stack slots as `Value`s.
    std.debug.assert(@sizeOf(Value) == @sizeOf(IValue) and @offsetOf(Value, "raw") == 0);
}

/// Any number of Lua values, borrowed from the state's stack: valid until
/// the next call into the state. As the result type of `call` (and
/// `doString`, `Coroutine.resume`) it takes every result; returned from a
/// Zig function, each value is a result; passed as `call`'s arguments in
/// place of a tuple, each value is an argument. Elsewhere, such as a struct
/// field, a slice of `Value` converts to a sequence like any slice.
pub const Values = []const Value;

/// A Lua table, borrowed.
pub const Table = struct {
    /// The engine's table; not part of the API.
    raw: *ITable,

    pub inline fn value(t: Table) Value {
        return .{ .raw = .table(t.raw) };
    }

    /// The raw length `#t` (a border), without `__len`.
    pub fn len(t: Table) u64 {
        return t.raw.length();
    }

    /// `t[key]` as a `T`, raw (`rawget`): no `__index`. `key` is any
    /// value the API converts.
    pub fn rawGet(t: Table, state: *State, comptime T: type, key: anytype) Error!T {
        const th = state.thread();
        const k = try toLua(th, key);
        const v = t.raw.get(k);
        if (decodeFast(T, v)) |x| return x;
        return fieldSlow(T, th, k, v);
    }

    /// `t[key] = x`, raw (`rawset`): no `__newindex`.
    pub fn rawSet(t: Table, state: *State, key: anytype, x: anytype) Error!void {
        const th = state.thread();
        const k = try toLua(th, key);
        return rawSetValue(th, t.raw, k, try toLua(th, x));
    }

    /// Visits every key and value, raw, in `next`'s order. Do not add keys
    /// to the table while iterating; assigning to existing keys or
    /// clearing them is fine.
    pub fn iterator(t: Table) Iterator {
        return .{ .t = t.raw };
    }

    pub const Entry = struct { key: Value, value: Value };

    pub const Iterator = struct {
        t: *ITable,
        key: IValue = .nil,

        pub fn next(it: *Iterator) ?Entry {
            const e = (it.t.next(it.key) catch return null) orelse return null;
            it.key = e.key;
            return .{ .key = .{ .raw = e.key }, .value = .{ .raw = e.value } };
        }
    };
};

/// A Lua function, or anything else `State.decode` accepted as one,
/// borrowed.
pub const Function = struct {
    /// The engine's value; not part of the API.
    raw: IValue,

    pub inline fn value(f: Function) Value {
        return .{ .raw = f.raw };
    }
};

/// A Lua coroutine (a thread), borrowed. `State.newCoroutine` makes one;
/// `resume` runs it until it yields or returns.
pub const Coroutine = struct {
    /// The engine's thread; not part of the API.
    raw: *Thread,

    pub inline fn value(co: Coroutine) Value {
        return .{ .raw = .thread(co.raw) };
    }

    /// What a resume gives back, each converted to `R`: the values the
    /// coroutine yielded, or, once its body returns, its results.
    pub fn Result(comptime R: type) type {
        return union(enum) { yielded: R, returned: R };
    }

    /// Starts or continues the coroutine, as `coroutine.resume` does,
    /// passing `args` (a tuple, or `Values`): the body's arguments on the
    /// first resume, and the results of the `yield` it is suspended in
    /// after that. `state` is the caller: the state at the top level, or
    /// the one a Zig function got. An error inside the coroutine kills it
    /// and comes back as `error.Runtime` (with `State.errorTraceback` set
    /// to the coroutine's traceback) or `error.OutOfMemory`; so does
    /// resuming one that is dead or running. `R` converts the values as
    /// `State.call` does; they are borrowed until the next call into the
    /// state.
    pub fn @"resume"(co: Coroutine, state: *State, comptime R: type, args: anytype) Error!Result(R) {
        const th = state.thread();
        const c = co.raw;
        if (c == th) return state.raise("cannot resume non-suspended coroutine", .{});
        const n: u32 = @intCast(argCount(args));
        const from = stackIndex(c, args);
        if (!(vm.checkStack(c, n) catch return error.OutOfMemory))
            return state.raise("too many arguments to resume", .{});
        try placeArgs(c, c.top, args, from);
        c.top += n;
        // The coroutine runs anchored on the caller's stack.
        dropKept(th);
        ensure(th, 1) catch |e| {
            c.top -= n;
            return e;
        };
        const bottom = th.top;
        defer th.top = bottom;
        th.push(.thread(c));
        extraOf(th.state).trace.clearRetainingCapacity();
        const r = vm.resumeThread(c, th, n) catch |e| return mapError(e);
        if (r.status == .err) return resumeError(th, c, r.err);
        const first = c.top - r.nres;
        defer c.top = first;
        const out = try results(R, th, c.stack[first..].ptr, r.nres);
        return if (r.status == .ok) .{ .returned = out } else .{ .yielded = out };
    }

    /// What a coroutine is doing, by `coroutine.status`'s names:
    /// `suspended` (not started, or in a yield), `running` (it is the
    /// caller), `normal` (it resumed the caller, directly or not), or
    /// `dead` (its body returned or failed, or it was closed).
    pub const Status = lib.coroutine.CoStatus;

    /// The coroutine's status seen from `state`, the caller, as
    /// `coroutine.status` reports it.
    pub fn status(co: Coroutine, state: *State) Status {
        return lib.coroutine.coStatus(state.thread(), co.raw);
    }

    /// Closes a suspended or dead coroutine, as `coroutine.close` does: its
    /// pending to-be-closed variables are closed and it is dead. When it
    /// had died with an error, or a `__close` handler raises, that error
    /// comes back as `error.Runtime`, or `error.OutOfMemory` when an
    /// allocation failed. Closing a running or normal coroutine raises
    /// the reference's error.
    pub fn close(co: Coroutine, state: *State) Error!void {
        const th = state.thread();
        const c = co.raw;
        switch (co.status(state)) {
            .suspended, .dead => {},
            .running, .normal => |s| return state.raise("cannot close a {s} coroutine", .{@tagName(s)}),
        }
        // Handlers run anchored on the caller's stack, as for `resume`.
        dropKept(th);
        try ensure(th, 1);
        const bottom = th.top;
        defer th.top = bottom;
        th.push(.thread(c));
        extraOf(th.state).trace.clearRetainingCapacity();
        const s = vm.closeThread(c, th);
        if (s == .ok) return;
        th.err = c.stack[c.top - 1];
        c.top -= 1;
        return if (s == .memory) error.OutOfMemory else error.Runtime;
    }
};

/// A reference to a Lua value in the registry, as `luaL_ref` makes: it
/// keeps the value alive and stays valid across collections until
/// `State.unref`. Use it wherever the API takes a Lua value.
pub const Ref = enum(i32) {
    /// The reference to `nil`, which holds nothing.
    nil = -1,
    _,
};

/// A Zig function's arguments as Lua passed them, numbered from 1, for a
/// function that takes any number of them: make `Args` its last
/// parameter. It sees every argument, including those earlier
/// parameters converted.
pub const Args = struct {
    th: *Thread,
    base: u32,
    top: u32,

    /// How many arguments the call passed.
    pub inline fn count(a: Args) u32 {
        return a.top - a.base;
    }

    /// Argument `n`, or nil when the call passed fewer.
    pub inline fn get(a: Args, n: u32) Value {
        const i = a.base + n - 1;
        return .{ .raw = if (i < a.top) a.th.stack[i] else .nil };
    }

    /// Argument `n` as a `T`, checked as a parameter of type `T` is, with
    /// the same "bad argument" errors.
    pub fn check(a: Args, comptime T: type, n: u32) Error!T {
        return checkArg(T, a.th, a.base, a.top, n);
    }

    pub inline fn state(a: Args) *State {
        return .of(a.th);
    }
};

/// How `State.load` treats binary chunks (`string.dump`, `luac` output).
/// The engine trusts a binary chunk the way reference Lua does: a crafted
/// one can corrupt memory, so load them only from trusted sources.
pub const Mode = enum { text, binary, any };

pub const LoadOptions = struct {
    /// The chunk's name in messages and tracebacks: "=name" as is,
    /// "@file" as a file name. By default the source itself, shown as
    /// `[string "..."]`, as `luaL_loadstring` does.
    name: ?[]const u8 = null,
    mode: Mode = .text,
};

pub const Options = struct {
    /// The standard libraries to open. By default every one when `io`
    /// is set, and `safe_libs` when it is not.
    libs: ?Libs = null,
    /// I/O for `print`, `dofile`, `loadfile`, `doFile`, and the `io`,
    /// `os`, and `package` libraries; the `io` and `os` libraries need
    /// it. Without it every operation fails: `print` prints nothing and
    /// no file opens, so scripts reach nothing outside the state.
    io: ?std.Io = null,
    /// Where `print` and `io.stdout` write, in place of the process's
    /// standard output: a GUI host captures them here, with or without
    /// `io`. It must outlive the state, which flushes it after each
    /// `print` and at `close`.
    stdout: ?*std.Io.Writer = null,
    /// The environment for `os.getenv` and `package`'s paths; none when
    /// null. It must outlive the state.
    environ: ?*const std.process.Environ.Map = null,
    /// `package.path` and `package.cpath` ignore `LUA_PATH` and
    /// `LUA_CPATH` and take their defaults, as with `lua -E`; `os.getenv`
    /// still reads `environ`.
    noenv: bool = false,
    /// Record a traceback when a call from the host fails, for
    /// `State.errorTraceback`. It costs a stack slot per call, and the
    /// traceback is written only on error.
    traceback: bool = true,
    /// The host's own data, for `State.context`.
    context: ?*anyopaque = null,
    /// Fixes the hash seed, for reproducible runs; random otherwise.
    seed: ?u64 = null,
    /// An allocator for string objects; the state's allocator when null.
    strings: ?std.mem.Allocator = null,
    /// The collector's mode from the start, as `collectgarbage` sets it;
    /// the standalone `lua` runs generational.
    gc_mode: enum { incremental, generational } = .incremental,
    /// Collector stress, for finding values a host holds borrowed past
    /// their lifetime: `full` collects at every safe point, `step` takes
    /// one incremental step at each. Slow.
    gc_stress: @FieldType(IState.Options, "gc_stress") = .off,
};

pub const DecodeOptions = struct {
    /// A table key that names no field of the struct being read is
    /// ignored, or, with `.reject`, an error that gives its path, such as
    /// "unknown key 'keybinds[2].acton'". Catches typos in configuration.
    unknown_keys: enum { ignore, reject } = .ignore,
};

/// What the API keeps beside the engine's state: the libraries' host and
/// the last traceback.
const Extra = struct {
    host: base.Host,
    gpa: std.mem.Allocator,
    traceback: bool,
    context: ?*anyopaque,
    trace: std.ArrayList(u8) = .empty,
    /// The metatables of userdata types, by `typeId`; the registry holds
    /// it.
    types: *ITable = undefined,
};

inline fn extraOf(s: *IState) *Extra {
    return @alignCast(@fieldParentPtr("host", base.hostOf(s).?));
}

/// A Lua universe as its main thread, or the coroutine a Zig function
/// runs on. Every method but `close` may be called from inside a Zig
/// function Lua called; there, Lua errors propagate to Lua's caller when
/// returned with `try`, as in Lua. At the top level, outside any call, every call
/// into Lua is protected and its error comes back as a Zig error.
pub const State = opaque {
    inline fn thread(state: *State) *Thread {
        return @ptrCast(@alignCast(state));
    }

    inline fn of(th: *Thread) *State {
        return @ptrCast(th);
    }

    /// A new state with the chosen libraries open. Every byte it
    /// allocates comes from `gpa`.
    pub fn init(gpa: std.mem.Allocator, options: Options) Error!*State {
        const extra = try gpa.create(Extra);
        errdefer gpa.destroy(extra);
        extra.* = .{ .host = undefined, .gpa = gpa, .traceback = options.traceback, .context = options.context };
        const libs = options.libs orelse if (options.io != null) Libs.full else safe_libs;
        if (options.io == null and (libs.contains(.io) or libs.contains(.os)))
            @panic("lua: the io and os libraries need Options.io");
        extra.host.init(options.io orelse .failing);
        if (options.stdout) |w| try extra.host.setStdout(w);
        errdefer extra.host.closeStdout();
        extra.host.environ = options.environ;
        extra.host.noenv = options.noenv;
        const s = try IState.create(gpa, .{
            .seed = options.seed,
            .strings = options.strings,
            .gc_stress = options.gc_stress,
        });
        errdefer s.destroy();
        extra.types = try s.newTable(0, 0);
        try s.registry.setStr(&s.heap, try s.newString("_ZIG_TYPES"), .table(extra.types));
        lib.openSome(s.main, &extra.host, libs) catch |e| return mapError(e);
        if (options.gc_mode == .generational) gc.changeMode(s.main, .gen_minor);
        return .of(s.main);
    }

    /// Closes the state: pending to-be-closed variables, then every
    /// pending finalizer, then frees everything. Call it on the state
    /// `init` returned, outside any call.
    pub fn close(state: *State) void {
        const th = state.thread();
        const s = th.state;
        std.debug.assert(th == s.main);
        std.debug.assert(th.frames.items.len == 1);
        const extra = extraOf(s);
        vm.closeState(s);
        lib.io.flushAll(th);
        extra.host.flushStdout();
        s.destroy();
        extra.host.closeStdout();
        extra.trace.deinit(extra.gpa);
        extra.gpa.destroy(extra);
    }

    /// `Options.context`, as a `*T`.
    pub fn context(state: *State, comptime T: type) *T {
        return @ptrCast(@alignCast(extraOf(state.thread().state).context.?));
    }

    /// The writer `print` and `io.stdout` use: `Options.stdout`, or the
    /// process's buffered standard output. Write the host's own output
    /// through it to keep it in order with the script's.
    pub fn stdout(state: *State) *std.Io.Writer {
        return extraOf(state.thread().state).host.writer();
    }

    /// Emits a warning, as `warn` does (`lua_warning`): pieces with
    /// `tocont` set continue the message, and "@on" and "@off" turn
    /// warnings on and off. Warnings start off.
    pub fn warn(state: *State, msg: []const u8, tocont: bool) void {
        base.warnf(&extraOf(state.thread().state).host, msg, tocont);
    }

    // -----------------------------------------------------------------
    // Chunks and calls
    // -----------------------------------------------------------------

    /// Compiles a chunk, or loads a binary one, into a function whose
    /// `_ENV` is the globals table, without running it.
    pub fn load(state: *State, source: []const u8, options: LoadOptions) Error!Function {
        const th = state.thread();
        const gpa = th.heap().allocator();
        const z = try gpa.dupeSentinel(u8, source, 0);
        defer gpa.free(z);
        const f = base.loadChunk(th, z, options.name orelse source, modeString(options.mode)) catch |e|
            return loadError(th, e);
        return .{ .raw = f };
    }

    /// `load` for a file read through `Options.io`, named "@path", or
    /// standard input, named "=stdin", when `path` is null.
    pub fn loadFile(state: *State, path: ?[]const u8, mode: Mode) Error!Function {
        const th = state.thread();
        const f = base.loadFile(th, path, modeString(mode)) catch |e| return loadError(th, e);
        return .{ .raw = f };
    }

    /// Loads and runs a chunk, and returns its results as `R` (see `call`).
    pub fn doString(state: *State, comptime R: type, source: []const u8, options: LoadOptions) Error!R {
        return state.call(R, try state.load(source, options), .{});
    }

    /// Loads and runs a file, and returns its results as `R` (see `call`).
    pub fn doFile(state: *State, comptime R: type, path: ?[]const u8, mode: Mode) Error!R {
        return state.call(R, try state.loadFile(path, mode), .{});
    }

    /// Calls `f`, any Lua value, with the tuple `args` converted to Lua
    /// values, or with `Values`. `R` says what comes back: `void` for
    /// nothing, a tuple type for several results, `Values` for all of
    /// them, or one type for one result, each converted as `decode` does.
    pub fn call(state: *State, comptime R: type, f: anytype, args: anytype) Error!R {
        const th = state.thread();
        const from = stackIndex(th, args);
        dropKept(th);
        try ensure(th, argCount(args) + 2);
        const bottom = th.top;
        if (th.frames.items.len == 1) return protectedCall(R, th, f, args, from, bottom);
        // An error leaves the stack to the protected call that catches
        // it, with the frames it unwinds intact for a traceback.
        try placeCall(th, bottom, f, args, from);
        vm.call(th, bottom, comptime resultCount(R)) catch |e| return mapError(e);
        return finishCall(R, th, bottom, bottom);
    }

    /// `call` in protected mode wherever it runs, as `lua_pcall`: inside a
    /// Zig function an error comes back as a Zig error, with the message
    /// and traceback, instead of propagating to Lua's caller. At the top
    /// level it is `call`.
    pub fn pcall(state: *State, comptime R: type, f: anytype, args: anytype) Error!R {
        const th = state.thread();
        const from = stackIndex(th, args);
        dropKept(th);
        try ensure(th, argCount(args) + 2);
        return protectedCall(R, th, f, args, from, th.top);
    }

    // -----------------------------------------------------------------
    // Globals and fields
    // -----------------------------------------------------------------

    /// The global `name` as a `T`, through `_G`'s `__index` if it has one.
    pub fn getGlobal(state: *State, comptime T: type, name: []const u8) Error!T {
        const th = state.thread();
        const s = th.state;
        const key = try s.newString(name);
        var v = s.globals.getStr(key);
        if (v.isNil() and s.fastTm(s.globals.metatable, .index) != null)
            v = try indexSlow(th, .table(s.globals), .string(key));
        if (decodeFast(T, v)) |x| return x;
        return globalSlow(T, th, name, v);
    }

    /// Sets the global `name` to `x` converted, through `_G`'s
    /// `__newindex` if it has one.
    pub fn setGlobal(state: *State, name: []const u8, x: anytype) Error!void {
        const th = state.thread();
        const s = th.state;
        const key = try s.newString(name);
        const v = try toLua(th, x);
        const g = s.globals;
        if (s.fastTm(g.metatable, .newindex) == null or !g.getStr(key).isNil()) return g.setStr(&s.heap, key, v);
        return setIndexSlow(th, .table(g), .string(key), v);
    }

    /// `obj[key]` as a `T`, with `__index`, as Lua's indexing does.
    /// `obj` and `key` are any values the API converts.
    pub fn getField(state: *State, comptime T: type, obj: anytype, key: anytype) Error!T {
        const th = state.thread();
        const k = try toLua(th, key);
        const v = try index(th, try toLua(th, obj), k);
        if (decodeFast(T, v)) |x| return x;
        return fieldSlow(T, th, k, v);
    }

    /// `#obj` with `__len`, as `luaL_len`: an error unless the length is
    /// an integer. `obj` is any value the API converts; `Table.len` is
    /// the raw length.
    pub fn len(state: *State, obj: anytype) Error!i64 {
        const th = state.thread();
        const o = try toLua(th, obj);
        if (o.isTable() and th.state.fastTm(o.asTable().metatable, .len) == null) return @bitCast(o.asTable().length());
        return lenSlow(th, o);
    }

    /// `obj[key] = x`, with `__newindex`, as Lua's assignment does.
    pub fn setField(state: *State, obj: anytype, key: anytype, x: anytype) Error!void {
        const th = state.thread();
        const o = try toLua(th, obj);
        const k = try toLua(th, key);
        try setIndex(th, o, k, try toLua(th, x));
    }

    // -----------------------------------------------------------------
    // Conversions
    // -----------------------------------------------------------------

    /// `x` as a Lua value: booleans, integers (as floats past 64 bits),
    /// floats, strings and string literals, enums (as their names),
    /// optionals (null is nil), slices, arrays, and tuples (as
    /// sequences), structs (as tables of their fields, null fields left
    /// out), Zig functions (see `function`), pointers from
    /// `newUserdata`, and `Value`, `Table`, `Function`, and `Ref`.
    pub fn value(state: *State, x: anytype) Error!Value {
        return .{ .raw = try toLua(state.thread(), x) };
    }

    /// A new empty table.
    pub fn newTable(state: *State) Error!Table {
        return .{ .raw = try state.thread().state.newTable(0, 0) };
    }

    /// Zig function `f` as a Lua function bound to `ctx`, which `f` gets
    /// as its first parameter on every call; the rest are as for
    /// `function`. A pointer is held as is (a light userdata), and must
    /// outlive the function; any other value is copied into memory the
    /// function owns, and `f` takes it by value or as a pointer to the
    /// copy, which it may change.
    pub fn function(state: *State, ctx: anytype, comptime f: anytype) Error!Function {
        const th = state.thread();
        const C = @TypeOf(ctx);
        const heap = th.heap();
        const up: IValue = if (comptime byPointer(C)) .lightUserdata(@ptrCast(@constCast(ctx))) else blk: {
            comptime std.debug.assert(@alignOf(C) <= 16);
            const u = try Userdata.create(heap, @sizeOf(C), 0);
            @as(*C, @ptrCast(@alignCast(u.bytes().ptr))).* = ctx;
            break :blk .userdata(u);
        };
        // No collection runs before the closure holds the userdata.
        const c = try Proto.NativeClosure.create(heap, &Native(f, C).call, 1);
        c.setUpvalue(heap, 0, up);
        return .{ .raw = .nativeClosure(c) };
    }

    /// A new coroutine with body `f`, any value the API converts, as
    /// `coroutine.create` makes it. Borrowed like any value: take a `Ref`
    /// to keep it across calls into Lua.
    pub fn newCoroutine(state: *State, f: anytype) Error!Coroutine {
        const th = state.thread();
        const fv = try toLua(th, f);
        const co = try Thread.create(th.state);
        co.inheritHook(th);
        co.push(fv);
        return .{ .raw = co };
    }

    /// Suspends the coroutine running the Zig function that calls it,
    /// passing `values` (a tuple, or `Values`) to its resumer, as
    /// `lua_yield` does. Only as the function's return value: `return
    /// state.yield(.{x});` in a function returning an error union. The
    /// next resume's values become the function's results. Outside a
    /// coroutine, or under a call that cannot yield, it raises the
    /// reference's error.
    pub fn yield(state: *State, values: anytype) Error {
        const th = state.thread();
        if (!vm.isYieldable(th)) {
            if (th.frames.items.len == 1) extraOf(th.state).trace.clearRetainingCapacity();
            return mapError(vm.yield(th, 0));
        }
        const from = stackIndex(th, values);
        const n: u32 = @intCast(argCount(values));
        try ensure(th, n);
        try placeArgs(th, th.top, values, from);
        th.top += n;
        return mapError(vm.yield(th, n));
    }

    /// The Lua value `x` (a `Value`, `Table`, `Function`, or `Ref`) as a
    /// `T`, with Lua's conversions as the reference's `luaL_check`
    /// functions make them: numbers from numeric strings and strings from
    /// numbers, integers from floats with an exact value, `bool` from
    /// any value by Lua's truth. Optionals take nil as null. An enum
    /// takes its name. A struct reads its fields from a table, raw, and
    /// fields that are nil take their default values; a tuple or array
    /// reads a sequence. Strings borrow Lua's bytes; slices other than
    /// strings need `decodeAlloc`. A value of the wrong type fails with
    /// `error.Runtime` and a message naming what was expected.
    pub fn decode(state: *State, comptime T: type, x: anytype, options: DecodeOptions) Error!T {
        const th = state.thread();
        const v = try toLua(th, x);
        if (decodeFast(T, v)) |r| return r;
        var d: Decoder = .{ .th = th, .ctx = .value, .reject = options.unknown_keys == .reject };
        return decodeAny(T, false, &d, v);
    }

    /// `decode`, copying strings into `gpa` and allocating slices from
    /// sequences. On error what was allocated so far is not freed: pass
    /// an arena.
    pub fn decodeAlloc(
        state: *State,
        comptime T: type,
        gpa: std.mem.Allocator,
        x: anytype,
        options: DecodeOptions,
    ) Error!T {
        const th = state.thread();
        var d: Decoder = .{ .th = th, .ctx = .value, .gpa = gpa, .reject = options.unknown_keys == .reject };
        return decodeAny(T, true, &d, try toLua(th, x));
    }

    /// `x` as a string, as `tostring` makes it, with `__tostring` and
    /// `__name`.
    pub fn toString(state: *State, x: anytype) Error![]const u8 {
        const th = state.thread();
        const v = try toLua(th, x);
        if (v.isString()) return v.asString().bytes();
        if (v.isNumber()) return (try vm.numberToString(th.state, v)).bytes();
        const s = if (th.frames.items.len > 1)
            base.toStringValue(th, v) catch |e| return mapError(e)
        else
            try protect(th, &tostringOp, &.{v});
        return s.asString().bytes();
    }

    // -----------------------------------------------------------------
    // References
    // -----------------------------------------------------------------

    /// A reference that keeps `x` alive until `unref`.
    pub fn ref(state: *State, x: anytype) Error!Ref {
        const th = state.thread();
        const v = try toLua(th, x);
        if (v.isNil()) return .nil;
        return newRef(th, v);
    }

    /// Releases a reference; its slot is reused.
    pub fn unref(state: *State, r: Ref) void {
        if (@backingInt(r) <= freelist) return;
        const s = state.thread().state;
        const i: i64 = @backingInt(r);
        // Both keys exist, so neither assignment allocates.
        s.registry.setInt(&s.heap, i, s.registry.getInt(freelist)) catch unreachable;
        s.registry.setInt(&s.heap, freelist, .int(i)) catch unreachable;
    }

    // -----------------------------------------------------------------
    // Userdata
    // -----------------------------------------------------------------

    /// A new userdata holding `init`, with `T`'s metatable, and a pointer
    /// to it, borrowed. Return the pointer from a Zig function or pass it
    /// to the API to hand the userdata to Lua.
    ///
    /// `T` describes its Lua side with an optional declaration
    /// `pub const lua_userdata = .{ ... }` with any of: `.name`, the
    /// metatable's `__name` (default: `T`'s name); `.methods`, a struct
    /// literal of Zig functions that becomes `__index`; `.meta`, a
    /// struct literal of metamethods (`.__gc`, `.__tostring`, `.__eq`,
    /// ...) as Zig functions. Functions take `self: *T` first. A `__gc`
    /// runs when the collector frees the userdata and at `close`.
    pub fn newUserdata(state: *State, comptime T: type, init_value: T) Error!*T {
        comptime std.debug.assert(@alignOf(T) <= 16);
        const th = state.thread();
        const mt = try metatableFor(th, T);
        const u = try Userdata.create(th.heap(), @sizeOf(T), 0);
        const p: *T = @ptrCast(@alignCast(u.bytes().ptr));
        p.* = init_value;
        th.state.setMetatable(.userdata(u), mt);
        return p;
    }

    // -----------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------

    /// Raises a Lua error with a formatted message, as `luaL_error` does:
    /// inside a Zig function Lua called, prefixed with the caller's
    /// "chunk:line:". Return it: `return state.raise("bad size {d}", .{n});`
    pub fn raise(state: *State, comptime fmt: []const u8, args: anytype) Error {
        const th = state.thread();
        if (th.frames.items.len == 1) extraOf(th.state).trace.clearRetainingCapacity();
        return mapError(debuginfo.raise(th, fmt, args));
    }

    /// The message of the last error: the error object if it is a string
    /// or number, else a description of its type.
    pub fn errorMessage(state: *State) []const u8 {
        const th = state.thread();
        const v = th.err;
        if (v.isString()) return v.asString().bytes();
        if (v.isNumber()) {
            const s = vm.numberToString(th.state, v) catch return "not enough memory";
            th.err = .string(s);
            return s.bytes();
        }
        return objectDescription(v);
    }

    /// The last error object, borrowed.
    pub fn errorValue(state: *State) Value {
        return .{ .raw = state.thread().err };
    }

    /// The message and a stack traceback of the last error a call from
    /// the top level raised, as the standalone `lua` prints them; null
    /// when the last error had none (it was not raised by running code,
    /// or `Options.traceback` is off). Valid until the next error.
    pub fn errorTraceback(state: *State) ?[]const u8 {
        const t = extraOf(state.thread().state).trace.items;
        return if (t.len == 0) null else t;
    }

    // -----------------------------------------------------------------
    // The collector
    // -----------------------------------------------------------------

    /// A full collection now, with finalizers.
    pub fn collect(state: *State) void {
        state.thread().state.collect();
    }

    /// Bytes the state has allocated, `collectgarbage("count")` times 1024.
    pub fn memoryUsed(state: *State) usize {
        return state.thread().state.heap.bytes;
    }
};

/// `f`, a Zig function, as a Lua value, for code that builds Lua values
/// itself. Passing the function to any API call does the same.
///
/// Parameters convert from Lua's arguments in order, checked as the
/// reference's `luaL_check` functions check them, with their "bad
/// argument #n to 'name' (number expected, got nil)" errors: integers
/// and floats, strings (`[]const u8` or `[:0]const u8`), `bool` (any
/// value), optionals (absent or nil is null), enums (by name), structs
/// (from a table), `Value` (any value, but present), `Table`,
/// `Function`, and `*T` for a userdata of type `T`. A first parameter
/// `*State` gets the running state, and a last `Args` all the arguments.
/// The result converts back: nothing for `void`, several results for a
/// tuple, else one. An error from the function becomes a Lua error:
/// `error.Runtime` raises the message already set (`State.raise`), and
/// any other error its name.
pub fn function(comptime f: anytype) Value {
    return .{ .raw = .native(&Native(f, void).call) };
}

/// Whether a context of type `C` is held by pointer (a light userdata)
/// rather than copied into a userdata.
fn byPointer(comptime C: type) bool {
    return switch (@typeInfo(C)) {
        .pointer => |p| p.size == .one,
        else => false,
    };
}

/// A bound function's context, from its upvalue, as parameter type `P`:
/// the pointer itself, or for a copied value the value or a pointer to
/// the copy.
inline fn boundContext(comptime P: type, comptime C: type, up: IValue) P {
    if (comptime byPointer(C)) {
        if (P != C) @compileError("the first parameter of a function bound to a " ++ @typeName(C) ++ " must be one");
        return @ptrCast(@alignCast(up.asLightUserdata().?));
    }
    const p: *C = @ptrCast(@alignCast(up.asUserdata().bytes().ptr));
    if (P == C) return p.*;
    if (P == *C or P == *const C) return p;
    @compileError("the first parameter of a function bound to a " ++ @typeName(C) ++
        " must be one, or a pointer to one");
}

// ---------------------------------------------------------------------------
// Errors and protected calls
// ---------------------------------------------------------------------------

inline fn mapError(e: IError) Error {
    return switch (e) {
        error.LuaError => error.Runtime,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn loadError(th: *Thread, e: IError) Error {
    @branchHint(.cold);
    extraOf(th.state).trace.clearRetainingCapacity();
    return switch (e) {
        error.LuaError => error.Syntax,
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// An error back into the engine's errors, for a Zig function's return.
fn toEngineError(th: *Thread, e: anyerror) IError {
    @branchHint(.cold);
    if (e == error.Runtime or e == error.Syntax) return error.LuaError;
    if (e == error.OutOfMemory) return error.OutOfMemory;
    return debuginfo.raise(th, "{s}", .{@errorName(e)});
}

inline fn ensure(th: *Thread, n: usize) Error!void {
    th.ensureStack(@intCast(n)) catch |e| return mapError(e);
}

/// How many values `args`, a tuple or `Values`, holds.
inline fn argCount(args: anytype) usize {
    if (@TypeOf(args) == Values) return args.len;
    return @typeInfo(@TypeOf(args)).@"struct".field_names.len;
}

/// Where `Values` borrowed from `th`'s stack start in it, taken before
/// the stack can move; null for anything else.
inline fn stackIndex(th: *const Thread, args: anytype) ?u32 {
    if (@TypeOf(args) != Values) return null;
    const p = @intFromPtr(args.ptr);
    const lo = @intFromPtr(th.stack.ptr);
    if (p < lo or p >= lo + th.stack.len * @sizeOf(IValue)) return null;
    return @intCast((p - lo) / @sizeOf(IValue));
}

/// `vals` as the engine's values.
inline fn rawValues(vals: Values) []const IValue {
    return @as([*]const IValue, @ptrCast(vals.ptr))[0..vals.len];
}

/// Writes `args`, a tuple or `Values`, to `dst.stack[at..]`, which has
/// room. `from` is `stackIndex(dst, args)` from before the stack last
/// moved. Borrowed values may overlap the destination, so they move.
inline fn placeArgs(dst: *Thread, at: u32, args: anytype, from: ?u32) error{OutOfMemory}!void {
    if (@TypeOf(args) == Values) {
        const src = if (from) |i| dst.stack[i..][0..args.len] else rawValues(args);
        @memmove(dst.stack[at..][0..args.len], src);
        return;
    }
    inline for (@typeInfo(@TypeOf(args)).@"struct".field_names, 0..) |name, i| {
        dst.stack[at + i] = try toLua(dst, @field(args, name));
    }
}

/// Puts `f` and `args` at `stack[func..]` for a call, with `top` after
/// them; the stack has room.
inline fn placeCall(th: *Thread, func: u32, f: anytype, args: anytype, from: ?u32) error{OutOfMemory}!void {
    if (@TypeOf(args) == Values) {
        // Borrowed values may sit where `f` goes, so `f` lands after them.
        const fv = try toLua(th, f);
        try placeArgs(th, func + 1, args, from);
        th.stack[func] = fv;
    } else {
        // Storing `f` first keeps its 16 bytes out of a spill slot.
        th.stack[func] = try toLua(th, f);
        try placeArgs(th, func + 1, args, from);
    }
    th.top = func + 1 + @as(u32, @intCast(argCount(args)));
}

/// Pushes `vals`, which may be borrowed from above `top`.
inline fn pushValues(th: *Thread, vals: Values) IError!void {
    const from = stackIndex(th, vals);
    try th.ensureStack(@intCast(vals.len));
    try placeArgs(th, th.top, vals, from);
    th.top += @intCast(vals.len);
}

fn globalSlow(comptime T: type, th: *Thread, name: []const u8, v: IValue) Error!T {
    var d: Decoder = .{ .th = th, .ctx = .{ .global = name } };
    return decodeAny(T, false, &d, v);
}

fn fieldSlow(comptime T: type, th: *Thread, k: IValue, v: IValue) Error!T {
    const root: Crumb = .ofKey(k);
    var d: Decoder = .{ .th = th, .ctx = .value, .path = &root };
    return decodeAny(T, false, &d, v);
}

/// `call` and `pcall` in protected mode, with room on the stack: `f`
/// and `args` go above `bottom`, the top.
inline fn protectedCall(comptime R: type, th: *Thread, f: anytype, args: anytype, from: ?u32, bottom: u32) Error!R {
    const extra = extraOf(th.state);
    const func = bottom + @intFromBool(extra.traceback);
    try placeCall(th, func, f, args, from);
    if (extra.traceback) th.stack[bottom] = .native(&messageHandler);
    extra.trace.clearRetainingCapacity();
    const status = vm.pcallMsgh(th, func, comptime resultCount(R), if (extra.traceback) bottom else 0);
    if (status != .ok) {
        th.top = bottom;
        return protectedError(th, func, status);
    }
    return finishCall(R, th, func, bottom);
}

/// The results of a call at `func` as `R`, with the stack back at
/// `bottom`. `Values` stay on the stack, as the running frame's kept
/// results, until the next call drops them (`dropKept`).
inline fn finishCall(comptime R: type, th: *Thread, func: u32, bottom: u32) Error!R {
    if (R == Values) {
        const f = th.frame();
        f.extra_args = bottom;
        f.old_errfunc = th.top;
        return @as([*]const Value, @ptrCast(th.stack[func..].ptr))[0 .. th.top - func];
    }
    defer th.top = bottom;
    return results(R, th, th.stack[func..].ptr, comptime @intCast(resultCount(R)));
}

/// Drops the `Values` a call from the running frame kept on the stack,
/// unless something was pushed above them. The frame records them in
/// `extra_args` (where they start; 0 for none) and `old_errfunc` (where
/// they end), which a frame without a continuation, as every Zig
/// function's and the base frame are, does not use; they go with the
/// frame.
inline fn dropKept(th: *Thread) void {
    const f = th.frame();
    if (f.extra_args == 0) return;
    if (th.top == f.old_errfunc) th.top = f.extra_args;
    f.extra_args = 0;
}

/// Runs `func` in protected mode, `msgh` the message handler's slot or
/// 0. A failure leaves the error object in `th.err`.
fn protectedRun(th: *Thread, func: u32, nres: i16, msgh: u32) Error!void {
    extraOf(th.state).trace.clearRetainingCapacity();
    const status = vm.pcallMsgh(th, func, nres, msgh);
    if (status != .ok) return protectedError(th, func, status);
}

fn protectedError(th: *Thread, func: u32, status: vm.Status) Error {
    @branchHint(.cold);
    th.err = th.stack[func];
    return if (status == .memory) error.OutOfMemory else error.Runtime;
}

/// A failed resume of `c` from `th`: its error object moves to `th`, and
/// the coroutine's traceback, when it died running, to the trace.
fn resumeError(th: *Thread, c: *Thread, status: vm.Status) Error {
    @branchHint(.cold);
    const err = c.stack[c.top - 1];
    c.top -= 1;
    th.err = err;
    if (status == .memory) return error.OutOfMemory;
    const extra = extraOf(th.state);
    if (extra.traceback and c.status == .dead) {
        var buf: [number.max_len]u8 = undefined;
        var aw: std.Io.Writer.Allocating = .fromArrayList(extra.gpa, &extra.trace);
        defer extra.trace = aw.toArrayList();
        debuginfo.traceback(&aw.writer, c, errorText(err, &buf), 0) catch extra.trace.clearRetainingCapacity();
    }
    return error.Runtime;
}

/// The message of error object `v` for a traceback: a string or number
/// as is, or a description of its type.
fn errorText(v: IValue, buf: *[number.max_len]u8) []const u8 {
    if (v.isString()) return v.asString().bytes();
    if (v.isNumber()) return vm.formatNumber(v, buf);
    return objectDescription(v);
}

/// The message handler of calls in protected mode, lua.c's `msghandler`:
/// records the message and a traceback, or, for an error object that is
/// not a string or number, its `__tostring` alone, and leaves the error
/// object as it is.
fn messageHandler(th: *Thread, b: u32) IError!u32 {
    const extra = extraOf(th.state);
    const v = th.stack[b];
    var buf: [number.max_len]u8 = undefined;
    if (!v.isString() and !v.isNumber()) tostring: {
        // `luaL_callmeta`: the metamethod's own result, which must be a
        // string, not `tostring`'s conversion of it.
        const mm = base.getMetafield(th, v, "__tostring") orelse break :tostring;
        try th.ensureStack(2);
        const func = th.top;
        th.push(mm);
        th.push(v);
        try vm.call(th, func, 1);
        const s = th.stack[func];
        th.top = func;
        if (s.isString()) {
            extra.trace.clearRetainingCapacity();
            extra.trace.appendSlice(extra.gpa, s.asString().bytes()) catch return 1;
            th.stack[b] = v;
            th.top = b + 1;
            return 1;
        }
    }
    extra.trace.clearRetainingCapacity();
    var aw: std.Io.Writer.Allocating = .fromArrayList(extra.gpa, &extra.trace);
    defer extra.trace = aw.toArrayList();
    // Without memory for it the error goes on without a traceback. The
    // message ends at a zero byte, as `luaL_traceback`'s C string does.
    const text = errorText(v, &buf);
    const msg = text[0 .. std.mem.findScalar(u8, text, 0) orelse text.len];
    debuginfo.traceback(&aw.writer, th, msg, 1) catch return 1;
    return 1;
}

fn objectDescription(v: IValue) []const u8 {
    return switch (v.typeOf()) {
        inline else => |t| "(error object is a " ++ comptime t.name() ++ " value)",
    };
}

/// Runs native `op` on `in` from the top level in protected mode, for an
/// operation that may call a metamethod, and returns its one result.
fn protect(th: *Thread, op: IValue.NativeFn, in: []const IValue) Error!IValue {
    @branchHint(.cold);
    try ensure(th, in.len + 2);
    const bottom = th.top;
    defer th.top = bottom;
    const msgh = extraOf(th.state).traceback;
    if (msgh) th.push(.native(&messageHandler));
    const func = th.top;
    th.push(.native(op));
    for (in) |v| th.push(v);
    try protectedRun(th, func, 1, if (msgh) bottom else 0);
    return th.stack[func];
}

fn getOp(th: *Thread, b: u32) IError!u32 {
    th.push(try vm.get(th, th.stack[b], th.stack[b + 1]));
    return 1;
}

fn setOp(th: *Thread, b: u32) IError!u32 {
    try vm.set(th, th.stack[b], th.stack[b + 1], th.stack[b + 2]);
    return 0;
}

fn lenOp(th: *Thread, b: u32) IError!u32 {
    th.push(.int(try auxlib.lenInt(th, th.stack[b])));
    return 1;
}

fn lenSlow(th: *Thread, o: IValue) Error!i64 {
    @branchHint(.cold);
    if (th.frames.items.len > 1) return auxlib.lenInt(th, o) catch |e| mapError(e);
    return (try protect(th, &lenOp, &.{o})).asInt();
}

fn tostringOp(th: *Thread, b: u32) IError!u32 {
    th.push(try base.toStringValue(th, th.stack[b]));
    return 1;
}

/// `o[k]` with `__index`: raw when that answers, else through the engine.
inline fn index(th: *Thread, o: IValue, k: IValue) Error!IValue {
    if (o.isTable()) {
        const t = o.asTable();
        const v = t.get(k);
        if (!v.isNil() or th.state.fastTm(t.metatable, .index) == null) return v;
    }
    return indexSlow(th, o, k);
}

fn indexSlow(th: *Thread, o: IValue, k: IValue) Error!IValue {
    @branchHint(.cold);
    if (th.frames.items.len > 1) return vm.get(th, o, k) catch |e| mapError(e);
    return protect(th, &getOp, &.{ o, k });
}

/// `o[k] = v` with `__newindex`.
inline fn setIndex(th: *Thread, o: IValue, k: IValue, v: IValue) Error!void {
    if (o.isTable()) {
        const t = o.asTable();
        if (th.state.fastTm(t.metatable, .newindex) == null or !t.get(k).isNil()) return rawSetValue(th, t, k, v);
    }
    return setIndexSlow(th, o, k, v);
}

inline fn rawSetValue(th: *Thread, t: *ITable, k: IValue, v: IValue) Error!void {
    return t.set(th.heap(), k, v) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.IndexIsNil => mapError(th.runError("table index is nil", .{})),
        error.IndexIsNaN => mapError(th.runError("table index is NaN", .{})),
    };
}

fn setIndexSlow(th: *Thread, o: IValue, k: IValue, v: IValue) Error!void {
    @branchHint(.cold);
    if (th.frames.items.len > 1) return vm.set(th, o, k, v) catch |e| mapError(e);
    _ = try protect(th, &setOp, &.{ o, k, v });
}

fn modeString(m: Mode) []const u8 {
    return switch (m) {
        .text => "t",
        .binary => "b",
        .any => "bt",
    };
}

// ---------------------------------------------------------------------------
// References
// ---------------------------------------------------------------------------

/// The registry slot that heads the free list of references, `t[1]` in
/// lauxlib.c's `luaL_ref`; false until the first reference.
const freelist = 1;

fn newRef(th: *Thread, v: IValue) Error!Ref {
    const reg = th.state.registry;
    const heap = th.heap();
    var r: i64 = 0;
    const head = reg.getInt(freelist);
    if (head.tag != .int) {
        try reg.setInt(heap, freelist, .int(0));
    } else {
        r = head.asInt();
    }
    if (r != 0) {
        try reg.setInt(heap, freelist, reg.getInt(r));
    } else {
        r = @intCast(reg.length() + 1);
    }
    try reg.setInt(heap, r, v);
    return @fromBackingInt(@intCast(r));
}

/// One payload and one tag variable: with a return for `.nil` and one for
/// the lookup, LLVM chose between the two values in memory, written in
/// pieces and read in one 16-byte load, which stalled store forwarding on
/// every call through a reference (`results/lean-20261031.md`).
inline fn refValue(th: *Thread, r: Ref) IValue {
    var payload = IValue.nil.payload;
    var tag = IValue.nil.tag;
    if (r != .nil) {
        const v = th.state.registry.getInt(@backingInt(r));
        payload = v.payload;
        tag = v.tag;
    }
    return .{ .payload = payload, .tag = tag };
}

// ---------------------------------------------------------------------------
// Zig to Lua
// ---------------------------------------------------------------------------

/// `x` as a Lua value. It allocates, but never collects, so values built
/// here stay alive until the caller anchors them.
fn toLua(th: *Thread, x: anytype) error{OutOfMemory}!IValue {
    const T = @TypeOf(x);
    const s = th.state;
    switch (T) {
        Value, Function => return x.raw,
        Table => return .table(x.raw),
        Coroutine => return .thread(x.raw),
        Ref => return refValue(th, x),
        @TypeOf(null) => return .nil,
        else => {},
    }
    switch (@typeInfo(T)) {
        .bool => return .boolean(x),
        .comptime_int => return if (x >= std.math.minInt(i64) and x <= std.math.maxInt(i64)) .int(x) else .float(x),
        .int => {
            if (std.math.cast(i64, x)) |i| return .int(i);
            return .float(@floatFromInt(x));
        },
        .comptime_float, .float => return .float(x),
        .enum_literal => return .string(try s.newString(@tagName(x))),
        .@"enum" => return .string(try s.newString(@tagName(x))),
        .optional => return if (x) |p| toLua(th, p) else .nil,
        .@"fn" => return .native(&Native(x, void).call),
        .array => |a| {
            if (a.child == u8) return .string(try s.newString(&x));
            return sequence(th, &x);
        },
        .pointer => |p| switch (p.size) {
            .slice => {
                if (p.child == u8) return .string(try s.newString(x));
                return sequence(th, x);
            },
            .one => switch (@typeInfo(p.child)) {
                .array => |a| {
                    if (a.child == u8) return .string(try s.newString(x));
                    return sequence(th, x);
                },
                .@"opaque" => {
                    if (p.child != anyopaque) @compileError("cannot convert " ++ @typeName(T) ++ " to a Lua value");
                    return .lightUserdata(@constCast(x));
                },
                .@"struct", .@"union", .@"enum" => {
                    // A pointer `newUserdata` returned.
                    const u = Userdata.fromBytes(@ptrCast(@constCast(x)));
                    std.debug.assert(u.header.tag == .userdata and u.len == @sizeOf(p.child));
                    return .userdata(u);
                },
                else => @compileError("cannot convert " ++ @typeName(T) ++ " to a Lua value"),
            },
            else => @compileError("cannot convert " ++ @typeName(T) ++ " to a Lua value"),
        },
        .@"struct" => |st| {
            if (st.is_tuple) return sequence(th, x);
            const t = try s.newTable(0, st.field_names.len);
            inline for (st.field_names) |name| {
                const fv = try toLua(th, @field(x, name));
                if (!fv.isNil()) try t.setStr(&s.heap, try s.newString(name), fv);
            }
            return .table(t);
        },
        else => @compileError("cannot convert " ++ @typeName(T) ++ " to a Lua value"),
    }
}

/// A sequence table from a slice, array, or tuple.
fn sequence(th: *Thread, items: anytype) error{OutOfMemory}!IValue {
    const s = th.state;
    const n = items.len;
    const t = try s.newTable(@intCast(n), 0);
    if (@typeInfo(@TypeOf(items)) == .@"struct") {
        inline for (0..n) |i| try t.setInt(&s.heap, i + 1, try toLua(th, items[i]));
    } else {
        for (items, 1..) |item, i| try t.setInt(&s.heap, @intCast(i), try toLua(th, item));
    }
    return .table(t);
}

// ---------------------------------------------------------------------------
// Lua to Zig
// ---------------------------------------------------------------------------

/// `v` as a `T` when it already has `T`'s Lua type, with no conversion
/// and nothing that can fail; null when it needs the full `decodeAny`.
/// Inlined where a value is decoded, so the common cases cost a tag check.
inline fn decodeFast(comptime T: type, v: IValue) ?T {
    switch (T) {
        Value => return .{ .raw = v },
        Table => if (v.isTable()) return .{ .raw = v.asTable() },
        Function => if (v.isFunction()) return .{ .raw = v },
        Coroutine => if (v.typeOf() == .thread) return .{ .raw = v.asThread() },
        bool => return !v.isFalsy(),
        []const u8 => if (v.isString()) return v.asString().bytes(),
        [:0]const u8 => if (v.isString()) return v.asString().bytesZ(),
        else => switch (@typeInfo(T)) {
            .int => if (v.isInt()) {
                if (T == i64) return v.asInt();
                if (std.math.cast(T, v.asInt())) |i| return i;
            },
            .float => {
                if (v.isFloat()) return @floatCast(v.asFloat());
                if (v.isInt()) return @floatFromInt(v.asInt());
            },
            .optional => |o| {
                if (v.isNil()) return @as(T, null);
                if (decodeFast(o.child, v)) |x| return @as(T, x);
            },
            else => {},
        },
    }
    return null;
}

/// Where a value being decoded came from, for messages.
const Ctx = union(enum) {
    /// Argument `n` of the running Zig function, in stack slot `slot`:
    /// "bad argument #n to 'f' (...)".
    arg: struct { n: u32, slot: u32 },
    global: []const u8,
    result: u32,
    value,
};

/// One step of the path to the value being decoded inside the outer one,
/// a field name or a sequence index, linked on the Zig stack so a
/// successful decode never builds the path's text.
const Crumb = struct {
    parent: ?*const Crumb,
    name: []const u8 = "",
    index: usize = 0,

    /// The path from the root as "a.b[2]", into `buf`.
    fn write(c: *const Crumb, buf: []u8) []const u8 {
        var steps: [16]*const Crumb = undefined;
        var n: usize = 0;
        var it: ?*const Crumb = c;
        while (it) |x| : (it = x.parent) {
            if (n == steps.len) break;
            steps[n] = x;
            n += 1;
        }
        var w: std.Io.Writer = .fixed(buf);
        while (n > 0) {
            n -= 1;
            const x = steps[n];
            const dot = if (x.parent != null and x.name.len > 0) "." else "";
            if (x.name.len > 0) {
                w.print("{s}{s}", .{ dot, x.name }) catch break;
            } else {
                w.print("[{d}]", .{x.index}) catch break;
            }
        }
        return w.buffered();
    }

    /// A root step for key `k` of any type.
    fn ofKey(k: IValue) Crumb {
        if (k.isString()) return .{ .parent = null, .name = k.asString().bytes() };
        if (k.isInt()) return .{ .parent = null, .index = @intCast(@max(k.asInt(), 0)) };
        return .{ .parent = null, .name = "?" };
    }
};

const Decoder = struct {
    th: *Thread,
    ctx: Ctx,
    path: ?*const Crumb = null,
    /// Where `decodeAlloc` copies strings and allocates slices.
    gpa: ?std.mem.Allocator = null,
    /// `DecodeOptions.unknown_keys` is `.reject`.
    reject: bool = false,

    /// Key `k` of the table being read as a struct names no field.
    fn unknownKey(d: *Decoder, k: IValue) Error {
        @branchHint(.cold);
        var c: Crumb = .ofKey(k);
        c.parent = d.path;
        var pbuf: [96]u8 = undefined;
        const path = c.write(&pbuf);
        d.path = null;
        return d.fail("unknown key '{s}'", .{path});
    }

    fn fail(d: *Decoder, comptime fmt: []const u8, args: anytype) Error {
        @branchHint(.cold);
        var pbuf: [96]u8 = undefined;
        var buf: [256]u8 = undefined;
        const prefix = if (d.path) |c|
            std.mem.print(&buf, "field '{s}': ", .{c.write(&pbuf)}) catch ""
        else
            "";
        const rest = buf[prefix.len..];
        const msg = buf[0 .. prefix.len + (std.mem.print(rest, fmt, args) catch rest).len];
        const th = d.th;
        if (th.frames.items.len == 1) extraOf(th.state).trace.clearRetainingCapacity();
        return mapError(switch (d.ctx) {
            .arg => |a| debuginfo.argError(th, a.n, "?", msg),
            .global => |name| debuginfo.raise(th, "global '{s}': {s}", .{ name, msg }),
            .result => |n| debuginfo.raise(th, "result #{d}: {s}", .{ n, msg }),
            .value => debuginfo.raise(th, "{s}", .{msg}),
        });
    }

    fn typeError(d: *Decoder, expected: []const u8, v: ?IValue) Error {
        @branchHint(.cold);
        const got = if (v) |x| auxlib.typeName(d.th.state, x) else "no value";
        return d.fail("{s} expected, got {s}", .{ expected, got });
    }

    /// The argument's stack slot, when the value is the argument itself
    /// and not a field of it.
    inline fn atArg(d: *const Decoder) ?u32 {
        return switch (d.ctx) {
            .arg => |a| if (d.path == null) a.slot else null,
            else => null,
        };
    }

    /// `decodeAny` one step down, at field `name` or index `index`.
    inline fn child(d: *Decoder, comptime T: type, comptime alloc: bool, v: IValue, key: []const u8, i: usize) Error!T {
        if (decodeFast(T, v)) |x| return x;
        const crumb: Crumb = .{ .parent = d.path, .name = key, .index = i };
        d.path = &crumb;
        defer d.path = crumb.parent;
        return decodeAny(T, alloc, d, v);
    }
};

/// Argument `n` of a Zig function whose arguments are `stack[b..top]`.
inline fn checkArg(comptime T: type, th: *Thread, b: u32, top: u32, n: u32) Error!T {
    const slot = b + n - 1;
    if (slot < top) {
        // Handles test the slot and copy it, with no optional between:
        // building one from narrow stores and reading it back whole
        // stalls on store forwarding.
        const v = &th.stack[slot];
        switch (T) {
            Function => if (v.isFunction()) return .{ .raw = v.* },
            Table => if (v.isTable()) return .{ .raw = v.asTable() },
            Value => return .{ .raw = v.* },
            else => if (decodeFast(T, v.*)) |x| return x,
        }
    }
    return checkArgSlow(T, th, top, n, slot);
}

fn checkArgSlow(comptime T: type, th: *Thread, top: u32, n: u32, slot: u32) Error!T {
    var d: Decoder = .{ .th = th, .ctx = .{ .arg = .{ .n = n, .slot = slot } } };
    return decodeAny(T, false, &d, if (slot < top) th.stack[slot] else null);
}

/// The `n` values at `vals` as `R`, missing ones nil; decoding errors are
/// raised on `th`.
inline fn results(comptime R: type, th: *Thread, vals: [*]const IValue, n: u32) Error!R {
    if (R == void) return;
    if (R == Values) return @as([*]const Value, @ptrCast(vals))[0..n];
    if (@typeInfo(R) == .@"struct" and @typeInfo(R).@"struct".is_tuple) {
        var r: R = undefined;
        const st = @typeInfo(R).@"struct";
        inline for (st.field_names, st.field_types, 0..) |name, F, i| {
            @field(r, name) = try result(F, th, if (i < n) vals[i] else .nil, i + 1);
        }
        return r;
    }
    return result(R, th, if (n > 0) vals[0] else .nil, 1);
}

inline fn result(comptime T: type, th: *Thread, v: IValue, n: u32) Error!T {
    if (decodeFast(T, v)) |x| return x;
    return resultSlow(T, th, v, n);
}

fn resultSlow(comptime T: type, th: *Thread, v: IValue, n: u32) Error!T {
    var d: Decoder = .{ .th = th, .ctx = .{ .result = n } };
    return decodeAny(T, false, &d, v);
}

/// How many results a call returning `R` asks for; -1 for all.
fn resultCount(comptime R: type) i16 {
    if (R == void) return 0;
    if (R == Values) return -1;
    if (@typeInfo(R) == .@"struct" and @typeInfo(R).@"struct".is_tuple) return @typeInfo(R).@"struct".field_names.len;
    return 1;
}

/// The name messages use for a userdata type.
fn userdataName(comptime T: type) []const u8 {
    if (comptime hasSpec(T, "name")) return T.lua_userdata.name;
    const full = @typeName(T);
    return full[if (std.mem.findScalarLast(u8, full, '.')) |i| i + 1 else 0..];
}

/// Whether `T.lua_userdata` gives `field`.
fn hasSpec(comptime T: type, comptime field: []const u8) bool {
    if (!@hasDecl(T, "lua_userdata")) return false;
    return @hasField(@TypeOf(T.lua_userdata), field);
}

/// The next userdata type number; every state uses the same numbers.
var next_type_id: std.atomic.Value(u32) = .init(1);

/// `T`'s number, from 1: its metatable's index in `Extra.types`, so
/// finding it is an array access.
inline fn typeId(comptime T: type) u32 {
    const S = struct {
        var id: std.atomic.Value(u32) = .init(0);
        comptime {
            _ = T;
        }
    };
    const id = S.id.load(.monotonic);
    return if (id != 0) id else newTypeId(&S.id);
}

fn newTypeId(slot: *std.atomic.Value(u32)) u32 {
    @branchHint(.cold);
    const id = next_type_id.fetchAdd(1, .monotonic);
    return slot.cmpxchgStrong(0, id, .monotonic, .monotonic) orelse id;
}

fn metatableFor(th: *Thread, comptime T: type) Error!*ITable {
    const id = typeId(T);
    const v = extraOf(th.state).types.getInt(id);
    if (v.isTable()) return v.asTable();
    return newMetatable(th, T, id);
}

fn newMetatable(th: *Thread, comptime T: type, id: u32) Error!*ITable {
    @branchHint(.cold);
    const s = th.state;
    const mt = try s.newTable(0, 4);
    try mt.setStr(&s.heap, s.name_key, .string(try s.newString(userdataName(T))));
    if (comptime hasSpec(T, "methods")) {
        const methods = T.lua_userdata.methods;
        const names = @typeInfo(@TypeOf(methods)).@"struct".field_names;
        const t = try s.newTable(0, names.len);
        inline for (names) |name| try t.setStr(&s.heap, try s.newString(name), try toLua(th, @field(methods, name)));
        try mt.setStr(&s.heap, s.tm_names[@backingInt(IState.Tm.index)], .table(t));
    }
    if (comptime hasSpec(T, "meta")) {
        const meta = T.lua_userdata.meta;
        inline for (@typeInfo(@TypeOf(meta)).@"struct".field_names) |name| {
            try mt.setStr(&s.heap, try s.newString(name), try toLua(th, @field(meta, name)));
        }
    }
    try extraOf(s).types.setInt(&s.heap, id, .table(mt));
    return mt;
}

/// The userdata `v` as a `*T`, or null when it is not one of `T`'s.
inline fn userdataOf(comptime T: type, th: *Thread, v: IValue) ?*T {
    if (v.typeOf() != .userdata) return null;
    const u = v.asUserdata();
    const mt = u.metatable orelse return null;
    const want = extraOf(th.state).types.getInt(typeId(T));
    if (!want.isTable() or want.asTable() != mt) return null;
    return @ptrCast(@alignCast(u.bytes().ptr));
}

/// `v` (null for an absent argument) as a `T`.
fn decodeAny(comptime T: type, comptime alloc: bool, d: *Decoder, v: ?IValue) Error!T {
    const th = d.th;
    switch (T) {
        Value => {
            if (v == null and d.atArg() != null) return d.fail("value expected", .{});
            return .{ .raw = v orelse .nil };
        },
        Table => {
            const x = v orelse return d.typeError("table", v);
            if (!x.isTable()) return d.typeError("table", v);
            return .{ .raw = x.asTable() };
        },
        Function => {
            const x = v orelse return d.typeError("function", v);
            if (!x.isFunction()) return d.typeError("function", v);
            return .{ .raw = x };
        },
        Coroutine => {
            const x = v orelse return d.typeError("thread", v);
            if (x.typeOf() != .thread) return d.typeError("thread", v);
            return .{ .raw = x.asThread() };
        },
        Ref => {
            const x = v orelse return .nil;
            if (x.isNil()) return .nil;
            return newRef(th, x);
        },
        *State, Args => @compileError(@typeName(T) ++ " is only a parameter of a Zig function"),
        else => {},
    }
    switch (@typeInfo(T)) {
        .bool => return if (v) |x| !x.isFalsy() else false,
        .optional => |o| {
            const x = v orelse return null;
            if (x.isNil()) return null;
            return try decodeAny(o.child, alloc, d, x);
        },
        .int => {
            const x = v orelse return d.typeError("number", v);
            const i = if (x.isInt()) x.asInt() else vm.toInteger(x) orelse {
                if (vm.toNumber(x) != null) return d.fail("number has no integer representation", .{});
                return d.typeError("number", v);
            };
            if (T == i64) return i;
            return std.math.cast(T, i) orelse d.fail("value out of range", .{});
        },
        .float => {
            const x = v orelse return d.typeError("number", v);
            if (x.isFloat()) return @floatCast(x.asFloat());
            const n = vm.toNumber(x) orelse return d.typeError("number", v);
            return @floatCast(n.asNumber());
        },
        .@"enum" => {
            const x = v orelse return d.typeError("string", v);
            if (!x.isString()) return d.typeError("string", v);
            const name = x.asString().bytes();
            return std.meta.stringToEnum(T, name) orelse d.fail("invalid option '{s}'", .{name});
        },
        .array => |a| {
            const t = try decodeAny(Table, alloc, d, v);
            var r: T = undefined;
            for (&r, 1..) |*e, i| e.* = try d.child(a.child, alloc, t.raw.getInt(@intCast(i)), "", i);
            return r;
        },
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) {
                if (!p.attrs.@"const" and !alloc)
                    @compileError("decoding " ++ @typeName(T) ++ " copies: use decodeAlloc, or []const u8");
                return decodeString(T, alloc, d, v, p.sentinel() != null);
            }
            if (p.size == .slice) {
                if (!alloc) @compileError("decoding " ++ @typeName(T) ++ " allocates: use decodeAlloc");
                const t = try decodeAny(Table, alloc, d, v);
                const n: usize = @intCast(t.raw.length());
                const r = try d.gpa.?.alloc(p.child, n);
                for (r, 1..) |*e, i| e.* = try d.child(p.child, alloc, t.raw.getInt(@intCast(i)), "", i);
                return r;
            }
            if (p.size == .one and p.child == anyopaque) {
                const x = v orelse return d.typeError("light userdata", v);
                if (x.typeOf() != .light_userdata or x.asLightUserdata() == null)
                    return d.typeError("light userdata", v);
                return @ptrCast(x.asLightUserdata().?);
            }
            if (p.size == .one) {
                const x = v orelse return d.typeError(userdataName(p.child), v);
                return userdataOf(p.child, th, x) orelse d.typeError(userdataName(p.child), v);
            }
            @compileError("cannot convert a Lua value to " ++ @typeName(T));
        },
        .@"struct" => |st| {
            const t = try decodeAny(Table, alloc, d, v);
            var r: T = undefined;
            if (st.is_tuple) {
                inline for (st.field_names, st.field_types, 1..) |name, F, i| {
                    @field(r, name) = try d.child(F, alloc, t.raw.getInt(i), "", i);
                }
                return r;
            }
            // Unknown keys first, so a misspelled field is reported as
            // that rather than as the field it was meant to be missing.
            if (d.reject) {
                var it = t.iterator();
                while (it.next()) |e| {
                    if (!isFieldName(T, e.key.raw)) return d.unknownKey(e.key.raw);
                }
            }
            inline for (st.field_names, st.field_types, st.field_attrs) |name, F, attrs| {
                const fv = t.raw.getStr(try th.state.newString(name));
                if (fv.isNil() and attrs.defaultValue(F) != null) {
                    @field(r, name) = attrs.defaultValue(F).?;
                } else {
                    @field(r, name) = try d.child(F, alloc, fv, name, 0);
                }
            }
            return r;
        },
        else => @compileError("cannot convert a Lua value to " ++ @typeName(T)),
    }
}

/// Whether `k` is the name of a field of struct `T`.
fn isFieldName(comptime T: type, k: IValue) bool {
    if (!k.isString()) return false;
    const name = k.asString().bytes();
    inline for (@typeInfo(T).@"struct".field_names) |f| {
        if (std.mem.eql(u8, f, name)) return true;
    }
    return false;
}

fn decodeString(comptime T: type, comptime alloc: bool, d: *Decoder, v: ?IValue, comptime z: bool) Error!T {
    const th = d.th;
    const x = v orelse return d.typeError("string", v);
    const s = if (x.isString()) x.asString() else blk: {
        if (!x.isNumber()) return d.typeError("string", v);
        // A number converts to a new string, which is anchored where Lua
        // can reach it: in the argument's slot, as `lua_tolstring` does,
        // or above a running Zig function's arguments.
        const s = try vm.numberToString(th.state, x);
        if (d.atArg()) |slot| {
            th.stack[slot] = .string(s);
        } else if (th.frames.items.len > 1) {
            try ensure(th, 1);
            th.push(.string(s));
        }
        break :blk s;
    };
    if (alloc) return if (z) d.gpa.?.dupeSentinel(u8, s.bytes(), 0) else d.gpa.?.dupe(u8, s.bytes());
    return if (z) s.bytesZ() else s.bytes();
}

// ---------------------------------------------------------------------------
// Zig functions as Lua functions
// ---------------------------------------------------------------------------

/// The native function for Zig function `f`. With a context type `C`
/// (not `void`), the native is a closure whose upvalue holds the context
/// (`State.function`), and `f` takes it first.
fn Native(comptime f: anytype, comptime C: type) type {
    const F = @TypeOf(f);
    const info = switch (@typeInfo(F)) {
        .@"fn" => |i| i,
        else => @compileError("expected a function, got " ++ @typeName(F)),
    };
    if (C != void and info.param_types.len == 0) @compileError("a function bound to a context takes it first");
    return struct {
        fn call(th: *Thread, b: u32) IError!u32 {
            const top = th.top;
            var args: std.meta.ArgsTuple(F) = undefined;
            comptime var n: u32 = 1;
            inline for (info.param_types, 0..) |p, i| {
                const P = p orelse @compileError("generic parameters are not supported");
                if (C != void and i == 0) {
                    args[0] = boundContext(P, C, th.stack[b - 1].asNativeClosure().upvalues()[0]);
                } else if (P == *State) {
                    args[i] = .of(th);
                } else if (P == Args) {
                    args[i] = .{ .th = th, .base = b, .top = top };
                } else {
                    args[i] = checkArg(P, th, b, top, n) catch |e| return toEngineError(th, e);
                    n += 1;
                }
            }
            const r = @call(.auto, f, args);
            const out = switch (@typeInfo(@TypeOf(r))) {
                .error_union => r catch |e| return toEngineError(th, e),
                else => r,
            };
            return pushResults(th, out);
        }
    };
}

/// Pushes a Zig function's result: nothing, a tuple's fields, or one
/// value. In the engine's errors, so its return needs no translation.
inline fn pushResults(th: *Thread, r: anytype) IError!u32 {
    const R = @TypeOf(r);
    if (R == void) return 0;
    if (R == Values) {
        try pushValues(th, r);
        return @intCast(r.len);
    }
    if (@typeInfo(R) == .@"struct" and @typeInfo(R).@"struct".is_tuple) {
        const n = @typeInfo(R).@"struct".field_names.len;
        try th.ensureStack(n);
        inline for (0..n) |i| th.push(try toLua(th, r[i]));
        return n;
    }
    try th.ensureStack(1);
    th.push(try toLua(th, r));
    return 1;
}

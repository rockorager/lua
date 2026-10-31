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
const vm = @import("vm.zig");
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
        return @as(IValue.Type, @enumFromInt(@intFromEnum(t))).name();
    }
};

comptime {
    for (@typeInfo(Type).@"enum".fields, @typeInfo(IValue.Type).@"enum".fields) |a, b| {
        std.debug.assert(std.mem.eql(u8, a.name, b.name) and a.value == b.value);
    }
}

/// Any Lua value, borrowed (see the file's comment). Convert it with
/// `State.decode`.
pub const Value = struct {
    /// The engine's representation; not part of the API.
    raw: IValue,

    pub const nil: Value = .{ .raw = .nil };

    pub inline fn typeOf(v: Value) Type {
        return @enumFromInt(@intFromEnum(v.raw.typeOf()));
    }

    pub inline fn isNil(v: Value) bool {
        return v.raw.isNil();
    }

    /// Lua's truth: false for `nil` and `false`, true for everything else.
    pub inline fn toBool(v: Value) bool {
        return !v.raw.isFalsy();
    }
};

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
    /// The environment for `os.getenv` and `package`'s paths; none when
    /// null. It must outlive the state.
    environ: ?*const std.process.Environ.Map = null,
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
        const libs = options.libs orelse if (options.io != null) Libs.initFull() else safe_libs;
        if (options.io == null and (libs.contains(.io) or libs.contains(.os)))
            @panic("lua: the io and os libraries need Options.io");
        extra.host.init(options.io orelse .failing);
        extra.host.environ = options.environ;
        const s = try IState.create(gpa, .{ .seed = options.seed, .strings = options.strings });
        errdefer s.destroy();
        extra.types = try s.newTable(0, 0);
        try s.registry.setStr(&s.heap, try s.newString("_ZIG_TYPES"), .table(extra.types));
        lib.openSome(s.main, &extra.host, libs) catch |e| return mapError(e);
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
        extra.trace.deinit(extra.gpa);
        extra.gpa.destroy(extra);
    }

    /// `Options.context`, as a `*T`.
    pub fn context(state: *State, comptime T: type) *T {
        return @ptrCast(@alignCast(extraOf(state.thread().state).context.?));
    }

    // -----------------------------------------------------------------
    // Chunks and calls
    // -----------------------------------------------------------------

    /// Compiles a chunk, or loads a binary one, into a function whose
    /// `_ENV` is the globals table, without running it.
    pub fn load(state: *State, source: []const u8, options: LoadOptions) Error!Function {
        const th = state.thread();
        const gpa = th.heap().allocator();
        const z = try gpa.dupeZ(u8, source);
        defer gpa.free(z);
        const f = base.loadChunk(th, z, options.name orelse source, modeString(options.mode)) catch |e|
            return loadError(th, e);
        return .{ .raw = f };
    }

    /// `load` for a file read through `Options.io`, named "@path".
    pub fn loadFile(state: *State, path: []const u8, mode: Mode) Error!Function {
        const th = state.thread();
        const f = base.loadFile(th, path, modeString(mode)) catch |e| return loadError(th, e);
        return .{ .raw = f };
    }

    /// Loads and runs a chunk, and returns its results as `R` (see `call`).
    pub fn doString(state: *State, comptime R: type, source: []const u8, options: LoadOptions) Error!R {
        return state.call(R, try state.load(source, options), .{});
    }

    /// Loads and runs a file, and returns its results as `R` (see `call`).
    pub fn doFile(state: *State, comptime R: type, path: []const u8, mode: Mode) Error!R {
        return state.call(R, try state.loadFile(path, mode), .{});
    }

    /// Calls `f`, any Lua value, with the tuple `args` converted to Lua
    /// values. `R` says what comes back: `void` for nothing, a tuple type
    /// for several results, or one type for one result, each converted
    /// as `decode` does.
    pub fn call(state: *State, comptime R: type, f: anytype, args: anytype) Error!R {
        const th = state.thread();
        const nres = comptime resultCount(R);
        try ensure(th, @typeInfo(@TypeOf(args)).@"struct".fields.len + 2);
        const bottom = th.top;
        defer th.top = bottom;
        if (th.frames.items.len == 1) {
            const extra = extraOf(th.state);
            if (extra.traceback) th.push(.native(&messageHandler));
            const func = th.top;
            try pushCall(th, f, args);
            extra.trace.clearRetainingCapacity();
            if (!vm.pcallMsgh(th, func, nres, if (extra.traceback) bottom else 0)) return protectedError(th, func);
            return results(R, th, func);
        }
        const func = th.top;
        try pushCall(th, f, args);
        vm.call(th, func, nres) catch |e| return mapError(e);
        return results(R, th, func);
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
    pub fn decode(state: *State, comptime T: type, x: anytype) Error!T {
        const th = state.thread();
        const v = try toLua(th, x);
        if (decodeFast(T, v)) |r| return r;
        var d: Decoder = .{ .th = th, .ctx = .value };
        return decodeAny(T, false, &d, v);
    }

    /// `decode`, copying strings into `gpa` and allocating slices from
    /// sequences. On error what was allocated so far is not freed: pass
    /// an arena.
    pub fn decodeAlloc(state: *State, comptime T: type, gpa: std.mem.Allocator, x: anytype) Error!T {
        const th = state.thread();
        var d: Decoder = .{ .th = th, .ctx = .value, .gpa = gpa };
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
        if (@intFromEnum(r) <= freelist) return;
        const s = state.thread().state;
        const i: i64 = @intFromEnum(r);
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
    return .{ .raw = .native(&Native(f).call) };
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
    if (th.frames.items.len == 1) extraOf(th.state).trace.clearRetainingCapacity();
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

/// Pushes `f` and the tuple `args` for a call.
inline fn pushCall(th: *Thread, f: anytype, args: anytype) error{OutOfMemory}!void {
    th.push(try toLua(th, f));
    inline for (@typeInfo(@TypeOf(args)).@"struct".fields) |field| th.push(try toLua(th, @field(args, field.name)));
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

/// Calls `func` from the top level in protected mode, `msgh` the message
/// handler's slot or 0. A failure leaves the error object in `th.err`.
fn protectedCall(th: *Thread, func: u32, nres: i16, msgh: u32) Error!void {
    extraOf(th.state).trace.clearRetainingCapacity();
    if (vm.pcallMsgh(th, func, nres, msgh)) return;
    return protectedError(th, func);
}

fn protectedError(th: *Thread, func: u32) Error {
    @branchHint(.cold);
    const err = th.stack[func];
    th.err = err;
    // `pcall` leaves the fixed memory-error string for allocation failure.
    if (err.isString() and err.asString() == th.state.memerr) return error.OutOfMemory;
    return error.Runtime;
}

/// The top level's message handler: records the message and a traceback
/// and leaves the error object as it is.
fn messageHandler(th: *Thread, b: u32) IError!u32 {
    const extra = extraOf(th.state);
    const v = th.stack[b];
    var buf: [128]u8 = undefined;
    const msg: []const u8 = if (v.isString())
        v.asString().bytes()
    else if (v.isNumber())
        vm.formatNumber(v, buf[0..number.max_len])
    else
        objectDescription(v);
    extra.trace.clearRetainingCapacity();
    var aw: std.Io.Writer.Allocating = .fromArrayList(extra.gpa, &extra.trace);
    defer extra.trace = aw.toArrayList();
    // Without memory for it the error goes on without a traceback.
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
    try protectedCall(th, func, 1, if (msgh) bottom else 0);
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
        if (th.state.fastTm(t.metatable, .newindex) == null or !t.get(k).isNil()) {
            return t.set(th.heap(), k, v) catch |e| switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                error.IndexIsNil => mapError(th.runError("table index is nil", .{})),
                error.IndexIsNaN => mapError(th.runError("table index is NaN", .{})),
            };
        }
    }
    return setIndexSlow(th, o, k, v);
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

/// The registry slot that heads the free list of references, `freelist`
/// in lauxlib.c; references start after it.
const freelist = 3;

fn newRef(th: *Thread, v: IValue) Error!Ref {
    const reg = th.state.registry;
    const heap = th.heap();
    var r: i64 = 0;
    const head = reg.getInt(freelist);
    if (head.isNil()) {
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
    return @enumFromInt(r);
}

inline fn refValue(th: *Thread, r: Ref) IValue {
    if (r == .nil) return .nil;
    return th.state.registry.getInt(@intFromEnum(r));
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
        .@"fn" => return .native(&Native(x).call),
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
            const t = try s.newTable(0, st.fields.len);
            inline for (st.fields) |f| {
                const fv = try toLua(th, @field(x, f.name));
                if (!fv.isNil()) try t.setStr(&s.heap, try s.newString(f.name), fv);
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

    fn fail(d: *Decoder, comptime fmt: []const u8, args: anytype) Error {
        @branchHint(.cold);
        var pbuf: [96]u8 = undefined;
        var buf: [256]u8 = undefined;
        const prefix = if (d.path) |c|
            std.fmt.bufPrint(&buf, "field '{s}': ", .{c.write(&pbuf)}) catch ""
        else
            "";
        const rest = buf[prefix.len..];
        const msg = buf[0 .. prefix.len + (std.fmt.bufPrint(rest, fmt, args) catch rest).len];
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

/// The results of a call at `func` as `R`.
inline fn results(comptime R: type, th: *Thread, func: u32) Error!R {
    if (R == void) return;
    if (@typeInfo(R) == .@"struct" and @typeInfo(R).@"struct".is_tuple) {
        var r: R = undefined;
        inline for (@typeInfo(R).@"struct".fields, 0..) |f, i| {
            @field(r, f.name) = try result(f.type, th, func + @as(u32, i), i + 1);
        }
        return r;
    }
    return result(R, th, func, 1);
}

inline fn result(comptime T: type, th: *Thread, slot: u32, n: u32) Error!T {
    if (decodeFast(T, th.stack[slot])) |x| return x;
    return resultSlow(T, th, slot, n);
}

fn resultSlow(comptime T: type, th: *Thread, slot: u32, n: u32) Error!T {
    var d: Decoder = .{ .th = th, .ctx = .{ .result = n } };
    return decodeAny(T, false, &d, th.stack[slot]);
}

fn resultCount(comptime R: type) i16 {
    if (R == void) return 0;
    if (@typeInfo(R) == .@"struct" and @typeInfo(R).@"struct".is_tuple) return @typeInfo(R).@"struct".fields.len;
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
        const names = comptime std.meta.fieldNames(@TypeOf(methods));
        const t = try s.newTable(0, names.len);
        inline for (names) |name| try t.setStr(&s.heap, try s.newString(name), try toLua(th, @field(methods, name)));
        try mt.setStr(&s.heap, s.tm_names[@intFromEnum(IState.Tm.index)], .table(t));
    }
    if (comptime hasSpec(T, "meta")) {
        const meta = T.lua_userdata.meta;
        inline for (comptime std.meta.fieldNames(@TypeOf(meta))) |name| {
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
                if (!p.is_const and !alloc)
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
                inline for (st.fields, 1..) |f, i| {
                    @field(r, f.name) = try d.child(f.type, alloc, t.raw.getInt(i), "", i);
                }
                return r;
            }
            inline for (st.fields) |f| {
                const fv = t.raw.getStr(try th.state.newString(f.name));
                if (fv.isNil() and f.defaultValue() != null) {
                    @field(r, f.name) = f.defaultValue().?;
                } else {
                    @field(r, f.name) = try d.child(f.type, alloc, fv, f.name, 0);
                }
            }
            return r;
        },
        else => @compileError("cannot convert a Lua value to " ++ @typeName(T)),
    }
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
    if (alloc) return if (z) d.gpa.?.dupeZ(u8, s.bytes()) else d.gpa.?.dupe(u8, s.bytes());
    return if (z) s.bytesZ() else s.bytes();
}

// ---------------------------------------------------------------------------
// Zig functions as Lua functions
// ---------------------------------------------------------------------------

fn Native(comptime f: anytype) type {
    const F = @TypeOf(f);
    const info = switch (@typeInfo(F)) {
        .@"fn" => |i| i,
        else => @compileError("expected a function, got " ++ @typeName(F)),
    };
    return struct {
        fn call(th: *Thread, b: u32) IError!u32 {
            const top = th.top;
            var args: std.meta.ArgsTuple(F) = undefined;
            comptime var n: u32 = 1;
            inline for (info.params, 0..) |p, i| {
                const P = p.type orelse @compileError("generic parameters are not supported");
                if (P == *State) {
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
    if (@typeInfo(R) == .@"struct" and @typeInfo(R).@"struct".is_tuple) {
        const n = @typeInfo(R).@"struct".fields.len;
        try th.ensureStack(n);
        inline for (0..n) |i| th.push(try toLua(th, r[i]));
        return n;
    }
    try th.ensureStack(1);
    th.push(try toLua(th, r));
    return 1;
}

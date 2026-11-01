//! Lua 5.5.1's C API, `lua.h`, for compiled C modules: built only with
//! `-Dc-api=true` (docs/slop/c-api.md has the design and its proofs).
//!
//! A `lua_State *` is the `*Thread` itself, so no API call translates
//! it; C-API builds keep `Thread.prefix_len` bytes in front of every
//! thread for this file's data and `lua_getextraspace`.
//!
//! A C function is an ordinary native closure whose `f` is `trampoline`
//! and whose `cfn` is the C function: the interpreter calls it like any
//! Zig native and knows nothing of C. The trampoline makes a protected
//! call (`jmp.call`); an API function that fails catches the Zig error
//! and `throw`s it, which jumps back to the innermost trampoline, where
//! it becomes the same Zig error again. Between a trampoline and a
//! `throw` sit only C frames and the one API function, which has no
//! pending `defer` when it throws.

const std = @import("std");
const Value = @import("../Value.zig");
const String = @import("../String.zig");
const Table = @import("../Table.zig");
const Thread = @import("../Thread.zig");
const State = @import("../State.zig");
const Proto = @import("../Proto.zig");
const Userdata = @import("../Userdata.zig");
const gc = @import("../gc.zig");
const vm = @import("../vm.zig");
const number = @import("../number.zig");
const debuginfo = @import("../debuginfo.zig");
const aux = @import("../lib/auxlib.zig");
const base = @import("../lib/base.zig");
const debug = @import("../lib/debug.zig");
const dump = @import("../dump.zig");
const jmp = @import("jmp.zig");
const va = @import("va.zig");

const lauxlib = @import("lauxlib.zig");
const state_mod = @import("state.zig");

comptime {
    _ = lauxlib;
    _ = state_mod;
}

test {
    _ = @import("unwind.zig");
}

const Error = Value.Error;
const Frame = Thread.Frame;

pub const lua_State = Thread;
pub const lua_CFunction = *const fn (*lua_State) callconv(.c) c_int;
pub const lua_KFunction = *const fn (*lua_State, c_int, lua_KContext) callconv(.c) c_int;
pub const lua_KContext = isize;
pub const lua_Reader = *const fn (*lua_State, ?*anyopaque, *usize) callconv(.c) ?[*]const u8;
pub const lua_Alloc = *const fn (?*anyopaque, ?*anyopaque, usize, usize) callconv(.c) ?*anyopaque;
pub const lua_Writer = *const fn (*lua_State, ?*const anyopaque, usize, ?*anyopaque) callconv(.c) c_int;
pub const lua_WarnFunction = *const fn (?*anyopaque, [*:0]const u8, c_int) callconv(.c) void;
pub const lua_Hook = *const fn (*lua_State, *lua_Debug) callconv(.c) void;
pub const lua_Number = f64;
pub const lua_Integer = i64;
pub const lua_Unsigned = u64;

/// `LUA_REGISTRYINDEX`, `-(INT_MAX/2 + 1000)`; upvalue `i` is this minus `i`.
pub const registry_index: c_int = -(std.math.maxInt(c_int) / 2 + 1000);

pub const lua_ok = 0;
pub const lua_yield = 1;
pub const lua_errrun = 2;
pub const lua_errsyntax = 3;
pub const lua_errmem = 4;
pub const lua_errerr = 5;
pub const lua_tnone = -1;

comptime {
    // lua.h's type codes are `Value.Type`'s order.
    std.debug.assert(@intFromEnum(Value.Type.thread) == 8);
    std.debug.assert(@intFromEnum(Value.Type.light_userdata) == 2);
}

// ---------------------------------------------------------------------------
// Per-thread data, in front of the thread
// ---------------------------------------------------------------------------

/// A C continuation and its context, for the native frame at the same
/// index in `Thread.frames`.
const KRec = struct { k: lua_KFunction, ctx: lua_KContext };

pub const ThreadData = struct {
    /// C continuations by frame index; `cK` reads them.
    ks: std.ArrayList(KRec) = .empty,
    /// The rest is the main thread's, for the whole state. Light C
    /// functions by address, so pushing one twice gives the same
    /// function, as in the reference. The registry holds the table.
    cfuncs: ?*Table = null,
    /// `lua_setwarnf`'s function and its data.
    warnf: ?lua_WarnFunction = null,
    warn_ud: ?*anyopaque = null,
    /// `lua_atpanic`'s function.
    panicf: ?lua_CFunction = null,
    /// What `lua_setallocf` gave a state the Zig API made, which keeps
    /// its own allocator (docs/slop/c-api.md).
    allocf: ?lua_Alloc = null,
    alloc_ud: ?*anyopaque = null,
    /// The metatable of `Box`es. The registry holds it.
    box_mt: ?*Table = null,
};

/// The thread's C hook, `lua_sethook`'s function, first in its prefix.
inline fn hookSlot(th: *const Thread) *?lua_Hook {
    return @ptrFromInt(@intFromPtr(th) - Thread.prefix_len);
}

inline fn dataSlot(th: *const Thread) *?*ThreadData {
    return @ptrFromInt(@intFromPtr(th) - Thread.prefix_len + @sizeOf(usize));
}

/// A new coroutine's C hook, its creator's (`Thread.inheritHook`).
pub fn inheritHook(th: *Thread, from: *const Thread) void {
    hookSlot(th).* = hookSlot(from).*;
}

pub fn threadData(th: *Thread) error{OutOfMemory}!*ThreadData {
    if (dataSlot(th).*) |d| return d;
    const d = try th.heap().allocator().create(ThreadData);
    d.* = .{};
    dataSlot(th).* = d;
    return d;
}

/// Frees what this file keeps for a thread; `Thread.destroy` calls it.
pub fn deinitThread(h: *gc.Heap, th: *Thread) void {
    const d = dataSlot(th).* orelse return;
    d.ks.deinit(h.allocator());
    h.allocator().destroy(d);
}

// ---------------------------------------------------------------------------
// Protected calls into C, and errors out of C
// ---------------------------------------------------------------------------

/// One protected call into C in progress: where `throw` jumps.
const Catch = struct {
    regs: jmp.Regs = .{},
    prev: ?*Catch,
    th: *Thread,
};

/// The innermost protected call into C on this OS thread. A coroutine
/// resumed from C runs its C functions deeper on the same native stack,
/// so the innermost is always the right target, whatever Lua thread
/// raises.
threadlocal var current: ?*Catch = null;

/// The native body of every C function.
fn trampoline(th: *Thread, b: u32) Error!u32 {
    const cl = th.stack[b - 1].asNativeClosure();
    const r = protect(th, cl.cfn.?, 0, 0);
    // One compare for the common case, `aborted` included.
    if (r > th.top - b) {
        failure.r = r;
        return failed(th, b);
    }
    if (th.tbc.items.len != 0) return closeReturn(th, b, @intCast(r));
    return @intCast(r);
}

/// A C function returned `n` results: closes the to-be-closed slots it
/// marked with `lua_toclose`, its `__close` calls above the results, as
/// `luaD_poscall` does for `CIST_TBC`. Yields in those calls are not
/// supported.
noinline fn closeReturn(th: *Thread, b: u32, n: u32) Error!u32 {
    @branchHint(.cold);
    if (th.tbc.items[th.tbc.items.len - 1] >= b) try vm.closeLevel(th, b, .ktop, false);
    return n;
}

/// Calls `f(th, a1, a2)` protected: its `int` result, or `jmp.aborted`
/// with the error in `failure.err`.
inline fn protect(th: *Thread, f: *const anyopaque, a1: usize, a2: usize) u64 {
    var c: Catch = .{ .prev = current, .th = th };
    current = &c;
    const r = jmp.call(&c.regs, f, @intFromPtr(th), a1, a2);
    current = c.prev;
    return r;
}

/// A protected call that did not return a count of results on top:
/// what `failed` reports, set by `throw` and the caller.
threadlocal var failure: struct { r: u64, err: Error } = undefined;

/// The error a protected call into C ended with.
inline fn failed(th: *Thread, _: u32) Error!u32 {
    @branchHint(.cold);
    if (failure.r == jmp.aborted) return failure.err;
    return th.runError("C function returned more results than it pushed", .{});
}

/// The continuation of every native frame that called `lua_callk`,
/// `lua_pcallk`, or `lua_yieldk` with one: runs the C continuation
/// recorded for its frame, protected like the function.
fn cK(th: *Thread, b: u32, status: Value.KStatus, ctx: u32) Error!u32 {
    const rec = dataSlot(th).*.?.ks.items[ctx];
    const st: c_int = switch (status) {
        .ok => lua_ok,
        .yield => lua_yield,
        .err => lua_errrun,
    };
    const r = protect(th, rec.k, @as(u32, @bitCast(st)), @bitCast(rec.ctx));
    if (r > th.top - b) {
        failure.r = r;
        return failed(th, b);
    }
    if (th.tbc.items.len != 0) return closeReturn(th, b, @intCast(r));
    return @intCast(r);
}

/// Records continuation `k` for the running native frame and returns
/// the frame's index, the context `cK` gets.
fn setK(th: *Thread, k: lua_KFunction, ctx: lua_KContext) error{OutOfMemory}!u32 {
    const idx = th.frames.items.len - 1;
    const d = try threadData(th);
    const gpa = th.heap().allocator();
    if (d.ks.items.len <= idx) try d.ks.appendNTimes(gpa, undefined, idx + 1 - d.ks.items.len);
    d.ks.items[idx] = .{ .k = k, .ctx = ctx };
    return @intCast(idx);
}

/// Raises `e` out of the running API function: jumps to the innermost
/// protected call into C, which returns `e`. An error raised on another
/// thread than that call's moves its error object there first.
pub fn throw(th: *Thread, e: Error) noreturn {
    @branchHint(.cold);
    const c = current orelse unprotected(th, e);
    // A protected call into another state's C function cannot catch it.
    if (c.th.state != th.state) unprotected(th, e);
    if (c.th != th and e == error.LuaError and th.status != .yield) {
        c.th.err = th.err;
        th.err = .nil;
    }
    failure.err = e;
    jmp.jump(&c.regs);
}

/// An error with no protected call to catch it: the panic function, then
/// abort, as `luaD_throw` does. A state from `lua_newstate` without a
/// panic function aborts silently, as the reference's does; the others
/// say why.
fn unprotected(th: *Thread, e: Error) noreturn {
    const d = dataSlot(th.state.main).*;
    if (d) |data| if (data.panicf) |f| {
        if (e == error.LuaError) th.push(th.err) else th.push(.string(th.state.memerr));
        _ = f(th);
        std.process.abort();
    };
    if (state_mod.of(th.state) != null) std.process.abort();
    const msg = if (e == error.OutOfMemory)
        "not enough memory"
    else if (th.err.isString())
        th.err.asString().bytes()
    else
        "error object is not a string";
    // Written directly: `std.debug.print` goes through std's debug `Io`,
    // whose table keeps all of `std.Io.Threaded` in the executable.
    const prefix = "PANIC: unprotected error in call to Lua API (";
    _ = std.c.write(2, prefix, prefix.len);
    _ = std.c.write(2, msg.ptr, msg.len);
    _ = std.c.write(2, ")\n", 2);
    std.process.abort();
}

pub inline fn check(th: *Thread, r: anytype) @typeInfo(@TypeOf(r)).error_union.payload {
    return r catch |e| throw(th, e);
}

fn statusCode(s: vm.Status) c_int {
    return switch (s) {
        .ok => lua_ok,
        .runtime => lua_errrun,
        .memory => lua_errmem,
        .handler => lua_errerr,
    };
}

// ---------------------------------------------------------------------------
// Indices
// ---------------------------------------------------------------------------

inline fn funcSlot(th: *Thread) u32 {
    return th.frame().func;
}

/// The stack slot of a stack index (not a pseudo-index).
inline fn slotOf(th: *Thread, idx: c_int) u32 {
    if (idx > 0) return funcSlot(th) + @as(u32, @intCast(idx));
    return th.top - @as(u32, @intCast(-idx));
}

inline fn isPseudo(idx: c_int) bool {
    return idx <= registry_index;
}

/// The value at an acceptable index, or null for none.
/// The value at an index, or null for a non-valid one. A pointer, not a
/// `?Value`: returned through memory, that cost a store-forwarding stall
/// on every load of its fields (docs/slop/results/capi-full-20261031.md).
/// The registry's comes from a per-thread scratch slot.
fn at(th: *Thread, idx: c_int) ?*const Value {
    if (idx > 0) {
        const i = funcSlot(th) + @as(u32, @intCast(idx));
        return if (i < th.top) &th.stack[i] else null;
    }
    if (!isPseudo(idx)) return &th.stack[th.top - @as(u32, @intCast(-idx))];
    if (idx == registry_index) {
        registry_scratch = .table(th.state.registry);
        return &registry_scratch;
    }
    const n: u32 = @intCast(registry_index - idx);
    const f = th.stack[funcSlot(th)];
    if (f.tag != .native_closure) return null;
    const ups = f.asNativeClosure().upvalues();
    return if (n <= ups.len) &ups[n - 1] else null;
}

threadlocal var registry_scratch: Value = .nil;

inline fn get(th: *Thread, idx: c_int) Value {
    return if (at(th, idx)) |p| p.* else .nil;
}

/// Stores `v` at a valid index, an upvalue with its barrier.
fn set(th: *Thread, idx: c_int, v: Value) void {
    if (!isPseudo(idx)) {
        th.stack[slotOf(th, idx)] = v;
    } else if (idx != registry_index) {
        const n: u32 = @intCast(registry_index - idx);
        th.stack[funcSlot(th)].asNativeClosure().setUpvalue(th.heap(), n - 1, v);
    }
}

inline fn push(th: *Thread, v: Value) void {
    th.stack[th.top] = v;
    th.top += 1;
}

inline fn top(th: *Thread, n: u32) Value {
    return th.stack[th.top - n];
}

fn typeCode(v: ?*const Value) c_int {
    return if (v) |x| @intFromEnum(x.typeOf()) else lua_tnone;
}

/// A NUL-terminated C string as a slice.
pub inline fn span(s: [*:0]const u8) []const u8 {
    return std.mem.span(s);
}

fn newString(th: *Thread, b: []const u8) *String {
    return check(th, th.state.newString(b));
}

// ---------------------------------------------------------------------------
// State manipulation
// ---------------------------------------------------------------------------

pub fn luaNewthread(L: *lua_State) callconv(.c) *lua_State {
    const co = check(L, Thread.create(L.state));
    push(L, .thread(co));
    co.inheritHook(L);
    const dst: [*]u8 = @ptrFromInt(@intFromPtr(co) - @sizeOf(usize));
    const src: [*]const u8 = @ptrFromInt(@intFromPtr(L.state.main) - @sizeOf(usize));
    @memcpy(dst[0..@sizeOf(usize)], src[0..@sizeOf(usize)]);
    return co;
}

pub fn luaClosethread(L: *lua_State, from: ?*lua_State) callconv(.c) c_int {
    return statusCode(vm.closeThread(L, from));
}

pub fn luaAtpanic(L: *lua_State, f: ?lua_CFunction) callconv(.c) ?lua_CFunction {
    const d = check(L, threadData(L.state.main));
    const old = d.panicf;
    d.panicf = f;
    return old;
}

pub fn luaVersion(L: *lua_State) callconv(.c) lua_Number {
    _ = L;
    return 505;
}

// ---------------------------------------------------------------------------
// Basic stack manipulation
// ---------------------------------------------------------------------------

pub fn luaAbsindex(L: *lua_State, idx: c_int) callconv(.c) c_int {
    if (idx > 0 or isPseudo(idx)) return idx;
    return @intCast(@as(i64, L.top) + idx - funcSlot(L));
}

pub fn luaGettop(L: *lua_State) callconv(.c) c_int {
    return @intCast(L.top - (funcSlot(L) + 1));
}

pub fn luaSettop(L: *lua_State, idx: c_int) callconv(.c) void {
    const new = if (idx >= 0) funcSlot(L) + 1 + @as(u32, @intCast(idx)) else L.top - @as(u32, @intCast(-idx - 1));
    while (L.top < new) push(L, .nil);
    // Popping a slot `lua_toclose` marked closes it first.
    if (L.tbc.items.len != 0 and L.tbc.items[L.tbc.items.len - 1] >= new) check(L, vm.closeLevel(L, new, .ktop, false));
    L.top = new;
}

pub fn luaToclose(L: *lua_State, idx: c_int) callconv(.c) void {
    const level = slotOf(L, idx);
    const v = L.stack[level];
    // False and nil need no closing (`luaF_newtbcupval`).
    if (v.isFalsy()) return;
    if (L.state.tmOf(v, .close) == null) {
        const i = L.frames.items.len - 1;
        const name = if (debug.findLocal(L, i, level - funcSlot(L))) |loc| loc[0] else "?";
        throw(L, L.runError("variable '{s}' got a non-closable value", .{name}));
    }
    check(L, L.tbc.append(L.heap().allocator(), level));
}

pub fn luaCloseslot(L: *lua_State, idx: c_int) callconv(.c) void {
    const level = slotOf(L, idx);
    check(L, vm.closeLevel(L, level, .ktop, false));
    L.stack[level] = .nil;
}

pub fn luaPushvalue(L: *lua_State, idx: c_int) callconv(.c) void {
    push(L, get(L, idx));
}

fn reverse(s: []Value) void {
    std.mem.reverse(Value, s);
}

pub fn luaRotate(L: *lua_State, idx: c_int, n: c_int) callconv(.c) void {
    const first = slotOf(L, idx);
    const s = L.stack[first..L.top];
    const len: i64 = @intCast(s.len);
    const m: usize = @intCast(if (n >= 0) len - n else -@as(i64, n));
    reverse(s[0..m]);
    reverse(s[m..]);
    reverse(s);
}

pub fn luaCopy(L: *lua_State, from: c_int, to: c_int) callconv(.c) void {
    set(L, to, get(L, from));
}

pub fn luaCheckstack(L: *lua_State, n: c_int) callconv(.c) c_int {
    const want: u32 = @intCast(@max(n, 0));
    const ok = check(L, vm.checkStack(L, want));
    if (!ok) return 0;
    const f = L.frame();
    if (f.top < L.top + want) f.top = L.top + want;
    return 1;
}

pub fn luaXmove(from: *lua_State, to: *lua_State, n: c_int) callconv(.c) void {
    if (from == to) return;
    const k: u32 = @intCast(n);
    from.top -= k;
    for (from.stack[from.top..][0..k]) |v| push(to, v);
}

// ---------------------------------------------------------------------------
// Access functions (stack -> C)
// ---------------------------------------------------------------------------

pub fn luaIsnumber(L: *lua_State, idx: c_int) callconv(.c) c_int {
    return @intFromBool(vm.toNumber(get(L, idx)) != null);
}

pub fn luaIsstring(L: *lua_State, idx: c_int) callconv(.c) c_int {
    const v = get(L, idx);
    return @intFromBool(v.isString() or v.isNumber());
}

pub fn luaIscfunction(L: *lua_State, idx: c_int) callconv(.c) c_int {
    const v = get(L, idx);
    return @intFromBool(v.tag == .native_fn or v.tag == .native_closure);
}

pub fn luaIsinteger(L: *lua_State, idx: c_int) callconv(.c) c_int {
    return @intFromBool(get(L, idx).tag == .int);
}

pub fn luaIsuserdata(L: *lua_State, idx: c_int) callconv(.c) c_int {
    const v = get(L, idx);
    return @intFromBool(v.tag == .userdata or v.tag == .light_userdata);
}

pub fn luaType(L: *lua_State, idx: c_int) callconv(.c) c_int {
    return typeCode(at(L, idx));
}

const type_names = [_][*:0]const u8{
    "no value", "nil",   "boolean",  "userdata", "number",
    "string",   "table", "function", "userdata", "thread",
};

pub fn luaTypename(L: *lua_State, t: c_int) callconv(.c) [*:0]const u8 {
    _ = L;
    return type_names[@intCast(t + 1)];
}

pub fn luaTonumberx(L: *lua_State, idx: c_int, isnum: ?*c_int) callconv(.c) lua_Number {
    const n = vm.toNumber(get(L, idx));
    if (isnum) |p| p.* = @intFromBool(n != null);
    return if (n) |v| v.asNumber() else 0;
}

pub fn luaTointegerx(L: *lua_State, idx: c_int, isnum: ?*c_int) callconv(.c) lua_Integer {
    const v = get(L, idx);
    const i: ?i64 = if (v.tag == .int) v.payload.int else vm.toInteger(v);
    if (isnum) |p| p.* = @intFromBool(i != null);
    return i orelse 0;
}

pub fn luaToboolean(L: *lua_State, idx: c_int) callconv(.c) c_int {
    return @intFromBool(!get(L, idx).isFalsy());
}

pub fn luaTolstring(L: *lua_State, idx: c_int, len: ?*usize) callconv(.c) ?[*:0]const u8 {
    var v = get(L, idx);
    if (!v.isString()) {
        if (!v.isNumber()) {
            if (len) |p| p.* = 0;
            return null;
        }
        v = .string(check(L, vm.numberToString(L.state, v)));
        set(L, idx, v);
    }
    const s = v.asString().bytesZ();
    if (len) |p| p.* = s.len;
    return s.ptr;
}

pub fn luaRawlen(L: *lua_State, idx: c_int) callconv(.c) lua_Unsigned {
    const v = get(L, idx);
    return switch (v.tag) {
        .short_string, .long_string => v.asString().len(),
        .userdata => v.asUserdata().len,
        .table => v.asTable().length(),
        else => 0,
    };
}

/// The C function a value runs, or null.
fn cfunction(v: Value) ?lua_CFunction {
    if (v.tag != .native_closure) return null;
    const c = v.asNativeClosure();
    if (c.f != &trampoline) return null;
    return @ptrCast(@alignCast(c.cfn.?));
}

pub fn luaTocfunction(L: *lua_State, idx: c_int) callconv(.c) ?lua_CFunction {
    return cfunction(get(L, idx));
}

pub fn luaTouserdata(L: *lua_State, idx: c_int) callconv(.c) ?*anyopaque {
    const v = get(L, idx);
    return switch (v.tag) {
        .userdata => v.asUserdata().bytes().ptr,
        .light_userdata => v.asLightUserdata(),
        else => null,
    };
}

pub fn luaTothread(L: *lua_State, idx: c_int) callconv(.c) ?*lua_State {
    const v = get(L, idx);
    return if (v.tag == .thread) v.asThread() else null;
}

pub fn luaTopointer(L: *lua_State, idx: c_int) callconv(.c) ?*const anyopaque {
    const v = get(L, idx);
    if (cfunction(v)) |f| return @ptrCast(f);
    const p = aux.toPointer(v) orelse return null;
    return @ptrFromInt(p);
}

// ---------------------------------------------------------------------------
// Comparison and arithmetic
// ---------------------------------------------------------------------------

pub fn luaArith(L: *lua_State, op: c_int) callconv(.c) void {
    const o: vm.ArithOp = @enumFromInt(op);
    const unary = o == .unm or o == .bnot;
    // The reference pushes a copy of a unary operator's operand.
    if (unary) push(L, top(L, 1));
    const r = check(L, vm.arith(L, o, top(L, 2), top(L, 1)));
    L.top -= 1;
    L.stack[L.top - 1] = r;
}

pub fn luaRawequal(L: *lua_State, idx1: c_int, idx2: c_int) callconv(.c) c_int {
    const a = (at(L, idx1) orelse return 0).*;
    const b = (at(L, idx2) orelse return 0).*;
    return @intFromBool(Value.rawEquals(a, b));
}

pub fn luaCompare(L: *lua_State, idx1: c_int, idx2: c_int, op: c_int) callconv(.c) c_int {
    const a = (at(L, idx1) orelse return 0).*;
    const b = (at(L, idx2) orelse return 0).*;
    const r = switch (op) {
        0 => check(L, vm.equal(L, a, b)),
        1 => check(L, vm.lessThan(L, a, b)),
        2 => check(L, vm.lessEqual(L, a, b)),
        else => false,
    };
    return @intFromBool(r);
}

// ---------------------------------------------------------------------------
// Push functions (C -> stack)
// ---------------------------------------------------------------------------

pub fn luaPushnil(L: *lua_State) callconv(.c) void {
    push(L, .nil);
}

pub fn luaPushnumber(L: *lua_State, n: lua_Number) callconv(.c) void {
    push(L, .float(n));
}

pub fn luaPushinteger(L: *lua_State, n: lua_Integer) callconv(.c) void {
    push(L, .int(n));
}

pub fn luaPushlstring(L: *lua_State, s: ?[*]const u8, len: usize) callconv(.c) [*:0]const u8 {
    const str = newString(L, if (len == 0) "" else s.?[0..len]);
    push(L, .string(str));
    return str.bytesZ().ptr;
}

/// 5.5's external strings: this engine copies the bytes and gives them
/// back to `falloc` at once, as the reference does for short ones.
pub fn luaPushexternalstring(
    L: *lua_State,
    s: [*]const u8,
    len: usize,
    falloc: ?lua_Alloc,
    ud: ?*anyopaque,
) callconv(.c) [*:0]const u8 {
    const str = newString(L, s[0..len]);
    push(L, .string(str));
    if (falloc) |f| _ = f(ud, @constCast(s), len + 1, 0);
    return str.bytesZ().ptr;
}

pub fn luaPushstring(L: *lua_State, s: ?[*:0]const u8) callconv(.c) ?[*:0]const u8 {
    const p = s orelse {
        push(L, .nil);
        return null;
    };
    const str = newString(L, span(p));
    push(L, .string(str));
    return str.bytesZ().ptr;
}

pub fn luaPushvfstring(L: *lua_State, fmt: [*:0]const u8, ap: *va.List) callconv(.c) [*:0]const u8 {
    return check(L, pushVfString(L, fmt, ap));
}

pub fn luaPushfstring(L: *lua_State, fmt: [*:0]const u8, ...) callconv(.c) [*:0]const u8 {
    var ap = @cVaStart();
    const r = pushVfString(L, fmt, &ap);
    @cVaEnd(&ap);
    return check(L, r);
}

/// `luaO_pushvfstring`: `%s`, `%c`, `%d`, `%I`, `%f`, `%p`, `%U`, and
/// `%%`; any other conversion is kept as written.
pub inline fn pushVfString(th: *Thread, fmt_z: [*:0]const u8, ap: *va.List) Error![*:0]const u8 {
    var b: aux.Buffer = .init(th.state);
    defer b.deinit();
    const w = &b.writer;
    var fmt = span(fmt_z);
    while (std.mem.findScalar(u8, fmt, '%')) |e| {
        w.writeAll(fmt[0..e]) catch return error.OutOfMemory;
        const spec: u8 = if (e + 1 < fmt.len) fmt[e + 1] else 0;
        var nbuf: [number.max_len]u8 = undefined;
        switch (spec) {
            's' => {
                const s = va.arg(ap, ?[*:0]const u8);
                w.writeAll(if (s) |p| span(p) else "(null)") catch return error.OutOfMemory;
            },
            'c' => w.writeByte(@truncate(@as(c_uint, @bitCast(va.arg(ap, c_int))))) catch return error.OutOfMemory,
            'd' => w.writeAll(vm.formatNumber(.int(va.arg(ap, c_int)), &nbuf)) catch return error.OutOfMemory,
            'I' => w.writeAll(vm.formatNumber(.int(va.arg(ap, i64)), &nbuf)) catch return error.OutOfMemory,
            'f' => w.writeAll(vm.formatNumber(.float(va.arg(ap, f64)), &nbuf)) catch return error.OutOfMemory,
            'p' => {
                const p = va.arg(ap, ?*anyopaque);
                if (p) |q|
                    w.print("0x{x}", .{@intFromPtr(q)}) catch return error.OutOfMemory
                else
                    w.writeAll("(nil)") catch return error.OutOfMemory;
            },
            'U' => {
                var ubuf: [8]u8 = undefined;
                w.writeAll(utf8Escape(&ubuf, @truncate(va.arg(ap, c_ulong)))) catch return error.OutOfMemory;
            },
            '%' => w.writeByte('%') catch return error.OutOfMemory,
            else => w.writeAll(fmt[e..@min(e + 2, fmt.len)]) catch return error.OutOfMemory,
        }
        fmt = fmt[@min(e + 2, fmt.len)..];
    }
    w.writeAll(fmt) catch return error.OutOfMemory;
    const s = try b.toString(th.state);
    push(th, .string(s));
    return s.bytesZ().ptr;
}

/// `luaO_utf8esc`: `x` (at most 0x7FFFFFFF) in UTF-8, up to six bytes.
fn utf8Escape(buf: *[8]u8, x_in: u32) []const u8 {
    var x = x_in;
    if (x < 0x80) {
        buf[7] = @intCast(x);
        return buf[7..];
    }
    var n: usize = 1;
    var mfb: u32 = 0x3f;
    while (true) {
        buf[8 - n] = @intCast(0x80 | (x & 0x3f));
        n += 1;
        x >>= 6;
        mfb >>= 1;
        if (x <= mfb) break;
    }
    buf[8 - n] = @intCast(((~mfb << 1) & 0xff) | x);
    return buf[8 - n ..];
}

/// The function value for C function `f` with `n` upvalues taken from
/// the top of the stack.
fn newCClosure(th: *Thread, f: lua_CFunction, n: u8) error{OutOfMemory}!*Proto.NativeClosure {
    const c = try Proto.NativeClosure.create(th.heap(), &trampoline, n);
    c.cfn = @ptrCast(f);
    return c;
}

var cfuncs_key: u8 = 0;

/// The one closure for light C function `f`, as `lua_pushcfunction`
/// pushes it.
pub fn lightCFunction(th: *Thread, f: lua_CFunction) error{OutOfMemory}!Value {
    const state = th.state;
    const d = try threadData(state.main);
    const t = d.cfuncs orelse blk: {
        const t = try state.newTable(0, 0);
        state.registry.set(&state.heap, .lightUserdata(&cfuncs_key), .table(t)) catch return error.OutOfMemory;
        d.cfuncs = t;
        break :blk t;
    };
    const key: Value = .lightUserdata(@ptrCast(@constCast(f)));
    const v = t.get(key);
    if (!v.isNil()) return v;
    const c: Value = .nativeClosure(try newCClosure(th, f, 0));
    t.set(&state.heap, key, c) catch return error.OutOfMemory;
    return c;
}

pub fn luaPushcclosure(L: *lua_State, f: lua_CFunction, n: c_int) callconv(.c) void {
    if (n == 0) return push(L, check(L, lightCFunction(L, f)));
    const k: u8 = @intCast(n);
    const c = check(L, newCClosure(L, f, k));
    L.top -= k;
    for (L.stack[L.top..][0..k], 0..) |v, i| c.setUpvalue(L.heap(), i, v);
    push(L, .nativeClosure(c));
}

pub fn luaPushboolean(L: *lua_State, b: c_int) callconv(.c) void {
    push(L, .boolean(b != 0));
}

pub fn luaPushlightuserdata(L: *lua_State, p: ?*anyopaque) callconv(.c) void {
    push(L, .lightUserdata(p));
}

pub fn luaPushthread(L: *lua_State) callconv(.c) c_int {
    push(L, .thread(L));
    return @intFromBool(L == L.state.main);
}

// ---------------------------------------------------------------------------
// Get functions (Lua -> stack)
// ---------------------------------------------------------------------------

/// Replaces the top with `v` and returns its type.
inline fn replaceTop(th: *Thread, v: Value) c_int {
    th.stack[th.top - 1] = v;
    return @intFromEnum(v.typeOf());
}

inline fn pushType(th: *Thread, v: Value) c_int {
    push(th, v);
    return @intFromEnum(v.typeOf());
}

pub fn luaGetglobal(L: *lua_State, name: [*:0]const u8) callconv(.c) c_int {
    const k = newString(L, span(name));
    return pushType(L, check(L, vm.get(L, .table(L.state.globals), .string(k))));
}

pub fn luaGettable(L: *lua_State, idx: c_int) callconv(.c) c_int {
    return replaceTop(L, check(L, vm.get(L, get(L, idx), top(L, 1))));
}

pub fn luaGetfield(L: *lua_State, idx: c_int, k: [*:0]const u8) callconv(.c) c_int {
    const t = get(L, idx);
    const key = newString(L, span(k));
    return pushType(L, check(L, vm.get(L, t, .string(key))));
}

pub fn luaGeti(L: *lua_State, idx: c_int, n: lua_Integer) callconv(.c) c_int {
    return pushType(L, check(L, aux.getI(L, get(L, idx), n)));
}

pub fn luaRawget(L: *lua_State, idx: c_int) callconv(.c) c_int {
    return replaceTop(L, get(L, idx).asTable().get(top(L, 1)));
}

pub fn luaRawgeti(L: *lua_State, idx: c_int, n: lua_Integer) callconv(.c) c_int {
    return pushType(L, get(L, idx).asTable().getInt(n));
}

pub fn luaRawgetp(L: *lua_State, idx: c_int, p: ?*const anyopaque) callconv(.c) c_int {
    return pushType(L, get(L, idx).asTable().get(.lightUserdata(@constCast(p))));
}

pub fn luaCreatetable(L: *lua_State, narr: c_int, nrec: c_int) callconv(.c) void {
    const t = check(L, L.state.newTable(@intCast(@max(narr, 0)), @intCast(@max(nrec, 0))));
    push(L, .table(t));
}

pub fn luaNewuserdatauv(L: *lua_State, size: usize, nuvalue: c_int) callconv(.c) *anyopaque {
    const u = check(L, Userdata.create(L.heap(), size, @intCast(nuvalue)));
    push(L, .userdata(u));
    return u.bytes().ptr;
}

pub fn luaGetmetatable(L: *lua_State, idx: c_int) callconv(.c) c_int {
    const mt = L.state.metatableOf(get(L, idx)) orelse return 0;
    push(L, .table(mt));
    return 1;
}

pub fn luaGetiuservalue(L: *lua_State, idx: c_int, n: c_int) callconv(.c) c_int {
    const v = get(L, idx);
    if (v.tag != .userdata or n <= 0 or n > v.asUserdata().nuvalue) {
        push(L, .nil);
        return lua_tnone;
    }
    return pushType(L, v.asUserdata().userValues()[@intCast(n - 1)]);
}

// ---------------------------------------------------------------------------
// Set functions (stack -> Lua)
// ---------------------------------------------------------------------------

pub fn luaSetglobal(L: *lua_State, name: [*:0]const u8) callconv(.c) void {
    const k = newString(L, span(name));
    check(L, vm.set(L, .table(L.state.globals), .string(k), top(L, 1)));
    L.top -= 1;
}

pub fn luaSettable(L: *lua_State, idx: c_int) callconv(.c) void {
    check(L, vm.set(L, get(L, idx), top(L, 2), top(L, 1)));
    L.top -= 2;
}

pub fn luaSetfield(L: *lua_State, idx: c_int, k: [*:0]const u8) callconv(.c) void {
    const t = get(L, idx);
    const key = newString(L, span(k));
    check(L, vm.set(L, t, .string(key), top(L, 1)));
    L.top -= 1;
}

pub fn luaSeti(L: *lua_State, idx: c_int, n: lua_Integer) callconv(.c) void {
    check(L, aux.setI(L, get(L, idx), n, top(L, 1)));
    L.top -= 1;
}

fn rawSet(th: *Thread, t: *Table, k: Value, v: Value) void {
    t.set(th.heap(), k, v) catch |e| switch (e) {
        error.OutOfMemory => throw(th, error.OutOfMemory),
        error.IndexIsNil => throw(th, th.runError("table index is nil", .{})),
        error.IndexIsNaN => throw(th, th.runError("table index is NaN", .{})),
    };
}

pub fn luaRawset(L: *lua_State, idx: c_int) callconv(.c) void {
    rawSet(L, get(L, idx).asTable(), top(L, 2), top(L, 1));
    L.top -= 2;
}

pub fn luaRawseti(L: *lua_State, idx: c_int, n: lua_Integer) callconv(.c) void {
    check(L, get(L, idx).asTable().setInt(L.heap(), n, top(L, 1)));
    L.top -= 1;
}

pub fn luaRawsetp(L: *lua_State, idx: c_int, p: ?*const anyopaque) callconv(.c) void {
    rawSet(L, get(L, idx).asTable(), .lightUserdata(@constCast(p)), top(L, 1));
    L.top -= 1;
}

pub fn luaSetmetatable(L: *lua_State, idx: c_int) callconv(.c) c_int {
    const mt = top(L, 1);
    L.state.setMetatable(get(L, idx), if (mt.isNil()) null else mt.asTable());
    L.top -= 1;
    return 1;
}

pub fn luaSetiuservalue(L: *lua_State, idx: c_int, n: c_int) callconv(.c) c_int {
    const v = get(L, idx);
    const ok = n > 0 and n <= v.asUserdata().nuvalue;
    if (ok) v.asUserdata().setUserValue(L.heap(), @intCast(n - 1), top(L, 1));
    L.top -= 1;
    return @intFromBool(ok);
}

// ---------------------------------------------------------------------------
// Load and call
// ---------------------------------------------------------------------------

/// `adjustresults`: room for every result of a call with `LUA_MULTRET`.
inline fn adjustResults(th: *Thread, nresults: c_int) void {
    const f = th.frame();
    if (nresults < 0 and f.top < th.top) f.top = th.top;
}

pub fn luaCallk(L: *lua_State, nargs: c_int, nresults: c_int, ctx: lua_KContext, k: ?lua_KFunction) callconv(.c) void {
    const func = L.top - @as(u32, @intCast(nargs)) - 1;
    const nr: i16 = @intCast(nresults);
    if (k) |kf| {
        const idx = check(L, setK(L, kf, ctx));
        check(L, vm.callk(L, func, nr, idx, &cK));
    } else {
        check(L, vm.call(L, func, nr));
    }
    adjustResults(L, nresults);
}

pub fn luaPcallk(
    L: *lua_State,
    nargs: c_int,
    nresults: c_int,
    errfunc: c_int,
    ctx: lua_KContext,
    k: ?lua_KFunction,
) callconv(.c) c_int {
    const func = L.top - @as(u32, @intCast(nargs)) - 1;
    const nr: i16 = @intCast(nresults);
    const msgh: u32 = if (errfunc == 0) 0 else slotOf(L, errfunc);
    const status = if (k != null and vm.isYieldable(L)) blk: {
        const idx = check(L, setK(L, k.?, ctx));
        break :blk check(L, vm.pcallk(L, func, nr, msgh, idx, &cK));
    } else vm.pcallMsgh(L, func, nr, msgh);
    adjustResults(L, nresults);
    return statusCode(status);
}

/// A growable byte buffer in a full userdata on the stack, which the
/// collector frees if an error abandons it: `lua_load` and lauxlib's
/// buffers keep no memory a jump could leak.
pub const Box = struct {
    /// The box's block: memory from the state's string allocator, outside
    /// the userdata, so it can grow in place. The bytes start after room
    /// for a `String` header, so `toString` can make the block a string
    /// without a copy, as 5.5.1's `luaL_pushresult` makes its box an
    /// external string.
    const Data = extern struct { ptr: ?[*]align(String.alignment.toByteUnits()) u8, len: usize };

    const header_len = @sizeOf(String);

    /// Makes the value at stack slot `slot` a box of `size` bytes that
    /// starts with `keep`, and returns its bytes. A box there already
    /// grows, in place where the allocator can (`mremap` for large
    /// blocks), as lauxlib.c's `realloc`s; then `keep` must be the start
    /// of its bytes. Otherwise a new box holds a copy of `keep`.
    pub fn grow(th: *Thread, slot: u32, keep: []const u8, size: usize) error{OutOfMemory}![]u8 {
        const heap = th.heap();
        const len = std.math.add(usize, size, header_len) catch return error.OutOfMemory;
        if (data(th, th.stack[slot])) |d| {
            const b = try heap.rawStrings().realloc(d.ptr.?[0..d.len], len);
            d.* = .{ .ptr = b.ptr, .len = b.len };
            return b[header_len..];
        }
        if (heap.stopped & gc.stop.closing != 0) {
            // Finalizers no longer register while the state closes: the
            // bytes in a plain userdata, a new one each time.
            const u = try Userdata.create(heap, size, 0);
            const b = u.bytes();
            @memcpy(b[0..keep.len], keep);
            th.stack[slot] = .userdata(u);
            return b;
        }
        const mt = try metatable(th);
        const u = try Userdata.create(heap, @sizeOf(Data), 0);
        const d: *Data = @ptrCast(u.bytes().ptr);
        d.* = .{ .ptr = null, .len = 0 };
        th.stack[slot] = .userdata(u);
        th.state.setMetatable(.userdata(u), mt);
        const b = try heap.rawStrings().alignedAlloc(u8, String.alignment, len);
        @memcpy(b[header_len..][0..keep.len], keep);
        d.* = .{ .ptr = b.ptr, .len = len };
        return b[header_len..];
    }

    /// Frees the bytes of the box at `slot` now, if it is one, instead of
    /// at its collection (lauxlib.c's `lua_closeslot` of the box).
    pub fn release(th: *Thread, slot: u32) void {
        const d = data(th, th.stack[slot]) orelse return;
        if (d.ptr) |p| th.heap().rawStrings().free(p[0..d.len]);
        d.* = .{ .ptr = null, .len = 0 };
    }

    /// The first `n` bytes of the box at `slot` as a long string made of
    /// its block, which the box gives up; null when `slot` holds no box
    /// (a placeholder, or a box made while the state closes) or `n` is
    /// short, for the caller to copy.
    pub fn toString(th: *Thread, slot: u32, n: usize) error{OutOfMemory}!?*String {
        if (n <= String.max_short_len) return null;
        const d = data(th, th.stack[slot]) orelse return null;
        const heap = th.heap();
        const block = try heap.rawStrings().realloc(d.ptr.?[0..d.len], String.allocSize(n));
        d.* = .{ .ptr = null, .len = 0 };
        return String.adoptLong(heap, th.state.seed, block, n);
    }

    fn data(th: *Thread, v: Value) ?*Data {
        if (v.tag != .userdata) return null;
        const u = v.asUserdata();
        const mt = u.metatable orelse return null;
        const td = dataSlot(th.state.main).* orelse return null;
        if (mt != td.box_mt) return null;
        return @ptrCast(@alignCast(u.bytes().ptr));
    }

    /// `{__gc = gcf}`, made once per state.
    fn metatable(th: *Thread) error{OutOfMemory}!*Table {
        const state = th.state;
        const d = try threadData(state.main);
        if (d.box_mt) |t| return t;
        const t = try state.newTable(0, 1);
        state.registry.set(&state.heap, .lightUserdata(&box_key), .table(t)) catch return error.OutOfMemory;
        const name = try state.newString("__gc");
        t.set(&state.heap, .string(name), try lightCFunction(th, &gcf)) catch return error.OutOfMemory;
        d.box_mt = t;
        return t;
    }

    /// Frees what an error left in a box.
    fn gcf(L: *lua_State) callconv(.c) c_int {
        const v = get(L, 1);
        const d: *Data = @ptrCast(@alignCast(v.asUserdata().bytes().ptr));
        if (d.ptr) |p| L.heap().rawStrings().free(p[0..d.len]);
        d.* = .{ .ptr = null, .len = 0 };
        return 0;
    }
};

var box_key: u8 = 0;

/// What `readShim` passes to and from a `lua_Reader`.
const ReadCall = struct { reader: lua_Reader, data: ?*anyopaque, size: usize = 0, p: ?[*]const u8 = null };

/// A reader's three arguments, and its pointer result, through a
/// protected call, which returns an `int`.
fn readShim(L: *lua_State, rc: *ReadCall) callconv(.c) c_int {
    rc.p = rc.reader(L, rc.data, &rc.size);
    return 0;
}

/// The status of a load that failed with `e`, with its error object
/// pushed at `slot`.
fn loadFailure(L: *lua_State, slot: u32, e: Error, syntax: bool) c_int {
    L.top = slot;
    switch (e) {
        error.OutOfMemory => {
            push(L, .string(L.state.memerr));
            return lua_errmem;
        },
        error.LuaError => {
            push(L, L.err);
            L.err = .nil;
            return if (syntax) lua_errsyntax else if (L.errerr) lua_errerr else lua_errrun;
        },
    }
}

/// Never raises: like `luaD_protectedparser`, a failure, the reader's
/// own errors included, is the result.
pub fn luaLoad(
    L: *lua_State,
    reader: lua_Reader,
    data: ?*anyopaque,
    chunkname: ?[*:0]const u8,
    mode: ?[*:0]const u8,
) callconv(.c) c_int {
    // The chunk accumulates in a box on the stack, which the collector
    // frees whatever happens.
    const slot = L.top;
    L.ensureStack(1) catch |e| return loadFailure(L, slot, e, false);
    push(L, .nil);
    var buf: []u8 = Box.grow(L, slot, "", 256) catch |e| return loadFailure(L, slot, e, false);
    var n: usize = 0;
    var rc: ReadCall = .{ .reader = reader, .data = data };
    while (true) {
        if (protect(L, &readShim, @intFromPtr(&rc), 0) == jmp.aborted) {
            Box.release(L, slot);
            return loadFailure(L, slot, failure.err, false);
        }
        const p = rc.p orelse break;
        if (rc.size == 0) break;
        if (n + rc.size + 1 > buf.len)
            buf = Box.grow(L, slot, buf[0..n], @max(buf.len * 2, n + rc.size + 1)) catch |e| {
                Box.release(L, slot);
                return loadFailure(L, slot, e, false);
            };
        @memcpy(buf[n..][0..rc.size], p[0..rc.size]);
        n += rc.size;
    }
    buf[n] = 0;
    const name = if (chunkname) |c| span(c) else "?";
    const f = base.loadChunk(L, buf[0..n :0], name, if (mode) |m| span(m) else "bt") catch |e| {
        Box.release(L, slot);
        return loadFailure(L, slot, e, true);
    };
    Box.release(L, slot);
    L.top = slot;
    push(L, f);
    return lua_ok;
}

/// `lua_dump`'s output: a writer whose drain hands what it has to the
/// `lua_Writer`, protected, so a writer that raises abandons only this
/// function's frame and `dump.zig`'s, which hold nothing then.
const DumpSink = struct {
    w: std.Io.Writer,
    th: *Thread,
    f: lua_Writer,
    ud: ?*anyopaque,
    /// The writer's last result; writing stops at the first nonzero one.
    status: c_int = 0,
    aborted: bool = false,
    /// What `writeShim` passes on.
    p: ?[*]const u8 = null,
    n: usize = 0,

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const d: *DumpSink = @fieldParentPtr("w", w);
        try d.send(w.buffered());
        w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |s| {
            try d.send(s);
            n += s.len;
        }
        for (0..splat) |_| {
            try d.send(data[data.len - 1]);
            n += data[data.len - 1].len;
        }
        return n;
    }

    /// Calls the writer with `bytes`, or with NULL and 0 for null, the
    /// end of the dump.
    fn send(d: *DumpSink, bytes: ?[]const u8) std.Io.Writer.Error!void {
        if (bytes) |b| if (b.len == 0) return;
        d.p = if (bytes) |b| b.ptr else null;
        d.n = if (bytes) |b| b.len else 0;
        const r = protect(d.th, &writeShim, @intFromPtr(d), 0);
        if (r == jmp.aborted) {
            d.aborted = true;
            return error.WriteFailed;
        }
        d.status = @bitCast(@as(u32, @truncate(r)));
        if (d.status != 0) return error.WriteFailed;
    }

    /// The writer's four arguments, from the three a protected call
    /// passes.
    fn writeShim(L: *lua_State, ctx: *DumpSink) callconv(.c) c_int {
        return ctx.f(L, ctx.p, ctx.n, ctx.ud);
    }
};

pub fn luaDump(L: *lua_State, writer: lua_Writer, data: ?*anyopaque, strip: c_int) callconv(.c) c_int {
    const proto = top(L, 1).asLuaClosure().proto;
    var buf: [512]u8 = undefined;
    var sink: DumpSink = .{
        .w = .{ .vtable = &.{ .drain = DumpSink.drain }, .buffer = &buf },
        .th = L,
        .f = writer,
        .ud = data,
    };
    const r = dump.dump(L.heap().allocator(), &sink.w, proto, strip != 0);
    if (sink.aborted) throw(L, failure.err);
    if (r) |_| {
        // A writer that fails or raises leaves its status or the error
        // in `sink`, read below and returned.
        if (sink.w.flush()) |_| sink.send(null) catch |e| switch (e) {
            error.WriteFailed => {},
        } else |_| {}
        if (sink.aborted) throw(L, failure.err);
    } else |e| if (e == error.OutOfMemory) throw(L, error.OutOfMemory);
    return sink.status;
}

// ---------------------------------------------------------------------------
// Coroutines
// ---------------------------------------------------------------------------

pub fn luaYieldk(L: *lua_State, nresults: c_int, ctx: lua_KContext, k: ?lua_KFunction) callconv(.c) c_int {
    // Hooks run inside the frame they report on and cannot yield here
    // (docs/slop/c-api.md).
    if (L.frame().flags.hooked) throw(L, L.runError("attempt to yield across a C-call boundary", .{}));
    const n: u32 = @intCast(nresults);
    const e = if (k) |kf| vm.yieldk(L, n, check(L, setK(L, kf, ctx)), &cK) else vm.yieldk(L, n, 0, null);
    throw(L, e);
}

pub fn luaResume(L: *lua_State, from: ?*lua_State, narg: c_int, nres: *c_int) callconv(.c) c_int {
    const r = check(from orelse L, vm.resumeThread(L, from, @intCast(narg)));
    nres.* = @intCast(r.nres);
    return switch (r.status) {
        .ok => lua_ok,
        .yield => lua_yield,
        .err => statusCode(r.err),
    };
}

pub fn luaStatus(L: *lua_State) callconv(.c) c_int {
    return switch (L.status) {
        .ok => lua_ok,
        .yield => lua_yield,
        .dead => statusCode(L.died),
    };
}

pub fn luaIsyieldable(L: *lua_State) callconv(.c) c_int {
    return @intFromBool(vm.isYieldable(L));
}

// ---------------------------------------------------------------------------
// Warnings and the collector
// ---------------------------------------------------------------------------

pub fn luaWarning(L: *lua_State, msg: [*:0]const u8, tocont: c_int) callconv(.c) void {
    if (L.state.warnf) |f| f(L.state, span(msg), tocont != 0);
}

pub fn luaSetwarnf(L: *lua_State, f: ?lua_WarnFunction, ud: ?*anyopaque) callconv(.c) void {
    const d = check(L, threadData(L.state.main));
    d.warnf = f;
    d.warn_ud = ud;
    L.state.warnf = if (f != null) &cWarn else null;
}

/// The state's warning function while `lua_setwarnf` gave it a C one.
/// The collector warns from deep in Zig code, so the C function runs
/// protected, and an error it raises is dropped.
fn cWarn(state: *State, msg: []const u8, tocont: bool) void {
    const d = dataSlot(state.main).*.?;
    const f = d.warnf orelse return;
    var call: WarnCall = .{ .f = f, .ud = d.warn_ud, .msg = undefined, .tocont = @intFromBool(tocont) };
    // Every message comes from a Lua string or a literal, both of which
    // end in a zero; copy the short ones anyway, as cheap insurance.
    var buf: [256]u8 = undefined;
    call.msg = if (msg.len < buf.len) blk: {
        @memcpy(buf[0..msg.len], msg);
        buf[msg.len] = 0;
        break :blk buf[0..msg.len :0].ptr;
    } else @ptrCast(msg.ptr);
    _ = protect(state.main, &warnShim, @intFromPtr(&call), 0);
}

const WarnCall = struct { f: lua_WarnFunction, ud: ?*anyopaque, msg: [*:0]const u8, tocont: c_int };

fn warnShim(_: *lua_State, call: *const WarnCall) callconv(.c) c_int {
    call.f(call.ud, call.msg, call.tocont);
    return 0;
}

/// `lua_gc`'s options, lua.h's `LUA_GC*`.
const GcOption = enum(c_int) { stop, restart, collect, count, countb, step, isrunning, gen, inc, param, _ };

pub fn luaGc(L: *lua_State, what: c_int, ...) callconv(.c) c_int {
    var ap = @cVaStart();
    const r = luaGcv(L, what, &ap);
    @cVaEnd(&ap);
    return r;
}

/// `lua_gc` with its arguments as a list, which aarch64 Linux's entry
/// builds (`va.zig`).
fn luaGcv(L: *lua_State, what: c_int, ap: *va.List) callconv(.c) c_int {
    const heap = L.heap();
    if (heap.stopped & (gc.stop.internal | gc.stop.closing) != 0) return -1;
    switch (@as(GcOption, @enumFromInt(what))) {
        .stop => heap.stopped = gc.stop.user,
        .restart => {
            heap.setDebt(0);
            heap.stopped = 0;
        },
        .collect => gc.fullGc(L, false),
        .count => return @intCast(heap.bytes >> 10),
        .countb => return @intCast(heap.bytes & 0x3ff),
        .step => {
            // A step of `n` bytes' worth, or one basic step for n <= 0,
            // as `collectgarbage("step")` takes it.
            const n: isize = @bitCast(va.arg(ap, usize));
            const old = heap.stopped;
            heap.stopped = 0;
            const max = std.math.maxInt(isize);
            heap.setDebt(if (n <= 0) 0 else if (heap.debt() >= n - max) heap.debt() - n else -max);
            const worked = L.state.gcDue();
            if (worked) gc.basicStep(L);
            heap.stopped = old;
            return @intFromBool(worked and heap.phase == .pause);
        },
        .isrunning => return @intFromBool(heap.running()),
        .gen, .inc => {
            const old = @intFromEnum(if (heap.kind == .incremental) GcOption.inc else GcOption.gen);
            gc.changeMode(L, if (what == @intFromEnum(GcOption.gen)) .gen_minor else .incremental);
            return old;
        },
        .param => {
            const p: usize = @intCast(va.arg(ap, c_int));
            const value = va.arg(ap, c_int);
            const old = gc.applyParam(heap.params[p], 100);
            if (value >= 0) heap.params[p] = gc.codeParam(@intCast(value));
            return @intCast(old);
        },
        _ => return -1,
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Miscellaneous
// ---------------------------------------------------------------------------

pub fn luaError(L: *lua_State) callconv(.c) c_int {
    const v = top(L, 1);
    // The memory error's message raises a memory error, as in lapi.c.
    if (v.tag == .short_string and v.asString() == L.state.memerr) throw(L, error.OutOfMemory);
    throw(L, L.throw(v));
}

pub fn luaNext(L: *lua_State, idx: c_int) callconv(.c) c_int {
    const t = get(L, idx).asTable();
    const e = t.next(top(L, 1)) catch throw(L, L.runError("invalid key to 'next'", .{}));
    if (e) |entry| {
        L.stack[L.top - 1] = entry.key;
        push(L, entry.value);
        return 1;
    }
    L.top -= 1;
    return 0;
}

pub fn luaConcat(L: *lua_State, n: c_int) callconv(.c) void {
    check(L, vm.concat(L, @intCast(n)));
}

pub fn luaLen(L: *lua_State, idx: c_int) callconv(.c) void {
    push(L, check(L, vm.length(L, get(L, idx))));
}

pub fn luaNumbertocstring(L: *lua_State, idx: c_int, buff: [*]u8) callconv(.c) c_uint {
    const v = get(L, idx);
    if (!v.isNumber()) return 0;
    var nbuf: [number.max_len]u8 = undefined;
    const s = vm.formatNumber(v, &nbuf);
    @memcpy(buff[0..s.len], s);
    buff[s.len] = 0;
    return @intCast(s.len + 1);
}

pub fn luaStringtonumber(L: *lua_State, s: [*:0]const u8) callconv(.c) usize {
    const b = span(s);
    const v = vm.stringToNumber(b) orelse return 0;
    push(L, v);
    return b.len + 1;
}

/// The allocator `lua_getallocf` gives C code: the state's own, with
/// 16-byte alignment, as `l_alloc` with realloc and free.
fn cAlloc(ud: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.c) ?*anyopaque {
    const state: *State = @ptrCast(@alignCast(ud.?));
    const a = state.heap.backing;
    const al: std.mem.Alignment = .@"16";
    const old: ?[*]u8 = @ptrCast(ptr);
    if (nsize == 0) {
        if (old) |p| a.rawFree(p[0..osize], al, @returnAddress());
        return null;
    }
    const new = a.rawAlloc(nsize, al, @returnAddress()) orelse return null;
    if (old) |p| {
        @memcpy(new[0..@min(osize, nsize)], p[0..@min(osize, nsize)]);
        a.rawFree(p[0..osize], al, @returnAddress());
    }
    return new;
}

pub fn luaGetallocf(L: *lua_State, ud: ?*?*anyopaque) callconv(.c) lua_Alloc {
    if (state_mod.of(L.state)) |cs| {
        if (ud) |p| p.* = cs.ud;
        return cs.f;
    }
    if (dataSlot(L.state.main).*) |d| if (d.allocf) |f| {
        if (ud) |p| p.* = d.alloc_ud;
        return f;
    };
    if (ud) |p| p.* = L.state;
    return &cAlloc;
}

/// A state from `lua_newstate` allocates through the new function from
/// now on. One the Zig API made keeps its allocator: blocks it allocated
/// carry alignments a `lua_Alloc` cannot be told, so only `lua_getallocf`
/// sees the change (docs/slop/c-api.md).
pub fn luaSetallocf(L: *lua_State, f: lua_Alloc, ud: ?*anyopaque) callconv(.c) void {
    if (state_mod.of(L.state)) |cs| {
        cs.f = f;
        cs.ud = ud;
        return;
    }
    const d = check(L, threadData(L.state.main));
    d.allocf = f;
    d.alloc_ud = ud;
}

// ---------------------------------------------------------------------------
// Debug API (the parts lauxlib-style code uses)
// ---------------------------------------------------------------------------

/// lua.h's `lua_Debug`, field for field.
pub const lua_Debug = extern struct {
    event: c_int,
    name: ?[*:0]const u8,
    namewhat: ?[*:0]const u8,
    what: ?[*:0]const u8,
    source: ?[*:0]const u8,
    srclen: usize,
    currentline: c_int,
    linedefined: c_int,
    lastlinedefined: c_int,
    nups: u8,
    nparams: u8,
    isvararg: u8,
    extraargs: u8,
    istailcall: u8,
    ftransfer: c_int,
    ntransfer: c_int,
    short_src: [60]u8,
    /// The frame's index plus one; 0 for a function from `>`.
    i_ci: usize,
};

pub fn luaGetstack(L: *lua_State, level: c_int, ar: *lua_Debug) callconv(.c) c_int {
    if (level < 0) return 0;
    const n = L.frames.items.len;
    const lv: usize = @intCast(level);
    if (lv + 1 >= n) return 0;
    ar.i_ci = n - 1 - lv + 1;
    return 1;
}

/// A NUL-terminated copy of `s`, interned so it lives as long as an equal
/// string does, as the reference's names point into its strings.
fn zstr(th: *Thread, s: []const u8) [*:0]const u8 {
    return newString(th, s).bytesZ().ptr;
}

pub fn luaGetinfo(L: *lua_State, what_in: [*:0]const u8, ar: *lua_Debug) callconv(.c) c_int {
    var what = span(what_in);
    var func: Value = undefined;
    var frame: ?usize = null;
    if (what.len > 0 and what[0] == '>') {
        func = top(L, 1);
        L.top -= 1;
        what = what[1..];
    } else {
        frame = ar.i_ci - 1;
        func = L.stack[L.frames.items[frame.?].func];
    }
    const lua: ?*Proto = if (func.tag == .lua_closure) func.asLuaClosure().proto else null;
    var ok: c_int = 1;
    for (what) |c| switch (c) {
        'S' => {
            const src: []const u8 = if (lua) |p| (if (p.source) |s| s.bytes() else "=?") else "=[C]";
            ar.source = if (lua) |p| (if (p.source) |s| s.bytesZ().ptr else "=?") else "=[C]";
            ar.srclen = src.len;
            var w: std.Io.Writer = .fixed(ar.short_src[0 .. ar.short_src.len - 1]);
            // The id is 60 bytes at most, as `short_src` holds.
            Thread.writeChunkId(&w, src) catch unreachable;
            ar.short_src[w.end] = 0;
            ar.linedefined = if (lua) |p| @intCast(p.linedefined) else -1;
            ar.lastlinedefined = if (lua) |p| @intCast(p.lastlinedefined) else -1;
            ar.what = if (lua) |p| (if (p.linedefined == 0) "main" else "Lua") else "C";
        },
        'l' => {
            ar.currentline = -1;
            if (frame) |i| {
                const f = &L.frames.items[i];
                if (f.flags.lua) ar.currentline = lua.?.lineAt(Thread.currentPc(lua.?, f)) orelse -1;
            }
        },
        'u' => {
            ar.nups = switch (func.tag) {
                .lua_closure => func.asLuaClosure().nupvalues,
                .native_closure => func.asNativeClosure().nupvalues,
                else => 0,
            };
            ar.nparams = if (lua) |p| p.numparams else 0;
            ar.isvararg = if (lua) |p| @intFromBool(p.flags.vararg or p.flags.vararg_table) else 1;
        },
        'n' => {
            const n = if (frame) |i| debuginfo.funcName(L, i) else null;
            ar.name = if (n) |v| zstr(L, v.name) else null;
            ar.namewhat = if (n) |v| zstr(L, v.kind) else "";
        },
        't' => {
            const f = if (frame) |i| &L.frames.items[i] else null;
            ar.istailcall = if (f) |x| @intFromBool(x.flags.tail) else 0;
            ar.extraargs = if (f) |x| x.flags.ncallmt else 0;
        },
        'r' => {
            // Only a frame running a hook has transfer information.
            const hooked = if (frame) |i| L.frames.items[i].flags.hooked else false;
            ar.ftransfer = if (hooked) L.ftransfer else 0;
            ar.ntransfer = if (hooked) L.ntransfer else 0;
        },
        'f', 'L' => {},
        else => ok = 0,
    };
    // 'f' then 'L', wherever they are in `what`, as `lua_getinfo` pushes.
    if (std.mem.findScalar(u8, what, 'f') != null) push(L, func);
    if (std.mem.findScalar(u8, what, 'L') != null) push(L, if (lua) |p| .table(check(L, activeLines(L, p))) else .nil);
    return ok;
}

/// The lines of `p` that have code, as a table of `true`s
/// (`collectvalidlines`). A vararg function's first instruction,
/// `VARARGPREP`, has no line of its own.
fn activeLines(th: *Thread, p: *Proto) Error!*Table {
    const t = try th.state.newTable(0, 0);
    // Rooted on the stack while it fills.
    push(th, .table(t));
    defer th.top -= 1;
    if (p.lineinfo.len == 0) return t;
    var line: i32 = @bitCast(p.linedefined);
    var first: usize = 0;
    if (p.flags.vararg or p.flags.vararg_table) {
        line = p.nextLine(line, 0);
        first = 1;
    }
    for (first..p.lineinfo.len) |pc| {
        line = p.nextLine(line, pc);
        try t.setInt(th.heap(), line, .true);
    }
    return t;
}

pub fn luaGetupvalue(L: *lua_State, funcindex: c_int, n: c_int) callconv(.c) ?[*:0]const u8 {
    const f = get(L, funcindex);
    if (n < 1) return null;
    const i: usize = @intCast(n - 1);
    switch (f.tag) {
        .native_closure => {
            const ups = f.asNativeClosure().upvalues();
            if (i >= ups.len) return null;
            push(L, ups[i]);
            return "";
        },
        .lua_closure => {
            const c = f.asLuaClosure();
            if (i >= c.nupvalues) return null;
            push(L, c.upvals()[i].v.*);
            const name = c.proto.upvalues[i].name orelse return "(no name)";
            return if (name.len() == 0) "(no name)" else name.bytesZ().ptr;
        },
        else => return null,
    }
}

pub fn luaSetupvalue(L: *lua_State, funcindex: c_int, n: c_int) callconv(.c) ?[*:0]const u8 {
    const f = get(L, funcindex);
    if (n < 1) return null;
    const i: usize = @intCast(n - 1);
    const v = top(L, 1);
    switch (f.tag) {
        .native_closure => {
            const c = f.asNativeClosure();
            if (i >= c.nupvalues) return null;
            c.setUpvalue(L.heap(), i, v);
            L.top -= 1;
            return "";
        },
        .lua_closure => {
            const c = f.asLuaClosure();
            if (i >= c.nupvalues) return null;
            c.upvals()[i].set(L.heap(), v);
            L.top -= 1;
            const name = c.proto.upvalues[i].name orelse return "(no name)";
            return if (name.len() == 0) "(no name)" else name.bytesZ().ptr;
        },
        else => return null,
    }
}

pub fn luaUpvalueid(L: *lua_State, fidx: c_int, n: c_int) callconv(.c) ?*anyopaque {
    return debug.upvalueId(get(L, fidx), n);
}

pub fn luaUpvaluejoin(L: *lua_State, f1: c_int, n1: c_int, f2: c_int, n2: c_int) callconv(.c) void {
    const c1 = get(L, f1).asLuaClosure();
    const c2 = get(L, f2).asLuaClosure();
    c1.setUpval(L.heap(), @intCast(n1 - 1), c2.upvals()[@intCast(n2 - 1)]);
}

pub fn luaGetlocal(L: *lua_State, ar: ?*const lua_Debug, n: c_int) callconv(.c) ?[*:0]const u8 {
    const a = ar orelse {
        // Parameters of the Lua function on top, which stays.
        const f = top(L, 1);
        if (f.tag != .lua_closure or n <= 0) return null;
        const name = debuginfo.localName(f.asLuaClosure().proto, @intCast(n), 0) orelse return null;
        return @ptrCast(name.ptr);
    };
    const loc = debug.findLocal(L, a.i_ci - 1, n) orelse return null;
    push(L, L.stack[loc[1]]);
    return @ptrCast(loc[0].ptr);
}

pub fn luaSetlocal(L: *lua_State, ar: *const lua_Debug, n: c_int) callconv(.c) ?[*:0]const u8 {
    const loc = debug.findLocal(L, ar.i_ci - 1, n) orelse return null;
    L.top -= 1;
    L.stack[loc[1]] = L.stack[L.top];
    return @ptrCast(loc[0].ptr);
}

// ---------------------------------------------------------------------------
// Hooks
// ---------------------------------------------------------------------------

/// The hook the interpreter calls while a thread has a C hook: calls it
/// protected, with `event`, `currentline`, and the frame filled in, as
/// `luaD_hook` does. An error it raises unwinds from here.
fn cHook(th: *Thread, event: Thread.HookEvent, line: i32, frame: usize) Error!void {
    const h = hookSlot(th).* orelse return;
    var ar: lua_Debug = undefined;
    ar.event = @intFromEnum(event);
    ar.currentline = line;
    ar.i_ci = frame + 1;
    if (protect(th, h, @intFromPtr(&ar), 0) == jmp.aborted) return failure.err;
}

/// What `lua_gethook` returns while the debug library's hook is set: a C
/// function that runs it, which `lua_sethook` turns back into it.
fn luaHook(L: *lua_State, ar: *lua_Debug) callconv(.c) void {
    check(L, debug.hookf(L, @enumFromInt(ar.event), ar.currentline, ar.i_ci - 1));
}

pub fn luaSethook(L: *lua_State, func: ?lua_Hook, mask: c_int, count: c_int) callconv(.c) void {
    const m: u8 = @truncate(@as(c_uint, @bitCast(mask)));
    const f = func orelse return vm.setHook(L, null, 0, count);
    if (f == &luaHook) return vm.setHook(L, &debug.hookf, m, count);
    hookSlot(L).* = f;
    vm.setHook(L, &cHook, m, count);
}

pub fn luaGethook(L: *lua_State) callconv(.c) ?lua_Hook {
    const h = L.hook orelse return null;
    if (h == &cHook) return hookSlot(L).*;
    return &luaHook;
}

pub fn luaGethookmask(L: *lua_State) callconv(.c) c_int {
    const th: *Thread = L;
    return th.hookmask;
}

pub fn luaGethookcount(L: *lua_State) callconv(.c) c_int {
    const th: *Thread = L;
    return th.basehookcount;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn oomReader(L: *lua_State, data: ?*anyopaque, size: *usize) callconv(.c) ?[*]const u8 {
    _ = L;
    const parts = [_][]const u8{ "local t = {} for i = 1, 40 do ", "t[i] = i .. 'x' end return t" };
    const n: *usize = @ptrCast(@alignCast(data.?));
    if (n.* == parts.len) return null;
    defer n.* += 1;
    size.* = parts[n.*].len;
    return parts[n.*].ptr;
}

fn oomRaise(L: *lua_State) callconv(.c) c_int {
    luaPushvalue(L, registry_index - 1);
    return luaError(L);
}

fn oomUdata(L: *lua_State) callconv(.c) c_int {
    _ = luaNewuserdatauv(L, 100, 1);
    return 1;
}

/// Allocates through C-API calls of each kind: loads in pieces, a call,
/// a protected call whose callee raises, strings, tables, userdata.
fn oomBody(L: *lua_State) callconv(.c) c_int {
    var n: usize = 0;
    if (luaLoad(L, &oomReader, &n, "=oom", null) != lua_ok) return luaError(L);
    luaCallk(L, 0, 1, 0, null);
    for (1..20) |i| {
        luaPushinteger(L, @intCast(i));
        _ = luaPushstring(L, "-k");
        luaConcat(L, 2);
        luaSeti(L, -2, @intCast(100 + i));
    }
    _ = luaPushstring(L, "raised");
    luaPushcclosure(L, &oomRaise, 1);
    if (luaPcallk(L, 0, 0, 0, 0, null) != lua_ok) {
        // The upvalue, or the memory error from creating the closure
        // or from the call.
        var len: usize = 0;
        const msg = luaTolstring(L, -1, &len).?[0..len];
        if (!std.mem.eql(u8, msg, "raised")) return luaError(L);
        luaSettop(L, -2);
    }
    luaPushcclosure(L, &oomUdata, 0);
    luaCallk(L, 0, 1, 0, null);
    luaSettop(L, -2);
    return 1;
}

test "allocation failure anywhere under C-API calls is clean" {
    const api = @import("../api.zig");
    var i: usize = 0;
    while (true) : (i += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = i });
        const s = api.State.init(failing.allocator(), .{}) catch continue;
        defer s.close();
        const th: *Thread = @ptrCast(@alignCast(s));
        const c = newCClosure(th, &oomBody, 0) catch continue;
        th.ensureStack(1) catch continue;
        push(th, .nativeClosure(c));
        const st = luaPcallk(th, 0, 1, 0, 0, null);
        if (st == lua_ok) {
            try std.testing.expectEqual(@as(c_int, 5), luaType(th, -1));
            luaSettop(th, 0);
            if (!failing.has_induced_failure) break;
            continue;
        }
        try std.testing.expectEqual(@as(c_int, lua_errmem), st);
        var len: usize = 0;
        try std.testing.expectEqualStrings("not enough memory", luaTolstring(th, -1, &len).?[0..len]);
        luaSettop(th, 0);
    }
    try std.testing.expect(i > 50);
}

// The C names of this file's functions, as the headers declare them.
comptime {
    @export(&luaNewthread, .{ .name = "lua_newthread" });
    @export(&luaClosethread, .{ .name = "lua_closethread" });
    @export(&luaAtpanic, .{ .name = "lua_atpanic" });
    @export(&luaVersion, .{ .name = "lua_version" });
    @export(&luaAbsindex, .{ .name = "lua_absindex" });
    @export(&luaGettop, .{ .name = "lua_gettop" });
    @export(&luaSettop, .{ .name = "lua_settop" });
    @export(&luaPushvalue, .{ .name = "lua_pushvalue" });
    @export(&luaRotate, .{ .name = "lua_rotate" });
    @export(&luaCopy, .{ .name = "lua_copy" });
    @export(&luaCheckstack, .{ .name = "lua_checkstack" });
    @export(&luaXmove, .{ .name = "lua_xmove" });
    @export(&luaIsnumber, .{ .name = "lua_isnumber" });
    @export(&luaIsstring, .{ .name = "lua_isstring" });
    @export(&luaIscfunction, .{ .name = "lua_iscfunction" });
    @export(&luaIsinteger, .{ .name = "lua_isinteger" });
    @export(&luaIsuserdata, .{ .name = "lua_isuserdata" });
    @export(&luaType, .{ .name = "lua_type" });
    @export(&luaTypename, .{ .name = "lua_typename" });
    @export(&luaTonumberx, .{ .name = "lua_tonumberx" });
    @export(&luaTointegerx, .{ .name = "lua_tointegerx" });
    @export(&luaToboolean, .{ .name = "lua_toboolean" });
    @export(&luaTolstring, .{ .name = "lua_tolstring" });
    @export(&luaRawlen, .{ .name = "lua_rawlen" });
    @export(&luaTocfunction, .{ .name = "lua_tocfunction" });
    @export(&luaTouserdata, .{ .name = "lua_touserdata" });
    @export(&luaTothread, .{ .name = "lua_tothread" });
    @export(&luaTopointer, .{ .name = "lua_topointer" });
    @export(&luaArith, .{ .name = "lua_arith" });
    @export(&luaRawequal, .{ .name = "lua_rawequal" });
    @export(&luaCompare, .{ .name = "lua_compare" });
    @export(&luaPushnil, .{ .name = "lua_pushnil" });
    @export(&luaPushnumber, .{ .name = "lua_pushnumber" });
    @export(&luaPushinteger, .{ .name = "lua_pushinteger" });
    @export(&luaPushlstring, .{ .name = "lua_pushlstring" });
    @export(&luaPushexternalstring, .{ .name = "lua_pushexternalstring" });
    @export(&luaPushstring, .{ .name = "lua_pushstring" });
    @export(&luaPushvfstring, .{ .name = "lua_pushvfstring" });
    // aarch64 Linux has no Zig `...` to read (`va.zig`).
    @export(if (va.native) &luaPushfstring else &va.Entry(&luaPushvfstring).entry, .{ .name = "lua_pushfstring" });
    @export(&luaPushcclosure, .{ .name = "lua_pushcclosure" });
    @export(&luaPushboolean, .{ .name = "lua_pushboolean" });
    @export(&luaPushlightuserdata, .{ .name = "lua_pushlightuserdata" });
    @export(&luaPushthread, .{ .name = "lua_pushthread" });
    @export(&luaGetglobal, .{ .name = "lua_getglobal" });
    @export(&luaGettable, .{ .name = "lua_gettable" });
    @export(&luaGetfield, .{ .name = "lua_getfield" });
    @export(&luaGeti, .{ .name = "lua_geti" });
    @export(&luaRawget, .{ .name = "lua_rawget" });
    @export(&luaRawgeti, .{ .name = "lua_rawgeti" });
    @export(&luaRawgetp, .{ .name = "lua_rawgetp" });
    @export(&luaCreatetable, .{ .name = "lua_createtable" });
    @export(&luaNewuserdatauv, .{ .name = "lua_newuserdatauv" });
    @export(&luaGetmetatable, .{ .name = "lua_getmetatable" });
    @export(&luaGetiuservalue, .{ .name = "lua_getiuservalue" });
    @export(&luaSetglobal, .{ .name = "lua_setglobal" });
    @export(&luaSettable, .{ .name = "lua_settable" });
    @export(&luaSetfield, .{ .name = "lua_setfield" });
    @export(&luaSeti, .{ .name = "lua_seti" });
    @export(&luaRawset, .{ .name = "lua_rawset" });
    @export(&luaRawseti, .{ .name = "lua_rawseti" });
    @export(&luaRawsetp, .{ .name = "lua_rawsetp" });
    @export(&luaSetmetatable, .{ .name = "lua_setmetatable" });
    @export(&luaSetiuservalue, .{ .name = "lua_setiuservalue" });
    @export(&luaCallk, .{ .name = "lua_callk" });
    @export(&luaPcallk, .{ .name = "lua_pcallk" });
    @export(&luaLoad, .{ .name = "lua_load" });
    @export(&luaYieldk, .{ .name = "lua_yieldk" });
    @export(&luaResume, .{ .name = "lua_resume" });
    @export(&luaStatus, .{ .name = "lua_status" });
    @export(&luaIsyieldable, .{ .name = "lua_isyieldable" });
    @export(&luaWarning, .{ .name = "lua_warning" });
    @export(if (va.native) &luaGc else &va.Entry(&luaGcv).entry, .{ .name = "lua_gc" });
    @export(&luaError, .{ .name = "lua_error" });
    @export(&luaNext, .{ .name = "lua_next" });
    @export(&luaConcat, .{ .name = "lua_concat" });
    @export(&luaLen, .{ .name = "lua_len" });
    @export(&luaNumbertocstring, .{ .name = "lua_numbertocstring" });
    @export(&luaStringtonumber, .{ .name = "lua_stringtonumber" });
    @export(&luaGetallocf, .{ .name = "lua_getallocf" });
    @export(&luaGetstack, .{ .name = "lua_getstack" });
    @export(&luaGetinfo, .{ .name = "lua_getinfo" });
    @export(&luaGetupvalue, .{ .name = "lua_getupvalue" });
    @export(&luaSetupvalue, .{ .name = "lua_setupvalue" });
    @export(&luaUpvalueid, .{ .name = "lua_upvalueid" });
    @export(&luaUpvaluejoin, .{ .name = "lua_upvaluejoin" });
    @export(&luaGetlocal, .{ .name = "lua_getlocal" });
    @export(&luaSetlocal, .{ .name = "lua_setlocal" });
    @export(&luaSethook, .{ .name = "lua_sethook" });
    @export(&luaGethook, .{ .name = "lua_gethook" });
    @export(&luaGethookmask, .{ .name = "lua_gethookmask" });
    @export(&luaGethookcount, .{ .name = "lua_gethookcount" });
    @export(&luaToclose, .{ .name = "lua_toclose" });
    @export(&luaCloseslot, .{ .name = "lua_closeslot" });
    @export(&luaDump, .{ .name = "lua_dump" });
    @export(&luaSetwarnf, .{ .name = "lua_setwarnf" });
    @export(&luaSetallocf, .{ .name = "lua_setallocf" });
}

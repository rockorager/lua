//! One Lua universe: the heap, the string table, the registry and globals,
//! the main thread, and the metatables of the basic types. Threads of one
//! state share all of it.

const State = @This();

const std = @import("std");
const gc = @import("gc.zig");
const Value = @import("Value.zig");
const String = @import("String.zig");
const Table = @import("Table.zig");
const Thread = @import("Thread.zig");

const Error = Value.Error;

heap: gc.Heap,
strings: String.Interner,
/// The hash seed, random per state unless `Options.seed` fixes it.
seed: u64,
main: *Thread,
/// The registry: `registry[1]` is the main thread and `registry[2]` the
/// globals table, as in PUC-Rio (`LUA_RIDX_MAINTHREAD`, `LUA_RIDX_GLOBALS`).
registry: *Table,
globals: *Table,
/// Metatables for values that have no metatable of their own, by basic
/// type. Tables and full userdata use their own.
metatables: [Value.Type.count]?*Table = @splat(null),
/// The metamethod names, interned and fixed.
tm_names: [Tm.count]*String,
/// The error object for allocation failures, fixed.
memerr: *String,
/// "__name", the metafield `typeName` reads, and "n", the count field of
/// vararg tables; fixed.
name_key: *String,
n_key: *String,

/// Metamethod events, in PUC-Rio's order (`ltm.h`). The first six are the
/// ones `Table.flags` caches the absence of.
pub const Tm = enum(u8) {
    index,
    newindex,
    gc,
    mode,
    len,
    eq,
    add,
    sub,
    mul,
    mod,
    pow,
    div,
    idiv,
    band,
    bor,
    bxor,
    shl,
    shr,
    unm,
    bnot,
    lt,
    le,
    concat,
    call,
    close,

    pub const count = @typeInfo(Tm).@"enum".fields.len;

    /// The field name, such as "__index".
    pub fn name(tm: Tm) []const u8 {
        return switch (tm) {
            inline else => |t| "__" ++ @tagName(t),
        };
    }
};

pub const Options = struct {
    /// Fixes the hash seed, for reproducible runs. By default it mixes
    /// addresses that ASLR randomizes, as PUC-Rio's `luai_makeseed` does.
    seed: ?u64 = null,
};

/// A new state with an empty registry and globals. Every byte it ever
/// allocates comes from `gpa`.
pub fn create(gpa: std.mem.Allocator, options: Options) error{OutOfMemory}!*State {
    const state = try gpa.create(State);
    errdefer gpa.destroy(state);
    var local: u8 = 0;
    const seed = options.seed orelse std.hash.Wyhash.hash(
        @intFromPtr(state),
        std.mem.asBytes(&[_]usize{ @intFromPtr(&local), @intFromPtr(&create), @intFromPtr(&gpa) }),
    );
    state.* = .{
        .heap = .{ .backing = gpa },
        .strings = undefined,
        .seed = seed,
        .main = undefined,
        .registry = undefined,
        .globals = undefined,
        .tm_names = undefined,
        .memerr = undefined,
        .name_key = undefined,
        .n_key = undefined,
    };
    state.strings = try .init(&state.heap, seed);
    errdefer {
        gc.freeAll(&state.heap);
        state.strings.deinit(&state.heap);
    }
    state.memerr = try state.strings.create(&state.heap, "not enough memory");
    state.memerr.header.marked |= gc.mark.fixed;
    state.name_key = try state.strings.create(&state.heap, "__name");
    state.name_key.header.marked |= gc.mark.fixed;
    state.n_key = try state.strings.create(&state.heap, "n");
    state.n_key.header.marked |= gc.mark.fixed;
    for (&state.tm_names, 0..) |*n, i| {
        n.* = try state.strings.create(&state.heap, @as(Tm, @enumFromInt(i)).name());
        n.*.header.marked |= gc.mark.fixed;
    }
    state.main = try Thread.create(state);
    // The main thread can never yield.
    state.main.nny = 1;
    state.registry = try Table.create(&state.heap, 2, 0);
    state.globals = try Table.create(&state.heap, 0, 0);
    try state.registry.setInt(&state.heap, 1, .thread(state.main));
    try state.registry.setInt(&state.heap, 2, .table(state.globals));
    return state;
}

/// Frees the state and every object in it.
pub fn destroy(state: *State) void {
    const gpa = state.heap.backing;
    gc.freeAll(&state.heap);
    state.strings.deinit(&state.heap);
    std.debug.assert(state.heap.bytes == 0);
    gpa.destroy(state);
}

/// A string with these bytes (interned when short).
pub fn newString(state: *State, b: []const u8) error{OutOfMemory}!*String {
    return state.strings.create(&state.heap, b);
}

/// A new table presized for `narray` sequence slots and `nhash` other keys.
pub fn newTable(state: *State, narray: u32, nhash: u32) error{OutOfMemory}!*Table {
    return Table.create(&state.heap, narray, nhash);
}

/// The metatable of any value.
pub fn metatableOf(state: *const State, v: Value) ?*Table {
    return switch (v.tag) {
        .table => v.asTable().metatable,
        .userdata => v.asUserdata().metatable,
        else => state.metatables[@intFromEnum(v.typeOf())],
    };
}

/// Sets the metatable of any value (`lua_setmetatable`): a table's or
/// full userdata's own, else the one its basic type shares.
pub fn setMetatable(state: *State, v: Value, mt: ?*Table) void {
    const mtv: Value = if (mt) |t| .table(t) else .nil;
    switch (v.tag) {
        .table => {
            v.asTable().metatable = mt;
            gc.barrier(&state.heap, &v.asTable().header, mtv);
        },
        .userdata => {
            v.asUserdata().metatable = mt;
            gc.barrier(&state.heap, &v.asUserdata().header, mtv);
        },
        else => state.metatables[@intFromEnum(v.typeOf())] = mt,
    }
}

/// The handler for event `tm` in metatable `mt`, or null. For the fast
/// events a miss is remembered in `mt.flags` until a key is added to `mt`.
pub inline fn fastTm(state: *const State, mt: ?*Table, tm: Tm) ?Value {
    const t = mt orelse return null;
    const bit = @as(u8, 1) << @intCast(@intFromEnum(tm));
    if (t.flags & bit != 0) return null;
    const v = t.getShortStr(state.tm_names[@intFromEnum(tm)]);
    if (v.isNil()) {
        t.flags |= bit;
        return null;
    }
    return v;
}

/// The type name error messages use, `luaT_objtypename`: a string
/// `__name` field in the metatable of a table or full userdata, else the
/// basic type's name.
pub fn typeName(state: *const State, v: Value) []const u8 {
    const mt = switch (v.tag) {
        .table => v.asTable().metatable,
        .userdata => v.asUserdata().metatable,
        else => null,
    };
    if (mt) |t| {
        const n = t.getShortStr(state.name_key);
        if (n.isString()) return n.asString().bytes();
    }
    return v.typeOf().name();
}

/// The handler for any event `tm` of value `v`, or null.
pub fn tmOf(state: *const State, v: Value, tm: Tm) ?Value {
    const mt = state.metatableOf(v) orelse return null;
    const h = mt.getShortStr(state.tm_names[@intFromEnum(tm)]);
    return if (h.isNil()) null else h;
}

/// A full collection now.
pub fn collect(state: *State) void {
    gc.fullCollect(state);
}

/// Collects if the heap has grown past its threshold. Call only at safe
/// points: every live value reachable from a root or below some frame's
/// top.
pub inline fn checkGc(state: *State) void {
    if (state.heap.bytes >= state.heap.threshold) gc.fullCollect(state);
}

const testing = std.testing;

test "metamethod names and the registry layout" {
    const state = try State.create(testing.allocator, .{ .seed = 7 });
    defer state.destroy();
    try testing.expectEqualStrings("__index", state.tm_names[@intFromEnum(Tm.index)].bytes());
    try testing.expectEqualStrings("__close", state.tm_names[@intFromEnum(Tm.close)].bytes());
    try testing.expectEqual(state.main, state.registry.getInt(1).asThread());
    try testing.expectEqual(state.globals, state.registry.getInt(2).asTable());
}

test "the absence cache answers repeated misses and sees new handlers" {
    const state = try State.create(testing.allocator, .{});
    defer state.destroy();
    const mt = try state.newTable(0, 0);
    try testing.expectEqual(@as(?Value, null), state.fastTm(mt, .index));
    try testing.expect(mt.flags & 1 != 0);
    try testing.expectEqual(@as(?Value, null), state.fastTm(mt, .index));
    try mt.setShortStr(&state.heap, state.tm_names[@intFromEnum(Tm.index)], .true);
    try testing.expect(state.fastTm(mt, .index).?.isFalsy() == false);
    try testing.expectEqual(@as(?Value, null), state.fastTm(null, .eq));
}

test "a state never leaks, and allocation failure at any point is clean" {
    // Fail each allocation of `create` in turn.
    var i: usize = 0;
    while (true) : (i += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = i });
        const state = State.create(failing.allocator(), .{}) catch continue;
        state.destroy();
        break;
    }
    try testing.expect(i > 3);
}

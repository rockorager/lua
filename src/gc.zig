//! The collector: precise, non-moving, stop-the-world mark and sweep for
//! now (plan decision 9). Every collectable object starts with a `Header`,
//! is linked into its `Heap`'s object list when created, and is freed only
//! here or by `State.destroy`. All memory the Lua universe uses, objects and
//! their parts alike, goes through `Heap.allocator()`, which counts bytes for
//! pacing and `collectgarbage("count")`.
//!
//! Collection runs only at safe points (`State.checkGc`), never inside an
//! allocation, so an object being built is never seen half done. Objects
//! with children sit on an intrusive gray list through their `gclist`
//! field, so marking allocates nothing and cannot fail.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("Value.zig");
const String = @import("String.zig");
const Table = @import("Table.zig");
const Proto = @import("Proto.zig");
const Thread = @import("Thread.zig");
const Userdata = @import("Userdata.zig");
const State = @import("State.zig");

/// The header every collectable object starts with.
pub const Header = struct {
    /// The next object in the heap's list of all objects.
    next: ?*Header,
    tag: Value.Tag,
    marked: u8,
};

/// Bits of `Header.marked`.
pub const mark = struct {
    /// Reached in the current collection.
    pub const black: u8 = 1 << 0;
    /// Never collected: the memory error message, metamethod names, and
    /// other strings the state holds for its whole life.
    pub const fixed: u8 = 1 << 1;
};

/// The collector's allocation accounting and object list.
pub const Heap = struct {
    backing: Allocator,
    /// Bytes currently allocated through `allocator()`.
    bytes: usize = 0,
    /// Collect once `bytes` reaches this.
    threshold: usize = initial_threshold,
    /// Every collectable object, newest first.
    objects: ?*Header = null,
    /// Objects reached but not yet traversed, linked through `gclist`.
    gray: ?*Header = null,
    /// Completed collections.
    cycles: usize = 0,
    /// Collect at every safe point, to shake out missing roots in tests.
    stress: bool = false,

    pub const initial_threshold = 256 * 1024;
    /// The next collection starts when the heap grows this much, in percent
    /// of what survived the last one (PUC-Rio's `pause`).
    pub const pause = 100;

    /// The counting allocator. Every byte of a Lua universe goes through it.
    pub fn allocator(heap: *Heap) Allocator {
        return .{ .ptr = heap, .vtable = &vtable };
    }

    /// Links a new object into the heap.
    pub fn link(heap: *Heap, h: *Header, tag: Value.Tag) void {
        h.* = .{ .next = heap.objects, .tag = tag, .marked = 0 };
        heap.objects = h;
    }

    const vtable: Allocator.VTable = .{
        .alloc = countAlloc,
        .resize = countResize,
        .remap = countRemap,
        .free = countFree,
    };

    fn countAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const heap: *Heap = @ptrCast(@alignCast(ctx));
        const p = heap.backing.rawAlloc(len, alignment, ret) orelse return null;
        heap.bytes += len;
        return p;
    }

    fn countResize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) bool {
        const heap: *Heap = @ptrCast(@alignCast(ctx));
        if (!heap.backing.rawResize(memory, alignment, new_len, ret)) return false;
        heap.bytes = heap.bytes - memory.len + new_len;
        return true;
    }

    fn countRemap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret: usize) ?[*]u8 {
        const heap: *Heap = @ptrCast(@alignCast(ctx));
        const p = heap.backing.rawRemap(memory, alignment, new_len, ret) orelse return null;
        heap.bytes = heap.bytes - memory.len + new_len;
        return p;
    }

    fn countFree(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const heap: *Heap = @ptrCast(@alignCast(ctx));
        heap.backing.rawFree(memory, alignment, ret);
        heap.bytes -= memory.len;
    }
};

/// The write barrier for a store of `v` into the object `parent` (an
/// upvalue, a closure, or a userdata's user value). Stop-the-world marking
/// needs none; every store calls it so incremental marking can land here.
pub inline fn barrier(heap: *Heap, parent: *Header, v: Value) void {
    _ = heap;
    _ = parent;
    _ = v;
}

/// The backward write barrier for a store of `v` into table `t`.
pub inline fn barrierBack(heap: *Heap, t: *Table, v: Value) void {
    _ = heap;
    _ = t;
    _ = v;
}

/// A full collection: mark from the roots, then sweep.
pub fn fullCollect(state: *State) void {
    const heap = &state.heap;
    markRoots(state);
    while (heap.gray) |h| {
        heap.gray = gclist(h).*;
        traverse(state, h);
    }
    state.strings.sweep(heap);
    sweep(state);
    heap.cycles += 1;
    heap.threshold = if (heap.stress) 0 else @max(heap.bytes + heap.bytes / 100 * Heap.pause, Heap.initial_threshold);
}

fn markRoots(state: *State) void {
    markObject(state, &state.main.header);
    markObject(state, &state.registry.header);
    markObject(state, &state.globals.header);
    for (state.metatables) |mt| if (mt) |t| markObject(state, &t.header);
}

pub inline fn markValue(state: *State, v: Value) void {
    if (v.isCollectable()) markObject(state, v.payload.gc);
}

fn markObject(state: *State, h: *Header) void {
    if (h.marked & mark.black != 0) return;
    h.marked |= mark.black;
    switch (h.tag) {
        .short_string, .long_string => {},
        // An upvalue's value is never another upvalue, so this recursion
        // stops after one level.
        .upval => markValue(state, Proto.Upval.fromHeader(h).v.*),
        else => {
            gclist(h).* = state.heap.gray;
            state.heap.gray = h;
        },
    }
}

fn gclist(h: *Header) *?*Header {
    return switch (h.tag) {
        .table => &@as(*Table, @fieldParentPtr("header", h)).gclist,
        .lua_closure => &@as(*Proto.LuaClosure, @fieldParentPtr("header", h)).gclist,
        .native_closure => &@as(*Proto.NativeClosure, @fieldParentPtr("header", h)).gclist,
        .proto => &@as(*Proto, @fieldParentPtr("header", h)).gclist,
        .thread => &@as(*Thread, @fieldParentPtr("header", h)).gclist,
        .userdata => &@as(*Userdata, @fieldParentPtr("header", h)).gclist,
        else => unreachable,
    };
}

fn traverse(state: *State, h: *Header) void {
    switch (h.tag) {
        .table => traverseTable(state, @fieldParentPtr("header", h)),
        .lua_closure => {
            const c: *Proto.LuaClosure = @fieldParentPtr("header", h);
            markObject(state, &c.proto.header);
            for (c.upvals()) |uv| markObject(state, &uv.header);
        },
        .native_closure => {
            const c: *Proto.NativeClosure = @fieldParentPtr("header", h);
            for (c.upvalues()) |v| markValue(state, v);
        },
        .proto => {
            const p: *Proto = @fieldParentPtr("header", h);
            if (p.source) |s| markObject(state, &s.header);
            for (p.k) |v| markValue(state, v);
            for (p.p) |child| markObject(state, &child.header);
            for (p.upvalues) |u| if (u.name) |s| markObject(state, &s.header);
            for (p.locvars) |l| if (l.name) |s| markObject(state, &s.header);
        },
        .thread => traverseThread(state, @fieldParentPtr("header", h)),
        .userdata => {
            const u: *Userdata = @fieldParentPtr("header", h);
            if (u.metatable) |mt| markObject(state, &mt.header);
            for (u.userValues()) |v| markValue(state, v);
        },
        else => unreachable,
    }
}

fn traverseTable(state: *State, t: *Table) void {
    if (t.metatable) |mt| markObject(state, &mt.header);
    for (0..t.asize) |i| markValue(state, t.arrayGet(@intCast(i)));
    for (t.nodes()) |*n| {
        if (n.val_tag == .nil) {
            // Keep the key for `next`, but stop it holding its object.
            if (n.key_tag.isCollectable()) n.key_tag = .dead_key;
        } else {
            markValue(state, n.keyValue());
            markValue(state, n.value());
        }
    }
}

fn traverseThread(state: *State, th: *Thread) void {
    // Mark up to the highest top any frame may use. Slots above it can hold
    // stale pointers this collection may free, so they become nil.
    var top = th.top;
    for (th.frames.items) |f| top = @max(top, f.top);
    top = @min(top, @as(u32, @intCast(th.stack.len)));
    for (th.stack[0..top]) |v| markValue(state, v);
    @memset(th.stack[top..], Value.nil);
    var uv = th.open_upvals;
    while (uv) |u| : (uv = u.open.next) markObject(state, &u.header);
    markValue(state, th.err);
}

fn sweep(state: *State) void {
    const heap = &state.heap;
    var link_ptr: *?*Header = &heap.objects;
    while (link_ptr.*) |h| {
        if (h.marked & (mark.black | mark.fixed) != 0) {
            h.marked &= ~mark.black;
            link_ptr = &h.next;
        } else {
            link_ptr.* = h.next;
            freeObject(heap, h);
        }
    }
}

/// Frees one object and everything it owns.
pub fn freeObject(heap: *Heap, h: *Header) void {
    switch (h.tag) {
        .short_string, .long_string => String.destroy(heap, @fieldParentPtr("header", h)),
        .table => Table.destroy(heap, @fieldParentPtr("header", h)),
        .lua_closure => Proto.LuaClosure.destroy(heap, @fieldParentPtr("header", h)),
        .native_closure => Proto.NativeClosure.destroy(heap, @fieldParentPtr("header", h)),
        .proto => Proto.destroy(heap, @fieldParentPtr("header", h)),
        .upval => Proto.Upval.destroy(heap, Proto.Upval.fromHeader(h)),
        .thread => Thread.destroy(heap, @fieldParentPtr("header", h)),
        .userdata => Userdata.destroy(heap, @fieldParentPtr("header", h)),
        else => unreachable,
    }
}

/// Frees every object; for `State.destroy`.
pub fn freeAll(heap: *Heap) void {
    // Threads first: closing their open upvalues touches the upvalues.
    var it = heap.objects;
    while (it) |h| : (it = h.next) {
        if (h.tag == .thread) Thread.closeAllUpvals(@fieldParentPtr("header", h));
    }
    while (heap.objects) |h| {
        heap.objects = h.next;
        freeObject(heap, h);
    }
}

const testing = std.testing;

fn countObjects(heap: *Heap) usize {
    var n: usize = 0;
    var it = heap.objects;
    while (it) |h| : (it = h.next) n += 1;
    return n;
}

fn nativeNop(_: *Thread, _: u32) Value.Error!u32 {
    return 0;
}

test "a collection frees exactly the unreachable objects of every kind" {
    const state = try State.create(testing.allocator, .{ .seed = 1 });
    defer state.destroy();
    const heap = &state.heap;
    // Give the globals their node for "live" now, so the baseline has it.
    try state.globals.setStr(heap, try state.newString("live"), .false);
    state.collect();
    const base_objects = countObjects(heap);
    const base_bytes = heap.bytes;

    // Reachable: a table in the globals holding one of each kind.
    const live = try state.newTable(0, 0);
    try state.globals.setStr(heap, try state.newString("live"), .table(live));
    const mt = try state.newTable(0, 0);
    live.metatable = mt;
    const proto = try Proto.create(heap);
    proto.k = try heap.allocator().dupe(Value, &.{.string(try state.newString("a constant"))});
    const lcl = try Proto.LuaClosure.create(heap, proto, 1);
    lcl.setUpval(heap, 0, try Proto.Upval.createClosed(heap, .string(try state.newString("in a closed upvalue"))));
    try live.setInt(heap, 1, .luaClosure(lcl));
    const ncl = try Proto.NativeClosure.create(heap, &nativeNop, 1);
    ncl.setUpvalue(heap, 0, .string(try state.newString("x" ** 50)));
    try live.setInt(heap, 2, .nativeClosure(ncl));
    const ud = try Userdata.create(heap, 24, 1);
    ud.setUserValue(heap, 0, .table(try state.newTable(0, 0)));
    try live.setInt(heap, 3, .userdata(ud));
    // A coroutine whose stack holds a value only an open upvalue shares.
    const co = try Thread.create(state);
    co.push(.string(try state.newString("on a coroutine stack")));
    const open = try co.findUpval(1);
    const cl2 = try Proto.LuaClosure.create(heap, proto, 1);
    cl2.setUpval(heap, 0, open);
    try live.setInt(heap, 4, .luaClosure(cl2));
    try live.setInt(heap, 5, .thread(co));
    const live_objects = countObjects(heap);

    // Unreachable: the same again, referenced from nowhere.
    const junk = try state.newTable(4, 4);
    for (0..100) |i| try junk.setInt(heap, @intCast(i + 1), .table(try state.newTable(0, 0)));
    try junk.setStr(heap, try state.newString("long " ** 20), .int(1));
    _ = try Proto.LuaClosure.create(heap, proto, 0);
    _ = try Proto.NativeClosure.create(heap, &nativeNop, 2);
    _ = try Userdata.create(heap, 100, 3);
    const dead_co = try Thread.create(state);
    dead_co.push(.int(5));
    const dead_uv = try dead_co.findUpval(1);
    _ = dead_uv;
    try testing.expect(countObjects(heap) > live_objects + 100);

    state.collect();
    try testing.expectEqual(live_objects, countObjects(heap));
    try testing.expectEqualStrings("in a closed upvalue", lcl.upvals()[0].v.asString().bytes());
    try testing.expectEqualStrings("x" ** 50, ncl.upvalues()[0].asString().bytes());
    try testing.expect(ud.userValues()[0].isTable());
    try testing.expectEqualStrings("on a coroutine stack", open.v.asString().bytes());
    try testing.expectEqualStrings("a constant", proto.k[0].asString().bytes());

    // Unreference the coroutine but keep a closure over its open upvalue:
    // freeing the thread closes the upvalue, which keeps the value.
    try live.setInt(heap, 5, .nil);
    state.collect();
    try testing.expect(!open.isOpen());
    try testing.expectEqualStrings("on a coroutine stack", open.v.asString().bytes());

    // Drop everything; only the baseline objects remain.
    try state.globals.setStr(heap, try state.newString("live"), .false);
    state.collect();
    try testing.expectEqual(base_objects, countObjects(heap));
    try testing.expectEqual(base_bytes, heap.bytes);
}

test "a key whose value was cleared stays traversable after its object dies" {
    const state = try State.create(testing.allocator, .{});
    defer state.destroy();
    const heap = &state.heap;
    const t = try state.newTable(0, 0);
    try state.globals.setStr(heap, try state.newString("t"), .table(t));
    try t.setStr(heap, try state.newString("a"), .int(1));
    const key = try state.newTable(0, 0);
    try t.set(heap, .table(key), .int(2));
    try t.setStr(heap, try state.newString("b"), .int(3));
    // Mid-traversal, clear the entry whose key is the table, then collect:
    // the key's object is freed, but `next` from it still works.
    var it = try t.next(.nil);
    var visited: usize = 0;
    var cleared = false;
    while (it) |e| : (it = try t.next(e.key)) {
        visited += 1;
        if (e.key.isTable()) {
            try t.set(heap, e.key, .nil);
            state.collect();
            cleared = true;
        }
    }
    try testing.expect(cleared);
    try testing.expectEqual(@as(usize, 3), visited);
    var dead_keys: usize = 0;
    for (t.nodes()) |n| {
        if (n.key_tag == .dead_key) dead_keys += 1;
    }
    try testing.expectEqual(@as(usize, 1), dead_keys);
}

test "the interner drops dead strings and keeps fixed ones" {
    const state = try State.create(testing.allocator, .{});
    defer state.destroy();
    const before = state.strings.count;
    var buf: [16]u8 = undefined;
    for (0..500) |i| _ = try state.newString(try std.fmt.bufPrint(&buf, "tmp{d}", .{i}));
    try testing.expectEqual(before + 500, state.strings.count);
    state.collect();
    try testing.expectEqual(before, state.strings.count);
    try testing.expectEqual(state.tm_names[0], try state.newString("__index"));
}

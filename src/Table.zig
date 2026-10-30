//! A Lua table: an array part for the keys 1..asize and a hash part for
//! the rest (plan decision 8).
//!
//! The array part uses Lua 5.5's compact layout, 9 bytes a slot: one block
//! holds the payloads in reverse order, then a 4-byte length hint, then the
//! tags. `array` points at the hint, so payload `i` is at `array - 8*(i+1)`
//! and tag `i` at `array + 4 + i`, and neither address depends on `asize`.
//!
//! The hash part is PUC-Rio's chained scatter table with Brent's variation:
//! a power-of-two node array where a colliding key goes to a free node and
//! chains from its main position, and a node out of its main position is
//! moved when the key that owns that position arrives. Nodes never move
//! otherwise, which is what lets `next` continue after its loop body assigns
//! to existing fields, nil included: a key whose value becomes nil stays in
//! its node until the next resize.
//!
//! Every function here is raw: no metamethods. Every store calls the
//! collector's write barrier.

const Table = @This();

const std = @import("std");
const gc = @import("gc.zig");
const Value = @import("Value.zig");
const String = @import("String.zig");

const Payload = Value.Payload;
const Tag = Value.Tag;

header: gc.Header,
/// Metamethod-absence cache: bit `e` set means this table, used as a
/// metatable, has no field for fast event `e` (`State.Tm`, the first 6
/// events). Any store that can add a key clears every bit.
flags: u8 = tm_fast_mask,
/// log2 of the number of nodes.
lsizenode: u8 = 0,
/// Size of the array part.
asize: u32 = 0,
/// The compact array block, pointing at its length hint; null when `asize`
/// is zero.
array: ?[*]align(8) u8 = null,
node: [*]Node = &dummy_node,
/// Every node at or above this index has been handed out as a free node.
lastfree: u32 = 0,
metatable: ?*Table = null,
gclist: ?*gc.Header = null,

/// The events whose absence `flags` caches: `__index` through `__eq`.
pub const tm_fast_mask: u8 = 0x3f;

/// Largest array part: 2^31 slots, PUC-Rio's `MAXASIZE` with 32-bit ints.
const max_abits = 31;
/// Largest hash part: 2^30 nodes.
const max_hbits = 30;

/// One hash slot, 24 bytes: the value's payload and tag, the key's tag, the
/// relative offset of the next node in the chain (0 ends it), and the key's
/// payload.
pub const Node = extern struct {
    val: Payload,
    val_tag: Tag,
    key_tag: Tag,
    next: i32,
    key: Payload,

    const empty: Node = .{ .val = .{ .int = 0 }, .val_tag = .nil, .key_tag = .nil, .next = 0, .key = .{ .int = 0 } };

    pub inline fn value(n: *const Node) Value {
        return .{ .payload = n.val, .tag = n.val_tag };
    }

    /// The key; its tag is `dead_key` when the collector dropped it.
    pub inline fn keyValue(n: *const Node) Value {
        return .{ .payload = n.key, .tag = n.key_tag };
    }
};

comptime {
    std.debug.assert(@sizeOf(Node) == 24);
}

/// The node array of every table with an empty hash part. Never written:
/// lookups never match its nil key, and inserts check `isDummy` first.
var dummy_node: [1]Node = .{Node.empty};

pub const SetError = error{ OutOfMemory, IndexIsNil, IndexIsNaN };

pub const Entry = struct { key: Value, value: Value };

/// A new empty table with room for `narray` array slots and `nhash` other
/// keys, linked into the heap.
pub fn create(heap: *gc.Heap, narray: u32, nhash: u32) error{OutOfMemory}!*Table {
    const t = try heap.allocator().create(Table);
    t.* = .{ .header = undefined };
    if (narray > 0 or nhash > 0) {
        t.resize(heap, narray, nhash) catch |e| {
            heap.allocator().destroy(t);
            return e;
        };
    }
    heap.link(&t.header, .table);
    return t;
}

pub fn destroy(heap: *gc.Heap, t: *Table) void {
    freeParts(heap, t.array, t.asize, t.node, t.lsizenode);
    heap.allocator().destroy(t);
}

fn freeParts(heap: *gc.Heap, array: ?[*]align(8) u8, asize: u32, node: [*]Node, lsizenode: u8) void {
    if (array) |a| heap.allocator().free(arrayBlock(a, asize));
    if (node != @as([*]Node, &dummy_node)) heap.allocator().free(node[0..(@as(usize, 1) << @intCast(lsizenode))]);
}

inline fn arrayBlockLen(asize: u32) usize {
    return @as(usize, asize) * 8 + 4 + asize;
}

fn arrayBlock(array: [*]align(8) u8, asize: u32) []align(8) u8 {
    return @alignCast((array - @as(usize, asize) * 8)[0..arrayBlockLen(asize)]);
}

pub inline fn isDummy(t: *const Table) bool {
    return t.node == @as([*]Node, &dummy_node);
}

pub inline fn nodeCount(t: *const Table) u32 {
    return @as(u32, 1) << @intCast(t.lsizenode);
}

/// The hash part's nodes; empty for a table without one.
pub fn nodes(t: *const Table) []Node {
    if (t.isDummy()) return &.{};
    return t.node[0..t.nodeCount()];
}

// The array part.

inline fn payloadPtr(t: *const Table, i: u32) *Payload {
    const p: [*]Payload = @ptrCast(t.array.?);
    return &(p - (@as(usize, i) + 1))[0];
}

inline fn tagPtr(t: *const Table, i: u32) *Tag {
    return @ptrCast(t.array.? + 4 + i);
}

inline fn lenHint(t: *const Table) *u32 {
    return @ptrCast(t.array.?);
}

/// Array slot `i` (key `i + 1`); `i < asize`.
pub inline fn arrayGet(t: *const Table, i: u32) Value {
    std.debug.assert(i < t.asize);
    return .{ .payload = t.payloadPtr(i).*, .tag = t.tagPtr(i).* };
}

inline fn arraySet(t: *Table, i: u32, v: Value) void {
    std.debug.assert(i < t.asize);
    t.payloadPtr(i).* = v.payload;
    t.tagPtr(i).* = v.tag;
}

inline fn arrayIsEmpty(t: *const Table, i: u32) bool {
    return t.tagPtr(i).* == .nil;
}

// Hashing.

inline fn mask(t: *const Table) u32 {
    return t.nodeCount() - 1;
}

inline fn mix(x: u64) u32 {
    // Fibonacci hashing: the multiply spreads sequential keys, and the high
    // half carries the mixed bits. Cheaper than PUC-Rio's modulo by an odd
    // number.
    return @truncate((x *% 0x9E3779B97F4A7C15) >> 32);
}

inline fn hashInt(t: *const Table, i: i64) u32 {
    return mix(@bitCast(i)) & t.mask();
}

fn mainPosition(t: *const Table, tag: Tag, key: Payload) u32 {
    const h: u32 = switch (tag) {
        .int => return t.hashInt(key.int),
        .short_string => @as(*String, @fieldParentPtr("header", key.gc)).hash,
        .long_string => String.hashOf(@fieldParentPtr("header", key.gc)),
        .float => blk: {
            const bits: u64 = @bitCast(key.float);
            break :blk mix(bits ^ (bits >> 29));
        },
        .bool_false => 0,
        .bool_true => 1,
        .light_userdata,
        .native_fn,
        .table,
        .lua_closure,
        .native_closure,
        .userdata,
        .thread,
        => mix(@intFromPtr(key.ptr) >> 3),
        .nil, .dead_key, .proto, .upval => unreachable,
    };
    return h & t.mask();
}

inline fn nextIndex(i: u32, n: *const Node) u32 {
    return i +% @as(u32, @bitCast(n.next));
}

inline fn rel(to: u32, from: u32) i32 {
    return @bitCast(to -% from);
}

// Lookups.

/// Raw `t[key]` for an integer key.
pub inline fn getInt(t: *const Table, key: i64) Value {
    const k: u64 = @bitCast(key -% 1);
    if (k < t.asize) return t.arrayGet(@intCast(k));
    return if (t.getIntNode(key)) |n| n.value() else .nil;
}

fn getIntNode(t: *const Table, key: i64) ?*Node {
    var i = t.hashInt(key);
    while (true) {
        const n = &t.node[i];
        if (n.key_tag == .int and n.key.int == key) return n;
        if (n.next == 0) return null;
        i = nextIndex(i, n);
    }
}

/// Raw `t[s]` for a short string key.
pub inline fn getShortStr(t: *const Table, s: *const String) Value {
    return if (t.getShortStrNode(s)) |n| n.value() else .nil;
}

fn getShortStrNode(t: *const Table, s: *const String) ?*Node {
    std.debug.assert(s.isShort());
    var i = s.hash & t.mask();
    while (true) {
        const n = &t.node[i];
        if (n.key_tag == .short_string and n.key.gc == &s.header) return n;
        if (n.next == 0) return null;
        i = nextIndex(i, n);
    }
}

/// Raw `t[s]` for any string key.
pub fn getStr(t: *const Table, s: *String) Value {
    return if (s.isShort()) t.getShortStr(s) else t.getGeneric(.string(s));
}

/// Raw `t[key]`.
pub fn get(t: *const Table, key: Value) Value {
    return switch (key.tag) {
        .short_string => t.getShortStr(key.asString()),
        .int => t.getInt(key.payload.int),
        .nil => .nil,
        .float => if (Value.floatToInt(key.payload.float)) |i| t.getInt(i) else t.getGeneric(key),
        else => t.getGeneric(key),
    };
}

fn getGeneric(t: *const Table, key: Value) Value {
    return if (t.findNode(key, false)) |n| n.value() else .nil;
}

/// The node holding `key`, which is normalized and not nil. With
/// `dead_ok`, a dead key matches the object it used to hold.
fn findNode(t: *const Table, key: Value, dead_ok: bool) ?*Node {
    var i = t.mainPosition(key.tag, key.payload);
    while (true) {
        const n = &t.node[i];
        if (keyEquals(n, key, dead_ok)) return n;
        if (n.next == 0) return null;
        i = nextIndex(i, n);
    }
}

inline fn keyEquals(n: *const Node, key: Value, dead_ok: bool) bool {
    if (n.key_tag != key.tag) {
        return dead_ok and n.key_tag == .dead_key and key.isCollectable() and n.key.gc == key.payload.gc;
    }
    return switch (key.tag) {
        .nil, .bool_false, .bool_true => true,
        .float => n.key.float == key.payload.float,
        .long_string => String.eqlLong(@fieldParentPtr("header", n.key.gc), key.asString()),
        else => n.key.int == key.payload.int,
    };
}

// Stores.

/// Raw `t[key] = val`. A nil or NaN key is an error; an integral float key
/// is stored as the integer.
pub fn set(t: *Table, heap: *gc.Heap, key: Value, val: Value) SetError!void {
    switch (key.tag) {
        .int => return t.setInt(heap, key.payload.int, val),
        .short_string => return t.setShortStr(heap, key.asString(), val),
        .nil => return error.IndexIsNil,
        .float => {
            if (Value.floatToInt(key.payload.float)) |i| return t.setInt(heap, i, val);
            if (std.math.isNan(key.payload.float)) return error.IndexIsNaN;
        },
        else => {},
    }
    if (t.findNode(key, false)) |n| return t.writeNode(heap, n, val);
    if (val.isNil()) return;
    try t.newKey(heap, key, val);
}

/// Raw `t[key] = val` for an integer key.
pub inline fn setInt(t: *Table, heap: *gc.Heap, key: i64, val: Value) error{OutOfMemory}!void {
    const k: u64 = @bitCast(key -% 1);
    if (k < t.asize) {
        t.arraySet(@intCast(k), val);
        gc.barrierBack(heap, t, val);
        return;
    }
    return t.setIntHash(heap, key, val);
}

fn setIntHash(t: *Table, heap: *gc.Heap, key: i64, val: Value) error{OutOfMemory}!void {
    if (t.getIntNode(key)) |n| return t.writeNode(heap, n, val);
    if (val.isNil()) return;
    t.newKey(heap, .int(key), val) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
}

/// Raw `t[s] = val` for a short string key.
pub fn setShortStr(t: *Table, heap: *gc.Heap, s: *String, val: Value) error{OutOfMemory}!void {
    if (t.getShortStrNode(s)) |n| return t.writeNode(heap, n, val);
    if (val.isNil()) return;
    t.newKey(heap, .string(s), val) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
}

/// Raw `t[s] = val` for any string key.
pub fn setStr(t: *Table, heap: *gc.Heap, s: *String, val: Value) error{OutOfMemory}!void {
    if (s.isShort()) return t.setShortStr(heap, s, val);
    t.set(heap, .string(s), val) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
}

/// Overwrites the value of an existing key. When the slot was nil the key
/// was absent, so the store may add a metamethod.
inline fn writeNode(t: *Table, heap: *gc.Heap, n: *Node, val: Value) void {
    if (n.val_tag == .nil) t.flags = 0;
    n.val = val.payload;
    n.val_tag = val.tag;
    gc.barrierBack(heap, t, val);
}

/// Inserts a key known to be absent, normalized, and not nil, growing the
/// table when the hash part is full.
fn newKey(t: *Table, heap: *gc.Heap, key: Value, val: Value) SetError!void {
    std.debug.assert(!val.isNil());
    if (!t.insert(key, val)) {
        try t.rehash(heap, key);
        // The key may belong in the array part now.
        return t.set(heap, key, val);
    }
    t.flags = 0;
    gc.barrierBack(heap, t, key);
    gc.barrierBack(heap, t, val);
}

/// Places a new key in the hash part, or returns false when no node is
/// free.
fn insert(t: *Table, key: Value, val: Value) bool {
    if (t.isDummy()) return false;
    var mp_i = t.mainPosition(key.tag, key.payload);
    var mp = &t.node[mp_i];
    if (mp.val_tag != .nil) {
        // The main position is taken.
        const f_i = t.freePosition() orelse return false;
        const f = &t.node[f_i];
        var other_i = t.mainPosition(mp.key_tag, mp.key);
        if (other_i != mp_i) {
            // The occupant is out of its own main position: move it to the
            // free node and give its place to the new key.
            while (nextIndex(other_i, &t.node[other_i]) != mp_i) other_i = nextIndex(other_i, &t.node[other_i]);
            t.node[other_i].next = rel(f_i, other_i);
            f.* = mp.*;
            if (mp.next != 0) {
                f.next += rel(mp_i, f_i);
                mp.next = 0;
            }
            mp.val_tag = .nil;
        } else {
            // The occupant owns this position: chain the new key after it,
            // in the free node.
            std.debug.assert(f.next == 0);
            if (mp.next != 0) f.next = rel(nextIndex(mp_i, mp), f_i);
            mp.next = rel(f_i, mp_i);
            mp_i = f_i;
            mp = f;
        }
    }
    mp.key = key.payload;
    mp.key_tag = key.tag;
    mp.val = val.payload;
    mp.val_tag = val.tag;
    return true;
}

fn freePosition(t: *Table) ?u32 {
    while (t.lastfree > 0) {
        t.lastfree -= 1;
        if (t.node[t.lastfree].key_tag == .nil) return t.lastfree;
    }
    return null;
}

// Resizing.

/// ceil(log2(x)) for x >= 1.
inline fn ceilLog2(x: u64) u7 {
    return if (x <= 1) 0 else @intCast(64 - @clz(x - 1));
}

const Counters = struct {
    /// nums[i]: integer keys k with 2^(i-1) < k <= 2^i.
    nums: [max_abits + 1]u32 = @splat(0),
    /// Keys that could go to the array part.
    na: u32 = 0,
    total: u32 = 0,
    deleted: bool = false,

    fn countInt(c: *Counters, key: i64) void {
        if (key >= 1 and key <= (@as(i64, 1) << max_abits)) {
            c.nums[ceilLog2(@intCast(key))] += 1;
            c.na += 1;
        }
    }
};

/// Picks new sizes for both parts when an insert finds no free node, as
/// Lua 5.5 does: the array part is the largest power of two n at most 3
/// times the number of integer keys in 1..n, since a compact slot costs
/// about a third of a node.
fn rehash(t: *Table, heap: *gc.Heap, extra: Value) error{OutOfMemory}!void {
    var c: Counters = .{ .total = 1 };
    if (extra.tag == .int) c.countInt(extra.payload.int);
    for (t.nodes()) |*n| {
        if (n.val_tag == .nil) {
            c.deleted = true;
        } else {
            c.total += 1;
            if (n.key_tag == .int) c.countInt(n.key.int);
        }
    }
    var new_asize = t.asize;
    if (c.na > 0) {
        // Count the array part slice by slice: keys (2^(lg-1), 2^lg].
        var key: u64 = 1;
        var lg: usize = 0;
        while (lg <= max_abits and key <= t.asize) : (lg += 1) {
            const lim = @min(@as(u64, 1) << @intCast(lg), t.asize);
            var used: u32 = 0;
            while (key <= lim) : (key += 1) used += @intFromBool(!t.arrayIsEmpty(@intCast(key - 1)));
            c.nums[lg] += used;
            c.na += used;
            c.total += used;
        }
        new_asize = computeSizes(&c);
    }
    // Otherwise no new key can go to the array part, which keeps its size
    // and its keys, and `total` counts only the keys bound for the hash.
    var nhash = c.total - c.na;
    if (c.deleted) nhash += nhash >> 2;
    try t.resize(heap, new_asize, nhash);
}

fn computeSizes(c: *Counters) u32 {
    var a: u64 = 0;
    var na: u32 = 0;
    var optimal: u64 = 0;
    var i: usize = 0;
    var twotoi: u64 = 1;
    while (i <= max_abits and twotoi <= @as(u64, c.na) * 3) : ({
        i += 1;
        twotoi *= 2;
    }) {
        a += c.nums[i];
        if (c.nums[i] > 0 and twotoi <= a * 3) {
            optimal = twotoi;
            na = @intCast(a);
        }
    }
    c.na = na;
    return @intCast(optimal);
}

/// Resizes both parts: `new_asize` array slots and room for `nhash` keys
/// in the hash part. On failure the table is unchanged.
pub fn resize(t: *Table, heap: *gc.Heap, new_asize: u32, nhash: u32) error{OutOfMemory}!void {
    const gpa = heap.allocator();
    const lsize = if (nhash == 0) 0 else ceilLog2(nhash);
    if (lsize > max_hbits or new_asize > (@as(u64, 1) << max_abits)) return error.OutOfMemory;

    // Allocate both new parts before touching the table.
    const new_node: [*]Node = if (nhash == 0) &dummy_node else blk: {
        const ns = try gpa.alloc(Node, @as(usize, 1) << @intCast(lsize));
        @memset(ns, Node.empty);
        break :blk ns.ptr;
    };
    const new_array: ?[*]align(8) u8 = if (new_asize == 0) null else blk: {
        const block = gpa.alignedAlloc(u8, .@"8", arrayBlockLen(new_asize)) catch |e| {
            if (nhash != 0) gpa.free(new_node[0..(@as(usize, 1) << @intCast(lsize))]);
            return e;
        };
        break :blk @alignCast(block.ptr + @as(usize, new_asize) * 8);
    };

    const old = t.*;
    t.node = new_node;
    t.lsizenode = @intCast(lsize);
    t.lastfree = if (nhash == 0) 0 else t.nodeCount();
    t.array = new_array;
    t.asize = new_asize;

    if (new_asize > 0) {
        const keep = @min(old.asize, new_asize);
        if (keep > 0) {
            // Payloads run backwards from `array`, tags forwards after the
            // hint: one copy each.
            @memcpy(t.array.? - 8 * @as(usize, keep), (old.array.? - 8 * @as(usize, keep))[0 .. 8 * @as(usize, keep)]);
            @memcpy((t.array.? + 4)[0..keep], (old.array.? + 4)[0..keep]);
        }
        @memset((t.array.? + 4 + keep)[0 .. new_asize - keep], @intFromEnum(Tag.nil));
        t.lenHint().* = if (old.asize > 0) @min(old.lenHint().*, new_asize) else 0;
    }
    // Array slots past the new size move to the hash part.
    if (new_asize < old.asize) {
        for (new_asize..old.asize) |i| {
            const v = old.arrayGet(@intCast(i));
            if (!v.isNil()) t.reinsert(.int(@intCast(i + 1)), v);
        }
    }
    for (old.nodes()) |*n| {
        if (n.val_tag != .nil) t.reinsert(n.keyValue(), n.value());
    }
    freeParts(heap, old.array, old.asize, old.node, old.lsizenode);
}

/// Places an entry during a resize, where room is guaranteed.
fn reinsert(t: *Table, key: Value, val: Value) void {
    if (key.tag == .int) {
        const k: u64 = @bitCast(key.payload.int -% 1);
        if (k < t.asize) return t.arraySet(@intCast(k), val);
    }
    const ok = t.insert(key, val);
    std.debug.assert(ok);
}

// Traversal and length.

/// The entry after `key` in traversal order, or null at the end; nil
/// starts the traversal. Fails when `key` is not in the table.
pub fn next(t: *const Table, key: Value) error{InvalidKey}!?Entry {
    var i = try t.traversalIndex(key);
    while (i < t.asize) : (i += 1) {
        if (!t.arrayIsEmpty(i)) return .{ .key = .int(@as(i64, i) + 1), .value = t.arrayGet(i) };
    }
    const ns = t.nodes();
    var j: usize = i - t.asize;
    while (j < ns.len) : (j += 1) {
        if (ns[j].val_tag != .nil) return .{ .key = ns[j].keyValue(), .value = ns[j].value() };
    }
    return null;
}

/// Where traversal resumes after `key`: array slots first, then nodes.
fn traversalIndex(t: *const Table, key: Value) error{InvalidKey}!u32 {
    var k = key;
    switch (k.tag) {
        .nil => return 0,
        .float => if (Value.floatToInt(k.payload.float)) |i| {
            k = .int(i);
        },
        else => {},
    }
    if (k.tag == .int) {
        const u: u64 = @bitCast(k.payload.int -% 1);
        if (u < t.asize) return @intCast(u + 1);
    }
    if (t.isDummy()) return error.InvalidKey;
    const n = t.findNode(k, true) orelse return error.InvalidKey;
    const idx: u32 = @intCast(n - t.node);
    return t.asize + idx + 1;
}

/// A border of the table, the raw `#t`: an n with t[n] non-nil (or n = 0)
/// and t[n+1] nil.
pub fn length(t: *Table) u64 {
    const asize = t.asize;
    if (asize > 0) {
        const hint = t.lenHint();
        var limit = hint.*;
        if (limit == 0) limit = 1;
        if (t.arrayIsEmpty(limit - 1)) {
            // A border lies below the hint; look nearby, then search.
            var n: u32 = 0;
            while (n < 4 and limit > 1) : (n += 1) {
                limit -= 1;
                if (!t.arrayIsEmpty(limit - 1)) {
                    hint.* = limit;
                    return limit;
                }
            }
            const b = t.binarySearch(0, limit);
            hint.* = b;
            return b;
        }
        var n: u32 = 0;
        while (n < 4 and limit < asize) : (n += 1) {
            limit += 1;
            if (t.arrayIsEmpty(limit - 1)) {
                hint.* = limit - 1;
                return limit - 1;
            }
        }
        if (t.arrayIsEmpty(asize - 1)) {
            const b = t.binarySearch(limit, asize);
            hint.* = b;
            return b;
        }
        hint.* = asize;
    }
    if (t.isDummy() or t.getInt(@as(i64, asize) + 1).isNil()) return asize;
    return t.hashSearch(asize);
}

/// A border in (i, j], given t[i] non-nil (or i = 0) and t[j] nil.
fn binarySearch(t: *const Table, i_in: u32, j_in: u32) u32 {
    var i = i_in;
    var j = j_in;
    while (j - i > 1) {
        const m = i + (j - i) / 2;
        if (t.arrayIsEmpty(m - 1)) j = m else i = m;
    }
    return i;
}

/// A border past the array part, given t[asize + 1] is non-nil: double
/// until a nil key, then bisect.
fn hashSearch(t: *const Table, asize: u32) u64 {
    const max: u64 = std.math.maxInt(i64);
    var i: u64 = @as(u64, asize) + 1;
    var j: u64 = i + 1;
    while (!t.getInt(@intCast(j)).isNil()) {
        i = j;
        if (j <= max / 2) {
            j *= 2;
        } else {
            j = max;
            if (t.getInt(@intCast(j)).isNil()) break;
            return j;
        }
    }
    while (j - i > 1) {
        const m = i + (j - i) / 2;
        if (t.getInt(@intCast(m)).isNil()) j = m else i = m;
    }
    return i;
}

const testing = std.testing;

const TestHeap = struct {
    heap: gc.Heap,
    strings: String.Interner,

    fn init(self: *TestHeap) !void {
        self.heap = .{ .backing = testing.allocator };
        self.strings = try .init(&self.heap, 0xfeed);
    }

    fn deinit(self: *TestHeap) void {
        gc.freeAll(&self.heap);
        self.strings.deinit(&self.heap);
        testing.expectEqual(@as(usize, 0), self.heap.bytes) catch @panic("leaked bytes");
        self.* = undefined;
    }

    fn str(self: *TestHeap, b: []const u8) Value {
        return .string(self.strings.create(&self.heap, b) catch @panic("oom"));
    }
};

test "integer keys fill the array part and read back" {
    var h: TestHeap = undefined;
    try h.init();
    defer h.deinit();
    const t = try Table.create(&h.heap, 0, 0);
    for (1..1001) |i| try t.setInt(&h.heap, @intCast(i), .int(@intCast(i * 3)));
    for (1..1001) |i| try testing.expectEqual(@as(i64, @intCast(i * 3)), t.getInt(@intCast(i)).asInt());
    try testing.expect(t.getInt(0).isNil());
    try testing.expect(t.getInt(1001).isNil());
    try testing.expect(t.getInt(-1).isNil());
    // Sequential keys end in the array part, not the hash part.
    try testing.expect(t.asize >= 1000);
    try testing.expectEqual(@as(u64, 1000), t.length());
}

test "string, float, boolean, and object keys" {
    var h: TestHeap = undefined;
    try h.init();
    defer h.deinit();
    const t = try Table.create(&h.heap, 0, 0);
    const other = try Table.create(&h.heap, 0, 0);
    const long = "L" ** 64;
    try t.set(&h.heap, h.str("x"), .int(1));
    try t.set(&h.heap, h.str(long), .int(2));
    try t.set(&h.heap, .float(1.5), .int(3));
    try t.set(&h.heap, .true, .int(4));
    try t.set(&h.heap, .false, .int(5));
    try t.set(&h.heap, .table(other), .int(6));
    try testing.expectEqual(@as(i64, 1), t.get(h.str("x")).asInt());
    // A different long string object with the same bytes finds the key.
    try testing.expectEqual(@as(i64, 2), t.get(h.str(long)).asInt());
    try testing.expectEqual(@as(i64, 3), t.get(.float(1.5)).asInt());
    try testing.expectEqual(@as(i64, 4), t.get(.true).asInt());
    try testing.expectEqual(@as(i64, 5), t.get(.false).asInt());
    try testing.expectEqual(@as(i64, 6), t.get(.table(other)).asInt());
    try testing.expect(t.get(h.str("y")).isNil());
    try testing.expect(t.get(.nil).isNil());
    try testing.expectError(error.IndexIsNil, t.set(&h.heap, .nil, .int(1)));
    try testing.expectError(error.IndexIsNaN, t.set(&h.heap, .float(std.math.nan(f64)), .int(1)));
}

test "integral float keys are the integer keys" {
    var h: TestHeap = undefined;
    try h.init();
    defer h.deinit();
    const t = try Table.create(&h.heap, 0, 0);
    try t.set(&h.heap, .float(2.0), .int(20));
    try t.set(&h.heap, .float(1e15), .int(30));
    try t.set(&h.heap, .float(-0.0), .int(40));
    try testing.expectEqual(@as(i64, 20), t.getInt(2).asInt());
    try testing.expectEqual(@as(i64, 30), t.get(.int(1_000_000_000_000_000)).asInt());
    try testing.expectEqual(@as(i64, 40), t.getInt(0).asInt());
    // Traversal reports the normalized key.
    var it = try t.next(.nil);
    var ints: usize = 0;
    while (it) |e| : (it = try t.next(e.key)) {
        try testing.expect(e.key.isInt());
        ints += 1;
    }
    try testing.expectEqual(@as(usize, 3), ints);
}

test "next visits every key once, even when the loop clears and reassigns fields" {
    var h: TestHeap = undefined;
    try h.init();
    defer h.deinit();
    const t = try Table.create(&h.heap, 0, 0);
    var buf: [16]u8 = undefined;
    for (1..51) |i| try t.setInt(&h.heap, @intCast(i), .int(@intCast(i)));
    for (0..200) |i| try t.set(&h.heap, h.str(try std.fmt.bufPrint(&buf, "k{d}", .{i})), .int(@intCast(i)));
    try t.set(&h.heap, .float(0.25), .int(1));

    var seen: usize = 0;
    var it = try t.next(.nil);
    while (it) |e| : (it = try t.next(e.key)) {
        seen += 1;
        // Clearing the current field and overwriting existing ones is
        // allowed during traversal.
        try t.set(&h.heap, e.key, .nil);
        try t.set(&h.heap, h.str("k0"), .int(-1));
    }
    try testing.expectEqual(@as(usize, 50 + 200 + 1), seen);
    try testing.expectError(error.InvalidKey, t.next(h.str("never a key")));
    // Only the field overwritten after its clearing remains.
    var left: usize = 0;
    it = try t.next(.nil);
    while (it) |e| : (it = try t.next(e.key)) left += 1;
    try testing.expectEqual(@as(usize, 1), left);
}

test "length is a border" {
    var h: TestHeap = undefined;
    try h.init();
    defer h.deinit();
    const t = try Table.create(&h.heap, 0, 0);
    try testing.expectEqual(@as(u64, 0), t.length());
    for (1..11) |i| try t.setInt(&h.heap, @intCast(i), .true);
    try testing.expectEqual(@as(u64, 10), t.length());
    try t.setInt(&h.heap, 10, .nil);
    try testing.expectEqual(@as(u64, 9), t.length());
    try t.setInt(&h.heap, 5, .nil);
    const n = t.length();
    // Either border is valid: 4 or 9.
    try testing.expect(n == 4 or n == 9);
    try testing.expect(!t.getInt(@intCast(n)).isNil() or n == 0);
    try testing.expect(t.getInt(@intCast(n + 1)).isNil());

    // A sequence living in the hash part.
    const u = try Table.create(&h.heap, 0, 0);
    try u.set(&h.heap, h.str("a"), .true);
    var i: i64 = 300;
    while (i >= 1) : (i -= 1) try u.setInt(&h.heap, i, .true);
    try testing.expectEqual(@as(u64, 300), u.length());

    // Presized array, all nil, with a hash-part entry at asize + 1.
    const w = try Table.create(&h.heap, 4, 4);
    try testing.expectEqual(@as(u64, 0), w.length());
    for (1..5) |k| try w.setInt(&h.heap, @intCast(k), .true);
    try w.setInt(&h.heap, 5, .true);
    try w.setInt(&h.heap, 6, .true);
    try testing.expectEqual(@as(u64, 6), w.length());
}

test "sparse integer keys stay in the hash part" {
    var h: TestHeap = undefined;
    try h.init();
    defer h.deinit();
    const t = try Table.create(&h.heap, 0, 0);
    var k: i64 = 1;
    for (0..30) |_| {
        try t.setInt(&h.heap, k, .int(k));
        k *= 3;
    }
    try testing.expect(t.asize <= 4);
    k = 1;
    for (0..30) |_| {
        try testing.expectEqual(k, t.getInt(k).asInt());
        k *= 3;
    }
}

test "a failed resize leaves the table unchanged" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    var heap: gc.Heap = .{ .backing = failing.allocator() };
    var strings: String.Interner = try .init(&heap, 1);
    defer {
        gc.freeAll(&heap);
        strings.deinit(&heap);
    }
    const t = try Table.create(&heap, 0, 0);
    for (1..9) |i| try t.setInt(&heap, @intCast(i), .int(@intCast(i)));
    failing.fail_index = failing.alloc_index;
    var i: i64 = 9;
    while (i < 100) : (i += 1) {
        t.setInt(&heap, i, .int(i)) catch break;
    }
    try testing.expect(i < 100);
    for (1..@intCast(i)) |j| try testing.expectEqual(@as(i64, @intCast(j)), t.getInt(@intCast(j)).asInt());
}

test "metamethod cache bits clear when a key is added" {
    var h: TestHeap = undefined;
    try h.init();
    defer h.deinit();
    const t = try Table.create(&h.heap, 0, 0);
    try testing.expectEqual(tm_fast_mask, t.flags);
    try t.set(&h.heap, h.str("__index"), .true);
    try testing.expectEqual(@as(u8, 0), t.flags);
    t.flags = tm_fast_mask;
    // Overwriting a present field cannot add a metamethod.
    try t.set(&h.heap, h.str("__index"), .false);
    try testing.expectEqual(tm_fast_mask, t.flags);
    try t.set(&h.heap, h.str("__index"), .nil);
    t.flags = tm_fast_mask;
    // Refilling a cleared field can.
    try t.set(&h.heap, h.str("__index"), .true);
    try testing.expectEqual(@as(u8, 0), t.flags);
}

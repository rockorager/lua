//! A Lua string: one allocation holding this header, the bytes, and a
//! trailing zero (plan decision 7). Strings of `max_short_len` bytes or
//! fewer are short: interned in the state's `Interner`, so two short strings
//! are equal exactly when they are the same object. Longer strings are not
//! interned and hash lazily, the first time they are used as a table key.

const String = @This();

const std = @import("std");
const gc = @import("gc.zig");
const Value = @import("Value.zig");

header: gc.Header,
/// Short strings: free for the lexer to mark reserved words (0 means none).
/// Long strings: 1 once `hash` holds the hash.
extra: u8 = 0,
/// Short strings: the length.
shrlen: u8 = 0,
hash: u32,
u: extern union {
    /// Long strings: the length.
    lnglen: usize,
    /// Short strings: the next string in the same intern bucket.
    hnext: ?*String,
},

comptime {
    // PUC-Rio's `TString` layout: the header, then a union of a long
    // string's length and a short string's link.
    std.debug.assert(@sizeOf(String) == 32);
}

/// The longest short string, PUC-Rio's `LUAI_MAXSHORTLEN`.
pub const max_short_len = 40;

pub const alignment: std.mem.Alignment = .of(String);

/// The length in bytes (`tsslen`).
pub inline fn len(s: *const String) usize {
    return if (s.isShort()) s.shrlen else s.u.lnglen;
}

/// The bytes, without the trailing zero.
pub inline fn bytes(s: *const String) []const u8 {
    return s.bytesPtr()[0..s.len()];
}

/// The bytes followed by the zero terminator, for code that needs one.
pub inline fn bytesZ(s: *const String) [:0]const u8 {
    return s.bytesPtr()[0..s.len() :0];
}

inline fn bytesPtr(s: *const String) [*]u8 {
    const p: [*]u8 = @ptrCast(@constCast(s));
    return p + @sizeOf(String);
}

pub inline fn isShort(s: *const String) bool {
    return s.header.tag == .short_string;
}

pub inline fn allocSize(n: usize) usize {
    return @sizeOf(String) + n + 1;
}

/// The seeded hash of `b`. Wyhash: fast on short keys, and the per-state
/// random seed keeps collision attacks out.
pub inline fn hashBytes(seed: u64, b: []const u8) u32 {
    return @truncate(std.hash.Wyhash.hash(seed, b));
}

/// The hash of any string, computing a long string's on first use. Until
/// then a long string's `hash` holds the state's seed, as in PUC-Rio, so
/// table code needs no state to hash a key.
pub inline fn hashOf(s: *String) u32 {
    if (s.header.tag == .long_string and s.extra == 0) {
        s.hash = hashBytes(s.hash, s.bytes());
        s.extra = 1;
    }
    return s.hash;
}

/// Content equality of two long strings.
pub fn eqlLong(a: *const String, b: *const String) bool {
    return a == b or (a.u.lnglen == b.u.lnglen and std.mem.eql(u8, a.bytes(), b.bytes()));
}

/// Allocates a string object with room for `n` bytes, not yet linked: a
/// short one when `n` is at most `max_short_len`.
fn alloc(heap: *gc.Heap, n: usize) error{OutOfMemory}!*String {
    const mem = try heap.stringAllocator().alignedAlloc(u8, alignment, allocSize(n));
    const s: *String = @ptrCast(mem.ptr);
    init(s, 0, n);
    return s;
}

fn init(s: *String, hash: u32, n: usize) void {
    s.* = if (n <= max_short_len)
        .{ .header = undefined, .hash = hash, .shrlen = @intCast(n), .u = .{ .hnext = null } }
    else
        .{ .header = undefined, .hash = hash, .u = .{ .lnglen = n } };
    s.bytesPtr()[n] = 0;
}

/// A new long string of `n` bytes, contents undefined, for building
/// results such as concatenations in place. `n` must exceed
/// `max_short_len`; build shorter results in a buffer and intern them.
pub fn createLong(heap: *gc.Heap, seed: u64, n: usize) error{OutOfMemory}!*String {
    std.debug.assert(n > max_short_len);
    const s = try alloc(heap, n);
    s.hash = @truncate(seed);
    heap.link(&s.header, .long_string);
    return s;
}

/// Makes a long string of the block `mem`, `allocSize(n)` bytes from the
/// heap's `stringAllocator` whose `n` bytes after the header are already
/// the contents: a buffer becomes its string without a copy. `n` must
/// exceed `max_short_len`.
pub fn adoptLong(heap: *gc.Heap, seed: u64, mem: []align(alignment.toByteUnits()) u8, n: usize) *String {
    std.debug.assert(n > max_short_len);
    std.debug.assert(mem.len == allocSize(n));
    const s: *String = @ptrCast(mem.ptr);
    init(s, @truncate(seed), n);
    heap.link(&s.header, .long_string);
    return s;
}

/// The writable bytes of a string made by `createLong` and not yet shared.
pub inline fn mutableBytes(s: *String) []u8 {
    return s.bytesPtr()[0..s.u.lnglen];
}

pub fn destroy(heap: *gc.Heap, s: *String) void {
    const p: [*]align(alignment.toByteUnits()) u8 = @ptrCast(s);
    heap.stringAllocator().free(p[0..allocSize(s.len())]);
}

/// The state's set of short strings, a chained hash set through `hnext`.
pub const Interner = struct {
    buckets: []?*String,
    count: usize = 0,
    seed: u64,

    const initial_buckets = 128;

    pub fn init(heap: *gc.Heap, seed: u64) error{OutOfMemory}!Interner {
        const buckets = try heap.allocator().alloc(?*String, initial_buckets);
        @memset(buckets, null);
        return .{ .buckets = buckets, .seed = seed };
    }

    pub fn deinit(self: *Interner, heap: *gc.Heap) void {
        heap.allocator().free(self.buckets);
        self.* = undefined;
    }

    /// A string with these bytes: the interned one when short, a new one
    /// when long.
    pub fn create(self: *Interner, heap: *gc.Heap, b: []const u8) error{OutOfMemory}!*String {
        if (b.len <= max_short_len) return self.intern(heap, b);
        const s = try createLong(heap, self.seed, b.len);
        @memcpy(s.mutableBytes(), b);
        return s;
    }

    /// The interned short string with these bytes, created if absent.
    pub fn intern(self: *Interner, heap: *gc.Heap, b: []const u8) error{OutOfMemory}!*String {
        std.debug.assert(b.len <= max_short_len);
        const h = hashBytes(self.seed, b);
        var it = self.buckets[h & (self.buckets.len - 1)];
        while (it) |s| : (it = s.u.hnext) {
            if (s.hash == h and s.shrlen == b.len and std.mem.eql(u8, s.bytes(), b)) {
                // Dead but not swept yet: in use again.
                if (heap.isDead(&s.header)) gc.Heap.resurrect(&s.header);
                return s;
            }
        }
        if (self.count >= self.buckets.len) self.grow(heap);
        const s = try alloc(heap, b.len);
        @memcpy(s.bytesPtr()[0..b.len], b);
        s.hash = h;
        heap.link(&s.header, .short_string);
        const slot = &self.buckets[h & (self.buckets.len - 1)];
        s.u.hnext = slot.*;
        slot.* = s;
        self.count += 1;
        return s;
    }

    /// Doubles the buckets. Failure is harmless: chains get longer.
    fn grow(self: *Interner, heap: *gc.Heap) void {
        self.resize(heap, self.buckets.len * 2);
    }

    /// Halves the buckets when a quarter or less is used (`checkSizes`).
    pub fn shrink(self: *Interner, heap: *gc.Heap) void {
        if (self.count < self.buckets.len / 4 and self.buckets.len > initial_buckets) {
            self.resize(heap, self.buckets.len / 2);
        }
    }

    fn resize(self: *Interner, heap: *gc.Heap, n: usize) void {
        const new = heap.allocator().alloc(?*String, n) catch return;
        @memset(new, null);
        for (self.buckets) |head| {
            var it = head;
            while (it) |s| {
                it = s.u.hnext;
                const slot = &new[s.hash & (new.len - 1)];
                s.u.hnext = slot.*;
                slot.* = s;
            }
        }
        heap.allocator().free(self.buckets);
        self.buckets = new;
    }

    /// Drops a short string the collector is about to free.
    pub fn remove(self: *Interner, s: *String) void {
        var link: *?*String = &self.buckets[s.hash & (self.buckets.len - 1)];
        while (link.*.? != s) link = &link.*.?.u.hnext;
        link.* = s.u.hnext;
        self.count -= 1;
    }
};

const testing = std.testing;

test "short strings intern to one object; long strings do not" {
    var heap: gc.Heap = .{ .backing = testing.allocator };
    var interner: Interner = try .init(&heap, 0x1234);
    defer {
        gc.freeAll(&heap);
        interner.deinit(&heap);
        std.debug.assert(heap.bytes == 0);
    }
    const a = try interner.create(&heap, "hello");
    const b = try interner.create(&heap, "hello");
    try testing.expectEqual(a, b);
    try testing.expectEqualStrings("hello", a.bytesZ());
    try testing.expectEqual(@as(u8, 0), a.bytesZ()[5]);

    const long = "x" ** (max_short_len + 1);
    const c = try interner.create(&heap, long);
    const d = try interner.create(&heap, long);
    try testing.expect(c != d);
    try testing.expect(eqlLong(c, d));
    try testing.expect(Value.rawEquals(.string(c), .string(d)));
    try testing.expectEqual(hashOf(c), hashOf(d));

    // The boundary: exactly max_short_len bytes is short.
    const e = try interner.create(&heap, long[0..max_short_len]);
    try testing.expect(e.isShort());
    try testing.expect(!c.isShort());
}

test "the interner keeps every string findable as it grows" {
    var heap: gc.Heap = .{ .backing = testing.allocator };
    var interner: Interner = try .init(&heap, 99);
    defer {
        gc.freeAll(&heap);
        interner.deinit(&heap);
    }
    var first: [1000]*String = undefined;
    var buf: [16]u8 = undefined;
    for (&first, 0..) |*s, i| {
        s.* = try interner.create(&heap, try std.fmt.bufPrint(&buf, "k{d}", .{i}));
    }
    try testing.expect(interner.buckets.len >= 1000);
    for (first, 0..) |s, i| {
        try testing.expectEqual(s, try interner.create(&heap, try std.fmt.bufPrint(&buf, "k{d}", .{i})));
    }
    try testing.expectEqual(@as(usize, 1000), interner.count);
}

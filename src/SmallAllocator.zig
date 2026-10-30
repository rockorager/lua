//! A single-threaded allocator for small blocks, with size classes 8
//! bytes apart up to 128 bytes; larger blocks go to a backing allocator.
//! The `lua` executable allocates strings with it (`State.Options.strings`):
//! a short string takes its header, its bytes, and a zero, which
//! `std.heap.SmpAllocator`'s power-of-two classes round up by a third on
//! average. A class keeps its freed blocks for itself.
//!
//! It is for strings only. Closures, prototypes, and short arrays in
//! classes off 32-byte boundaries made call-heavy programs 20–30% slower
//! (`docs/slop/results/allocator-20261030.md`).

const SmallAllocator = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

backing: Allocator,
/// Each class's freed blocks, a list threaded through them.
frees: [class_count]?*FreeBlock = @splat(null),
/// Each class's unused tail of its newest chunk.
next: [class_count]usize = @splat(0),
end: [class_count]usize = @splat(0),
/// Every chunk, linked through its first bytes, for `deinit`.
chunks: ?*Chunk = null,

const FreeBlock = struct { next: ?*FreeBlock };
const Chunk = struct { next: ?*Chunk };
/// Room for the chunk link, keeping the blocks 16-aligned.
const chunk_header = 16;

const max_small = 128;
const class_count = max_small / 8;
/// What a class takes from the backing allocator when it runs out.
const chunk_len = 64 * 1024;

pub fn init(backing: Allocator) SmallAllocator {
    return .{ .backing = backing };
}

/// Returns every chunk to the backing allocator. Blocks still allocated
/// from the classes go with them.
pub fn deinit(a: *SmallAllocator) void {
    var it = a.chunks;
    while (it) |c| {
        it = c.next;
        const p: [*]u8 = @ptrCast(c);
        a.backing.rawFree(p[0..chunk_len], .@"16", @returnAddress());
    }
    a.* = undefined;
}

pub fn allocator(a: *SmallAllocator) Allocator {
    return .{ .ptr = a, .vtable = &vtable };
}

/// The class for a request, or null for one the backing allocator takes.
/// Blocks sit at multiples of their size from a 16-aligned chunk start, so
/// a 16-aligned request rounds up to a multiple of 16.
fn classOf(len: usize, alignment: Alignment) ?usize {
    if (alignment.compare(.gt, .@"16")) return null;
    const n = if (alignment == .@"16") std.mem.alignForward(usize, len, 16) else len;
    if (n > max_small) return null;
    return (n - 1) / 8;
}

const vtable: Allocator.VTable = .{
    .alloc = alloc,
    .resize = resize,
    .remap = remap,
    .free = free,
};

fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret: usize) ?[*]u8 {
    const a: *SmallAllocator = @ptrCast(@alignCast(ctx));
    const c = classOf(len, alignment) orelse return a.backing.rawAlloc(len, alignment, ret);
    if (a.frees[c]) |b| {
        a.frees[c] = b.next;
        return @ptrCast(b);
    }
    const size = (c + 1) * 8;
    if (a.end[c] - a.next[c] < size) {
        const chunk = a.backing.rawAlloc(chunk_len, .@"16", ret) orelse return null;
        const link: *Chunk = @ptrCast(@alignCast(chunk));
        link.next = a.chunks;
        a.chunks = link;
        a.next[c] = @intFromPtr(chunk) + chunk_header;
        a.end[c] = a.next[c] + (chunk_len - chunk_header) / size * size;
    }
    const p = a.next[c];
    a.next[c] = p + size;
    return @ptrFromInt(p);
}

fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret: usize) bool {
    const a: *SmallAllocator = @ptrCast(@alignCast(ctx));
    const old = classOf(memory.len, alignment);
    const new = classOf(new_len, alignment);
    if (old == null and new == null) return a.backing.rawResize(memory, alignment, new_len, ret);
    return old != null and old == new;
}

fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret: usize) ?[*]u8 {
    const a: *SmallAllocator = @ptrCast(@alignCast(ctx));
    const old = classOf(memory.len, alignment);
    const new = classOf(new_len, alignment);
    if (old == null and new == null) return a.backing.rawRemap(memory, alignment, new_len, ret);
    return if (old != null and old == new) memory.ptr else null;
}

fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret: usize) void {
    const a: *SmallAllocator = @ptrCast(@alignCast(ctx));
    const c = classOf(memory.len, alignment) orelse return a.backing.rawFree(memory, alignment, ret);
    const b: *FreeBlock = @ptrCast(@alignCast(memory.ptr));
    b.next = a.frees[c];
    a.frees[c] = b;
}

test "small blocks are packed, reused, and resized within their class" {
    var sa: SmallAllocator = .init(std.testing.allocator);
    defer sa.deinit();
    const gpa = sa.allocator();
    const x = try gpa.alloc(u8, 42);
    const y = try gpa.alloc(u8, 42);
    try std.testing.expectEqual(@as(usize, 48), @intFromPtr(y.ptr) - @intFromPtr(x.ptr));
    gpa.free(x);
    const z = try gpa.alloc(u8, 41);
    try std.testing.expectEqual(x.ptr, z.ptr);
    try std.testing.expect(gpa.resize(z, 48));
    try std.testing.expect(!gpa.resize(z, 49));
    const v = try gpa.alloc(u128, 3);
    try std.testing.expect(std.mem.isAligned(@intFromPtr(v.ptr), 16));
    // Past the classes, blocks come from the backing allocator, which
    // checks them for leaks.
    const big = try gpa.alloc(u8, 1000);
    const bigger = try gpa.realloc(big, 3000);
    gpa.free(bigger);
}

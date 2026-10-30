//! A full userdata: a block of raw memory the collector owns, with an
//! optional metatable and `nuvalue` user values. One allocation: this
//! header, the user values, then the bytes, 16-byte aligned.

const Userdata = @This();

const std = @import("std");
const gc = @import("gc.zig");
const Value = @import("Value.zig");
const Table = @import("Table.zig");

header: gc.Header,
nuvalue: u16,
gclist: ?*gc.Header = null,
metatable: ?*Table = null,
len: usize,

const alignment: std.mem.Alignment = .@"16";

inline fn bytesOffset(nuvalue: usize) usize {
    return std.mem.alignForward(usize, @sizeOf(Userdata) + nuvalue * @sizeOf(Value), alignment.toByteUnits());
}

/// A new userdata of `len` bytes, contents undefined, with nil user values.
pub fn create(heap: *gc.Heap, len: usize, nuvalue: u16) error{OutOfMemory}!*Userdata {
    const mem = try heap.allocator().alignedAlloc(u8, alignment, bytesOffset(nuvalue) + len);
    const u: *Userdata = @ptrCast(mem.ptr);
    u.* = .{ .header = undefined, .nuvalue = nuvalue, .len = len };
    @memset(u.userValues(), Value.nil);
    heap.link(&u.header, .userdata);
    return u;
}

pub fn destroy(heap: *gc.Heap, u: *Userdata) void {
    const p: [*]align(alignment.toByteUnits()) u8 = @ptrCast(@alignCast(u));
    heap.allocator().free(p[0..(bytesOffset(u.nuvalue) + u.len)]);
}

/// The bytes the userdata holds, for the collector's pacing.
pub fn byteSize(u: *const Userdata) usize {
    return bytesOffset(u.nuvalue) + u.len;
}

pub inline fn userValues(u: *Userdata) []Value {
    const p: [*]u8 = @ptrCast(u);
    const v: [*]Value = @ptrCast(@alignCast(p + @sizeOf(Userdata)));
    return v[0..u.nuvalue];
}

/// Stores user value `i`, with the write barrier.
pub inline fn setUserValue(u: *Userdata, heap: *gc.Heap, i: usize, v: Value) void {
    u.userValues()[i] = v;
    gc.barrier(heap, &u.header, v);
}

/// The raw memory.
pub inline fn bytes(u: *Userdata) []align(16) u8 {
    const p: [*]align(16) u8 = @ptrCast(@alignCast(u));
    return @alignCast((p + bytesOffset(u.nuvalue))[0..u.len]);
}

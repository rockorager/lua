//! `string.dump`: a prototype as a precompiled chunk in reference Lua
//! 5.5.1's binary format (ldump.c), so the reference loads it and, for a
//! function our compiler built, the bytes are what `luac -o` writes for the
//! same source. `undump.zig` reads the format back. The prototype holds
//! line information in the format's encoding, so it is written as is.

const std = @import("std");
const Writer = std.Io.Writer;
const Proto = @import("Proto.zig");
const String = @import("String.zig");

/// `LUA_SIGNATURE`.
pub const signature = "\x1bLua";
/// `LUAC_VERSION`: major and minor version, a nibble each.
pub const version = 0x55;
/// `LUAC_FORMAT`: the official format.
pub const format = 0;
/// `LUAC_DATA`: catches text-mode conversions of the file.
pub const data = "\x19\x93\r\n\x1a\n";
/// `LUAC_INT` and `LUAC_INST`, written in their types to check sizes and
/// byte order.
pub const check_int: i32 = -0x5678;
pub const check_inst: u32 = 0x12345678;
pub const check_num: f64 = -370.5;

/// The constant tags of the format, lobject.h's variant tags.
pub const Tag = struct {
    pub const nil = 0x00;
    pub const false_ = 0x01;
    pub const true_ = 0x11;
    pub const int = 0x03;
    pub const float = 0x13;
    pub const short_string = 0x04;
    pub const long_string = 0x14;
};

/// lobject.h's `PF_FIXED`: a loader's flag, never meaningful in a dump.
pub const pf_fixed = 4;

pub const Error = Writer.Error || error{OutOfMemory};

/// Writes `f` as a binary chunk, `luaU_dump`. With `strip`, the chunk
/// carries no line information, local or upvalue names, or source.
pub fn dump(gpa: std.mem.Allocator, w: *Writer, f: *const Proto, strip: bool) Error!void {
    var d: Dumper = .{ .gpa = gpa, .w = w, .strip = strip };
    defer d.saved.deinit(gpa);
    try d.block(signature);
    try d.byte(version);
    try d.byte(format);
    try d.block(data);
    try d.numInfo(i32, check_int);
    try d.numInfo(u32, check_inst);
    try d.numInfo(i64, check_int);
    try d.numInfo(f64, check_num);
    try d.byte(@intCast(f.upvalues.len));
    try d.function(f);
}

const Dumper = struct {
    gpa: std.mem.Allocator,
    w: *Writer,
    strip: bool,
    /// Bytes written, for alignment.
    offset: usize = 0,
    /// Strings already written, by contents, with their 1-based index: a
    /// later occurrence is written as a reference.
    saved: std.StringHashMapUnmanaged(u64) = .empty,

    fn block(d: *Dumper, b: []const u8) Writer.Error!void {
        try d.w.writeAll(b);
        d.offset += b.len;
    }

    fn byte(d: *Dumper, b: u8) Writer.Error!void {
        try d.w.writeByte(b);
        d.offset += 1;
    }

    fn numInfo(d: *Dumper, comptime T: type, v: T) Writer.Error!void {
        try d.byte(@sizeOf(T));
        try d.block(std.mem.asBytes(&v));
    }

    /// Zeros up to a multiple of `alignment`, counted from the start.
    fn alignTo(d: *Dumper, alignment: usize) Writer.Error!void {
        const pad = (alignment - d.offset % alignment) % alignment;
        const zeros: [8]u8 = @splat(0);
        try d.block(zeros[0..pad]);
    }

    /// An unsigned integer in MSB-first varint: 7 bits a byte, the high
    /// bit set on every byte but the last.
    fn varint(d: *Dumper, x_in: u64) Writer.Error!void {
        var buf: [10]u8 = undefined;
        var x = x_in;
        var n: usize = 1;
        buf[buf.len - 1] = @intCast(x & 0x7f);
        x >>= 7;
        while (x != 0) : (x >>= 7) {
            n += 1;
            buf[buf.len - n] = @intCast((x & 0x7f) | 0x80);
        }
        try d.block(buf[buf.len - n ..]);
    }

    fn int(d: *Dumper, x: u32) Writer.Error!void {
        try d.varint(x);
    }

    /// A Lua integer, zigzag coded so small negative values stay short.
    fn integer(d: *Dumper, x: i64) Writer.Error!void {
        const u: u64 = @bitCast(x);
        try d.varint(if (x >= 0) 2 *% u else 2 *% ~u + 1);
    }

    /// A string: its length plus one and its bytes with the trailing zero,
    /// or 0 and the index of the same string written before (0 for none).
    fn string(d: *Dumper, s: ?*const String) Error!void {
        const str = s orelse {
            try d.varint(0);
            return d.varint(0);
        };
        const gop = try d.saved.getOrPut(d.gpa, str.bytes());
        if (gop.found_existing) {
            try d.varint(0);
            return d.varint(gop.value_ptr.*);
        }
        gop.value_ptr.* = d.saved.count();
        try d.varint(str.len() + 1);
        try d.block(str.bytesZ()[0 .. str.len() + 1]);
    }

    fn function(d: *Dumper, f: *const Proto) Error!void {
        try d.int(f.linedefined);
        try d.int(f.lastlinedefined);
        try d.byte(f.numparams);
        try d.byte(@as(u8, @bitCast(f.flags)) & ~@as(u8, pf_fixed));
        try d.byte(f.maxstacksize);

        try d.int(@intCast(f.code.len));
        try d.alignTo(@sizeOf(u32));
        for (f.code) |i| try d.block(std.mem.asBytes(&i));

        try d.int(@intCast(f.k.len));
        for (f.k) |v| switch (v.tag) {
            .nil => try d.byte(Tag.nil),
            .bool_false => try d.byte(Tag.false_),
            .bool_true => try d.byte(Tag.true_),
            .float => {
                try d.byte(Tag.float);
                const x = v.asFloat();
                try d.block(std.mem.asBytes(&x));
            },
            .int => {
                try d.byte(Tag.int);
                try d.integer(v.asInt());
            },
            .short_string, .long_string => {
                try d.byte(if (v.tag == .short_string) Tag.short_string else Tag.long_string);
                try d.string(v.asString());
            },
            else => unreachable,
        };

        try d.int(@intCast(f.upvalues.len));
        for (f.upvalues) |u| {
            try d.byte(@intFromBool(u.instack));
            try d.byte(u.idx);
            try d.byte(u.kind);
        }

        try d.int(@intCast(f.p.len));
        for (f.p) |p| try d.function(p);

        try d.string(if (d.strip) null else f.source);
        try d.debug(f);
    }

    fn debug(d: *Dumper, f: *const Proto) Error!void {
        if (d.strip) {
            for (0..4) |_| try d.int(0);
            return;
        }
        try d.int(@intCast(f.lineinfo.len));
        try d.block(@ptrCast(f.lineinfo));
        try d.int(@intCast(f.abslineinfo.len));
        if (f.abslineinfo.len > 0) {
            try d.alignTo(@sizeOf(i32));
            try d.block(@ptrCast(f.abslineinfo));
        }
        try d.int(@intCast(f.locvars.len));
        for (f.locvars) |lv| {
            try d.string(lv.name);
            try d.int(lv.startpc);
            try d.int(lv.endpc);
        }
        try d.int(@intCast(f.upvalues.len));
        for (f.upvalues) |u| try d.string(u.name);
    }
};

const testing = std.testing;
const State = @import("State.zig");
const Parser = @import("Parser.zig");

/// A chunk with a long string, repeated strings, numbers, a nested vararg
/// function with an upvalue, and a generic `for` spanning 130 lines, whose
/// `TFORLOOP` luac encodes as a forced absolute line.
pub const test_source = "local t, s = {}, \"a string longer than forty bytes, so it is long\"\n" ++
    "local function f(a, ...) return a, -7, 2.5, s, \"k\", \"k\" end\n" ++
    "for k in pairs(t) do" ++ &@as([130]u8, @splat('\n')) ++ " s = k end\n" ++
    "return f";

/// `luac -o` and `luac -s -o` of `test_source` saved as "golden.lua".
pub const test_luac =
    "1b4c7561550019930d0a1a0a0488a9ffff04785634120888a9ffffffffffff0800000000002877c00100000001090f00" ++
    "530000001300000054000000830000004f0100008b01000100020000c4010205cb81000080000600cc010001cd810100" ++
    "b601000046810201c68101010214306120737472696e67206c6f6e676572207468616e20666f7274792062797465732c" ++
    "20736f206974206973206c6f6e670004067061697273000101000001020201010809000053000000000100008101fc7f" ++
    "0302000089020000038300008383000046010702460101020213000000000000044004026b0001010100000c40676f6c" ++
    "64656e2e6c75610009000000000000000000000202610000090f28766172617267207461626c65290001090102730000" ++
    "040f01000000010100000080808080010004000009000000850000000a000000030000000b000000030000000c000000" ++
    "8500000007027400040f0007040f026600050f0c28666f722073746174652900080d000a080d000a080d0003090a0105" ++
    "5f454e5600";
const test_luac_stripped =
    "1b4c7561550019930d0a1a0a0488a9ffff04785634120888a9ffffffffffff0800000000002877c00100000001090f00" ++
    "530000001300000054000000830000004f0100008b01000100020000c4010205cb81000080000600cc010001cd810100" ++
    "b601000046810201c68101010214306120737472696e67206c6f6e676572207468616e20666f7274792062797465732c" ++
    "20736f206974206973206c6f6e670004067061697273000101000001020201010809000053000000000100008101fc7f" ++
    "0302000089020000038300008383000046010702460101020213000000000000044004026b0001010100000000000000" ++
    "00000000000000";

fn expectDump(f: *const Proto, strip: bool, comptime hex: []const u8) !void {
    var want: [hex.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&want, hex);
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try dump(testing.allocator, &out.writer, f, strip);
    try testing.expectEqualSlices(u8, &want, out.written());
}

test "a function our compiler built dumps as luac writes it" {
    const state = try State.create(testing.allocator, .{});
    defer state.destroy();
    const p = try Parser.compile(state.main, test_source, "@golden.lua");
    try expectDump(p, false, test_luac);
    try expectDump(p, true, test_luac_stripped);
}

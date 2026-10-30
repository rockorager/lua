//! `string.pack`, `string.unpack`, and `string.packsize`: the binary formats of
//! the reference manual's §6.4.2, with the reference implementation's sizes
//! for this platform, its alignment rules, overflow checks, and errors.
//!
//! The engine works over byte slices and plain numbers. The caller supplies
//! `pack`'s values and receives `unpack`'s through the interfaces each
//! function describes.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Writer = std.Io.Writer;

/// The only error the engine raises; the message is in a `Diagnostic`.
pub const Error = error{PackError};

/// The message of the last `error.PackError`. When `arg` is not zero the
/// error is about that argument, and Lua reports it as
/// "bad argument #arg to 'pack' (message)"; otherwise the message stands
/// alone.
pub const Diagnostic = struct {
    arg: u32 = 0,
    len: u8 = 0,
    buf: [96]u8 = undefined,

    pub fn message(d: *const Diagnostic) []const u8 {
        return d.buf[0..d.len];
    }

    fn fail(d: *Diagnostic, arg: u32, comptime fmt: []const u8, args: anytype) Error {
        const s = std.fmt.bufPrint(&d.buf, fmt, args) catch unreachable;
        d.arg = arg;
        d.len = @intCast(s.len);
        return error.PackError;
    }
};

/// The largest integer size an option may ask for (`MAXINTSIZE`).
const max_int_size = 16;

/// The largest result or string size (`MAX_SIZE`): `math.maxinteger`, since
/// `size_t` is as wide as a Lua integer here.
const max_size: usize = std.math.maxInt(i64);

const native_little = builtin.cpu.arch.endian() == .little;

/// The default for '!': the strictest alignment of the C types the reference
/// lists in `LUAI_MAXALIGN` (long double, void *, long long).
const native_max_align = @max(@alignOf(c_longdouble), @alignOf(usize), @alignOf(c_longlong));

const Kind = enum {
    int,
    uint,
    float,
    number,
    double,
    char,
    string,
    zstr,
    padding,
    paddalign,
    nop,
};

const Option = struct {
    kind: Kind,
    size: usize,
    /// Padding bytes before the option, for alignment.
    ntoalign: usize,
};

/// Reads a format string an option at a time (`Header` and `getdetails`).
const Parser = struct {
    fmt: []const u8,
    i: usize = 0,
    little: bool = native_little,
    max_align: usize = 1,
    diag: *Diagnostic,

    fn init(fmt: []const u8, diag: *Diagnostic) Parser {
        // The reference reads the format as a C string.
        return .{ .fmt = fmt[0 .. std.mem.findScalar(u8, fmt, 0) orelse fmt.len], .diag = diag };
    }

    fn done(p: *const Parser) bool {
        return p.i >= p.fmt.len;
    }

    fn isDigit(p: *const Parser) bool {
        return !p.done() and std.ascii.isDigit(p.fmt[p.i]);
    }

    /// A numeral, or null when there is none (`getnum`). Digits that would
    /// overflow are left for the next option.
    fn number(p: *Parser) ?usize {
        if (!p.isDigit()) return null;
        var a: usize = 0;
        while (true) {
            a = a * 10 + (p.fmt[p.i] - '0');
            p.i += 1;
            if (!p.isDigit() or a > (max_size - 9) / 10) return a;
        }
    }

    /// An integer size in [1, 16] (`getnumlimit`).
    fn sizeLimit(p: *Parser, default: usize) Error!usize {
        const sz = p.number() orelse default;
        if (sz -% 1 >= max_int_size) {
            // The reference passes a size_t where luaL_error reads an int.
            const shown: i32 = @truncate(@as(i64, @bitCast(sz)));
            return p.diag.fail(0, "integral size ({d}) out of limits [1,{d}]", .{ shown, max_int_size });
        }
        return sz;
    }

    /// The next option and its size (`getoption`).
    fn option(p: *Parser, size: *usize) Error!Kind {
        const opt = p.fmt[p.i];
        p.i += 1;
        size.* = 0;
        switch (opt) {
            'b' => size.* = 1,
            'B' => size.* = 1,
            'h' => size.* = @sizeOf(c_short),
            'H' => size.* = @sizeOf(c_short),
            'l' => size.* = @sizeOf(c_long),
            'L' => size.* = @sizeOf(c_long),
            'j' => size.* = 8,
            'J' => size.* = 8,
            'T' => size.* = @sizeOf(usize),
            'f' => size.* = 4,
            'n' => size.* = 8,
            'd' => size.* = 8,
            'i' => size.* = try p.sizeLimit(@sizeOf(c_int)),
            'I' => size.* = try p.sizeLimit(@sizeOf(c_int)),
            's' => size.* = try p.sizeLimit(@sizeOf(usize)),
            'c' => size.* = p.number() orelse return p.diag.fail(0, "missing size for format option 'c'", .{}),
            'z' => {},
            'x' => size.* = 1,
            'X' => {},
            ' ' => {},
            '<' => p.little = true,
            '>' => p.little = false,
            '=' => p.little = native_little,
            '!' => p.max_align = try p.sizeLimit(native_max_align),
            else => return p.diag.fail(0, "invalid format option '{c}'", .{opt}),
        }
        return switch (opt) {
            'b', 'h', 'l', 'j', 'i' => .int,
            'B', 'H', 'L', 'J', 'T', 'I' => .uint,
            'f' => .float,
            'n' => .number,
            'd' => .double,
            's' => .string,
            'c' => .char,
            'z' => .zstr,
            'x' => .padding,
            'X' => .paddalign,
            else => .nop,
        };
    }

    /// The next option with the padding that aligns it at offset `total`.
    fn next(p: *Parser, total: usize) Error!Option {
        var size: usize = undefined;
        const kind = try p.option(&size);
        var alignment = size;
        if (kind == .paddalign) { // 'X' takes its alignment from the next option
            if (p.done() or try p.option(&alignment) == .char or alignment == 0)
                return p.diag.fail(1, "invalid next option for option 'X'", .{});
        }
        if (alignment <= 1 or kind == .char) return .{ .kind = kind, .size = size, .ntoalign = 0 };
        alignment = @min(alignment, p.max_align);
        if (!std.math.isPowerOfTwo(alignment))
            return p.diag.fail(1, "format asks for alignment not power of 2", .{});
        const ntoalign = (alignment - (total & (alignment - 1))) & (alignment - 1);
        return .{ .kind = kind, .size = size, .ntoalign = ntoalign };
    }
};

/// Write `n` in `size` bytes, sign-extending past 8 bytes when `negative`.
fn packInt(w: *Writer, n: u64, little: bool, size: usize, negative: bool) Writer.Error!void {
    var buf: [max_int_size]u8 = undefined;
    for (0..size) |i| {
        const byte: u8 = if (i < 8) @truncate(n >> @intCast(8 * i)) else if (negative) 0xff else 0;
        buf[if (little) i else size - 1 - i] = byte;
    }
    try w.writeAll(buf[0..size]);
}

/// Write a float's bytes in the requested byte order.
fn packFloat(w: *Writer, comptime T: type, v: T, little: bool) Writer.Error!void {
    var bytes: [@sizeOf(T)]u8 = @bitCast(v);
    if (little != native_little) std.mem.reverse(u8, &bytes);
    try w.writeAll(&bytes);
}

/// `string.pack`: write `fmt`'s values to `w`. Argument numbers are Lua's: the
/// format is argument 1 and the values start at 2. `args` supplies them,
/// raising the caller's own errors for wrong types:
///
///     integer(arg: u32) !i64        // luaL_checkinteger
///     number(arg: u32) !f64         // luaL_checknumber
///     string(arg: u32) ![]const u8  // luaL_checklstring
///
/// The engine's own errors are `error.PackError`, described in `diag`.
pub fn pack(w: *Writer, fmt: []const u8, args: anytype, diag: *Diagnostic) !void {
    var p: Parser = .init(fmt, diag);
    var arg: u32 = 1;
    var total: usize = 0;
    while (!p.done()) {
        const opt = try p.next(total);
        if (opt.size + opt.ntoalign > max_size -% total) return diag.fail(arg, "result too long", .{});
        total += opt.ntoalign + opt.size;
        try w.splatByteAll(0, opt.ntoalign);
        arg += 1;
        switch (opt.kind) {
            .int => {
                const n = try args.integer(arg);
                if (opt.size < 8) {
                    const lim = @as(i64, 1) << @intCast(opt.size * 8 - 1);
                    if (n < -lim or n >= lim) return diag.fail(arg, "integer overflow", .{});
                }
                try packInt(w, @bitCast(n), p.little, opt.size, n < 0);
            },
            .uint => {
                const n = try args.integer(arg);
                if (opt.size < 8 and @as(u64, @bitCast(n)) >= @as(u64, 1) << @intCast(opt.size * 8))
                    return diag.fail(arg, "unsigned overflow", .{});
                try packInt(w, @bitCast(n), p.little, opt.size, false);
            },
            .float => try packFloat(w, f32, @floatCast(try args.number(arg)), p.little),
            .number, .double => try packFloat(w, f64, try args.number(arg), p.little),
            .char => {
                const s = try args.string(arg);
                if (s.len > opt.size) return diag.fail(arg, "string longer than given size", .{});
                try w.writeAll(s);
                try w.splatByteAll(0, opt.size - s.len);
            },
            .string => {
                const s = try args.string(arg);
                if (opt.size < 8 and s.len >= @as(u64, 1) << @intCast(opt.size * 8))
                    return diag.fail(arg, "string length does not fit in given size", .{});
                try packInt(w, s.len, p.little, opt.size, false);
                try w.writeAll(s);
                total +%= s.len;
            },
            .zstr => {
                const s = try args.string(arg);
                if (std.mem.findScalar(u8, s, 0) != null) return diag.fail(arg, "string contains zeros", .{});
                try w.writeAll(s);
                try w.writeByte(0);
                total +%= s.len + 1;
            },
            .padding => {
                try w.writeByte(0);
                arg -= 1;
            },
            .paddalign, .nop => arg -= 1,
        }
    }
}

/// `string.packsize`: the length of what `fmt` packs, which may not hold
/// variable-length options.
pub fn packsize(fmt: []const u8, diag: *Diagnostic) Error!i64 {
    var p: Parser = .init(fmt, diag);
    var total: usize = 0;
    while (!p.done()) {
        const opt = try p.next(total);
        if (opt.kind == .string or opt.kind == .zstr) return diag.fail(1, "variable-length format", .{});
        const size = opt.size + opt.ntoalign;
        if (total > max_size - size) return diag.fail(1, "format result too large", .{});
        total += size;
    }
    return @intCast(total);
}

/// Read an integer of `size` bytes, sign-extending it when `signed`; past 8
/// bytes, the extra bytes must only extend the sign (`unpackint`).
fn unpackInt(bytes: []const u8, little: bool, size: usize, signed: bool, diag: *Diagnostic) Error!i64 {
    const limit = @min(size, 8);
    var res: u64 = 0;
    var i = limit;
    while (i > 0) {
        i -= 1;
        res = (res << 8) | bytes[if (little) i else size - 1 - i];
    }
    if (size < 8) {
        if (signed) {
            const mask = @as(u64, 1) << @intCast(size * 8 - 1);
            res = (res ^ mask) -% mask;
        }
    } else if (size > 8) {
        const mask: u8 = if (!signed or @as(i64, @bitCast(res)) >= 0) 0 else 0xff;
        for (limit..size) |j| {
            if (bytes[if (little) j else size - 1 - j] != mask)
                return diag.fail(0, "{d}-byte integer does not fit into Lua Integer", .{size});
        }
    }
    return @bitCast(res);
}

fn unpackFloat(comptime T: type, bytes: []const u8, little: bool) T {
    var b: [@sizeOf(T)]u8 = bytes[0..@sizeOf(T)].*;
    if (little != native_little) std.mem.reverse(u8, &b);
    return @bitCast(b);
}

/// `string.unpack`: read `fmt`'s values from `data` starting at Lua position
/// `init`, hand each to `sink`, and return the position after the last byte
/// read. `sink` receives the values in order and may raise its own errors,
/// such as running out of stack:
///
///     integer(v: i64) !void
///     number(v: f64) !void
///     string(s: []const u8) !void  // a slice of `data`
///
/// The engine's own errors are `error.PackError`, described in `diag`.
pub fn unpack(fmt: []const u8, data: []const u8, init: i64, sink: anytype, diag: *Diagnostic) !i64 {
    var p: Parser = .init(fmt, diag);
    var pos = startIndex(init, data.len);
    if (pos > data.len) return diag.fail(3, "initial position out of string", .{});
    while (!p.done()) {
        const opt = try p.next(pos);
        if (opt.ntoalign + opt.size > data.len - pos) return diag.fail(2, "data string too short", .{});
        pos += opt.ntoalign;
        const bytes = data[pos..];
        switch (opt.kind) {
            .int, .uint => try sink.integer(try unpackInt(bytes, p.little, opt.size, opt.kind == .int, diag)),
            .float => try sink.number(unpackFloat(f32, bytes, p.little)),
            .number, .double => try sink.number(unpackFloat(f64, bytes, p.little)),
            .char => try sink.string(bytes[0..opt.size]),
            .string => {
                const len: u64 = @bitCast(try unpackInt(bytes, p.little, opt.size, false, diag));
                if (len > data.len - pos - opt.size) return diag.fail(2, "data string too short", .{});
                try sink.string(bytes[opt.size..][0..len]);
                pos += len;
            },
            .zstr => {
                const len = std.mem.findScalar(u8, bytes, 0) orelse bytes.len;
                if (pos + len >= data.len) return diag.fail(2, "unfinished string for format 'z'", .{});
                try sink.string(bytes[0..len]);
                pos += len + 1;
            },
            .padding, .paddalign, .nop => {},
        }
        pos += opt.size;
    }
    return @as(i64, @intCast(pos)) + 1;
}

/// The 0-based offset for an `init` argument (`posrelatI` minus one).
fn startIndex(init: i64, len: usize) usize {
    if (init > 0) return @intCast(init - 1);
    if (init == 0) return 0;
    const back = @as(u64, @intCast(-(init + 1))) + 1;
    return if (back > len) 0 else len - back;
}

// Expected results below come from reference Lua 5.5.1 (`lua` in the dev
// shell), mostly from the cases in test/lua-5.5.1-tests/tpack.lua.

const TestValue = union(enum) {
    integer: i64,
    float: f64,
    string: []const u8,
};

const TestArgs = struct {
    list: []const TestValue,

    pub fn integer(a: TestArgs, arg: u32) !i64 {
        return switch (a.list[arg - 2]) {
            .integer => |v| v,
            else => error.TestArgument,
        };
    }

    pub fn number(a: TestArgs, arg: u32) !f64 {
        return switch (a.list[arg - 2]) {
            .integer => |v| @floatFromInt(v),
            .float => |v| v,
            else => error.TestArgument,
        };
    }

    pub fn string(a: TestArgs, arg: u32) ![]const u8 {
        return switch (a.list[arg - 2]) {
            .string => |s| s,
            else => error.TestArgument,
        };
    }
};

/// Writes unpacked values separated by spaces: integers in decimal, floats
/// as 'f' and their bits in hexadecimal, strings in double quotes.
const TestSink = struct {
    w: *Writer,

    pub fn integer(s: TestSink, v: i64) !void {
        try s.w.print("{d} ", .{v});
    }

    pub fn number(s: TestSink, v: f64) !void {
        try s.w.print("f{x:0>16} ", .{@as(u64, @bitCast(v))});
    }

    pub fn string(s: TestSink, v: []const u8) !void {
        try s.w.print("\"{s}\" ", .{v});
    }
};

fn writeError(w: *Writer, diag: *const Diagnostic, function: []const u8) !void {
    if (diag.arg != 0)
        try w.print("error: bad argument #{d} to '{s}' ({s})", .{ diag.arg, function, diag.message() })
    else
        try w.print("error: {s}", .{diag.message()});
}

test "pack matches the reference" {
    const cases = [_]struct { fmt: []const u8, args: []const TestValue, want: []const u8 }{
        .{ .fmt = "B", .args = &.{.{ .integer = 255 }}, .want = "\xff" },
        .{ .fmt = "b", .args = &.{.{ .integer = -128 }}, .want = "\x80" },
        .{ .fmt = "h", .args = &.{.{ .integer = 32767 }}, .want = "\xff\x7f" },
        .{ .fmt = "<H", .args = &.{.{ .integer = 65535 }}, .want = "\xff\xff" },
        .{
            .fmt = ">l",
            .args = &.{
                .{ .integer = -2147483648 },
            },
            .want = "\xff\xff\xff\xff\x80\x00\x00\x00",
        },
        .{
            .fmt = "i16",
            .args = &.{
                .{ .integer = -1 },
            },
            .want = "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff",
        },
        .{
            .fmt = "<I16",
            .args = &.{
                .{ .integer = 170 },
            },
            .want = "\xaa\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
        },
        .{
            .fmt = ">I16",
            .args = &.{
                .{ .integer = 170 },
            },
            .want = "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\xaa",
        },
        .{
            .fmt = "<j",
            .args = &.{
                .{ .integer = 578437695752307201 },
            },
            .want = "\x01\x02\x03\x04\x05\x06\x07\x08",
        },
        .{ .fmt = "<i3", .args = &.{.{ .integer = 197121 }}, .want = "\x01\x02\x03" },
        .{ .fmt = ">i3", .args = &.{.{ .integer = 197121 }}, .want = "\x03\x02\x01" },
        .{
            .fmt = ">i2 <i2",
            .args = &.{
                .{ .integer = 10 },
                .{ .integer = 20 },
            },
            .want = "\x00\x0a\x14\x00",
        },
        .{ .fmt = "=i4", .args = &.{.{ .integer = 2001 }}, .want = "\xd1\x07\x00\x00" },
        .{ .fmt = "<f", .args = &.{.{ .integer = 24 }}, .want = "\x00\x00\xc0A" },
        .{
            .fmt = ">d",
            .args = &.{
                .{ .float = -1.1000000000000001 },
            },
            .want = "\xbf\xf1\x99\x99\x99\x99\x99\x9a",
        },
        .{
            .fmt = "<n",
            .args = &.{
                .{ .float = std.math.inf(f64) },
            },
            .want = "\x00\x00\x00\x00\x00\x00\xf0\x7f",
        },
        .{ .fmt = "zB", .args = &.{ .{ .string = "abc" }, .{ .integer = 247 } }, .want = "abc\x00\xf7" },
        .{ .fmt = "s1", .args = &.{.{ .string = "alo" }}, .want = "\x03alo" },
        .{ .fmt = ">s2", .args = &.{.{ .string = "hi" }}, .want = "\x00\x02hi" },
        .{ .fmt = "c0", .args = &.{.{ .string = "" }}, .want = "" },
        .{ .fmt = "c8", .args = &.{.{ .string = "123456" }}, .want = "123456\x00\x00" },
        .{ .fmt = "<! c3", .args = &.{.{ .string = "abc" }}, .want = "abc" },
        .{ .fmt = ">!4 c6", .args = &.{.{ .string = "abcdef" }}, .want = "abcdef" },
        .{ .fmt = " < i1 i2 ", .args = &.{ .{ .integer = 2 }, .{ .integer = 3 } }, .want = "\x02\x03\x00" },
        .{
            .fmt = ">!8 b Xh i4 i8 c1 Xi8",
            .args = &.{
                .{ .integer = -12 },
                .{ .integer = 100 },
                .{ .integer = 200 },
                .{ .string = "\xec" },
            },
            .want = "\xf4\x00\x00\x00\x00\x00\x00d\x00\x00\x00\x00\x00\x00\x00\xc8\xec\x00\x00\x00\x00\x00\x00\x00",
        },
        .{
            .fmt = ">!4 c3 c4 c2 z i4 c5 c2 Xi4",
            .args = &.{
                .{ .string = "abc" },
                .{ .string = "abcd" },
                .{ .string = "xz" },
                .{ .string = "hello" },
                .{ .integer = 5 },
                .{ .string = "world" },
                .{ .string = "xy" },
            },
            .want = "abcabcdxzhello\x00\x00\x00\x00\x00\x05worldxy\x00",
        },
        .{
            .fmt = " b b Xd b Xb x",
            .args = &.{
                .{ .integer = 1 },
                .{ .integer = 2 },
                .{ .integer = 3 },
            },
            .want = "\x01\x02\x03\x00",
        },
        .{ .fmt = "!xXi16", .args = &.{}, .want = "\x00" ** 16 },
        .{ .fmt = "i\x00garbage", .args = &.{.{ .integer = 1 }}, .want = "\x01\x00\x00\x00" },
        .{
            .fmt = "i0",
            .args = &.{
                .{ .integer = 0 },
            },
            .want = "error: integral size (0) out of limits [1,16]",
        },
        .{
            .fmt = "i17",
            .args = &.{
                .{ .integer = 0 },
            },
            .want = "error: integral size (17) out of limits [1,16]",
        },
        .{
            .fmt = "!17",
            .args = &.{
                .{ .integer = 0 },
            },
            .want = "error: integral size (17) out of limits [1,16]",
        },
        .{ .fmt = "Xi17", .args = &.{}, .want = "error: integral size (17) out of limits [1,16]" },
        .{ .fmt = "i3r", .args = &.{.{ .integer = 0 }}, .want = "error: invalid format option 'r'" },
        .{
            .fmt = "!4i3",
            .args = &.{
                .{ .integer = 0 },
            },
            .want = "error: bad argument #1 to 'pack' (format asks for alignment not power of 2)",
        },
        .{
            .fmt = "c",
            .args = &.{
                .{ .string = "" },
            },
            .want = "error: missing size for format option 'c'",
        },
        .{
            .fmt = "X",
            .args = &.{},
            .want = "error: bad argument #1 to 'pack' (invalid next option for option 'X')",
        },
        .{
            .fmt = "Xc1",
            .args = &.{},
            .want = "error: bad argument #1 to 'pack' (invalid next option for option 'X')",
        },
        .{
            .fmt = "c3",
            .args = &.{
                .{ .string = "1234" },
            },
            .want = "error: bad argument #2 to 'pack' (string longer than given size)",
        },
        .{
            .fmt = "s1",
            .args = &.{
                .{ .string = "x" ** 256 },
            },
            .want = "error: bad argument #2 to 'pack' (string length does not fit in given size)",
        },
        .{
            .fmt = "z",
            .args = &.{
                .{ .string = "alo\x00" },
            },
            .want = "error: bad argument #2 to 'pack' (string contains zeros)",
        },
        .{
            .fmt = "<I1",
            .args = &.{
                .{ .integer = -1 },
            },
            .want = "error: bad argument #2 to 'pack' (unsigned overflow)",
        },
        .{
            .fmt = "<I2",
            .args = &.{
                .{ .integer = 65536 },
            },
            .want = "error: bad argument #2 to 'pack' (unsigned overflow)",
        },
        .{
            .fmt = ">i1",
            .args = &.{
                .{ .integer = 128 },
            },
            .want = "error: bad argument #2 to 'pack' (integer overflow)",
        },
        .{
            .fmt = "<i2",
            .args = &.{
                .{ .integer = -32769 },
            },
            .want = "error: bad argument #2 to 'pack' (integer overflow)",
        },
        .{
            .fmt = "i99999999999",
            .args = &.{
                .{ .integer = 1 },
            },
            .want = "error: integral size (1215752191) out of limits [1,16]",
        },
        .{
            .fmt = "s100",
            .args = &.{
                .{ .string = "alo" },
            },
            .want = "error: integral size (100) out of limits [1,16]",
        },
        .{
            .fmt = "xxxxxxxxxx c9223372036854775798",
            .args = &.{},
            .want = "error: bad argument #1 to 'pack' (result too long)",
        },
    };
    for (cases) |c| {
        var out: Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        var diag: Diagnostic = .{};
        pack(&out.writer, c.fmt, TestArgs{ .list = c.args }, &diag) catch |err| switch (err) {
            error.PackError => {
                out.clearRetainingCapacity();
                try writeError(&out.writer, &diag, "pack");
            },
            else => |e| return e,
        };
        testing.expectEqualStrings(c.want, out.written()) catch |err| {
            std.debug.print("pack \"{s}\"\n", .{c.fmt});
            return err;
        };
    }
}

test "packsize matches the reference" {
    const cases = [_]struct { fmt: []const u8, want: []const u8 }{
        .{ .fmt = "h", .want = "2" },
        .{ .fmt = "i", .want = "4" },
        .{ .fmt = "l", .want = "8" },
        .{ .fmt = "T", .want = "8" },
        .{ .fmt = "j", .want = "8" },
        .{ .fmt = "f", .want = "4" },
        .{ .fmt = "n", .want = "8" },
        .{ .fmt = "<b h b f d f n i", .want = "32" },
        .{ .fmt = ">!8 b Xh i4 i8 c1 Xi8", .want = "24" },
        .{ .fmt = " b b Xd b Xb x", .want = "4" },
        .{ .fmt = "!8 xXi8", .want = "8" },
        .{ .fmt = "!8 xXi2", .want = "2" },
        .{ .fmt = "!2 xXi8", .want = "2" },
        .{ .fmt = "!16 xXi16", .want = "16" },
        .{ .fmt = "!xXi16", .want = "16" },
        .{ .fmt = "c9223372036854775798", .want = "9223372036854775798" },
        .{
            .fmt = "c9223372036854775798c10",
            .want = "error: bad argument #1 to 'packsize' (format result too large)",
        },
        .{
            .fmt = "c10000000000000000000000000000000000000000",
            .want = "error: invalid format option '0'",
        },
        .{ .fmt = "s", .want = "error: bad argument #1 to 'packsize' (variable-length format)" },
        .{ .fmt = "z", .want = "error: bad argument #1 to 'packsize' (variable-length format)" },
        .{ .fmt = "i17", .want = "error: integral size (17) out of limits [1,16]" },
    };
    for (cases) |c| {
        var buf: [128]u8 = undefined;
        var w: Writer = .fixed(&buf);
        var diag: Diagnostic = .{};
        if (packsize(c.fmt, &diag)) |n| try w.print("{d}", .{n}) else |_| try writeError(&w, &diag, "packsize");
        try testing.expectEqualStrings(c.want, w.buffered());
    }
}

test "unpack matches the reference" {
    const cases = [_]struct { fmt: []const u8, data: []const u8, init: i64, want: []const u8 }{
        .{
            .fmt = "<i16",
            .data = "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff",
            .init = 1,
            .want = "-1 @17",
        },
        .{ .fmt = ">I3", .data = "\xf0\xff\xff", .init = 1, .want = "15794175 @4" },
        .{ .fmt = "<i3", .data = "\xf0\xff\xff", .init = 1, .want = "-16 @4" },
        .{ .fmt = "<i9", .data = "\xfb\xff\xff\xff\xff\xff\xff\xff\xff", .init = 1, .want = "-5 @10" },
        .{ .fmt = "<I9", .data = "\xfb\xff\xff\xff\xff\xff\xff\xff\x00", .init = 1, .want = "-5 @10" },
        .{
            .fmt = "<I9",
            .data = "\x00\x00\x00\x00\x00\x00\x00\x00\x01",
            .init = 1,
            .want = "error: 9-byte integer does not fit into Lua Integer",
        },
        .{
            .fmt = ">i9",
            .data = "\x01\x00\x00\x00\x00\x00\x00\x00\x00",
            .init = 1,
            .want = "error: 9-byte integer does not fit into Lua Integer",
        },
        .{
            .fmt = "i16",
            .data = "\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03\x03",
            .init = 1,
            .want = "error: 16-byte integer does not fit into Lua Integer",
        },
        .{ .fmt = "<i2 >i2", .data = "\x0a\x00\x00\x14", .init = 1, .want = "10 20 @5" },
        .{ .fmt = "zB", .data = "abc\x00\xf9", .init = 1, .want = "\x22abc\x22 249 @6" },
        .{
            .fmt = "s",
            .data = "\x03\x00\x00\x00\x00\x00\x00\x00alo",
            .init = 1,
            .want = "\x22alo\x22 @12",
        },
        .{
            .fmt = "s",
            .data = "\x03\x00\x00\x00\x00\x00\x00\x00al",
            .init = 1,
            .want = "error: bad argument #2 to 'unpack' (data string too short)",
        },
        .{
            .fmt = "c5",
            .data = "abcd",
            .init = 1,
            .want = "error: bad argument #2 to 'unpack' (data string too short)",
        },
        .{
            .fmt = "zc10000000",
            .data = "alo",
            .init = 1,
            .want = "error: bad argument #2 to 'unpack' (unfinished string for format 'z')",
        },
        .{
            .fmt = "!4 z c3",
            .data = "abcdefghi\x00xyz",
            .init = 1,
            .want = "\x22abcdefghi\x22 \x22xyz\x22 @14",
        },
        .{ .fmt = "c0", .data = "", .init = 1, .want = "\x22\x22 @1" },
        .{
            .fmt = ">!8 c1 Xh i4 i8 b Xi8 XI XH",
            .data = "\xf4\x00\x00\x00\x00\x00\x00d\x00\x00\x00\x00\x00\x00\x00\xc8\xec\x00\x00\x00\x00\x00\x00\x00",
            .init = 1,
            .want = "\x22\xf4\x22 100 200 -20 @25",
        },
        .{ .fmt = "!8 xXi8", .data = "0123456701234567", .init = 1, .want = "@9" },
        .{ .fmt = "!2 xXi8", .data = "0123456701234567", .init = 1, .want = "@3" },
        .{
            .fmt = "i4",
            .data = "\x01\x00\x00\x00\x02\x00\x00\x00\x03\x00\x00\x00\x04\x00\x00\x00",
            .init = 5,
            .want = "2 @9",
        },
        .{
            .fmt = "!4 i4",
            .data = "\x01\x00\x00\x00\x02\x00\x00\x00\x03\x00\x00\x00\x04\x00\x00\x00",
            .init = 2,
            .want = "2 @9",
        },
        .{
            .fmt = "!4 i4",
            .data = "\x01\x00\x00\x00\x02\x00\x00\x00\x03\x00\x00\x00\x04\x00\x00\x00",
            .init = -4,
            .want = "4 @17",
        },
        .{
            .fmt = "!4 i4",
            .data = "\x01\x00\x00\x00\x02\x00\x00\x00\x03\x00\x00\x00\x04\x00\x00\x00",
            .init = -7,
            .want = "4 @17",
        },
        .{
            .fmt = "!4 i4",
            .data = "\x01\x00\x00\x00\x02\x00\x00\x00\x03\x00\x00\x00\x04\x00\x00\x00",
            .init = -16,
            .want = "1 @5",
        },
        .{
            .fmt = "c0",
            .data = "\x01\x00\x00\x00\x02\x00\x00\x00\x03\x00\x00\x00\x04\x00\x00\x00",
            .init = 17,
            .want = "\x22\x22 @17",
        },
        .{
            .fmt = "c0",
            .data = "\x01\x00\x00\x00\x02\x00\x00\x00\x03\x00\x00\x00\x04\x00\x00\x00",
            .init = 18,
            .want = "error: bad argument #3 to 'unpack' (initial position out of string)",
        },
        .{
            .fmt = "XXi",
            .data = "",
            .init = 1,
            .want = "error: bad argument #1 to 'unpack' (invalid next option for option 'X')",
        },
        .{
            .fmt = "X i",
            .data = "",
            .init = 1,
            .want = "error: bad argument #1 to 'unpack' (invalid next option for option 'X')",
        },
        .{
            .fmt = ">f <d",
            .data = "?\x00\x00\x00\x00\x00\x00\x00\x00A\x9f\xc0",
            .init = 1,
            .want = "f3fe0000000000000 fc09f410000000000 @13",
        },
        .{ .fmt = "<f", .data = "\xcd\xcc\xcc=", .init = 1, .want = "f3fb99999a0000000 @5" },
        .{
            .fmt = "z",
            .data = "abc",
            .init = 1,
            .want = "error: bad argument #2 to 'unpack' (unfinished string for format 'z')",
        },
    };
    for (cases) |c| {
        var out: Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        var diag: Diagnostic = .{};
        if (unpack(c.fmt, c.data, c.init, TestSink{ .w = &out.writer }, &diag)) |next| {
            try out.writer.print("@{d}", .{next});
        } else |err| switch (err) {
            error.PackError => {
                out.clearRetainingCapacity();
                try writeError(&out.writer, &diag, "unpack");
            },
            else => |e| return e,
        }
        testing.expectEqualStrings(c.want, out.written()) catch |err| {
            std.debug.print("unpack \"{s}\"\n", .{c.fmt});
            return err;
        };
    }
}

test "pack and unpack round-trip every integer size" {
    // tpack.lua: -1 in i1-i16 is all 0xff bytes, and 0xAA in I1-I16 is 0xAA
    // and zeros, in either byte order.
    var buf: [32]u8 = undefined;
    var fmt_buf: [8]u8 = undefined;
    for (1..max_int_size + 1) |i| {
        var diag: Diagnostic = .{};
        var w: Writer = .fixed(&buf);
        try pack(&w, try std.fmt.bufPrint(&fmt_buf, "i{d}", .{i}), TestArgs{ .list = &.{.{ .integer = -1 }} }, &diag);
        try testing.expectEqual(i, w.end);
        try testing.expect(std.mem.allEqual(u8, w.buffered(), 0xff));
        w = .fixed(&buf);
        const unsigned = try std.fmt.bufPrint(&fmt_buf, ">I{d}", .{i});
        try pack(&w, unsigned, TestArgs{ .list = &.{.{ .integer = 0xAA }} }, &diag);
        try testing.expectEqual(0xAA, w.buffered()[i - 1]);
        try testing.expect(std.mem.allEqual(u8, w.buffered()[0 .. i - 1], 0));
        var out: [64]u8 = undefined;
        var ow: Writer = .fixed(&out);
        const next = try unpack(unsigned, w.buffered(), 1, TestSink{ .w = &ow }, &diag);
        try testing.expectEqualStrings("170 ", ow.buffered());
        try testing.expectEqual(@as(i64, @intCast(i)) + 1, next);
    }
}

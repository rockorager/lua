//! The utf8 library, the reference manual's §6.5, after lutf8lib.c: strict
//! and lax decoding, sequences of up to six bytes for values below 2^31, and
//! 5.5's `utf8.offset`, which also returns where the character ends.

const std = @import("std");
const Value = @import("../Value.zig");
const Thread = @import("../Thread.zig");
const State = @import("../State.zig");
const auxlib = @import("auxlib.zig");

const Error = Value.Error;
const Args = auxlib.Args;
const raise = auxlib.raise;

const max_unicode = 0x10FFFF;
const max_utf = 0x7FFFFFFF;
const msg_invalid = "invalid UTF-8 code";

/// The pattern for one UTF-8 character (`UTF8PATT`).
pub const charpattern = "[\x00-\x7F\xC2-\xFD][\x80-\xBF]*";

/// Creates the `utf8` table and sets the global.
pub fn open(state: *State) Error!void {
    const lib = try auxlib.newLib(state, .{
        .{ "offset", offset },
        .{ "codepoint", codepoint },
        .{ "char", char },
        .{ "len", len },
        .{ "codes", codes },
    });
    try auxlib.setField(state, lib, "charpattern", .string(try state.newString(charpattern)));
    try auxlib.setField(state, state.globals, "utf8", .table(lib));
}

inline fn isCont(c: u8) bool {
    return c & 0xC0 == 0x80;
}

/// `u_posrelat`: a position, negative from the end, with positions before
/// the start going to 0.
fn posrelat(pos: i64, n: usize) i64 {
    if (pos >= 0) return pos;
    if (0 -% @as(u64, @bitCast(pos)) > n) return 0;
    return @as(i64, @intCast(n)) + pos + 1;
}

/// Decodes the sequence at `s[0]`, where `s` ends in the string's zero
/// terminator. Returns the code point and the sequence length, or null for
/// an invalid sequence; `strict` also rejects surrogates and values past
/// U+10FFFF (`utf8_decode`).
fn decode(s: [*:0]const u8, strict: bool) ?struct { code: u32, len: usize } {
    const limits = [_]u32{ ~@as(u32, 0), 0x80, 0x800, 0x10000, 0x200000, 0x4000000 };
    var c: u32 = s[0];
    var res: u32 = 0;
    var count: usize = 0;
    if (c < 0x80) {
        res = c;
    } else if (c >= 0xfe) {
        return null;
    } else {
        while (c & 0x40 != 0) : (c <<= 1) {
            count += 1;
            const cc = s[count];
            if (!isCont(cc)) return null;
            res = (res << 6) | (cc & 0x3F);
        }
        res |= (c & 0x7F) << @intCast(count * 5);
        if (res > max_utf or res < limits[count]) return null;
    }
    if (strict and (res > max_unicode or (0xD800 <= res and res <= 0xDFFF))) return null;
    return .{ .code = res, .len = count + 1 };
}

/// `utf8.len(s [, i [, j [, lax]]])`: the number of characters that start
/// in [i, j], or fail and the position of the first invalid byte.
fn len(th: *Thread, base: u32) Error!u32 {
    const a: Args = .init(th, base, "len");
    const str = try a.checkString(1);
    const n: i64 = @intCast(str.len);
    var posi = posrelat(try a.optInteger(2, 1), str.len);
    var posj = posrelat(try a.optInteger(3, -1), str.len);
    const lax = !a.get(4).isFalsy();
    if (!(1 <= posi and posi - 1 <= n)) return a.argError(2, "initial position out of bounds", .{});
    posi -= 1;
    posj -= 1;
    if (!(posj < n)) return a.argError(3, "final position out of bounds", .{});
    const s = str.bytesZ().ptr;
    var count: i64 = 0;
    while (posi <= posj) {
        const d = decode(s + @as(usize, @intCast(posi)), !lax) orelse {
            th.push(.nil);
            th.push(.int(posi + 1));
            return 2;
        };
        posi += @intCast(d.len);
        count += 1;
    }
    th.push(.int(count));
    return 1;
}

/// `utf8.codepoint(s [, i [, j [, lax]]])`: the code points of the
/// characters that start in [i, j].
fn codepoint(th: *Thread, base: u32) Error!u32 {
    const a: Args = .init(th, base, "codepoint");
    const str = try a.checkString(1);
    const n: i64 = @intCast(str.len);
    const posi = posrelat(try a.optInteger(2, 1), str.len);
    const pose = posrelat(try a.optInteger(3, posi), str.len);
    const lax = !a.get(4).isFalsy();
    if (posi < 1) return a.argError(2, "out of bounds", .{});
    if (pose > n) return a.argError(3, "out of bounds", .{});
    if (posi > pose) return 0;
    if (pose - posi >= std.math.maxInt(i32)) return raise(th, "string slice too long", .{});
    try auxlib.checkStack(th, @intCast(pose - posi + 1), "string slice too long");
    const s = str.bytesZ().ptr;
    var i: usize = @intCast(posi - 1);
    const end: usize = @intCast(pose);
    var count: u32 = 0;
    while (i < end) {
        const d = decode(s + i, !lax) orelse return raise(th, msg_invalid, .{});
        th.push(.int(d.code));
        i += d.len;
        count += 1;
    }
    return count;
}

/// Writes `code` as a UTF-8 sequence of up to six bytes (`luaO_utf8esc`);
/// returns the bytes used, at the end of `buf`.
fn encode(buf: *[8]u8, code_in: u32) []const u8 {
    var code = code_in;
    var n: usize = 1;
    if (code < 0x80) {
        buf[7] = @intCast(code);
    } else {
        // The largest value that fits in the first byte.
        var mfb: u32 = 0x3f;
        while (true) {
            buf[8 - n] = @intCast(0x80 | (code & 0x3f));
            n += 1;
            code >>= 6;
            mfb >>= 1;
            if (code <= mfb) break;
        }
        buf[8 - n] = @truncate((~mfb << 1) | code);
    }
    return buf[8 - n ..];
}

/// `utf8.char(...)`: the characters with these code points.
fn char(th: *Thread, base: u32) Error!u32 {
    const a: Args = .init(th, base, "char");
    var b: auxlib.Buffer = undefined;
    b.init(th.state);
    defer b.deinit();
    var i: u32 = 1;
    while (i <= a.count()) : (i += 1) {
        const code: u64 = @bitCast(try a.checkInteger(i));
        if (code > max_utf) return a.argError(i, "value out of range", .{});
        var buf: [8]u8 = undefined;
        b.writer.writeAll(encode(&buf, @intCast(code))) catch return error.OutOfMemory;
    }
    th.push(.string(try b.toString(th.state)));
    return 1;
}

/// `utf8.offset(s, n [, i])`: where the n-th character counting from
/// position i starts and ends; n = 0 finds the start of the character at i.
fn offset(th: *Thread, base: u32) Error!u32 {
    const a: Args = .init(th, base, "offset");
    const str = try a.checkString(1);
    const l = str.len;
    var n = try a.checkInteger(2);
    const def: i64 = if (n >= 0) 1 else @as(i64, @intCast(l)) + 1;
    const li: i64 = @intCast(l);
    var posi = posrelat(try a.optInteger(3, def), l);
    if (!(1 <= posi and posi - 1 <= li)) return a.argError(3, "position out of bounds", .{});
    posi -= 1;
    const s = str.bytesZ();
    const at = struct {
        fn f(z: [:0]const u8, p: i64) u8 {
            return z.ptr[@intCast(p)];
        }
    }.f;
    if (n == 0) {
        while (posi > 0 and isCont(at(s, posi))) posi -= 1;
    } else {
        if (isCont(at(s, posi))) return raise(th, "initial position is a continuation byte", .{});
        if (n < 0) {
            while (n < 0 and posi > 0) {
                posi -= 1;
                while (posi > 0 and isCont(at(s, posi))) posi -= 1;
                n += 1;
            }
        } else {
            n -= 1;
            while (n > 0 and posi < li) {
                posi += 1;
                while (isCont(at(s, posi))) posi += 1;
                n -= 1;
            }
        }
    }
    if (n != 0) {
        th.push(.nil);
        return 1;
    }
    th.push(.int(posi + 1));
    if (at(s, posi) & 0x80 != 0) {
        if (isCont(at(s, posi))) return raise(th, "initial position is a continuation byte", .{});
        while (isCont(at(s, posi + 1))) posi += 1;
    }
    th.push(.int(posi + 1));
    return 2;
}

fn iterAux(th: *Thread, base: u32, comptime strict: bool) Error!u32 {
    const a: Args = .init(th, base, "for iterator");
    const str = try a.checkString(1);
    const l = str.len;
    var n: u64 = @bitCast(auxlib.toInteger(a.get(2)) orelse 0);
    const s = str.bytesZ().ptr;
    if (n < l) {
        while (isCont(s[n])) n += 1;
    }
    if (n >= l) return 0;
    const d = decode(s + n, strict) orelse return raise(th, msg_invalid, .{});
    if (isCont(s[n + d.len])) return raise(th, msg_invalid, .{});
    th.push(.int(@intCast(n + 1)));
    th.push(.int(d.code));
    return 2;
}

fn iterStrict(th: *Thread, base: u32) Error!u32 {
    return iterAux(th, base, true);
}

fn iterLax(th: *Thread, base: u32) Error!u32 {
    return iterAux(th, base, false);
}

/// `utf8.codes(s [, lax])`: the generic-for triple over `s`'s characters.
fn codes(th: *Thread, base: u32) Error!u32 {
    const a: Args = .init(th, base, "codes");
    const lax = !a.get(2).isFalsy();
    const str = try a.checkString(1);
    if (isCont(str.bytesZ()[0])) return a.argError(1, msg_invalid, .{});
    th.push(.native(if (lax) &iterLax else &iterStrict));
    th.push(.string(str));
    th.push(.int(0));
    return 3;
}

// ---------------------------------------------------------------------------
// Tests. Expected values come from reference Lua 5.5.1 (`lua` in the dev
// shell), most from the cases in test/lua-5.5.1-tests/utf8.lua.
// ---------------------------------------------------------------------------

const testing = std.testing;
const h = auxlib.testing;

test "utf8 functions match the reference" {
    @setEvalBranchQuota(100_000);
    const state = try h.newState();
    defer state.destroy();
    try open(state);
    try h.expectCases(state, .{
        .{
            "utf8.char",
            .{ @as(i64, 72), @as(i64, 2047), @as(i64, 2048), @as(i64, 65535), @as(i64, 65536), @as(i64, 1114111) },
            "H\xdf\xbf\xe0\xa0\x80\xef\xbf\xbf\xf0\x90\x80\x80\xf4\x8f\xbf\xbf",
        },
        .{ "utf8.char", .{}, "" },
        .{ "utf8.char", .{@as(i64, 2147483647)}, "\xfd\xbf\xbf\xbf\xbf\xbf" },
        .{ "utf8.char", .{@as(i64, 2147483648)}, "error: bad argument #1 to 'char' (value out of range)" },
        .{ "utf8.char", .{@as(i64, -1)}, "error: bad argument #1 to 'char' (value out of range)" },
        .{ "utf8.char", .{@as(i64, 2097152)}, "\xf8\x88\x80\x80\x80" },
        .{ "utf8.char", .{@as(i64, 67108864)}, "\xfc\x84\x80\x80\x80\x80" },
        .{ "utf8.char", .{@as(i64, 55296)}, "\xed\xa0\x80" },
        .{ "utf8.char", .{"65"}, "A" },
        .{ "utf8.char", .{@as(f64, 1.5)}, "error: bad argument #1 to 'char' (number has no integer representation)" },
        .{ "utf8.charpattern", .{}, "error: attempt to call a string value" },
        .{ "utf8.len", .{"abc"}, "3" },
        .{ "utf8.len", .{""}, "0" },
        .{ "utf8.len", .{"a\xf4\x8f\xbf\xbfb"}, "3" },
        .{
            "utf8.len",
            .{ "abc", @as(i64, 0), @as(i64, 2) },
            "error: bad argument #2 to 'len' (initial position out of bounds)",
        },
        .{
            "utf8.len",
            .{ "abc", @as(i64, 1), @as(i64, 4) },
            "error: bad argument #3 to 'len' (final position out of bounds)",
        },
        .{ "utf8.len", .{ "abc", @as(i64, 4) }, "0" },
        .{ "utf8.len", .{ "abc", @as(i64, 5) }, "error: bad argument #2 to 'len' (initial position out of bounds)" },
        .{ "utf8.len", .{ "abc", @as(i64, -1) }, "1" },
        .{ "utf8.len", .{ "abc", @as(i64, -4) }, "error: bad argument #2 to 'len' (initial position out of bounds)" },
        .{ "utf8.len", .{ "abc", @as(i64, 1), @as(i64, -4) }, "0" },
        .{ "utf8.len", .{"\xf4\x9f\xbf\xbf"}, "nil\t1" },
        .{ "utf8.len", .{ "\xf4\x9f\xbf\xbf", @as(i64, 1), @as(i64, -1), true }, "1" },
        .{ "utf8.len", .{"a\x80b"}, "nil\t2" },
        .{ "utf8.len", .{"\xed\xa0\x80"}, "nil\t1" },
        .{ "utf8.len", .{ "\xed\xa0\x80", @as(i64, 1), @as(i64, -1), true }, "1" },
        .{ "utf8.len", .{"\xc0\x80"}, "nil\t1" },
        .{ "utf8.len", .{"\xff"}, "nil\t1" },
        .{ "utf8.len", .{ "\xfd\xbf\xbf\xbf\xbf\xbf", @as(i64, 1), @as(i64, -1), true }, "1" },
        .{ "utf8.len", .{"\xfd\xbf\xbf\xbf\xbf\xbf"}, "nil\t1" },
        .{ "utf8.len", .{ "\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e", @as(i64, 2) }, "nil\t2" },
        .{ "utf8.len", .{ "\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e", @as(i64, 4) }, "2" },
        .{ "utf8.len", .{ "x", @as(i64, 1), @as(i64, 1) }, "1" },
        .{ "utf8.len", .{ "x", @as(i64, 2), @as(i64, 1) }, "0" },
        .{ "utf8.codepoint", .{"abc"}, "97" },
        .{ "utf8.codepoint", .{ "abc", @as(i64, 1), @as(i64, -1) }, "97\t98\t99" },
        .{
            "utf8.codepoint",
            .{ "\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e", @as(i64, 1), @as(i64, -1) },
            "26085\t26412\t35486",
        },
        .{ "utf8.codepoint", .{ "\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e", @as(i64, 4) }, "26412" },
        .{ "utf8.codepoint", .{ "\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e", @as(i64, 2) }, "error: invalid UTF-8 code" },
        .{ "utf8.codepoint", .{ "abc", @as(i64, 3), @as(i64, 2) }, "" },
        .{ "utf8.codepoint", .{ "abc", @as(i64, 4) }, "error: bad argument #3 to 'codepoint' (out of bounds)" },
        .{ "utf8.codepoint", .{ "abc", @as(i64, 0) }, "error: bad argument #2 to 'codepoint' (out of bounds)" },
        .{
            "utf8.codepoint",
            .{ "abc", @as(i64, 1), @as(i64, 4) },
            "error: bad argument #3 to 'codepoint' (out of bounds)",
        },
        .{
            "utf8.codepoint",
            .{ "abc", @as(i64, -4), @as(i64, 1) },
            "error: bad argument #2 to 'codepoint' (out of bounds)",
        },
        .{ "utf8.codepoint", .{"\xed\xa0\x80"}, "error: invalid UTF-8 code" },
        .{ "utf8.codepoint", .{ "\xed\xa0\x80", @as(i64, 1), @as(i64, 1), true }, "55296" },
        .{ "utf8.codepoint", .{ "\xfd\xbf\xbf\xbf\xbf\xbf", @as(i64, 1), @as(i64, 1), true }, "2147483647" },
        .{ "utf8.codepoint", .{"\xf4\x90\x80\x80"}, "error: invalid UTF-8 code" },
        .{ "utf8.codepoint", .{ "\xf4\x90\x80\x80", @as(i64, 1), @as(i64, -1), @as(i64, 1) }, "1114112" },
        .{ "utf8.codepoint", .{""}, "error: bad argument #3 to 'codepoint' (out of bounds)" },
        .{ "utf8.codepoint", .{ "", @as(i64, 1), @as(i64, 0) }, "" },
        .{ "utf8.codepoint", .{ "a\x00b", @as(i64, 1), @as(i64, -1) }, "97\t0\t98" },
        .{ "utf8.offset", .{ "a\xc3\xb1b", @as(i64, 2) }, "2\t3" },
        .{ "utf8.offset", .{ "a\xc3\xb1b", @as(i64, -1) }, "4\t4" },
        .{ "utf8.offset", .{ "a\xc3\xb1b", @as(i64, 3) }, "4\t4" },
        .{ "utf8.offset", .{ "a\xc3\xb1b", @as(i64, 4) }, "5\t5" },
        .{ "utf8.offset", .{ "a\xc3\xb1b", @as(i64, 5) }, "nil" },
        .{ "utf8.offset", .{ "a\xc3\xb1b", @as(i64, 0), @as(i64, 3) }, "2\t3" },
        .{ "utf8.offset", .{ "a\xc3\xb1b", @as(i64, 0), @as(i64, 2) }, "2\t3" },
        .{ "utf8.offset", .{ "a\xc3\xb1b", @as(i64, -2) }, "2\t3" },
        .{ "utf8.offset", .{ "a\xc3\xb1b", @as(i64, -3) }, "1\t1" },
        .{ "utf8.offset", .{ "a\xc3\xb1b", @as(i64, -4) }, "nil" },
        .{
            "utf8.offset",
            .{ "abc", @as(i64, 1), @as(i64, 5) },
            "error: bad argument #3 to 'offset' (position out of bounds)",
        },
        .{
            "utf8.offset",
            .{ "abc", @as(i64, 1), @as(i64, -4) },
            "error: bad argument #3 to 'offset' (position out of bounds)",
        },
        .{
            "utf8.offset",
            .{ "", @as(i64, 1), @as(i64, 2) },
            "error: bad argument #3 to 'offset' (position out of bounds)",
        },
        .{
            "utf8.offset",
            .{ "", @as(i64, 1), @as(i64, -1) },
            "error: bad argument #3 to 'offset' (position out of bounds)",
        },
        .{
            "utf8.offset",
            .{ "\xf0\xa6\xa7\xba", @as(i64, 1), @as(i64, 2) },
            "error: initial position is a continuation byte",
        },
        .{ "utf8.offset", .{ "\x80", @as(i64, 1) }, "error: initial position is a continuation byte" },
        .{ "utf8.offset", .{ "\x9c", @as(i64, -1) }, "error: initial position is a continuation byte" },
        .{ "utf8.offset", .{ "", @as(i64, 1) }, "1\t1" },
        .{ "utf8.offset", .{ "", @as(i64, 0) }, "1\t1" },
        .{ "utf8.offset", .{ "", @as(i64, -1) }, "nil" },
        .{ "utf8.offset", .{ "\xf0\xa6\xa7\xbax", @as(i64, 1) }, "1\t4" },
        .{ "utf8.offset", .{ "\xf0\xa6\xa7\xbax", @as(i64, 2) }, "5\t5" },
        .{ "utf8.offset", .{ "\xf0\xa6\xa7\xbax", @as(i64, 0), @as(i64, 4) }, "1\t4" },
        .{ "utf8.offset", .{ "abc", @as(i64, 2), @as(i64, 2) }, "3\t3" },
        .{ "utf8.offset", .{"abc"}, "error: bad argument #2 to 'offset' (number expected, got no value)" },
        .{
            "utf8.offset",
            .{ "abc", @as(f64, 1.5) },
            "error: bad argument #2 to 'offset' (number has no integer representation)",
        },
        .{ "utf8.offset", .{ "a\xc3", @as(i64, 2) }, "2\t2" },
        .{ "utf8.offset", .{ "\xc3\xb1", @as(i64, 0), @as(i64, 2) }, "1\t2" },
        .{ "utf8.codes", .{"\x80"}, "error: bad argument #1 to 'codes' (invalid UTF-8 code)" },
        .{ "utf8.codes", .{ "abc", true }, "function\tabc\t0" },
        .{ "utf8.codes", .{}, "error: bad argument #1 to 'codes' (string expected, got no value)" },
        .{ "utf8.codes", .{@as(i64, 1)}, "function\t1\t0" },
    });
}

test "codes iterates over characters with their positions" {
    const state = try h.newState();
    defer state.destroy();
    try open(state);
    const iter = try h.global(state, "utf8.codes");
    const cases = .{
        .{ .{"añ€😀"}, "1:97,2:241,4:8364,7:128512" },
        .{ .{"a\x80"}, "error: invalid UTF-8 code" },
        .{ .{"a\xed\xa0\x80"}, "1:97,error: invalid UTF-8 code" },
        .{ .{ "a\xed\xa0\x80", true }, "1:97,2:55296" },
        .{ .{"ab\xff"}, "1:97,2:98,error: invalid UTF-8 code" },
    };
    inline for (cases) |c| {
        const r = try h.ok(state, iter, try h.vals(state, c[0]));
        const f = r[0];
        const s = r[1];
        var buf: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        var ctl: Value = r[2];
        while (true) {
            switch (try h.call(state, f, &.{ s, ctl })) {
                .ok => |res| {
                    if (res.len == 0) break;
                    if (w.end > 0) try w.writeByte(',');
                    try w.print("{d}:{d}", .{ res[0].asInt(), res[1].asInt() });
                    ctl = res[0];
                },
                .err => |e| {
                    if (w.end > 0) try w.writeByte(',');
                    try w.print("error: {s}", .{e.asString().bytes()});
                    break;
                },
            }
        }
        try testing.expectEqualStrings(c[1], w.buffered());
    }
}

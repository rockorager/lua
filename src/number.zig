//! Lua numbers: conversion between numerals and numbers, and the arithmetic
//! Lua defines differently from Zig. Plain `i64` and `f64` in and out.
//!
//! The rules are the reference manual's §3.1 (numerals) and §3.4.3
//! (coercions), worded the way reference Lua 5.5.1 implements them in
//! lobject.c (`luaO_str2num`, `tostringbuffFloat`) and lvm.c (`luaV_idiv`,
//! `luaV_mod`, `luaV_shiftl`, `luaV_flttointeger`, the mixed comparisons).

const std = @import("std");
const math = std.math;

/// A Lua number: an integer or a float subtype.
pub const Number = union(enum) {
    int: i64,
    float: f64,
};

// ---------------------------------------------------------------------------
// Numeral to number
// ---------------------------------------------------------------------------

/// Converts a numeral to a number, as `tonumber` and string coercion do:
/// optional whitespace around it, an optional sign, then a decimal or
/// hexadecimal integer or float. A decimal integer that does not fit in an
/// `i64` becomes a float; a hexadecimal integer wraps around. `inf` and
/// `nan` are not numerals. Returns null when `s` is not a numeral, which
/// includes any embedded zero byte.
pub fn parse(s: []const u8) ?Number {
    if (parseInt(s)) |i| return .{ .int = i };
    if (parseFloat(s)) |f| return .{ .float = f };
    return null;
}

/// `l_str2int`: the numeral as an integer, or null when it has a fraction,
/// an exponent, or a decimal value outside the `i64` range.
fn parseInt(s: []const u8) ?i64 {
    var i: usize = 0;
    while (i < s.len and isSpace(s[i])) i += 1;
    var neg = false;
    if (i < s.len and (s[i] == '-' or s[i] == '+')) {
        neg = s[i] == '-';
        i += 1;
    }
    var a: u64 = 0;
    var empty = true;
    if (i + 1 < s.len and s[i] == '0' and (s[i + 1] | 0x20) == 'x') {
        i += 2;
        while (i < s.len) : (i += 1) {
            const d = hexValue(s[i]) orelse break;
            a = a *% 16 +% d;
            empty = false;
        }
    } else {
        const max_by_10: u64 = math.maxInt(i64) / 10;
        const max_last_digit: u64 = math.maxInt(i64) % 10;
        while (i < s.len and isDigit(s[i])) : (i += 1) {
            const d = s[i] - '0';
            if (a >= max_by_10 and (a > max_by_10 or d > max_last_digit + @intFromBool(neg)))
                return null;
            a = a * 10 + d;
            empty = false;
        }
    }
    while (i < s.len and isSpace(s[i])) i += 1;
    if (empty or i != s.len) return null;
    return @bitCast(if (neg) 0 -% a else a);
}

/// `l_str2d`: the numeral as a float, by C's `strtod` grammar without
/// `inf` and `nan`, correctly rounded.
fn parseFloat(s: []const u8) ?f64 {
    var lo: usize = 0;
    var hi: usize = s.len;
    while (lo < hi and isSpace(s[lo])) lo += 1;
    while (hi > lo and isSpace(s[hi - 1])) hi -= 1;
    const t = s[lo..hi];
    var i: usize = 0;
    var neg = false;
    if (i < t.len and (t[i] == '-' or t[i] == '+')) {
        neg = t[i] == '-';
        i += 1;
    }
    if (i + 1 < t.len and t[i] == '0' and (t[i + 1] | 0x20) == 'x') {
        const f = parseHexFloat(t[i + 2 ..]) orelse return null;
        return if (neg) -f else f;
    }
    // Decimal: digits [. digits] with at least one digit, then [e [sign] digits].
    var digits: usize = 0;
    while (i < t.len and isDigit(t[i])) : (i += 1) digits += 1;
    if (i < t.len and t[i] == '.') {
        i += 1;
        while (i < t.len and isDigit(t[i])) : (i += 1) digits += 1;
    }
    if (digits == 0) return null;
    if (i < t.len and (t[i] | 0x20) == 'e') {
        i += 1;
        if (i < t.len and (t[i] == '-' or t[i] == '+')) i += 1;
        const start = i;
        while (i < t.len and isDigit(t[i])) i += 1;
        if (i == start) return null;
    }
    if (i != t.len) return null;
    // The grammar above is a subset of std's (no underscores, no inf or
    // nan), and std rounds decimal input correctly.
    return std.fmt.parseFloat(f64, t) catch unreachable;
}

/// The part of a hexadecimal float after `0x`: hex digits with an optional
/// point, at least one digit, and an optional binary exponent `p[sign]digits`.
/// Rounds to nearest, ties to even, as `strtod` does.
fn parseHexFloat(t: []const u8) ?f64 {
    var mant: u64 = 0;
    var exp: i64 = 0; // value = mant * 2^exp, plus a little if `sticky`
    var sticky = false;
    var digits: usize = 0;
    var i: usize = 0;
    var seen_point = false;
    while (i < t.len) : (i += 1) {
        if (t[i] == '.' and !seen_point) {
            seen_point = true;
            continue;
        }
        const d = hexValue(t[i]) orelse break;
        digits += 1;
        if (mant >> 60 == 0) {
            mant = mant * 16 + d;
            if (seen_point) exp -= 4;
        } else {
            sticky = sticky or d != 0;
            if (!seen_point) exp += 4;
        }
    }
    if (digits == 0) return null;
    if (i < t.len and (t[i] | 0x20) == 'p') {
        i += 1;
        var eneg = false;
        if (i < t.len and (t[i] == '-' or t[i] == '+')) {
            eneg = t[i] == '-';
            i += 1;
        }
        const start = i;
        var e: i64 = 0;
        while (i < t.len and isDigit(t[i])) : (i += 1) {
            // Saturate far outside the float range, so `exp` cannot overflow.
            if (e < 1 << 40) e = e * 10 + (t[i] - '0');
        }
        if (i == start) return null;
        exp += if (eneg) -e else e;
    }
    if (i != t.len) return null;
    if (mant == 0) return 0.0;

    // Normalize to mant in [2^63, 2^64); the value is in [2^top, 2^(top+1)).
    const lz = @clz(mant);
    mant <<= @intCast(lz);
    exp -= lz;
    const top = exp + 63;
    if (top > 1023) return math.inf(f64);
    // Keep 53 bits for a normal result, fewer for a subnormal one.
    const shift: u64 = if (top >= -1022) 11 else @intCast(@min(11 + (-1022 - top), 65));
    if (shift > 64) return 0.0;
    var q: u64 = if (shift == 64) 0 else mant >> @intCast(shift);
    const rest: u64 = if (shift == 64) mant else mant & ((@as(u64, 1) << @intCast(shift)) - 1);
    const half = @as(u64, 1) << @intCast(shift - 1);
    if (rest > half or (rest == half and (sticky or q & 1 == 1))) q += 1;
    // For a normal result q holds the implicit bit, so adding the biased
    // exponent above it yields the bit pattern, and a carry out of the
    // mantissa bumps the exponent. A subnormal q is the pattern itself.
    const bits: u64 = if (top >= -1022) (@as(u64, @intCast(top + 1022)) << 52) + q else q;
    if (bits >= 0x7ff0_0000_0000_0000) return math.inf(f64);
    return @bitCast(bits);
}

/// `lisspace` in Lua's lctype: the C locale's whitespace.
fn isSpace(c: u8) bool {
    return c == ' ' or (c >= '\t' and c <= '\r');
}

fn isDigit(c: u8) bool {
    return c -% '0' < 10;
}

fn hexValue(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Number to numeral
// ---------------------------------------------------------------------------

/// Buffer size for `formatInt` and `formatFloat`, `LUA_N2SBUFFSZ`.
pub const max_len = 64;

/// An integer as `tostring` writes it: plain decimal.
pub fn formatInt(buf: *[max_len]u8, i: i64) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{i}) catch unreachable;
}

/// A float as `tostring` writes it. Like C's `%.15g`, or `%.17g` when 15
/// digits do not read back as the same float, with `.0` appended when the
/// result looks like an integer: `1e+15`, `9007199254740992.0`, `0.1`,
/// `-0.0`, `inf`, `-nan`. NaN keeps the sign of its sign bit, as glibc's
/// printf does.
pub fn formatFloat(buf: *[max_len]u8, f: f64) []const u8 {
    var len: usize = 0;
    if (math.signbit(f)) {
        buf[0] = '-';
        len = 1;
    }
    const a = @abs(f);
    const special: ?[]const u8 = if (math.isNan(a))
        "nan"
    else if (math.isInf(a))
        "inf"
    else if (a == 0)
        "0.0"
    else
        null;
    if (special) |s| {
        @memcpy(buf[len..][0..s.len], s);
        return buf[0 .. len + s.len];
    }

    // The shortest digits that read back as `a`. For a normal float with
    // 15 or fewer, they are also `%.15g`'s digits: the 15-digit decimals
    // there are spaced more than ten half-ulps apart, so the one nearest to
    // `a` is the shortest. More than 15 means `%.15g` does not read back.
    // A subnormal's ulp is too coarse for that, so it rounds exactly and
    // reads back the way the reference does.
    const d = std.fmt.float.binaryToDecimal(u64, @bitCast(a), 52, 11, false, &std.fmt.float.Backend64_TablesFull);
    var m = d.mantissa;
    var x: i32 = d.exponent;
    while (m % 10 == 0) {
        m /= 10;
        x += 1;
    }
    var digits_buf: [20]u8 = undefined;
    var ds: []const u8 = std.fmt.bufPrint(&digits_buf, "{d}", .{m}) catch unreachable;
    x += @as(i32, @intCast(ds.len)) - 1;
    var precision: i32 = 15;
    if (a < math.floatMin(f64)) {
        const r = exactDigits(a, x, 15);
        const ds15 = std.mem.trimEnd(u8, std.fmt.bufPrint(&digits_buf, "{d}", .{r.digits}) catch unreachable, "0");
        var check: [max_len]u8 = undefined;
        const n = layoutG(&check, ds15, r.exp, 15);
        if (std.fmt.parseFloat(f64, check[0..n]) catch unreachable == a) {
            ds = ds15;
            x = r.exp;
        } else {
            precision = 17;
        }
    } else if (ds.len > 15) {
        precision = 17;
    }
    if (precision == 17) {
        const r = exactDigits(a, x, 17);
        x = r.exp;
        ds = std.mem.trimEnd(u8, std.fmt.bufPrint(&digits_buf, "{d}", .{r.digits}) catch unreachable, "0");
    }
    len += layoutG(buf[len..], ds, x, precision);
    // Looks like an integer: no point and no exponent.
    if (std.mem.findNone(u8, buf[0..len], "-0123456789") == null) {
        buf[len..][0..2].* = ".0".*;
        len += 2;
    }
    return buf[0..len];
}

/// Writes significant digits `ds` (no trailing zeros), whose first digit is
/// in the 10^x place, the way `%.{precision}g` lays them out.
fn layoutG(out: []u8, ds: []const u8, x: i32, precision: i32) usize {
    var w: std.Io.Writer = .fixed(out);
    if (x < -4 or x >= precision) {
        w.writeByte(ds[0]) catch unreachable;
        if (ds.len > 1) w.print(".{s}", .{ds[1..]}) catch unreachable;
        w.print("e{c}{d:0>2}", .{ @as(u8, if (x < 0) '-' else '+'), @abs(x) }) catch unreachable;
    } else if (x >= 0) {
        const int_digits: usize = @intCast(x + 1);
        if (ds.len <= int_digits) {
            w.writeAll(ds) catch unreachable;
            w.splatByteAll('0', int_digits - ds.len) catch unreachable;
        } else {
            w.print("{s}.{s}", .{ ds[0..int_digits], ds[int_digits..] }) catch unreachable;
        }
    } else {
        w.writeAll("0.") catch unreachable;
        w.splatByteAll('0', @intCast(-x - 1)) catch unreachable;
        w.writeAll(ds) catch unreachable;
    }
    return w.end;
}

/// `a` rounded to `precision` significant digits exactly, as glibc's printf
/// does (to nearest, ties to even): `digits` in [10^(precision-1),
/// 10^precision), the first one in the 10^exp place. `guess` is the decimal
/// exponent of `a`'s shortest digits, which is `exp` or one more. Precision
/// 15 is only asked of subnormals.
fn exactDigits(a: f64, guess: i32, comptime precision: u5) struct { digits: u64, exp: i32 } {
    const bits: u64 = @bitCast(a);
    const biased: i32 = @intCast(bits >> 52);
    const frac = bits & ((@as(u64, 1) << 52) - 1);
    // a = m * 2^e exactly.
    const m: u64 = if (biased == 0) frac else frac | (@as(u64, 1) << 52);
    const e: i32 = @as(i32, @max(biased, 1)) - 1075;
    const lo: u64 = comptime math.powi(u64, 10, precision - 1) catch unreachable;
    const hi: u64 = lo * 10;
    var x = guess;
    while (true) {
        // q = a * 10^(precision - 1 - x), truncated, and how the dropped
        // part compares with one half.
        const s = precision - 1 - x;
        var n: Big = .init(m);
        var q: u64 = undefined;
        var half: math.Order = undefined;
        if (s >= 0) {
            n.mulPow10(@intCast(s));
            if (e >= 0) {
                n.shl(@intCast(e));
                q = n.toU64Saturating();
                half = .lt;
            } else {
                q, half = n.shrRounding(@intCast(-e));
            }
        } else {
            // Only a >= 10^17 > 2^53 gets here, so e > 0 and a is an integer.
            n.shl(@intCast(e));
            q, half = n.divPow10(@intCast(-s));
        }
        if (q >= hi) {
            x += 1;
            continue;
        }
        if (q < lo) {
            x -= 1;
            continue;
        }
        if (half == .gt or (half == .eq and q & 1 == 1)) q += 1;
        if (q == hi) return .{ .digits = lo, .exp = x + 1 };
        return .{ .digits = q, .exp = x };
    }
}

/// A nonnegative integer big enough for m * 10^340 with m < 2^53, the
/// largest product `exactDigits` forms: about 1,183 bits.
const Big = struct {
    limbs: [40]u32,
    len: usize,

    fn init(v: u64) Big {
        var b: Big = .{ .limbs = undefined, .len = 0 };
        var x = v;
        while (x != 0) : (x >>= 32) {
            b.limbs[b.len] = @truncate(x);
            b.len += 1;
        }
        return b;
    }

    fn mulSmall(b: *Big, k: u32) void {
        var carry: u64 = 0;
        for (b.limbs[0..b.len]) |*l| {
            const p = @as(u64, l.*) * k + carry;
            l.* = @truncate(p);
            carry = p >> 32;
        }
        if (carry != 0) {
            b.limbs[b.len] = @intCast(carry);
            b.len += 1;
        }
    }

    fn mulPow10(b: *Big, n: u32) void {
        var left = n;
        while (left >= 9) : (left -= 9) b.mulSmall(1_000_000_000);
        if (left > 0) b.mulSmall(math.powi(u32, 10, left) catch unreachable);
    }

    /// Divides by k in place and returns the remainder.
    fn divSmall(b: *Big, k: u32) u32 {
        var rem: u64 = 0;
        var i = b.len;
        while (i > 0) {
            i -= 1;
            const cur = (rem << 32) | b.limbs[i];
            b.limbs[i] = @intCast(cur / k);
            rem = cur % k;
        }
        while (b.len > 0 and b.limbs[b.len - 1] == 0) b.len -= 1;
        return @intCast(rem);
    }

    fn shl(b: *Big, n: u32) void {
        if (b.len == 0) return;
        const limbs = n / 32;
        const bits: u5 = @intCast(n % 32);
        var i = b.len;
        b.limbs[b.len + limbs] = 0;
        while (i > 0) {
            i -= 1;
            const v = b.limbs[i];
            if (bits != 0) b.limbs[i + limbs + 1] |= v >> @intCast(@as(u6, 32) - bits);
            b.limbs[i + limbs] = v << bits;
        }
        @memset(b.limbs[0..limbs], 0);
        b.len += limbs + 1;
        while (b.len > 0 and b.limbs[b.len - 1] == 0) b.len -= 1;
    }

    fn bit(b: *const Big, i: usize) bool {
        const l = i / 32;
        if (l >= b.len) return false;
        return (b.limbs[l] >> @intCast(i % 32)) & 1 == 1;
    }

    fn toU64Saturating(b: *const Big) u64 {
        if (b.len > 2) return math.maxInt(u64);
        var v: u64 = 0;
        if (b.len > 1) v = @as(u64, b.limbs[1]) << 32;
        if (b.len > 0) v |= b.limbs[0];
        return v;
    }

    /// floor(b / 2^n), saturated, and how b mod 2^n compares with 2^(n-1).
    fn shrRounding(b: *const Big, n: u32) struct { u64, math.Order } {
        var q: u64 = 0;
        var i: usize = 64;
        while (i > 0) {
            i -= 1;
            q = (q << 1) | @intFromBool(b.bit(n + i));
        }
        if (b.len > 0 and (b.len - 1) * 32 + (32 - @clz(b.limbs[b.len - 1])) > n + 64) q = math.maxInt(u64);
        if (n == 0) return .{ q, .lt };
        if (!b.bit(n - 1)) return .{ q, .lt };
        var j: usize = 0;
        while (j < n - 1) : (j += 1) {
            if (b.bit(j)) return .{ q, .gt };
        }
        return .{ q, .eq };
    }

    /// floor(b / 10^n), saturated, and how b mod 10^n compares with
    /// 10^n / 2. Clobbers b.
    fn divPow10(b: *Big, n: u32) struct { u64, math.Order } {
        var sticky = false;
        var left = n - 1;
        while (left >= 9) : (left -= 9) sticky = b.divSmall(1_000_000_000) != 0 or sticky;
        while (left > 0) : (left -= 1) sticky = b.divSmall(10) != 0 or sticky;
        const last = b.divSmall(10);
        const half: math.Order = if (last != 5) math.order(last, 5) else if (sticky) .gt else .eq;
        return .{ b.toU64Saturating(), half };
    }
};

// ---------------------------------------------------------------------------
// Arithmetic
// ---------------------------------------------------------------------------

/// Integer floor division, `//`: rounds toward minus infinity, and
/// `minInt(i64) // -1` wraps to `minInt(i64)`. The caller raises "attempt
/// to perform 'n//0'" on `error.DivisionByZero`.
pub fn divFloorInt(m: i64, n: i64) error{DivisionByZero}!i64 {
    if (n == 0) return error.DivisionByZero;
    if (n == -1) return 0 -% m;
    return @divFloor(m, n);
}

/// Integer modulo, `%`: the result has the sign of the divisor. The caller
/// raises "attempt to perform 'n%%0'" on `error.DivisionByZero`.
pub fn modInt(m: i64, n: i64) error{DivisionByZero}!i64 {
    if (n == 0) return error.DivisionByZero;
    if (n == -1) return 0;
    return @mod(m, n);
}

/// Float floor division, `//`: floor(m / n).
pub fn divFloorFloat(m: f64, n: f64) f64 {
    return @floor(m / n);
}

/// Float modulo, `%`: C's `fmod`, moved to the divisor's sign when the two
/// differ, as `luai_nummod` does. `5.0 % math.huge` is 5.0 and `-5.0 %
/// math.huge` is `math.huge`.
pub fn modFloat(m: f64, n: f64) f64 {
    var r = @rem(m, n);
    if (if (r > 0) n < 0 else (r < 0 and n > 0)) r += n;
    return r;
}

/// `x << n` on the integer's bits: a negative `n` shifts right, and any
/// shift of 64 or more either way yields 0. Right shifts fill with zeros.
pub fn shiftLeft(x: i64, n: i64) i64 {
    if (n <= -64 or n >= 64) return 0;
    const u: u64 = @bitCast(x);
    return @bitCast(if (n < 0) u >> @intCast(-n) else u << @intCast(n));
}

/// `x >> n`, which is `x << -n`.
pub fn shiftRight(x: i64, n: i64) i64 {
    return shiftLeft(x, 0 -% n);
}

/// How `floatToInt` treats a float with a fraction.
pub const Rounding = enum {
    /// Fail: only integral floats convert, as for table keys, `math.tointeger`,
    /// and bitwise operands.
    exact,
    floor,
    ceil,
};

/// The float as an integer, or null when it is NaN, out of the `i64` range
/// after rounding, or not integral under `.exact`.
pub fn floatToInt(f: f64, rounding: Rounding) ?i64 {
    var r = @floor(f);
    if (f != r) switch (rounding) {
        .exact => return null,
        .floor => {},
        .ceil => r += 1,
    };
    // -2^63 is exact as a float; 2^63 is the first float above the range.
    if (r >= -0x1p63 and r < 0x1p63) return @intFromFloat(r);
    return null;
}

/// Whether an integer converts to a float exactly: |i| <= 2^53.
fn intFitsFloat(i: i64) bool {
    return (@as(u64, 1 << 53) +% @as(u64, @bitCast(i))) <= 1 << 54;
}

/// `i == f`, exactly: false for every float that is not integral.
pub fn eqIntFloat(i: i64, f: f64) bool {
    return if (floatToInt(f, .exact)) |fi| fi == i else false;
}

/// `i < f`, exactly, with no rounding of `i`.
pub fn ltIntFloat(i: i64, f: f64) bool {
    if (intFitsFloat(i)) return @as(f64, @floatFromInt(i)) < f;
    // i < f <=> i < ceil(f)
    if (floatToInt(f, .ceil)) |fi| return i < fi;
    return f > 0;
}

/// `i <= f`, exactly.
pub fn leIntFloat(i: i64, f: f64) bool {
    if (intFitsFloat(i)) return @as(f64, @floatFromInt(i)) <= f;
    // i <= f <=> i <= floor(f)
    if (floatToInt(f, .floor)) |fi| return i <= fi;
    return f > 0;
}

/// `f < i`, exactly.
pub fn ltFloatInt(f: f64, i: i64) bool {
    if (intFitsFloat(i)) return f < @as(f64, @floatFromInt(i));
    // f < i <=> floor(f) < i
    if (floatToInt(f, .floor)) |fi| return fi < i;
    return f < 0;
}

/// `f <= i`, exactly.
pub fn leFloatInt(f: f64, i: i64) bool {
    if (intFitsFloat(i)) return f <= @as(f64, @floatFromInt(i));
    // f <= i <=> ceil(f) <= i
    if (floatToInt(f, .ceil)) |fi| return fi <= i;
    return f < 0;
}

// ---------------------------------------------------------------------------
// Tests. Expected values come from reference Lua 5.5.1: `tostring(x)`,
// `tonumber(s)`, and the operators, run in the dev shell's `lua`.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "formatFloat matches tostring" {
    const cases = [_]struct { f64, []const u8 }{
        .{ 0.0, "0.0" },
        .{ -0.0, "-0.0" },
        .{ math.inf(f64), "inf" },
        .{ -math.inf(f64), "-inf" },
        .{ @bitCast(@as(u64, 0xfff8_0000_0000_0000)), "-nan" }, // 0/0 on x86
        .{ @bitCast(@as(u64, 0x7ff8_0000_0000_0000)), "nan" },
        .{ 1e15, "1e+15" },
        .{ 1e16, "1e+16" },
        .{ 0x1p53, "9007199254740992.0" },
        .{ 0x1p63, "9.2233720368547758e+18" },
        .{ -0x1p63, "-9.2233720368547758e+18" },
        .{ 0x1.999999999999ap-4, "0.1" },
        .{ 0x1.3333333333334p-2, "0.30000000000000004" },
        // Shortest is 0.7999999999999999; %.17g's exact digits differ.
        .{ 0x1.9999999999999p-1, "0.79999999999999993" },
        .{ 0x1.5555555555555p-2, "0.33333333333333331" },
        .{ 100.0, "100.0" },
        .{ 1e100, "1e+100" },
        .{ 1e-5, "1e-05" },
        .{ 1e-4, "0.0001" },
        .{ 123456789012345.0, "123456789012345.0" },
        .{ 1234567890123456.0, "1234567890123456.0" },
        // Subnormals: %.15g reads back, though the shortest is "5e-324".
        .{ 0x0.0000000000001p-1022, "4.94065645841247e-324" },
        .{ 0x0.0000000000002p-1022, "9.88131291682493e-324" },
        .{ 0x1.fffffffffffffp+1023, "1.7976931348623157e+308" },
        .{ 0x1p-1022, "2.2250738585072014e-308" },
        .{ -1.5, "-1.5" },
        .{ 0x1.921f9f01b866ep+1, "3.14159" },
    };
    var buf: [max_len]u8 = undefined;
    for (cases) |c| try testing.expectEqualStrings(c[1], formatFloat(&buf, c[0]));
}

test "formatInt writes plain decimal" {
    var buf: [max_len]u8 = undefined;
    try testing.expectEqualStrings("-9223372036854775808", formatInt(&buf, math.minInt(i64)));
    try testing.expectEqualStrings("0", formatInt(&buf, 0));
}

test "parse matches tonumber" {
    const cases = [_]struct { []const u8, ?Number }{
        .{ "10", .{ .int = 10 } },
        .{ "  0x10  ", .{ .int = 16 } },
        .{ "-0x1", .{ .int = -1 } },
        // Hex integers wrap; decimal ones become floats.
        .{ "0xffffffffffffffff", .{ .int = -1 } },
        .{ "0x1ffffffffffffffff", .{ .int = -1 } },
        .{ "9223372036854775807", .{ .int = 9223372036854775807 } },
        .{ "9223372036854775808", .{ .float = 0x1p+63 } },
        .{ "-9223372036854775808", .{ .int = -9223372036854775808 } },
        .{ "-9223372036854775809", .{ .float = -0x1p+63 } },
        .{ "1e2", .{ .float = 100.0 } },
        .{ " .5 ", .{ .float = 0.5 } },
        .{ "1.", .{ .float = 1.0 } },
        .{ "0x.8", .{ .float = 0.5 } },
        .{ "0x1p-2", .{ .float = 0.25 } },
        .{ "0X1P+4", .{ .float = 16.0 } },
        .{ "0x1.8", .{ .float = 1.5 } },
        .{ "1e400", .{ .float = math.inf(f64) } },
        .{ "0x1p-1075", .{ .float = 0.0 } },
        // Hex rounding past 53 bits: a tie to even, a tie broken by a
        // far digit, and a tie that rounds up to even.
        .{ "0x1.00000000000008p0", .{ .float = 1.0 } },
        .{ "0x1.000000000000080000000001p0", .{ .float = 0x1.0000000000001p+0 } },
        .{ "0x1.0000000000001800p0", .{ .float = 0x1.0000000000002p+0 } },
        .{ "0x1p99999999999999999999", .{ .float = math.inf(f64) } },
        .{ "\t\n\x0b\x0c\r12\r\n", .{ .int = 12 } },
        .{ "", null },
        .{ " ", null },
        .{ "0x", null },
        .{ "1e", null },
        .{ "1e+", null },
        .{ ".", null },
        .{ "inf", null },
        .{ "nan", null },
        .{ "- 1", null },
        .{ "1 2", null },
        .{ "0x1p", null },
        .{ "1_000", null },
        .{ "1\x00", null },
        .{ "0x1e+1", null },
        .{ "1e5.5", null },
    };
    for (cases) |c| try testing.expectEqualDeep(c[1], parse(c[0]));
}

test "integer and float division and modulo take Lua's signs" {
    try testing.expectEqual(3, try divFloorInt(7, 2));
    try testing.expectEqual(-4, try divFloorInt(-7, 2));
    try testing.expectEqual(-4, try divFloorInt(7, -2));
    try testing.expectEqual(math.minInt(i64), try divFloorInt(math.minInt(i64), -1));
    try testing.expectError(error.DivisionByZero, divFloorInt(1, 0));
    try testing.expectEqual(-2, try modInt(7, -3));
    try testing.expectEqual(2, try modInt(-7, 3));
    try testing.expectEqual(0, try modInt(math.minInt(i64), -1));
    try testing.expectError(error.DivisionByZero, modInt(1, 0));

    try testing.expectEqual(3.0, divFloorFloat(7.5, 2));
    try testing.expectEqual(-4.0, divFloorFloat(-7.5, 2));
    try testing.expectEqual(math.inf(f64), divFloorFloat(1, 0.0));
    try testing.expectEqual(-1.0, modFloat(5.0, -3));
    try testing.expectEqual(1.0, modFloat(-5.0, 3));
    try testing.expectEqual(5.0, modFloat(5.0, math.inf(f64)));
    try testing.expectEqual(math.inf(f64), modFloat(-5.0, math.inf(f64)));
    try testing.expectEqual(-math.inf(f64), modFloat(5.0, -math.inf(f64)));
    try testing.expect(math.isNan(modFloat(5.3, 0.0)));
    try testing.expect(math.signbit(modFloat(-0.0, 1)));
}

test "shifts saturate at 64 and fill with zeros" {
    try testing.expectEqual(math.minInt(i64), shiftLeft(1, 63));
    try testing.expectEqual(0, shiftLeft(1, 64));
    try testing.expectEqual(math.maxInt(i64), shiftRight(-1, 1));
    try testing.expectEqual(1, shiftRight(-1, 63));
    try testing.expectEqual(0, shiftRight(-1, 64));
    try testing.expectEqual(0, shiftLeft(1, -1));
    try testing.expectEqual(4, shiftRight(2, -1));
    try testing.expectEqual(0, shiftLeft(1, math.minInt(i64)));
    try testing.expectEqual(0, shiftRight(1, math.minInt(i64)));
}

test "floatToInt converts only what fits" {
    try testing.expectEqual(null, floatToInt(0x1p63, .exact));
    try testing.expectEqual(math.minInt(i64), floatToInt(-0x1p63, .exact));
    try testing.expectEqual(null, floatToInt(3.5, .exact));
    try testing.expectEqual(-4, floatToInt(-3.5, .floor));
    try testing.expectEqual(-3, floatToInt(-3.5, .ceil));
    try testing.expectEqual(null, floatToInt(math.nan(f64), .floor));
    // The largest float below 2^63 converts.
    try testing.expectEqual(0x7fff_ffff_ffff_fc00, floatToInt(0x1.fffffffffffffp+62, .exact));
}

test "integer and float compare exactly" {
    const big: i64 = (1 << 53) + 1; // rounds to 2^53 as a float
    try testing.expect(!eqIntFloat(big, 0x1p53));
    try testing.expect(ltIntFloat(big, 0x1p53 + 2));
    try testing.expect(!ltFloatInt(0x1p53 + 2, big));
    try testing.expect(ltIntFloat(math.maxInt(i64), 0x1p63));
    try testing.expect(!eqIntFloat(math.maxInt(i64), 0x1p63));
    try testing.expect(leIntFloat(math.minInt(i64), -0x1p63));
    try testing.expect(!ltIntFloat(math.minInt(i64), -0x1p63));
    try testing.expect(leFloatInt(-0x1p63, math.minInt(i64)));
    try testing.expect(!ltIntFloat(big, math.nan(f64)));
    try testing.expect(!leFloatInt(math.nan(f64), big));
    try testing.expect(ltFloatInt(-math.inf(f64), math.minInt(i64)));
    try testing.expect(ltIntFloat(math.maxInt(i64), math.inf(f64)));
}

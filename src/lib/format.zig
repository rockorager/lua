//! `string.format`: its conversions, flags, widths, and precisions, within the
//! limits and with the errors of the reference implementation.
//!
//! The reference hands each conversion to the C library's `snprintf`, so the
//! output here follows glibc's: floats print with exact decimal expansion and
//! round-half-even, `%a` follows glibc's hexadecimal layout, and a NaN prints
//! with its sign bit. The engine works over byte slices and plain numbers and
//! writes to a `std.Io.Writer`; the caller supplies the arguments through the
//! interface `format` describes.

const std = @import("std");
const testing = std.testing;
const Writer = std.Io.Writer;

/// The only error the engine raises; the message is in a `Diagnostic`.
pub const Error = error{FormatError};

/// The message of the last `error.FormatError`. When `arg` is not zero the
/// error is about that argument, and Lua reports it as
/// "bad argument #arg to 'format' (message)"; otherwise the message stands
/// alone.
pub const Diagnostic = struct {
    arg: u32 = 0,
    len: u8 = 0,
    buf: [96]u8 = undefined,

    pub fn message(d: *const Diagnostic) []const u8 {
        return d.buf[0..d.len];
    }

    fn fail(d: *Diagnostic, arg: u32, comptime fmt: []const u8, args: anytype) Error {
        const s = std.mem.print(&d.buf, fmt, args) catch unreachable;
        d.arg = arg;
        d.len = @intCast(s.len);
        return error.FormatError;
    }
};

/// How `%q` writes one argument, as the caller classifies it. `text` is for
/// nil and booleans, whose literal is their `tostring`.
pub const Literal = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    text: []const u8,
};

/// One conversion specification, after validation. Width and precision stay
/// within the reference's limit of two digits each.
pub const Spec = struct {
    minus: bool = false,
    plus: bool = false,
    space: bool = false,
    hash: bool = false,
    zero: bool = false,
    width: u8 = 0,
    precision: ?u8 = null,
    conversion: u8,
};

/// The flags each conversion accepts (`L_FMTFLAGS*`).
const flags_float = "-+#0 ";
const flags_hex = "-#0";
const flags_int = "-+0 ";
const flags_unsigned = "-0";
const flags_char = "-";

/// The longest specification, '%' and the conversion excluded (`MAX_FORMAT`
/// less the room the reference keeps for a length modifier).
const max_spec = 22;

/// Format `fmt` to `w`, as `string.format` does. Argument numbers are Lua's:
/// the format string is argument 1, and `top` is the last argument's number.
/// `args` supplies each argument as a conversion needs it, raising the
/// caller's own errors for wrong types:
///
///     integer(arg: u32) !i64        // luaL_checkinteger: %c %d %i %u %o %x %X
///     number(arg: u32) !f64         // luaL_checknumber: %a %A %e %E %f %g %G
///     string(arg: u32) ![]const u8  // luaL_tolstring: %s
///     pointer(arg: u32) ?usize      // lua_topointer: %p, null for non-objects
///     literal(arg: u32) !Literal    // %q, or "value has no literal form"
///
/// The engine's own errors are `error.FormatError`, described in `diag`.
pub fn format(w: *Writer, fmt: []const u8, top: u32, args: anytype, diag: *Diagnostic) !void {
    var arg: u32 = 1;
    var i: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] != '%') {
            const j = std.mem.findScalarPos(u8, fmt, i, '%') orelse fmt.len;
            try w.writeAll(fmt[i..j]);
            i = j;
            continue;
        }
        i += 1;
        if (i < fmt.len and fmt[i] == '%') {
            try w.writeByte('%');
            i += 1;
            continue;
        }
        arg += 1;
        if (arg > top) return diag.fail(arg, "no value", .{});
        // The specification spans flags, digits, and '.', then the conversion.
        var n: usize = 0;
        while (i + n < fmt.len and std.mem.findScalar(u8, flags_float ++ "123456789.", fmt[i + n]) != null) n += 1;
        if (n + 1 >= max_spec) return diag.fail(0, "invalid format (too long)", .{});
        const conv: u8 = if (i + n < fmt.len) fmt[i + n] else 0;
        const form = fmt[i - 1 .. @min(i + n + 1, fmt.len)];
        i += n + 1;
        switch (conv) {
            'c' => {
                const spec = try check(form, flags_char, false, diag);
                const c: u8 = @truncate(@as(u64, @bitCast(try args.integer(arg))));
                try pad(w, spec, "", &.{c}, false);
            },
            'd', 'i', 'u', 'o', 'x', 'X' => {
                const v = try args.integer(arg);
                const flags = switch (conv) {
                    'd', 'i' => flags_int,
                    'u' => flags_unsigned,
                    else => flags_hex,
                };
                try formatInt(w, try check(form, flags, true, diag), v);
            },
            'a', 'A' => {
                const spec = try check(form, flags_float, true, diag);
                try formatFloat(w, spec, try args.number(arg));
            },
            'e', 'E', 'f', 'g', 'G' => {
                const v = try args.number(arg);
                try formatFloat(w, try check(form, flags_float, true, diag), v);
            },
            'p' => {
                const p = args.pointer(arg);
                var spec = try check(form, flags_char, false, diag);
                if (p) |addr| {
                    var buf: [16]u8 = undefined;
                    try pad(w, spec, "0x", digitsOf(&buf, addr, 16, false), false);
                } else {
                    spec.conversion = 's';
                    try formatString(w, spec, "(null)");
                }
            },
            'q' => {
                if (form.len > 2) return diag.fail(0, "specifier '%q' cannot have modifiers", .{});
                switch (try args.literal(arg)) {
                    .string => |s| try quoteString(w, s),
                    .integer => |v| try quoteInteger(w, v),
                    .float => |v| try quoteFloat(w, v),
                    .text => |s| try w.writeAll(s),
                }
            },
            's' => {
                const s = try args.string(arg);
                if (form.len == 2) {
                    try w.writeAll(s);
                } else {
                    if (std.mem.findScalar(u8, s, 0) != null) return diag.fail(arg, "string contains zeros", .{});
                    const spec = try check(form, flags_char, true, diag);
                    // Without a precision, a long string is kept whole.
                    if (spec.precision == null and s.len >= 100) {
                        try w.writeAll(s);
                    } else try formatString(w, spec, s);
                }
            },
            else => return diag.fail(0, "invalid conversion '{s}' to 'format'", .{untilZero(form)}),
        }
    }
}

/// The text the reference's C string would show: up to the first zero byte.
fn untilZero(s: []const u8) []const u8 {
    return s[0 .. std.mem.findScalar(u8, s, 0) orelse s.len];
}

/// Validate a specification against the conversion's flags and whether it
/// takes a precision (`checkformat`), and decode it. `form` runs from '%'
/// through the conversion.
fn check(form: []const u8, flags: []const u8, precision: bool, diag: *Diagnostic) Error!Spec {
    var spec: Spec = .{ .conversion = form[form.len - 1] };
    var i: usize = 1;
    while (std.mem.findScalar(u8, flags, form[i]) != null) : (i += 1) {
        switch (form[i]) {
            '-' => spec.minus = true,
            '+' => spec.plus = true,
            ' ' => spec.space = true,
            '#' => spec.hash = true,
            '0' => spec.zero = true,
            else => unreachable,
        }
    }
    if (form[i] != '0') { // a width cannot start with '0'
        spec.width = twoDigits(form, &i);
        if (form[i] == '.' and precision) {
            i += 1;
            spec.precision = twoDigits(form, &i);
        }
    }
    if (!std.ascii.isAlphabetic(form[i]))
        return diag.fail(0, "invalid conversion specification: '{s}'", .{untilZero(form)});
    return spec;
}

fn twoDigits(form: []const u8, i: *usize) u8 {
    var v: u8 = 0;
    var n: usize = 0;
    while (n < 2 and std.ascii.isDigit(form[i.*])) : (n += 1) {
        v = v * 10 + (form[i.*] - '0');
        i.* += 1;
    }
    return v;
}

/// Write `prefix` (a sign or "0x") and `body` padded to the width: on the
/// right for '-', with zeros between them for '0' when `zeros` allows it, and
/// with spaces on the left otherwise.
fn pad(w: *Writer, spec: Spec, prefix: []const u8, body: []const u8, zeros: bool) Writer.Error!void {
    const len = prefix.len + body.len;
    const fill = if (spec.width > len) spec.width - len else 0;
    if (spec.minus) {
        try w.writeAll(prefix);
        try w.writeAll(body);
        try w.splatByteAll(' ', fill);
    } else if (spec.zero and zeros) {
        try w.writeAll(prefix);
        try w.splatByteAll('0', fill);
        try w.writeAll(body);
    } else {
        try w.splatByteAll(' ', fill);
        try w.writeAll(prefix);
        try w.writeAll(body);
    }
}

/// The digits of `v` in `base`, at the end of `buf`.
fn digitsOf(buf: []u8, v: u64, base: u8, upper: bool) []const u8 {
    const chars = if (upper) "0123456789ABCDEF" else "0123456789abcdef";
    var i = buf.len;
    var x = v;
    while (true) {
        i -= 1;
        buf[i] = chars[@intCast(x % base)];
        x /= base;
        if (x == 0) break;
    }
    return buf[i..];
}

/// `%s` with a width or precision: the precision limits the bytes written.
pub fn formatString(w: *Writer, spec: Spec, s: []const u8) Writer.Error!void {
    const len = if (spec.precision) |p| @min(p, s.len) else s.len;
    try pad(w, spec, "", s[0..len], false);
}

/// `%d %i %u %o %x %X` of a Lua integer; `%u %o %x %X` read it as unsigned.
pub fn formatInt(w: *Writer, spec: Spec, v: i64) Writer.Error!void {
    std.debug.assert(spec.width <= 99);
    std.debug.assert((spec.precision orelse 0) <= 99);
    const signed = spec.conversion == 'd' or spec.conversion == 'i';
    const mag: u64 = if (signed) @abs(v) else @bitCast(v);
    const base: u8 = switch (spec.conversion) {
        'o' => 8,
        'x', 'X' => 16,
        else => 10,
    };
    var dbuf: [24]u8 = undefined;
    // A zero precision prints no digits for zero.
    const digits = if (spec.precision == 0 and mag == 0) "" else digitsOf(&dbuf, mag, base, spec.conversion == 'X');
    var zeros = if (spec.precision) |p| p -| digits.len else 0;
    if (spec.hash and base == 8 and zeros == 0 and (digits.len == 0 or digits[0] != '0')) zeros = 1;
    const prefix: []const u8 = if (signed)
        (if (v < 0) "-" else if (spec.plus) "+" else if (spec.space) " " else "")
    else if (spec.hash and base == 16 and mag != 0)
        (if (spec.conversion == 'X') "0X" else "0x")
    else
        "";
    var body: [128]u8 = undefined;
    @memset(body[0..zeros], '0');
    @memcpy(body[zeros..][0..digits.len], digits);
    try pad(w, spec, prefix, body[0 .. zeros + digits.len], spec.precision == null);
}

/// `%a %A %e %E %f %g %G` of a float.
pub fn formatFloat(w: *Writer, spec: Spec, v: f64) Writer.Error!void {
    std.debug.assert(spec.width <= 99);
    std.debug.assert((spec.precision orelse 0) <= 99);
    const upper = std.ascii.isUpper(spec.conversion);
    const sign: []const u8 = if (std.math.signbit(v)) "-" else if (spec.plus) "+" else if (spec.space) " " else "";
    if (!std.math.isFinite(v)) {
        const body = if (std.math.isNan(v))
            (if (upper) "NAN" else "nan")
        else
            (if (upper) "INF" else "inf");
        return pad(w, spec, sign, body, false);
    }
    const x = @abs(v);
    // Room for the longest '%.99f': 309 integer digits, '.', 99 decimals.
    var buf: [440]u8 = undefined;
    var out: Writer = .fixed(&buf);
    switch (spec.conversion) {
        'a', 'A' => {
            hexFloat(&out, spec, x) catch unreachable;
            var prefix: [3]u8 = undefined;
            @memcpy(prefix[0..sign.len], sign);
            @memcpy(prefix[sign.len..][0..2], if (upper) "0X" else "0x");
            return pad(w, spec, prefix[0 .. sign.len + 2], out.buffered(), true);
        },
        'f' => {
            const p = spec.precision orelse 6;
            var d: Digits = .{};
            d.fixed(x, p);
            d.writeFixed(&out, @intCast(p), spec.hash) catch unreachable;
        },
        'e', 'E' => {
            const p = spec.precision orelse 6;
            var d: Digits = .{};
            d.scientific(x, @as(u32, p) + 1);
            d.writeScientific(&out, @as(u32, p) + 1, spec.hash, upper) catch unreachable;
        },
        'g', 'G' => {
            // P significant digits; fixed notation when the exponent X
            // satisfies P > X >= -4, then trailing zeros go unless '#'.
            const p: i32 = if (spec.precision) |p| @max(p, 1) else 6;
            var d: Digits = .{};
            d.scientific(x, @intCast(p));
            const exp = d.point - 1;
            if (spec.hash and d.carried and exp == p) {
                // glibc picks the notation before rounding: when rounding
                // carries a fixed-notation value to 10^P, it switches to
                // scientific notation keeping the fixed one's zero decimals.
                d.writeScientific(&out, 1, true, upper) catch unreachable;
            } else if (exp < p and exp >= -4) {
                var decimals = p - 1 - exp;
                if (!spec.hash) {
                    while (decimals > 0 and d.buf[@intCast(d.point + decimals - 1)] == '0') decimals -= 1;
                }
                d.writeFixed(&out, @intCast(decimals), spec.hash) catch unreachable;
            } else {
                var n: u32 = @intCast(p);
                if (!spec.hash) {
                    while (n > 1 and d.buf[n - 1] == '0') n -= 1;
                }
                d.writeScientific(&out, n, spec.hash, upper) catch unreachable;
            }
        },
        else => unreachable,
    }
    try pad(w, spec, sign, out.buffered(), true);
}

/// glibc's `%a` of a nonnegative finite float, without the "0x": a leading
/// digit (1, or 0 for zero and subnormals), the fraction in hexadecimal, and
/// the binary exponent. A precision rounds half to even and may carry the
/// leading digit to 2.
fn hexFloat(w: *Writer, spec: Spec, x: f64) Writer.Error!void {
    const bits: u64 = @bitCast(x);
    const biased: i32 = @intCast(bits >> 52);
    const frac = bits & ((1 << 52) - 1);
    var lead: u64 = if (biased == 0) 0 else 1;
    const exp: i32 = if (biased == 0) (if (frac == 0) 0 else -1022) else biased - 1023;
    var nibbles: u32 = 13;
    var f = frac;
    if (spec.precision) |p| {
        if (p < 13) {
            const shift: u6 = @intCast((13 - @as(u32, p)) * 4);
            const v = (lead << 52) | frac;
            var q = v >> shift;
            const rem = v & ((@as(u64, 1) << shift) - 1);
            const half = @as(u64, 1) << (shift - 1);
            if (rem > half or (rem == half and q & 1 == 1)) q += 1;
            nibbles = p;
            lead = q >> @intCast(p * 4);
            f = q & ((@as(u64, 1) << @intCast(p * 4)) - 1);
        }
    } else {
        // Without a precision, as many digits as the value needs.
        if (f == 0) nibbles = 0 else while (f & 0xf == 0) {
            f >>= 4;
            nibbles -= 1;
        }
        f = frac >> @intCast((13 - nibbles) * 4);
    }
    const upper = spec.conversion == 'A';
    const chars = if (upper) "0123456789ABCDEF" else "0123456789abcdef";
    try w.writeByte(chars[@intCast(lead)]);
    const extra: u32 = if (spec.precision) |p| p -| 13 else 0;
    if (nibbles + extra > 0 or spec.hash) try w.writeByte('.');
    var i = nibbles;
    while (i > 0) {
        i -= 1;
        try w.writeByte(chars[@intCast((f >> @intCast(i * 4)) & 0xf)]);
    }
    try w.splatByteAll('0', extra);
    try w.print("{c}{c}{d}", .{ @as(u8, if (upper) 'P' else 'p'), @as(u8, if (exp < 0) '-' else '+'), @abs(exp) });
}

/// `%q` of a string: a Lua string literal that reads back as the same bytes.
pub fn quoteString(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeByte('"');
    for (s, 0..) |c, i| {
        switch (c) {
            '"', '\\', '\n' => {
                try w.writeByte('\\');
                try w.writeByte(c);
            },
            0...9, 11...31, 127 => {
                // Three digits when a digit follows, so it does not join the escape.
                const next_digit = i + 1 < s.len and std.ascii.isDigit(s[i + 1]);
                if (next_digit) try w.print("\\{d:0>3}", .{c}) else try w.print("\\{d}", .{c});
            },
            else => try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

/// `%q` of an integer: decimal, except `math.mininteger`, whose decimal
/// numeral would read back as a float.
pub fn quoteInteger(w: *Writer, v: i64) Writer.Error!void {
    if (v == std.math.minInt(i64)) return w.writeAll("0x8000000000000000");
    try w.print("{d}", .{v});
}

/// `%q` of a float: hexadecimal, to keep every bit, with fixed numerals for
/// infinities and NaN.
pub fn quoteFloat(w: *Writer, v: f64) Writer.Error!void {
    if (std.math.isNan(v)) return w.writeAll("(0/0)");
    if (std.math.isInf(v)) return w.writeAll(if (v > 0) "1e9999" else "-1e9999");
    try formatFloat(w, .{ .conversion = 'a' }, v);
}

/// The exact decimal digits of a nonnegative finite float, rounded half to
/// even at a requested place. The value is `0.d1d2d3... * 10^point`.
const Digits = struct {
    /// Room for 309 integer digits and 99 decimals, or a digit to round on.
    buf: [420]u8 = undefined,
    len: u32 = 0,
    point: i32 = 0,
    /// Whether rounding carried out of the first digit, as in 9.99 to 10.0.
    carried: bool = false,

    /// Digits through the `decimals`-th place after the point (`%f`).
    fn fixed(d: *Digits, x: f64, decimals: u32) void {
        var g: Expansion = .init(x);
        d.len = g.intDigits(&d.buf);
        d.point = @intCast(d.len);
        for (0..decimals) |_| d.push(g.nextFraction());
        d.round(g.nextFraction(), !g.fractionIsZero());
    }

    /// The first `n` significant digits (`%e` with precision n - 1).
    fn scientific(d: *Digits, x: f64, n: u32) void {
        if (x == 0) {
            @memset(d.buf[0..n], '0');
            d.len = n;
            d.point = 1;
            return;
        }
        var g: Expansion = .init(x);
        d.len = g.intDigits(&d.buf);
        d.point = @intCast(d.len);
        if (d.len == 0) { // skip the zeros after the point
            var c = g.nextFraction();
            while (c == 0) : (c = g.nextFraction()) d.point -= 1;
            d.push(c);
        }
        if (d.len > n) {
            const sticky = std.mem.findNone(u8, d.buf[n + 1 .. d.len], "0") != null or !g.fractionIsZero();
            const r = d.buf[n] - '0';
            d.len = n;
            d.round(r, sticky);
        } else {
            while (d.len < n) d.push(g.nextFraction());
            d.round(g.nextFraction(), !g.fractionIsZero());
        }
        if (d.len > n) d.len = n; // a carry added a digit, and it is a zero
    }

    fn push(d: *Digits, c: u8) void {
        d.buf[d.len] = '0' + c;
        d.len += 1;
    }

    /// Round the kept digits given the next digit and whether anything nonzero
    /// follows it: half to even, as glibc does in the default rounding mode.
    fn round(d: *Digits, next: u8, sticky: bool) void {
        const odd = d.len > 0 and (d.buf[d.len - 1] - '0') & 1 == 1;
        if (next < 5 or (next == 5 and !sticky and !odd)) return;
        var i = d.len;
        while (i > 0) {
            i -= 1;
            if (d.buf[i] != '9') {
                d.buf[i] += 1;
                return;
            }
            d.buf[i] = '0';
        }
        // All nines: the carry adds a leading 1.
        @memmove(d.buf[1 .. d.len + 1], d.buf[0..d.len]);
        d.buf[0] = '1';
        d.len += 1;
        d.point += 1;
        d.carried = true;
    }

    /// Fixed notation with `decimals` digits after the point; the digits past
    /// `len` are zeros.
    fn writeFixed(d: *const Digits, w: *Writer, decimals: u32, hash: bool) Writer.Error!void {
        const digits = d.buf[0..d.len];
        if (d.point > 0) {
            const ip: usize = @intCast(d.point);
            try w.writeAll(digits[0..@min(ip, digits.len)]);
            if (ip > digits.len) try w.splatByteAll('0', ip - digits.len);
        } else try w.writeByte('0');
        if (decimals > 0 or hash) try w.writeByte('.');
        var written: u32 = 0;
        if (d.point < 0) {
            const z = @min(decimals, @as(u32, @intCast(-d.point)));
            try w.splatByteAll('0', z);
            written = z;
        }
        const start: usize = @intCast(@max(d.point, 0));
        if (start < digits.len) {
            const frac = digits[start..][0..@min(digits.len - start, decimals - written)];
            try w.writeAll(frac);
            written += @intCast(frac.len);
        }
        try w.splatByteAll('0', decimals - written);
    }

    /// Scientific notation with `n` significant digits.
    fn writeScientific(d: *const Digits, w: *Writer, n: u32, hash: bool, upper: bool) Writer.Error!void {
        try w.writeByte(d.buf[0]);
        if (n > 1 or hash) try w.writeByte('.');
        try w.writeAll(d.buf[1..n]);
        const exp = d.point - 1;
        try w.writeByte(if (upper) 'E' else 'e');
        try w.writeByte(if (exp < 0) '-' else '+');
        if (@abs(exp) < 10) try w.writeByte('0');
        try w.print("{d}", .{@abs(exp)});
    }
};

/// A float split into its integer part and its fraction over a power of two,
/// for producing its decimal digits exactly.
const Expansion = struct {
    int: Big,
    frac: Big,
    /// The fraction is `frac / 2^k`.
    k: u32,

    fn init(x: f64) Expansion {
        const bits: u64 = @bitCast(x);
        const biased: u32 = @intCast(bits >> 52);
        const low = bits & ((1 << 52) - 1);
        const m: u64 = if (biased == 0) low else low | (1 << 52);
        const e: i32 = if (biased == 0) -1074 else @as(i32, @intCast(biased)) - 1075;
        if (e >= 0) return .{ .int = .initShifted(m, @intCast(e)), .frac = .{}, .k = 0 };
        const k: u32 = @intCast(-e);
        if (k >= 64) return .{ .int = .{}, .frac = .initShifted(m, 0), .k = k };
        return .{
            .int = .initShifted(m >> @intCast(k), 0),
            .frac = .initShifted(m & ((@as(u64, 1) << @intCast(k)) - 1), 0),
            .k = k,
        };
    }

    /// Write the integer part's decimal digits, most significant first, and
    /// return how many; none for zero.
    fn intDigits(g: *Expansion, out: []u8) u32 {
        var chunks: [40]u32 = undefined;
        var n: usize = 0;
        while (!g.int.isZero()) : (n += 1) chunks[n] = g.int.divSmall(1_000_000_000);
        if (n == 0) return 0;
        var w: Writer = .fixed(out);
        w.print("{d}", .{chunks[n - 1]}) catch unreachable;
        var i = n - 1;
        while (i > 0) {
            i -= 1;
            w.print("{d:0>9}", .{chunks[i]}) catch unreachable;
        }
        return @intCast(w.end);
    }

    /// The next decimal digit of the fraction.
    fn nextFraction(g: *Expansion) u8 {
        if (g.frac.isZero()) return 0;
        g.frac.mulSmall(10);
        return g.frac.takeAbove(g.k);
    }

    fn fractionIsZero(g: *const Expansion) bool {
        return g.frac.isZero();
    }
};

/// A nonnegative integer of up to 1152 bits, enough for a double's integer
/// part (1024 bits) and its fraction's numerator times ten (1078 bits).
const Big = struct {
    limbs: [36]u32 = undefined,
    /// Limbs in use; the top one is not zero.
    len: u32 = 0,

    fn initShifted(m: u64, shift: u32) Big {
        var b: Big = .{};
        if (m == 0) return b;
        const q = shift / 32;
        const r: u6 = @intCast(shift % 32);
        @memset(b.limbs[0..q], 0);
        const wide = @as(u128, m) << r;
        var i: u32 = 0;
        while (i < 4) : (i += 1) b.limbs[q + i] = @truncate(wide >> @intCast(32 * i));
        b.len = q + 4;
        b.normalize();
        return b;
    }

    fn isZero(b: *const Big) bool {
        return b.len == 0;
    }

    fn normalize(b: *Big) void {
        while (b.len > 0 and b.limbs[b.len - 1] == 0) b.len -= 1;
    }

    fn mulSmall(b: *Big, m: u32) void {
        var carry: u64 = 0;
        for (b.limbs[0..b.len]) |*l| {
            const t = @as(u64, l.*) * m + carry;
            l.* = @truncate(t);
            carry = t >> 32;
        }
        if (carry != 0) {
            b.limbs[b.len] = @intCast(carry);
            b.len += 1;
        }
    }

    /// Divide in place and return the remainder.
    fn divSmall(b: *Big, d: u32) u32 {
        var rem: u64 = 0;
        var i = b.len;
        while (i > 0) {
            i -= 1;
            const t = (rem << 32) | b.limbs[i];
            b.limbs[i] = @intCast(t / d);
            rem = t % d;
        }
        b.normalize();
        return @intCast(rem);
    }

    /// Remove and return the bits at and above bit `k`, which hold a decimal
    /// digit.
    fn takeAbove(b: *Big, k: u32) u8 {
        const q = k / 32;
        const r: u5 = @intCast(k % 32);
        if (q >= b.len) return 0;
        var v: u64 = b.limbs[q];
        if (q + 1 < b.len) v |= @as(u64, b.limbs[q + 1]) << 32;
        const digit: u8 = @intCast((v >> r) & 0xf);
        b.limbs[q] &= (@as(u32, 1) << r) -% 1;
        if (r == 0) b.limbs[q] = 0;
        b.len = q + 1;
        b.normalize();
        return digit;
    }
};

// Expected outputs below come from reference Lua 5.5.1 (`lua` in the dev
// shell), including the format cases in test/lua-5.5.1-tests/strings.lua.

/// An argument as a test supplies it; `args` stands in for the glue's checks.
const TestArg = union(enum) {
    integer: i64,
    float: f64,
    string: []const u8,
    boolean: bool,
    nil,
    table,
};

const TestArgs = struct {
    list: []const TestArg,

    fn get(a: TestArgs, arg: u32) TestArg {
        return a.list[arg - 2];
    }

    pub fn integer(a: TestArgs, arg: u32) !i64 {
        return switch (a.get(arg)) {
            .integer => |v| v,
            .float => |v| if (@trunc(v) == v) @intFromFloat(v) else error.TestArgument,
            else => error.TestArgument,
        };
    }

    pub fn number(a: TestArgs, arg: u32) !f64 {
        return switch (a.get(arg)) {
            .integer => |v| @floatFromInt(v),
            .float => |v| v,
            else => error.TestArgument,
        };
    }

    pub fn string(a: TestArgs, arg: u32) ![]const u8 {
        return switch (a.get(arg)) {
            .string => |s| s,
            else => error.TestArgument,
        };
    }

    pub fn pointer(a: TestArgs, arg: u32) ?usize {
        return if (a.get(arg) == .table) 0x1234 else null;
    }

    pub fn literal(a: TestArgs, arg: u32) !Literal {
        return switch (a.get(arg)) {
            .integer => |v| .{ .integer = v },
            .float => |v| .{ .float = v },
            .string => |s| .{ .string = s },
            .boolean => |b| .{ .text = if (b) "true" else "false" },
            .nil => .{ .text = "nil" },
            .table => error.NoLiteral,
        };
    }
};

/// `string.format`'s result, or "error: " and the message Lua would raise.
fn formatText(fmt: []const u8, list: []const TestArg) ![]u8 {
    var out: Writer.Allocating = .init(testing.allocator);
    errdefer out.deinit();
    var diag: Diagnostic = .{};
    const top: u32 = @intCast(list.len + 1);
    format(&out.writer, fmt, top, TestArgs{ .list = list }, &diag) catch |err| {
        out.clearRetainingCapacity();
        const w = &out.writer;
        switch (err) {
            error.FormatError => if (diag.arg != 0)
                try w.print("error: bad argument #{d} to 'string.format' ({s})", .{ diag.arg, diag.message() })
            else
                try w.print("error: {s}", .{diag.message()}),
            error.NoLiteral => try w.writeAll("error: bad argument #2 to 'string.format' (value has no literal form)"),
            else => |e| return e,
        }
    };
    return out.toOwnedSlice();
}

test "format matches the reference" {
    const cases = [_]struct { fmt: []const u8, args: []const TestArg, want: []const u8 }{
        .{ .fmt = "%d", .args = &.{.{ .integer = 0 }}, .want = "0" },
        .{ .fmt = "%5d|%-5d|", .args = &.{ .{ .integer = 42 }, .{ .integer = 42 } }, .want = "   42|42   |" },
        .{ .fmt = "%+08d", .args = &.{.{ .integer = 31501 }}, .want = "+0031501" },
        .{ .fmt = "%+08d", .args = &.{.{ .integer = -30927 }}, .want = "-0030927" },
        .{ .fmt = "%013i", .args = &.{.{ .integer = -100 }}, .want = "-000000000100" },
        .{ .fmt = "%2.5d", .args = &.{.{ .integer = -100 }}, .want = "-00100" },
        .{ .fmt = "%.u", .args = &.{.{ .integer = 0 }}, .want = "" },
        .{ .fmt = "%.0d", .args = &.{.{ .integer = 0 }}, .want = "" },
        .{ .fmt = "%+.0d", .args = &.{.{ .integer = 0 }}, .want = "+" },
        .{ .fmt = "% d", .args = &.{.{ .integer = 5 }}, .want = " 5" },
        .{ .fmt = "%d", .args = &.{.{ .integer = std.math.minInt(i64) }}, .want = "-9223372036854775808" },
        .{ .fmt = "%d", .args = &.{.{ .integer = 9223372036854775807 }}, .want = "9223372036854775807" },
        .{ .fmt = "%u", .args = &.{.{ .integer = -1 }}, .want = "18446744073709551615" },
        .{ .fmt = "%x", .args = &.{.{ .integer = -1 }}, .want = "ffffffffffffffff" },
        .{ .fmt = "%X", .args = &.{.{ .integer = 11259375 }}, .want = "ABCDEF" },
        .{ .fmt = "%o", .args = &.{.{ .integer = 43981 }}, .want = "125715" },
        .{ .fmt = "%#12o", .args = &.{.{ .integer = 10 }}, .want = "         012" },
        .{ .fmt = "%#10x", .args = &.{.{ .integer = 100 }}, .want = "      0x64" },
        .{ .fmt = "%#-17X", .args = &.{.{ .integer = 100 }}, .want = "0X64             " },
        .{ .fmt = "%#x", .args = &.{.{ .integer = 0 }}, .want = "0" },
        .{ .fmt = "%#.0o", .args = &.{.{ .integer = 0 }}, .want = "0" },
        .{ .fmt = "%#o", .args = &.{.{ .integer = 8 }}, .want = "010" },
        .{ .fmt = "%010.3d", .args = &.{.{ .integer = 5 }}, .want = "       005" },
        .{ .fmt = "%#08x", .args = &.{.{ .integer = 255 }}, .want = "0x0000ff" },
        .{ .fmt = "%x", .args = &.{.{ .float = 0 }}, .want = "0" },
        .{ .fmt = "%-16c", .args = &.{.{ .integer = 97 }}, .want = "a               " },
        .{ .fmt = "%5c|%c", .args = &.{ .{ .integer = 65 }, .{ .integer = 0 } }, .want = "    A|\x00" },
        .{ .fmt = "%c", .args = &.{.{ .integer = 321 }}, .want = "A" },
        .{ .fmt = "%f", .args = &.{.{ .float = 10.300000000000001 }}, .want = "10.300000" },
        .{
            .fmt = "%.0f %.0f %.0f %.1f %.2f",
            .args = &.{
                .{ .float = 0.5 },
                .{ .float = 1.5 },
                .{ .float = 2.5 },
                .{ .float = 0.25 },
                .{ .float = 0.125 },
            },
            .want = "0 2 2 0.2 0.12",
        },
        .{ .fmt = "%.20f", .args = &.{.{ .float = 0.10000000000000001 }}, .want = "0.10000000000000000555" },
        .{ .fmt = "%+#014.0f", .args = &.{.{ .integer = 100 }}, .want = "+000000000100." },
        .{
            .fmt = "%05f|%-6f|%+f|% f",
            .args = &.{
                .{ .float = std.math.inf(f64) },
                .{ .float = -std.math.inf(f64) },
                .{ .float = -std.math.nan(f64) },
                .{ .float = std.math.nan(f64) },
            },
            .want = "  inf|-inf  |-nan| nan",
        },
        .{ .fmt = "%e", .args = &.{.{ .float = 0 }}, .want = "0.000000e+00" },
        .{ .fmt = "%#.0e", .args = &.{.{ .float = 12345 }}, .want = "1.e+04" },
        .{ .fmt = "%E", .args = &.{.{ .float = 1e-300 }}, .want = "1.000000E-300" },
        .{ .fmt = "%e", .args = &.{.{ .float = 4.9406564584124654e-324 }}, .want = "4.940656e-324" },
        .{ .fmt = "% 1.0E", .args = &.{.{ .integer = 100 }}, .want = " 1E+02" },
        .{ .fmt = "%.3e", .args = &.{.{ .float = 9.9994999999999994 }}, .want = "9.999e+00" },
        .{ .fmt = "%.0f", .args = &.{.{ .float = 1e+22 }}, .want = "10000000000000000000000" },
        .{
            .fmt = "%g %g %g %g %g",
            .args = &.{
                .{ .float = 1e+100 },
                .{ .integer = 100000 },
                .{ .float = 1000000 },
                .{ .float = 0.0001 },
                .{ .float = 1.0000000000000001e-05 },
            },
            .want = "1e+100 100000 1e+06 0.0001 1e-05",
        },
        .{
            .fmt = "%.3g %#g %#.3g %g",
            .args = &.{
                .{ .float = 0.00012339999999999999 },
                .{ .float = 1 },
                .{ .integer = 1 },
                .{ .float = 0 },
            },
            .want = "0.000123 1.00000 1.00 0",
        },
        .{ .fmt = "%+.3G", .args = &.{.{ .float = 1.5 }}, .want = "+1.5" },
        .{ .fmt = "% .1g", .args = &.{.{ .float = 1024 }}, .want = " 1e+03" },
        .{ .fmt = "%.14g", .args = &.{.{ .float = 0.10000000000000001 }}, .want = "0.1" },
        .{ .fmt = "%.17g", .args = &.{.{ .float = 0.10000000000000001 }}, .want = "0.10000000000000001" },
        .{ .fmt = "%#g", .args = &.{.{ .float = 999999.5 }}, .want = "1.e+06" },
        .{ .fmt = "%#.2g", .args = &.{.{ .float = 99.950000000000003 }}, .want = "1.e+02" },
        .{ .fmt = "%#.3g", .args = &.{.{ .float = 9.9994999999999994e-05 }}, .want = "0.000100" },
        .{ .fmt = "%-12g|", .args = &.{.{ .float = -0.0 }}, .want = "-0          |" },
        .{
            .fmt = "%a %a %a",
            .args = &.{
                .{ .float = 1 },
                .{ .float = 0.5 },
                .{ .float = 0.10000000000000001 },
            },
            .want = "0x1p+0 0x1p-1 0x1.999999999999ap-4",
        },
        .{ .fmt = "%A", .args = &.{.{ .float = 0.10000000000000001 }}, .want = "0X1.999999999999AP-4" },
        .{
            .fmt = "%a %a",
            .args = &.{
                .{ .float = 4.9406564584124654e-324 },
                .{ .float = 2.2250738585072014e-308 },
            },
            .want = "0x0.0000000000001p-1022 0x1p-1022",
        },
        .{ .fmt = "%a %A", .args = &.{ .{ .float = -0.0 }, .{ .float = 0 } }, .want = "-0x0p+0 0X0P+0" },
        .{
            .fmt = "%.0a %.0a %.0a",
            .args = &.{
                .{ .float = 1.5 },
                .{ .float = 2.5 },
                .{ .float = 3.5 },
            },
            .want = "0x2p+0 0x1p+1 0x2p+1",
        },
        .{
            .fmt = "%.1a %.1a",
            .args = &.{
                .{ .float = 1.09375 },
                .{ .float = 1.03125 },
            },
            .want = "0x1.2p+0 0x1.0p+0",
        },
        .{ .fmt = "%.3a", .args = &.{.{ .float = 0.33333333333333331 }}, .want = "0x1.555p-2" },
        .{ .fmt = "%#a", .args = &.{.{ .float = 1 }}, .want = "0x1.p+0" },
        .{
            .fmt = "%010a|%-12a|%+a|% a",
            .args = &.{
                .{ .integer = 1 },
                .{ .integer = 1 },
                .{ .integer = 1 },
                .{ .integer = 1 },
            },
            .want = "0x00001p+0|0x1p+0      |+0x1p+0| 0x1p+0",
        },
        .{ .fmt = "%.20a", .args = &.{.{ .float = 1 }}, .want = "0x1.00000000000000000000p+0" },
        .{ .fmt = "%+.2A", .args = &.{.{ .integer = 12 }}, .want = "+0X1.80P+3" },
        .{ .fmt = "%.4A", .args = &.{.{ .integer = -12 }}, .want = "-0X1.8000P+3" },
        .{ .fmt = "%a", .args = &.{.{ .float = -std.math.inf(f64) }}, .want = "-inf" },
        .{ .fmt = "%s", .args = &.{.{ .string = "a\x00b" }}, .want = "a\x00b" },
        .{ .fmt = "%5.2s|%-5s|", .args = &.{ .{ .string = "abc" }, .{ .string = "x" } }, .want = "   ab|x    |" },
        .{ .fmt = "%.0s|%.s|", .args = &.{ .{ .string = "alo" }, .{ .string = "alo" } }, .want = "||" },
        .{
            .fmt = "%-50s|",
            .args = &.{
                .{ .string = "a" },
            },
            .want = "a                                                 |",
        },
        .{
            .fmt = "%.20s",
            .args = &.{
                .{ .string = "%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%" },
            },
            .want = "%%%%%%%%%%%%%%%%%%%%",
        },
        .{ .fmt = "%20s", .args = &.{.{ .string = &@as([120]u8, @splat('y')) }}, .want = &@as([120]u8, @splat('y')) },
        .{ .fmt = "%5p|%-7p|%p", .args = &.{ .nil, .{ .boolean = false }, .table }, .want = "(null)|(null) |0x1234" },
        .{ .fmt = "%%%d", .args = &.{.{ .integer = 10 }}, .want = "%10" },
        .{
            .fmt = "\x00%c\x00%s",
            .args = &.{
                .{ .integer = 66 },
                .{ .string = "\x00\x01" },
            },
            .want = "\x00B\x00\x00\x01",
        },
        .{ .fmt = "%q", .args = &.{.{ .string = "\x22\x0a\x5c" }}, .want = "\x22\x5c\x22\x5c\x0a\x5c\x5c\x22" },
        .{ .fmt = "%q", .args = &.{.{ .string = "\x00" }}, .want = "\x22\x5c0\x22" },
        .{
            .fmt = "%q",
            .args = &.{
                .{ .string = "\x001\x0d9\xc8\x7f\x09" },
            },
            .want = "\x22\x5c0001\x5c0139\xc8\x5c127\x5c9\x22",
        },
        .{ .fmt = "%q", .args = &.{.{ .float = 1 }}, .want = "0x1p+0" },
        .{ .fmt = "%q", .args = &.{.{ .float = 1e+100 }}, .want = "0x1.249ad2594c37dp+332" },
        .{ .fmt = "%q", .args = &.{.{ .float = -0.0 }}, .want = "-0x0p+0" },
        .{ .fmt = "%q", .args = &.{.{ .integer = std.math.minInt(i64) }}, .want = "0x8000000000000000" },
        .{ .fmt = "%q", .args = &.{.{ .integer = 9223372036854775807 }}, .want = "9223372036854775807" },
        .{ .fmt = "%q", .args = &.{.{ .float = 9.2233720368547758e+18 }}, .want = "0x1p+63" },
        .{ .fmt = "%q", .args = &.{.{ .float = 0.10000000000000001 }}, .want = "0x1.999999999999ap-4" },
        .{ .fmt = "%q", .args = &.{.{ .float = std.math.inf(f64) }}, .want = "1e9999" },
        .{ .fmt = "%q", .args = &.{.{ .float = -std.math.inf(f64) }}, .want = "-1e9999" },
        .{ .fmt = "%q", .args = &.{.{ .float = -std.math.nan(f64) }}, .want = "(0/0)" },
        .{
            .fmt = "%d %d",
            .args = &.{
                .{ .integer = 1 },
            },
            .want = "error: bad argument #3 to 'string.format' (no value)",
        },
        .{ .fmt = "%", .args = &.{.{ .integer = 1 }}, .want = "error: invalid conversion '%' to 'format'" },
        .{
            .fmt = "%100.3d",
            .args = &.{
                .{ .integer = 10 },
            },
            .want = "error: invalid conversion specification: '%100.3d'",
        },
        .{
            .fmt = "%1000000000000000000000000000000.3d",
            .args = &.{
                .{ .integer = 10 },
            },
            .want = "error: invalid format (too long)",
        },
        .{
            .fmt = "%1.100d",
            .args = &.{
                .{ .integer = 10 },
            },
            .want = "error: invalid conversion specification: '%1.100d'",
        },
        .{ .fmt = "%t", .args = &.{.{ .integer = 10 }}, .want = "error: invalid conversion '%t' to 'format'" },
        .{ .fmt = "%010c", .args = &.{.{ .integer = 10 }}, .want = "error: invalid conversion specification: '%010c'" },
        .{ .fmt = "%.10c", .args = &.{.{ .integer = 10 }}, .want = "error: invalid conversion specification: '%.10c'" },
        .{
            .fmt = "%0.34s",
            .args = &.{
                .{ .string = "a" },
            },
            .want = "error: invalid conversion specification: '%0.34s'",
        },
        .{ .fmt = "%#i", .args = &.{.{ .integer = 10 }}, .want = "error: invalid conversion specification: '%#i'" },
        .{ .fmt = "%3.1p", .args = &.{.{ .integer = 10 }}, .want = "error: invalid conversion specification: '%3.1p'" },
        .{ .fmt = "%0.s", .args = &.{.{ .string = "a" }}, .want = "error: invalid conversion specification: '%0.s'" },
        .{ .fmt = "%10q", .args = &.{.{ .integer = 10 }}, .want = "error: specifier '%q' cannot have modifiers" },
        .{ .fmt = "%F", .args = &.{.{ .float = 10 }}, .want = "error: invalid conversion '%F' to 'format'" },
        .{
            .fmt = "%q %q %q",
            .args = &.{
                .nil,
                .{ .boolean = true },
                .{ .boolean = false },
            },
            .want = "nil true false",
        },
        .{
            .fmt = "%10s",
            .args = &.{
                .{ .string = "\x00" },
            },
            .want = "error: bad argument #2 to 'string.format' (string contains zeros)",
        },
        .{
            .fmt = "%q",
            .args = &.{
                .table,
            },
            .want = "error: bad argument #2 to 'string.format' (value has no literal form)",
        },
    };
    for (cases) |c| {
        const got = try formatText(c.fmt, c.args);
        defer testing.allocator.free(got);
        testing.expectEqualStrings(c.want, got) catch |err| {
            std.debug.print("format \"{s}\"\n", .{c.fmt});
            return err;
        };
    }
}

test "the longest floats print every digit" {
    // string.format('%.99f', -(10^308)), as strings.lua checks: 309 integer
    // digits, the point, and 99 decimals.
    const got = try formatText("%.99f", &.{.{ .float = -1e308 }});
    defer testing.allocator.free(got);
    try testing.expectEqual(1 + 309 + 1 + 99, got.len);
    try testing.expectEqualStrings("-1000000000000000010979063629440455417404923096773118463368106829031", got[0..68]);
    try testing.expectEqual('.', got[310]);
    try testing.expect(std.mem.allEqual(u8, got[311..], '0'));
}

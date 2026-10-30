//! The math library, the reference manual's §6.7, after lmathlib.c: integer
//! and float results as the reference gives them, and `math.random` with the
//! reference's xoshiro256** generator, seeding, and projection, so a seeded
//! sequence matches the reference bit for bit.

const std = @import("std");
const Value = @import("../Value.zig");
const Thread = @import("../Thread.zig");
const State = @import("../State.zig");
const Proto = @import("../Proto.zig");
const Userdata = @import("../Userdata.zig");
const number = @import("../number.zig");
const auxlib = @import("auxlib.zig");
const libm = @import("libm.zig");

const Error = Value.Error;
const Args = auxlib.Args;
const raise = auxlib.raise;

const pi = 3.141592653589793238462643383279502884;

/// Creates the `math` table and sets the global.
pub fn open(state: *State) Error!void {
    const lib = try auxlib.newLib(state, .{
        .{ "abs", abs },
        .{ "acos", unary("acos", acos) },
        .{ "asin", unary("asin", asin) },
        .{ "atan", atan },
        .{ "ceil", ceil },
        .{ "cos", unary("cos", std.math.cos) },
        .{ "deg", deg },
        .{ "exp", unary("exp", libm.exp) },
        .{ "tointeger", tointeger },
        .{ "floor", floor },
        .{ "fmod", fmod },
        .{ "frexp", frexp },
        .{ "ult", ult },
        .{ "ldexp", ldexp },
        .{ "log", log },
        .{ "max", max },
        .{ "min", min },
        .{ "modf", modf },
        .{ "rad", rad },
        .{ "sin", unary("sin", std.math.sin) },
        .{ "sqrt", unary("sqrt", std.math.sqrt) },
        .{ "tan", unary("tan", std.math.tan) },
        .{ "type", mathType },
    });
    try auxlib.setField(state, lib, "pi", .float(pi));
    try auxlib.setField(state, lib, "huge", .float(std.math.inf(f64)));
    try auxlib.setField(state, lib, "maxinteger", .int(std.math.maxInt(i64)));
    try auxlib.setField(state, lib, "mininteger", .int(std.math.minInt(i64)));
    // `random` and `randomseed` share their generator state, a userdata
    // upvalue.
    const ud = try Userdata.create(&state.heap, @sizeOf(Rng), 0);
    rngOf(ud).seed(makeSeed(state), 0);
    inline for (.{ .{ "random", random }, .{ "randomseed", randomseed } }) |f| {
        const cl = try Proto.NativeClosure.create(&state.heap, f[1], 1);
        cl.setUpvalue(&state.heap, 0, .userdata(ud));
        try auxlib.setField(state, lib, f[0], .nativeClosure(cl));
    }
    try auxlib.setField(state, state.globals, "math", .table(lib));
}

/// A float to integer conversion that keeps the integer subtype when the
/// value fits (`pushnumint`).
fn pushNumInt(th: *Thread, d: f64) void {
    th.push(if (number.floatToInt(d, .exact)) |i| .int(i) else .float(d));
}

fn unary(comptime name: []const u8, comptime f: anytype) Value.NativeFn {
    return struct {
        fn native(th: *Thread, base: u32) Error!u32 {
            const a: Args = .init(th, base, name);
            th.push(.float(f(@as(f64, try a.checkNumber(1)))));
            return 1;
        }
    }.native;
}

// glibc's wrappers return a positive NaN for domain errors of `asin` and
// `acos`; the functions themselves give x86's negative one.

fn asin(x: f64) f64 {
    return if (@abs(x) > 1) std.math.nan(f64) else std.math.asin(x);
}

fn acos(x: f64) f64 {
    return if (@abs(x) > 1) std.math.nan(f64) else std.math.acos(x);
}

fn abs(th: *Thread, base: u32) Error!u32 {
    const a: Args = .init(th, base, "abs");
    const v = a.get(1);
    if (v.tag == .int) {
        const n = v.payload.int;
        th.push(.int(if (n < 0) 0 -% n else n));
    } else th.push(.float(@abs(try a.checkNumber(1))));
    return 1;
}

fn atan(th: *Thread, base: u32) Error!u32 {
    const a: Args = .init(th, base, "atan");
    const y = try a.checkNumber(1);
    const x = try a.optNumber(2, 1);
    th.push(.float(std.math.atan2(y, x)));
    return 1;
}

fn tointeger(th: *Thread, base: u32) Error!u32 {
    const a: Args = .init(th, base, "tointeger");
    if (auxlib.toInteger(a.get(1))) |n| {
        th.push(.int(n));
    } else {
        try a.checkAny(1);
        th.push(.nil);
    }
    return 1;
}

fn floor(th: *Thread, base: u32) Error!u32 {
    const a: Args = .init(th, base, "floor");
    const v = a.get(1);
    if (v.tag == .int) th.push(v) else pushNumInt(th, @floor(try a.checkNumber(1)));
    return 1;
}

fn ceil(th: *Thread, base: u32) Error!u32 {
    const a: Args = .init(th, base, "ceil");
    const v = a.get(1);
    if (v.tag == .int) th.push(v) else pushNumInt(th, @ceil(try a.checkNumber(1)));
    return 1;
}

fn fmod(th: *Thread, base: u32) Error!u32 {
    const a: Args = .init(th, base, "fmod");
    const x = a.get(1);
    const y = a.get(2);
    if (x.tag == .int and y.tag == .int) {
        const d = y.payload.int;
        if (d == 0) return a.argError(2, "zero", .{});
        // -1 would overflow with minInt(i64); the remainder is 0.
        th.push(.int(if (d == -1) 0 else @rem(x.payload.int, d)));
    } else {
        // GCC evaluates the reference's two checks right to left.
        const d = try a.checkNumber(2);
        th.push(.float(cFmod(try a.checkNumber(1), d)));
    }
    return 1;
}

/// C's `fmod`. The NaN it returns for a zero divisor or an infinite
/// dividend is the one x86 arithmetic produces (`-nan`), as glibc's is.
fn cFmod(x: f64, y: f64) f64 {
    if (y == 0 or std.math.isInf(x)) return (x * y) / (x * y);
    return @rem(x, y);
}

fn modf(th: *Thread, base: u32) Error!u32 {
    const a: Args = .init(th, base, "modf");
    const v = a.get(1);
    if (v.tag == .int) {
        th.push(v);
        th.push(.float(0));
    } else {
        const n = try a.checkNumber(1);
        // The integer part rounds toward zero.
        const ip = if (n < 0) @ceil(n) else @floor(n);
        pushNumInt(th, ip);
        // The test keeps inf - inf from giving NaN.
        th.push(.float(if (n == ip) 0.0 else n - ip));
    }
    return 2;
}

fn ult(th: *Thread, base: u32) Error!u32 {
    const a: Args = .init(th, base, "ult");
    const x: u64 = @bitCast(try a.checkInteger(1));
    const y: u64 = @bitCast(try a.checkInteger(2));
    th.push(.boolean(x < y));
    return 1;
}

fn log(th: *Thread, base: u32) Error!u32 {
    const a: Args = .init(th, base, "log");
    const x = try a.checkNumber(1);
    var res: f64 = undefined;
    if (a.isNoneOrNil(2)) {
        res = libm.log(x);
    } else {
        const b = try a.checkNumber(2);
        res = if (b == 2.0) libm.log2(x) else if (b == 10.0) libm.log10(x) else libm.log(x) / libm.log(b);
    }
    th.push(.float(res));
    return 1;
}

fn deg(th: *Thread, base: u32) Error!u32 {
    const a: Args = .init(th, base, "deg");
    th.push(.float(try a.checkNumber(1) * (180.0 / pi)));
    return 1;
}

fn rad(th: *Thread, base: u32) Error!u32 {
    const a: Args = .init(th, base, "rad");
    th.push(.float(try a.checkNumber(1) * (pi / 180.0)));
    return 1;
}

fn frexp(th: *Thread, base: u32) Error!u32 {
    const a: Args = .init(th, base, "frexp");
    const x = try a.checkNumber(1);
    // C's frexp: zero, infinities, and NaN come back unchanged with
    // exponent 0.
    if (x == 0 or !std.math.isFinite(x)) {
        th.push(.float(x));
        th.push(.int(0));
    } else {
        const r = std.math.frexp(x);
        th.push(.float(r.significand));
        th.push(.int(r.exponent));
    }
    return 2;
}

fn ldexp(th: *Thread, base: u32) Error!u32 {
    const a: Args = .init(th, base, "ldexp");
    const x = try a.checkNumber(1);
    // The reference casts the exponent to a C int.
    const e: i32 = @truncate(try a.checkInteger(2));
    th.push(.float(std.math.ldexp(x, e)));
    return 1;
}

/// `math.min` and `math.max` compare with `<`, metamethods included, and
/// return the winning argument itself.
fn minMax(th: *Thread, base: u32, comptime name: []const u8, comptime is_max: bool) Error!u32 {
    const a: Args = .init(th, base, name);
    const n = a.count();
    if (n < 1) return a.argError(1, "value expected", .{});
    var best: u32 = 1;
    var i: u32 = 2;
    while (i <= n) : (i += 1) {
        const better = if (is_max)
            try auxlib.lessThan(th, a.get(best), a.get(i))
        else
            try auxlib.lessThan(th, a.get(i), a.get(best));
        if (better) best = i;
    }
    th.push(a.get(best));
    return 1;
}

fn min(th: *Thread, base: u32) Error!u32 {
    return minMax(th, base, "min", false);
}

fn max(th: *Thread, base: u32) Error!u32 {
    return minMax(th, base, "max", true);
}

fn mathType(th: *Thread, base: u32) Error!u32 {
    const a: Args = .init(th, base, "type");
    const v = a.get(1);
    switch (v.tag) {
        .int => th.push(.string(try th.state.newString("integer"))),
        .float => th.push(.string(try th.state.newString("float"))),
        else => {
            try a.checkAny(1);
            th.push(.nil);
        },
    }
    return 1;
}

// ---------------------------------------------------------------------------
// Pseudo-random numbers: xoshiro256**, as lmathlib.c implements it.
// ---------------------------------------------------------------------------

const Rng = struct {
    s: [4]u64,

    fn next(r: *Rng) u64 {
        const s0 = r.s[0];
        const s1 = r.s[1];
        const s2 = r.s[2] ^ s0;
        const s3 = r.s[3] ^ s1;
        const res = std.math.rotl(u64, s1 *% 5, 7) *% 9;
        r.s[0] = s0 ^ s3;
        r.s[1] = s1 ^ s2;
        r.s[2] = s2 ^ (s1 << 17);
        r.s[3] = std.math.rotl(u64, s3, 45);
        return res;
    }

    /// `setseed`: the state from two seeds, with the first 16 values
    /// discarded to spread the seed.
    fn seed(r: *Rng, n1: u64, n2: u64) void {
        r.s = .{ n1, 0xff, n2, 0 };
        for (0..16) |_| _ = r.next();
    }

    /// Projects `ran` into [0, n]: masks it to the smallest Mersenne number
    /// not below `n`, drawing again while the result exceeds `n`.
    fn project(r: *Rng, ran_in: u64, n: u64) u64 {
        var lim = n;
        var sh: u6 = 1;
        while (lim & (lim +% 1) != 0) : (sh *%= 2) lim |= lim >> sh;
        var ran = ran_in & lim;
        while (ran > n) ran = r.next() & lim;
        return ran;
    }
};

/// A float in [0, 1) from the top 53 bits (`I2d`).
fn toUnitFloat(x: u64) f64 {
    return @as(f64, @floatFromInt(x >> 11)) * 0x1p-53;
}

fn rngOf(ud: *Userdata) *Rng {
    return @ptrCast(ud.bytes().ptr);
}

fn rngArg(th: *Thread, base: u32) *Rng {
    return rngOf(th.stack[base - 1].asNativeClosure().upvalues()[0].asUserdata());
}

/// `luaL_makeseed`: a seed that varies between runs. The reference mixes
/// the time and an address; this mixes addresses ASLR moves and the state's
/// hash seed.
fn makeSeed(state: *State) u64 {
    var local: u8 = 0;
    return std.hash.Wyhash.hash(state.seed, std.mem.asBytes(&[_]usize{ @intFromPtr(&local), @intFromPtr(state) }));
}

fn random(th: *Thread, base: u32) Error!u32 {
    const a: Args = .init(th, base, "random");
    const r = rngArg(th, base);
    const rv = r.next();
    var low: i64 = undefined;
    var up: i64 = undefined;
    switch (a.count()) {
        0 => {
            th.push(.float(toUnitFloat(rv)));
            return 1;
        },
        1 => {
            low = 1;
            up = try a.checkInteger(1);
            if (up == 0) {
                th.push(.int(@bitCast(rv)));
                return 1;
            }
        },
        2 => {
            low = try a.checkInteger(1);
            up = try a.checkInteger(2);
        },
        else => return raise(th, "wrong number of arguments", .{}),
    }
    if (low > up) return a.argError(1, "interval is empty", .{});
    const p = r.project(rv, @as(u64, @bitCast(up)) -% @as(u64, @bitCast(low)));
    th.push(.int(@bitCast(p +% @as(u64, @bitCast(low)))));
    return 1;
}

fn randomseed(th: *Thread, base: u32) Error!u32 {
    const a: Args = .init(th, base, "randomseed");
    const r = rngArg(th, base);
    var n1: u64 = undefined;
    var n2: u64 = undefined;
    if (a.isNone(1)) {
        n1 = makeSeed(th.state);
        n2 = r.next();
    } else {
        n1 = @bitCast(try a.checkInteger(1));
        n2 = @bitCast(try a.optInteger(2, 0));
    }
    r.seed(n1, n2);
    th.push(.int(@bitCast(n1)));
    th.push(.int(@bitCast(n2)));
    return 2;
}

// ---------------------------------------------------------------------------
// Tests. Expected values come from reference Lua 5.5.1 (`lua` in the dev
// shell), most from the cases in test/lua-5.5.1-tests/math.lua.
// ---------------------------------------------------------------------------

const testing = std.testing;
const h = auxlib.testing;

test "math functions match the reference" {
    @setEvalBranchQuota(100_000);
    const state = try h.newState();
    defer state.destroy();
    try open(state);
    try h.expectCases(state, .{
        .{ "math.abs", .{@as(f64, -10.43)}, "10.43" },
        .{ "math.abs", .{@as(i64, -9223372036854775807 - 1)}, "-9223372036854775808" },
        .{ "math.abs", .{@as(i64, 9223372036854775807)}, "9223372036854775807" },
        .{ "math.abs", .{@as(i64, -9223372036854775807)}, "9223372036854775807" },
        .{ "math.abs", .{@as(f64, -0.0)}, "0.0" },
        .{ "math.abs", .{"-3"}, "3.0" },
        .{ "math.abs", .{.{ .kv = .{} }}, "error: bad argument #1 to 'abs' (number expected, got table)" },
        .{ "math.abs", .{}, "error: bad argument #1 to 'abs' (number expected, got no value)" },
        .{ "math.floor", .{@as(f64, 3.3999999999999999)}, "3" },
        .{ "math.ceil", .{@as(f64, 3.3999999999999999)}, "4" },
        .{ "math.floor", .{@as(f64, -3.3999999999999999)}, "-4" },
        .{ "math.ceil", .{@as(f64, -3.3999999999999999)}, "-3" },
        .{ "math.floor", .{@as(i64, 9223372036854775807)}, "9223372036854775807" },
        .{ "math.ceil", .{@as(i64, -9223372036854775807 - 1)}, "-9223372036854775808" },
        .{ "math.floor", .{@as(f64, -9.2233720368547758e+18)}, "-9223372036854775808" },
        .{ "math.ceil", .{@as(f64, -9.2233720368547758e+18)}, "-9223372036854775808" },
        .{ "math.floor", .{@as(f64, 1.0000000000000001e+50)}, "1e+50" },
        .{ "math.ceil", .{@as(f64, -1.0000000000000001e+50)}, "-1e+50" },
        .{ "math.floor", .{@as(f64, 9.2233720368547758e+18)}, "9.2233720368547758e+18" },
        .{ "math.ceil", .{@as(f64, -9.2233720368547758e+18)}, "-9223372036854775808" },
        .{ "math.floor", .{std.math.inf(f64)}, "inf" },
        .{ "math.ceil", .{-std.math.inf(f64)}, "-inf" },
        .{ "math.floor", .{@as(f64, -0.0)}, "0" },
        .{ "math.floor", .{"3.7"}, "3" },
        .{ "math.floor", .{"8"}, "8" },
        .{ "math.floor", .{.{ .kv = .{} }}, "error: bad argument #1 to 'floor' (number expected, got table)" },
        .{ "math.ceil", .{.native_function}, "error: bad argument #1 to 'ceil' (number expected, got function)" },
        .{ "math.floor", .{@as(f64, @bitCast(@as(u64, 0xfff8000000000000)))}, "-nan" },
        .{ "math.tointeger", .{@as(i64, -9223372036854775807 - 1)}, "-9223372036854775808" },
        .{ "math.tointeger", .{"-9223372036854775808"}, "-9223372036854775808" },
        .{ "math.tointeger", .{"9223372036854775807"}, "9223372036854775807" },
        .{ "math.tointeger", .{@as(f64, -9.2233720368547758e+18)}, "-9223372036854775808" },
        .{ "math.tointeger", .{@as(f64, 9.2233720368547758e+18)}, "nil" },
        .{ "math.tointeger", .{@as(f64, 3.1415926535897931)}, "nil" },
        .{ "math.tointeger", .{std.math.inf(f64)}, "nil" },
        .{ "math.tointeger", .{"34.0"}, "34" },
        .{ "math.tointeger", .{"34.3"}, "nil" },
        .{ "math.tointeger", .{.{ .kv = .{} }}, "nil" },
        .{ "math.tointeger", .{@as(f64, @bitCast(@as(u64, 0xfff8000000000000)))}, "nil" },
        .{ "math.tointeger", .{}, "error: bad argument #1 to 'tointeger' (value expected)" },
        .{ "math.tointeger", .{null}, "nil" },
        .{ "math.tointeger", .{" 0x10 "}, "16" },
        .{ "math.fmod", .{ @as(i64, 10), @as(i64, 3) }, "1" },
        .{ "math.fmod", .{ @as(i64, -6), @as(i64, 4) }, "-2" },
        .{ "math.fmod", .{ @as(i64, 6), @as(i64, -4) }, "2" },
        .{ "math.fmod", .{ @as(f64, -6.0), @as(i64, 4) }, "-2.0" },
        .{ "math.fmod", .{ @as(i64, -9223372036854775807 - 1), @as(i64, -9223372036854775807 - 1) }, "0" },
        .{ "math.fmod", .{ @as(i64, 9223372036854775807), @as(i64, 9223372036854775807) }, "0" },
        .{
            "math.fmod",
            .{ @as(i64, -9223372036854775807), @as(i64, -9223372036854775807 - 1) },
            "-9223372036854775807",
        },
        .{ "math.fmod", .{ @as(i64, 9223372036854775806), @as(i64, 9223372036854775807) }, "9223372036854775806" },
        .{ "math.fmod", .{ @as(i64, -9223372036854775807 - 1), @as(i64, -1) }, "0" },
        .{ "math.fmod", .{ @as(i64, 3), @as(i64, 0) }, "error: bad argument #2 to 'fmod' (zero)" },
        .{ "math.fmod", .{ @as(i64, 3), @as(f64, 0.0) }, "-nan" },
        .{ "math.fmod", .{ @as(i64, 1), std.math.inf(f64) }, "1.0" },
        .{ "math.fmod", .{ @as(i64, -1), std.math.inf(f64) }, "-1.0" },
        .{ "math.fmod", .{ std.math.inf(f64), @as(i64, 1) }, "-nan" },
        .{ "math.fmod", .{ @as(f64, 5.5), @as(i64, 2) }, "1.5" },
        .{ "math.fmod", .{ @as(f64, -5.5), @as(i64, 2) }, "-1.5" },
        .{ "math.fmod", .{ "7", @as(i64, 2) }, "1.0" },
        .{ "math.fmod", .{ @as(i64, 7), "x" }, "error: bad argument #2 to 'fmod' (number expected, got string)" },
        .{ "math.fmod", .{ @as(f64, 0.0), @as(i64, 1) }, "0.0" },
        .{ "math.fmod", .{ @as(f64, -0.0), @as(i64, 1) }, "-0.0" },
        .{ "math.fmod", .{ @as(f64, 1e+308), @as(i64, 3) }, "2.0" },
        .{ "math.modf", .{@as(f64, 3.5)}, "3\t0.5" },
        .{ "math.modf", .{@as(f64, -2.5)}, "-2\t-0.5" },
        .{ "math.modf", .{@as(f64, -3.0000000000000001e+23)}, "-3e+23\t0.0" },
        .{ "math.modf", .{@as(f64, 2.9999999999999999e+35)}, "3e+35\t0.0" },
        .{ "math.modf", .{-std.math.inf(f64)}, "-inf\t0.0" },
        .{ "math.modf", .{std.math.inf(f64)}, "inf\t0.0" },
        .{ "math.modf", .{@as(f64, @bitCast(@as(u64, 0xfff8000000000000)))}, "-nan\t-nan" },
        .{ "math.modf", .{@as(i64, 3)}, "3\t0.0" },
        .{ "math.modf", .{@as(i64, -9223372036854775807 - 1)}, "-9223372036854775808\t0.0" },
        .{ "math.modf", .{@as(f64, -0.0)}, "0\t0.0" },
        .{ "math.modf", .{"2.25"}, "2\t0.25" },
        .{ "math.ult", .{ @as(i64, 3), @as(i64, 4) }, "true" },
        .{ "math.ult", .{ @as(i64, 4), @as(i64, 4) }, "false" },
        .{ "math.ult", .{ @as(i64, -2), @as(i64, -1) }, "true" },
        .{ "math.ult", .{ @as(i64, 2), @as(i64, -1) }, "true" },
        .{ "math.ult", .{ @as(i64, 9223372036854775807), @as(i64, -9223372036854775807 - 1) }, "true" },
        .{ "math.ult", .{ null, null }, "error: bad argument #1 to 'ult' (number expected, got nil)" },
        .{
            "math.ult",
            .{ @as(f64, 1.5), @as(i64, 2) },
            "error: bad argument #1 to 'ult' (number has no integer representation)",
        },
        .{ "math.ult", .{@as(i64, 1)}, "error: bad argument #2 to 'ult' (number expected, got no value)" },
        .{ "math.max", .{}, "error: bad argument #1 to 'max' (value expected)" },
        .{ "math.min", .{}, "error: bad argument #1 to 'min' (value expected)" },
        .{ "math.max", .{@as(i64, 3)}, "3" },
        .{ "math.max", .{ @as(i64, 3), @as(i64, 5), @as(i64, 9), @as(i64, 1) }, "9" },
        .{ "math.max", .{ @as(i64, 9223372036854775807), @as(f64, 9.9999999999999995e+60) }, "1e+61" },
        .{
            "math.max",
            .{ @as(i64, -9223372036854775807 - 1), @as(i64, -9223372036854775807) },
            "-9223372036854775807",
        },
        .{
            "math.min",
            .{
                @as(f64, 3.2000000000000002),
                @as(f64, 5.9000000000000004),
                @as(f64, -9.1999999999999993),
                @as(f64, 1.1000000000000001),
            },
            "-9.2",
        },
        .{ "math.min", .{ @as(f64, 1.8999999999999999), @as(f64, 1.7), @as(f64, 1.72) }, "1.7" },
        .{ "math.min", .{ @as(f64, -9.9999999999999995e+60), @as(i64, -9223372036854775807 - 1) }, "-1e+61" },
        .{ "math.min", .{ @as(i64, 9223372036854775807), @as(i64, 9223372036854775806) }, "9223372036854775806" },
        .{
            "math.min",
            .{ @as(i64, 9223372036854775805), @as(i64, 9223372036854775807), @as(i64, 9223372036854775806) },
            "9223372036854775805",
        },
        .{ "math.max", .{ @as(i64, 1), @as(f64, 1.0) }, "1" },
        .{ "math.max", .{ @as(f64, 1.0), @as(i64, 1) }, "1.0" },
        .{ "math.min", .{ "b", "a" }, "a" },
        .{ "math.max", .{ @as(i64, 1), "a" }, "error: attempt to compare number with string" },
        .{ "math.max", .{ @as(f64, @bitCast(@as(u64, 0xfff8000000000000))), @as(i64, 1) }, "-nan" },
        .{ "math.max", .{ @as(i64, 1), @as(f64, @bitCast(@as(u64, 0xfff8000000000000))) }, "1" },
        .{ "math.min", .{ .{ .kv = .{} }, .{ .kv = .{} } }, "error: attempt to compare two table values" },
        .{ "math.type", .{@as(i64, 0)}, "integer" },
        .{ "math.type", .{@as(f64, 0.0)}, "float" },
        .{ "math.type", .{"10"}, "nil" },
        .{ "math.type", .{}, "error: bad argument #1 to 'type' (value expected)" },
        .{ "math.type", .{null}, "nil" },
        .{ "math.log", .{ @as(i64, 2), @as(i64, 10) }, "0.3010299956639812" },
        .{ "math.log", .{ @as(i64, 2), @as(i64, 2) }, "1.0" },
        .{ "math.log", .{ @as(i64, 9), @as(i64, 3) }, "2.0" },
        .{ "math.log", .{@as(i64, 8)}, "2.0794415416798357" },
        .{ "math.log", .{ @as(i64, 1024), @as(i64, 2) }, "10.0" },
        .{ "math.log", .{ @as(i64, 1000), @as(i64, 10) }, "3.0" },
        .{ "math.log", .{@as(i64, 0)}, "-inf" },
        .{ "math.log", .{@as(i64, -1)}, "-nan" },
        .{ "math.log", .{ @as(i64, 2), null }, "0.69314718055994529" },
        .{ "math.log", .{ @as(i64, 10), @as(i64, 0) }, "-0.0" },
        .{ "math.exp", .{@as(i64, 0)}, "1.0" },
        .{ "math.exp", .{@as(i64, 1)}, "2.7182818284590451" },
        .{ "math.exp", .{@as(i64, 710)}, "inf" },
        .{ "math.exp", .{@as(i64, -746)}, "0.0" },
        .{ "math.exp", .{@as(f64, 0.5)}, "1.6487212707001282" },
        .{ "math.sqrt", .{@as(i64, 4)}, "2.0" },
        .{ "math.sqrt", .{@as(i64, 2)}, "1.4142135623730951" },
        .{ "math.sqrt", .{@as(i64, -1)}, "-nan" },
        .{ "math.sqrt", .{"16"}, "4.0" },
        .{ "math.sin", .{@as(i64, 0)}, "0.0" },
        .{ "math.sin", .{@as(f64, 1.5707963267948966)}, "1.0" },
        .{ "math.cos", .{@as(i64, 0)}, "1.0" },
        .{ "math.cos", .{@as(f64, 3.1415926535897931)}, "-1.0" },
        .{ "math.tan", .{@as(i64, 0)}, "0.0" },
        .{ "math.tan", .{@as(f64, 0.78539816339744828)}, "0.99999999999999989" },
        .{ "math.asin", .{@as(i64, 1)}, "1.5707963267948966" },
        .{ "math.acos", .{@as(i64, -1)}, "3.1415926535897931" },
        .{ "math.acos", .{@as(i64, 2)}, "nan" },
        .{ "math.atan", .{@as(i64, 1)}, "0.78539816339744828" },
        .{ "math.atan", .{ @as(i64, 1), @as(i64, 2) }, "0.46364760900080609" },
        .{ "math.atan", .{ @as(i64, 1), @as(i64, -1) }, "2.3561944901923448" },
        .{ "math.atan", .{ @as(f64, -0.0), @as(i64, -1) }, "-3.1415926535897931" },
        .{ "math.atan", .{ @as(i64, 0), @as(i64, 0) }, "0.0" },
        .{ "math.atan", .{ @as(i64, 1), null }, "0.78539816339744828" },
        .{ "math.atan", .{null}, "error: bad argument #1 to 'atan' (number expected, got nil)" },
        .{ "math.deg", .{@as(f64, 3.1415926535897931)}, "180.0" },
        .{ "math.deg", .{@as(i64, 1)}, "57.295779513082323" },
        .{ "math.rad", .{@as(i64, 180)}, "3.1415926535897931" },
        .{ "math.rad", .{@as(i64, 1)}, "0.017453292519943295" },
        .{ "math.frexp", .{@as(i64, 8)}, "0.5\t4" },
        .{ "math.frexp", .{@as(f64, 0.29999999999999999)}, "0.6\t-1" },
        .{ "math.frexp", .{@as(i64, -5)}, "-0.625\t3" },
        .{ "math.frexp", .{@as(i64, 0)}, "0.0\t0" },
        .{ "math.frexp", .{@as(f64, -0.0)}, "-0.0\t0" },
        .{ "math.frexp", .{std.math.inf(f64)}, "inf\t0" },
        .{ "math.frexp", .{@as(f64, 4.9406564584124654e-324)}, "0.5\t-1073" },
        .{ "math.frexp", .{@as(f64, 1e+308)}, "0.55626846462680035\t1024" },
        .{ "math.ldexp", .{ @as(i64, 1), @as(i64, 10) }, "1024.0" },
        .{ "math.ldexp", .{ @as(f64, 0.75), @as(i64, -2) }, "0.1875" },
        .{ "math.ldexp", .{ @as(i64, 1), @as(i64, 2000) }, "inf" },
        .{ "math.ldexp", .{ @as(i64, 1), @as(i64, -1080) }, "0.0" },
        .{ "math.ldexp", .{ @as(i64, 1), @as(f64, 4294967299.0) }, "8.0" },
        .{
            "math.ldexp",
            .{ @as(i64, 1), @as(f64, 1.5) },
            "error: bad argument #2 to 'ldexp' (number has no integer representation)",
        },
        .{ "math.ldexp", .{ @as(i64, 3), @as(i64, -1074) }, "1.48219693752374e-323" },
        .{ "math.randomseed", .{@as(i64, 1007)}, "1007\t0" },
        .{ "math.random", .{@as(i64, 0)}, "8822622750169614806" },
        .{ "math.randomseed", .{ @as(i64, 1007), @as(i64, 0) }, "1007\t0" },
        .{ "math.random", .{}, "0.47827533763769658" },
        .{ "math.randomseed", .{@as(i64, 42)}, "42\t0" },
        .{ "math.random", .{}, "0.93081217803956817" },
        .{ "math.random", .{@as(i64, 10)}, "2" },
        .{ "math.random", .{@as(i64, 0)}, "-8358531260401861301" },
        .{ "math.random", .{ @as(i64, -5), @as(i64, 5) }, "0" },
        .{
            "math.random",
            .{ @as(i64, -9223372036854775807 - 1), @as(i64, 9223372036854775807) },
            "2164128405858571189",
        },
        .{ "math.random", .{ @as(i64, 1), @as(i64, 1) }, "1" },
        .{ "math.random", .{@as(i64, 3)}, "3" },
        .{ "math.random", .{@as(i64, 9223372036854775807)}, "3891836817331783282" },
        .{ "math.random", .{ @as(i64, -9223372036854775807 - 1), @as(i64, -1) }, "-4158689442498620264" },
        .{ "math.random", .{ @as(i64, 0), @as(i64, 9223372036854775807) }, "3570341730643388674" },
        .{ "math.random", .{ @as(i64, 10), @as(i64, 1) }, "error: bad argument #1 to 'random' (interval is empty)" },
        .{ "math.random", .{ @as(i64, 1), @as(i64, 2), @as(i64, 3) }, "error: wrong number of arguments" },
        .{
            "math.random",
            .{@as(f64, 1.5)},
            "error: bad argument #1 to 'random' (number has no integer representation)",
        },
        .{ "math.random", .{"7"}, "1" },
        .{ "math.random", .{@as(i64, -3)}, "error: bad argument #1 to 'random' (interval is empty)" },
        .{ "math.randomseed", .{ @as(i64, -1), @as(i64, -2) }, "-1\t-2" },
        .{ "math.random", .{@as(i64, 1000000)}, "212044" },
        .{ "math.random", .{@as(i64, 6)}, "5" },
        .{ "math.random", .{@as(i64, 6)}, "1" },
        .{ "math.random", .{}, "0.88765156414261737" },
        .{ "math.randomseed", .{@as(f64, 1.0)}, "1\t0" },
        .{ "math.random", .{@as(i64, 0)}, "-3401804370673955427" },
        .{
            "math.randomseed",
            .{@as(f64, 1.5)},
            "error: bad argument #1 to 'randomseed' (number has no integer representation)",
        },
        .{ "math.exp", .{std.math.inf(f64)}, "inf" },
        .{ "math.exp", .{-std.math.inf(f64)}, "0.0" },
        .{ "math.exp", .{@as(f64, @bitCast(@as(u64, 0xfff8000000000000)))}, "-nan" },
        .{ "math.exp", .{@as(f64, @bitCast(@as(u64, 0x7ff8000000000000)))}, "nan" },
        .{ "math.exp", .{@as(f64, 0.0)}, "1.0" },
        .{ "math.exp", .{@as(f64, -0.0)}, "1.0" },
        .{ "math.exp", .{@as(f64, 1e+308)}, "inf" },
        .{ "math.exp", .{@as(f64, -1e+308)}, "0.0" },
        .{ "math.exp", .{@as(i64, 2)}, "7.38905609893065" },
        .{ "math.exp", .{@as(i64, -2)}, "0.1353352832366127" },
        .{ "math.exp", .{@as(f64, 9.9999999999999694e-311)}, "1.0" },
        .{ "math.log", .{std.math.inf(f64)}, "inf" },
        .{ "math.log", .{-std.math.inf(f64)}, "-nan" },
        .{ "math.log", .{@as(f64, @bitCast(@as(u64, 0xfff8000000000000)))}, "-nan" },
        .{ "math.log", .{@as(f64, @bitCast(@as(u64, 0x7ff8000000000000)))}, "nan" },
        .{ "math.log", .{@as(f64, 0.0)}, "-inf" },
        .{ "math.log", .{@as(f64, -0.0)}, "-inf" },
        .{ "math.log", .{@as(f64, 1e+308)}, "709.19620864216608" },
        .{ "math.log", .{@as(f64, -1e+308)}, "-nan" },
        .{ "math.log", .{@as(i64, 2)}, "0.69314718055994529" },
        .{ "math.log", .{@as(i64, -2)}, "-nan" },
        .{ "math.log", .{@as(f64, 9.9999999999999694e-311)}, "-713.80137882815416" },
        .{ "math.sin", .{std.math.inf(f64)}, "-nan" },
        .{ "math.sin", .{-std.math.inf(f64)}, "-nan" },
        .{ "math.sin", .{@as(f64, @bitCast(@as(u64, 0xfff8000000000000)))}, "-nan" },
        .{ "math.sin", .{@as(f64, @bitCast(@as(u64, 0x7ff8000000000000)))}, "nan" },
        .{ "math.sin", .{@as(f64, 0.0)}, "0.0" },
        .{ "math.sin", .{@as(f64, -0.0)}, "-0.0" },
        .{ "math.sin", .{@as(f64, 1e+308)}, "0.4533964905016491" },
        .{ "math.sin", .{@as(f64, -1e+308)}, "-0.4533964905016491" },
        .{ "math.sin", .{@as(i64, 2)}, "0.90929742682568171" },
        .{ "math.sin", .{@as(i64, -2)}, "-0.90929742682568171" },
        .{ "math.sin", .{@as(f64, 9.9999999999999694e-311)}, "9.99999999999997e-311" },
        .{ "math.cos", .{std.math.inf(f64)}, "-nan" },
        .{ "math.cos", .{-std.math.inf(f64)}, "-nan" },
        .{ "math.cos", .{@as(f64, @bitCast(@as(u64, 0xfff8000000000000)))}, "-nan" },
        .{ "math.cos", .{@as(f64, @bitCast(@as(u64, 0x7ff8000000000000)))}, "nan" },
        .{ "math.cos", .{@as(f64, 0.0)}, "1.0" },
        .{ "math.cos", .{@as(f64, -0.0)}, "1.0" },
        .{ "math.cos", .{@as(f64, 1e+308)}, "-0.89130893768703345" },
        .{ "math.cos", .{@as(f64, -1e+308)}, "-0.89130893768703345" },
        .{ "math.cos", .{@as(i64, 2)}, "-0.41614683654714241" },
        .{ "math.cos", .{@as(i64, -2)}, "-0.41614683654714241" },
        .{ "math.cos", .{@as(f64, 9.9999999999999694e-311)}, "1.0" },
        .{ "math.tan", .{std.math.inf(f64)}, "-nan" },
        .{ "math.tan", .{-std.math.inf(f64)}, "-nan" },
        .{ "math.tan", .{@as(f64, @bitCast(@as(u64, 0xfff8000000000000)))}, "-nan" },
        .{ "math.tan", .{@as(f64, @bitCast(@as(u64, 0x7ff8000000000000)))}, "nan" },
        .{ "math.tan", .{@as(f64, 0.0)}, "0.0" },
        .{ "math.tan", .{@as(f64, -0.0)}, "-0.0" },
        .{ "math.tan", .{@as(f64, 1e+308)}, "-0.50868612591075679" },
        .{ "math.tan", .{@as(f64, -1e+308)}, "0.50868612591075679" },
        .{ "math.tan", .{@as(i64, 2)}, "-2.1850398632615189" },
        .{ "math.tan", .{@as(i64, -2)}, "2.1850398632615189" },
        .{ "math.tan", .{@as(f64, 9.9999999999999694e-311)}, "9.99999999999997e-311" },
        .{ "math.asin", .{std.math.inf(f64)}, "nan" },
        .{ "math.asin", .{-std.math.inf(f64)}, "nan" },
        .{ "math.asin", .{@as(f64, @bitCast(@as(u64, 0xfff8000000000000)))}, "-nan" },
        .{ "math.asin", .{@as(f64, @bitCast(@as(u64, 0x7ff8000000000000)))}, "nan" },
        .{ "math.asin", .{@as(f64, 0.0)}, "0.0" },
        .{ "math.asin", .{@as(f64, -0.0)}, "-0.0" },
        .{ "math.asin", .{@as(f64, 1e+308)}, "nan" },
        .{ "math.asin", .{@as(f64, -1e+308)}, "nan" },
        .{ "math.asin", .{@as(i64, 2)}, "nan" },
        .{ "math.asin", .{@as(i64, -2)}, "nan" },
        .{ "math.asin", .{@as(f64, 9.9999999999999694e-311)}, "9.99999999999997e-311" },
        .{ "math.acos", .{std.math.inf(f64)}, "nan" },
        .{ "math.acos", .{-std.math.inf(f64)}, "nan" },
        .{ "math.acos", .{@as(f64, @bitCast(@as(u64, 0xfff8000000000000)))}, "-nan" },
        .{ "math.acos", .{@as(f64, @bitCast(@as(u64, 0x7ff8000000000000)))}, "nan" },
        .{ "math.acos", .{@as(f64, 0.0)}, "1.5707963267948966" },
        .{ "math.acos", .{@as(f64, -0.0)}, "1.5707963267948966" },
        .{ "math.acos", .{@as(f64, 1e+308)}, "nan" },
        .{ "math.acos", .{@as(f64, -1e+308)}, "nan" },
        .{ "math.acos", .{@as(i64, 2)}, "nan" },
        .{ "math.acos", .{@as(i64, -2)}, "nan" },
        .{ "math.acos", .{@as(f64, 9.9999999999999694e-311)}, "1.5707963267948966" },
        .{ "math.atan", .{std.math.inf(f64)}, "1.5707963267948966" },
        .{ "math.atan", .{-std.math.inf(f64)}, "-1.5707963267948966" },
        .{ "math.atan", .{@as(f64, @bitCast(@as(u64, 0xfff8000000000000)))}, "-nan" },
        .{ "math.atan", .{@as(f64, @bitCast(@as(u64, 0x7ff8000000000000)))}, "nan" },
        .{ "math.atan", .{@as(f64, 0.0)}, "0.0" },
        .{ "math.atan", .{@as(f64, -0.0)}, "-0.0" },
        .{ "math.atan", .{@as(f64, 1e+308)}, "1.5707963267948966" },
        .{ "math.atan", .{@as(f64, -1e+308)}, "-1.5707963267948966" },
        .{ "math.atan", .{@as(i64, 2)}, "1.1071487177940904" },
        .{ "math.atan", .{@as(i64, -2)}, "-1.1071487177940904" },
        .{ "math.atan", .{@as(f64, 9.9999999999999694e-311)}, "9.99999999999997e-311" },
        .{ "math.sqrt", .{std.math.inf(f64)}, "inf" },
        .{ "math.sqrt", .{-std.math.inf(f64)}, "-nan" },
        .{ "math.sqrt", .{@as(f64, @bitCast(@as(u64, 0xfff8000000000000)))}, "-nan" },
        .{ "math.sqrt", .{@as(f64, @bitCast(@as(u64, 0x7ff8000000000000)))}, "nan" },
        .{ "math.sqrt", .{@as(f64, 0.0)}, "0.0" },
        .{ "math.sqrt", .{@as(f64, -0.0)}, "-0.0" },
        .{ "math.sqrt", .{@as(f64, 1e+308)}, "1e+154" },
        .{ "math.sqrt", .{@as(f64, -1e+308)}, "-nan" },
        .{ "math.sqrt", .{@as(i64, 2)}, "1.4142135623730951" },
        .{ "math.sqrt", .{@as(i64, -2)}, "-nan" },
        .{ "math.sqrt", .{@as(f64, 9.9999999999999694e-311)}, "9.9999999999999857e-156" },
        .{ "math.floor", .{std.math.inf(f64)}, "inf" },
        .{ "math.floor", .{-std.math.inf(f64)}, "-inf" },
        .{ "math.floor", .{@as(f64, @bitCast(@as(u64, 0xfff8000000000000)))}, "-nan" },
        .{ "math.floor", .{@as(f64, @bitCast(@as(u64, 0x7ff8000000000000)))}, "nan" },
        .{ "math.floor", .{@as(f64, 0.0)}, "0" },
        .{ "math.floor", .{@as(f64, -0.0)}, "0" },
        .{ "math.floor", .{@as(f64, 1e+308)}, "1e+308" },
        .{ "math.floor", .{@as(f64, -1e+308)}, "-1e+308" },
        .{ "math.floor", .{@as(i64, 2)}, "2" },
        .{ "math.floor", .{@as(i64, -2)}, "-2" },
        .{ "math.floor", .{@as(f64, 9.9999999999999694e-311)}, "0" },
        .{ "math.ceil", .{std.math.inf(f64)}, "inf" },
        .{ "math.ceil", .{-std.math.inf(f64)}, "-inf" },
        .{ "math.ceil", .{@as(f64, @bitCast(@as(u64, 0xfff8000000000000)))}, "-nan" },
        .{ "math.ceil", .{@as(f64, @bitCast(@as(u64, 0x7ff8000000000000)))}, "nan" },
        .{ "math.ceil", .{@as(f64, 0.0)}, "0" },
        .{ "math.ceil", .{@as(f64, -0.0)}, "0" },
        .{ "math.ceil", .{@as(f64, 1e+308)}, "1e+308" },
        .{ "math.ceil", .{@as(f64, -1e+308)}, "-1e+308" },
        .{ "math.ceil", .{@as(i64, 2)}, "2" },
        .{ "math.ceil", .{@as(i64, -2)}, "-2" },
        .{ "math.ceil", .{@as(f64, 9.9999999999999694e-311)}, "1" },
        .{ "math.abs", .{std.math.inf(f64)}, "inf" },
        .{ "math.abs", .{-std.math.inf(f64)}, "inf" },
        .{ "math.abs", .{@as(f64, @bitCast(@as(u64, 0xfff8000000000000)))}, "nan" },
        .{ "math.abs", .{@as(f64, @bitCast(@as(u64, 0x7ff8000000000000)))}, "nan" },
        .{ "math.abs", .{@as(f64, 0.0)}, "0.0" },
        .{ "math.abs", .{@as(f64, -0.0)}, "0.0" },
        .{ "math.abs", .{@as(f64, 1e+308)}, "1e+308" },
        .{ "math.abs", .{@as(f64, -1e+308)}, "1e+308" },
        .{ "math.abs", .{@as(i64, 2)}, "2" },
        .{ "math.abs", .{@as(i64, -2)}, "2" },
        .{ "math.abs", .{@as(f64, 9.9999999999999694e-311)}, "9.99999999999997e-311" },
        .{ "math.deg", .{std.math.inf(f64)}, "inf" },
        .{ "math.deg", .{-std.math.inf(f64)}, "-inf" },
        .{ "math.deg", .{@as(f64, @bitCast(@as(u64, 0xfff8000000000000)))}, "-nan" },
        .{ "math.deg", .{@as(f64, @bitCast(@as(u64, 0x7ff8000000000000)))}, "nan" },
        .{ "math.deg", .{@as(f64, 0.0)}, "0.0" },
        .{ "math.deg", .{@as(f64, -0.0)}, "-0.0" },
        .{ "math.deg", .{@as(f64, 1e+308)}, "inf" },
        .{ "math.deg", .{@as(f64, -1e+308)}, "-inf" },
        .{ "math.deg", .{@as(i64, 2)}, "114.59155902616465" },
        .{ "math.deg", .{@as(i64, -2)}, "-114.59155902616465" },
        .{ "math.deg", .{@as(f64, 9.9999999999999694e-311)}, "5.7295779513082142e-309" },
        .{ "math.rad", .{std.math.inf(f64)}, "inf" },
        .{ "math.rad", .{-std.math.inf(f64)}, "-inf" },
        .{ "math.rad", .{@as(f64, @bitCast(@as(u64, 0xfff8000000000000)))}, "-nan" },
        .{ "math.rad", .{@as(f64, @bitCast(@as(u64, 0x7ff8000000000000)))}, "nan" },
        .{ "math.rad", .{@as(f64, 0.0)}, "0.0" },
        .{ "math.rad", .{@as(f64, -0.0)}, "-0.0" },
        .{ "math.rad", .{@as(f64, 1e+308)}, "1.7453292519943295e+306" },
        .{ "math.rad", .{@as(f64, -1e+308)}, "-1.7453292519943295e+306" },
        .{ "math.rad", .{@as(i64, 2)}, "0.034906585039886591" },
        .{ "math.rad", .{@as(i64, -2)}, "-0.034906585039886591" },
        .{ "math.rad", .{@as(f64, 9.9999999999999694e-311)}, "1.74532925199524e-312" },
        .{ "math.modf", .{std.math.inf(f64)}, "inf\t0.0" },
        .{ "math.modf", .{-std.math.inf(f64)}, "-inf\t0.0" },
        .{ "math.modf", .{@as(f64, @bitCast(@as(u64, 0xfff8000000000000)))}, "-nan\t-nan" },
        .{ "math.modf", .{@as(f64, @bitCast(@as(u64, 0x7ff8000000000000)))}, "nan\tnan" },
        .{ "math.modf", .{@as(f64, 0.0)}, "0\t0.0" },
        .{ "math.modf", .{@as(f64, -0.0)}, "0\t0.0" },
        .{ "math.modf", .{@as(f64, 1e+308)}, "1e+308\t0.0" },
        .{ "math.modf", .{@as(f64, -1e+308)}, "-1e+308\t0.0" },
        .{ "math.modf", .{@as(i64, 2)}, "2\t0.0" },
        .{ "math.modf", .{@as(i64, -2)}, "-2\t0.0" },
        .{ "math.modf", .{@as(f64, 9.9999999999999694e-311)}, "0\t9.99999999999997e-311" },
        .{ "math.frexp", .{std.math.inf(f64)}, "inf\t0" },
        .{ "math.frexp", .{-std.math.inf(f64)}, "-inf\t0" },
        .{ "math.frexp", .{@as(f64, @bitCast(@as(u64, 0xfff8000000000000)))}, "-nan\t0" },
        .{ "math.frexp", .{@as(f64, @bitCast(@as(u64, 0x7ff8000000000000)))}, "nan\t0" },
        .{ "math.frexp", .{@as(f64, 0.0)}, "0.0\t0" },
        .{ "math.frexp", .{@as(f64, -0.0)}, "-0.0\t0" },
        .{ "math.frexp", .{@as(f64, 1e+308)}, "0.55626846462680035\t1024" },
        .{ "math.frexp", .{@as(f64, -1e+308)}, "-0.55626846462680035\t1024" },
        .{ "math.frexp", .{@as(i64, 2)}, "0.5\t2" },
        .{ "math.frexp", .{@as(i64, -2)}, "-0.5\t2" },
        .{ "math.frexp", .{@as(f64, 9.9999999999999694e-311)}, "0.57526180315593933\t-1029" },
        .{ "math.log", .{ @as(f64, 0.0), @as(i64, 2) }, "-inf" },
        .{ "math.log", .{ @as(f64, -0.0), @as(i64, 2) }, "-inf" },
        .{ "math.log", .{ @as(i64, 1), @as(i64, 2) }, "0.0" },
        .{ "math.log", .{ @as(i64, -1), @as(i64, 2) }, "-nan" },
        .{ "math.log", .{ std.math.inf(f64), @as(i64, 2) }, "inf" },
        .{ "math.log", .{ -std.math.inf(f64), @as(i64, 2) }, "-nan" },
        .{ "math.log", .{ @as(f64, @bitCast(@as(u64, 0xfff8000000000000))), @as(i64, 2) }, "-nan" },
        .{ "math.log", .{ @as(i64, 8), @as(i64, 2) }, "3.0" },
        .{ "math.log", .{ @as(f64, 0.0), @as(i64, 10) }, "-inf" },
        .{ "math.log", .{ @as(f64, -0.0), @as(i64, 10) }, "-inf" },
        .{ "math.log", .{ @as(i64, 1), @as(i64, 10) }, "0.0" },
        .{ "math.log", .{ @as(i64, -1), @as(i64, 10) }, "nan" },
        .{ "math.log", .{ std.math.inf(f64), @as(i64, 10) }, "inf" },
        .{ "math.log", .{ -std.math.inf(f64), @as(i64, 10) }, "nan" },
        .{ "math.log", .{ @as(f64, @bitCast(@as(u64, 0xfff8000000000000))), @as(i64, 10) }, "-nan" },
        .{ "math.log", .{ @as(i64, 8), @as(i64, 10) }, "0.90308998699194354" },
        .{ "math.log", .{ @as(f64, 0.0), @as(f64, 0.5) }, "inf" },
        .{ "math.log", .{ @as(f64, -0.0), @as(f64, 0.5) }, "inf" },
        .{ "math.log", .{ @as(i64, 1), @as(f64, 0.5) }, "-0.0" },
        .{ "math.log", .{ @as(i64, -1), @as(f64, 0.5) }, "-nan" },
        .{ "math.log", .{ std.math.inf(f64), @as(f64, 0.5) }, "-inf" },
        .{ "math.log", .{ -std.math.inf(f64), @as(f64, 0.5) }, "-nan" },
        .{ "math.log", .{ @as(f64, @bitCast(@as(u64, 0xfff8000000000000))), @as(f64, 0.5) }, "-nan" },
        .{ "math.log", .{ @as(i64, 8), @as(f64, 0.5) }, "-3.0" },
        .{ "math.log", .{ @as(f64, 0.0), @as(i64, 0) }, "-nan" },
        .{ "math.log", .{ @as(f64, -0.0), @as(i64, 0) }, "-nan" },
        .{ "math.log", .{ @as(i64, 1), @as(i64, 0) }, "-0.0" },
        .{ "math.log", .{ @as(i64, -1), @as(i64, 0) }, "-nan" },
        .{ "math.log", .{ std.math.inf(f64), @as(i64, 0) }, "-nan" },
        .{ "math.log", .{ -std.math.inf(f64), @as(i64, 0) }, "-nan" },
        .{ "math.log", .{ @as(f64, @bitCast(@as(u64, 0xfff8000000000000))), @as(i64, 0) }, "-nan" },
        .{ "math.log", .{ @as(i64, 8), @as(i64, 0) }, "-0.0" },
        .{ "math.log", .{ @as(f64, 0.0), @as(i64, 1) }, "-inf" },
        .{ "math.log", .{ @as(f64, -0.0), @as(i64, 1) }, "-inf" },
        .{ "math.log", .{ @as(i64, 1), @as(i64, 1) }, "-nan" },
        .{ "math.log", .{ @as(i64, -1), @as(i64, 1) }, "-nan" },
        .{ "math.log", .{ std.math.inf(f64), @as(i64, 1) }, "inf" },
        .{ "math.log", .{ -std.math.inf(f64), @as(i64, 1) }, "-nan" },
        .{ "math.log", .{ @as(f64, @bitCast(@as(u64, 0xfff8000000000000))), @as(i64, 1) }, "-nan" },
        .{ "math.log", .{ @as(i64, 8), @as(i64, 1) }, "inf" },
        .{ "math.log", .{ @as(f64, 0.0), @as(i64, -1) }, "-nan" },
        .{ "math.log", .{ @as(f64, -0.0), @as(i64, -1) }, "-nan" },
        .{ "math.log", .{ @as(i64, 1), @as(i64, -1) }, "-nan" },
        .{ "math.log", .{ @as(i64, -1), @as(i64, -1) }, "-nan" },
        .{ "math.log", .{ std.math.inf(f64), @as(i64, -1) }, "-nan" },
        .{ "math.log", .{ -std.math.inf(f64), @as(i64, -1) }, "-nan" },
        .{ "math.log", .{ @as(f64, @bitCast(@as(u64, 0xfff8000000000000))), @as(i64, -1) }, "-nan" },
        .{ "math.log", .{ @as(i64, 8), @as(i64, -1) }, "-nan" },
        .{ "math.log", .{ @as(f64, 0.0), std.math.inf(f64) }, "-nan" },
        .{ "math.log", .{ @as(f64, -0.0), std.math.inf(f64) }, "-nan" },
        .{ "math.log", .{ @as(i64, 1), std.math.inf(f64) }, "0.0" },
        .{ "math.log", .{ @as(i64, -1), std.math.inf(f64) }, "-nan" },
        .{ "math.log", .{ std.math.inf(f64), std.math.inf(f64) }, "-nan" },
        .{ "math.log", .{ -std.math.inf(f64), std.math.inf(f64) }, "-nan" },
        .{ "math.log", .{ @as(f64, @bitCast(@as(u64, 0xfff8000000000000))), std.math.inf(f64) }, "-nan" },
        .{ "math.log", .{ @as(i64, 8), std.math.inf(f64) }, "0.0" },
        .{ "math.atan", .{ @as(f64, 0.0), @as(f64, 0.0) }, "0.0" },
        .{ "math.fmod", .{ @as(f64, 0.0), @as(f64, 0.0) }, "-nan" },
        .{ "math.atan", .{ @as(f64, 0.0), @as(f64, -0.0) }, "3.1415926535897931" },
        .{ "math.fmod", .{ @as(f64, 0.0), @as(f64, -0.0) }, "-nan" },
        .{ "math.atan", .{ @as(f64, 0.0), std.math.inf(f64) }, "0.0" },
        .{ "math.fmod", .{ @as(f64, 0.0), std.math.inf(f64) }, "0.0" },
        .{ "math.atan", .{ @as(f64, 0.0), -std.math.inf(f64) }, "3.1415926535897931" },
        .{ "math.fmod", .{ @as(f64, 0.0), -std.math.inf(f64) }, "0.0" },
        .{ "math.atan", .{ @as(f64, 0.0), @as(f64, @bitCast(@as(u64, 0xfff8000000000000))) }, "-nan" },
        .{ "math.fmod", .{ @as(f64, 0.0), @as(f64, @bitCast(@as(u64, 0xfff8000000000000))) }, "-nan" },
        .{ "math.atan", .{ @as(f64, 0.0), @as(i64, 1) }, "0.0" },
        .{ "math.fmod", .{ @as(f64, 0.0), @as(i64, 1) }, "0.0" },
        .{ "math.atan", .{ @as(f64, 0.0), @as(i64, -1) }, "3.1415926535897931" },
        .{ "math.fmod", .{ @as(f64, 0.0), @as(i64, -1) }, "0.0" },
        .{ "math.atan", .{ @as(f64, -0.0), @as(f64, 0.0) }, "-0.0" },
        .{ "math.fmod", .{ @as(f64, -0.0), @as(f64, 0.0) }, "-nan" },
        .{ "math.atan", .{ @as(f64, -0.0), @as(f64, -0.0) }, "-3.1415926535897931" },
        .{ "math.fmod", .{ @as(f64, -0.0), @as(f64, -0.0) }, "-nan" },
        .{ "math.atan", .{ @as(f64, -0.0), std.math.inf(f64) }, "-0.0" },
        .{ "math.fmod", .{ @as(f64, -0.0), std.math.inf(f64) }, "-0.0" },
        .{ "math.atan", .{ @as(f64, -0.0), -std.math.inf(f64) }, "-3.1415926535897931" },
        .{ "math.fmod", .{ @as(f64, -0.0), -std.math.inf(f64) }, "-0.0" },
        .{ "math.atan", .{ @as(f64, -0.0), @as(f64, @bitCast(@as(u64, 0xfff8000000000000))) }, "-nan" },
        .{ "math.fmod", .{ @as(f64, -0.0), @as(f64, @bitCast(@as(u64, 0xfff8000000000000))) }, "-nan" },
        .{ "math.atan", .{ @as(f64, -0.0), @as(i64, 1) }, "-0.0" },
        .{ "math.fmod", .{ @as(f64, -0.0), @as(i64, 1) }, "-0.0" },
        .{ "math.atan", .{ @as(f64, -0.0), @as(i64, -1) }, "-3.1415926535897931" },
        .{ "math.fmod", .{ @as(f64, -0.0), @as(i64, -1) }, "-0.0" },
        .{ "math.atan", .{ std.math.inf(f64), @as(f64, 0.0) }, "1.5707963267948966" },
        .{ "math.fmod", .{ std.math.inf(f64), @as(f64, 0.0) }, "-nan" },
        .{ "math.atan", .{ std.math.inf(f64), @as(f64, -0.0) }, "1.5707963267948966" },
        .{ "math.fmod", .{ std.math.inf(f64), @as(f64, -0.0) }, "-nan" },
        .{ "math.atan", .{ std.math.inf(f64), std.math.inf(f64) }, "0.78539816339744828" },
        .{ "math.fmod", .{ std.math.inf(f64), std.math.inf(f64) }, "-nan" },
        .{ "math.atan", .{ std.math.inf(f64), -std.math.inf(f64) }, "2.3561944901923448" },
        .{ "math.fmod", .{ std.math.inf(f64), -std.math.inf(f64) }, "-nan" },
        .{ "math.atan", .{ std.math.inf(f64), @as(f64, @bitCast(@as(u64, 0xfff8000000000000))) }, "-nan" },
        .{ "math.fmod", .{ std.math.inf(f64), @as(f64, @bitCast(@as(u64, 0xfff8000000000000))) }, "-nan" },
        .{ "math.atan", .{ std.math.inf(f64), @as(i64, 1) }, "1.5707963267948966" },
        .{ "math.fmod", .{ std.math.inf(f64), @as(i64, 1) }, "-nan" },
        .{ "math.atan", .{ std.math.inf(f64), @as(i64, -1) }, "1.5707963267948966" },
        .{ "math.fmod", .{ std.math.inf(f64), @as(i64, -1) }, "-nan" },
        .{ "math.atan", .{ -std.math.inf(f64), @as(f64, 0.0) }, "-1.5707963267948966" },
        .{ "math.fmod", .{ -std.math.inf(f64), @as(f64, 0.0) }, "-nan" },
        .{ "math.atan", .{ -std.math.inf(f64), @as(f64, -0.0) }, "-1.5707963267948966" },
        .{ "math.fmod", .{ -std.math.inf(f64), @as(f64, -0.0) }, "-nan" },
        .{ "math.atan", .{ -std.math.inf(f64), std.math.inf(f64) }, "-0.78539816339744828" },
        .{ "math.fmod", .{ -std.math.inf(f64), std.math.inf(f64) }, "-nan" },
        .{ "math.atan", .{ -std.math.inf(f64), -std.math.inf(f64) }, "-2.3561944901923448" },
        .{ "math.fmod", .{ -std.math.inf(f64), -std.math.inf(f64) }, "-nan" },
        .{ "math.atan", .{ -std.math.inf(f64), @as(f64, @bitCast(@as(u64, 0xfff8000000000000))) }, "-nan" },
        .{ "math.fmod", .{ -std.math.inf(f64), @as(f64, @bitCast(@as(u64, 0xfff8000000000000))) }, "-nan" },
        .{ "math.atan", .{ -std.math.inf(f64), @as(i64, 1) }, "-1.5707963267948966" },
        .{ "math.fmod", .{ -std.math.inf(f64), @as(i64, 1) }, "-nan" },
        .{ "math.atan", .{ -std.math.inf(f64), @as(i64, -1) }, "-1.5707963267948966" },
        .{ "math.fmod", .{ -std.math.inf(f64), @as(i64, -1) }, "-nan" },
        .{ "math.atan", .{ @as(f64, @bitCast(@as(u64, 0xfff8000000000000))), @as(f64, 0.0) }, "-nan" },
        .{ "math.fmod", .{ @as(f64, @bitCast(@as(u64, 0xfff8000000000000))), @as(f64, 0.0) }, "-nan" },
        .{ "math.atan", .{ @as(f64, @bitCast(@as(u64, 0xfff8000000000000))), @as(f64, -0.0) }, "-nan" },
        .{ "math.fmod", .{ @as(f64, @bitCast(@as(u64, 0xfff8000000000000))), @as(f64, -0.0) }, "-nan" },
        .{ "math.atan", .{ @as(f64, @bitCast(@as(u64, 0xfff8000000000000))), std.math.inf(f64) }, "-nan" },
        .{ "math.fmod", .{ @as(f64, @bitCast(@as(u64, 0xfff8000000000000))), std.math.inf(f64) }, "-nan" },
        .{ "math.atan", .{ @as(f64, @bitCast(@as(u64, 0xfff8000000000000))), -std.math.inf(f64) }, "-nan" },
        .{ "math.fmod", .{ @as(f64, @bitCast(@as(u64, 0xfff8000000000000))), -std.math.inf(f64) }, "-nan" },
        .{
            "math.atan",
            .{ @as(f64, @bitCast(@as(u64, 0xfff8000000000000))), @as(f64, @bitCast(@as(u64, 0xfff8000000000000))) },
            "-nan",
        },
        .{
            "math.fmod",
            .{ @as(f64, @bitCast(@as(u64, 0xfff8000000000000))), @as(f64, @bitCast(@as(u64, 0xfff8000000000000))) },
            "-nan",
        },
        .{ "math.atan", .{ @as(f64, @bitCast(@as(u64, 0xfff8000000000000))), @as(i64, 1) }, "-nan" },
        .{ "math.fmod", .{ @as(f64, @bitCast(@as(u64, 0xfff8000000000000))), @as(i64, 1) }, "-nan" },
        .{ "math.atan", .{ @as(f64, @bitCast(@as(u64, 0xfff8000000000000))), @as(i64, -1) }, "-nan" },
        .{ "math.fmod", .{ @as(f64, @bitCast(@as(u64, 0xfff8000000000000))), @as(i64, -1) }, "-nan" },
        .{ "math.atan", .{ @as(i64, 1), @as(f64, 0.0) }, "1.5707963267948966" },
        .{ "math.fmod", .{ @as(i64, 1), @as(f64, 0.0) }, "-nan" },
        .{ "math.atan", .{ @as(i64, 1), @as(f64, -0.0) }, "1.5707963267948966" },
        .{ "math.fmod", .{ @as(i64, 1), @as(f64, -0.0) }, "-nan" },
        .{ "math.atan", .{ @as(i64, 1), std.math.inf(f64) }, "0.0" },
        .{ "math.fmod", .{ @as(i64, 1), std.math.inf(f64) }, "1.0" },
        .{ "math.atan", .{ @as(i64, 1), -std.math.inf(f64) }, "3.1415926535897931" },
        .{ "math.fmod", .{ @as(i64, 1), -std.math.inf(f64) }, "1.0" },
        .{ "math.atan", .{ @as(i64, 1), @as(f64, @bitCast(@as(u64, 0xfff8000000000000))) }, "-nan" },
        .{ "math.fmod", .{ @as(i64, 1), @as(f64, @bitCast(@as(u64, 0xfff8000000000000))) }, "-nan" },
        .{ "math.atan", .{ @as(i64, 1), @as(i64, 1) }, "0.78539816339744828" },
        .{ "math.fmod", .{ @as(i64, 1), @as(i64, 1) }, "0" },
        .{ "math.atan", .{ @as(i64, 1), @as(i64, -1) }, "2.3561944901923448" },
        .{ "math.fmod", .{ @as(i64, 1), @as(i64, -1) }, "0" },
        .{ "math.ldexp", .{ std.math.inf(f64), @as(i64, 3) }, "inf" },
        .{ "math.ldexp", .{ std.math.inf(f64), @as(i64, -2000) }, "inf" },
        .{ "math.ldexp", .{ -std.math.inf(f64), @as(i64, 3) }, "-inf" },
        .{ "math.ldexp", .{ -std.math.inf(f64), @as(i64, -2000) }, "-inf" },
        .{ "math.ldexp", .{ @as(f64, @bitCast(@as(u64, 0xfff8000000000000))), @as(i64, 3) }, "-nan" },
        .{ "math.ldexp", .{ @as(f64, @bitCast(@as(u64, 0xfff8000000000000))), @as(i64, -2000) }, "-nan" },
        .{ "math.ldexp", .{ @as(f64, 0.0), @as(i64, 3) }, "0.0" },
        .{ "math.ldexp", .{ @as(f64, 0.0), @as(i64, -2000) }, "0.0" },
        .{ "math.ldexp", .{ @as(i64, 1), @as(i64, 3) }, "8.0" },
        .{ "math.ldexp", .{ @as(i64, 1), @as(i64, -2000) }, "0.0" },
    });
}

test "randomseed returns seeds that repeat the sequence" {
    const state = try h.newState();
    defer state.destroy();
    try open(state);
    const seed = try h.global(state, "math.randomseed");
    const rand = try h.global(state, "math.random");
    const s = try h.ok(state, seed, &.{});
    const x = s[0];
    const y = s[1];
    const r = (try h.ok(state, rand, &.{.int(0)}))[0].asInt();
    _ = try h.ok(state, seed, &.{ x, y });
    try testing.expectEqual(r, (try h.ok(state, rand, &.{.int(0)}))[0].asInt());
}

//! The operating system library (manual §6.9), after reference Lua 5.5.1's
//! loslib.c on glibc: `clock`, `date`, `difftime`, `execute`, `exit`,
//! `getenv`, `remove`, `rename`, `setlocale`, `time`, and `tmpname`.
//!
//! The C library's pieces are written here. Local time follows glibc: the
//! zone comes from `TZ` (a TZif file name, with or without ':', or a POSIX TZ
//! string), else `/etc/localtime`, else UTC; `os.time` normalizes a table as
//! `mktime` does; `os.date` formats as `strftime` does in the C locale, the
//! only locale there is. The environment is the embedder's: `setEnviron`.

const std = @import("std");
const Value = @import("../Value.zig");
const State = @import("../State.zig");
const Thread = @import("../Thread.zig");
const aux = @import("auxlib.zig");
const base = @import("base.zig");
const iolib = @import("io.zig");
const package = @import("package.zig");

const Error = Value.Error;
const Args = aux.Args;
const Writer = std.Io.Writer;

// ---------------------------------------------------------------------------
// The environment
// ---------------------------------------------------------------------------

const environ_key = "_LUA_ENVIRON";

/// Gives `os.getenv` and `package`'s paths the process environment. Call
/// before `openLibs`; `map` must outlive the state. Without it the
/// environment is empty.
pub fn setEnviron(th: *Thread, map: *const std.process.Environ.Map) Error!void {
    const state = th.state;
    try state.registry.setStr(&state.heap, try state.newString(environ_key), .lightUserdata(@constCast(map)));
}

/// The environment variable `name`, `getenv`.
pub fn getenv(state: *State, name: []const u8) ?[]const u8 {
    const key = state.newString(environ_key) catch return null;
    const v = state.registry.getStr(key);
    if (v.tag != .light_userdata) return null;
    const map: *const std.process.Environ.Map = @ptrCast(@alignCast(v.asLightUserdata().?));
    return map.get(name);
}

fn cstr(s: []const u8) []const u8 {
    return s[0 .. std.mem.findScalar(u8, s, 0) orelse s.len];
}

// ---------------------------------------------------------------------------
// Files and processes
// ---------------------------------------------------------------------------

fn execute(th: *Thread, b: u32) Error!u32 {
    const a = Args.init(th, b, "execute");
    const io = base.getHost(th).io;
    if (a.isNoneOrNil(1)) {
        // `system(NULL)`: whether there is a shell.
        const ok = if (std.Io.Dir.cwd().access(io, "/bin/sh", .{})) true else |_| false;
        th.push(.boolean(ok));
        return 1;
    }
    const cmd = cstr((try a.checkString(1)).bytes());
    const argv: []const []const u8 = &.{ "/bin/sh", "-c", cmd };
    var child = std.process.spawn(io, .{ .argv = argv }) catch |e| return iolib.fileResult(th, e, null);
    const term = child.wait(io) catch |e| return iolib.fileResult(th, e, null);
    return iolib.execResult(th, term);
}

fn remove(th: *Thread, b: u32) Error!u32 {
    const a = Args.init(th, b, "remove");
    const name = try a.checkString(1);
    const io = base.getHost(th).io;
    const path = cstr(name.bytes());
    const cwd = std.Io.Dir.cwd();
    // `remove` unlinks a file and removes an empty directory.
    // For these calls EBUSY is "busy", not a busy executable.
    cwd.deleteFile(io, path) catch |e| switch (e) {
        error.IsDir => cwd.deleteDir(io, path) catch |e2| {
            if (e2 == error.FileBusy) return iolib.fileResultErrno(th, 16, path);
            return iolib.fileResult(th, e2, path);
        },
        error.FileBusy => return iolib.fileResultErrno(th, 16, path),
        else => return iolib.fileResult(th, e, path),
    };
    th.push(.true);
    return 1;
}

fn rename(th: *Thread, b: u32) Error!u32 {
    const a = Args.init(th, b, "rename");
    const from = cstr((try a.checkString(1)).bytes());
    const to = cstr((try a.checkString(2)).bytes());
    const io = base.getHost(th).io;
    const cwd = std.Io.Dir.cwd();
    cwd.rename(from, cwd, to, io) catch |e| return iolib.fileResult(th, e, null);
    th.push(.true);
    return 1;
}

/// A new empty file "/tmp/lua_XXXXXX", as `mkstemp` makes it, still open.
pub fn makeTemp(io: std.Io, name: *[15]u8) !std.Io.File {
    const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    name.* = "/tmp/lua_XXXXXX".*;
    var tries: usize = 0;
    while (true) : (tries += 1) {
        var rnd: [6]u8 = undefined;
        io.random(&rnd);
        for (name[9..], rnd) |*c, r| c.* = chars[r % chars.len];
        const options: std.Io.Dir.CreateFileOptions = .{
            .read = true,
            .exclusive = true,
            .permissions = .fromMode(0o600),
        };
        return std.Io.Dir.cwd().createFile(io, name, options) catch |e| {
            if (e == error.PathAlreadyExists and tries < 100) continue;
            return e;
        };
    }
}

fn tmpname(th: *Thread, b: u32) Error!u32 {
    _ = b;
    const io = base.getHost(th).io;
    var name: [15]u8 = undefined;
    const f = makeTemp(io, &name) catch return aux.raise(th, "unable to generate a unique filename", .{});
    f.close(io);
    th.push(.string(try th.state.newString(&name)));
    return 1;
}

fn getenvFn(th: *Thread, b: u32) Error!u32 {
    const a = Args.init(th, b, "getenv");
    const name = cstr((try a.checkString(1)).bytes());
    const v = getenv(th.state, name);
    th.push(if (v) |s| .string(try th.state.newString(s)) else .nil);
    return 1;
}

fn clock(th: *Thread, b: u32) Error!u32 {
    _ = b;
    const io = base.getHost(th).io;
    const ns = std.Io.Clock.cpu_process.now(io).nanoseconds;
    // `clock()` counts whole microseconds.
    const us: f64 = @floatFromInt(@divTrunc(ns, 1000));
    th.push(.float(us / 1e6));
    return 1;
}

fn setlocale(th: *Thread, b: u32) Error!u32 {
    const a = Args.init(th, b, "setlocale");
    const l: ?[]const u8 = if (a.isNoneOrNil(1)) null else (try a.checkString(1)).bytes();
    const cats = [_][]const u8{ "all", "collate", "ctype", "monetary", "numeric", "time" };
    const cat = try a.optString(2, "all");
    var found = false;
    for (cats) |c| found = found or std.mem.eql(u8, c, cat);
    if (!found) return a.argError(2, "invalid option '{s}'", .{cat[0..@min(cat.len, 80)]});
    // Only the C locale exists: querying, "", "C", and "POSIX" give "C".
    const ok = if (l) |name| name.len == 0 or std.mem.eql(u8, name, "C") or std.mem.eql(u8, name, "POSIX") else true;
    th.push(if (ok) .string(try th.state.newString("C")) else .nil);
    return 1;
}

fn exit(th: *Thread, b: u32) Error!u32 {
    const a = Args.init(th, b, "exit");
    const v = a.get(1);
    const status: i64 = switch (v.tag) {
        .bool_true => 0,
        .bool_false => 1,
        else => try a.optInteger(1, 0),
    };
    // C's `exit` flushes every stream. With `close`, the reference first
    // runs `lua_close`: pending to-be-closed variables and finalizers.
    // TODO(core): that needs a close the running native can call; freeing
    // the state here would free memory its callers still hold. Until then
    // `close` only flushes, which is what finalizers of files would do.
    _ = a.get(2);
    iolib.flushAll(th);
    base.getHost(th).flushStdout();
    std.process.exit(@truncate(@as(u64, @bitCast(status))));
}

// ---------------------------------------------------------------------------
// Broken-down time
// ---------------------------------------------------------------------------

/// C's `struct tm`. `year` counts from 1900 and must fit an `int`.
const Tm = struct {
    sec: i32 = 0,
    min: i32 = 0,
    hour: i32 = 0,
    mday: i32 = 0,
    mon: i32 = 0,
    year: i32 = 0,
    wday: i32 = 0,
    yday: i32 = 0,
    isdst: i32 = 0,
    /// Seconds east of UTC.
    gmtoff: i32 = 0,
    zone: [15]u8 = undefined,
    zone_len: u8 = 0,

    fn zoneName(tm: *const Tm) []const u8 {
        return tm.zone[0..tm.zone_len];
    }
};

/// Days from 1970-01-01 to the given proleptic Gregorian date (month 1-12).
fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp = @mod(m + 9, 12);
    const doy = @divTrunc(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

const Civil = struct { y: i64, m: i64, d: i64 };

fn civilFromDays(z_in: i64) Civil {
    const z = z_in + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divTrunc(doe - @divTrunc(doe, 1460) + @divTrunc(doe, 36524) - @divTrunc(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divTrunc(yoe, 4) - @divTrunc(yoe, 100));
    const mp = @divTrunc(5 * doy + 2, 153);
    const d = doy - @divTrunc(153 * mp + 2, 5) + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{ .y = yoe + era * 400 + @intFromBool(m <= 2), .m = m, .d = d };
}

fn isLeap(y: i64) bool {
    return @mod(y, 4) == 0 and (@mod(y, 100) != 0 or @mod(y, 400) == 0);
}

/// The broken-down time of `t + off`, or null when its year does not fit,
/// as `gmtime` fails with EOVERFLOW.
fn breakDown(t: i64, off: i32) ?Tm {
    const local = std.math.add(i64, t, off) catch return null;
    const days = @divFloor(local, 86400);
    const secs = @mod(local, 86400);
    const c = civilFromDays(days);
    const year = c.y - 1900;
    if (year < std.math.minInt(i32) or year > std.math.maxInt(i32)) return null;
    return .{
        .sec = @intCast(@mod(secs, 60)),
        .min = @intCast(@divTrunc(@mod(secs, 3600), 60)),
        .hour = @intCast(@divTrunc(secs, 3600)),
        .mday = @intCast(c.d),
        .mon = @intCast(c.m - 1),
        .year = @intCast(year),
        .wday = @intCast(@mod(days + 4, 7)),
        .yday = @intCast(days - daysFromCivil(c.y, 1, 1)),
        .gmtoff = off,
    };
}

fn gmtime(t: i64) ?Tm {
    var tm = breakDown(t, 0) orelse return null;
    tm.zone_len = 3;
    @memcpy(tm.zone[0..3], "GMT");
    return tm;
}

fn localtime(zone: *const Zone, t: i64) ?Tm {
    // glibc breaks a time down in UTC first when the zone is a TZ string.
    if (zone.types.len == 0 and breakDown(t, 0) == null) return null;
    const l = zone.lookup(t);
    var tm = breakDown(t, l.off) orelse return null;
    tm.isdst = @intFromBool(l.isdst);
    tm.zone_len = @intCast(@min(l.abbr.len, tm.zone.len));
    @memcpy(tm.zone[0..tm.zone_len], l.abbr[0..tm.zone_len]);
    return tm;
}

/// glibc's `ydhms_diff`: (year1-yday1 hour1:min1:sec1) less (year0-yday0
/// hour0:min0:sec0) in seconds, years counted from 1900 and days from 0.
fn ydhmsDiff(
    year1: i64,
    yday1: i64,
    hour1: i64,
    min1: i64,
    sec1: i64,
    year0: i64,
    yday0: i64,
    hour0: i64,
    min0: i64,
    sec0: i64,
) i64 {
    const days = daysFromCivil(year1 + 1900, 1, 1) + yday1 - (daysFromCivil(year0 + 1900, 1, 1) + yday0);
    return ((days * 24 + hour1 - hour0) * 60 + min1 - min0) * 60 + sec1 - sec0;
}

fn tmDiff(year: i64, yday: i64, hour: i64, min: i64, sec: i64, tm: *const Tm) i64 {
    return ydhmsDiff(year, yday, hour, min, sec, tm.year, tm.yday, tm.hour, tm.min, tm.sec);
}

/// glibc's `ranged_convert`: `localtime(t)`, or of the nearest time
/// toward 0 that has a representable year.
fn rangedConvert(zone: *const Zone, t: *i64) ?Tm {
    if (localtime(zone, t.*)) |tm| return tm;
    var bad = t.*;
    var ok: i64 = 0;
    var oktm: ?Tm = null;
    while (true) {
        const mid = (bad >> 1) + (ok >> 1) + ((bad | ok) & 1);
        if (mid == ok or mid == bad) break;
        if (localtime(zone, mid)) |tm| {
            ok = mid;
            oktm = tm;
        } else bad = mid;
    }
    t.* = ok;
    return oktm;
}

fn isdstDiffer(a: i32, b: i32) bool {
    return (a == 0) != (b == 0) and a >= 0 and b >= 0;
}

const Mktime = struct { t: i64, tm: Tm };

/// `mktime`, glibc's `__mktime_internal`: the time for `tp`'s fields, out of
/// range or not, in `zone`, and the normalized fields. `tp.isdst` positive
/// or zero asks for daylight saving or standard time. `offset` is glibc's
/// remembered guess from the previous call, which decides ambiguous times.
/// Null when the result cannot be represented.
fn mktime(zone: *const Zone, tp: *const Tm, offset: *i64) ?Mktime {
    var remaining_probes: u32 = 6;
    var sec: i64 = tp.sec;
    const min: i64 = tp.min;
    const hour: i64 = tp.hour;
    const isdst = tp.isdst;
    var dst2 = false;
    const mon_rem = @mod(@as(i64, tp.mon), 12);
    const year = @as(i64, tp.year) + @divFloor(@as(i64, tp.mon), 12);
    const mon_yday = daysFromCivil(year + 1900, mon_rem + 1, 1) - daysFromCivil(year + 1900, 1, 1) - 1;
    const yday = mon_yday + tp.mday;
    const sec_requested = sec;
    // Leap seconds are possible: probe with seconds in range.
    sec = std.math.clamp(sec, 0, 59);
    const negative_offset_guess = 0 -% offset.*;
    const t0 = ydhmsDiff(year, yday, hour, min, sec, 70, 0, 0, 0, negative_offset_guess);
    var t = t0;
    var t1 = t0;
    var t2 = t0;
    var tm: Tm = undefined;
    found: {
        while (true) {
            tm = rangedConvert(zone, &t) orelse return null;
            const dt = tmDiff(year, yday, hour, min, sec, &tm);
            if (dt == 0) break;
            // Oscillating between two times: a spring-forward gap.
            const prefer = if (isdst < 0)
                @intFromBool(dst2) <= @intFromBool(tm.isdst != 0)
            else
                (isdst != 0) != (tm.isdst != 0);
            if (t == t1 and t != t2 and (tm.isdst < 0 or prefer)) break :found;
            remaining_probes -= 1;
            if (remaining_probes == 0) return null;
            t1 = t2;
            t2 = t;
            t += dt;
            dst2 = tm.isdst != 0;
        }
        if (isdstDiffer(isdst, tm.isdst)) {
            const dst_difference: i64 = @as(i64, @intFromBool(isdst == 0)) - @intFromBool(tm.isdst == 0);
            const stride = 601200;
            const delta_bound = 457243209 / 2 + stride;
            var delta: i64 = stride;
            while (delta < delta_bound) : (delta += stride) {
                for ([_]i64{ -1, 1 }) |direction| {
                    var ot = std.math.add(i64, t, delta * direction) catch continue;
                    const otm = rangedConvert(zone, &ot) orelse return null;
                    if (!isdstDiffer(isdst, otm.isdst)) {
                        const gt = ot + tmDiff(year, yday, hour, min, sec, &otm);
                        if (localtime(zone, gt)) |g| {
                            t = gt;
                            tm = g;
                            break :found;
                        }
                    }
                }
            }
            t += 60 * 60 * dst_difference;
            tm = localtime(zone, t) orelse return null;
        }
    }
    offset.* = (t -% t0) -% negative_offset_guess;
    if (sec_requested != tm.sec) {
        const adjust = @as(i64, @intFromBool(sec == 0 and tm.sec == 60)) - sec + sec_requested;
        t = std.math.add(i64, t, adjust) catch return null;
        tm = localtime(zone, t) orelse return null;
    }
    return .{ .t = t, .tm = tm };
}

// ---------------------------------------------------------------------------
// Time zones
// ---------------------------------------------------------------------------

const Local = struct { off: i32, isdst: bool, abbr: []const u8 };

/// A POSIX TZ rule, such as "CST6CDT,M3.2.0,M11.1.0".
const Rule = struct {
    std_name: []const u8,
    std_off: i32,
    dst: ?struct {
        name: []const u8,
        off: i32,
        start: Date,
        end: Date,
    } = null,

    const Date = struct {
        kind: enum { julian1, julian0, mwd },
        n: i32 = 0,
        m: i32 = 0,
        w: i32 = 0,
        d: i32 = 0,
        time: i32 = 7200,

        /// glibc's `compute_change`: when this date's change happens in
        /// `year`, for a zone at `off` seconds east before it. Faithful to
        /// glibc's `int` arithmetic, which wraps past year 5,800,000, and
        /// to its counting from 1970 for earlier years.
        fn change(dt: Date, year: i32, off: i32) i64 {
            var t: i64 = 0;
            if (year > 1970) {
                const days = (year -% 1970) *% 365 +%
                    (@divTrunc(year - 1, 4) - 1970 / 4) -%
                    (@divTrunc(year - 1, 100) - 1970 / 100) +%
                    (@divTrunc(year - 1, 400) - 1970 / 400);
                t = @as(i64, days) * 86400;
            }
            const leap = @rem(year, 4) == 0 and (@rem(year, 100) != 0 or @rem(year, 400) == 0);
            switch (dt.kind) {
                .julian1 => {
                    t += @as(i64, dt.n - 1) * 86400;
                    if (dt.n >= 60 and leap) t += 86400;
                },
                .julian0 => t += @as(i64, dt.n) * 86400,
                .mwd => {
                    const cum = [_]i32{ 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334, 365 };
                    const m: usize = @intCast(dt.m);
                    const before = cum[m - 1] + @intFromBool(leap and m > 2);
                    const mdays = cum[m] - cum[m - 1] + @intFromBool(leap and m == 2);
                    t += @as(i64, before) * 86400;
                    // Zeller's congruence for the first day of the month.
                    const m1 = @rem(dt.m + 9, 12) + 1;
                    const yy0 = if (dt.m <= 2) year -% 1 else year;
                    const yy1 = @divTrunc(yy0, 100);
                    const yy2 = @rem(yy0, 100);
                    const z = @divTrunc(26 * m1 - 2, 10) + 1 + yy2 + @divTrunc(yy2, 4) + @divTrunc(yy1, 4) - 2 * yy1;
                    var dow = @rem(z, 7);
                    if (dow < 0) dow += 7;
                    var d = dt.d - dow;
                    if (d < 0) d += 7;
                    var i: i32 = 1;
                    while (i < dt.w) : (i += 1) {
                        if (d + 7 >= mdays) break;
                        d += 7;
                    }
                    t += @as(i64, d) * 86400;
                },
            }
            return t - off + dt.time;
        }
    };

    /// glibc's `__tz_compute`, which takes the year from UTC.
    fn lookup(r: *const Rule, t: i64) Local {
        const std_local: Local = .{ .off = r.std_off, .isdst = false, .abbr = r.std_name };
        const dst = r.dst orelse return std_local;
        const utc = breakDown(t, 0) orelse return std_local;
        const year = 1900 +% utc.year;
        const c0 = dst.start.change(year, r.std_off);
        const c1 = dst.end.change(year, dst.off);
        const in_dst = if (c0 > c1) (t < c1 or t >= c0) else (t >= c0 and t < c1);
        return if (in_dst) .{ .off = dst.off, .isdst = true, .abbr = dst.name } else std_local;
    }

    /// Parses a POSIX TZ string; null when it is not one.
    fn parse(s: []const u8) ?Rule {
        var p: Parser = .{ .s = s };
        var r: Rule = .{ .std_name = p.name() orelse return null, .std_off = -(p.offset() orelse return null) };
        if (p.i == s.len) return r;
        const dst_name = p.name() orelse return null;
        var dst_off = r.std_off + 3600;
        if (p.i < s.len and s[p.i] != ',') dst_off = -(p.offset() orelse return null);
        var start: Date = .{ .kind = .mwd, .m = 3, .w = 2, .d = 0 };
        var end: Date = .{ .kind = .mwd, .m = 11, .w = 1, .d = 0 };
        if (p.i < s.len) {
            if (!p.eat(',')) return null;
            start = p.date() orelse return null;
            if (!p.eat(',')) return null;
            end = p.date() orelse return null;
            if (p.i != s.len) return null;
        }
        r.dst = .{ .name = dst_name, .off = dst_off, .start = start, .end = end };
        return r;
    }

    const Parser = struct {
        s: []const u8,
        i: usize = 0,

        fn eat(p: *Parser, c: u8) bool {
            if (p.i < p.s.len and p.s[p.i] == c) {
                p.i += 1;
                return true;
            }
            return false;
        }

        fn name(p: *Parser) ?[]const u8 {
            if (p.eat('<')) {
                const start = p.i;
                while (p.i < p.s.len and p.s[p.i] != '>') p.i += 1;
                const n = p.s[start..p.i];
                if (!p.eat('>') or n.len < 3) return null;
                return n;
            }
            const start = p.i;
            while (p.i < p.s.len and std.ascii.isAlphabetic(p.s[p.i])) p.i += 1;
            if (p.i - start < 3) return null;
            return p.s[start..p.i];
        }

        fn num(p: *Parser, max: i32) ?i32 {
            const start = p.i;
            var v: i32 = 0;
            while (p.i < p.s.len and std.ascii.isDigit(p.s[p.i]) and p.i - start < 3) : (p.i += 1) {
                v = v * 10 + p.s[p.i] - '0';
            }
            if (p.i == start or v > max) return null;
            return v;
        }

        /// [+-]hh[:mm[:ss]] in seconds.
        fn offset(p: *Parser) ?i32 {
            var sign: i32 = 1;
            if (p.eat('-')) sign = -1 else _ = p.eat('+');
            var v = (p.num(167) orelse return null) * 3600;
            if (p.eat(':')) {
                v += (p.num(59) orelse return null) * 60;
                if (p.eat(':')) v += p.num(59) orelse return null;
            }
            return sign * v;
        }

        fn date(p: *Parser) ?Date {
            var d: Date = undefined;
            if (p.eat('J')) {
                d = .{ .kind = .julian1, .n = p.num(365) orelse return null };
                if (d.n < 1) return null;
            } else if (p.eat('M')) {
                d = .{ .kind = .mwd, .m = p.num(12) orelse return null };
                if (!p.eat('.')) return null;
                d.w = p.num(5) orelse return null;
                if (!p.eat('.')) return null;
                d.d = p.num(6) orelse return null;
                if (d.m < 1 or d.w < 1) return null;
            } else {
                d = .{ .kind = .julian0, .n = p.num(365) orelse return null };
            }
            d.time = 7200;
            if (p.eat('/')) d.time = p.offset() orelse return null;
            return d;
        }
    };
};

/// The local time zone: a TZif file's transitions with its footer rule for
/// later times, a POSIX rule, or UTC.
const Zone = struct {
    /// The TZif file, owned.
    data: ?[]u8 = null,
    times: []const u8 = &.{},
    time_size: usize = 8,
    indices: []const u8 = &.{},
    types: []const u8 = &.{},
    chars: []const u8 = &.{},
    rule: ?Rule = null,
    utc_name: []const u8 = "UTC",

    fn deinit(z: *Zone, gpa: std.mem.Allocator) void {
        if (z.data) |d| gpa.free(d);
        z.* = undefined;
    }

    fn ntimes(z: *const Zone) usize {
        return z.times.len / z.time_size;
    }

    fn timeAt(z: *const Zone, i: usize) i64 {
        const p = z.times[i * z.time_size ..];
        return if (z.time_size == 8) std.mem.readInt(i64, p[0..8], .big) else std.mem.readInt(i32, p[0..4], .big);
    }

    fn timetype(z: *const Zone, i: usize) Local {
        const t = z.types[@min(i, z.types.len / 6 - 1) * 6 ..][0..6];
        const ai = @min(t[5], z.chars.len);
        return .{
            .off = std.mem.readInt(i32, t[0..4], .big),
            .isdst = t[4] != 0,
            .abbr = cstr(z.chars[ai..]),
        };
    }

    /// The index of the last transition at or before `t`.
    fn transitionBefore(z: *const Zone, t: i64) ?usize {
        var lo: usize = 0;
        var hi = z.ntimes();
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (z.timeAt(mid) <= t) lo = mid + 1 else hi = mid;
        }
        return if (lo == 0) null else lo - 1;
    }

    /// glibc's `__tzfile_compute` for a TZif file: before the first
    /// transition the first standard time type, after the last the footer
    /// rule.
    fn lookup(z: *const Zone, t: i64) Local {
        if (z.types.len == 0) {
            if (z.rule) |*r| return r.lookup(t);
            return .{ .off = 0, .isdst = false, .abbr = z.utc_name };
        }
        const n = z.ntimes();
        const i = (if (n == 0) null else z.transitionBefore(t)) orelse {
            const ntypes = z.types.len / 6;
            var k: usize = 0;
            while (k < ntypes and z.timetype(k).isdst) k += 1;
            return z.timetype(if (k == ntypes) 0 else k);
        };
        if (i == n - 1) if (z.rule) |*r| {
            if (breakDown(t, 0) != null) return r.lookup(t);
        };
        return z.timetype(z.indices[i]);
    }

    /// Reads a TZif file (RFC 8536); false when it is not one.
    fn parseTzif(z: *Zone, d: []const u8) bool {
        if (d.len < 44 or !std.mem.eql(u8, d[0..4], "TZif")) return false;
        var off: usize = 0;
        var hdr = d[0..44];
        var tsize: usize = 4;
        if (d[4] >= '2') {
            off = 44 + blockLen(hdr, 4);
            if (d.len < off + 44 or !std.mem.eql(u8, d[off..][0..4], "TZif")) return false;
            hdr = d[off..][0..44];
            tsize = 8;
        }
        const cnt = struct {
            fn at(h: *const [44]u8, i: usize) usize {
                return std.mem.readInt(u32, h[20 + 4 * i ..][0..4], .big);
            }
        }.at;
        const timecnt = cnt(hdr, 3);
        const typecnt = cnt(hdr, 4);
        const charcnt = cnt(hdr, 5);
        const start = off + 44;
        const end = start + blockLen(hdr, tsize);
        if (typecnt == 0 or d.len < end) return false;
        z.time_size = tsize;
        z.times = d[start..][0 .. timecnt * tsize];
        z.indices = d[start + timecnt * tsize ..][0..timecnt];
        for (z.indices) |ix| if (ix >= typecnt) return false;
        z.types = d[start + timecnt * (tsize + 1) ..][0 .. typecnt * 6];
        z.chars = d[start + timecnt * (tsize + 1) + typecnt * 6 ..][0..charcnt];
        if (tsize == 8 and end < d.len and d[end] == '\n') {
            const fend = std.mem.findScalarPos(u8, d, end + 1, '\n') orelse d.len;
            z.rule = Rule.parse(d[end + 1 .. fend]);
        }
        return true;
    }

    fn blockLen(h: *const [44]u8, tsize: usize) usize {
        const c = struct {
            fn at(hh: *const [44]u8, i: usize) usize {
                return std.mem.readInt(u32, hh[20 + 4 * i ..][0..4], .big);
            }
        }.at;
        return c(h, 3) * (tsize + 1) + c(h, 4) * 6 + c(h, 5) + c(h, 2) * (tsize + 4) + c(h, 1) + c(h, 0);
    }
};

/// The local zone, as glibc's `tzset` finds it.
const zoneinfo = "/usr/share/zoneinfo";

fn loadZone(th: *Thread) Zone {
    const state = th.state;
    const io = base.getHost(th).io;
    const gpa = state.heap.allocator();
    var z: Zone = .{};
    const env = getenv(state, "TZ");
    var spec = env orelse "/etc/localtime";
    if (spec.len == 0) return z;
    const colon = spec[0] == ':';
    if (colon) spec = spec[1..];
    var path_buf: [4096]u8 = undefined;
    const path = if (spec.len > 0 and spec[0] == '/')
        spec
    else
        std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ getenv(state, "TZDIR") orelse zoneinfo, spec }) catch spec;
    if (std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20))) |data| {
        z.data = data;
        if (z.parseTzif(data)) return z;
        z.deinit(gpa);
        z = .{};
    } else |_| {}
    if (env == null) return z;
    if (!colon) {
        if (Rule.parse(spec)) |r| {
            z.rule = r;
            return z;
        }
    }
    // Otherwise glibc uses UTC, named by the leading name if it has one.
    var n: usize = 0;
    while (n < spec.len and std.ascii.isAlphabetic(spec[n])) n += 1;
    z.utc_name = if (n >= 3) spec[0..n] else "";
    return z;
}

// ---------------------------------------------------------------------------
// strftime
// ---------------------------------------------------------------------------

/// `LUA_STRFTIMEOPTIONS` for C99: the one-character conversions, then the
/// two-character ones after "||".
const one_char_options = "aAbBcCdDeFgGhHIjmMnprRStTuUVwWxXyYzZ%";
const two_char_options = "EcECExEXEyEY" ++ "OdOeOHOIOmOMOSOuOUOVOwOWOy";

const day_names = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
const month_names = [_][]const u8{
    "January", "February", "March",     "April",   "May",      "June",
    "July",    "August",   "September", "October", "November", "December",
};

/// glibc's `iso_week_days`: days since the start of the ISO week-based
/// year's first week.
fn isoWeekDays(yday: i64, wday: i64) i64 {
    const big = (366 / 7 + 2) * 7;
    return yday - @mod(yday - wday + 4 + big, 7) + 4 - 1;
}

const IsoWeek = struct { year: i64, days: i64 };

fn isoWeek(tm: *const Tm) IsoWeek {
    var year: i64 = @as(i64, tm.year) + 1900;
    var days = isoWeekDays(tm.yday, tm.wday);
    if (days < 0) {
        year -= 1;
        days = isoWeekDays(@as(i64, tm.yday) + 365 + @intFromBool(isLeap(year)), tm.wday);
    } else {
        const d = isoWeekDays(@as(i64, tm.yday) - 365 - @intFromBool(isLeap(year)), tm.wday);
        if (d >= 0) {
            year += 1;
            days = d;
        }
    }
    return .{ .year = year, .days = days };
}

fn name3(names: []const []const u8, i: i32) []const u8 {
    return if (i >= 0 and i < names.len) names[@intCast(i)][0..3] else "?";
}

fn fullName(names: []const []const u8, i: i32) []const u8 {
    return if (i >= 0 and i < names.len) names[@intCast(i)] else "?";
}

/// Writes one conversion, `c` with its modifier already dropped, as glibc's
/// `strftime` does in the C locale.
fn formatOne(w: *Writer, c: u8, tm: *const Tm) Writer.Error!void {
    const year: i64 = @as(i64, tm.year) + 1900;
    switch (c) {
        'a' => try w.writeAll(name3(&day_names, tm.wday)),
        'A' => try w.writeAll(fullName(&day_names, tm.wday)),
        'b', 'h' => try w.writeAll(name3(&month_names, tm.mon)),
        'B' => try w.writeAll(fullName(&month_names, tm.mon)),
        'c' => try formatAll(w, "%a %b %e %H:%M:%S %Y", tm),
        'C' => try w.print("{d}", .{@divFloor(year, 100)}),
        'd' => try w.print("{d:0>2}", .{@as(u32, @intCast(@mod(tm.mday, 100)))}),
        'D', 'x' => try formatAll(w, "%m/%d/%y", tm),
        'e' => try w.print("{d: >2}", .{@as(u32, @intCast(@mod(tm.mday, 100)))}),
        'F' => try formatAll(w, "%Y-%m-%d", tm),
        'g' => try w.print("{d:0>2}", .{@as(u32, @intCast(@mod(isoWeek(tm).year, 100)))}),
        'G' => try w.print("{d}", .{isoWeek(tm).year}),
        'H' => try w.print("{d:0>2}", .{@as(u32, @intCast(tm.hour))}),
        'I' => try w.print("{d:0>2}", .{@as(u32, @intCast(if (@mod(tm.hour, 12) == 0) 12 else @mod(tm.hour, 12)))}),
        'j' => try w.print("{d:0>3}", .{@as(u32, @intCast(tm.yday + 1))}),
        'm' => try w.print("{d:0>2}", .{@as(u32, @intCast(tm.mon + 1))}),
        'M' => try w.print("{d:0>2}", .{@as(u32, @intCast(tm.min))}),
        'n' => try w.writeByte('\n'),
        'p' => try w.writeAll(if (tm.hour >= 12) "PM" else "AM"),
        'r' => try formatAll(w, "%I:%M:%S %p", tm),
        'R' => try formatAll(w, "%H:%M", tm),
        'S' => try w.print("{d:0>2}", .{@as(u32, @intCast(tm.sec))}),
        't' => try w.writeByte('\t'),
        'T', 'X' => try formatAll(w, "%H:%M:%S", tm),
        'u' => try w.print("{d}", .{if (tm.wday == 0) 7 else tm.wday}),
        'U' => try w.print("{d:0>2}", .{@as(u32, @intCast(@divTrunc(tm.yday - tm.wday + 7, 7)))}),
        'V' => try w.print("{d:0>2}", .{@as(u32, @intCast(@divTrunc(isoWeek(tm).days, 7) + 1))}),
        'w' => try w.print("{d}", .{tm.wday}),
        'W' => try w.print("{d:0>2}", .{@as(u32, @intCast(@divTrunc(tm.yday - @mod(tm.wday - 1 + 7, 7) + 7, 7)))}),
        'y' => try w.print("{d:0>2}", .{@as(u32, @intCast(@mod(year, 100)))}),
        'Y' => try w.print("{d}", .{year}),
        'z' => {
            const off = @divTrunc(tm.gmtoff, 60);
            const a: u32 = @abs(off);
            try w.print("{c}{d:0>4}", .{ @as(u8, if (off < 0) '-' else '+'), a / 60 * 100 + a % 60 });
        },
        'Z' => try w.writeAll(tm.zoneName()),
        '%' => try w.writeByte('%'),
        else => unreachable,
    }
}

/// Formats a fixed format of valid conversions.
fn formatAll(w: *Writer, comptime fmt: []const u8, tm: *const Tm) Writer.Error!void {
    comptime var i = 0;
    inline while (i < fmt.len) : (i += 1) {
        if (fmt[i] == '%') {
            i += 1;
            try formatOne(w, fmt[i], tm);
        } else {
            try w.writeByte(fmt[i]);
        }
    }
}

/// The length of the valid conversion at the start of `conv`, `checkoption`.
fn conversionLength(conv: []const u8) ?usize {
    if (conv.len >= 1 and std.mem.findScalar(u8, one_char_options, conv[0]) != null) return 1;
    if (conv.len >= 2) {
        var i: usize = 0;
        while (i < two_char_options.len) : (i += 2) {
            if (std.mem.eql(u8, two_char_options[i..][0..2], conv[0..2])) return 2;
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// date and time
// ---------------------------------------------------------------------------

/// `l_checktime`: time_t is 64-bit, so every integer fits.
fn checkTime(a: Args, n: u32) Error!i64 {
    return a.checkInteger(n);
}

fn now(th: *Thread) i64 {
    const io = base.getHost(th).io;
    return @intCast(@divFloor(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_s));
}

fn setAllFields(th: *Thread, t: Value, tm: *const Tm, days: bool) Error!void {
    const state = th.state;
    const fields = .{
        .{ "year", @as(i64, tm.year) + 1900 }, .{ "month", @as(i64, tm.mon) + 1 },
        .{ "day", @as(i64, tm.mday) },         .{ "hour", @as(i64, tm.hour) },
        .{ "min", @as(i64, tm.min) },          .{ "sec", @as(i64, tm.sec) },
    };
    inline for (fields) |f| try aux.setIndex(th, t, .string(try state.newString(f[0])), .int(f[1]));
    if (days) {
        try aux.setIndex(th, t, .string(try state.newString("yday")), .int(@as(i64, tm.yday) + 1));
        try aux.setIndex(th, t, .string(try state.newString("wday")), .int(@as(i64, tm.wday) + 1));
    }
    if (tm.isdst >= 0) try aux.setIndex(th, t, .string(try state.newString("isdst")), .boolean(tm.isdst != 0));
}

const unrepresentable_date = "date result cannot be represented in this installation";

fn date(th: *Thread, b: u32) Error!u32 {
    const a = Args.init(th, b, "date");
    var s = try a.optString(1, "%c");
    const t = if (a.isNoneOrNil(2)) now(th) else try checkTime(a, 2);
    var tm: Tm = undefined;
    if (s.len > 0 and s[0] == '!') {
        tm = gmtime(t) orelse return aux.raise(th, unrepresentable_date, .{});
        s = s[1..];
    } else {
        var zone = loadZone(th);
        defer zone.deinit(th.state.heap.allocator());
        tm = localtime(&zone, t) orelse return aux.raise(th, unrepresentable_date, .{});
    }
    if (std.mem.eql(u8, cstr(s), "*t")) {
        const tbl = try th.state.newTable(0, 9);
        th.push(.table(tbl));
        try setAllFields(th, .table(tbl), &tm, true);
        return 1;
    }
    var buf: aux.Buffer = undefined;
    buf.init(th.state);
    defer buf.deinit();
    const w = &buf.writer;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] != '%') {
            w.writeByte(s[i]) catch return error.OutOfMemory;
            i += 1;
            continue;
        }
        i += 1;
        const conv = s[i..];
        const n = conversionLength(conv) orelse {
            return aux.raise(th, "bad argument #1 to 'date' (invalid conversion specifier '%{s}')", .{cstr(conv)});
        };
        formatOne(w, conv[n - 1], &tm) catch return error.OutOfMemory;
        i += n;
    }
    th.push(.string(try buf.toString(th.state)));
    return 1;
}

/// `getfield`: an integer field of the date table, less `delta`, which
/// must fit an `int`.
fn getField(th: *Thread, t: Value, comptime key: []const u8, d: i32, delta: i32) Error!i32 {
    const v = try aux.index(th, t, .string(try th.state.newString(key)));
    const res = aux.toInteger(v) orelse {
        if (!v.isNil()) return aux.raise(th, "field '{s}' is not an integer", .{key});
        if (d < 0) return aux.raise(th, "field '{s}' missing in date table", .{key});
        return d;
    };
    const ok = if (res >= 0) res - delta <= std.math.maxInt(i32) else @as(i64, std.math.minInt(i32)) + delta <= res;
    if (!ok) return aux.raise(th, "field '{s}' is out-of-bound", .{key});
    return @intCast(res - delta);
}

fn time(th: *Thread, b: u32) Error!u32 {
    const a = Args.init(th, b, "time");
    if (a.isNoneOrNil(1)) {
        th.push(.int(now(th)));
        return 1;
    }
    _ = try a.checkTable(1);
    th.top = b + 1;
    const t = th.stack[b];
    var tm: Tm = .{};
    tm.year = try getField(th, t, "year", -1, 1900);
    tm.mon = try getField(th, t, "month", -1, 1);
    tm.mday = try getField(th, t, "day", -1, 0);
    tm.hour = try getField(th, t, "hour", 12, 0);
    tm.min = try getField(th, t, "min", 0, 0);
    tm.sec = try getField(th, t, "sec", 0, 0);
    const isdst = try aux.index(th, t, .string(try th.state.newString("isdst")));
    tm.isdst = if (isdst.isNil()) -1 else @intFromBool(!isdst.isFalsy());
    var zone = loadZone(th);
    defer zone.deinit(th.state.heap.allocator());
    // glibc keeps its guess in a static; here the state keeps it.
    const state = th.state;
    const key = try state.newString("_OS_MKTIME_OFFSET");
    const saved = state.registry.getStr(key);
    var offset: i64 = if (saved.tag == .int) saved.asInt() else 0;
    const result = mktime(&zone, &tm, &offset);
    try state.registry.setStr(&state.heap, key, .int(offset));
    // C writes the fields back before checking: unchanged when `mktime`
    // failed, except `yday` and `wday`, which it leaves unset.
    const r = result orelse {
        try setAllFields(th, t, &tm, false);
        return aux.raise(th, "time result cannot be represented in this installation", .{});
    };
    try setAllFields(th, t, &r.tm, true);
    if (r.t == -1) return aux.raise(th, "time result cannot be represented in this installation", .{});
    th.push(.int(r.t));
    return 1;
}

fn difftime(th: *Thread, b: u32) Error!u32 {
    const a = Args.init(th, b, "difftime");
    const t1 = try checkTime(a, 1);
    const t2 = try checkTime(a, 2);
    th.push(.float(@floatFromInt(@as(i128, t1) - t2)));
    return 1;
}

/// Opens the library into the global `os`.
pub fn open(th: *Thread) Error!void {
    const state = th.state;
    const t = try aux.newLib(state, .{
        .{ "clock", &clock },
        .{ "date", &date },
        .{ "difftime", &difftime },
        .{ "execute", &execute },
        .{ "exit", &exit },
        .{ "getenv", &getenvFn },
        .{ "remove", &remove },
        .{ "rename", &rename },
        .{ "setlocale", &setlocale },
        .{ "time", &time },
        .{ "tmpname", &tmpname },
    });
    try aux.setField(state, state.globals, "os", .table(t));
}

test "date and time in a TZ string's zone, mktime's normalization, and errors" {
    // Expected values from the reference, run with this TZ.
    try package.testing.expectChunk(&.{.{ "TZ", "CST6CDT,M3.2.0,M11.1.0" }},
        \\-- TZ=CST6CDT,M3.2.0,M11.1.0
        \\assert(os.date("!%Y-%m-%d %H:%M:%S %Z %z|%a %A %b %B|%j %U %W %V %G %g|%c", 0) ==
        \\  "1970-01-01 00:00:00 GMT +0000|Thu Thursday Jan January|001 00 00 01 1970 70|Thu Jan  1 00:00:00 1970")
        \\assert(os.date("%c %Z %z", 1710057600) == "Sun Mar 10 03:00:00 2024 CDT -0500")
        \\assert(os.date("%c %Z %z", 1710053999) == "Sun Mar 10 00:59:59 2024 CST -0600")
        \\assert(os.date("!%Y|%C|%y|%G|%g|%F", os.time{year = -5, month = 1, day = 1}) == "-5|-1|95|-6|94|-5-01-01")
        \\local d = os.date("*t", 1730617200)
        \\assert(d.year == 2024 and d.month == 11 and d.day == 3 and d.hour == 1)
        \\assert(d.isdst == false and d.yday == 308 and d.wday == 1)
        \\-- mktime normalizes the table
        \\local t = {year = 2005, month = 1, day = 1, hour = 1, min = 0, sec = -3602}
        \\assert(os.time(t) == 1104559198)
        \\assert(t.year == 2004 and t.month == 12 and t.day == 31 and t.hour == 23 and t.min == 59)
        \\assert(t.sec == 58 and t.yday == 366 and t.isdst == false)
        \\-- a time in the spring-forward gap, and the isdst hint
        \\assert(os.time{year = 2024, month = 3, day = 10, hour = 2, min = 30} == 1710059400)
        \\assert(os.time{year = 2024, month = 7, day = 1, hour = 12, isdst = false} == 1719856800)
        \\assert(os.time{year = 2024, month = 1, day = 1, hour = 12, isdst = true} == 1704128400)
        \\assert(os.time{year = 2000, month = 14, day = -40, hour = 50, min = -70, sec = 100000} == 977740600)
        \\local function fails(msg, f, ...) return select(2, pcall(f, ...)):find(msg, 1, true) end
        \\local max = {year = 2147485547, month = 12, day = 31, hour = 23, min = 59, sec = 59}
        \\assert(fails("cannot be represented", os.time, max))
        \\assert(fails("field 'year' is out-of-bound", os.time, {year = 2^31 + 1900, month = 1, day = 1}))
        \\assert(fails("invalid conversion specifier '%Ea'", os.date, "%Ea"))
        \\assert(fails("field 'year' missing in date table", os.time, {hour = 12}))
        \\assert(fails("field 'min' is not an integer", os.time, {year = 1, month = 1, day = 1, min = 1.5}))
        \\assert(fails("field 'year' is out-of-bound", os.time, {year = -2^31 + 1899, month = 1, day = 1}))
        \\assert(fails("cannot be represented", os.date, "%Y", 2^60))
        \\assert(os.date(string.rep("%", 6), 0) == "%%%")
        \\assert(os.getenv("TZ") == "CST6CDT,M3.2.0,M11.1.0" and os.getenv("NOT_SET") == nil)
        \\assert(os.setlocale() == "C" and os.setlocale("POSIX") == "C" and os.setlocale("fr_FR") == nil)
        \\assert(os.difftime(1, 3) == -2.0 and math.type(os.difftime(1, 3)) == "float")
        \\return true
    );
}

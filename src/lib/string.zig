//! The string library, the reference manual's §6.5: the natives around the
//! engines in `pattern.zig`, `format.zig`, and `pack.zig`, with lstrlib.c's
//! argument checks and messages, and the string metatable: `__index` is the
//! library, and the arithmetic metamethods convert numeric strings (§3.4.3).
//!
//! The glue allocates only the strings the language creates: results are
//! built in an `auxlib.Buffer`, which starts on the Zig stack, or written
//! straight into a new string when their length is known.

const std = @import("std");
const Writer = std.Io.Writer;
const Value = @import("../Value.zig");
const Thread = @import("../Thread.zig");
const State = @import("../State.zig");
const Proto = @import("../Proto.zig");
const Userdata = @import("../Userdata.zig");
const vm = @import("../vm.zig");
const number = @import("../number.zig");
const auxlib = @import("auxlib.zig");
const libm = @import("libm.zig");
const pattern = @import("pattern.zig");
const fmt_engine = @import("format.zig");
const pack_engine = @import("pack.zig");
const dump_engine = @import("../dump.zig");

const Error = Value.Error;
const Args = auxlib.Args;
const raise = auxlib.raise;

/// The largest string, `MAX_SIZE`: `size_t` is as wide as a Lua integer.
const max_size: u64 = std.math.maxInt(i64);

/// Creates the `string` table, sets the global, and makes the string
/// metatable.
pub fn open(state: *State) Error!void {
    const lib = try auxlib.newLib(state, .{
        .{ "byte", byte },
        .{ "char", char },
        .{ "dump", dump },
        .{ "find", find },
        .{ "format", format },
        .{ "gmatch", gmatch },
        .{ "gsub", gsub },
        .{ "len", len },
        .{ "lower", lower },
        .{ "match", match },
        .{ "rep", rep },
        .{ "reverse", reverse },
        .{ "sub", sub },
        .{ "upper", upper },
        .{ "pack", pack },
        .{ "packsize", packsize },
        .{ "unpack", unpack },
    });
    try auxlib.setField(state, state.globals, "string", .table(lib));
    const mt = try auxlib.newLib(state, .{
        .{ "__add", arithFn(.add) },
        .{ "__sub", arithFn(.sub) },
        .{ "__mul", arithFn(.mul) },
        .{ "__mod", arithFn(.mod) },
        .{ "__pow", arithFn(.pow) },
        .{ "__div", arithFn(.div) },
        .{ "__idiv", arithFn(.idiv) },
        .{ "__unm", arithFn(.unm) },
    });
    try auxlib.setField(state, mt, "__index", .table(lib));
    state.metatables[@intFromEnum(Value.Type.string)] = mt;
}

/// `posrelatI`: a 1-based start position, negative from the end, clipped
/// to [1, inf).
fn posrelatI(pos: i64, n: usize) usize {
    if (pos > 0) return @intCast(pos);
    if (pos == 0) return 1;
    if (pos < -@as(i64, @intCast(n))) return 1;
    return n - @as(usize, @intCast(-pos)) + 1;
}

/// `getendpos`: an optional end position, negative from the end, clipped
/// to [0, len].
fn getEndPos(a: Args, arg: u32, def: i64, n: usize) Error!usize {
    const pos = try a.optInteger(arg, def);
    const l: i64 = @intCast(n);
    if (pos > l) return n;
    if (pos >= 0) return @intCast(pos);
    if (pos < -l) return 0;
    return n - @as(usize, @intCast(-pos)) + 1;
}

fn pushString(th: *Thread, b: []const u8) Error!void {
    th.push(.string(try th.state.newString(b)));
}

fn len(th: *Thread, base: u32) Error!u32 {
    const a: Args = .init(th, base, "len");
    th.push(.int(@intCast((try a.checkString(1)).len)));
    return 1;
}

fn sub(th: *Thread, base: u32) Error!u32 {
    const a: Args = .init(th, base, "sub");
    const s = (try a.checkString(1)).bytes();
    const start = posrelatI(try a.checkInteger(2), s.len);
    const end = try getEndPos(a, 3, -1, s.len);
    try pushString(th, if (start <= end) s[start - 1 .. end] else "");
    return 1;
}

/// A string as long as argument 1, each byte mapped by `f` (`reverse` maps
/// positions instead).
fn mapBytes(th: *Thread, base: u32, comptime name: []const u8, comptime f: anytype) Error!u32 {
    const a: Args = .init(th, base, name);
    const s = (try a.checkString(1)).bytes();
    var sb: auxlib.Sized = undefined;
    const out = try sb.init(th.state, s.len);
    f(out, s);
    th.push(.string(try sb.finish(th.state)));
    return 1;
}

fn reverse(th: *Thread, base: u32) Error!u32 {
    return mapBytes(th, base, "reverse", struct {
        fn f(out: []u8, s: []const u8) void {
            for (out, 0..) |*c, i| c.* = s[s.len - 1 - i];
        }
    }.f);
}

fn lower(th: *Thread, base: u32) Error!u32 {
    return mapBytes(th, base, "lower", struct {
        fn f(out: []u8, s: []const u8) void {
            for (out, s) |*c, x| c.* = std.ascii.toLower(x);
        }
    }.f);
}

fn upper(th: *Thread, base: u32) Error!u32 {
    return mapBytes(th, base, "upper", struct {
        fn f(out: []u8, s: []const u8) void {
            for (out, s) |*c, x| c.* = std.ascii.toUpper(x);
        }
    }.f);
}

fn rep(th: *Thread, base: u32) Error!u32 {
    const a: Args = .init(th, base, "rep");
    const s = (try a.checkString(1)).bytes();
    const n = try a.checkInteger(2);
    const sep = try a.optString(3, "");
    if (n <= 0 or (s.len | sep.len) == 0) {
        try pushString(th, "");
        return 1;
    }
    const un: u64 = @intCast(n);
    if (s.len > max_size - sep.len or s.len + sep.len > max_size / un)
        return raise(th, "resulting string too large", .{});
    const total = un * (s.len + sep.len) - sep.len;
    var sb: auxlib.Sized = undefined;
    const out = try sb.init(th.state, total);
    if (s.len == 1 and sep.len == 0) {
        @memset(out, s[0]);
    } else {
        var p: usize = 0;
        var i: u64 = 1;
        while (i < un) : (i += 1) {
            @memcpy(out[p..][0..s.len], s);
            p += s.len;
            @memcpy(out[p..][0..sep.len], sep);
            p += sep.len;
        }
        @memcpy(out[p..][0..s.len], s);
    }
    th.push(.string(try sb.finish(th.state)));
    return 1;
}

fn byte(th: *Thread, base: u32) Error!u32 {
    const a: Args = .init(th, base, "byte");
    const s = (try a.checkString(1)).bytes();
    const pi = try a.optInteger(2, 1);
    const posi = posrelatI(pi, s.len);
    const pose = try getEndPos(a, 3, pi, s.len);
    if (posi > pose) return 0;
    if (pose - posi >= std.math.maxInt(i32)) return raise(th, "string slice too long", .{});
    const n = pose - posi + 1;
    try auxlib.checkStack(th, n, "string slice too long");
    for (s[posi - 1 .. pose]) |c| th.push(.int(c));
    return @intCast(n);
}

fn char(th: *Thread, base: u32) Error!u32 {
    const a: Args = .init(th, base, "char");
    const n = a.count();
    var sb: auxlib.Sized = undefined;
    const out = try sb.init(th.state, n);
    for (out, 1..) |*c, i| {
        const v: u64 = @bitCast(try a.checkInteger(@intCast(i)));
        if (v > 255) return a.argError(@intCast(i), "value out of range", .{});
        c.* = @intCast(v);
    }
    th.push(.string(try sb.finish(th.state)));
    return 1;
}

/// `string.dump`: the function's prototype as a binary chunk
/// (`dump_engine`), without debug information when `strip` is true.
fn dump(th: *Thread, base: u32) Error!u32 {
    const a: Args = .init(th, base, "dump");
    const f = a.get(1);
    if (f.tag != .lua_closure) return a.argError(1, "Lua function expected", .{});
    var b: auxlib.Buffer = undefined;
    b.init(th.state);
    defer b.deinit();
    dump_engine.dump(th.heap().allocator(), &b.writer, f.asLuaClosure().proto, !a.get(2).isFalsy()) catch
        return error.OutOfMemory;
    th.push(.string(try b.toString(th.state)));
    return 1;
}

// ---------------------------------------------------------------------------
// Patterns
// ---------------------------------------------------------------------------

fn patternError(th: *Thread, diag: *const pattern.Diagnostic) Error {
    return raise(th, "{s}", .{diag.message()});
}

/// Pushes the captures of the match `span`, or the whole match when the
/// pattern has none and `whole` (`push_captures`).
fn pushCaptures(th: *Thread, m: *pattern.Matcher, span: pattern.Span, whole: bool) Error!u32 {
    const n: u32 = if (whole) @intCast(m.resultCount()) else m.level;
    try auxlib.checkStack(th, n, "too many captures");
    for (0..n) |i| {
        switch (m.capture(i, span) catch return patternError(th, &m.diag)) {
            .string => |s| try pushString(th, s),
            .position => |p| th.push(.int(@intCast(p))),
        }
    }
    return n;
}

/// `str_find_aux`: `string.find` and `string.match`.
fn findAux(th: *Thread, base: u32, comptime is_find: bool) Error!u32 {
    const a: Args = .init(th, base, if (is_find) "find" else "match");
    const s = (try a.checkString(1)).bytes();
    const p = (try a.checkString(2)).bytes();
    const init = posrelatI(try a.optInteger(3, 1), s.len) - 1;
    if (init > s.len) {
        th.push(.nil);
        return 1;
    }
    if (is_find and (!a.get(4).isFalsy() or !pattern.hasSpecials(p))) {
        if (pattern.findPlain(s, p, init)) |span| {
            th.push(.int(@intCast(span.start + 1)));
            th.push(.int(@intCast(span.end)));
            return 2;
        }
    } else {
        var m: pattern.Matcher = .init(s, p);
        if (pattern.find(&m, init) catch return patternError(th, &m.diag)) |span| {
            if (!is_find) return pushCaptures(th, &m, span, true);
            th.push(.int(@intCast(span.start + 1)));
            th.push(.int(@intCast(span.end)));
            return 2 + try pushCaptures(th, &m, span, false);
        }
    }
    th.push(.nil);
    return 1;
}

fn find(th: *Thread, base: u32) Error!u32 {
    return findAux(th, base, true);
}

fn match(th: *Thread, base: u32) Error!u32 {
    return findAux(th, base, false);
}

/// `string.gmatch`: an iterator closure whose upvalues are the subject, the
/// pattern (so the collector keeps the bytes the state points into), and a
/// userdata holding the `pattern.Gmatch` state.
fn gmatch(th: *Thread, base: u32) Error!u32 {
    const a: Args = .init(th, base, "gmatch");
    const s = try a.checkString(1);
    const p = try a.checkString(2);
    const init = posrelatI(try a.optInteger(3, 1), s.len) - 1;
    const heap = th.heap();
    const ud = try Userdata.create(heap, @sizeOf(pattern.Gmatch), 0);
    const g: *pattern.Gmatch = @ptrCast(auxlib.userdataBytes(ud).ptr);
    g.* = .init(s.bytes(), p.bytes(), init);
    const cl = try Proto.NativeClosure.create(heap, gmatchAux, 3);
    cl.setUpvalue(heap, 0, .string(s));
    cl.setUpvalue(heap, 1, .string(p));
    cl.setUpvalue(heap, 2, .userdata(ud));
    th.push(.nativeClosure(cl));
    return 1;
}

fn gmatchAux(th: *Thread, base: u32) Error!u32 {
    const cl = th.stack[base - 1].asNativeClosure();
    const g: *pattern.Gmatch = @ptrCast(auxlib.userdataBytes(cl.upvalues()[2].asUserdata()).ptr);
    const span = (g.next() catch return patternError(th, &g.m.diag)) orelse return 0;
    return pushCaptures(th, &g.m, span, true);
}

/// Writes a table's or function's replacement `v` for the match `span`, or
/// the original text when `v` is false or nil (`add_value`).
fn addValue(th: *Thread, v: Value, m: *pattern.Matcher, span: pattern.Span, w: *Writer) Error!bool {
    if (v.isFalsy()) {
        w.writeAll(m.src[span.start..span.end]) catch return error.OutOfMemory;
        return false;
    }
    if (v.isString()) {
        w.writeAll(v.asString().bytes()) catch return error.OutOfMemory;
    } else if (v.isNumber()) {
        var nb: [number.max_len]u8 = undefined;
        w.writeAll(auxlib.formatNumber(&nb, v)) catch return error.OutOfMemory;
    } else {
        return raise(th, "invalid replacement value (a {s})", .{v.typeOf().name()});
    }
    return true;
}

/// The first capture of a match as a Lua value.
fn captureValue(th: *Thread, m: *pattern.Matcher, span: pattern.Span) Error!Value {
    return switch (m.capture(0, span) catch return patternError(th, &m.diag)) {
        .string => |s| .string(try th.state.newString(s)),
        .position => |p| .int(@intCast(p)),
    };
}

const TableReplacement = struct {
    th: *Thread,
    t: Value,

    pub fn replace(r: TableReplacement, m: *pattern.Matcher, span: pattern.Span, w: *Writer) Error!bool {
        const key = try captureValue(r.th, m, span);
        return addValue(r.th, try auxlib.index(r.th, r.t, key), m, span, w);
    }
};

const FunctionReplacement = struct {
    th: *Thread,
    f: Value,

    pub fn replace(r: FunctionReplacement, m: *pattern.Matcher, span: pattern.Span, w: *Writer) Error!bool {
        const th = r.th;
        try th.ensureStack(1);
        const func = th.top;
        th.push(r.f);
        _ = try pushCaptures(th, m, span, true);
        try vm.call(th, func, 1);
        const v = th.stack[func];
        th.top = func;
        return addValue(th, v, m, span, w);
    }
};

fn gsub(th: *Thread, base: u32) Error!u32 {
    const a: Args = .init(th, base, "gsub");
    const src = try a.checkString(1);
    const p = (try a.checkString(2)).bytes();
    const repl = a.get(3);
    const max_n = try a.optInteger(4, @intCast(src.len + 1));
    var b: auxlib.Buffer = undefined;
    b.init(th.state);
    defer b.deinit();
    var m: pattern.Matcher = .init(src.bytes(), p);
    const res = switch (repl.typeOf()) {
        .number, .string => blk: {
            const text = (try a.checkString(3)).bytes();
            break :blk pattern.gsub(&m, max_n, &b.writer, pattern.StringReplacement{ .text = text });
        },
        .table => pattern.gsub(&m, max_n, &b.writer, TableReplacement{ .th = th, .t = repl }),
        .function => pattern.gsub(&m, max_n, &b.writer, FunctionReplacement{ .th = th, .f = repl }),
        else => return a.typeError(3, "string/function/table"),
    } catch |e| return gsubError(th, &m, e);
    th.push(if (res.changed) .string(try b.toString(th.state)) else .string(src));
    th.push(.int(res.count));
    return 2;
}

fn gsubError(th: *Thread, m: *pattern.Matcher, e: anyerror) Error {
    return switch (e) {
        error.PatternError => patternError(th, &m.diag),
        error.LuaError => error.LuaError,
        error.OutOfMemory, error.WriteFailed => error.OutOfMemory,
        else => unreachable,
    };
}

// ---------------------------------------------------------------------------
// format, pack, unpack, packsize
// ---------------------------------------------------------------------------

/// `string.format`'s arguments, for the engine.
const FormatArgs = struct {
    a: Args,
    /// A stack slot that keeps the last `%s` conversion's string alive.
    scratch: u32,

    pub fn integer(f: FormatArgs, arg: u32) Error!i64 {
        return f.a.checkInteger(arg);
    }

    pub fn number(f: FormatArgs, arg: u32) Error!f64 {
        return f.a.checkNumber(arg);
    }

    pub fn string(f: FormatArgs, arg: u32) Error![]const u8 {
        const v = f.a.get(arg);
        if (v.isString()) return v.asString().bytes();
        const s = try auxlib.tolstring(f.a.th, v);
        f.a.th.stack[f.scratch] = .string(s);
        return s.bytes();
    }

    pub fn pointer(f: FormatArgs, arg: u32) ?usize {
        return auxlib.toPointer(f.a.get(arg));
    }

    pub fn literal(f: FormatArgs, arg: u32) Error!fmt_engine.Literal {
        const v = f.a.get(arg);
        return switch (v.tag) {
            .short_string, .long_string => .{ .string = v.asString().bytes() },
            .int => .{ .integer = v.payload.int },
            .float => .{ .float = v.payload.float },
            .nil => .{ .text = "nil" },
            .bool_false => .{ .text = "false" },
            .bool_true => .{ .text = "true" },
            else => f.a.argError(arg, "value has no literal form", .{}),
        };
    }
};

fn format(th: *Thread, base: u32) Error!u32 {
    const a: Args = .init(th, base, "format");
    const fmt = try a.checkString(1);
    try th.ensureStack(1);
    const scratch = th.top;
    th.push(.nil);
    var b: auxlib.Buffer = undefined;
    b.init(th.state);
    defer b.deinit();
    var diag: fmt_engine.Diagnostic = .{};
    fmt_engine.format(
        &b.writer,
        fmt.bytes(),
        a.count(),
        FormatArgs{ .a = a, .scratch = scratch },
        &diag,
    ) catch |e| switch (e) {
        error.FormatError => return if (diag.arg != 0)
            a.argError(diag.arg, "{s}", .{diag.message()})
        else
            raise(th, "{s}", .{diag.message()}),
        error.WriteFailed => return error.OutOfMemory,
        else => |x| return x,
    };
    th.push(.string(try b.toString(th.state)));
    return 1;
}

/// `string.pack`'s arguments, for the engine.
const PackArgs = struct {
    a: Args,

    pub fn integer(p: PackArgs, arg: u32) Error!i64 {
        return p.a.checkInteger(arg);
    }

    pub fn number(p: PackArgs, arg: u32) Error!f64 {
        return p.a.checkNumber(arg);
    }

    pub fn string(p: PackArgs, arg: u32) Error![]const u8 {
        return (try p.a.checkString(arg)).bytes();
    }
};

fn packError(a: Args, diag: *const pack_engine.Diagnostic) Error {
    if (diag.arg != 0) return a.argError(diag.arg, "{s}", .{diag.message()});
    return raise(a.th, "{s}", .{diag.message()});
}

fn pack(th: *Thread, base: u32) Error!u32 {
    const fmt = (try Args.init(th, base, "pack").checkString(1)).bytes();
    // The reference pushes a nil above the arguments before reading them,
    // so the first missing one is "nil", not "no value".
    try th.ensureStack(1);
    th.push(.nil);
    const a: Args = .init(th, base, "pack");
    var b: auxlib.Buffer = undefined;
    b.init(th.state);
    defer b.deinit();
    var diag: pack_engine.Diagnostic = .{};
    pack_engine.pack(&b.writer, fmt, PackArgs{ .a = a }, &diag) catch |e| switch (e) {
        error.PackError => return packError(a, &diag),
        error.WriteFailed => return error.OutOfMemory,
        else => |x| return x,
    };
    th.push(.string(try b.toString(th.state)));
    return 1;
}

fn packsize(th: *Thread, base: u32) Error!u32 {
    const a: Args = .init(th, base, "packsize");
    const fmt = (try a.checkString(1)).bytes();
    var diag: pack_engine.Diagnostic = .{};
    const n = pack_engine.packsize(fmt, &diag) catch return packError(a, &diag);
    th.push(.int(n));
    return 1;
}

/// Receives `string.unpack`'s values and pushes them.
const UnpackSink = struct {
    th: *Thread,
    n: *u32,

    fn room(s: UnpackSink) Error!void {
        try auxlib.checkStack(s.th, 2, "too many results");
        s.n.* += 1;
    }

    pub fn integer(s: UnpackSink, v: i64) Error!void {
        try s.room();
        s.th.push(.int(v));
    }

    pub fn number(s: UnpackSink, v: f64) Error!void {
        try s.room();
        s.th.push(.float(v));
    }

    pub fn string(s: UnpackSink, v: []const u8) Error!void {
        try s.room();
        try pushString(s.th, v);
    }
};

fn unpack(th: *Thread, base: u32) Error!u32 {
    const a: Args = .init(th, base, "unpack");
    const fmt = (try a.checkString(1)).bytes();
    const data = (try a.checkString(2)).bytes();
    const init = try a.optInteger(3, 1);
    var n: u32 = 0;
    var diag: pack_engine.Diagnostic = .{};
    const pos = pack_engine.unpack(fmt, data, init, UnpackSink{ .th = th, .n = &n }, &diag) catch |e| switch (e) {
        error.PackError => return packError(a, &diag),
        else => |x| return x,
    };
    try th.ensureStack(1);
    th.push(.int(pos));
    return n + 1;
}

// ---------------------------------------------------------------------------
// Arithmetic metamethods: string coercion (§3.4.3)
// ---------------------------------------------------------------------------

const ArithOp = enum { add, sub, mul, mod, pow, div, idiv, unm };

fn arithFn(comptime op: ArithOp) Value.NativeFn {
    return struct {
        fn f(th: *Thread, base: u32) Error!u32 {
            return arith(th, base, op);
        }
    }.f;
}

/// Both operands as numbers, then the operation; otherwise the second
/// operand's metamethod, or the reference's error (`arith`, `trymt`).
fn arith(th: *Thread, base: u32, comptime op: ArithOp) Error!u32 {
    const a: Args = .init(th, base, "__" ++ @tagName(op));
    const x = a.get(1);
    const y = a.get(2);
    if (auxlib.toNumberValue(x)) |nx| {
        // Called with one operand, the reference converts the first and
        // then finds that conversion in the second's place.
        if (if (a.isNone(2)) nx else auxlib.toNumberValue(y)) |ny| {
            // `lua_arith` negates the top value, which is the second
            // operand's conversion.
            th.push(try arithOp(th, op, if (op == .unm) ny else nx, ny));
            return 1;
        }
    }
    const mm = (if (y.isString()) null else auxlib.metafield(th.state, y, "__" ++ @tagName(op))) orelse
        return raise(
            th,
            "attempt to {s} a '{s}' with a '{s}'",
            .{ @tagName(op), x.typeOf().name(), y.typeOf().name() },
        );
    th.push(try auxlib.call1(th, mm, &.{ x, y }));
    return 1;
}

/// `lua_arith` on two numbers.
fn arithOp(th: *Thread, comptime op: ArithOp, x: Value, y: Value) Error!Value {
    if (x.tag == .int and y.tag == .int) {
        const i = x.payload.int;
        const j = y.payload.int;
        switch (op) {
            .add => return .int(i +% j),
            .sub => return .int(i -% j),
            .mul => return .int(i *% j),
            .unm => return .int(0 -% i),
            .mod => return .int(number.modInt(i, j) catch return th.runError("attempt to perform 'n%0'", .{})),
            .idiv => return .int(number.divFloorInt(i, j) catch return th.runError("attempt to divide by zero", .{})),
            .pow, .div => {},
        }
    }
    const f = x.asNumber();
    const g = y.asNumber();
    return .float(switch (op) {
        .add => f + g,
        .sub => f - g,
        .mul => f * g,
        .unm => -f,
        .mod => number.modFloat(f, g),
        .idiv => number.divFloorFloat(f, g),
        .div => f / g,
        .pow => if (g == 2) f * f else libm.pow(f, g),
    });
}

// ---------------------------------------------------------------------------
// Tests. Expected values come from reference Lua 5.5.1 (`lua` in the dev
// shell), most from the cases in test/lua-5.5.1-tests/strings.lua, pm.lua,
// and tpack.lua.
// ---------------------------------------------------------------------------

const testing = std.testing;
const h = auxlib.testing;

test "string functions match the reference" {
    @setEvalBranchQuota(100_000);
    const state = try h.newState();
    defer state.destroy();
    try open(state);
    try h.expectCases(state, .{
        .{ "string.sub", .{ "123456789", @as(i64, 2), @as(i64, 4) }, "234" },
        .{ "string.sub", .{ "123456789", @as(i64, 7) }, "789" },
        .{ "string.sub", .{ "123456789", @as(i64, 7), @as(i64, 6) }, "" },
        .{ "string.sub", .{ "123456789", @as(i64, 0), @as(i64, 0) }, "" },
        .{ "string.sub", .{ "123456789", @as(i64, -10), @as(i64, 10) }, "123456789" },
        .{ "string.sub", .{ "123456789", @as(i64, -10), @as(i64, -20) }, "" },
        .{ "string.sub", .{ "123456789", @as(i64, -4) }, "6789" },
        .{ "string.sub", .{ "123456789", @as(i64, -6), @as(i64, -4) }, "456" },
        .{ "string.sub", .{ "123456789", @as(i64, -9223372036854775807 - 1), @as(i64, -4) }, "123456" },
        .{
            "string.sub",
            .{ "123456789", @as(i64, -9223372036854775807 - 1), @as(i64, 9223372036854775807) },
            "123456789",
        },
        .{ "string.sub", .{ "123456789", @as(i64, -9223372036854775807 - 1), @as(i64, -9223372036854775807 - 1) }, "" },
        .{ "string.sub", .{ "\x0c3456789", @as(i64, 3), @as(i64, 5) }, "456" },
        .{ "string.sub", .{ "123456789", @as(f64, 2.0), "3" }, "23" },
        .{ "string.sub", .{ @as(i64, 123456789), @as(i64, 2), @as(i64, 3) }, "23" },
        .{
            "string.sub",
            .{ "x", @as(f64, 1.5) },
            "error: bad argument #2 to 'sub' (number has no integer representation)",
        },
        .{ "string.sub", .{"x"}, "error: bad argument #2 to 'sub' (number expected, got no value)" },
        .{
            "string.sub",
            .{ .{ .kv = .{} }, @as(i64, 1) },
            "error: bad argument #1 to 'sub' (string expected, got table)",
        },
        .{ "string.find", .{ "123456789", "345" }, "3\t5" },
        .{ "string.find", .{ "1234567890123456789", "345", @as(i64, 3) }, "3\t5" },
        .{ "string.find", .{ "1234567890123456789", "345", @as(i64, 4) }, "13\t15" },
        .{ "string.find", .{ "1234567890123456789", "346", @as(i64, 4) }, "nil" },
        .{ "string.find", .{ "1234567890123456789", ".45", @as(i64, -9) }, "13\t15" },
        .{ "string.find", .{ "abcdefg", "\x00", @as(i64, 5), @as(i64, 1) }, "nil" },
        .{ "string.find", .{ "", "" }, "1\t0" },
        .{ "string.find", .{ "", "", @as(i64, 1) }, "1\t0" },
        .{ "string.find", .{ "", "", @as(i64, 2) }, "nil" },
        .{ "string.find", .{ "", "aaa", @as(i64, 1) }, "nil" },
        .{ "string.find", .{ "alo(.)alo", "(.)", @as(i64, 1), @as(i64, 1) }, "4\t6" },
        .{ "string.find", .{ "alo(.)alo", "(.)", @as(i64, 1), false }, "1\t1\ta" },
        .{ "string.find", .{ "hello world", "(o)(r)" }, "8\t9\to\tr" },
        .{ "string.find", .{ "hello world", "()ll()" }, "3\t4\t3\t5" },
        .{ "string.find", .{ "hello", "l", @as(i64, 10) }, "nil" },
        .{ "string.find", .{ "hello", "l", @as(i64, -100) }, "3\t3" },
        .{ "string.find", .{ "hello", "%" }, "error: malformed pattern (ends with '%')" },
        .{ "string.find", .{ "hello", "(()" }, "error: unfinished capture" },
        .{ "string.find", .{ "hello", "[a" }, "error: malformed pattern (missing ']')" },
        .{ "string.find", .{ "a\x00b", "\x00b" }, "2\t3" },
        .{ "string.match", .{ "hello world", "o (w)" }, "w" },
        .{ "string.match", .{ "hello world", "%w+" }, "hello" },
        .{ "string.match", .{ "hello world", "^(h)(e)" }, "h\te" },
        .{ "string.match", .{ "hello world", "^e" }, "nil" },
        .{ "string.match", .{ "key = value", "(%w+)%s*=%s*(%w+)" }, "key\tvalue" },
        .{ "string.match", .{ "  x", "()x()" }, "3\t4" },
        .{ "string.match", .{ "hello", ".-", @as(i64, 3) }, "" },
        .{ "string.match", .{ "hello", "(h)%2" }, "error: invalid capture index %2" },
        .{ "string.match", .{ "hello", "%1" }, "error: invalid capture index %1" },
        .{
            "string.match",
            .{
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
                "(a)(a)(a)(a)(a)(a)(a)(a)(a)(a)(a)(a)(a)(a)(a)(a)(a)(a)(a)(a)(a)(a)(a)(a)(a)(a)(a)(a)(a)(a)(a)(a)(a)",
            },
            "error: too many captures",
        },
        .{ "string.len", .{""}, "0" },
        .{ "string.len", .{"\x00\x00\x00"}, "3" },
        .{ "string.len", .{@as(i64, 1234)}, "4" },
        .{ "string.len", .{@as(f64, 1.5)}, "3" },
        .{ "string.len", .{}, "error: bad argument #1 to 'len' (string expected, got no value)" },
        .{ "string.reverse", .{""}, "" },
        .{ "string.reverse", .{"\x00\x01\x02\x03"}, "\x03\x02\x01\x00" },
        .{
            "string.reverse",
            .{"abcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabc"},
            "cbacbacbacbacbacbacbacbacbacbacbacbacbacbacbacbacbacbacbacba",
        },
        .{ "string.upper", .{"ab\x00c"}, "AB\x00C" },
        .{ "string.lower", .{"\x00ABCc%$"}, "\x00abcc%$" },
        .{ "string.upper", .{"\xe1\xe9 x"}, "\xe1\xe9 X" },
        .{
            "string.lower",
            .{"ABCABCABCABCABCABCABCABCABCABCABCABCABCABCABCABCABCABCABCABC"},
            "abcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabcabc",
        },
        .{ "string.rep", .{ "teste", @as(i64, 0) }, "" },
        .{ "string.rep", .{ "t\xe9s\x00t\xea", @as(i64, 2) }, "t\xe9s\x00t\xeat\xe9s\x00t\xea" },
        .{ "string.rep", .{ "", @as(i64, 10) }, "" },
        .{ "string.rep", .{ "aa", @as(i64, 9223372036854775807) }, "error: resulting string too large" },
        .{ "string.rep", .{ "a", @as(i64, 9223372036854775807), "," }, "error: resulting string too large" },
        .{ "string.rep", .{ "teste", @as(i64, 0), "xuxu" }, "" },
        .{ "string.rep", .{ "teste", @as(i64, 1), "xuxu" }, "teste" },
        .{ "string.rep", .{ "\x01\x00\x01", @as(i64, 2), "\x00\x00" }, "\x01\x00\x01\x00\x00\x01\x00\x01" },
        .{ "string.rep", .{ "", @as(i64, 10), "." }, "........." },
        .{ "string.rep", .{ "", @as(i64, 4611686018427387913), "aa" }, "error: resulting string too large" },
        .{ "string.rep", .{ "ab", @as(i64, 3), "," }, "ab,ab,ab" },
        .{ "string.rep", .{ "x", @as(i64, 50) }, "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" },
        .{ "string.rep", .{ "ab", @as(i64, -1) }, "" },
        .{
            "string.rep",
            .{ "ab", @as(f64, 2.5) },
            "error: bad argument #2 to 'rep' (number has no integer representation)",
        },
        .{ "string.rep", .{ "ab", "2" }, "abab" },
        .{ "string.rep", .{ "ab", "x" }, "error: bad argument #2 to 'rep' (number expected, got string)" },
        .{ "string.rep", .{"ab"}, "error: bad argument #2 to 'rep' (number expected, got no value)" },
        .{ "string.rep", .{ null, @as(i64, 2) }, "error: bad argument #1 to 'rep' (string expected, got nil)" },
        .{
            "string.rep",
            .{ "ab", @as(i64, 2), .{ .kv = .{} } },
            "error: bad argument #3 to 'rep' (string expected, got table)",
        },
        .{ "string.byte", .{"a"}, "97" },
        .{ "string.byte", .{ "\x00\x00alo\x00x", @as(i64, -1) }, "120" },
        .{ "string.byte", .{ "ba", @as(i64, 2) }, "97" },
        .{ "string.byte", .{ "\n\n", @as(i64, 2), @as(i64, -1) }, "10" },
        .{ "string.byte", .{""}, "" },
        .{ "string.byte", .{ "hi", @as(i64, -3) }, "" },
        .{ "string.byte", .{ "hi", @as(i64, 3) }, "" },
        .{ "string.byte", .{ "hi", @as(i64, 9), @as(i64, 10) }, "" },
        .{ "string.byte", .{ "hi", @as(i64, 2), @as(i64, 1) }, "" },
        .{ "string.byte", .{ "hello", @as(i64, 1), @as(i64, -1) }, "104\t101\t108\t108\t111" },
        .{
            "string.byte",
            .{ "hello", @as(i64, -9223372036854775807 - 1), @as(i64, 9223372036854775807) },
            "104\t101\t108\t108\t111",
        },
        .{ "string.char", .{}, "" },
        .{ "string.char", .{ @as(i64, 0), @as(i64, 255), @as(i64, 0) }, "\x00\xff\x00" },
        .{ "string.char", .{ @as(i64, 104), @as(i64, 105) }, "hi" },
        .{ "string.char", .{@as(i64, 256)}, "error: bad argument #1 to 'char' (value out of range)" },
        .{ "string.char", .{@as(i64, -1)}, "error: bad argument #1 to 'char' (value out of range)" },
        .{ "string.char", .{@as(i64, 9223372036854775807)}, "error: bad argument #1 to 'char' (value out of range)" },
        .{
            "string.char",
            .{@as(i64, -9223372036854775807 - 1)},
            "error: bad argument #1 to 'char' (value out of range)",
        },
        .{ "string.char", .{ @as(i64, 65), "66", @as(f64, 67.0) }, "ABC" },
        .{
            "string.char",
            .{ @as(i64, 65), @as(f64, 66.5) },
            "error: bad argument #2 to 'char' (number has no integer representation)",
        },
        .{ "string.char", .{ @as(i64, 65), null }, "error: bad argument #2 to 'char' (number expected, got nil)" },
        .{
            "string.char",
            .{
                @as(i64, 65),
                @as(i64, 66),
                @as(i64, 67),
                @as(i64, 68),
                @as(i64, 69),
                @as(i64, 70),
                @as(i64, 71),
                @as(i64, 72),
                @as(i64, 73),
                @as(i64, 74),
                @as(i64, 75),
                @as(i64, 76),
                @as(i64, 77),
                @as(i64, 78),
                @as(i64, 79),
                @as(i64, 80),
                @as(i64, 81),
                @as(i64, 82),
                @as(i64, 83),
                @as(i64, 84),
                @as(i64, 85),
                @as(i64, 86),
                @as(i64, 87),
                @as(i64, 88),
                @as(i64, 89),
                @as(i64, 90),
                @as(i64, 97),
                @as(i64, 98),
                @as(i64, 99),
                @as(i64, 100),
                @as(i64, 101),
                @as(i64, 102),
                @as(i64, 103),
                @as(i64, 104),
                @as(i64, 105),
            },
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghi",
        },
        .{ "string.dump", .{.native_function}, "error: bad argument #1 to 'dump' (Lua function expected)" },
        .{ "string.dump", .{@as(i64, 1)}, "error: bad argument #1 to 'dump' (Lua function expected)" },
        .{ "string.format", .{ "%d", @as(i64, 10) }, "10" },
        .{ "string.format", .{ "%5d|%-5d|", @as(i64, 42), @as(i64, 42) }, "   42|42   |" },
        .{ "string.format", .{ "%d", "10" }, "10" },
        .{ "string.format", .{ "%d", @as(f64, 3.0) }, "3" },
        .{
            "string.format",
            .{ "%d", @as(f64, 3.5) },
            "error: bad argument #2 to 'format' (number has no integer representation)",
        },
        .{
            "string.format",
            .{ "%d", "3.5" },
            "error: bad argument #2 to 'format' (number has no integer representation)",
        },
        .{ "string.format", .{ "%d", "x" }, "error: bad argument #2 to 'format' (number expected, got string)" },
        .{ "string.format", .{"%d"}, "error: bad argument #2 to 'format' (no value)" },
        .{ "string.format", .{ "%d %d", @as(i64, 10) }, "error: bad argument #3 to 'format' (no value)" },
        .{ "string.format", .{ "%5.2f", @as(f64, 3.1415899999999999) }, " 3.14" },
        .{ "string.format", .{ "%5.1f", "3" }, "  3.0" },
        .{ "string.format", .{ "%g", @as(f64, 1.0000000000000001e+300) }, "1e+300" },
        .{ "string.format", .{ "%x", @as(f64, 0.0) }, "0" },
        .{ "string.format", .{ "%02x", @as(f64, 0.0) }, "00" },
        .{ "string.format", .{ "%08X", @as(i64, 4294967295) }, "FFFFFFFF" },
        .{ "string.format", .{ "%s", @as(f64, 1.5) }, "1.5" },
        .{ "string.format", .{ "%s %s", null, true }, "nil true" },
        .{ "string.format", .{ "%s %.4s", false, true }, "false true" },
        .{ "string.format", .{ "%.3s %.3s", false, true }, "fal tru" },
        .{ "string.format", .{ "%s", @as(i64, 10) }, "10" },
        .{ "string.format", .{ "%10s|", "abc" }, "       abc|" },
        .{ "string.format", .{ "%-10s|", "abc" }, "abc       |" },
        .{ "string.format", .{ "%10s", "\x00" }, "error: bad argument #2 to 'format' (string contains zeros)" },
        .{ "string.format", .{ "\x00%s\x00", "\x00\x00\x01" }, "\x00\x00\x00\x01\x00" },
        .{ "string.format", .{ "%q", "\"\xedlo\"\n\\" }, "\"\\\"\xedlo\\\"\\\n\\\\\"" },
        .{ "string.format", .{ "%q", "\x00" }, "\"\\0\"" },
        .{ "string.format", .{ "%q", "\x00\x01\x023\x05\x009" }, "\"\\0\\1\\0023\\5\\0009\"" },
        .{ "string.format", .{ "%q", @as(i64, 9223372036854775807) }, "9223372036854775807" },
        .{ "string.format", .{ "%q", @as(i64, -9223372036854775807 - 1) }, "0x8000000000000000" },
        .{ "string.format", .{ "%q", @as(f64, 3.1415926535897931) }, "0x1.921fb54442d18p+1" },
        .{ "string.format", .{ "%q", @as(f64, 0.10000000000000001) }, "0x1.999999999999ap-4" },
        .{ "string.format", .{ "%q", @as(f64, 1.0) }, "0x1p+0" },
        .{ "string.format", .{ "%q", true }, "true" },
        .{ "string.format", .{ "%q", null }, "nil" },
        .{ "string.format", .{ "%q", std.math.inf(f64) }, "1e9999" },
        .{ "string.format", .{ "%q", -std.math.inf(f64) }, "-1e9999" },
        .{ "string.format", .{ "%q", @as(f64, @bitCast(@as(u64, 0xfff8000000000000))) }, "(0/0)" },
        .{
            "string.format",
            .{ "%q", .{ .kv = .{} } },
            "error: bad argument #2 to 'format' (value has no literal form)",
        },
        .{ "string.format", .{ "%10q", @as(i64, 1) }, "error: specifier '%q' cannot have modifiers" },
        .{ "string.format", .{ "%p", @as(i64, 4) }, "(null)" },
        .{ "string.format", .{ "%p", true }, "(null)" },
        .{ "string.format", .{ "%p", null }, "(null)" },
        .{ "string.format", .{ "%10p", false }, "    (null)" },
        .{ "string.format", .{ "%-12p", @as(f64, 1.5) }, "(null)      " },
        .{ "string.format", .{ "%c%c%c", @as(i64, 104), @as(i64, 105), @as(i64, 33) }, "hi!" },
        .{ "string.format", .{ "%%%d %010d", @as(i64, 10), @as(i64, 23) }, "%10 0000000023" },
        .{ "string.format", .{ "%+08d", @as(i64, -30927) }, "-0030927" },
        .{ "string.format", .{ "%#12o", @as(i64, 10) }, "         012" },
        .{ "string.format", .{ "%a", @as(f64, 1.0) }, "0x1p+0" },
        .{ "string.format", .{ "%.3a", @as(i64, 0) }, "0x0.000p+0" },
        .{ "string.format", .{ "%100.3d", @as(i64, 10) }, "error: invalid conversion specification: '%100.3d'" },
        .{
            "string.format",
            .{
                "%10000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000" ++
                    "00000000000000000000000000000000000000000000000000000000000000000000000000000000" ++
                    "0000000000000000" ++
                    "00000000000000000000000000000000000000000000000000000000000000000000000000000000" ++
                    "0000000000000000" ++
                    "00000000000000000000000000000000000000000000000000000000000000000000000000000000" ++
                    "0000000000000000" ++
                    "00000000000000000000000000000000000000000000000000000000000000000000000000000000" ++
                    "0000000000000000" ++
                    "00000000000000000000000000000000000000000000000000000000000000000000000000000000" ++
                    "0000000000000000" ++
                    "00000000000000000000000000.3d",
                @as(i64, 10),
            },
            "error: invalid format (too long)",
        },
        .{ "string.format", .{ "%t", @as(i64, 10) }, "error: invalid conversion '%t' to 'format'" },
        .{ "string.format", .{ "%010c", @as(i64, 10) }, "error: invalid conversion specification: '%010c'" },
        .{ "string.format", .{ "%F", @as(i64, 10) }, "error: invalid conversion '%F' to 'format'" },
        .{ "string.format", .{ "%i", @as(f64, -9007199254740992.0) }, "-9007199254740992" },
        .{ "string.format", .{ "%u", @as(i64, -1) }, "18446744073709551615" },
        .{
            "string.format",
            .{ "%.99f", @as(f64, -9.9999999999999998e+37) },
            "-99999999999999997748809823456034029568.00000000000000000000000000000000000000000000000000000000" ++
                "0000000000000000000000000000000000000000000",
        },
        .{
            "string.format",
            .{
                "-%.20s.20s",
                "%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%" ++
                    "%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%" ++
                    "%%%%%%%%%%%%%%%%" ++
                    "%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%" ++
                    "%%%%%%%%%%%%%%%%" ++
                    "%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%" ++
                    "%%%%%%%%%%%%%%%%" ++
                    "%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%" ++
                    "%%%%%%%%%%%%%%%%" ++
                    "%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%" ++
                    "%%%%%%%%%%%%%%%%" ++
                    "%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%" ++
                    "%%%%%%%%%%%%%%%%" ++
                    "%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%" ++
                    "%%%%%%%%%%%%%%%%" ++
                    "%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%" ++
                    "%%%%%%%%%%%%%%%%" ++
                    "%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%" ++
                    "%%%%%%%%%%%%%%%%" ++
                    "%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%" ++
                    "%%%%%%%%%%%%%%%%" ++
                    "%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%" ++
                    "%%%%%%%%%%%%%%%%" ++
                    "%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%" ++
                    "%%%%%%%%%%%%%%%%" ++
                    "%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%" ++
                    "%%%%%%%%%%%%%%%%" ++
                    "%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%" ++
                    "%%%%%%%%%%%%%%%%" ++
                    "%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%" ++
                    "%%%%%%%%%%%%%%%%" ++
                    "%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%" ++
                    "%%%%%%%%%%%%%%%%" ++
                    "%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%" ++
                    "%%%%%%%%%%%%%%%%" ++
                    "%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%" ++
                    "%%%%%%%%%%%%%%%%" ++
                    "%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%" ++
                    "%%%%%%%%%%%%%%%%" ++
                    "%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%",
            },
            "-%%%%%%%%%%%%%%%%%%%%.20s",
        },
        .{
            "string.format",
            .{
                "%s",
                "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
            },
            "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
                "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
                "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
                "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
                "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
                "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
                "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
                "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
                "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
                "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
                "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
                "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
                "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
                "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
                "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
                "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
        },
        .{
            "string.format",
            .{
                "%.20s",
                "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
            },
            "xxxxxxxxxxxxxxxxxxxx",
        },
        .{ "string.format", .{}, "error: bad argument #1 to 'format' (string expected, got no value)" },
        .{ "string.format", .{@as(i64, 12)}, "12" },
        .{ "string.format", .{ "%e %E", @as(f64, 12345.678), @as(f64, -0.001) }, "1.234568e+04 -1.000000E-03" },
        .{ "string.gsub", .{ "hello world", "o", "0" }, "hell0 w0rld\t2" },
        .{ "string.gsub", .{ "hello world", "o", "0", @as(i64, 1) }, "hell0 world\t1" },
        .{ "string.gsub", .{ "hello world", "(o)", "[%1]" }, "hell[o] w[o]rld\t2" },
        .{ "string.gsub", .{ "hello world", "(o)", "[%0%%]" }, "hell[o%] w[o%]rld\t2" },
        .{ "string.gsub", .{ "hello world", "", "-" }, "-h-e-l-l-o- -w-o-r-l-d-\t12" },
        .{ "string.gsub", .{ "hello world", "^h", "H" }, "Hello world\t1" },
        .{ "string.gsub", .{ "hello world", "%w+", "%0 %0", @as(i64, 1) }, "hello hello world\t1" },
        .{ "string.gsub", .{ "abc", "%w", "%1" }, "abc\t3" },
        .{ "string.gsub", .{ "abc", "%w", "%2" }, "error: invalid capture index %2" },
        .{ "string.gsub", .{ "abc", "%w", "%x" }, "error: invalid use of '%' in replacement string" },
        .{ "string.gsub", .{ "abc", "b", @as(i64, 5) }, "a5c\t1" },
        .{ "string.gsub", .{ "abc", "b", @as(f64, 1.5) }, "a1.5c\t1" },
        .{
            "string.gsub",
            .{ "abc", "b" },
            "error: bad argument #3 to 'gsub' (string/function/table expected, got no value)",
        },
        .{
            "string.gsub",
            .{ "abc", "b", true },
            "error: bad argument #3 to 'gsub' (string/function/table expected, got boolean)",
        },
        .{ "string.gsub", .{ "abc", "b", "x", "y" }, "error: bad argument #4 to 'gsub' (number expected, got string)" },
        .{
            "string.gsub",
            .{ "abc", "b", "x", @as(f64, 1.5) },
            "error: bad argument #4 to 'gsub' (number has no integer representation)",
        },
        .{ "string.gsub", .{ "abc", "b", "x", @as(i64, 0) }, "abc\t0" },
        .{ "string.gsub", .{ "abc", "b", "x", @as(i64, -1) }, "abc\t0" },
        .{ "string.gsub", .{ "abc", "(b", "x" }, "axc\t1" },
        .{ "string.gsub", .{ "alo alo", "()", "%1" }, "1a2l3o4 5a6l7o8\t8" },
        .{ "string.gsub", .{ "abc d", "(%w)", "%1-" }, "a-b-c- d-\t4" },
        .{ "string.gsub", .{ @as(i64, 123), @as(i64, 2), @as(i64, 4) }, "143\t1" },
        .{ "string.pack", .{ "i4", @as(i64, 100) }, "d\x00\x00\x00" },
        .{ "string.pack", .{ ">i4", @as(i64, 100) }, "\x00\x00\x00d" },
        .{ "string.pack", .{ "<i2 >i2", @as(i64, 1), @as(i64, 1) }, "\x01\x00\x00\x01" },
        .{ "string.pack", .{ "z", "hello" }, "hello\x00" },
        .{ "string.pack", .{ "s1", "hi" }, "\x02hi" },
        .{ "string.pack", .{ "b", @as(i64, 200) }, "error: bad argument #2 to 'pack' (integer overflow)" },
        .{ "string.pack", .{ "B", @as(i64, -1) }, "error: bad argument #2 to 'pack' (unsigned overflow)" },
        .{ "string.pack", .{ "i17", @as(i64, 1) }, "error: integral size (17) out of limits [1,16]" },
        .{ "string.pack", .{ "d", "1.5" }, "\x00\x00\x00\x00\x00\x00\xf8?" },
        .{ "string.pack", .{ "i", "x" }, "error: bad argument #2 to 'pack' (number expected, got string)" },
        .{
            "string.pack",
            .{ "i", @as(f64, 1.5) },
            "error: bad argument #2 to 'pack' (number has no integer representation)",
        },
        .{ "string.pack", .{ "z", "a\x00b" }, "error: bad argument #2 to 'pack' (string contains zeros)" },
        .{ "string.pack", .{ "c3", "abcd" }, "error: bad argument #2 to 'pack' (string longer than given size)" },
        .{
            "string.pack",
            .{
                "s1",
                "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxx" ++
                    "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
            },
            "error: bad argument #2 to 'pack' (string length does not fit in given size)",
        },
        .{
            "string.pack",
            .{ "j n", @as(i64, 9223372036854775807), @as(f64, 1.5) },
            "\xff\xff\xff\xff\xff\xff\xff\x7f\x00\x00\x00\x00\x00\x00\xf8?",
        },
        .{ "string.pack", .{"i4"}, "error: bad argument #2 to 'pack' (number expected, got nil)" },
        .{ "string.packsize", .{"i4i8"}, "12" },
        .{ "string.packsize", .{"!8 i1 i8"}, "16" },
        .{ "string.packsize", .{"s"}, "error: bad argument #1 to 'packsize' (variable-length format)" },
        .{ "string.packsize", .{"c9223372036854775807"}, "error: invalid format option '7'" },
        .{
            "string.packsize",
            .{"c4611686018427387903c4611686018427387903c2"},
            "error: bad argument #1 to 'packsize' (format result too large)",
        },
        .{ "string.unpack", .{ "i4", "d\x00\x00\x00" }, "100\t5" },
        .{ "string.unpack", .{ ">i4", "\x00\x00\x00d" }, "100\t5" },
        .{ "string.unpack", .{ "z s1 B", "hello\x00\x02hi\xff" }, "hello\thi\t255\t11" },
        .{ "string.unpack", .{ "i4", "\x01\x00\x00" }, "error: bad argument #2 to 'unpack' (data string too short)" },
        .{ "string.unpack", .{ "i4", "\x01\x00\x00\x00\x02\x00\x00\x00", @as(i64, 5) }, "2\t9" },
        .{
            "string.unpack",
            .{ "i4", "\x01\x00\x00\x00", @as(i64, 6) },
            "error: bad argument #3 to 'unpack' (initial position out of string)",
        },
        .{ "string.unpack", .{ "i4", "\x01\x00\x00\x00", @as(i64, -4) }, "1\t5" },
        .{ "string.unpack", .{ "z", "abc" }, "error: bad argument #2 to 'unpack' (unfinished string for format 'z')" },
        .{
            "string.unpack",
            .{ "i9", "\x00\x00\x00\x00\x00\x00\x00\x00\x01" },
            "error: 9-byte integer does not fit into Lua Integer",
        },
        .{ "string.unpack", .{ "f d", "\x00\x00\x00?\x00\x00\x00\x00\x00\x00\x02\xc0" }, "0.5\t-2.25\t13" },
        .{ "string.unpack", .{ "!4 b i4", "\x01\x00\x00\x00\x02\x00\x00\x00" }, "1\t2\t9" },
        .{ "string.unpack", .{ "c0", "" }, "\t1" },
    });
}

/// Calls `f` with `args` and returns each result's `show` text, one call
/// per element of `calls`.
fn expectIterator(state: *State, want: []const []const u8, f: Value) !void {
    for (want) |w| try h.expectShow(state, w, f, &.{});
}

test "gmatch iterates over matches and their captures" {
    const state = try h.newState();
    defer state.destroy();
    try open(state);
    const gm = try h.global(state, "string.gmatch");
    const cases = .{
        .{ .{ "hello world from Lua", "%a+" }, &[_][]const u8{ "hello", "world", "from", "Lua", "" } },
        .{ .{ "k1=v1, k2=v2", "(%w+)=(%w+)" }, &[_][]const u8{ "k1\tv1", "k2\tv2", "" } },
        // '^' is not an anchor in gmatch.
        .{ .{ "^a^a", "^a" }, &[_][]const u8{ "^a", "^a", "" } },
        .{ .{ "abc", "()(.)", 2 }, &[_][]const u8{ "2\tb", "3\tc", "" } },
        .{ .{ "ab", "." }, &[_][]const u8{ "a", "b", "", "" } },
        .{ .{ "abc", "" }, &[_][]const u8{ "", "", "", "", "" } },
        .{ .{ "abc", "(%" }, &[_][]const u8{"error: malformed pattern (ends with '%')"} },
    };
    inline for (cases) |c| {
        const r = try h.ok(state, gm, try h.vals(state, c[0]));
        // Keep the iterator out of the stack area the next call reuses.
        const it = r[0];
        try state.globals.setStr(&state.heap, try state.newString("it"), it);
        try expectIterator(state, c[1], it);
    }
}

fn upperBang(th: *Thread, base: u32) Error!u32 {
    const s = th.stack[base].asString().bytes();
    var buf: [16]u8 = undefined;
    const u = std.ascii.upperString(&buf, s);
    buf[u.len] = '!';
    try pushString(th, buf[0 .. u.len + 1]);
    return 1;
}

fn angleUnlessB(th: *Thread, base: u32) Error!u32 {
    const s = th.stack[base].asString().bytes();
    if (std.mem.eql(u8, s, "b")) {
        th.push(.nil);
    } else {
        var buf: [16]u8 = undefined;
        try pushString(th, std.fmt.bufPrint(&buf, "<{s}>", .{s}) catch unreachable);
    }
    return 1;
}

fn firstArg(th: *Thread, base: u32) Error!u32 {
    th.push(th.stack[base]);
    return 1;
}

fn returnTrue(th: *Thread, base: u32) Error!u32 {
    _ = base;
    th.push(.true);
    return 1;
}

fn returnNothing(th: *Thread, base: u32) Error!u32 {
    _ = th;
    _ = base;
    return 0;
}

test "gsub with table and function replacements" {
    const state = try h.newState();
    defer state.destroy();
    try open(state);
    const gs = try h.global(state, "string.gsub");
    const t1 = try state.newTable(0, 2);
    try auxlib.setField(state, t1, "name", try h.str(state, "Lua"));
    try auxlib.setField(state, t1, "age", .int(30));
    try h.expectShow(
        state,
        "Lua is 30, $x\t3",
        gs,
        &.{ try h.str(state, "$name is $age, $x"), try h.str(state, "%$(%w+)"), .table(t1) },
    );
    const t2 = try state.newTable(0, 2);
    try auxlib.setField(state, t2, "a", .false);
    try auxlib.setField(state, t2, "b", try h.str(state, "B"));
    try h.expectShow(state, "aBc\t3", gs, &.{ try h.str(state, "abc"), try h.str(state, "%w"), .table(t2) });
    const t3 = try state.newTable(0, 1);
    try auxlib.setField(state, t3, "a", .table(try state.newTable(0, 0)));
    try h.expectShow(
        state,
        "error: invalid replacement value (a table)",
        gs,
        &.{ try h.str(state, "abc"), try h.str(state, "%w"), .table(t3) },
    );
    const t4 = try state.newTable(0, 2);
    try t4.setInt(&state.heap, 1, try h.str(state, "one"));
    try t4.setInt(&state.heap, 3, .float(3.5));
    try h.expectShow(state, "oneab3.5c\t4", gs, &.{ try h.str(state, "abc"), try h.str(state, "()"), .table(t4) });

    try h.expectShow(
        state,
        "hellO! wO!rld\t2",
        gs,
        &.{ try h.str(state, "hello world"), try h.str(state, "(o)"), .native(&upperBang) },
    );
    try h.expectShow(
        state,
        "<a>b<c>\t3",
        gs,
        &.{ try h.str(state, "abc"), try h.str(state, "%w"), .native(&angleUnlessB) },
    );
    try h.expectShow(
        state,
        "123\t3",
        gs,
        &.{ try h.str(state, "abc"), try h.str(state, "()(%w)"), .native(&firstArg) },
    );
    try h.expectShow(
        state,
        "error: invalid replacement value (a boolean)",
        gs,
        &.{ try h.str(state, "abc"), try h.str(state, "%w"), .native(&returnTrue) },
    );
    try h.expectShow(
        state,
        "abc\t3",
        gs,
        &.{ try h.str(state, "abc"), try h.str(state, "%w"), .native(&returnNothing) },
    );
}

fn mmAdd(th: *Thread, base: u32) Error!u32 {
    _ = base;
    try pushString(th, "mm");
    return 1;
}

test "the string metatable: __index and arithmetic on numeric strings" {
    const state = try h.newState();
    defer state.destroy();
    try open(state);
    const mt = state.metatables[@intFromEnum(Value.Type.string)].?;
    try testing.expect(
        mt.getStr(try state.newString("__index")).asTable() == (try h.global(state, "string")).asTable(),
    );
    const s = struct {
        fn f(st: *State, name: []const u8) !Value {
            return st.metatables[@intFromEnum(Value.Type.string)].?.getStr(try st.newString(name));
        }
    }.f;
    const cases = .{
        .{ "__add", .{ "10", 1 }, "11" },
        .{ "__add", .{ "3", "4" }, "7" },
        .{ "__mul", .{ "3", "4" }, "12" },
        .{ "__div", .{ "10", 2 }, "5.0" },
        .{ "__idiv", .{ "7", 2 }, "3" },
        .{ "__mod", .{ "7", "3" }, "1" },
        .{ "__unm", .{ "2", "2" }, "-2" },
        .{ "__unm", .{ "2.5", "2.5" }, "-2.5" },
        .{ "__add", .{ "0x10", 0 }, "16" },
        .{ "__add", .{ "1e1", 0 }, "10.0" },
        .{ "__pow", .{ "2", "10" }, "1024.0" },
        .{ "__sub", .{ " 5 ", 1 }, "4" },
        .{ "__add", .{ "abc", 1 }, "error: attempt to add a 'string' with a 'number'" },
        .{ "__add", .{ 1, "abc" }, "error: attempt to add a 'number' with a 'string'" },
        .{ "__mod", .{ "7", "0" }, "error: attempt to perform 'n%0'" },
        .{ "__idiv", .{ "7", 0 }, "error: attempt to divide by zero" },
        .{ "__add", .{ "1", .empty_table }, "error: attempt to add a 'string' with a 'table'" },
        .{ "__idiv", .{ "7.0", 0 }, "inf" },
        .{ "__mod", .{ "7", 0.0 }, "-nan" },
        .{ "__add", .{ std.math.maxInt(i64), "1" }, "-9223372036854775808" },
        .{ "__add", .{"1"}, "2" },
    };
    inline for (cases) |c| try h.expectShow(state, c[2], try s(state, c[0]), try h.vals(state, c[1]));
    // The second operand's own metamethod.
    const other = try state.newTable(0, 0);
    other.metatable = try state.newTable(0, 1);
    try auxlib.setField(state, other.metatable.?, "__add", .native(&mmAdd));
    try h.expectShow(state, "mm", try s(state, "__add"), &.{ try h.str(state, "1"), .table(other) });
}

fn helloString(th: *Thread, base: u32) Error!u32 {
    _ = base;
    try pushString(th, "hello");
    return 1;
}

fn fortyTwo(th: *Thread, base: u32) Error!u32 {
    _ = base;
    th.push(.int(42));
    return 1;
}

fn emptyTable(th: *Thread, base: u32) Error!u32 {
    _ = base;
    th.push(.table(try th.state.newTable(0, 0)));
    return 1;
}

test "format's %s uses __tostring and __name" {
    const state = try h.newState();
    defer state.destroy();
    try open(state);
    const fmt = try h.global(state, "string.format");
    const m = try state.newTable(0, 0);
    const mt = try state.newTable(0, 2);
    m.metatable = mt;
    try auxlib.setField(state, mt, "__tostring", .native(&helloString));
    try auxlib.setField(state, mt, "__name", try h.str(state, "hi"));
    try h.expectShow(
        state,
        "hello hello|hello",
        fmt,
        &.{ try h.str(state, "%s %.10s|%5s"), .table(m), .table(m), .table(m) },
    );
    try auxlib.setField(state, mt, "__tostring", .native(&fortyTwo));
    try h.expectShow(state, "42", fmt, &.{ try h.str(state, "%s"), .table(m) });
    try auxlib.setField(state, mt, "__tostring", .native(&emptyTable));
    try h.expectShow(state, "error: '__tostring' must return a string", fmt, &.{ try h.str(state, "%s"), .table(m) });
    // Without __tostring, "__name: address", as strings.lua checks.
    try auxlib.setField(state, mt, "__tostring", .nil);
    try h.expectShow(state, "hi: ", fmt, &.{ try h.str(state, "%.4s"), .table(m) });
    const r = try h.ok(state, fmt, &.{ try h.str(state, "%s|%p"), .table(m), .table(m) });
    const text = r[0].asString().bytes();
    const bar = std.mem.findScalar(u8, text, '|').?;
    try testing.expectEqualStrings(text[bar + 1 ..], text[4..bar]);
    try testing.expect(std.mem.startsWith(u8, text, "hi: 0x"));
}

test "errors from a native name the calling Lua function's line" {
    const state = try h.newState();
    defer state.destroy();
    try open(state);
    switch (try h.callFromLua(state, try h.global(state, "string.rep"), &.{try h.str(state, "x")})) {
        .ok => return error.TestExpectedError,
        .err => |e| try testing.expectEqualStrings(
            "test:7: bad argument #2 to 'rep' (number expected, got no value)",
            e.asString().bytes(),
        ),
    }
    // A runtime error inside the native has no position, as in the
    // reference.
    switch (try h.callFromLua(
        state,
        try h.global(state, "string.format"),
        &.{ try h.str(state, "%d"), try h.str(state, "x") },
    )) {
        .ok => return error.TestExpectedError,
        .err => |e| try testing.expectEqualStrings(
            "test:7: bad argument #2 to 'format' (number expected, got string)",
            e.asString().bytes(),
        ),
    }
    const mt = state.metatables[@intFromEnum(Value.Type.string)].?;
    switch (try h.callFromLua(state, mt.getStr(try state.newString("__mod")), &.{ try h.str(state, "1"), .int(0) })) {
        .ok => return error.TestExpectedError,
        .err => |e| try testing.expectEqualStrings("attempt to perform 'n%0'", e.asString().bytes()),
    }
}

fn collectingUpper(th: *Thread, base: u32) Error!u32 {
    th.state.collect();
    const s = th.stack[base].asString().bytes();
    var sb: auxlib.Sized = undefined;
    const out = try sb.init(th.state, s.len);
    _ = std.ascii.upperString(out, s);
    th.push(.string(try sb.finish(th.state)));
    return 1;
}

fn collectingToString(th: *Thread, base: u32) Error!u32 {
    _ = base;
    th.state.collect();
    try pushString(th, "a fresh string longer than forty bytes, so it is not interned");
    return 1;
}

test "values natives hold survive collections in callbacks" {
    const state = try h.newState();
    defer state.destroy();
    try open(state);
    const long = "words and more words " ** 4;
    // gsub's subject, pattern, and buffer across collecting callbacks.
    try h.expectShow(state, ("WORDS AND MORE WORDS " ** 4) ++ "\t16", try h.global(state, "string.gsub"), &.{
        try h.str(state, long), try h.str(state, "%a+"), .native(&collectingUpper),
    });
    // format keeps each %s result until it is written.
    const m = try state.newTable(0, 0);
    m.metatable = try state.newTable(0, 1);
    try auxlib.setField(state, m.metatable.?, "__tostring", .native(&collectingToString));
    const fresh = "a fresh string longer than forty bytes, so it is not interned";
    try h.expectShow(state, fresh ++ "|" ++ fresh, try h.global(state, "string.format"), &.{
        try h.str(state, "%s|%s"), .table(m), .table(m),
    });
    // gmatch's closure keeps its subject and pattern.
    const it = (try h.ok(
        state,
        try h.global(state, "string.gmatch"),
        &.{ try h.str(state, long), try h.str(state, "%a+") },
    ))[0];
    try state.globals.setStr(&state.heap, try state.newString("it"), it);
    state.collect();
    try h.expectShow(state, "words", it, &.{});
    try h.expectShow(state, "and", it, &.{});
}

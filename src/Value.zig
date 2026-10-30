//! A Lua value: an 8-byte payload and a 1-byte tag, 16 bytes in all, the
//! shape PUC-Rio uses. Code outside this file reads and builds values only
//! through the inline functions below, so the representation (NaN-boxing is
//! the alternative to measure, docs/slop/plan.md decision 1) changes here
//! alone.

const Value = @This();

const std = @import("std");
const gc = @import("gc.zig");
const String = @import("String.zig");
const Table = @import("Table.zig");
const Thread = @import("Thread.zig");
const Proto = @import("Proto.zig");
const Userdata = @import("Userdata.zig");

payload: Payload,
tag: Tag,

comptime {
    std.debug.assert(@sizeOf(Value) == 16);
    std.debug.assert(@sizeOf(Payload) == 8);
}

/// The errors every operation that can run Lua code or allocate returns.
/// `error.LuaError` carries its error object in `Thread.err`.
/// `error.OutOfMemory` is the Lua memory error; a protected boundary turns
/// it into the "not enough memory" string, as the manual requires.
pub const Error = error{ LuaError, OutOfMemory };

/// A native function: it takes the thread and the stack index of its first
/// argument (arguments run from `base` to `thread.top`), pushes its results
/// on top, and returns how many it pushed (plan decision 11).
pub const NativeFn = *const fn (thread: *Thread, base: u32) Error!u32;

/// The payload. An extern union so any member reads back the bits of any
/// other; the tag says which member is meaningful.
pub const Payload = extern union {
    int: i64,
    float: f64,
    ptr: ?*anyopaque,
    gc: *gc.Header,
};

/// The variant tag. Values never hold `proto`, `upval`, or `dead_key`;
/// those tag collectable objects and dead table keys.
pub const Tag = enum(u8) {
    nil = 0,
    bool_false = 1,
    bool_true = 2,
    int,
    float,
    light_userdata,
    /// A native function without upvalues, PUC-Rio's light C function.
    native_fn,
    // Collectable from here on.
    short_string,
    long_string,
    table,
    lua_closure,
    native_closure,
    userdata,
    thread,
    proto,
    upval,
    /// A table key whose value is nil and whose object the collector may
    /// have freed; `next` still finds it by identity.
    dead_key,

    pub inline fn isCollectable(t: Tag) bool {
        return @intFromEnum(t) >= @intFromEnum(Tag.short_string) and t != .dead_key;
    }
};

/// Lua's basic types, in `lua.h`'s order (`LUA_TNIL` .. `LUA_TTHREAD`).
pub const Type = enum(u8) {
    nil,
    boolean,
    light_userdata,
    number,
    string,
    table,
    function,
    userdata,
    thread,

    pub const count = @typeInfo(Type).@"enum".fields.len;

    /// The name `type()` returns.
    pub fn name(t: Type) []const u8 {
        return switch (t) {
            .nil => "nil",
            .boolean => "boolean",
            .light_userdata, .userdata => "userdata",
            .number => "number",
            .string => "string",
            .table => "table",
            .function => "function",
            .thread => "thread",
        };
    }
};

pub const nil: Value = .{ .payload = .{ .int = 0 }, .tag = .nil };
pub const @"false": Value = .{ .payload = .{ .int = 0 }, .tag = .bool_false };
pub const @"true": Value = .{ .payload = .{ .int = 0 }, .tag = .bool_true };

pub inline fn int(i: i64) Value {
    return .{ .payload = .{ .int = i }, .tag = .int };
}

pub inline fn float(f: f64) Value {
    return .{ .payload = .{ .float = f }, .tag = .float };
}

pub inline fn boolean(b: bool) Value {
    return if (b) Value.true else Value.false;
}

pub inline fn lightUserdata(p: ?*anyopaque) Value {
    return .{ .payload = .{ .ptr = p }, .tag = .light_userdata };
}

pub inline fn native(f: NativeFn) Value {
    return .{ .payload = .{ .ptr = @ptrCast(@constCast(f)) }, .tag = .native_fn };
}

pub inline fn string(s: *String) Value {
    return .{ .payload = .{ .gc = &s.header }, .tag = s.header.tag };
}

pub inline fn table(t: *Table) Value {
    return .{ .payload = .{ .gc = &t.header }, .tag = .table };
}

pub inline fn luaClosure(c: *Proto.LuaClosure) Value {
    return .{ .payload = .{ .gc = &c.header }, .tag = .lua_closure };
}

pub inline fn nativeClosure(c: *Proto.NativeClosure) Value {
    return .{ .payload = .{ .gc = &c.header }, .tag = .native_closure };
}

pub inline fn userdata(u: *Userdata) Value {
    return .{ .payload = .{ .gc = &u.header }, .tag = .userdata };
}

pub inline fn thread(t: *Thread) Value {
    return .{ .payload = .{ .gc = &t.header }, .tag = .thread };
}

/// A value for a collectable object of any kind, from its header.
pub inline fn object(h: *gc.Header) Value {
    return .{ .payload = .{ .gc = h }, .tag = h.tag };
}

pub inline fn isNil(v: Value) bool {
    return v.tag == .nil;
}

/// `nil` and `false` are false; everything else is true.
pub inline fn isFalsy(v: Value) bool {
    return @intFromEnum(v.tag) <= @intFromEnum(Tag.bool_false);
}

pub inline fn isInt(v: Value) bool {
    return v.tag == .int;
}

pub inline fn isFloat(v: Value) bool {
    return v.tag == .float;
}

pub inline fn isNumber(v: Value) bool {
    return v.tag == .int or v.tag == .float;
}

pub inline fn isString(v: Value) bool {
    return v.tag == .short_string or v.tag == .long_string;
}

pub inline fn isTable(v: Value) bool {
    return v.tag == .table;
}

pub inline fn isFunction(v: Value) bool {
    return v.tag == .lua_closure or v.tag == .native_closure or v.tag == .native_fn;
}

pub inline fn isCollectable(v: Value) bool {
    return v.tag.isCollectable();
}

pub inline fn asInt(v: Value) i64 {
    std.debug.assert(v.tag == .int);
    return v.payload.int;
}

pub inline fn asFloat(v: Value) f64 {
    std.debug.assert(v.tag == .float);
    return v.payload.float;
}

/// An int or float as a float; the caller checked `isNumber`.
pub inline fn asNumber(v: Value) f64 {
    return if (v.tag == .int) @floatFromInt(v.payload.int) else v.payload.float;
}

pub inline fn asGc(v: Value) *gc.Header {
    std.debug.assert(v.isCollectable());
    return v.payload.gc;
}

pub inline fn asString(v: Value) *String {
    std.debug.assert(v.isString());
    return @fieldParentPtr("header", v.payload.gc);
}

pub inline fn asTable(v: Value) *Table {
    std.debug.assert(v.tag == .table);
    return @fieldParentPtr("header", v.payload.gc);
}

pub inline fn asLuaClosure(v: Value) *Proto.LuaClosure {
    std.debug.assert(v.tag == .lua_closure);
    return @fieldParentPtr("header", v.payload.gc);
}

pub inline fn asNativeClosure(v: Value) *Proto.NativeClosure {
    std.debug.assert(v.tag == .native_closure);
    return @fieldParentPtr("header", v.payload.gc);
}

pub inline fn asNative(v: Value) NativeFn {
    std.debug.assert(v.tag == .native_fn);
    return @ptrCast(v.payload.ptr);
}

pub inline fn asUserdata(v: Value) *Userdata {
    std.debug.assert(v.tag == .userdata);
    return @fieldParentPtr("header", v.payload.gc);
}

pub inline fn asThread(v: Value) *Thread {
    std.debug.assert(v.tag == .thread);
    return @fieldParentPtr("header", v.payload.gc);
}

pub inline fn asLightUserdata(v: Value) ?*anyopaque {
    std.debug.assert(v.tag == .light_userdata);
    return v.payload.ptr;
}

const type_of_tag = blk: {
    var types: [@typeInfo(Tag).@"enum".fields.len]Type = undefined;
    for (@typeInfo(Tag).@"enum".fields) |f| {
        types[f.value] = switch (@as(Tag, @enumFromInt(f.value))) {
            .nil, .dead_key, .proto, .upval => .nil,
            .bool_false, .bool_true => .boolean,
            .int, .float => .number,
            .light_userdata => .light_userdata,
            .native_fn, .lua_closure, .native_closure => .function,
            .short_string, .long_string => .string,
            .table => .table,
            .userdata => .userdata,
            .thread => .thread,
        };
    }
    break :blk types;
};

/// The basic type of `v`.
pub inline fn typeOf(v: Value) Type {
    return type_of_tag[@intFromEnum(v.tag)];
}

/// The float `f` as an integer if it has an exact integer value.
/// TODO(number.zig): use number.zig's conversion once it lands.
pub inline fn floatToInt(f: f64) ?i64 {
    // -2^63 is exact; 2^63 is the first float out of range.
    if (!(f >= -9223372036854775808.0 and f < 9223372036854775808.0)) return null;
    const i: i64 = @intFromFloat(f);
    if (@as(f64, @floatFromInt(i)) != f) return null;
    return i;
}

/// Primitive equality, without `__eq`: numbers by mathematical value, short
/// strings by identity, long strings by contents, the rest by identity.
pub fn rawEquals(a: Value, b: Value) bool {
    if (a.tag != b.tag) {
        if (a.tag == .int and b.tag == .float) return floatToInt(b.payload.float) == a.payload.int;
        if (a.tag == .float and b.tag == .int) return floatToInt(a.payload.float) == b.payload.int;
        // A short and a long string never have the same length.
        return false;
    }
    return switch (a.tag) {
        .nil, .bool_false, .bool_true => true,
        .float => a.payload.float == b.payload.float,
        .long_string => String.eqlLong(a.asString(), b.asString()),
        else => a.payload.int == b.payload.int,
    };
}

const testing = std.testing;

test "falsy values are exactly nil and false" {
    try testing.expect(Value.nil.isFalsy());
    try testing.expect(Value.false.isFalsy());
    try testing.expect(!Value.true.isFalsy());
    try testing.expect(!Value.int(0).isFalsy());
    try testing.expect(!Value.float(0).isFalsy());
}

test "raw equality compares numbers by value across int and float" {
    try testing.expect(rawEquals(.int(3), .float(3.0)));
    try testing.expect(rawEquals(.float(-0.0), .int(0)));
    try testing.expect(!rawEquals(.int(3), .float(3.5)));
    try testing.expect(!rawEquals(.float(std.math.nan(f64)), .float(std.math.nan(f64))));
    // 2^53 + 1 has no float; the nearest float is 2^53, a different integer.
    try testing.expect(!rawEquals(.int((1 << 53) + 1), .float(9007199254740992.0)));
    try testing.expect(rawEquals(.int(std.math.minInt(i64)), .float(-9223372036854775808.0)));
    try testing.expect(!rawEquals(.int(std.math.maxInt(i64)), .float(9223372036854775808.0)));
    try testing.expect(!rawEquals(.nil, .false));
}

test "float to int accepts only exact integral values in range" {
    try testing.expectEqual(@as(?i64, 5), floatToInt(5.0));
    try testing.expectEqual(@as(?i64, null), floatToInt(5.5));
    try testing.expectEqual(@as(?i64, null), floatToInt(9223372036854775808.0));
    try testing.expectEqual(@as(?i64, std.math.minInt(i64)), floatToInt(-9223372036854775808.0));
    try testing.expectEqual(@as(?i64, null), floatToInt(std.math.inf(f64)));
    try testing.expectEqual(@as(?i64, null), floatToInt(std.math.nan(f64)));
}

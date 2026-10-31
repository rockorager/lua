//! The standard libraries and `openLibs`, which opens them into a state,
//! as reference Lua's linit.c does. Each library is a file in this
//! directory with an `open` function that sets its globals.

const std = @import("std");
const Value = @import("../Value.zig");
const State = @import("../State.zig");
const Thread = @import("../Thread.zig");

pub const base = @import("base.zig");
pub const package = @import("package.zig");
pub const io = @import("io.zig");
pub const os = @import("os.zig");
pub const coroutine = @import("coroutine.zig");
pub const debug = @import("debug.zig");
pub const string = @import("string.zig");
pub const table = @import("table.zig");
pub const math = @import("math.zig");
pub const utf8 = @import("utf8.zig");

/// A standard library, by the global it sets, in linit.c's order.
pub const Lib = enum { base, package, coroutine, debug, io, math, os, string, table, utf8 };

/// Each library's global and `open`, indexed by `Lib`.
const libs = [_]struct { []const u8, *const fn (*Thread) Value.Error!void }{
    .{ "_G", base.open },
    .{ "package", package.open },
    .{ "coroutine", onState(coroutine.open) },
    .{ "debug", onState(debug.open) },
    .{ "io", io.open },
    .{ "math", onState(math.open) },
    .{ "os", os.open },
    .{ "string", onState(string.open) },
    .{ "table", onState(table.open) },
    .{ "utf8", onState(utf8.open) },
};

comptime {
    std.debug.assert(libs.len == @typeInfo(Lib).@"enum".fields.len);
}

/// Adapts a library whose `open` takes the state.
fn onState(comptime open: fn (*State) Value.Error!void) fn (*Thread) Value.Error!void {
    return struct {
        fn f(th: *Thread) Value.Error!void {
            return open(th.state);
        }
    }.f;
}

/// Opens every standard library into the globals of `th`'s state, and
/// records each in `package.loaded`, as `luaL_requiref` does. `host`
/// supplies their I/O and must outlive the state.
pub fn openLibs(th: *Thread, host: *base.Host) Value.Error!void {
    return openSome(th, host, .initFull());
}

/// `openLibs` for the libraries in `which` only, in linit.c's order.
pub fn openSome(th: *Thread, host: *base.Host, which: std.EnumSet(Lib)) Value.Error!void {
    try base.setHost(th, host);
    const state = th.state;
    const loaded = try package.registryTable(state, package.loaded_key);
    for (libs, 0..) |lib, i| {
        if (!which.contains(@enumFromInt(i))) continue;
        try lib[1](th);
        const name = try state.newString(lib[0]);
        try loaded.setStr(&state.heap, name, state.globals.getStr(name));
    }
}

test {
    _ = package;
    _ = io;
    _ = os;
}

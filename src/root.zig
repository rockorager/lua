//! Lua 5.5 in Zig, with no C: the language as the Lua 5.5 reference manual
//! defines it, checked against the official Lua 5.5.1 test suite.

const std = @import("std");
const testing = std.testing;

/// The value of the global `_VERSION`, as the reference manual's §6.2 gives it.
pub const version = "Lua 5.5";

test "version is the one the vendored test suite requires" {
    // all.lua exits early unless `_VERSION` is exactly this string.
    const all = try std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        "test/lua-5.5.1-tests/all.lua",
        testing.allocator,
        .limited(1 << 20),
    );
    defer testing.allocator.free(all);
    try testing.expect(std.mem.find(u8, all, "local version = \"" ++ version ++ "\"") != null);
}

test {
    _ = @import("Lexer.zig");
    _ = @import("number.zig");
    _ = @import("lib/pattern.zig");
    _ = @import("lib/format.zig");
    _ = @import("lib/pack.zig");
}

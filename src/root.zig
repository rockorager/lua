//! Lua 5.5 in Zig, with no C: the language as the Lua 5.5 reference manual
//! defines it, checked against the official Lua 5.5.1 test suite.

const std = @import("std");
const testing = std.testing;

const api = @import("api.zig");
const lua_options = @import("lua_options");
const capi = @import("capi/capi.zig");

// A C-API build (`-Dc-api=true`) exports lua.h's and lauxlib.h's functions.
comptime {
    if (lua_options.c_api) _ = capi;
}

// The embedding API: what a host program uses. `docs/embedding.md` is the
// guide.
pub const State = api.State;
pub const Options = api.Options;
pub const Error = api.Error;
pub const Lib = api.Lib;
pub const Libs = api.Libs;
pub const safe_libs = api.safe_libs;
pub const LoadOptions = api.LoadOptions;
pub const DecodeOptions = api.DecodeOptions;
pub const Mode = api.Mode;
pub const Type = api.Type;
pub const Value = api.Value;
pub const Table = api.Table;
pub const Function = api.Function;
pub const Coroutine = api.Coroutine;
pub const Values = api.Values;
pub const Ref = api.Ref;
pub const Args = api.Args;
pub const function = api.function;

/// The engine itself, for the standalone `lua` and the repository's tools.
/// Unstable, and not part of the embedding API.
pub const internal = @import("internal.zig");

/// A single-threaded allocator with fine size classes for small blocks,
/// for `Options.strings`; the `lua` executable allocates strings with it.
pub const SmallAllocator = @import("SmallAllocator.zig");

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
    testing.refAllDecls(@This());
    testing.refAllDecls(internal);
    if (lua_options.c_api) _ = capi;
    if (lua_options.c_api) _ = @import("capi/jmp.zig");
    _ = @import("api_test.zig");
    _ = @import("Lexer.zig");
    _ = @import("number.zig");
    _ = @import("lib/pattern.zig");
    _ = @import("lib/format.zig");
    _ = @import("lib/pack.zig");
    _ = @import("lib/libm.zig");
    _ = @import("lib/auxlib.zig");
    _ = @import("lib/string.zig");
    _ = @import("lib/table.zig");
    _ = @import("lib/math.zig");
    _ = @import("lib/utf8.zig");
    _ = @import("lib/base.zig");
}

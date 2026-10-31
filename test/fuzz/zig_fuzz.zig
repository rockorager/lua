//! Coverage-guided fuzz tests on Zig's fuzzer. `zig build fuzz-zig` runs
//! each once over its corpus, as a test; `zig build fuzz-zig --fuzz`
//! (or `just fuzz-zig`) fuzzes them, guided by coverage. The standalone
//! driver in main.zig does the rest: differential runs, allocation
//! failure, hangs, and memory.

const std = @import("std");
const lua = @import("lua");
const Gen = @import("gen.zig");

test {
    _ = Gen;
}

const seeds = [_][]const u8{
    "local x <const> = 1 + 2 * 3 return x",
    "local function f(a, ...t) return t.n, ... end return f(1, 2, 3)",
    "global x; x = {1, 2, [3] = 4, k = 'v'} for i, v in ipairs(x) do end",
    "goto a ::a:: while true do break end repeat local y until y",
    "return 0x7fffffffffffffff, 1e308, [[long]], '\\u{10FFFF}\\z  '",
    "local a <close> = nil do local b = a end return function() return a end",
    "x = a.b.c:d('e'){f = 1}[g] return #x .. -y ^ 2 // 3 % 4 & 5 | ~6 << 7 >> 8",
};

/// Any source compiles or fails with error.Syntax, and frees what it took.
fn compile(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [4096]u8 = undefined;
    const src = buf[0..smith.slice(&buf)];
    const state = try lua.State.init(std.testing.allocator, .{ .libs = .initEmpty(), .seed = 1 });
    defer state.close();
    _ = state.load(src, .{ .name = "=fuzz" }) catch |e| switch (e) {
        error.Syntax => {},
        else => return e,
    };
}

test "the compiler takes any source" {
    try std.testing.fuzz({}, compile, .{ .corpus = &seeds });
}

/// Any binary chunk loads or fails with "bad binary format" (or, with its
/// first byte changed, is refused as text).
fn undump(chunks: []const []const u8, smith: *std.testing.Smith) anyerror!void {
    var buf: [8192]u8 = undefined;
    const base = chunks[smith.index(chunks.len)];
    const n = @min(base.len, buf.len);
    @memcpy(buf[0..n], base[0..n]);
    // A few edits of the dump: the fuzzer picks where and what.
    var len: usize = n;
    var edits = smith.valueRangeAtMost(u8, 1, 8);
    while (edits > 0) : (edits -= 1) {
        if (len == 0) break;
        const at = smith.index(len);
        switch (smith.valueRangeAtMost(u8, 0, 2)) {
            0 => buf[at] = smith.value(u8),
            1 => len = at,
            else => buf[at] ^= @as(u8, 1) << smith.value(u3),
        }
    }
    const state = try lua.State.init(std.testing.allocator, .{ .libs = .initEmpty(), .seed = 1 });
    defer state.close();
    _ = state.load(buf[0..len], .{ .name = "=c", .mode = .binary }) catch |e| switch (e) {
        error.Syntax => {
            const msg = state.errorMessage();
            if (!std.mem.startsWith(u8, msg, "c: bad binary format (") and
                !std.mem.startsWith(u8, msg, "attempt to load a text chunk")) return error.UnexpectedMessage;
        },
        else => return e,
    };
}

test "the loader refuses or loads any binary chunk" {
    const state = try lua.State.init(std.testing.allocator, .{});
    defer state.close();
    const dumper = try state.doString(lua.Function, "return function(s) local f = load(s) return f and string.dump(f) end", .{});
    var chunks: std.ArrayList([]const u8) = .empty;
    defer {
        for (chunks.items) |c| std.testing.allocator.free(c);
        chunks.deinit(std.testing.allocator);
    }
    for (seeds) |src| {
        const d = try state.call(?[]const u8, dumper, .{src}) orelse continue;
        try chunks.append(std.testing.allocator, try std.testing.allocator.dupe(u8, d));
    }
    try std.testing.fuzz(@as([]const []const u8, chunks.items), undump, .{});
}

/// Generated programs, chosen by the fuzzer's seed, compile and run
/// without crashing.
fn generated(_: void, smith: *std.testing.Smith) anyerror!void {
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(std.testing.allocator);
    try Gen.program(std.testing.allocator, &src, smith.value(u64), if (smith.value(bool)) .diff else .wild);
    var discard_buf: [64]u8 = undefined;
    var discard: std.Io.Writer.Discarding = .init(&discard_buf);
    const state = try lua.State.init(std.testing.allocator, .{ .seed = 1, .stdout = &discard.writer });
    defer state.close();
    state.doString(void, src.items, .{ .name = "@gen.lua" }) catch |e| switch (e) {
        error.Syntax, error.Runtime => {},
        else => return e,
    };
}

test "generated programs run" {
    try std.testing.fuzz({}, generated, .{});
}

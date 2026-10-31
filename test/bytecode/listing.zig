//! Compiles Lua files and prints their bytecode as `luac -l -l -p` lists it,
//! addresses masked to 0x0. `just bytecode` diffs this against the
//! reference luac over the suite and the benchmarks.

const std = @import("std");
const lua = @import("lua").internal;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var out_buf: [64 * 1024]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &out_buf);
    const w = &out.interface;
    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.skip();
    var status: u8 = 0;
    while (args.next()) |path| {
        const state = try lua.State.create(gpa, .{});
        defer state.destroy();
        const raw = try std.Io.Dir.cwd().readFileAllocOptions(io, path, gpa, .limited(1 << 26), .of(u8), 0);
        defer gpa.free(raw);
        // Like luaL_loadfile, skip a first line starting with '#' but keep
        // its newline, so line numbers stay.
        var src: [:0]const u8 = raw;
        if (src.len > 0 and src[0] == '#') src = src[std.mem.findScalar(u8, src, '\n') orelse src.len ..];
        const name = try std.fmt.allocPrint(gpa, "@{s}", .{path});
        defer gpa.free(name);
        const p = lua.Parser.compile(state.main, src, name) catch |e| switch (e) {
            error.LuaError => {
                try w.flush();
                std.debug.print("{s}\n", .{state.main.err.asString().bytes()});
                status = 1;
                continue;
            },
            else => return e,
        };
        try lua.Code.writeListing(w, p);
    }
    try w.flush();
    std.process.exit(status);
}

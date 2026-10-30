const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The one exported module. Everything below is a developer step, so a
    // consumer's fetch graph stops at this module.
    const mod = b.addModule("lua", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    if (b.pkg_hash.len != 0) return;

    // The standalone interpreter, `lua`, as reference Lua's lua.c.
    const exe = b.addExecutable(.{
        .name = "lua",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "lua", .module = mod }},
        }),
    });
    b.installArtifact(exe);
    const run_exe = b.addRunArtifact(exe);
    if (b.args) |args| run_exe.addArgs(args);
    b.step("run", "Run the lua interpreter").dependOn(&run_exe.step);

    // The bytecode lister `just bytecode` compares with `luac -l -l`.
    const listing = b.addExecutable(.{
        .name = "listing",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/bytecode/listing.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "lua", .module = mod }},
        }),
    });
    b.step("listing", "Build the bytecode lister").dependOn(&b.addInstallArtifact(listing, .{}).step);

    // Every step below needs testingx, which is lazy so a consumer never
    // fetches it. On the first configure pass it is not fetched yet, and the
    // build runner fetches it and reruns this script.
    const testingx = b.lazyDependency("testingx", .{ .target = target }) orelse return;
    const runner: std.Build.Step.Compile.TestRunner = .{
        .path = testingx.path("src/runner.zig"),
        .mode = .simple,
    };

    const mod_tests = b.addTest(.{ .root_module = mod, .test_runner = runner });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    // Tests read the vendored suite under `test/`, so they run from the root.
    run_mod_tests.setCwd(b.path("."));
    run_mod_tests.addArg(b.fmt("--seed=0x{x}", .{b.graph.random_seed}));
    b.step("test", "Run the unit tests").dependOn(&run_mod_tests.step);
}

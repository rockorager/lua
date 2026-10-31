const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The C API (lua.h and lauxlib.h, for compiled Lua C modules), off by
    // default: `-Dc-api=true` here, `.c_api = true` from a host's
    // build.zig. It links libc; without it the build is libc-free.
    const c_api = (b.option(bool, "c-api", "Export Lua 5.5.1's C API and load C modules (links libc)") orelse false) or
        (b.option(bool, "c_api", "Same as -Dc-api, under the name a dependency passes") orelse false);
    const lua_options = b.addOptions();
    lua_options.addOption(bool, "c_api", c_api);

    // The one exported module. Everything below is a developer step, so a
    // consumer's fetch graph stops at this module.
    const mod = b.addModule("lua", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = if (c_api) true else null,
    });
    mod.addOptions("lua_options", lua_options);

    if (b.pkg_hash.len != 0) return;

    // The standalone interpreter, `lua`, as reference Lua's lua.c. It
    // builds its own instance of the module without frame pointers in
    // optimized builds: the interpreter loop needs every register
    // (docs/slop/results/frame-pointer-20261030.md).
    const omit_fp: ?bool = if (optimize == .Debug) null else true;
    // Nor unwind tables: only Debug's stack traces read them, and they
    // are 50 KiB of read-only data mapped next to the constants
    // (docs/slop/results/lean-20261031.md).
    const unwind: ?std.builtin.UnwindTables = if (optimize == .Debug) null else .none;
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .omit_frame_pointer = omit_fp,
        .unwind_tables = unwind,
        .link_libc = if (c_api) true else null,
    });
    exe_mod.addOptions("lua_options", lua_options);
    const exe = b.addExecutable(.{
        .name = "lua",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .omit_frame_pointer = omit_fp,
            .unwind_tables = unwind,
            .imports = &.{.{ .name = "lua", .module = exe_mod }},
        }),
    });
    // Collector stress for the suite: `full` collects at every safe point,
    // `step` takes one incremental step at each.
    const exe_options = b.addOptions();
    const gc_stress = b.option([]const u8, "gc-stress", "Collector stress in the lua executable: off, full, or step");
    exe_options.addOption([]const u8, "gc_stress", gc_stress orelse "off");
    exe.root_module.addOptions("build_options", exe_options);
    if (c_api) {
        // C modules link against the executable's own lua_* symbols, as
        // lua.c's `-Wl,-E` exports them, and build with the headers
        // installed to zig-out/include. Zig builds glibc-linked code
        // position-independent, which costs the interpreter loop a
        // register for its jump table base
        // (docs/slop/results/c-api-20261031.md).
        exe.rdynamic = true;
        b.installDirectory(.{ .source_dir = b.path("include"), .install_dir = .header, .install_subdir = "" });
        // liblua for C hosts, as the reference's: `liblua.a`, `liblua.so`,
        // and a pkg-config file, exporting lua.h's, lauxlib.h's, and
        // lualib.h's functions (docs/slop/c-api.md).
        for ([_]std.builtin.LinkMode{ .static, .dynamic }) |linkage| {
            const lib_mod = b.createModule(.{
                .root_source_file = b.path("src/root.zig"),
                .target = target,
                .optimize = optimize,
                .omit_frame_pointer = omit_fp,
                .link_libc = true,
                .pic = true,
            });
            lib_mod.addOptions("lua_options", lua_options);
            const liblua = b.addLibrary(.{
                .name = "lua",
                .linkage = linkage,
                .root_module = lib_mod,
                .version = if (linkage == .dynamic) .{ .major = 5, .minor = 5, .patch = 1 } else null,
            });
            // A C host's linker has no Zig runtime to resolve against.
            liblua.bundle_compiler_rt = true;
            liblua.bundle_ubsan_rt = false;
            if (linkage == .dynamic) liblua.setVersionScript(b.path("src/capi/liblua.map"));
            b.installArtifact(liblua);
        }
        const pc = b.addWriteFiles().add("lua5.5.pc", b.fmt(
            \\prefix={s}
            \\libdir=${{prefix}}/lib
            \\includedir=${{prefix}}/include
            \\
            \\Name: Lua
            \\Description: Lua 5.5.1 in Zig, with the C API
            \\Version: 5.5.1
            \\Libs: -L${{libdir}} -llua
            \\Cflags: -I${{includedir}}
            \\
        , .{b.install_prefix}));
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(pc, .lib, "pkgconfig/lua5.5.pc").step);
    }
    // Optimized builds put the functions a short run calls first ahead of
    // the rest (src/order.ld, from `just order`): the kernel maps code
    // 64 KiB around each page that faults, so scattered first calls kept
    // nearly all of it resident (docs/slop/results/lean-20261031.md).
    if (optimize != .Debug) {
        exe.link_function_sections = true;
        exe.setLinkerScript(b.path("src/order.ld"));
    }
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

    // The tracer `just order` writes src/order.ld with (test/order/main.zig).
    const order = b.addExecutable(.{
        .name = "order",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/order/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.step("order", "Build the startup-order tracer").dependOn(&b.addInstallArtifact(order, .{}).step);

    // The fuzz driver `just fuzz` runs (test/fuzz/main.zig).
    const fuzz = b.addExecutable(.{
        .name = "fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/fuzz/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "lua", .module = mod }},
        }),
    });
    // With -Dc-api, its `capi` target loads test/fuzz/capifuzz.c, a C
    // module, which links against the driver's own lua_* symbols.
    const fuzz_options = b.addOptions();
    fuzz_options.addOption(bool, "capi_module", c_api);
    fuzz.root_module.addOptions("fuzz_options", fuzz_options);
    fuzz.rdynamic = c_api;
    b.step("fuzz", "Build the fuzz driver").dependOn(&b.addInstallArtifact(fuzz, .{}).step);

    // Coverage-guided fuzz tests on Zig's own fuzzer: `zig build
    // fuzz-zig --fuzz`. They need the default test runner.
    const fuzz_tests = b.addTest(.{
        .name = "fuzz-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/fuzz/zig_fuzz.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "lua", .module = mod }},
        }),
    });
    const run_fuzz_tests = b.addRunArtifact(fuzz_tests);
    run_fuzz_tests.setCwd(b.path("."));
    b.step("fuzz-zig", "Run the coverage-guided fuzz tests (add --fuzz to fuzz)").dependOn(&run_fuzz_tests.step);

    // The example host, which the embedding guide walks through.
    const example_mod = b.createModule(.{
        .root_source_file = b.path("examples/host/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lua", .module = mod }},
    });
    const example = b.addExecutable(.{ .name = "example-host", .root_module = example_mod });
    const run_example = b.addRunArtifact(example);
    if (b.args) |args| run_example.addArgs(args);
    b.step("example", "Run the example host").dependOn(&run_example.step);

    // The embedding API's cost against the engine's own path, for `just
    // bench-api`.
    const bench_api = b.addExecutable(.{
        .name = "bench-api",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/api/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "lua", .module = mod }},
        }),
    });
    b.step("bench-api", "Build the embedding API benchmark").dependOn(&b.addInstallArtifact(bench_api, .{}).step);

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
    const example_tests = b.addTest(.{ .root_module = example_mod, .test_runner = runner });
    const run_example_tests = b.addRunArtifact(example_tests);
    run_example_tests.addArg(b.fmt("--seed=0x{x}", .{b.graph.random_seed}));
    const test_step = b.step("test", "Run the unit tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_example_tests.step);
    // The fuzzers build, and their Zig fuzz tests run once on their seeds.
    test_step.dependOn(&fuzz.step);
    test_step.dependOn(&run_fuzz_tests.step);
}

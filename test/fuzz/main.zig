//! The fuzz driver behind `just fuzz`. Each command runs one fuzzer until
//! its time is up and writes what it finds under `zig-out/fuzz/<command>/`:
//! the failing input, minimized, and what went wrong.
//!
//! In-process targets run in a forked child that reports each input to
//! the parent through shared memory before running it, so a crash, a
//! safety panic, a hang, a leak, or a wrong outcome is caught with the
//! input that caused it:
//!
//!   run parse    mutated suite, bench, and corpus files, generated
//!                programs, and token soup through `State.load`: a chunk
//!                compiles or fails with error.Syntax, within time and
//!                memory, and frees everything at `close`.
//!   run grammar  generated programs, compiled and run with the safe
//!                libraries; with --gc-stress, under collector stress.
//!   run binary   corrupted `string.dump` output through `load(..., "b")`:
//!                the loader must refuse it or load it ("not enough
//!                memory" for a count past the cap, holding nothing).
//!                A crash or hang while running a chunk that loaded is
//!                the known limit (the loader checks opcodes, not the
//!                code), and is written to `known/` instead.
//!   run oom      every program in `oom_programs` and the API scenario,
//!                with the Nth allocation failing, for every N, once
//!                (later allocations succeed) and from then on: the error
//!                is error.OutOfMemory or "not enough memory", nothing
//!                leaks, and the state still runs code or closes.
//!   run capi     the same sweep over generated C-API workloads, which
//!                load test/fuzz/capifuzz.c from --module and call it:
//!                allocation failure at every index through C module
//!                calls. Needs a fuzz driver built with -Dc-api=true.
//!
//! The differential commands compare with the dev shell's reference:
//!
//!   diff      generated deterministic programs on our `lua` and the
//!             reference: stdout, stderr, and exit status.
//!   bytecode  generated programs through `listing` and `luac -l -l -p`.
//!   messages  malformed sources through `load` on both, in batches: the
//!             same syntax error, or the same success.
//!   binary-diff  corrupted dumps through `load(..., "b")` on both.
//!   capi-diff generated C-API workloads, which call capifuzz.so from
//!             --module, on our C-API `lua` and the reference.

const std = @import("std");
const lua = @import("lua");
const fuzz_options = @import("fuzz_options");
const Gen = @import("gen.zig");
const linux = std.os.linux;

const max_input = 1 << 20;

const usage =
    \\usage: fuzz run (parse|grammar|binary|oom|capi) [options]
    \\       fuzz (diff|bytecode|messages|binary-diff|capi-diff) [options]
    \\       fuzz repro (parse|grammar|binary) FILE
    \\       fuzz repro (oom|capi) FILE N (once|always) [lax]
    \\       fuzz gen SEED [diff|wild|capi]
    \\options:
    \\  --seconds N     how long to run (default 60)
    \\  --seed N        the first seed (default: from the clock)
    \\  --gc-stress M   full or step: collector stress for in-process runs
    \\  --ours PATH     our lua for the differential commands (zig-out/bin/lua)
    \\  --out DIR       where findings go (zig-out/fuzz)
    \\  --stack KIB     run in-process inputs on a thread with this much stack
    \\  --module DIR    the directory of capifuzz.so (zig-out/fuzz-capi/lib)
    \\
;

const Options = struct {
    seconds: u64 = 60,
    seed: ?u64 = null,
    gc_stress: @FieldType(lua.Options, "gc_stress") = .off,
    ours: []const u8 = "zig-out/bin/lua",
    listing: []const u8 = "zig-out/bin/listing",
    out: []const u8 = "zig-out/fuzz",
    /// Run the inputs on a thread with this much stack, as a host's
    /// worker thread might, instead of the main thread's 8 MiB.
    stack: ?usize = null,
    /// Where `capi` and `capi-diff` find capifuzz.so.
    module: []const u8 = "zig-out/fuzz-capi/lib",
};

var io: std.Io = undefined;
/// What lives for the whole run: the corpus, paths, what was seen.
const perm = std.heap.smp_allocator;
/// Everything else: in the differential commands, an arena reset after
/// each program or batch.
var gpa: std.mem.Allocator = perm;

pub fn main(init: std.process.Init) !void {
    io = init.io;
    var args: std.ArrayList([]const u8) = .empty;
    var it = try init.minimal.args.iterateAllocator(gpa);
    defer it.deinit();
    _ = it.skip();
    var opts: Options = .{};
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--seconds")) {
            opts.seconds = try std.fmt.parseInt(u64, it.next() orelse return fail(), 10);
        } else if (std.mem.eql(u8, a, "--seed")) {
            opts.seed = try std.fmt.parseInt(u64, it.next() orelse return fail(), 10);
        } else if (std.mem.eql(u8, a, "--gc-stress")) {
            opts.gc_stress = std.meta.stringToEnum(@TypeOf(opts.gc_stress), it.next() orelse return fail()) orelse return fail();
        } else if (std.mem.eql(u8, a, "--ours")) {
            opts.ours = try gpa.dupe(u8, it.next() orelse return fail());
        } else if (std.mem.eql(u8, a, "--stack")) {
            opts.stack = 1024 * try std.fmt.parseInt(usize, it.next() orelse return fail(), 10);
        } else if (std.mem.eql(u8, a, "--module")) {
            opts.module = try gpa.dupe(u8, it.next() orelse return fail());
        } else if (std.mem.eql(u8, a, "--out")) {
            opts.out = try gpa.dupe(u8, it.next() orelse return fail());
        } else try args.append(gpa, try gpa.dupe(u8, a));
    }
    if (args.items.len == 0) return fail();
    const cmd = args.items[0];
    const seed = opts.seed orelse @as(u64, @intCast(nowMs())) *% 0x9e3779b97f4a7c15;
    if (std.mem.eql(u8, cmd, "gen")) {
        if (args.items.len < 2) return fail();
        var buf: std.ArrayList(u8) = .empty;
        const program_seed = try std.fmt.parseInt(u64, args.items[1], 10);
        if (args.items.len > 2 and std.mem.eql(u8, args.items[2], "capi")) {
            try capiProgram(&buf, program_seed, opts.module);
        } else {
            const mode: Gen.Mode = if (args.items.len > 2 and std.mem.eql(u8, args.items[2], "wild")) .wild else .diff;
            try Gen.program(gpa, &buf, program_seed, mode);
        }
        try std.Io.File.stdout().writeStreamingAll(io, buf.items);
        return;
    }
    if (std.mem.eql(u8, cmd, "run")) {
        if (args.items.len < 2) return fail();
        const target = std.meta.stringToEnum(Target, args.items[1]) orelse return fail();
        return supervise(target, opts, seed);
    }
    if (std.mem.eql(u8, cmd, "repro")) {
        if (args.items.len < 3) return fail();
        const target = std.meta.stringToEnum(Target, args.items[1]) orelse return fail();
        const data = try std.Io.Dir.cwd().readFileAlloc(io, args.items[2], gpa, .limited(max_input));
        var ctx: Ctx = .{ .opts = opts, .rng = undefined, .corpus = &.{} };
        var case: u64 = 0;
        if (target.sweeps()) {
            if (args.items.len < 5) return fail();
            ctx.oom_lax = args.items.len > 5 and std.mem.eql(u8, args.items[5], "lax");
            ctx.capi = target == .capi;
            const n = try std.fmt.parseInt(u64, args.items[3], 10);
            const always: u64 = @intFromBool(std.mem.eql(u8, args.items[4], "always"));
            case = n << 1 | always;
        }
        const outcome = if (opts.stack) |size| blk: {
            var result: Outcome = .ok;
            const t = try std.Thread.spawn(.{ .stack_size = size }, struct {
                fn run(c: *Ctx, tg: Target, d: []const u8, cs: u64, r: *Outcome) void {
                    r.* = runOne(c, tg, d, cs);
                }
            }.run, .{ &ctx, target, data, case, &result });
            t.join();
            break :blk result;
        } else runOne(&ctx, target, data, case);
        std.debug.print("{s}\n", .{outcome.describe()});
        std.process.exit(if (outcome == .ok) 0 else 1);
    }
    const diff_cmd = std.meta.stringToEnum(DiffCommand, cmd) orelse return fail();
    return differential(diff_cmd, opts, seed);
}

fn fail() error{Usage} {
    std.debug.print("{s}", .{usage});
    return error.Usage;
}

fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn sleepMs(ms: u32) void {
    const ts: linux.timespec = .{ .sec = 0, .nsec = @as(isize, ms) * 1_000_000 };
    _ = linux.nanosleep(&ts, null);
}

// ---------------------------------------------------------------------
// Allocators
// ---------------------------------------------------------------------

/// Counts what a state holds and refuses to go past `cap`, so a chunk
/// that wants unbounded memory gets "not enough memory" instead of the
/// machine's. Can fail the Nth allocation (counting growth by `resize`
/// and `remap`), once or from then on.
const Counting = struct {
    backing: std.mem.Allocator,
    cap: usize = 1 << 30,
    live: usize = 0,
    peak: usize = 0,
    events: u64 = 0,
    fail_at: u64 = std.math.maxInt(u64),
    fail_always: bool = false,
    failed: bool = false,

    fn allocator(c: *Counting) std.mem.Allocator {
        return .{ .ptr = c, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn shouldFail(c: *Counting, grow: usize) bool {
        if (c.live + grow > c.cap) return true;
        const n = c.events;
        c.events += 1;
        if (n == c.fail_at or (c.fail_always and n > c.fail_at)) {
            c.failed = true;
            return true;
        }
        return false;
    }

    fn note(c: *Counting, add: usize, sub: usize) void {
        c.live = c.live + add - sub;
        c.peak = @max(c.peak, c.live);
    }

    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const c: *Counting = @ptrCast(@alignCast(ctx));
        if (c.shouldFail(len)) return null;
        const p = c.backing.rawAlloc(len, a, ra) orelse return null;
        c.note(len, 0);
        return p;
    }

    fn resize(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const c: *Counting = @ptrCast(@alignCast(ctx));
        if (new_len > mem.len and c.shouldFail(new_len - mem.len)) return false;
        if (!c.backing.rawResize(mem, a, new_len, ra)) return false;
        c.note(new_len, mem.len);
        return true;
    }

    fn remap(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const c: *Counting = @ptrCast(@alignCast(ctx));
        if (new_len > mem.len and c.shouldFail(new_len - mem.len)) return null;
        const p = c.backing.rawRemap(mem, a, new_len, ra) orelse return null;
        c.note(new_len, mem.len);
        return p;
    }

    fn free(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, ra: usize) void {
        const c: *Counting = @ptrCast(@alignCast(ctx));
        c.backing.rawFree(mem, a, ra);
        c.note(0, mem.len);
    }
};

// ---------------------------------------------------------------------
// In-process targets
// ---------------------------------------------------------------------

const Target = enum {
    parse,
    grammar,
    binary,
    oom,
    capi,

    /// Whether the target sweeps allocation failures over fixed programs.
    fn sweeps(t: Target) bool {
        return t == .oom or t == .capi;
    }
};

const Outcome = union(enum) {
    ok,
    /// The state still held this many bytes after `close`.
    leak: usize,
    /// A wrong error, or a wrong result: the message says which.
    wrong: []const u8,
    /// A small input that needed this much memory.
    memory: usize,

    fn describe(o: Outcome) []const u8 {
        return switch (o) {
            .ok => "ok",
            .leak => |n| std.fmt.allocPrint(gpa, "leak: {d} bytes held after close", .{n}) catch "leak",
            .wrong => |m| m,
            .memory => |n| std.fmt.allocPrint(gpa, "memory: peak {d} bytes", .{n}) catch "memory",
        };
    }

    fn code(o: Outcome) u8 {
        return switch (o) {
            .ok => 0,
            .leak => 3,
            .wrong => 4,
            .memory => 5,
        };
    }
};

const Ctx = struct {
    opts: Options,
    rng: std.Random,
    corpus: []const []const u8,
    /// `string.dump` output of corpus programs, for `binary`.
    dumps: []const []const u8 = &.{},
    shared: ?*Shared = null,
    /// More programs for `oom`: test/diff's, which catch errors with
    /// pcall and go on, so any error is fine; only crashes, leaks, hangs,
    /// and a state left unusable count.
    oom_extra: []const []const u8 = &.{},
    oom_lax: bool = false,
    /// The programs a sweep goes through, and how many of them, from the
    /// first, are strict: any error must be "not enough memory".
    oom_set: []const []const u8 = &.{},
    oom_strict: usize = 0,
    /// The programs load capifuzz, so the state needs `package`.
    capi: bool = false,
};

/// Runs one input in this process. For `oom`, `case` is the allocation
/// to fail, shifted left one, with the low bit set to keep failing.
fn runOne(ctx: *Ctx, target: Target, input: []const u8, case: u64) Outcome {
    return switch (target) {
        .parse => runParse(ctx, input),
        .grammar => runGrammar(ctx, input),
        .binary => runBinary(ctx, input),
        .oom, .capi => runOom(ctx, input, case),
    };
}

fn setPhase(ctx: *Ctx, phase: Phase) void {
    if (ctx.shared) |s| @atomicStore(u32, &s.phase, @intFromEnum(phase), .seq_cst);
}

fn runParse(ctx: *Ctx, input: []const u8) Outcome {
    var counting: Counting = .{ .backing = std.heap.smp_allocator };
    {
        const state = lua.State.init(counting.allocator(), .{ .libs = .initEmpty(), .seed = 1, .gc_stress = ctx.opts.gc_stress }) catch
            return .{ .wrong = "State.init failed" };
        defer state.close();
        setPhase(ctx, .load);
        if (state.load(input, .{ .name = "=fuzz" })) |_| {} else |e| switch (e) {
            error.Syntax => {},
            error.OutOfMemory => if (input.len < 1 << 16) return .{ .memory = counting.peak },
            error.Runtime => return .{ .wrong = "load returned error.Runtime" },
        }
        setPhase(ctx, .idle);
    }
    if (counting.live != 0) return .{ .leak = counting.live };
    if (counting.peak > (64 << 20) + 256 * input.len) return .{ .memory = counting.peak };
    return .ok;
}

var discard_buf: [256]u8 = undefined;

fn runGrammar(ctx: *Ctx, input: []const u8) Outcome {
    var counting: Counting = .{ .backing = std.heap.smp_allocator };
    var discard: std.Io.Writer.Discarding = .init(&discard_buf);
    {
        const state = lua.State.init(counting.allocator(), .{ .seed = 1, .stdout = &discard.writer, .gc_stress = ctx.opts.gc_stress }) catch
            return .{ .wrong = "State.init failed" };
        defer state.close();
        setPhase(ctx, .run);
        state.doString(void, input, .{ .name = "@gen.lua" }) catch |e| switch (e) {
            error.Syntax, error.Runtime => {},
            error.OutOfMemory => return .{ .memory = counting.peak },
        };
        // The state is still usable after whatever the program did.
        const n = state.doString(i64, "local t = {} for i = 1, 10 do t[i] = i end return #t", .{}) catch 0;
        if (n != 10) return .{ .wrong = "state unusable after the program" };
        setPhase(ctx, .idle);
    }
    if (counting.live != 0) return .{ .leak = counting.live };
    return .ok;
}

const binary_runner =
    \\local chunk = ...
    \\debug.sethook(function(e) if e == "count" then error("instruction budget", 0) end end, "l", 1000000)
    \\local ok = pcall(chunk)
    \\debug.sethook()
;

fn runBinary(ctx: *Ctx, input: []const u8) Outcome {
    var counting: Counting = .{ .backing = std.heap.smp_allocator, .cap = 256 << 20 };
    var discard: std.Io.Writer.Discarding = .init(&discard_buf);
    const outcome: Outcome = blk: {
        var libs = lua.safe_libs;
        libs.insert(.debug);
        const state = lua.State.init(counting.allocator(), .{ .seed = 1, .libs = libs, .stdout = &discard.writer }) catch
            return .{ .wrong = "State.init failed" };
        defer state.close();
        const runner = state.load(binary_runner, .{ .name = "=runner" }) catch return .{ .wrong = "runner did not compile" };
        setPhase(ctx, .load);
        const f = state.load(input, .{ .name = "=chunk", .mode = .binary }) catch |e| switch (e) {
            error.Syntax => {
                const msg = state.errorMessage();
                if (std.mem.startsWith(u8, msg, "chunk: bad binary format (") or
                    std.mem.startsWith(u8, msg, "attempt to load a text chunk")) break :blk .ok;
                break :blk .{ .wrong = std.fmt.allocPrint(gpa, "unexpected load error: {s}", .{msg}) catch "unexpected load error" };
            },
            // The loader asks for the block a count needs, as the
            // reference does, but fills only what the chunk holds: a
            // refused block is "not enough memory" there too, and only
            // memory still held after the failure is a finding.
            error.OutOfMemory => break :blk if (counting.live > (64 << 20) + 256 * input.len) .{ .memory = counting.live } else .ok,
            error.Runtime => break :blk .{ .wrong = "load returned error.Runtime" },
        };
        // Line lookups on a loaded chunk stay in bounds whatever its
        // line info says, so every one the interpreter and the debug
        // library make is a finding if it crashes.
        if (f.raw.tag == .lua_closure) walkLines(f.raw.asLuaClosure().proto, 0);
        // The chunk loaded: running it is the known limit, and so is a
        // crash in `close` after it ran, as the run may have broken the
        // heap. The phase stays `run` until the state is gone.
        setPhase(ctx, .run);
        state.call(void, runner, .{f}) catch {};
        break :blk .ok;
    };
    setPhase(ctx, .idle);
    if (outcome != .ok) return outcome;
    return leakCheck(&counting);
}

/// Every line lookup on `p` and its nested functions: `lineAt` at each
/// pc and past the end, `changedLine` as the line hook asks it, and the
/// `nextLine` walk of `debug.getinfo`'s "L".
fn walkLines(p: *const lua.internal.Proto, depth: u32) void {
    var sink: i64 = 0;
    const n = p.code.len;
    for (0..n + 2) |pc| sink +%= p.lineAt(pc) orelse 0;
    for (1..@max(n, 1)) |pc| {
        sink +%= @intFromBool(p.changedLine(pc - 1, pc));
        sink +%= @intFromBool(p.changedLine(0, pc));
        if (pc >= 70) sink +%= @intFromBool(p.changedLine(pc - 70, pc));
    }
    var line: i32 = @bitCast(p.linedefined);
    for (0..p.lineinfo.len) |pc| line = p.nextLine(line, pc);
    std.mem.doNotOptimizeAway(sink +% line);
    if (depth < 200) for (p.p) |c| walkLines(c, depth + 1);
}

fn leakCheck(counting: *const Counting) Outcome {
    return if (counting.live != 0) .{ .leak = counting.live } else .ok;
}

/// Small programs for the allocation-failure sweep. Each runs without
/// pcall, so the only way an allocation failure can end it is with the
/// error "not enough memory".
const oom_programs = [_][]const u8{
    "local t = {} for i = 1, 100 do t[i] = i .. '' end return #t",
    "local s = '' for i = 1, 50 do s = s .. string.rep('x', i) end return #s",
    "local t = {} for i = 1, 200 do t['k' .. i] = {i} end local n = 0 for k, v in pairs(t) do n = n + v[1] end return n",
    "local function f(n) if n == 0 then return 0 end return 1 + f(n - 1) end return f(300)",
    "local co = coroutine.wrap(function(a) for i = 1, 10 do a = coroutine.yield(a + i) end return a end) local x = 0 for i = 1, 11 do x = co(x) end return x",
    "return string.format('%d %s %q %g %5.2f', 1, 'two', 'th\\nree', 4.5, math.pi) .. table.concat({1, 2, 3}, ',')",
    "local t = {} for w in ('the quick brown fox jumps over the lazy dog'):gmatch('%a+') do t[#t + 1] = w:upper() end table.sort(t) return table.concat(t, ' ')",
    "return (('hello world'):gsub('(%w+)', '<%1>')) .. select(2, ('abc'):gsub('.', {a = 1, b = false}))",
    "local f = assert(load('local a, b = ... return a + b, function() return a end')) local x, g = f(1, 2) return x + g()",
    "local mt = {__index = function(t, k) return k .. '!' end, __add = function(a, b) return 3 end, __tostring = function() return 'obj' end} local o = setmetatable({}, mt) return o.x .. tostring(o) .. (o + o)",
    "local d = string.dump(function(a) return a * 2 end) return assert(load(d, 'd', 'b'))(21)",
    "local t = setmetatable({}, {__mode = 'k'}) for i = 1, 50 do t[{}] = i end collectgarbage() return 1",
    "local x = 0 for i = 1, 20 do local o = setmetatable({}, {__gc = function() x = x + 1 end}) end collectgarbage() collectgarbage() return x",
    "do local a <close> = setmetatable({}, {__close = function() end}) local t = table.pack(1, 2, 3) return t.n + #table.concat({'a', 'b'}) end",
    "return utf8.char(72, 228, 8364, 128512) .. string.pack('<i4z', 7, 'zz') .. #string.rep('ab', 100, ',')",
    "local t = {} for i = 1, 30 do table.insert(t, 1, i) end table.remove(t, 5) return table.unpack(t, 1, 3)",
    "local function gen(...t) return t.n, ... end return gen(1, 2, 3)",
    "local s = {} for i = 1, 40 do s[#s + 1] = tostring(i * 1.5) .. tostring(i) end return #table.concat(s)",
    "local ok, e = pcall(error, {code = 1}) local x = xpcall(function() return nil + 1 end, function(m) return m end) if ok or x then return 0 end return e.code",
    "collectgarbage('generational') local t = {} for i = 1, 300 do t[i % 17] = {i} end collectgarbage('incremental') return #t",
    "local co = coroutine.create(function() local x <close> = setmetatable({}, {__close = function() end}) coroutine.yield(1) end) coroutine.resume(co) return coroutine.close(co)",
    "return assert(load('return ' .. string.rep('(', 50) .. '1' .. string.rep(')', 50)))() + #string.format('%099d', 7)",
};

/// The input of an `oom` case: an index into `oom_programs`, or the API
/// scenario at `oom_programs.len`, as text so `repro` can read it.
fn runOom(ctx: *Ctx, input: []const u8, case: u64) Outcome {
    const fail_at = case >> 1;
    const always = case & 1 == 1;
    var debug_alloc: std.heap.DebugAllocator(.{ .stack_trace_frames = 8 }) = .init;
    var counting: Counting = .{ .backing = debug_alloc.allocator(), .fail_at = fail_at, .fail_always = always };
    const outcome = oomCase(ctx, &counting, input);
    if (debug_alloc.deinit() == .leak) return .{ .leak = counting.live };
    if (outcome != .ok) return outcome;
    if (counting.live != 0) return .{ .leak = counting.live };
    return .ok;
}

fn oomCase(ctx: *Ctx, counting: *Counting, input: []const u8) Outcome {
    var discard: std.Io.Writer.Discarding = .init(&discard_buf);
    var libs = lua.safe_libs;
    if (ctx.capi) libs.insert(.package);
    const state = lua.State.init(counting.allocator(), .{
        .seed = 1,
        .stdout = &discard.writer,
        .gc_stress = ctx.opts.gc_stress,
        .libs = libs,
        .io = if (ctx.capi) io else null,
    }) catch |e| {
        return if (e == error.OutOfMemory) .ok else .{ .wrong = "State.init failed without running out of memory" };
    };
    defer state.close();
    setPhase(ctx, .run);
    const result = if (std.mem.eql(u8, input, "api")) apiScenario(state) else state.doString(void, input, .{ .name = "=oom" });
    setPhase(ctx, .idle);
    if (result) |_| {
        return .ok;
    } else |e| switch (e) {
        error.OutOfMemory => {},
        error.Runtime, error.Syntax => {
            const msg = state.errorMessage();
            if (!ctx.oom_lax and std.mem.indexOf(u8, msg, "not enough memory") == null)
                return .{ .wrong = std.fmt.allocPrint(gpa, "{t}: {s}", .{ e, msg }) catch "wrong error" };
        },
    }
    // A lax program can fail on its own before the Nth allocation, which
    // the sanity run below would then hit.
    if (!counting.failed) return if (ctx.oom_lax) .ok else .{ .wrong = "an error without a failed allocation" };
    if (counting.fail_always) return .ok; // `close`, still failing, is the check
    // With allocations succeeding again, the state runs code.
    const n = state.doString(i64, "local t = {} for i = 1, 10 do t[i] = i .. '' end return #t", .{}) catch |e|
        return .{ .wrong = std.fmt.allocPrint(gpa, "state unusable after the failure: {t}: {s}", .{ e, state.errorMessage() }) catch "unusable" };
    if (n != 10) return .{ .wrong = "state gives a wrong answer after the failure" };
    return .ok;
}

const Point = struct {
    x: f64 = 0,
    y: f64 = 0,
    pub const lua_userdata = .{ .name = "Point", .methods = .{ .len = len } };
    fn len(p: *const Point) f64 {
        return @sqrt(p.x * p.x + p.y * p.y);
    }
};

fn newPoint(state: *lua.State, x: f64, y: f64) !*Point {
    return state.newUserdata(Point, .{ .x = x, .y = y });
}

fn concatArgs(state: *lua.State, args: lua.Args) ![]const u8 {
    var total: usize = 0;
    var i: u32 = 1;
    while (i <= args.count()) : (i += 1) total += (try state.toString(args.get(i))).len;
    return state.toString(total);
}

fn bump(count: *i64, by: ?i64) i64 {
    count.* += by orelse 1;
    return count.*;
}

/// Every kind of API call a host makes, each of which can fail.
fn apiScenario(state: *lua.State) lua.Error!void {
    try state.setGlobal("width", 80);
    try state.setGlobal("config", .{ .name = "editor", .sizes = .{ 1, 2, 3 }, .nested = .{ .on = true } });
    try state.setGlobal("Point", newPoint);
    try state.setGlobal("concat", concatArgs);
    try state.setGlobal("next_id", try state.function(@as(i64, 0), bump));
    const t = try state.newTable();
    try state.setField(t, "k", "v");
    try t.rawSet(state, 1, 2.5);
    try state.setGlobal("t", t);
    const f = try state.load("local p = Point(3, 4) return p:len() + #concat(1, 'two', 3.5) + next_id() + next_id(5) + config.sizes[3] + t[1]", .{ .name = "=api" });
    const r = try state.call(f64, f, .{});
    if (r != 5 + 1 + 1 + 6 + 3 + 2.5) return state.raise("wrong api result {d}", .{r});
    const C = struct { name: []const u8, sizes: []const i64, nested: struct { on: bool } };
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const c = try state.decodeAlloc(C, arena.allocator(), try state.getGlobal(lua.Value, "config"), .{ .unknown_keys = .reject });
    if (c.sizes.len != 3) return state.raise("decode", .{});
    const handler = try state.ref(try state.doString(lua.Function, "return function(s) return s .. '!' end", .{}));
    defer state.unref(handler);
    _ = try state.call([]const u8, handler, .{"key"});
    const vals = try state.doString(lua.Values, "return 1, 'two', {}, nil", .{});
    _ = try state.call(lua.Values, try state.getGlobal(lua.Function, "select"), .{ "#", vals[0], vals[1] });
    const co = try state.newCoroutine(try state.doString(lua.Function, "return function(a) local b = coroutine.yield(a) return b * 2 end", .{}));
    _ = try co.@"resume"(state, i64, .{1});
    _ = try co.@"resume"(state, i64, .{2});
    const dumped = try state.doString([]const u8, "return string.dump(function(x) return x + 1 end)", .{});
    const copy = try arena.allocator().dupe(u8, dumped);
    _ = try state.call(i64, try state.load(copy, .{ .mode = .binary }), .{41});
    _ = try state.toString(try state.getGlobal(lua.Value, "config"));
    _ = try state.len(try state.getGlobal(lua.Value, "t"));
    _ = state.pcall(void, try state.doString(lua.Function, "return function() error({}) end", .{}), .{}) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => {},
    };
    if (state.errorTraceback()) |tb| _ = tb;
}

// ---------------------------------------------------------------------
// Inputs
// ---------------------------------------------------------------------

fn loadCorpus(dirs: []const []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    for (dirs) |path| {
        var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var iter = dir.iterate();
        while (try iter.next(io)) |entry| {
            if (entry.kind != .file) continue;
            const data = dir.readFileAlloc(io, entry.name, gpa, .limited(max_input)) catch continue;
            try list.append(gpa, data);
        }
    }
    return list.items;
}

const source_dirs = [_][]const u8{ "test/lua-5.5.1-tests", "bench", "test/diff", "test/fuzz/corpus/parse", "test/fuzz/crashers" };

const interesting = "()[]{}=.,;:'\"\\-+*/%^#&|~<> \n\t0123456789abcdefxXeEp_";
const numbers = [_][]const u8{ "0", "-0", "1e308", "1e-400", "0x7fffffffffffffff", "0x8000000000000000", "9223372036854775807", "9223372036854775808", "-9223372036854775808", "0x", "1e", ".5", "5.", "0x1p99999", "1" ++ "0" ** 40, "0x.1p-1080", "3e", "0xep1" };

fn mutate(ctx: *Ctx, buf: *std.ArrayList(u8), binary: bool) !void {
    const r = ctx.rng;
    var n = 1 + r.uintLessThan(u32, 8);
    while (n > 0) : (n -= 1) {
        const len = buf.items.len;
        if (len == 0) {
            try buf.append(gpa, interesting[r.uintLessThan(usize, interesting.len)]);
            continue;
        }
        const at = r.uintLessThan(usize, len);
        switch (r.uintLessThan(u32, if (binary) 9 else 12)) {
            0 => buf.items[at] ^= @as(u8, 1) << r.int(u3),
            1 => buf.items[at] = if (binary) r.int(u8) else interesting[r.uintLessThan(usize, interesting.len)],
            2 => {
                const k = @min(len - at, 1 + r.uintLessThan(usize, 64));
                try buf.replaceRange(gpa, at, k, &.{});
            },
            3 => {
                const k = @min(len - at, 1 + r.uintLessThan(usize, 64));
                const copy = try gpa.dupe(u8, buf.items[at..][0..k]);
                defer gpa.free(copy);
                try buf.insertSlice(gpa, r.uintLessThan(usize, len + 1), copy);
            },
            4 => buf.shrinkRetainingCapacity(at),
            5 => {
                const other = ctx.corpus[r.uintLessThan(usize, ctx.corpus.len)];
                if (other.len == 0) continue;
                const from = r.uintLessThan(usize, other.len);
                const k = @min(other.len - from, 1 + r.uintLessThan(usize, 256));
                try buf.insertSlice(gpa, at, other[from..][0..k]);
            },
            6 => buf.items[at] = if (binary) ([_]u8{ 0, 0xff, 0x7f, 0x80, 1 })[r.uintLessThan(usize, 5)] else interesting[r.uintLessThan(usize, interesting.len)],
            7 => if (binary) {
                // A size field, set large: the loader's length checks.
                const big = [_]u8{ 0x8f, 0xff, 0xff, 0xff, 0x7f };
                const k = @min(len - at, big.len);
                @memcpy(buf.items[at..][0..k], big[0..k]);
            } else {
                try buf.insertSlice(gpa, at, Gen.tokens_for_mutation[r.uintLessThan(usize, Gen.tokens_for_mutation.len)]);
            },
            8 => {
                // A run of one byte or token: nesting depth, long lines.
                const unit: []const u8 = if (binary) buf.items[at..][0..1] else Gen.tokens_for_mutation[r.uintLessThan(usize, Gen.tokens_for_mutation.len)];
                const unit_copy = try gpa.dupe(u8, unit);
                defer gpa.free(unit_copy);
                var k = 1 + r.uintLessThan(u32, 400);
                while (k > 0) : (k -= 1) try buf.insertSlice(gpa, at, unit_copy);
            },
            9 => try buf.insertSlice(gpa, at, numbers[r.uintLessThan(usize, numbers.len)]),
            10 => {
                // Brackets around a range.
                const k = @min(len - at, r.uintLessThan(usize, 200));
                const pairs = [_][2][]const u8{ .{ "(", ")" }, .{ "{", "}" }, .{ "[[", "]]" }, .{ "function() ", " end" }, .{ "do ", " end" }, .{ "--[==[", "]==]" }, .{ "\"", "\"" } };
                const p = pairs[r.uintLessThan(usize, pairs.len)];
                try buf.insertSlice(gpa, at + k, p[1]);
                try buf.insertSlice(gpa, at, p[0]);
            },
            else => buf.items[at] = r.int(u8),
        }
        if (buf.items.len > max_input / 2) buf.shrinkRetainingCapacity(max_input / 2);
    }
}

/// The next input for `target`, in `buf`.
fn makeInput(ctx: *Ctx, target: Target, buf: *std.ArrayList(u8), iter: u64) !void {
    buf.clearRetainingCapacity();
    const r = ctx.rng;
    switch (target) {
        .parse => switch (r.uintLessThan(u32, 10)) {
            0...5 => {
                try buf.appendSlice(gpa, ctx.corpus[r.uintLessThan(usize, ctx.corpus.len)]);
                try mutate(ctx, buf, false);
            },
            6, 7 => {
                try Gen.program(gpa, buf, r.int(u64), .wild);
                if (r.boolean()) try mutate(ctx, buf, false);
            },
            8 => {
                var k = 1 + r.uintLessThan(u32, 50);
                while (k > 0) : (k -= 1) {
                    try buf.appendSlice(gpa, Gen.tokens_for_mutation[r.uintLessThan(usize, Gen.tokens_for_mutation.len)]);
                    try buf.append(gpa, ' ');
                }
            },
            else => {
                var k = r.uintLessThan(u32, 200);
                while (k > 0) : (k -= 1) try buf.append(gpa, interesting[r.uintLessThan(usize, interesting.len)]);
            },
        },
        .grammar => try Gen.program(gpa, buf, programSeed(ctx.opts.seed.?, iter), if (r.boolean()) .diff else .wild),
        .binary => {
            try buf.appendSlice(gpa, ctx.dumps[r.uintLessThan(usize, ctx.dumps.len)]);
            try mutate(ctx, buf, true);
        },
        .oom, .capi => unreachable,
    }
}

/// `string.dump` of every corpus program that compiles, plain and stripped.
fn makeDumps(corpus: []const []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    const state = try lua.State.init(gpa, .{});
    defer state.close();
    const dumper = try state.doString(lua.Function, "return function(s, strip) local f = load(s) return f and string.dump(f, strip) end", .{});
    for (corpus) |src| {
        if (src.len > 64 << 10) continue;
        for ([_]bool{ false, true }) |strip| {
            const d = state.call(?[]const u8, dumper, .{ src, strip }) catch continue;
            if (d) |bytes| try list.append(gpa, try gpa.dupe(u8, bytes));
        }
    }
    return list.items;
}

// ---------------------------------------------------------------------
// The supervisor
// ---------------------------------------------------------------------

const Phase = enum(u32) { idle, load, run };

/// What the child tells the parent about the input it is running.
const Shared = extern struct {
    heartbeat: u64,
    phase: u32,
    len: u32,
    case: u64,
    done: u64,
    data: [max_input]u8,
};

const Kind = enum {
    crash,
    hang,
    leak,
    wrong,
    memory,

    fn fromExit(code: u8) Kind {
        return switch (code) {
            3 => .leak,
            5 => .memory,
            else => .wrong,
        };
    }
};

const Finding = struct {
    kind: Kind,
    phase: Phase,
    input: []const u8,
    case: u64,
    log: []const u8,
};

fn mapShared() !*Shared {
    const size = std.mem.alignForward(usize, @sizeOf(Shared), std.heap.page_size_min);
    const rc = linux.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED, .ANONYMOUS = true }, -1, 0);
    if (linux.errno(rc) != .SUCCESS) return error.MmapFailed;
    return @ptrFromInt(rc);
}

fn timeoutMs(target: Target) i64 {
    // Collector stress makes everything slower.
    const scale: i64 = if (stress) 6 else 1;
    return scale * @as(i64, switch (target) {
        .parse => 5_000,
        .grammar => 20_000,
        .binary => 10_000,
        .oom, .capi => 20_000,
    });
}

var stress = false;

/// The child's loop: inputs from `seed` until the time is up. Exits 0
/// when done, or with the outcome's code at the first bad outcome.
fn childLoop(ctx: *Ctx, target: Target, deadline: i64) noreturn {
    const shared = ctx.shared.?;
    var buf: std.ArrayList(u8) = .empty;
    var iter: u64 = shared.done;
    if (target.sweeps()) {
        // Each case is (program, N, once or always), in order; `done`
        // says where the previous child stopped.
        const total = ctx.oom_set.len;
        var prog: usize = @intCast(shared.case >> 32);
        var n: u64 = shared.case & 0xffff_ffff;
        while (prog < total and nowMs() < deadline) {
            const text = ctx.oom_set[prog];
            ctx.oom_lax = prog >= ctx.oom_strict;
            var finished = true;
            for ([_]u64{ 0, 1 }) |always| {
                @memcpy(shared.data[0..text.len], text);
                shared.len = @intCast(text.len);
                @atomicStore(u64, &shared.case, (@as(u64, prog) << 32) | n, .seq_cst);
                shared.done = n << 1 | always;
                _ = @atomicRmw(u64, &shared.heartbeat, .Add, 1, .seq_cst);
                var counting_probe: bool = false;
                const outcome = runOomProbe(ctx, text, n << 1 | always, &counting_probe);
                if (outcome != .ok) {
                    std.debug.print("{s}\n", .{outcome.describe()});
                    linux.exit_group(outcome.code());
                }
                if (counting_probe) finished = false;
            }
            if (finished) {
                std.debug.print("oom: program {d} swept {d} allocations, once and from then on\n", .{ prog, n });
                prog += 1;
                n = 0;
            } else n += 1;
        }
        @atomicStore(u64, &shared.case, @as(u64, prog) << 32, .seq_cst);
        linux.exit_group(0);
    }
    while (nowMs() < deadline) : (iter += 1) {
        var prng: std.Random.DefaultPrng = .init(ctx.opts.seed.? +% iter *% 0x9e3779b97f4a7c15);
        ctx.rng = prng.random();
        makeInput(ctx, target, &buf, iter) catch linux.exit_group(9);
        const len = @min(buf.items.len, max_input);
        @memcpy(shared.data[0..len], buf.items[0..len]);
        shared.len = @intCast(len);
        shared.done = iter;
        _ = @atomicRmw(u64, &shared.heartbeat, .Add, 1, .seq_cst);
        const outcome = runOne(ctx, target, buf.items[0..len], 0);
        if (outcome != .ok) {
            std.debug.print("{s}\n", .{outcome.describe()});
            linux.exit_group(outcome.code());
        }
    }
    shared.done = iter;
    linux.exit_group(0);
}

/// `runOom`, noting whether the run reached the failing allocation: when
/// it did not, N is past the program's allocations.
fn runOomProbe(ctx: *Ctx, text: []const u8, case: u64, reached: *bool) Outcome {
    const fail_at = case >> 1;
    var debug_alloc: std.heap.DebugAllocator(.{ .stack_trace_frames = 8 }) = .init;
    var counting: Counting = .{ .backing = debug_alloc.allocator(), .fail_at = fail_at, .fail_always = case & 1 == 1 };
    const outcome = oomCase(ctx, &counting, text);
    reached.* = counting.failed;
    if (debug_alloc.deinit() == .leak) return .{ .leak = counting.live };
    if (outcome != .ok) return outcome;
    if (counting.live != 0) return .{ .leak = counting.live };
    return .ok;
}

const Child = struct {
    pid: linux.pid_t,
    log_path: [:0]const u8,
};

fn spawnChild(ctx: *Ctx, target: Target, deadline: i64, log_path: [:0]const u8, single: ?[]const u8) !Child {
    const rc = linux.fork();
    if (linux.errno(rc) != .SUCCESS) return error.ForkFailed;
    if (rc == 0) {
        const fd = linux.open(log_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
        if (linux.errno(fd) == .SUCCESS) _ = linux.dup2(@intCast(fd), 2);
        if (ctx.opts.stack) |size| {
            const t = std.Thread.spawn(.{ .stack_size = size }, childMain, .{ ctx, target, deadline, single }) catch linux.exit_group(9);
            t.join();
        }
        childMain(ctx, target, deadline, single);
    }
    return .{ .pid = @intCast(rc), .log_path = log_path };
}

fn childMain(ctx: *Ctx, target: Target, deadline: i64, single: ?[]const u8) noreturn {
    if (single) |input| {
        // One input, for minimizing: exit with its outcome.
        _ = @atomicRmw(u64, &ctx.shared.?.heartbeat, .Add, 1, .seq_cst);
        const outcome = runOne(ctx, target, input, ctx.shared.?.case);
        if (outcome != .ok) std.debug.print("{s}\n", .{outcome.describe()});
        linux.exit_group(outcome.code());
    }
    childLoop(ctx, target, deadline);
}

const Status = union(enum) { exited: u8, signaled: u32, hung };

/// Waits for the child, killing it when its heartbeat stops for longer
/// than the target's timeout.
fn waitChild(shared: *Shared, child: Child, timeout: i64) Status {
    var last = @atomicLoad(u64, &shared.heartbeat, .seq_cst);
    var since = nowMs();
    while (true) {
        var status: u32 = 0;
        const rc = linux.waitpid(child.pid, &status, linux.W.NOHANG);
        if (rc == child.pid) {
            if (linux.W.IFEXITED(status)) return .{ .exited = linux.W.EXITSTATUS(status) };
            return .{ .signaled = @intFromEnum(linux.W.TERMSIG(status)) };
        }
        const beat = @atomicLoad(u64, &shared.heartbeat, .seq_cst);
        if (beat != last) {
            last = beat;
            since = nowMs();
        } else if (nowMs() - since > timeout) {
            _ = linux.kill(child.pid, .KILL);
            _ = linux.waitpid(child.pid, &status, 0);
            return .hung;
        }
        sleepMs(5);
    }
}

fn kindOf(status: Status) ?Kind {
    return switch (status) {
        .exited => |c| if (c == 0) null else if (c == 3 or c == 4 or c == 5) Kind.fromExit(c) else .crash,
        .signaled => .crash,
        .hung => .hang,
    };
}

/// The first line of a panic or of the outcome in the child's log: what
/// a minimized input must still produce.
fn signature(log: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, log, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "panic: ")) |i| return line[i..];
        if (std.mem.startsWith(u8, line, "leak") or std.mem.startsWith(u8, line, "memory")) return line[0..@min(line.len, 6)];
        if (std.mem.startsWith(u8, line, "Segmentation fault")) return line;
    }
    // Otherwise the child's last line, the outcome it printed before
    // exiting, after any progress lines.
    var rest = std.mem.trimEnd(u8, log, "\n");
    if (std.mem.lastIndexOfScalar(u8, rest, '\n')) |i| rest = rest[i + 1 ..];
    return rest;
}

/// Whether the panic's first frame is in `Proto.zig`, where the line
/// lookups are. Release traces are unreliable past the first frame.
fn inLineLookup(log: []const u8) bool {
    const i = std.mem.indexOf(u8, log, "panic: ") orelse return false;
    var lines = std.mem.splitScalar(u8, log[i..], '\n');
    _ = lines.next();
    const frame = lines.next() orelse return false;
    if (std.mem.indexOf(u8, frame, "/src/Proto.zig:") == null) return false;
    // Proto.zig's closure helpers inline into the loop too: a crash in
    // one, from a chunk's bad upvalue index, is the known limit.
    const source = lines.next() orelse return false;
    return std.mem.indexOf(u8, source, "line") != null or std.mem.indexOf(u8, source, "abs") != null;
}

fn readLog(path: []const u8) []const u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch "";
}

fn supervise(target: Target, opts_in: Options, seed: u64) !void {
    var opts = opts_in;
    opts.seed = seed;
    stress = opts.gc_stress != .off;
    const shared = try mapShared();
    shared.* = .{ .heartbeat = 0, .phase = 0, .len = 0, .case = 0, .done = 0, .data = undefined };
    const corpus = try loadCorpus(&source_dirs);
    var ctx: Ctx = .{ .opts = opts, .rng = undefined, .corpus = corpus, .shared = shared };
    if (target == .binary) ctx.dumps = try makeDumps(corpus);
    if (target == .oom) {
        const strict = oom_programs ++ [_][]const u8{"api"};
        ctx.oom_set = try std.mem.concat(perm, []const u8, &.{ &strict, try loadCorpus(&.{"test/diff"}) });
        ctx.oom_strict = strict.len;
    }
    if (target == .capi) {
        if (!fuzz_options.capi_module) {
            std.debug.print("fuzz capi: build the driver with -Dc-api=true\n", .{});
            return error.NoCApi;
        }
        // Workloads from the seed: each sweep takes a while.
        var set: std.ArrayList([]const u8) = .empty;
        for (0..capi_workloads) |i| {
            var buf: std.ArrayList(u8) = .empty;
            try capiWorkload(&buf, programSeed(seed, i), opts.module, 12);
            try set.append(perm, buf.items);
        }
        ctx.oom_set = set.items;
        ctx.oom_strict = set.items.len;
        ctx.capi = true;
    }
    if (target.sweeps()) {
        // Each strict program must succeed when nothing fails.
        for (ctx.oom_set[0..ctx.oom_strict]) |p| {
            const outcome = runOne(&ctx, target, p, std.math.maxInt(u64) - 1);
            if (outcome != .ok) {
                std.debug.print("oom program fails on its own: {s}\n{s}\n", .{ p, outcome.describe() });
                return error.BadProgram;
            }
        }
    }
    const dir = try std.fmt.allocPrint(gpa, "{s}/{t}{s}", .{ opts.out, target, if (opts.gc_stress != .off) "-stress" else "" });
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const log_path = try std.fmt.allocPrintSentinel(gpa, "{s}/child-{d}.log", .{ dir, seed % 100000 }, 0);
    const start = nowMs();
    const deadline = start + @as(i64, @intCast(opts.seconds)) * 1000;
    var findings: u32 = 0;
    var known: u32 = 0;
    var restarts: u32 = 0;
    var slow: u32 = 0;
    std.debug.print("fuzz {t}: seed {d}, {d}s, {d} corpus files{s}\n", .{ target, seed, opts.seconds, corpus.len, if (opts.gc_stress != .off) ", gc stress" else "" });
    while (nowMs() < deadline) {
        const child = try spawnChild(&ctx, target, deadline, log_path, null);
        const status = waitChild(shared, child, timeoutMs(target));
        const kind = kindOf(status) orelse break;
        restarts += 1;
        const phase: Phase = @enumFromInt(shared.phase);
        const input = try gpa.dupe(u8, shared.data[0..shared.len]);
        const log = readLog(log_path);
        const case = if (target.sweeps()) shared.done else 0;
        // Resume after the failing input.
        if (target.sweeps()) shared.case += 1 else shared.done += 1;
        shared.phase = 0;
        if (target == .grammar and kind == .hang and try referenceHangs(input)) {
            // The program is slow on the reference too: the generator's
            // fault, not a finding.
            slow += 1;
            continue;
        }
        const finding: Finding = .{ .kind = kind, .phase = phase, .input = input, .case = case, .log = log };
        // A crash in a line lookup is a finding even while running.
        const is_known = target == .binary and phase == .run and (kind == .crash or kind == .hang) and !inLineLookup(log);
        if (is_known) known += 1 else findings += 1;
        try record(&ctx, target, dir, finding, is_known, status);
    }
    const ran = shared.done;
    std.debug.print("fuzz {t}: {d} inputs in {d}s, {d} findings, {d} known-limit, {d} slow on the reference too, {d} restarts\n", .{ target, if (target.sweeps()) shared.case >> 32 else ran, @divTrunc(nowMs() - start, 1000), findings, known, slow, restarts });
    if (findings != 0) std.process.exit(1);
}

var minimized: std.StringHashMapUnmanaged(void) = .empty;

/// Whether the reference `lua` also takes more than 30 seconds on a
/// generated program.
fn referenceHangs(src: []const u8) !bool {
    const dir = "zig-out/fuzz/reference-check";
    try std.Io.Dir.cwd().createDirPath(io, dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/gen.lua", .data = src });
    const r = try runProcess(&.{ try which("lua"), "gen.lua" }, dir, 30);
    return r.timed_out;
}

fn record(ctx: *Ctx, target: Target, dir: []const u8, f: Finding, known: bool, status: Status) !void {
    const sig = signature(f.log);
    const hash = std.hash.Wyhash.hash(0, f.input) % 1_000_000;
    const sub = if (known) "known" else "findings";
    const base = if (target.sweeps())
        try std.fmt.allocPrint(gpa, "{s}/{s}/{t}-{d}-n{d}{s}", .{ dir, sub, f.kind, hash, f.case >> 1, if (f.case & 1 == 1) "-always" else "" })
    else
        try std.fmt.allocPrint(gpa, "{s}/{s}/{t}-{d}", .{ dir, sub, f.kind, hash });
    try std.Io.Dir.cwd().createDirPath(io, try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, sub }));
    std.debug.print("{s}: {t} in {t} ({s}), {d} bytes{s}\n", .{ if (known) "known limit" else "FINDING", f.kind, f.phase, sig, f.input.len, if (target.sweeps() or known) "" else ", minimizing" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(gpa, "{s}.input", .{base}), .data = f.input });
    const info = try std.fmt.allocPrint(gpa, "target: {t}\nkind: {t}\nphase: {t}\nstatus: {any}\ncase: n={d} {s}\nsignature: {s}\n\n{s}", .{ target, f.kind, f.phase, status, f.case >> 1, if (f.case & 1 == 1) "always" else "once", sig, f.log });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(gpa, "{s}.txt", .{base}), .data = info });
    if (target.sweeps() or known) return;
    // One minimized input per signature and kind is enough.
    const key = try std.fmt.allocPrint(gpa, "{t}|{t}|{s}", .{ f.kind, f.phase, sig });
    if (minimized.contains(key)) return;
    try minimized.put(gpa, key, {});
    const min = try minimize(ctx, target, f, sig, dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(gpa, "{s}.min", .{base}), .data = min });
    std.debug.print("  minimized to {d} bytes: {s}.min\n", .{ min.len, base });
}

/// Delta debugging over lines, then bytes, keeping the failure's kind
/// and signature. Each try runs in a fresh child.
fn minimize(ctx: *Ctx, target: Target, f: Finding, sig: []const u8, dir: []const u8) ![]const u8 {
    const log_path = try std.fmt.allocPrintSentinel(gpa, "{s}/minimize.log", .{dir}, 0);
    var best = try gpa.dupe(u8, f.input);
    const deadline = nowMs() + 120_000;
    const Tester = struct {
        fn still(c: *Ctx, t: Target, input: []const u8, want: Finding, want_sig: []const u8, path: [:0]const u8) bool {
            const child = spawnChild(c, t, 0, path, input) catch return false;
            const timeout: i64 = if (want.kind == .hang) timeoutMs(t) else timeoutMs(t) * 2;
            const status = waitChild(c.shared.?, child, timeout);
            const kind = kindOf(status) orelse return false;
            if (kind != want.kind) return false;
            if (kind == .hang) return true;
            return std.mem.eql(u8, signature(readLog(path)), want_sig);
        }
    };
    for ([_]u8{ '\n', 0 }) |unit| {
        var chunk: usize = @max(1, best.len / 2);
        while (chunk >= 1 and nowMs() < deadline) {
            var changed = false;
            var at: usize = 0;
            while (at < best.len and nowMs() < deadline) {
                // Remove [at, at + chunk) in units of lines or bytes.
                const end = if (unit == '\n') blk: {
                    var e = at;
                    var lines: usize = 0;
                    while (e < best.len and lines < chunk) : (e += 1) {
                        if (best[e] == '\n') lines += 1;
                    }
                    break :blk e;
                } else @min(best.len, at + chunk);
                if (end == at) break;
                const candidate = try std.mem.concat(gpa, u8, &.{ best[0..at], best[end..] });
                if (Tester.still(ctx, target, candidate, f, sig, log_path)) {
                    best = candidate;
                    changed = true;
                } else {
                    at = end;
                }
            }
            if (!changed) {
                if (chunk == 1) break;
                chunk /= 2;
            }
        }
    }
    return best;
}

// ---------------------------------------------------------------------
// Differential fuzzing against the reference
// ---------------------------------------------------------------------

const DiffCommand = enum { diff, bytecode, messages, @"binary-diff", @"capi-diff" };

const Run = struct {
    out: []const u8,
    timed_out: bool,
};

fn runProcess(argv: []const []const u8, cwd: ?[]const u8, timeout_s: u32) !Run {
    var full: std.ArrayList([]const u8) = .empty;
    defer full.deinit(gpa);
    const t = try std.fmt.allocPrint(gpa, "{d}", .{timeout_s});
    // A run may take 2 GiB of address space: past that, an allocation
    // fails, so a runaway input cannot take the machine down.
    try full.appendSlice(gpa, &.{ "prlimit", "--as=2147483648", "timeout", "-s", "KILL", t });
    try full.appendSlice(gpa, argv);
    var dir: ?std.Io.Dir = null;
    defer if (dir) |d| d.close(io);
    if (cwd) |p| dir = try std.Io.Dir.cwd().openDir(io, p, .{});
    const result = std.process.run(gpa, io, .{
        .argv = full.items,
        .cwd = if (dir) |d| .{ .dir = d } else .inherit,
        .stdout_limit = .limited(16 << 20),
        .stderr_limit = .limited(16 << 20),
    }) catch |e| switch (e) {
        // Too much output to compare: count it as a timeout.
        error.StreamTooLong => return .{ .out = "output too long", .timed_out = true },
        else => return e,
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(gpa, result.stdout);
    try text.appendSlice(gpa, "\n-- stderr --\n");
    try text.appendSlice(gpa, result.stderr);
    var timed_out = false;
    switch (result.term) {
        .exited => |c| {
            if (c == 137) timed_out = true;
            try text.print(gpa, "\n-- exit {d} --\n", .{c});
        },
        .signal => |s| {
            if (s == .KILL) timed_out = true;
            try text.print(gpa, "\n-- signal {t} --\n", .{s});
        },
        else => try text.appendSlice(gpa, "\n-- other --\n"),
    }
    return .{ .out = try normalize(text.items, argv[0]), .timed_out = timed_out };
}

/// Masks what legitimately differs between runs: addresses, and the
/// interpreter's own path at the start of its messages.
fn normalize(text: []const u8, bin: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (std.mem.startsWith(u8, text[i..], bin)) {
            try out.appendSlice(gpa, "lua");
            i += bin.len;
        } else if (std.mem.startsWith(u8, text[i..], "0x") and i >= 2 and text[i - 1] == ' ' and text[i - 2] == ':') {
            try out.appendSlice(gpa, "ADDR");
            i += 2;
            while (i < text.len and std.ascii.isHex(text[i])) i += 1;
        } else {
            try out.append(gpa, text[i]);
            i += 1;
        }
    }
    return out.items;
}

fn which(name: []const u8) ![]const u8 {
    const r = try std.process.run(perm, io, .{ .argv = &.{ "sh", "-c", try std.fmt.allocPrint(perm, "command -v {s}", .{name}) } });
    return std.mem.trimEnd(u8, r.stdout, "\n");
}

const DiffCtx = struct {
    cmd: DiffCommand,
    dir: []const u8,
    ref: []const u8,
    luac: []const u8,
    ours: []const u8,
    listing: []const u8,
    /// Seconds each run may take; short while minimizing, where removing
    /// a loop's counter makes it run forever.
    timeout: u32 = 20,
    /// The outputs of the last comparison.
    last: [2][]const u8 = .{ "", "" },
    /// capifuzz.so's directory, absolute, for `capi-diff`.
    module: []const u8 = "",
    /// What every program starts with, which minimizing keeps: for
    /// `capi-diff`, the lines that load capifuzz.
    header: []const u8 = "",
};

/// Whether `src` still shows the difference; for `diff`, both arms must
/// finish, so a timeout never counts.
fn differs(d: *DiffCtx, src: []const u8) !bool {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(gpa, "{s}/prog.lua", .{d.dir}), .data = try std.mem.concat(gpa, u8, &.{ d.header, src }) });
    switch (d.cmd) {
        .diff, .@"capi-diff" => {
            const a = try runProcess(&.{ d.ref, "prog.lua" }, d.dir, d.timeout);
            if (a.timed_out) return false;
            const b = try runProcess(&.{ d.ours, "prog.lua" }, d.dir, d.timeout);
            d.last = .{ a.out, b.out };
            return !std.mem.eql(u8, a.out, b.out);
        },
        .bytecode => {
            const a = try runProcess(&.{ d.luac, "-l", "-l", "-p", "prog.lua" }, d.dir, d.timeout);
            const b = try runProcess(&.{ d.listing, "prog.lua" }, d.dir, d.timeout);
            if (std.mem.indexOf(u8, a.out, "-- exit 0 --") == null) return false; // luac refused it
            d.last = .{ maskListing(a.out), maskListing(b.out) };
            return !std.mem.eql(u8, d.last[0], d.last[1]);
        },
        else => unreachable,
    }
}

fn maskListing(text: []const u8) []const u8 {
    // luac prints "at 0x..." and "for 0x...:" and CLOSURE's "; 0x...";
    // the listing prints 0x0. Mask every hex address.
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (std.mem.startsWith(u8, text[i..], "0x") and i > 0 and (text[i - 1] == ' ')) {
            out.appendSlice(gpa, "0x0") catch {};
            i += 2;
            while (i < text.len and std.ascii.isHex(text[i])) i += 1;
        } else {
            out.append(gpa, text[i]) catch {};
            i += 1;
        }
    }
    return out.items;
}

fn differential(cmd: DiffCommand, opts: Options, seed: u64) !void {
    const dir = try std.fmt.allocPrint(perm, "{s}/{t}", .{ opts.out, cmd });
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const work = try std.fmt.allocPrint(perm, "{s}/work-{d}", .{ dir, seed % 100000 });
    try std.Io.Dir.cwd().createDirPath(io, work);
    const abs = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", perm);
    var d: DiffCtx = .{
        .cmd = cmd,
        .dir = work,
        .ref = try which("lua"),
        .luac = try which("luac"),
        .ours = try std.fs.path.resolve(perm, &.{ abs, opts.ours }),
        .listing = try std.fs.path.resolve(perm, &.{ abs, opts.listing }),
        .module = try std.fs.path.resolve(perm, &.{ abs, opts.module }),
    };
    if (cmd == .@"capi-diff") {
        const so = try std.fmt.allocPrint(perm, "{s}/capifuzz.so", .{d.module});
        std.Io.Dir.cwd().access(io, so, .{}) catch {
            std.debug.print("fuzz capi-diff: no {s}; `just fuzz-capi` builds it\n", .{so});
            return error.NoModule;
        };
    }
    const start = nowMs();
    const deadline = start + @as(i64, @intCast(opts.seconds)) * 1000;
    var iter: u64 = 0;
    var found: u32 = 0;
    var cases: u64 = 0;
    std.debug.print("fuzz {t}: seed {d}, {d}s, ours {s}\n", .{ cmd, seed, opts.seconds, d.ours });
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    gpa = arena.allocator();
    while (nowMs() < deadline) : (iter += 1) {
        _ = arena.reset(.retain_capacity);
        switch (cmd) {
            .diff, .bytecode, .@"capi-diff" => {
                var buf: std.ArrayList(u8) = .empty;
                defer buf.deinit(gpa);
                if (cmd == .@"capi-diff") {
                    try capiProgram(&buf, programSeed(seed, iter), d.module);
                    // The two lines that load capifuzz stay; the rest
                    // is what differs and gets minimized.
                    const split = std.mem.indexOfScalarPos(u8, buf.items, std.mem.indexOfScalar(u8, buf.items, '\n').? + 1, '\n').? + 1;
                    if (d.header.len == 0) d.header = try perm.dupe(u8, buf.items[0..split]);
                    try buf.replaceRange(gpa, 0, split, &.{});
                } else try Gen.program(gpa, &buf, programSeed(seed, iter), if (cmd == .diff) .diff else .wild);
                cases += 1;
                if (!try differs(&d, buf.items)) continue;
                found += 1;
                const first = d.last;
                const name = try std.fmt.allocPrint(gpa, "{s}/{t}-{d}.lua", .{ dir, cmd, programSeed(seed, iter) });
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(gpa, "{s}.full", .{name}), .data = try std.mem.concat(gpa, u8, &.{ d.header, buf.items }) });
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(gpa, "{s}.full.ref", .{name}), .data = first[0] });
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(gpa, "{s}.full.ours", .{name}), .data = first[1] });
                std.debug.print("DIFFERS: {s}.full ({d} bytes), minimizing\n", .{ name, buf.items.len });
                d.timeout = 3;
                const min = try minimizeText(&d, buf.items, nowMs() + 180_000);
                d.timeout = 20;
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = name, .data = try std.mem.concat(gpa, u8, &.{ d.header, min }) });
                _ = try differs(&d, min);
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(gpa, "{s}.ref", .{name}), .data = d.last[0] });
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(gpa, "{s}.ours", .{name}), .data = d.last[1] });
                std.debug.print("  minimized to {d} bytes: {s}\n", .{ min.len, name });
            },
            .messages, .@"binary-diff" => {
                const n = try batch(&d, cmd, opts, seed +% iter *% 1000003, dir, &found, &seen);
                cases += n;
            },
        }
    }
    std.debug.print("fuzz {t}: {d} cases in {d}s, {d} differences\n", .{ cmd, cases, @divTrunc(nowMs() - start, 1000), found });
    if (found != 0) std.process.exit(1);
}

/// The seed of the program a run generates at `iter`: runs started with
/// different seeds do not overlap. `fuzz gen` takes this number.
fn programSeed(seed: u64, iter: u64) u64 {
    return (seed *% 1_000_003 +% iter) % 1_000_000_000_000;
}

/// How many workloads one `run capi` sweeps.
const capi_workloads = 1000;

/// A C-API workload: LINES calls of capifuzz's `run`, each with up to
/// eight random operations, printing what they noted. Registers persist
/// across lines, so later lines see what earlier ones built.
fn capiWorkload(buf: *std.ArrayList(u8), seed: u64, module: []const u8, lines: u32) !void {
    var prng: std.Random.DefaultPrng = .init(seed);
    const r = prng.random();
    try buf.print(gpa, "package.cpath = \"{s}/?.so\"\nlocal run = require(\"capifuzz\").run\n", .{module});
    for (0..lines) |_| {
        try buf.appendSlice(gpa, "print(run(\"");
        for (0..4 * (1 + r.uintLessThan(u32, 8))) |_| try buf.print(gpa, "\\{d}", .{r.int(u8)});
        try buf.appendSlice(gpa, "\"))\n");
    }
}

/// The workload `capi-diff` runs and `fuzz gen SEED capi` prints.
fn capiProgram(buf: *std.ArrayList(u8), seed: u64, module: []const u8) !void {
    try capiWorkload(buf, seed, module, 40);
}

fn minimizeText(d: *DiffCtx, src: []const u8, deadline: i64) ![]const u8 {
    var best = try gpa.dupe(u8, src);
    for ([_]u8{ '\n', 0 }) |unit| {
        var chunk: usize = @max(1, std.mem.count(u8, best, "\n") / 2);
        if (unit == 0) chunk = @min(chunk, 32);
        while (nowMs() < deadline) {
            var changed = false;
            var at: usize = 0;
            while (at < best.len and nowMs() < deadline) {
                const end = if (unit == '\n') blk: {
                    var e = at;
                    var lines: usize = 0;
                    while (e < best.len and lines < chunk) : (e += 1) {
                        if (best[e] == '\n') lines += 1;
                    }
                    break :blk e;
                } else @min(best.len, at + chunk);
                if (end == at) break;
                const candidate = try std.mem.concat(gpa, u8, &.{ best[0..at], best[end..] });
                if (try differs(d, candidate)) {
                    best = candidate;
                    changed = true;
                } else at = end;
            }
            if (!changed) {
                if (chunk == 1) break;
                chunk /= 2;
            }
        }
    }
    return best;
}

const messages_runner =
    \\-- Loads every file named on the command line and prints the result,
    \\-- one line per file: the same lines from both interpreters.
    \\local mode = arg[1]
    \\for i = 2, #arg do
    \\  local f = assert(io.open(arg[i], "rb"))
    \\  local src = f:read("a")
    \\  f:close()
    \\  local fn, err = load(src, "=src", mode)
    \\  local line
    \\  if fn then line = "ok" else line = "error: " .. err end
    \\  -- lua.c's message handler adds a traceback to a "C stack overflow"
    \\  -- raised while compiling; ours keeps tracebacks apart (README).
    \\  line = line:gsub("\nstack traceback:.*", "")
    \\  io.write(i - 1, "\t", (line:gsub("\n", "\\n")), "\n")
    \\end
;

/// One batch for `messages` or `binary-diff`: inputs written to files,
/// loaded by both interpreters in one process each, results compared
/// line by line. Returns how many inputs it compared.
fn batch(d: *DiffCtx, cmd: DiffCommand, opts: Options, seed: u64, dir: []const u8, found: *u32, seen: *std.StringHashMapUnmanaged(void)) !u64 {
    const n = 400;
    const corpus = try cachedCorpus(cmd);
    var prng: std.Random.DefaultPrng = .init(seed);
    var ctx: Ctx = .{ .opts = opts, .rng = prng.random(), .corpus = corpus.sources, .dumps = corpus.dumps };
    const runner = try std.fmt.allocPrint(gpa, "{s}/runner.lua", .{d.dir});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = runner, .data = messages_runner });
    var argv_ref: std.ArrayList([]const u8) = .empty;
    try argv_ref.appendSlice(gpa, &.{ d.ref, "runner.lua", if (cmd == .messages) "t" else "b" });
    var inputs: std.ArrayList([]const u8) = .empty;
    var buf: std.ArrayList(u8) = .empty;
    for (0..n) |i| {
        if (cmd == .messages) {
            try makeInput(&ctx, .parse, &buf, i);
            // Keep messages comparable: lua.c's traceback and chunk names
            // do not apply to load, but huge inputs make huge lines.
            if (buf.items.len > 32 << 10) buf.shrinkRetainingCapacity(32 << 10);
        } else try makeInput(&ctx, .binary, &buf, i);
        const name = try std.fmt.allocPrint(gpa, "in{d}", .{i});
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ d.dir, name }), .data = buf.items });
        try argv_ref.append(gpa, name);
        try inputs.append(gpa, try gpa.dupe(u8, buf.items));
    }
    const a = try runProcess(argv_ref.items, d.dir, 60);
    argv_ref.items[0] = d.ours;
    const b = try runProcess(argv_ref.items, d.dir, 60);
    var la = std.mem.splitScalar(u8, a.out, '\n');
    var lb = std.mem.splitScalar(u8, b.out, '\n');
    var i: usize = 0;
    while (true) : (i += 1) {
        const x = la.next() orelse break;
        const y = lb.next() orelse break;
        if (std.mem.startsWith(u8, x, "-- ")) break;
        if (std.mem.eql(u8, x, y)) continue;
        // Unlike lundump.c, the loader refuses opcodes outside the set.
        if (cmd == .@"binary-diff" and std.mem.endsWith(u8, y, "bad binary format (invalid opcode)")) continue;
        const idx = i;
        const key = try std.fmt.allocPrint(perm, "{s}|{s}", .{ classOf(x), classOf(y) });
        if (seen.contains(key)) continue;
        try seen.put(perm, key, {});
        found.* += 1;
        const base = try std.fmt.allocPrint(gpa, "{s}/{t}-{d}-{d}", .{ dir, cmd, seed, idx });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(gpa, "{s}.input", .{base}), .data = inputs.items[idx] });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(gpa, "{s}.txt", .{base}), .data = try std.fmt.allocPrint(gpa, "ref:  {s}\nours: {s}\n", .{ x[0..@min(x.len, 4000)], y[0..@min(y.len, 4000)] }) });
        std.debug.print("DIFFERS: {s}\n  ref:  {s}\n  ours: {s}\n", .{ base, x[0..@min(x.len, 300)], y[0..@min(y.len, 300)] });
    }
    if (a.timed_out or b.timed_out or std.mem.indexOf(u8, b.out, "-- exit 0 --") == null) {
        // A whole batch that crashed or hung on one side: keep it.
        if (std.mem.indexOf(u8, a.out, "-- exit 0 --") != null) {
            found.* += 1;
            const base = try std.fmt.allocPrint(gpa, "{s}/{t}-{d}-batch", .{ dir, cmd, seed });
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(gpa, "{s}.txt", .{base}), .data = b.out[b.out.len -| 4000..] });
            std.debug.print("BATCH FAILED on ours: {s}.txt (input {d})\n", .{ base, i });
            if (i < inputs.items.len) try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(gpa, "{s}.input", .{base}), .data = inputs.items[i] });
        }
    }
    return n;
}

/// The kind of a result line, for grouping differences: the message with
/// positions and quoted text taken out.
fn classOf(line: []const u8) []const u8 {
    const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return line;
    var rest = line[tab + 1 ..];
    if (std.mem.indexOf(u8, rest, "near")) |i| rest = rest[0..i];
    var out: std.ArrayList(u8) = .empty;
    for (rest) |c| {
        if (std.ascii.isDigit(c)) continue;
        out.append(gpa, c) catch {};
    }
    return out.items;
}

var cached: ?struct { sources: []const []const u8, dumps: []const []const u8 } = null;

fn cachedCorpus(cmd: DiffCommand) !@TypeOf(cached.?) {
    if (cached) |c| return c;
    const saved = gpa;
    defer gpa = saved;
    gpa = perm;
    const sources = try loadCorpus(&source_dirs);
    cached = .{ .sources = sources, .dumps = if (cmd == .@"binary-diff") try makeDumps(sources) else &.{} };
    return cached.?;
}

//! Loading a precompiled chunk, reference Lua 5.5.1's lundump.c: the format
//! `dump.zig` and `luac` write, with the reference's checks and its
//! messages ("name: bad binary format (truncated chunk)", "version
//! mismatch", ...). Like the reference, it does not verify the bytecode's
//! operands; unlike it, it rejects an instruction whose opcode is not one
//! of the set ("invalid opcode"), so the interpreter never dispatches one.
//!
//! Line information is luac's relative bytes and absolute entries, which
//! `Proto` holds as they come; like the reference, the loader does not
//! check them, and `Proto.lineAt` reads any of them safely.

const std = @import("std");
const Proto = @import("Proto.zig");
const String = @import("String.zig");
const Value = @import("Value.zig");
const Thread = @import("Thread.zig");
const dump = @import("dump.zig");
const opcodes = @import("opcodes.zig");

const Error = Value.Error;

/// Loads the binary chunk `chunk`, which starts with `dump.signature`'s
/// first byte, and returns its main prototype; the caller makes the
/// closure. `chunkname` names the chunk in error messages, as
/// `luaU_undump` shortens it. Errors are Lua errors with the message as
/// their value.
pub fn undump(th: *Thread, chunk: []const u8, chunkname: []const u8) Error!*Proto {
    var name = chunkname;
    if (name.len > 0 and (name[0] == '@' or name[0] == '=')) {
        name = name[1..];
    } else if (name.len > 0 and name[0] == dump.signature[0]) {
        name = "binary string";
    }
    var s: Loader = .{ .th = th, .src = chunk, .pos = 1, .name = name };
    defer s.saved.deinit(th.heap().allocator());
    try s.header();
    const nupvalues = try s.byte();
    const f = try Proto.create(th.heap());
    try s.function(f);
    if (nupvalues != f.upvalues.len) return s.fail("corrupted chunk");
    return f;
}

const Loader = struct {
    th: *Thread,
    src: []const u8,
    /// The next byte to read, which is also the offset from the start of
    /// the dump, for alignment.
    pos: usize,
    name: []const u8,
    /// Strings loaded so far; a reference to string i is `saved[i - 1]`.
    saved: std.ArrayList(*String) = .empty,

    fn fail(s: *Loader, why: []const u8) Error {
        const gpa = s.th.heap().allocator();
        const msg = try gpa.print("{s}: bad binary format ({s})", .{ s.name, why });
        defer gpa.free(msg);
        return s.th.throwRaw(.string(try s.th.state.newString(msg)));
    }

    fn block(s: *Loader, n: usize) Error![]const u8 {
        if (n > s.src.len - s.pos) return s.fail("truncated chunk");
        const b = s.src[s.pos..][0..n];
        s.pos += n;
        return b;
    }

    fn byte(s: *Loader) Error!u8 {
        return (try s.block(1))[0];
    }

    fn alignTo(s: *Loader, alignment: usize) Error!void {
        _ = try s.block((alignment - s.pos % alignment) % alignment);
    }

    /// Whether what is left can hold `n` items of at least `min_bytes`
    /// each. The reference allocates room for a count before it reads the
    /// items; a count that fails this check gets only `probe`, so the
    /// memory it touches stays bounded by the chunk, and then the error
    /// the reference meets next: `overlongBytes` or `overlong`.
    fn fits(s: *const Loader, n: u64, min_bytes: usize) bool {
        return n <= (s.src.len - s.pos) / min_bytes;
    }

    /// Asks the allocator for the block the reference allocates for `n`
    /// items of `item_size` bytes and gives it back untouched, so a count
    /// no allocator can satisfy is "not enough memory" here too.
    fn probe(s: *Loader, n: u64, item_size: usize) Error!void {
        const len = std.math.mul(usize, std.math.cast(usize, n) orelse return error.OutOfMemory, item_size) catch
            return error.OutOfMemory;
        const a = s.th.heap().allocator();
        const p = a.rawAlloc(len, .@"16", @returnAddress()) orelse return error.OutOfMemory;
        a.rawFree(p[0..len], .@"16", @returnAddress());
    }

    /// A count of plain bytes or bytes-only items that `fits` refused:
    /// what is left is too short for it.
    fn overlongBytes(s: *Loader, n: u64, item_size: usize) Error {
        try s.probe(n, item_size);
        return s.fail("truncated chunk");
    }

    /// Reads and drops the items of a count that `fits` refused, with
    /// `read`. Each takes at least the bytes `fits` assumed, so one of them
    /// fails, with the error the reference gives for the same bytes
    /// ("invalid constant", "integer overflow", ..., or a truncated chunk).
    fn overlong(s: *Loader, n: u64, item_size: usize, comptime read: anytype) Error {
        try s.probe(n, item_size);
        while (true) _ = try read(s);
    }

    fn varint(s: *Loader, limit_in: u64) Error!u64 {
        const limit = limit_in >> 7;
        var x: u64 = 0;
        while (true) {
            const b = try s.byte();
            if (x > limit) return s.fail("integer overflow");
            x = (x << 7) | (b & 0x7f);
            if (b & 0x80 == 0) return x;
        }
    }

    fn size(s: *Loader) Error!u64 {
        return s.varint(std.math.maxInt(i64));
    }

    fn int(s: *Loader) Error!u32 {
        return @intCast(try s.varint(std.math.maxInt(i32)));
    }

    fn native(s: *Loader, comptime T: type) Error!T {
        return std.mem.bytesToValue(T, try s.block(@sizeOf(T)));
    }

    fn integer(s: *Loader) Error!i64 {
        const cx = try s.varint(std.math.maxInt(u64));
        return @bitCast(if (cx & 1 != 0) ~(cx >> 1) else cx >> 1);
    }

    /// A string or null: a new one is saved for later references.
    fn string(s: *Loader) Error!?*String {
        const n = try s.size();
        if (n == 0) {
            const idx = try s.varint(std.math.maxInt(u64));
            if (idx == 0) return null;
            if (idx > s.saved.items.len) return s.fail("invalid string index");
            return s.saved.items[@intCast(idx - 1)];
        }
        // The reference makes a long string before reading its bytes.
        if (n - 1 > String.max_short_len and !s.fits(n, 1)) return s.overlongBytes(n, 1);
        const b = try s.block(@intCast(n));
        const str = try s.th.state.newString(b[0 .. b.len - 1]);
        try s.saved.append(s.th.heap().allocator(), str);
        return str;
    }

    fn constant(s: *Loader) Error!Value {
        return switch (try s.byte()) {
            dump.Tag.nil => .nil,
            dump.Tag.false_ => .boolean(false),
            dump.Tag.true_ => .boolean(true),
            dump.Tag.float => .float(try s.native(f64)),
            dump.Tag.int => .int(try s.integer()),
            dump.Tag.short_string, dump.Tag.long_string => .string(try s.string() orelse
                return s.fail("bad format for constant string")),
            else => s.fail("invalid constant"),
        };
    }

    fn locVar(s: *Loader) Error!Proto.LocVar {
        const name = try s.string();
        const startpc = try s.int();
        return .{ .name = name, .startpc = startpc, .endpc = try s.int() };
    }

    /// A nested function outside any array, which the heap holds.
    fn newFunction(s: *Loader) Error!void {
        try s.function(try Proto.create(s.th.heap()));
    }

    fn checkLiteral(s: *Loader, lit: []const u8, why: []const u8) Error!void {
        if (!std.mem.eql(u8, try s.block(lit.len), lit)) return s.fail(why);
    }

    fn checkNum(s: *Loader, comptime T: type, v: T, comptime tname: []const u8) Error!void {
        if (try s.byte() != @sizeOf(T)) return s.fail(tname ++ " size mismatch");
        if (try s.native(T) != v) return s.fail(tname ++ " format mismatch");
    }

    fn header(s: *Loader) Error!void {
        try s.checkLiteral(dump.signature[1..], "not a binary chunk");
        if (try s.byte() != dump.version) return s.fail("version mismatch");
        if (try s.byte() != dump.format) return s.fail("format mismatch");
        try s.checkLiteral(dump.data, "corrupted chunk");
        try s.checkNum(i32, dump.check_int, "int");
        try s.checkNum(u32, dump.check_inst, "instruction");
        try s.checkNum(i64, dump.check_int, "Lua integer");
        try s.checkNum(f64, dump.check_num, "Lua number");
    }

    /// Fills `f`, which the heap already holds. Every slice is valid (its
    /// elements nil or null) before anything is read into it, so the
    /// prototype is consistent whenever a read fails.
    fn function(s: *Loader, f: *Proto) Error!void {
        const gpa = s.th.heap().allocator();
        f.linedefined = try s.int();
        f.lastlinedefined = try s.int();
        f.numparams = try s.byte();
        f.flags = @bitCast((try s.byte()) & ~@as(u8, dump.pf_fixed));
        f.maxstacksize = try s.byte();

        const ncode = try s.int();
        try s.alignTo(@sizeOf(u32));
        if (!s.fits(ncode, @sizeOf(u32))) return s.overlongBytes(ncode, @sizeOf(u32));
        const code_bytes = try s.block(ncode * @sizeOf(u32));
        f.code = try gpa.alloc(u32, ncode);
        @memcpy(std.mem.sliceAsBytes(f.code), code_bytes);
        // The interpreter's dispatch trusts every opcode, so a chunk with
        // one outside the set fails here instead of running into it.
        for (f.code) |i| {
            if (@as(u7, @truncate(i)) >= opcodes.props.len) return s.fail("invalid opcode");
        }

        const nk = try s.int();
        if (!s.fits(nk, 1)) return s.overlong(nk, @sizeOf(Value), constant);
        f.k = try gpa.alloc(Value, nk);
        @memset(f.k, .nil);
        for (f.k) |*k| k.* = try s.constant();

        try f.initSlots(gpa);

        const nup = try s.int();
        if (!s.fits(nup, 3)) return s.overlongBytes(nup, @sizeOf(Proto.UpvalDesc));
        f.upvalues = try gpa.alloc(Proto.UpvalDesc, nup);
        @memset(f.upvalues, .{ .instack = false, .idx = 0 });
        for (f.upvalues) |*u| {
            const b = try s.block(3);
            u.* = .{ .instack = b[0] != 0, .idx = b[1], .kind = b[2] };
        }

        const np = try s.int();
        if (!s.fits(np, 1)) return s.overlong(np, @sizeOf(*Proto), newFunction);
        const protos = try gpa.alloc(*Proto, np);
        var made: usize = 0;
        errdefer if (made < np) gpa.free(protos);
        while (made < np) : (made += 1) protos[made] = try Proto.create(s.th.heap());
        f.p = protos;
        for (f.p) |p| try s.function(p);

        f.source = try s.string();
        try s.debug(f);
    }

    fn debug(s: *Loader, f: *Proto) Error!void {
        const gpa = s.th.heap().allocator();
        const nlines = try s.int();
        if (!s.fits(nlines, 1)) return s.overlongBytes(nlines, 1);
        const rel: []const i8 = @ptrCast(try s.block(nlines));
        f.lineinfo = try gpa.dupe(i8, rel);
        const nabs = try s.int();
        if (nabs > 0) {
            try s.alignTo(@sizeOf(i32));
            if (!s.fits(nabs, @sizeOf(Proto.AbsLineInfo))) return s.overlongBytes(nabs, @sizeOf(Proto.AbsLineInfo));
            const abs = try s.block(nabs * @sizeOf(Proto.AbsLineInfo));
            f.abslineinfo = try gpa.alloc(Proto.AbsLineInfo, nabs);
            @memcpy(std.mem.sliceAsBytes(f.abslineinfo), abs);
        }

        const nloc = try s.int();
        if (!s.fits(nloc, 3)) return s.overlong(nloc, @sizeOf(Proto.LocVar), locVar);
        f.locvars = try gpa.alloc(Proto.LocVar, nloc);
        @memset(f.locvars, .{ .name = null, .startpc = 0, .endpc = 0 });
        for (f.locvars) |*lv| lv.* = try s.locVar();

        // Upvalue names come all or none.
        if (try s.int() != 0) {
            for (f.upvalues) |*u| u.name = try s.string();
        }
    }
};

const testing = std.testing;
const State = @import("State.zig");

fn dumpToOwned(f: *const Proto, strip: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try dump.dump(testing.allocator, &out.writer, f, strip);
    return out.toOwnedSlice();
}

/// Decodes every instruction's line, as the debug library and hooks do.
fn readLines(p: *const Proto) void {
    for (0..p.code.len) |pc| {
        _ = p.lineAt(pc);
        if (pc > 0) _ = p.changedLine(pc - 1, pc);
    }
}

fn expectFailure(th: *Thread, chunk: []const u8, msg: []const u8) !void {
    try testing.expectError(error.LuaError, undump(th, chunk, "=c"));
    try testing.expectEqualStrings(msg, th.err.asString().bytes());
    th.err = .nil;
}

test "luac's chunk loads and dumps back byte for byte" {
    const state = try State.create(testing.allocator, .{});
    defer state.destroy();
    var chunk: [dump.test_luac.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&chunk, dump.test_luac);
    const p = try undump(state.main, &chunk, "@golden.lua");
    try testing.expectEqualStrings("@golden.lua", p.source.?.bytes());
    // `TFORCALL` and `TFORLOOP` sit on the `for` line, between lines 133.
    const lines = [_]i32{ 1, 1, 1, 1, 2, 3, 3, 3, 3, 133, 3, 3, 133, 134, 134 };
    try testing.expectEqual(lines.len, p.lineinfo.len);
    for (lines, 0..) |line, pc| try testing.expectEqual(line, p.lineAt(pc).?);
    const again = try dumpToOwned(p, false);
    defer testing.allocator.free(again);
    try testing.expectEqualSlices(u8, &chunk, again);
}

test "bad chunks raise the reference's messages and never crash" {
    const state = try State.create(testing.allocator, .{});
    defer state.destroy();
    const th = state.main;
    var chunk: [dump.test_luac.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&chunk, dump.test_luac);
    for (1..chunk.len) |n| try expectFailure(th, chunk[0..n], "c: bad binary format (truncated chunk)");
    const headers = [_]struct { at: usize, byte: u8, msg: []const u8 }{
        .{ .at = 1, .byte = 'M', .msg = "not a binary chunk" },
        .{ .at = 4, .byte = 0x54, .msg = "version mismatch" },
        .{ .at = 5, .byte = 1, .msg = "format mismatch" },
        .{ .at = 8, .byte = '\n', .msg = "corrupted chunk" },
        .{ .at = 12, .byte = 8, .msg = "int size mismatch" },
        .{ .at = 13, .byte = 0, .msg = "int format mismatch" },
        .{ .at = 17, .byte = 2, .msg = "instruction size mismatch" },
        .{ .at = 21, .byte = 0, .msg = "instruction format mismatch" },
        .{ .at = 22, .byte = 4, .msg = "Lua integer size mismatch" },
        .{ .at = 30, .byte = 0, .msg = "Lua integer format mismatch" },
        .{ .at = 31, .byte = 4, .msg = "Lua number size mismatch" },
        .{ .at = 39, .byte = 0, .msg = "Lua number format mismatch" },
        .{ .at = 40, .byte = 2, .msg = "corrupted chunk" },
    };
    for (headers) |h| {
        var bad = chunk;
        bad[h.at] = h.byte;
        var buf: [64]u8 = undefined;
        try expectFailure(th, &bad, try std.mem.print(&buf, "c: bad binary format ({s})", .{h.msg}));
    }
    // A count the bytes left cannot hold fails on its first bad item, as
    // the reference reads the items before running out: the header, then
    // a function with no code (one byte of padding) and 100 constants.
    const head = chunk[0..41].* ++ [_]u8{ 0, 0, 0, 0, 2, 0, 0, 100 };
    try expectFailure(th, &(head ++ [_]u8{ dump.Tag.nil, 0x55 }), "c: bad binary format (invalid constant)");
    const bad_index = head ++ [_]u8{ dump.Tag.short_string, 0, 1 };
    try expectFailure(th, &bad_index, "c: bad binary format (invalid string index)");
    try expectFailure(th, &(head ++ [_]u8{ dump.Tag.nil, dump.Tag.true_ }), "c: bad binary format (truncated chunk)");
    // An opcode outside the set, in the main function or a nested one,
    // with the rest of the instruction intact. 84 (EXTRAARG) is the last
    // valid one.
    const golden = try undump(th, &chunk, "=c");
    for ([_]*const Proto{ golden, golden.p[0] }) |f| {
        const at = std.mem.find(u8, &chunk, std.mem.asBytes(&f.code[0])).?;
        for ([_]u7{ 85, 127 }) |o| {
            var bad = chunk;
            bad[at] = (bad[at] & 0x80) | o;
            try expectFailure(th, &bad, "c: bad binary format (invalid opcode)");
        }
        var ok = chunk;
        ok[at] = (ok[at] & 0x80) | 84;
        _ = try undump(th, &ok, "=c");
    }
    // Any single corrupted byte loads or fails cleanly, and whatever loads
    // dumps again and reads its lines.
    for (0..chunk.len) |at| {
        for ([_]u8{ 0x01, 0x40, 0x80, 0xff }) |flip| {
            var bad = chunk;
            bad[at] ^= flip;
            const p = undump(th, &bad, "=c") catch |e| {
                try testing.expectEqual(error.LuaError, e);
                th.err = .nil;
                continue;
            };
            testing.allocator.free(try dumpToOwned(p, false));
            readLines(p);
            for (p.p) |q| readLines(q);
        }
    }
}

test "a stripped dump loads without debug information" {
    const state = try State.create(testing.allocator, .{});
    defer state.destroy();
    var chunk: [dump.test_luac.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&chunk, dump.test_luac);
    const p = try undump(state.main, &chunk, "=c");
    const stripped = try dumpToOwned(p, true);
    defer testing.allocator.free(stripped);
    const q = try undump(state.main, stripped, "=c");
    try testing.expect(q.source == null and q.lineinfo.len == 0 and q.locvars.len == 0);
    try testing.expect(q.upvalues[0].name == null and q.p[0].source == null);
    try testing.expectEqualSlices(u32, p.code, q.code);
    const again = try dumpToOwned(q, true);
    defer testing.allocator.free(again);
    try testing.expectEqualSlices(u8, stripped, again);
}

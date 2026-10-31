//! The table library, the reference manual's §6.6, after ltablib.c: every
//! function reads and writes through `__index` and `__newindex` and takes
//! lengths through `__len`, and accepts any value whose metatable supplies
//! the metamethods it needs. `sort` is the reference's quicksort, so the
//! comparator sees the same calls and "invalid order function for sorting"
//! fires where it does there.

const std = @import("std");
const Value = @import("../Value.zig");
const Thread = @import("../Thread.zig");
const State = @import("../State.zig");
const Table = @import("../Table.zig");
const number = @import("../number.zig");
const vm = @import("../vm.zig");
const auxlib = @import("auxlib.zig");

const Error = Value.Error;
const Args = auxlib.Args;
const raise = auxlib.raise;
const getI = auxlib.getI;
const setI = auxlib.setI;

const max_int = std.math.maxInt(i64);
/// `INT_MAX`, which bounds `unpack`'s results and `sort`'s length.
const c_int_max = std.math.maxInt(i32);

/// Creates the `table` table and sets the global.
pub fn open(state: *State) Error!void {
    const lib = try auxlib.newLib(state, .{
        .{ "concat", concat },
        .{ "create", create },
        .{ "insert", insert },
        .{ "pack", pack },
        .{ "unpack", unpack },
        .{ "remove", remove },
        .{ "move", move },
        .{ "sort", sort },
    });
    try auxlib.setField(state, state.globals, "table", .table(lib));
}

/// The operations a value must support to stand in for a table.
const Ops = packed struct(u3) {
    read: bool = false,
    write: bool = false,
    length: bool = false,
};

/// `checktab`: argument `n` is a table, or has a metatable with the
/// metamethods `ops` needs (strings have a length without `__len`).
fn checkTab(a: Args, n: u32, ops: Ops) Error!void {
    const v = a.get(n);
    if (v.tag == .table) return;
    const state = a.th.state;
    if (state.metatableOf(v)) |mt| {
        const has = struct {
            fn f(s: *State, t: anytype, comptime name: []const u8) bool {
                const key = s.newString(name) catch return false;
                return !t.getShortStr(key).isNil();
            }
        }.f;
        if ((!ops.read or has(state, mt, "__index")) and
            (!ops.write or has(state, mt, "__newindex")) and
            (!ops.length or v.isString() or has(state, mt, "__len"))) return;
    }
    return a.typeError(n, "table");
}

/// `aux_getn`: checks argument `n` and returns its length.
fn getn(a: Args, n: u32, ops: Ops) Error!i64 {
    var o = ops;
    o.length = true;
    try checkTab(a, n, o);
    return auxlib.lenInt(a.th, a.get(n));
}

fn create(th: *Thread, base: u32) Error!u32 {
    const a: Args = .init(th, base, "create");
    const sizeseq: u64 = @bitCast(try a.checkInteger(1));
    const sizerest: u64 = @bitCast(try a.optInteger(2, 0));
    if (sizeseq > c_int_max) return a.argError(1, "out of range", .{});
    if (sizerest > c_int_max) return a.argError(2, "out of range", .{});
    // `luaH_resize`: the hash part holds at most 2^30 nodes.
    if (sizerest > 1 << 30) return th.runError("table overflow", .{});
    th.push(.table(try th.state.newTable(@intCast(sizeseq), @intCast(sizerest))));
    return 1;
}

fn insert(th: *Thread, base: u32) Error!u32 {
    const a: Args = .init(th, base, "insert");
    const t = a.get(1);
    // The first empty element.
    const e = (try getn(a, 1, .{ .read = true, .write = true })) +% 1;
    var pos: i64 = undefined;
    switch (a.count()) {
        2 => pos = e,
        3 => {
            pos = try a.checkInteger(2);
            // pos in [1, e]
            if (@as(u64, @bitCast(pos)) -% 1 >= @as(u64, @bitCast(e))) return a.argError(
                2,
                "position out of bounds",
                .{},
            );
            var i = e;
            while (i > pos) : (i -= 1) try setI(th, t, i, try getI(th, t, i - 1));
        },
        else => return raise(th, "wrong number of arguments to 'insert'", .{}),
    }
    try setI(th, t, pos, a.get(a.count()));
    return 0;
}

fn remove(th: *Thread, base: u32) Error!u32 {
    const a: Args = .init(th, base, "remove");
    const t = a.get(1);
    const size = try getn(a, 1, .{ .read = true, .write = true });
    var pos = try a.optInteger(2, size);
    // pos in [1, size + 1] when given
    if (pos != size and @as(u64, @bitCast(pos)) -% 1 > @as(u64, @bitCast(size)))
        return a.argError(2, "position out of bounds", .{});
    try th.ensureStack(1);
    th.push(try getI(th, t, pos));
    while (pos < size) : (pos += 1) try setI(th, t, pos, try getI(th, t, pos + 1));
    try setI(th, t, pos, .nil);
    return 1;
}

/// Copies `a1[f..e]` to `tt[t..]`, in increasing order when that is safe:
/// the destination after the source, before it, or another table.
fn move(th: *Thread, base: u32) Error!u32 {
    const a: Args = .init(th, base, "move");
    const f = try a.checkInteger(2);
    const e = try a.checkInteger(3);
    const t = try a.checkInteger(4);
    const tt: u32 = if (!a.isNoneOrNil(5)) 5 else 1;
    try checkTab(a, 1, .{ .read = true });
    try checkTab(a, tt, .{ .write = true });
    const src = a.get(1);
    const dst = a.get(tt);
    if (e >= f) {
        if (!(f > 0 or e < max_int + f)) return a.argError(3, "too many elements to move", .{});
        const n = e - f + 1;
        if (t > max_int - n + 1) return a.argError(4, "destination wrap around", .{});
        if (t > e or t <= f or (tt != 1 and !try auxlib.equal(th, src, dst))) {
            var i: i64 = 0;
            while (i < n) : (i += 1) try setI(th, dst, t + i, try getI(th, src, f + i));
        } else {
            var i: i64 = n - 1;
            while (i >= 0) : (i -= 1) try setI(th, dst, t + i, try getI(th, src, f + i));
        }
    }
    try th.ensureStack(1);
    th.push(dst);
    return 1;
}

fn concat(th: *Thread, base: u32) Error!u32 {
    const a: Args = .init(th, base, "concat");
    const t = a.get(1);
    var last = try getn(a, 1, .{ .read = true });
    const sep = try a.optString(2, "");
    var i = try a.optInteger(3, 1);
    last = try a.optInteger(4, last);
    var b: auxlib.Buffer = .init(th.state);
    defer b.deinit();
    const w = &b.writer;
    while (i < last) : (i += 1) {
        try addField(th, w, t, i);
        w.writeAll(sep) catch return error.OutOfMemory;
        // The reference's buffer checks the collector each time it grows;
        // the table and the separator are on the stack, the buffer is not
        // an object.
        _ = th.state.checkGc(th);
    }
    if (i == last) try addField(th, w, t, i);
    try th.ensureStack(1);
    th.push(.string(try b.toString(th.state)));
    return 1;
}

fn addField(th: *Thread, w: *std.Io.Writer, t: Value, i: i64) Error!void {
    const v = try getI(th, t, i);
    if (v.isString()) {
        w.writeAll(v.asString().bytes()) catch return error.OutOfMemory;
    } else if (v.isNumber()) {
        var nb: [number.max_len]u8 = undefined;
        w.writeAll(auxlib.formatNumber(&nb, v)) catch return error.OutOfMemory;
    } else {
        return raise(th, "invalid value ({s}) at index {d} in table for 'concat'", .{ v.typeOf().name(), i });
    }
}

fn pack(th: *Thread, base: u32) Error!u32 {
    const n = th.top - base;
    const t = try th.state.newTable(n, 1);
    for (0..n) |i| try t.setInt(th.heap(), @intCast(i + 1), th.stack[base + i]);
    try auxlib.setField(th.state, t, "n", .int(n));
    th.push(.table(t));
    return 1;
}

fn unpack(th: *Thread, base: u32) Error!u32 {
    const a: Args = .init(th, base, "unpack");
    const t = a.get(1);
    const n_len = try getn(a, 1, .{ .read = true });
    var i = try a.optInteger(2, 1);
    const e = if (a.isNoneOrNil(3)) n_len else try a.checkInteger(3);
    if (i > e) return 0;
    // The number of elements minus one, as `lua_checkstack` counts.
    const n = @as(u64, @bitCast(e)) -% @as(u64, @bitCast(i));
    if (n >= c_int_max or th.top + Thread.extra_stack + n + 1 > Thread.max_stack)
        return raise(th, "too many results to unpack", .{});
    try th.ensureStack(@intCast(n + 1));
    while (i < e) : (i += 1) th.push(try getI(th, t, i));
    th.push(try getI(th, t, e));
    return @intCast(n + 1);
}

// ---------------------------------------------------------------------------
// sort: quicksort, after 'Algorithms in MODULA-3' (Sedgewick), as the
// reference implements it, keeping the values it holds on the Lua stack.
// ---------------------------------------------------------------------------

/// Arrays larger than this may use randomized pivots (`RANLIMIT`).
const ran_limit = 100;

const Sorter = struct {
    th: *Thread,
    t: Value,
    /// The order function, or nil for `<`.
    cmp: Value,

    /// Pushes `t[i]`.
    fn geti(s: *const Sorter, i: u32) Error!void {
        const v = try getI(s.th, s.t, i);
        try s.th.ensureStack(1);
        s.th.push(v);
    }

    /// Pops the top value into `t[i]`.
    fn seti(s: *const Sorter, i: u32) Error!void {
        try setI(s.th, s.t, i, s.th.stack[s.th.top - 1]);
        s.th.top -= 1;
    }

    fn set2(s: *const Sorter, i: u32, j: u32) Error!void {
        try s.seti(i);
        try s.seti(j);
    }

    fn pop(s: *const Sorter, n: u32) void {
        s.th.top -= n;
    }

    /// Whether the value `a` slots below the top sorts before the one `b`
    /// slots below it (`sort_comp` with negative indices). Out of line: the
    /// comparator's call is on the native stack of every level of a sort
    /// inside a comparator, and inlined, each of its six uses kept its own
    /// arguments in `sort`'s frame (`results/stack-20261031.md`).
    noinline fn less(s: *const Sorter, a: u32, b: u32) Error!bool {
        const th = s.th;
        const x = th.stack[th.top - a];
        const y = th.stack[th.top - b];
        if (s.cmp.isNil()) return auxlib.lessThan(th, x, y);
        // Pushed here rather than through `auxlib.call1`, one frame less.
        try th.ensureStack(3);
        const func = th.top;
        th.push(s.cmp);
        th.push(x);
        th.push(y);
        try vm.call(th, func, 1);
        th.top = func;
        return !th.stack[func].isFalsy();
    }

    /// Partitions `t[lo..up]` around the pivot P on top of the stack, with
    /// `a[lo] <= P == a[up-1] <= a[up]`; returns P's final index.
    fn partition(s: *const Sorter, lo: u32, up: u32) Error!u32 {
        var i = lo;
        var j = up - 1;
        while (true) {
            // Repeat ++i while a[i] < P.
            i += 1;
            try s.geti(i);
            while (try s.less(1, 2)) {
                if (i == up - 1) return raise(s.th, "invalid order function for sorting", .{});
                s.pop(1);
                i += 1;
                try s.geti(i);
            }
            // Repeat --j while P < a[j].
            j -= 1;
            try s.geti(j);
            while (try s.less(3, 1)) {
                if (j < i) return raise(s.th, "invalid order function for sorting", .{});
                s.pop(1);
                j -= 1;
                try s.geti(j);
            }
            if (j < i) {
                s.pop(1);
                try s.set2(up - 1, i);
                return i;
            }
            try s.set2(i, j);
        }
    }

    fn sort(s: *const Sorter, lo_in: u32, up_in: u32, rnd_in: u32) Error!void {
        var lo = lo_in;
        var up = up_in;
        var rnd = rnd_in;
        while (lo < up) {
            // Sort a[lo], a[p], a[up].
            try s.geti(lo);
            try s.geti(up);
            if (try s.less(1, 2)) try s.set2(lo, up) else s.pop(2);
            if (up - lo == 1) return;
            var p: u32 = if (up - lo < ran_limit or rnd == 0) lo + (up - lo) / 2 else choosePivot(lo, up, rnd);
            try s.geti(p);
            try s.geti(lo);
            if (try s.less(2, 1)) {
                try s.set2(p, lo);
            } else {
                s.pop(1);
                try s.geti(up);
                if (try s.less(1, 2)) try s.set2(p, up) else s.pop(2);
            }
            if (up - lo == 2) return;
            // Swap the pivot P = a[p] with a[up - 1], keeping a copy on top.
            try s.geti(p);
            try s.th.ensureStack(1);
            s.th.push(s.th.stack[s.th.top - 1]);
            try s.geti(up - 1);
            try s.set2(p, up - 1);
            p = try s.partition(lo, up);
            // Recurse into the smaller half, loop on the larger.
            var n: u32 = undefined;
            if (p - lo < up - p) {
                try s.sort(lo, p - 1, rnd);
                n = p - lo;
                lo = p + 1;
            } else {
                try s.sort(p + 1, up, rnd);
                n = up - p;
                up = p - 1;
            }
            if ((up -% lo) / 128 > n) rnd = randomPivot(s.th);
        }
    }
};

/// A pivot in the middle half of [lo, up], "randomized" by `rnd`.
fn choosePivot(lo: u32, up: u32, rnd: u32) u32 {
    const r4 = (up - lo) / 4;
    return (rnd ^ lo ^ up) % (r4 * 2) + (lo + r4);
}

/// `l_randomizePivot`, which the reference takes from `luaL_makeseed`: any
/// value that varies will do.
fn randomPivot(th: *Thread) u32 {
    var local: u8 = 0;
    return @truncate(std.hash.Wyhash.hash(th.state.seed, std.mem.asBytes(&[_]usize{ @intFromPtr(&local), th.top })));
}

fn sort(th: *Thread, base: u32) Error!u32 {
    const a: Args = .init(th, base, "sort");
    const n = try sortLength(a);
    if (n > 1) {
        const s: Sorter = .{ .th = th, .t = a.get(1), .cmp = a.get(2) };
        try s.sort(1, n, 0);
    }
    return 0;
}

/// `sort`'s checks, and the length of the table. Out of line: `sort`'s
/// frame is on the native stack of every level of a sort inside a
/// comparator, and these locals need not be (`results/stack-20261031.md`).
noinline fn sortLength(a: Args) Error!u32 {
    const n = try getn(a, 1, .{ .read = true, .write = true });
    if (n <= 1) return 0;
    if (n >= c_int_max) return a.argError(1, "array too big", .{});
    if (!a.isNoneOrNil(2) and !a.get(2).isFunction()) return a.typeError(2, "function");
    return @intCast(n);
}

// ---------------------------------------------------------------------------
// Tests. Expected values come from reference Lua 5.5.1 (`lua` in the dev
// shell), most from the cases in test/lua-5.5.1-tests/sort.lua and
// nextvar.lua.
// ---------------------------------------------------------------------------

const testing = std.testing;
const h = auxlib.testing;

test "table functions match the reference" {
    @setEvalBranchQuota(100_000);
    const state = try h.newState();
    defer state.destroy();
    try open(state);
    try h.expectCases(state, .{
        .{ "table.concat", .{@as(i64, 3)}, "error: bad argument #1 to 'concat' (table expected, got number)" },
        .{
            "table.concat",
            .{ .{ .kv = .{} }, " ", @as(i64, 9223372036854775807), @as(i64, 9223372036854775807) },
            "error: invalid value (nil) at index 9223372036854775807 in table for 'concat'",
        },
        .{
            "table.concat",
            .{ .{ .kv = .{} }, " ", @as(i64, -9223372036854775807 - 1), @as(i64, -9223372036854775807 - 1) },
            "error: invalid value (nil) at index -9223372036854775808 in table for 'concat'",
        },
        .{ "table.concat", .{.{ .kv = .{} }}, "" },
        .{ "table.concat", .{ .{ .kv = .{} }, "x" }, "" },
        .{
            "table.concat",
            .{
                .{
                    .kv = .{ .{ @as(i64, 1), "\x00" }, .{ @as(i64, 2), "\x00\x01" }, .{ @as(i64, 3), "\x00\x01\x02" } },
                },
                ".\x00.",
            },
            "\x00.\x00.\x00\x01.\x00.\x00\x01\x02",
        },
        .{ "table.concat", .{ .{ .kv = .{} }, "x", @as(i64, 9223372036854775807), @as(i64, 9223372036854775806) }, "" },
        .{
            "table.concat",
            .{ .{ .kv = .{} }, "x", @as(i64, -9223372036854775807), @as(i64, -9223372036854775807 - 1) },
            "",
        },
        .{
            "table.concat",
            .{ .{ .kv = .{} }, "x", @as(i64, 9223372036854775807), @as(i64, -9223372036854775807 - 1) },
            "",
        },
        .{
            "table.concat",
            .{
                .{ .kv = .{.{ @as(i64, 9223372036854775807), "alo" }} },
                "x",
                @as(i64, 9223372036854775807),
                @as(i64, 9223372036854775807),
            },
            "alo",
        },
        .{
            "table.concat",
            .{
                .{ .kv = .{ .{ @as(i64, 9223372036854775806), "y" }, .{ @as(i64, 9223372036854775807), "alo" } } },
                "-",
                @as(i64, 9223372036854775806),
                @as(i64, 9223372036854775807),
            },
            "y-alo",
        },
        .{
            "table.concat",
            .{.{ .kv = .{ .{ @as(i64, 1), "a" }, .{ @as(i64, 2), "b" }, .{ @as(i64, 3), .{ .kv = .{} } } } }},
            "error: invalid value (table) at index 3 in table for 'concat'",
        },
        .{
            "table.concat",
            .{
                .{ .kv = .{ .{ @as(i64, 1), "a" }, .{ @as(i64, 2), "b" }, .{ @as(i64, 3), "c" } } },
                ",",
                @as(i64, 1),
                @as(i64, 0),
            },
            "",
        },
        .{
            "table.concat",
            .{
                .{ .kv = .{ .{ @as(i64, 1), "a" }, .{ @as(i64, 2), "b" }, .{ @as(i64, 3), "c" } } },
                ",",
                @as(i64, 1),
                @as(i64, 1),
            },
            "a",
        },
        .{
            "table.concat",
            .{
                .{ .kv = .{ .{ @as(i64, 1), "a" }, .{ @as(i64, 2), "b" }, .{ @as(i64, 3), "c" } } },
                ",",
                @as(i64, 1),
                @as(i64, 2),
            },
            "a,b",
        },
        .{
            "table.concat",
            .{ .{ .kv = .{ .{ @as(i64, 1), "a" }, .{ @as(i64, 2), "b" }, .{ @as(i64, 3), "c" } } }, ",", @as(i64, 2) },
            "b,c",
        },
        .{
            "table.concat",
            .{ .{ .kv = .{ .{ @as(i64, 1), "a" }, .{ @as(i64, 2), "b" }, .{ @as(i64, 3), "c" } } }, ",", @as(i64, 3) },
            "c",
        },
        .{
            "table.concat",
            .{ .{ .kv = .{ .{ @as(i64, 1), "a" }, .{ @as(i64, 2), "b" }, .{ @as(i64, 3), "c" } } }, ",", @as(i64, 4) },
            "",
        },
        .{
            "table.concat",
            .{
                .{
                    .kv = .{
                        .{ @as(i64, 1), @as(i64, 1) },
                        .{ @as(i64, 2), @as(f64, 2.5) },
                        .{ @as(i64, 3), @as(f64, 3.0) },
                        .{ @as(i64, 4), "x" },
                    },
                },
                ", ",
            },
            "1, 2.5, 3.0, x",
        },
        .{
            "table.concat",
            .{ .{ .kv = .{ .{ @as(i64, 1), @as(i64, 1) }, .{ @as(i64, 2), @as(i64, 2) } } }, @as(i64, 3) },
            "132",
        },
        .{
            "table.concat",
            .{ .{ .kv = .{ .{ @as(i64, 1), @as(i64, 1) }, .{ @as(i64, 2), @as(i64, 2) } } }, .{ .kv = .{} } },
            "error: bad argument #2 to 'concat' (string expected, got table)",
        },
        .{ "table.concat", .{.{ .kv = .{ .{ @as(i64, 1), @as(i64, 1) }, .{ @as(i64, 3), @as(i64, 3) } } }}, "1" },
        .{
            "table.concat",
            .{.{ .kv = .{.{ @as(i64, 1), true }} }},
            "error: invalid value (boolean) at index 1 in table for 'concat'",
        },
        .{
            "table.concat",
            .{ .{ .kv = .{ .{ @as(i64, 1), @as(i64, 1) }, .{ @as(i64, 2), @as(i64, 2) } } }, "", @as(f64, 1.5) },
            "error: bad argument #3 to 'concat' (number has no integer representation)",
        },
        .{
            "table.unpack",
            .{
                .{
                    .kv = .{
                        .{ @as(i64, 1), @as(i64, 1) },
                        .{ @as(i64, 2), @as(i64, 2) },
                        .{ @as(i64, 3), @as(i64, 3) },
                    },
                },
            },
            "1\t2\t3",
        },
        .{
            "table.unpack",
            .{
                .{
                    .kv = .{
                        .{ @as(i64, 1), @as(i64, 1) },
                        .{ @as(i64, 2), @as(i64, 2) },
                        .{ @as(i64, 3), @as(i64, 3) },
                    },
                },
                @as(i64, 2),
            },
            "2\t3",
        },
        .{
            "table.unpack",
            .{
                .{
                    .kv = .{
                        .{ @as(i64, 1), @as(i64, 1) },
                        .{ @as(i64, 2), @as(i64, 2) },
                        .{ @as(i64, 3), @as(i64, 3) },
                    },
                },
                @as(i64, 2),
                @as(i64, 5),
            },
            "2\t3\tnil\tnil",
        },
        .{
            "table.unpack",
            .{
                .{
                    .kv = .{
                        .{ @as(i64, 1), @as(i64, 1) },
                        .{ @as(i64, 2), @as(i64, 2) },
                        .{ @as(i64, 3), @as(i64, 3) },
                    },
                },
                @as(i64, 0),
            },
            "nil\t1\t2\t3",
        },
        .{
            "table.unpack",
            .{
                .{
                    .kv = .{
                        .{ @as(i64, 1), @as(i64, 1) },
                        .{ @as(i64, 2), @as(i64, 2) },
                        .{ @as(i64, 3), @as(i64, 3) },
                    },
                },
                @as(i64, -1),
                @as(i64, 1),
            },
            "nil\tnil\t1",
        },
        .{
            "table.unpack",
            .{ .{ .kv = .{} }, @as(i64, 0), @as(i64, 9223372036854775807) },
            "error: too many results to unpack",
        },
        .{
            "table.unpack",
            .{ .{ .kv = .{} }, @as(i64, 1), @as(i64, 9223372036854775807) },
            "error: too many results to unpack",
        },
        .{
            "table.unpack",
            .{ .{ .kv = .{} }, @as(i64, -9223372036854775807 - 1), @as(i64, 9223372036854775807) },
            "error: too many results to unpack",
        },
        .{
            "table.unpack",
            .{ .{ .kv = .{} }, @as(i64, -9223372036854775807), @as(i64, 9223372036854775807) },
            "error: too many results to unpack",
        },
        .{
            "table.unpack",
            .{ .{ .kv = .{} }, @as(i64, -9223372036854775807 - 1), @as(i64, -9223372036854775807 - 1) },
            "nil",
        },
        .{ "table.unpack", .{ .{ .kv = .{} }, @as(i64, 9223372036854775807), @as(i64, 9223372036854775807) }, "nil" },
        .{
            "table.unpack",
            .{ .{ .kv = .{} }, @as(i64, 9223372036854775806), @as(i64, 9223372036854775807) },
            "nil\tnil",
        },
        .{ "table.unpack", .{ .{ .kv = .{} }, @as(i64, 1), @as(i64, 0) }, "" },
        .{ "table.unpack", .{ .{ .kv = .{} }, @as(i64, 3), @as(i64, 1) }, "" },
        .{ "table.unpack", .{}, "error: bad argument #1 to 'unpack' (table expected, got no value)" },
        .{ "table.unpack", .{ .{ .kv = .{.{ @as(i64, 1), "a" }} }, null, @as(i64, 2) }, "a\tnil" },
        .{ "table.unpack", .{ .{ .kv = .{} }, @as(i64, 1), @as(i64, 1000000) }, "error: too many results to unpack" },
        .{
            "table.unpack",
            .{ .{ .kv = .{} }, @as(i64, 1), @as(f64, 1.5) },
            "error: bad argument #3 to 'unpack' (number has no integer representation)",
        },
        .{ "table.pack", .{}, "table" },
        .{ "table.create", .{@as(i64, 10)}, "table" },
        .{ "table.create", .{ @as(i64, 0), @as(i64, 1024) }, "table" },
        .{ "table.create", .{@as(i64, 2147483648)}, "error: bad argument #1 to 'create' (out of range)" },
        .{
            "table.create",
            .{ @as(i64, 0), @as(i64, 2147483648) },
            "error: bad argument #2 to 'create' (out of range)",
        },
        .{ "table.create", .{ @as(i64, 0), @as(i64, 2147483647) }, "error: table overflow" },
        .{ "table.create", .{@as(i64, -1)}, "error: bad argument #1 to 'create' (out of range)" },
        .{
            "table.create",
            .{@as(f64, 1.5)},
            "error: bad argument #1 to 'create' (number has no integer representation)",
        },
        .{ "table.create", .{}, "error: bad argument #1 to 'create' (number expected, got no value)" },
        .{
            "table.insert",
            .{ .{ .kv = .{} }, @as(i64, 2), @as(i64, 3), @as(i64, 4) },
            "error: wrong number of arguments to 'insert'",
        },
        .{ "table.insert", .{.{ .kv = .{} }}, "error: wrong number of arguments to 'insert'" },
        .{
            "table.insert",
            .{ .{ .kv = .{} }, @as(i64, 3), @as(i64, 1) },
            "error: bad argument #2 to 'insert' (position out of bounds)",
        },
        .{
            "table.insert",
            .{ .{ .kv = .{} }, @as(i64, 0), @as(i64, 1) },
            "error: bad argument #2 to 'insert' (position out of bounds)",
        },
        .{
            "table.insert",
            .{ .{ .kv = .{.{ @as(i64, 1), @as(i64, 1) }} }, @as(f64, 1.5), @as(i64, 1) },
            "error: bad argument #2 to 'insert' (number has no integer representation)",
        },
        .{
            "table.insert",
            .{ @as(i64, 1), @as(i64, 2) },
            "error: bad argument #1 to 'insert' (table expected, got number)",
        },
        .{ "table.remove", .{.{ .kv = .{} }}, "nil" },
        .{
            "table.remove",
            .{
                .{
                    .kv = .{
                        .{ @as(i64, 1), @as(i64, 1) },
                        .{ @as(i64, 2), @as(i64, 2) },
                        .{ @as(i64, 3), @as(i64, 3) },
                    },
                },
            },
            "3",
        },
        .{
            "table.remove",
            .{
                .{
                    .kv = .{
                        .{ @as(i64, 1), @as(i64, 1) },
                        .{ @as(i64, 2), @as(i64, 2) },
                        .{ @as(i64, 3), @as(i64, 3) },
                    },
                },
                @as(i64, 1),
            },
            "1",
        },
        .{
            "table.remove",
            .{
                .{
                    .kv = .{
                        .{ @as(i64, 1), @as(i64, 1) },
                        .{ @as(i64, 2), @as(i64, 2) },
                        .{ @as(i64, 3), @as(i64, 3) },
                    },
                },
                @as(i64, 4),
            },
            "nil",
        },
        .{
            "table.remove",
            .{
                .{
                    .kv = .{
                        .{ @as(i64, 1), @as(i64, 1) },
                        .{ @as(i64, 2), @as(i64, 2) },
                        .{ @as(i64, 3), @as(i64, 3) },
                    },
                },
                @as(i64, 5),
            },
            "error: bad argument #2 to 'remove' (position out of bounds)",
        },
        .{ "table.remove", .{ .{ .kv = .{} }, @as(i64, 0) }, "nil" },
        .{ "table.remove", .{ .{ .kv = .{} }, @as(i64, 1) }, "nil" },
        .{
            "table.remove",
            .{ .{ .kv = .{} }, @as(i64, -1) },
            "error: bad argument #2 to 'remove' (position out of bounds)",
        },
        .{ "table.remove", .{ .{ .kv = .{.{ @as(i64, 0), "z" }} }, @as(i64, 0) }, "z" },
        .{
            "table.move",
            .{ @as(i64, 1), @as(i64, 2), @as(i64, 3), @as(i64, 4) },
            "error: bad argument #1 to 'move' (table expected, got number)",
        },
        .{
            "table.move",
            .{ .{ .kv = .{} }, @as(i64, 0), @as(i64, 9223372036854775807), @as(i64, 1) },
            "error: bad argument #3 to 'move' (too many elements to move)",
        },
        .{
            "table.move",
            .{ .{ .kv = .{} }, @as(i64, -1), @as(i64, 9223372036854775806), @as(i64, 1) },
            "error: bad argument #3 to 'move' (too many elements to move)",
        },
        .{
            "table.move",
            .{ .{ .kv = .{} }, @as(i64, -9223372036854775807 - 1), @as(i64, -1), @as(i64, 1) },
            "error: bad argument #3 to 'move' (too many elements to move)",
        },
        .{
            "table.move",
            .{ .{ .kv = .{} }, @as(i64, -9223372036854775807 - 1), @as(i64, 9223372036854775807), @as(i64, 1) },
            "error: bad argument #3 to 'move' (too many elements to move)",
        },
        .{
            "table.move",
            .{ .{ .kv = .{} }, @as(i64, 1), @as(i64, 9223372036854775807), @as(i64, 2) },
            "error: bad argument #4 to 'move' (destination wrap around)",
        },
        .{
            "table.move",
            .{ .{ .kv = .{} }, @as(i64, 1), @as(i64, 2), @as(i64, 9223372036854775807) },
            "error: bad argument #4 to 'move' (destination wrap around)",
        },
        .{
            "table.move",
            .{ .{ .kv = .{} }, @as(i64, -9223372036854775807 - 1), @as(i64, -2), @as(i64, 2) },
            "error: bad argument #4 to 'move' (destination wrap around)",
        },
        .{ "table.move", .{ .{ .kv = .{} }, @as(i64, 1), @as(i64, 0), @as(i64, 1) }, "table" },
        .{
            "table.move",
            .{ .{ .kv = .{} }, @as(i64, 1), @as(i64, 2) },
            "error: bad argument #4 to 'move' (number expected, got no value)",
        },
        .{
            "table.move",
            .{ .{ .kv = .{} }, @as(i64, 1), @as(i64, 2), @as(i64, 3), @as(i64, 4) },
            "error: bad argument #5 to 'move' (table expected, got number)",
        },
        .{ "table.sort", .{.{ .kv = .{} }}, "" },
        .{ "table.sort", .{ .{ .kv = .{.{ @as(i64, 1), @as(i64, 1) }} }, @as(i64, 3) }, "" },
        .{
            "table.sort",
            .{ .{ .kv = .{ .{ @as(i64, 1), @as(i64, 2) }, .{ @as(i64, 2), @as(i64, 1) } } }, @as(i64, 3) },
            "error: bad argument #2 to 'sort' (function expected, got number)",
        },
        .{
            "table.sort",
            .{.{ .kv = .{ .{ @as(i64, 1), @as(i64, 1) }, .{ @as(i64, 2), "x" } } }},
            "error: attempt to compare string with number",
        },
        .{
            "table.sort",
            .{.{ .kv = .{ .{ @as(i64, 1), .{ .kv = .{} } }, .{ @as(i64, 2), .{ .kv = .{} } } } }},
            "error: attempt to compare two table values",
        },
        .{ "table.sort", .{@as(i64, 1)}, "error: bad argument #1 to 'sort' (table expected, got number)" },
        .{ "table.sort", .{"x"}, "error: bad argument #1 to 'sort' (table expected, got string)" },
    });
}

/// `n` pseudo-random integers in [0, 1000), the same sequence as the Lua
/// generator the expected values came from.
fn lcgTable(state: *State, n: usize, seed: i64) !*Table {
    const t = try state.newTable(@intCast(n), 0);
    var x = seed;
    for (1..n + 1) |i| {
        x = @mod(x * 1103515245 + 12345, 2147483648);
        try t.setInt(&state.heap, @intCast(i), .int(@mod(x, 1000)));
    }
    return t;
}

var comparisons: usize = 0;

fn countingLess(th: *Thread, base: u32) Error!u32 {
    comparisons += 1;
    th.push(.boolean(th.stack[base].asInt() < th.stack[base + 1].asInt()));
    return 1;
}

fn countingGreater(th: *Thread, base: u32) Error!u32 {
    comparisons += 1;
    th.push(.boolean(th.stack[base].asInt() > th.stack[base + 1].asInt()));
    return 1;
}

fn alwaysTrue(th: *Thread, base: u32) Error!u32 {
    _ = base;
    th.push(.true);
    return 1;
}

/// `__len` for a proxy whose `__index` is the table holding its elements.
fn proxyLen(th: *Thread, base: u32) Error!u32 {
    const mt = th.stack[base].asTable().metatable.?;
    const inner = mt.getStr(try th.state.newString("__index")).asTable();
    th.push(.int(@bitCast(inner.length())));
    return 1;
}

/// An empty table that reads, writes, and measures `inner` through
/// `__index`, `__newindex`, and `__len`.
fn proxyOf(state: *State, inner: *Table) !Value {
    const p = try state.newTable(0, 0);
    const mt = try state.newTable(0, 3);
    try auxlib.setField(state, mt, "__index", .table(inner));
    try auxlib.setField(state, mt, "__newindex", .table(inner));
    try auxlib.setField(state, mt, "__len", .native(&proxyLen));
    p.metatable = mt;
    return .table(p);
}

test "sort makes the reference's comparisons" {
    const state = try h.newState();
    defer state.destroy();
    try open(state);
    const sortf = try h.global(state, "table.sort");
    const cat = try h.global(state, "table.concat");
    const comma = try h.str(state, ",");

    var t = try lcgTable(state, 200, 7);
    comparisons = 0;
    _ = try h.ok(state, sortf, &.{ .table(t), .native(&countingLess) });
    try testing.expectEqual(@as(usize, 1644), comparisons);
    try testing.expectEqual(@as(i64, 3), t.getInt(1).asInt());
    try testing.expectEqual(@as(i64, 489), t.getInt(100).asInt());
    try testing.expectEqual(@as(i64, 991), t.getInt(200).asInt());

    t = try lcgTable(state, 200, 7);
    comparisons = 0;
    _ = try h.ok(state, sortf, &.{ .table(t), .native(&countingGreater) });
    try testing.expectEqual(@as(usize, 1591), comparisons);
    try testing.expectEqual(@as(i64, 991), t.getInt(1).asInt());
    try testing.expectEqual(@as(i64, 501), t.getInt(100).asInt());
    try testing.expectEqual(@as(i64, 3), t.getInt(200).asInt());

    const strs = try h.vals(state, .{.{ .kv = .{ .{ 1, "b" }, .{ 2, "a" }, .{ 3, "d" }, .{ 4, "c" } } }});
    const st = strs[0];
    _ = try h.ok(state, sortf, &.{st});
    try h.expectShow(state, "a,b,c,d", cat, &.{ st, comma });

    const five = (try h.vals(state, .{.{ .kv = .{ .{ 1, 1 }, .{ 2, 2 }, .{ 3, 3 }, .{ 4, 4 }, .{ 5, 5 } } }}))[0];
    try h.expectShow(state, "error: invalid order function for sorting", sortf, &.{ five, .native(&alwaysTrue) });
    try h.expectShow(
        state,
        "error: invalid order function for sorting",
        sortf,
        &.{ .table(try lcgTable(state, 50, 3)), .native(&alwaysTrue) },
    );

    const inner = try lcgTable(state, 30, 11);
    _ = try h.ok(state, sortf, &.{try proxyOf(state, inner)});
    try h.expectShow(
        state,
        "37,168,174,183,195,236,283,293,358,472,495,505,513,575,586,652,662,690,701,707,736,777,800,866,8" ++
            "86,893,897,908,964,999",
        cat,
        &.{ .table(inner), comma },
    );
}

test "table functions go through __index, __newindex, and __len" {
    const state = try h.newState();
    defer state.destroy();
    try open(state);
    const cat = try h.global(state, "table.concat");
    const ins_fn = try h.global(state, "table.insert");
    const rem_fn = try h.global(state, "table.remove");
    const comma = try h.str(state, ",");
    const inner = (try h.vals(state, .{.{ .kv = .{ .{ 1, 1 }, .{ 2, 2 }, .{ 3, 3 } } }}))[0];
    const proxy = try proxyOf(state, inner.asTable());
    try state.globals.setStr(&state.heap, try state.newString("proxy"), proxy);
    _ = try h.ok(state, ins_fn, &.{ proxy, .int(4) });
    _ = try h.ok(state, ins_fn, &.{ proxy, .int(1), .int(0) });
    try h.expectShow(state, "0,1,2,3,4", cat, &.{ inner, comma });
    try h.expectShow(state, "0,1,2,3,4", cat, &.{ proxy, comma });
    try testing.expectEqual(@as(u64, 0), proxy.asTable().length());
    try h.expectShow(state, "4", rem_fn, &.{proxy});
    try h.expectShow(state, "0", rem_fn, &.{ proxy, .int(1) });
    try h.expectShow(state, "1,2,3", cat, &.{ inner, comma });
    try h.expectShow(state, "1\t2\t3", try h.global(state, "table.unpack"), &.{proxy});
    _ = try h.ok(state, try h.global(state, "table.move"), &.{ proxy, .int(1), .int(3), .int(2) });
    try h.expectShow(state, "1,1,2,3", cat, &.{ inner, comma });
}

test "insert, mov_fn, and pack place elements as the reference does" {
    const state = try h.newState();
    defer state.destroy();
    try open(state);
    const cat = try h.global(state, "table.concat");
    const mov_fn = try h.global(state, "table.move");
    const comma = try h.str(state, ",");
    const ins = (try h.vals(state, .{.{ .kv = .{ .{ 1, 1 }, .{ 2, 2 }, .{ 3, 3 } } }}))[0];
    _ = try h.ok(state, try h.global(state, "table.insert"), &.{ ins, .int(2), .int(9) });
    try h.expectShow(state, "1,9,2,3", cat, &.{ ins, comma });
    const five = .{.{ .kv = .{ .{ 1, 1 }, .{ 2, 2 }, .{ 3, 3 }, .{ 4, 4 }, .{ 5, 5 } } }};
    const m1 = (try h.vals(state, five))[0];
    _ = try h.ok(state, mov_fn, &.{ m1, .int(1), .int(3), .int(2) });
    try h.expectShow(state, "1,1,2,3,5", cat, &.{ m1, comma });
    const m2 = (try h.vals(state, five))[0];
    _ = try h.ok(state, mov_fn, &.{ m2, .int(2), .int(5), .int(1) });
    try h.expectShow(state, "2,3,4,5,5", cat, &.{ m2, comma });
    const src = (try h.vals(state, .{.{ .kv = .{ .{ 1, 1 }, .{ 2, 2 }, .{ 3, 3 } } }}))[0];
    const dst = try state.newTable(0, 0);
    const r = try h.ok(state, mov_fn, &.{ src, .int(1), .int(3), .int(2), .table(dst) });
    try testing.expect(r[0].asTable() == dst);
    try testing.expect(dst.getInt(1).isNil());
    try testing.expectEqual(@as(i64, 3), dst.getInt(4).asInt());
    const p = (try h.ok(state, try h.global(state, "table.pack"), &.{ .int(1), .nil, .int(3) }))[0].asTable();
    try testing.expectEqual(@as(i64, 3), p.getStr(try state.newString("n")).asInt());
    try testing.expectEqual(@as(i64, 1), p.getInt(1).asInt());
    try testing.expect(p.getInt(2).isNil());
    try testing.expectEqual(@as(i64, 3), p.getInt(3).asInt());
}

fn collectingLess(th: *Thread, base: u32) Error!u32 {
    th.state.collect();
    const a = th.stack[base].asString().bytes();
    const b = th.stack[base + 1].asString().bytes();
    th.push(.boolean(std.mem.order(u8, a, b) == .lt));
    return 1;
}

test "sort keeps the values it holds across collections" {
    const state = try h.newState();
    defer state.destroy();
    try open(state);
    // Long strings referenced only by the table and the sort's stack slots.
    const t = try state.newTable(0, 0);
    const n = 40;
    for (0..n) |i| {
        var buf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(
            &buf,
            "a long string, longer than forty bytes: {d:0>4}",
            .{(i * 17) % n},
        ) catch unreachable;
        try t.setInt(&state.heap, @intCast(i + 1), try h.str(state, s));
    }
    _ = try h.ok(state, try h.global(state, "table.sort"), &.{ .table(t), .native(&collectingLess) });
    for (0..n) |i| {
        var buf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "a long string, longer than forty bytes: {d:0>4}", .{i}) catch unreachable;
        try testing.expectEqualStrings(s, t.getInt(@intCast(i + 1)).asString().bytes());
    }
}

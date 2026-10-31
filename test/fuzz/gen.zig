//! Grammar-aware generation of Lua 5.5 programs for the fuzzers.
//!
//! `Gen.program` writes a complete chunk from a seed. In `.diff` mode the
//! program is deterministic, so its output can be compared with the
//! reference `lua`: no addresses in comparisons or sorts, `pairs` only
//! over keys collected and sorted, a fixed `math.randomseed`, nothing
//! from `os` or `io` but `io.write`. Risky operations run inside `pcall`
//! so one error does not end the run, but the error messages, with their
//! variable names, are printed and compared. In `.wild` mode the
//! generator also produces syntax the run does not need to be
//! deterministic for: deep nesting, many locals and upvalues, `global`
//! declarations, `goto`, long strings and odd numerals, for the parser,
//! the compiler, and `just bytecode`'s listing comparison.

const std = @import("std");

const Gen = @This();

pub const Mode = enum { diff, wild };

const Kind = enum { int, flt, str, tbl, fun, bool, nil, any };

const Local = struct {
    id: u32,
    kind: Kind,
    constant: bool,
};

rng: std.Random,
out: *std.ArrayList(u8),
gpa: std.mem.Allocator,
mode: Mode,
locals: std.ArrayList(Local) = .empty,
/// Statements still to write in the whole program; bounds its size.
budget: u32,
depth: u32 = 0,
edepth: u32 = 0,
loops: u32 = 0,
next_id: u32 = 1,
/// Locals declared in the innermost function, to stay under the 200
/// limit (`.wild` mode crosses it on purpose, rarely).
fn_locals: u32 = 0,
fn_base: usize = 0,
vararg: bool = true,

pub const Error = std.mem.Allocator.Error;

/// Writes one program for `seed` to `out`.
pub fn program(gpa: std.mem.Allocator, out: *std.ArrayList(u8), seed: u64, mode: Mode) Error!void {
    var prng: std.Random.DefaultPrng = .init(seed);
    var g: Gen = .{
        .rng = prng.random(),
        .out = out,
        .gpa = gpa,
        .mode = mode,
        .budget = 20 + prng.random().uintLessThan(u32, 120),
    };
    defer g.locals.deinit(gpa);
    try g.prelude();
    while (g.budget > 0) try g.stmt();
    if (g.chance(8)) {
        // An error that reaches the top: the standalone lua's message and
        // traceback on stderr, and its exit status.
        try g.w("error(");
        try g.anyExpr();
        try g.w(")\n");
    }
}

fn chance(g: *Gen, n: u32) bool {
    return g.rng.uintLessThan(u32, n) == 0;
}

fn below(g: *Gen, n: u32) u32 {
    return g.rng.uintLessThan(u32, n);
}

fn pick(g: *Gen, comptime T: type, items: []const T) T {
    return items[g.rng.uintLessThan(usize, items.len)];
}

fn w(g: *Gen, s: []const u8) Error!void {
    try g.out.appendSlice(g.gpa, s);
}

fn print(g: *Gen, comptime fmt: []const u8, args: anytype) Error!void {
    try g.out.print(g.gpa, fmt, args);
}

fn indent(g: *Gen) Error!void {
    var i: u32 = 0;
    while (i < g.depth) : (i += 1) try g.w("  ");
}

fn prelude(g: *Gen) Error!void {
    try g.w("math.randomseed(42)\n");
    // A deterministic `pairs`: keys sorted by type, then value.
    try g.w(
        \\local function spairs(t)
        \\  local ks = {}
        \\  for k in next, t do ks[#ks + 1] = k end
        \\  table.sort(ks, function(a, b)
        \\    local ta, tb = type(a), type(b)
        \\    if ta ~= tb then return ta < tb end
        \\    if ta == "number" or ta == "string" then return a < b end
        \\    if ta == "boolean" then return (not a) and b end
        \\    return false
        \\  end)
        \\  local i = 0
        \\  return function() i = i + 1 local k = ks[i] if k ~= nil then return k, t[k] end end
        \\end
        \\-- The first line of an error: the standalone lua's message handler
        \\-- appends a traceback where ours keeps it apart (see the README).
        \\local function first(e) return (string.match(tostring(e), "^[^\n]*")) end
        \\local function show(...)
        \\  local n = select('#', ...)
        \\  local parts = {}
        \\  for i = 1, n do
        \\    local v = select(i, ...)
        \\    local tv = type(v)
        \\    if tv == "table" or tv == "function" or tv == "thread" or tv == "userdata" then
        \\      parts[i] = tv
        \\    else
        \\      parts[i] = tostring(v)
        \\    end
        \\  end
        \\  print(n, table.concat(parts, " "))
        \\end
        \\
    );
}

fn newLocal(g: *Gen, kind: Kind, constant: bool) Error!u32 {
    const id = g.reserve();
    try g.addLocal(id, kind, constant);
    return id;
}

/// A fresh name, brought into scope later with `addLocal`, after the
/// expressions that initialize it.
fn reserve(g: *Gen) u32 {
    const id = g.next_id;
    g.next_id += 1;
    return id;
}

fn addLocal(g: *Gen, id: u32, kind: Kind, constant: bool) Error!void {
    try g.locals.append(g.gpa, .{ .id = id, .kind = kind, .constant = constant });
    g.fn_locals += 1;
}

/// A visible local of `kind`, or null.
fn findLocal(g: *Gen, kind: Kind, assignable: bool) ?Local {
    const items = g.locals.items;
    if (items.len == 0) return null;
    // Try a few random positions, then scan from a random start.
    const start = g.rng.uintLessThan(usize, items.len);
    var i: usize = 0;
    while (i < items.len) : (i += 1) {
        const l = items[(start + i) % items.len];
        if (assignable and l.constant) continue;
        if (kind == .any or l.kind == kind) return l;
    }
    return null;
}

fn canStmt(g: *Gen) bool {
    return g.budget > 0;
}

fn block(g: *Gen, max: u32) Error!void {
    const mark = g.locals.items.len;
    const saved = g.fn_locals;
    g.depth += 1;
    var n = 1 + g.below(max);
    while (n > 0 and g.budget > 0) : (n -= 1) try g.stmt();
    g.depth -= 1;
    g.locals.shrinkRetainingCapacity(mark);
    g.fn_locals = saved;
}

fn stmt(g: *Gen) Error!void {
    if (g.budget == 0) return;
    g.budget -= 1;
    try g.indent();
    const deep = g.depth >= 5;
    const choice = g.below(if (deep) 8 else 30);
    switch (choice) {
        0, 1 => try g.localDecl(),
        2, 3 => try g.assign(),
        4, 5, 6 => try g.printStmt(),
        7 => try g.risky(),
        8, 9 => try g.ifStmt(),
        10, 11 => try g.numericFor(),
        12 => try g.genericFor(),
        13 => try g.whileStmt(),
        14 => try g.repeatStmt(),
        15, 16 => try g.localFunction(),
        17 => try g.metatableStmt(),
        18 => try g.coroutineStmt(),
        19 => try g.gotoStmt(),
        20 => try g.closeStmt(),
        21 => try g.loadStmt(),
        22 => try g.tableStmt(),
        23 => try g.stringStmt(),
        24 => try g.numberStmt(),
        25 => try g.doStmt(),
        26 => try g.recursion(),
        27 => if (g.mode == .wild) try g.wildStmt() else try g.printStmt(),
        28 => try g.varargStmt(),
        else => try g.risky(),
    }
}

fn localDecl(g: *Gen) Error!void {
    if (g.fn_locals > 150 and g.mode == .diff) return g.printStmt();
    const kind = g.pick(Kind, &.{ .int, .int, .flt, .str, .str, .tbl, .fun, .bool, .any });
    const constant = g.chance(6);
    // The new local is not in scope in its own initializer.
    const id = g.reserve();
    try g.print("local l{d:0>5}", .{id % 100000});
    if (constant) try g.w(" <const>");
    try g.w(" = ");
    try g.expr(kind);
    try g.w("\n");
    try g.addLocal(id, kind, constant);
}

fn localName(g: *Gen, l: Local) Error!void {
    try g.print("l{d:0>5}", .{l.id % 100000});
}

fn assign(g: *Gen) Error!void {
    const target = g.findLocal(.any, true) orelse return g.localDecl();
    switch (g.below(4)) {
        0 => if (target.kind == .tbl) {
            // A field store.
            try g.localName(target);
            if (g.chance(4)) {
                try g.w("[#");
                try g.localName(target);
                try g.w(" + 1]");
            } else try g.w(g.pick([]const u8, &.{ ".a", ".b", ".n", "[1]", "[2]", ".x" }));
            try g.w(" = ");
            try g.anyExpr();
            try g.w("\n");
            return;
        },
        1 => {
            // A multiple assignment.
            const other = g.findLocal(.any, true) orelse target;
            try g.localName(target);
            try g.w(", ");
            try g.localName(other);
            try g.w(" = ");
            try g.boundedExpr(target.kind);
            try g.w(", ");
            try g.boundedExpr(other.kind);
            try g.w("\n");
            return;
        },
        else => {},
    }
    try g.localName(target);
    try g.w(" = ");
    try g.boundedExpr(target.kind);
    try g.w("\n");
}

/// An expression of `kind` whose size cannot grow without bound when it
/// is assigned back to a variable in a loop.
fn boundedExpr(g: *Gen, kind: Kind) Error!void {
    switch (kind) {
        .str => {
            try g.w("string.sub(");
            try g.expr(.str);
            try g.w(", 1, 40)");
        },
        else => try g.expr(kind),
    }
}

fn printStmt(g: *Gen) Error!void {
    try g.w(if (g.chance(2)) "print(" else "show(");
    const n = g.below(4);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        if (i > 0) try g.w(", ");
        try g.printable();
    }
    try g.w(")\n");
}

/// An expression whose printed form is deterministic.
fn printable(g: *Gen) Error!void {
    const kind = g.pick(Kind, &.{ .int, .int, .flt, .str, .str, .bool, .nil, .any });
    if (kind == .any) {
        try g.w("type(");
        try g.anyExpr();
        try g.w(")");
        return;
    }
    try g.expr(kind);
}

fn anyExpr(g: *Gen) Error!void {
    try g.expr(g.pick(Kind, &.{ .int, .flt, .str, .tbl, .fun, .bool, .nil, .any }));
}

fn expr(g: *Gen, kind: Kind) Error!void {
    g.edepth += 1;
    defer g.edepth -= 1;
    const leaf = g.edepth > 4 or g.chance(3);
    // A local of the kind, often.
    if (g.chance(3)) {
        if (g.findLocal(kind, false)) |l| return g.localName(l);
    }
    switch (kind) {
        .int => try g.intExpr(leaf),
        .flt => try g.fltExpr(leaf),
        .str => try g.strExpr(leaf),
        .tbl => try g.tblExpr(leaf),
        .fun => try g.funExpr(leaf),
        .bool => try g.boolExpr(leaf),
        .nil => try g.w(g.pick([]const u8, &.{ "nil", "(nil)", "({})[1]", "rawget({}, 1)", "select(2, 1)" })),
        .any => try g.expr(g.pick(Kind, &.{ .int, .flt, .str, .tbl, .bool, .nil })),
    }
}

fn intLiteral(g: *Gen) Error!void {
    switch (g.below(10)) {
        0 => try g.w(g.pick([]const u8, &.{
            "math.maxinteger",      "math.mininteger", "0x7fffffffffffffff", "0xffffffffffffffff",
            "-9223372036854775807", "0x10",            "0xA",                "1 << 62",
            "-1",                   "0",
        })),
        1, 2 => try g.print("{d}", .{@as(i64, g.rng.int(i32))}),
        else => try g.print("{d}", .{g.below(20)}),
    }
}

fn intExpr(g: *Gen, leaf: bool) Error!void {
    if (leaf) return g.intLiteral();
    switch (g.below(16)) {
        0, 1, 2 => {
            try g.w("(");
            try g.expr(.int);
            try g.w(g.pick([]const u8, &.{ " + ", " - ", " * ", " & ", " | ", " ~ ", " << ", " >> " }));
            try g.expr(.int);
            try g.w(")");
        },
        3 => {
            // Floor division and modulo by a nonzero constant.
            try g.w("(");
            try g.expr(.int);
            try g.w(g.pick([]const u8, &.{ " // ", " % " }));
            try g.print("{d}", .{@as(i64, g.below(9)) - 4 + @as(i64, if (g.chance(2)) 5 else -5)});
            try g.w(")");
        },
        4 => {
            try g.w("#");
            try g.expr(if (g.chance(2)) .str else .tbl);
        },
        5 => {
            try g.w("(math.tointeger(math.floor(");
            try g.expr(.flt);
            try g.w(" % 1e9)) or 0)");
        },
        6 => {
            try g.w("(-");
            try g.expr(.int);
            try g.w(")");
        },
        7 => {
            try g.w("(~");
            try g.expr(.int);
            try g.w(")");
        },
        8 => {
            try g.w("(");
            try g.expr(.bool);
            try g.w(" and ");
            try g.expr(.int);
            try g.w(" or ");
            try g.expr(.int);
            try g.w(")");
        },
        9 => {
            try g.w("string.byte(");
            try g.expr(.str);
            try g.w(", 1) or 0");
        },
        10 => {
            try g.w("math.max(");
            try g.expr(.int);
            try g.w(", ");
            try g.expr(.int);
            try g.w(")");
        },
        11 => try g.w(if (g.vararg) "select('#', ...)" else "0"),
        12 => {
            try g.w("(math.tointeger(");
            try g.expr(.flt);
            try g.w(") or 7)");
        },
        13 => {
            try g.w("math.random(");
            try g.print("{d}", .{1 + g.below(100)});
            try g.w(")");
        },
        14 => {
            try g.w("utf8.len(");
            try g.expr(.str);
            try g.w(") or -1");
        },
        else => try g.intLiteral(),
    }
}

fn fltLiteral(g: *Gen) Error!void {
    try g.w(g.pick([]const u8, &.{
        "1.5",   "0.1",  "-0.0",      "1e300", "1e-310", "2^53",  "3.0",   "1/0",
        "-1/0",  "0.5",  "123.456",   "1e15",  "2^63",   "-2^63", "0x1p4", "0x.8",
        "1e100", "7.25", "(0.1+0.2)", "1e-5",  "2.5e10", "100.0",
    }));
}

fn fltExpr(g: *Gen, leaf: bool) Error!void {
    if (leaf) return g.fltLiteral();
    switch (g.below(10)) {
        0, 1 => {
            try g.w("(");
            try g.expr(.flt);
            try g.w(g.pick([]const u8, &.{ " + ", " - ", " * ", " / " }));
            try g.expr(if (g.chance(2)) .flt else .int);
            try g.w(")");
        },
        2 => {
            try g.w("(");
            try g.expr(.int);
            try g.w(" / ");
            try g.expr(.int);
            try g.w(")");
        },
        3 => {
            try g.w("(");
            try g.expr(.int);
            try g.w(" ^ ");
            try g.print("{d}", .{g.below(4)});
            try g.w(")");
        },
        4 => {
            const f = g.below(3);
            try g.w(([_][]const u8{ "math.sqrt(math.abs(", "math.exp(math.fmod(", "math.log(1 + math.abs(" })[f]);
            try g.expr(.flt);
            try g.w(if (f == 1) ", 10))" else "))");
        },
        5 => {
            try g.w("(");
            try g.expr(.flt);
            try g.w(" // ");
            try g.fltLiteral();
            try g.w(")");
        },
        6 => try g.w("math.pi"),
        7 => {
            try g.w("(");
            try g.expr(.int);
            try g.w(" + 0.0)");
        },
        8 => try g.w("math.random()"),
        else => try g.fltLiteral(),
    }
}

fn strLiteral(g: *Gen) Error!void {
    try g.w(g.pick([]const u8, &.{
        "\"\"",          "\"a\"",       "'hello'",              "\"10\"",           "\"0x1F\"",     "\" 3.5 \"",
        "\"abc\\ndef\"", "'\\65\\066'", "\"\\u{48}\\u{20AC}\"", "[[long\nstring]]", "[==[a]]b]==]", "\"\\x41\\z   B\"",
        "'%d'",          "\"x y z\"",   "\"1e2\"",              "'nan'",            "\"\\0nul\"",   "'k=v, k2=v2'",
    }));
}

fn strExpr(g: *Gen, leaf: bool) Error!void {
    if (leaf) return g.strLiteral();
    switch (g.below(16)) {
        0, 1 => {
            try g.w("(");
            try g.expr(.str);
            try g.w(" .. ");
            try g.expr(g.pick(Kind, &.{ .str, .int, .flt }));
            try g.w(")");
        },
        2 => {
            try g.w("tostring(");
            try g.expr(g.pick(Kind, &.{ .int, .flt, .bool, .nil }));
            try g.w(")");
        },
        3 => {
            try g.w("string.rep(");
            try g.expr(.str);
            try g.print(", {d}", .{g.below(4)});
            if (g.chance(2)) try g.w(", '-'");
            try g.w(")");
        },
        4 => {
            try g.w("string.sub(");
            try g.expr(.str);
            try g.w(", ");
            try g.expr(.int);
            if (g.chance(2)) {
                try g.w(", ");
                try g.expr(.int);
            }
            try g.w(")");
        },
        5 => {
            try g.w(g.pick([]const u8, &.{ "string.upper(", "string.lower(", "string.reverse(" }));
            try g.expr(.str);
            try g.w(")");
        },
        6 => try g.formatExpr(),
        7 => {
            try g.w("string.char(");
            try g.print("{d}", .{32 + g.below(95)});
            if (g.chance(2)) try g.print(", {d}", .{32 + g.below(95)});
            try g.w(")");
        },
        8 => {
            try g.w("(string.gsub(");
            try g.expr(.str);
            try g.w(", ");
            try g.w(g.pick([]const u8, &.{ "'%a'", "'(%w+)'", "'%s+'", "'l+'", "'.'", "'^a'", "'%d+'", "'[aeiou]'", "'(.)(.)'", "'%f[%w]%w+'" }));
            try g.w(", ");
            try g.w(g.pick([]const u8, &.{ "'<%0>'", "'%1%1'", "''", "{a = 'A', l = 1}", "function(c) return c:upper() end", "'%%'", "function() return nil end" }));
            if (g.chance(3)) try g.print(", {d}", .{g.below(4)});
            try g.w("))");
        },
        9 => {
            try g.w("(string.match(");
            try g.expr(.str);
            try g.w(", ");
            try g.w(g.pick([]const u8, &.{ "'%a+'", "'(%d+)'", "'^(.-)%s'", "'()'", "'%b()'", "'[%w_]+'", "'.$'" }));
            try g.w(") or 'none')");
        },
        10 => {
            try g.w("table.concat({");
            try g.expr(.str);
            try g.w(", ");
            try g.expr(.int);
            try g.w("}, ");
            try g.strLiteral();
            try g.w(")");
        },
        11 => {
            try g.w("utf8.char(");
            try g.print("{d}", .{g.below(0x11000)});
            try g.w(")");
        },
        12 => {
            try g.w("string.format('%q', ");
            try g.expr(g.pick(Kind, &.{ .str, .int, .flt }));
            try g.w(")");
        },
        13 => {
            try g.w("type(");
            try g.anyExpr();
            try g.w(")");
        },
        14 => {
            try g.w("math.type(");
            try g.expr(g.pick(Kind, &.{ .int, .flt, .str }));
            try g.w(") or 'no'");
        },
        else => try g.strLiteral(),
    }
}

fn formatExpr(g: *Gen) Error!void {
    switch (g.below(6)) {
        0 => {
            try g.w("string.format('%d|%5d|%-5d|%x|%X|%o', ");
            for (0..6) |i| {
                if (i > 0) try g.w(", ");
                try g.expr(.int);
            }
            try g.w(")");
        },
        1 => {
            try g.w(g.pick([]const u8, &.{ "string.format('%g', ", "string.format('%.3f', ", "string.format('%10.2e', ", "string.format('%.14g', ", "string.format('%5.1f', ", "string.format('%a', " }));
            try g.expr(.flt);
            try g.w(")");
        },
        2 => {
            try g.w("string.format('%s and %s', ");
            try g.expr(.str);
            try g.w(", ");
            try g.expr(g.pick(Kind, &.{ .int, .flt, .bool, .nil }));
            try g.w(")");
        },
        3 => {
            try g.w("string.format('%-8s|%8s|%.2s', ");
            try g.expr(.str);
            try g.w(", ");
            try g.expr(.str);
            try g.w(", ");
            try g.expr(.str);
            try g.w(")");
        },
        4 => {
            try g.w("string.format('%c%c', ");
            try g.print("{d}, {d}", .{ 48 + g.below(70), 48 + g.below(70) });
            try g.w(")");
        },
        else => {
            try g.w("string.format('%i %% %d', ");
            try g.expr(.int);
            try g.w(", ");
            try g.expr(.int);
            try g.w(")");
        },
    }
}

fn tblExpr(g: *Gen, leaf: bool) Error!void {
    if (leaf) {
        try g.w(g.pick([]const u8, &.{ "{}", "{1, 2, 3}", "{a = 1}", "{'x', 'y', n = 2}", "{[1] = 'a', [3] = 'c'}" }));
        return;
    }
    switch (g.below(6)) {
        0 => {
            try g.w("setmetatable({}, {__index = ");
            try g.tblExpr(true);
            try g.w("})");
        },
        1 => {
            try g.w("table.pack(");
            try g.expr(.int);
            try g.w(", ");
            try g.expr(.str);
            try g.w(")");
        },
        2 => try g.w(if (g.vararg) "{...}" else "{}"),
        else => {
            try g.w("{");
            const n = g.below(6);
            var i: u32 = 0;
            while (i < n) : (i += 1) {
                if (i > 0) try g.w(g.pick([]const u8, &.{ ", ", "; " }));
                switch (g.below(4)) {
                    0 => {
                        try g.w(g.pick([]const u8, &.{ "a", "b", "n", "x", "name" }));
                        try g.w(" = ");
                        try g.anyExpr();
                    },
                    1 => {
                        try g.w("[");
                        try g.expr(g.pick(Kind, &.{ .int, .str, .flt, .bool }));
                        try g.w("] = ");
                        try g.anyExpr();
                    },
                    else => try g.anyExpr(),
                }
            }
            try g.w("}");
        },
    }
}

fn funExpr(g: *Gen, leaf: bool) Error!void {
    if (leaf or g.depth > 4) {
        try g.w(g.pick([]const u8, &.{ "print", "tostring", "function(x) return x end", "function(...) return select('#', ...) end", "math.abs", "string.len", "type" }));
        return;
    }
    try g.funBody(false);
}

/// `function (params) body end`, with its own locals.
fn funBody(g: *Gen, named_vararg: bool) Error!void {
    try g.w("function(");
    const mark = g.locals.items.len;
    const saved_fn = g.fn_locals;
    const saved_va = g.vararg;
    const saved_loops = g.loops;
    g.fn_locals = 0;
    g.loops = 0;
    const nparams = g.below(4);
    var i: u32 = 0;
    while (i < nparams) : (i += 1) {
        if (i > 0) try g.w(", ");
        const id = try g.newLocal(.any, false);
        try g.print("l{d:0>5}", .{id % 100000});
    }
    g.vararg = g.chance(2) or named_vararg;
    if (g.vararg) {
        if (nparams > 0) try g.w(", ");
        if (named_vararg) {
            const id = try g.newLocal(.tbl, false);
            try g.print("...l{d:0>5}", .{id % 100000});
        } else try g.w("...");
    }
    try g.w(")\n");
    try g.block(4);
    try g.indent();
    try g.w("  return ");
    try g.anyExpr();
    if (g.chance(3)) {
        try g.w(", ");
        try g.anyExpr();
    }
    try g.w("\n");
    try g.indent();
    try g.w("end");
    g.locals.shrinkRetainingCapacity(mark);
    g.fn_locals = saved_fn;
    g.vararg = saved_va;
    g.loops = saved_loops;
}

fn boolExpr(g: *Gen, leaf: bool) Error!void {
    if (leaf) return g.w(g.pick([]const u8, &.{ "true", "false", "not nil", "1 == 1.0", "'a' < 'b'" }));
    switch (g.below(6)) {
        0, 1 => {
            const k = g.pick(Kind, &.{ .int, .flt, .str });
            try g.w("(");
            try g.expr(k);
            try g.w(g.pick([]const u8, &.{ " < ", " <= ", " > ", " >= ", " == ", " ~= " }));
            try g.expr(if (k == .str) .str else g.pick(Kind, &.{ .int, .flt }));
            try g.w(")");
        },
        2 => {
            try g.w("(not ");
            try g.anyExpr();
            try g.w(")");
        },
        3 => {
            try g.w("(");
            try g.expr(.bool);
            try g.w(g.pick([]const u8, &.{ " and ", " or " }));
            try g.expr(.bool);
            try g.w(")");
        },
        4 => {
            try g.w("(");
            try g.anyExpr();
            try g.w(" == ");
            try g.anyExpr();
            try g.w(")");
        },
        else => {
            try g.w("math.ult(");
            try g.expr(.int);
            try g.w(", ");
            try g.expr(.int);
            try g.w(")");
        },
    }
}

/// An operation that may raise, inside `pcall`, with its result printed.
fn risky(g: *Gen) Error!void {
    const saved = g.vararg;
    g.vararg = false;
    defer g.vararg = saved;
    try g.w("show(pcall(function() ");
    switch (g.below(24)) {
        0 => {
            try g.w("return ");
            try g.anyExpr();
            try g.w(g.pick([]const u8, &.{ " + ", " .. ", " < ", " // ", " % ", " & ", " ^ ", " <= " }));
            try g.anyExpr();
        },
        1 => {
            try g.w("return ");
            try g.anyExpr();
            try g.w(g.pick([]const u8, &.{ ".x", "[1]", ".a.b", ":m()", "()" }));
        },
        2 => {
            try g.w("return ");
            try g.expr(.int);
            try g.w(g.pick([]const u8, &.{ " // 0", " % 0", " // 0.0", " % (1 - 1)" }));
        },
        3 => {
            try g.w("local t = ");
            try g.anyExpr();
            try g.w(" t[");
            try g.anyExpr();
            try g.w("] = 1 return t");
        },
        4 => try g.w(g.pick([]const u8, &.{
            "return string.rep('x', -1)",                                                    "return string.rep('x', 1 << 40)",       "return ('x'):rep(1e10)",
            "return string.char(256)",                                                       "return setmetatable(1, {})",            "return tostring()",
            "return select(0)",                                                              "return string.format('%d', 1.5)",       "return utf8.char(-1)",
            "return table.concat({{}})",                                                     "return ipairs()",                       "return math.floor('a')",
            "return ('x'):bad()",                                                            "return #5",                             "return -{}",
            "return string.format('%5')",                                                    "return table.insert({}, 1, 2, 3)",      "return table.unpack({}, 1, 1e8)",
            "return math.random(0)",                                                         "return math.random(3, 1)",              "return string.byte('abc', 0, -1)",
            "return tonumber('10', 99)",                                                     "return tonumber(10, 16)",               "return string.format('%q', {})",
            "return next({}, 'nope')",                                                       "return rawset({}, nil, 1)",             "return setmetatable({}, 1)",
            "return coroutine.resume(1)",                                                    "return string.pack('i17', 1)",          "return utf8.codepoint('\\xff')",
            "return load(1)",                                                                "return error()",                        "return error(nil)",
            "return error(setmetatable({}, {__tostring = function() return 'custom' end}))", "return math.tointeger('8')",            "return 1 < 'x'",
            "return {} < {}",                                                                "return 2^63 | 0",                       "return '1.5' | 0",
            "return 'abc' + 1",                                                              "return math.huge // 1 | 0",             "return string.sub()",
            "return (nil)()",                                                                "local a <const> = 1; return a.b.c",     "return table.remove({}, 5)",
            "return table.move({1}, 1, 2, math.maxinteger)",                                 "for i = 1, 10, 0 do end",               "for i = 'a', 2 do end",
            "for i = 1, {} do end",                                                          "return string.pack('>i2', 70000)",      "return string.unpack('i4', 'ab')",
            "return utf8.offset('abc', 5)",                                                  "return select(-5, 1)",                  "return assert(false)",
            "return assert(nil, 'assert msg')",                                              "return assert(false, {})",              "return getmetatable('').__index.nope()",
            "return ('%d'):format('x')",                                                     "return string.gsub('x', '(', '')",      "return string.find('x', '[a')",
            "return string.match('x', '%')",                                                 "return string.gsub('abc', '%w', '%2')", "return string.rep('ab', 3, 1)",
            "return os.time({})",
        })),
        5 => {
            try g.w("error(");
            try g.anyExpr();
            if (g.chance(2)) try g.print(", {d}", .{g.below(3)});
            try g.w(")");
        },
        6 => {
            const l = g.findLocal(.any, false);
            try g.w("return ");
            if (l) |x| try g.localName(x) else try g.w("undefined_global");
            try g.w(g.pick([]const u8, &.{ ".field.sub", "()", " + {}", " .. {}", "[nil]", ":method()", " < {}" }));
        },
        7 => {
            try g.w("local up = ");
            try g.anyExpr();
            try g.w(" return (function() return up");
            try g.w(g.pick([]const u8, &.{ ".x.y", "()", " + nil", "[1][2]" }));
            try g.w(" end)()");
        },
        8 => {
            try g.w("return string.format(");
            try g.w(g.pick([]const u8, &.{ "'%d'", "'%s'", "'%x'", "'%5.2f'", "'%c'", "'%q'", "'%i'", "'%-3s|'" }));
            try g.w(", ");
            try g.anyExpr();
            try g.w(")");
        },
        9 => {
            try g.w("return math.tointeger(");
            try g.anyExpr();
            try g.w("), math.type(");
            try g.anyExpr();
            try g.w("), tonumber(");
            try g.anyExpr();
            try g.w(")");
        },
        10 => {
            try g.w("local t = {} for i = 1, 5 do t[i] = ");
            try g.anyExpr();
            try g.w(" end table.sort(t) return t[1], t[5]");
        },
        11 => {
            try g.w("return string.rep(");
            try g.anyExpr();
            try g.w(", 2)");
        },
        12 => try g.w("local t = setmetatable({}, {__index = function(t, k) return k * 2 end}) return t[21], t.x"),
        13 => try g.w("return coroutine.wrap(function() error('in coroutine') end)()"),
        14 => try g.w("local co = coroutine.create(function() coroutine.yield(1) error({}) end) return coroutine.resume(co), coroutine.resume(co), coroutine.resume(co)"),
        15 => {
            try g.w("return ");
            try g.anyExpr();
            try g.w(" .. ");
            try g.anyExpr();
        },
        16 => {
            try g.w("return #");
            try g.anyExpr();
        },
        17 => {
            try g.w("return -");
            try g.anyExpr();
        },
        18 => {
            try g.w("return string.byte(");
            try g.anyExpr();
            try g.w(", ");
            try g.anyExpr();
            try g.w(")");
        },
        19 => {
            try g.w("return math.max(");
            try g.anyExpr();
            try g.w(", ");
            try g.anyExpr();
            try g.w(")");
        },
        20 => {
            try g.w("return table.concat(");
            try g.tblExpr(false);
            try g.w(", ");
            try g.anyExpr();
            try g.w(")");
        },
        21 => try g.w("local a <close> = 42 return a"),
        22 => {
            // The loop's checks, then one pass: the bounds may be huge.
            try g.w("for i = ");
            try g.anyExpr();
            try g.w(", ");
            try g.anyExpr();
            try g.w(" do break end");
        },
        else => {
            try g.w("return xpcall(function() ");
            try g.w(g.pick([]const u8, &.{ "error('x')", "local x = nil; return x.y", "error({})", "return 1" }));
            try g.w(" end, function(m) return 'handled: ' .. tostring(m) end)");
        },
    }
    try g.w(" end))\n");
}

fn ifStmt(g: *Gen) Error!void {
    try g.w("if ");
    try g.expr(.bool);
    try g.w(" then\n");
    try g.block(3);
    var n = g.below(3);
    while (n > 0) : (n -= 1) {
        try g.indent();
        try g.w("elseif ");
        try g.expr(.bool);
        try g.w(" then\n");
        try g.block(2);
    }
    if (g.chance(2)) {
        try g.indent();
        try g.w("else\n");
        try g.block(2);
    }
    try g.indent();
    try g.w("end\n");
}

fn loopBody(g: *Gen) Error!void {
    g.loops += 1;
    defer g.loops -= 1;
    try g.block(3);
    if (g.chance(5)) {
        try g.indent();
        try g.w("  if ");
        try g.expr(.bool);
        try g.w(" then break end\n");
    }
}

fn numericFor(g: *Gen) Error!void {
    const mark = g.locals.items.len;
    try g.w("for ");
    const id = g.next_id;
    try g.print("l{d:0>5} = ", .{id % 100000});
    if (g.loops >= 2) {
        try g.w("1, 2");
    } else switch (g.below(8)) {
        0 => try g.w("math.maxinteger - 2, math.maxinteger"),
        1 => try g.w("math.mininteger, math.mininteger + 2"),
        2 => try g.w("1, 3, 0.5"),
        3 => try g.w("3, 1, -1"),
        4 => try g.w("1.0, 3"),
        5 => try g.w("0.1, 1, 0.3"),
        6 => try g.w("math.maxinteger - 1, math.maxinteger, 2"),
        else => try g.print("{d}, {d}", .{ @as(i32, @intCast(g.below(3))) - 1, g.below(8) }),
    }
    try g.w(" do\n");
    _ = try g.newLocal(.int, true);
    try g.loopBody();
    g.locals.shrinkRetainingCapacity(mark);
    try g.indent();
    try g.w("end\n");
}

fn genericFor(g: *Gen) Error!void {
    const mark = g.locals.items.len;
    const k = g.reserve();
    const v = g.reserve();
    try g.print("for l{d:0>5}, l{d:0>5} in ", .{ k % 100000, v % 100000 });
    switch (g.below(5)) {
        0 => {
            try g.w("utf8.codes(");
            try g.strExpr(true);
            try g.w(")");
        },
        1 => {
            try g.w("string.gmatch(");
            try g.strExpr(false);
            try g.w(", '(%a)(%a*)')");
        },
        2 => {
            // Raw `next` over a sequence: integer keys keep their order.
            try g.w("next, {");
            try g.expr(.int);
            try g.w(", ");
            try g.expr(.str);
            try g.w("}");
        },
        else => {
            try g.w(if (g.chance(2)) "ipairs(" else "spairs(");
            try g.tblExpr(false);
            try g.w(")");
        },
    }
    try g.w(" do\n");
    try g.addLocal(k, .any, true);
    try g.addLocal(v, .any, true);
    try g.loopBody();
    g.locals.shrinkRetainingCapacity(mark);
    try g.indent();
    try g.w("end\n");
}

fn whileStmt(g: *Gen) Error!void {
    const id = try g.newLocal(.int, false);
    try g.print("local l{d:0>5} = 0\n", .{id % 100000});
    try g.indent();
    try g.print("while l{d:0>5} < {d} do\n", .{ id % 100000, 1 + g.below(5) });
    try g.indent();
    try g.print("  l{d:0>5} = l{d:0>5} + 1\n", .{ id % 100000, id % 100000 });
    // The counter must not be reassigned by the body.
    g.locals.items[g.locals.items.len - 1].constant = true;
    try g.loopBody();
    try g.indent();
    try g.w("end\n");
}

fn repeatStmt(g: *Gen) Error!void {
    const id = try g.newLocal(.int, true);
    try g.print("local l{d:0>5} = 0\n", .{id % 100000});
    try g.indent();
    try g.w("repeat\n");
    try g.indent();
    try g.print("  l{d:0>5} = l{d:0>5} + 1\n", .{ id % 100000, id % 100000 });
    try g.loopBody();
    try g.indent();
    try g.print("until l{d:0>5} >= {d}", .{ id % 100000, 1 + g.below(4) });
    if (g.chance(3)) {
        try g.w(" or ");
        try g.expr(.bool);
    }
    try g.w("\n");
}

fn localFunction(g: *Gen) Error!void {
    const id = g.next_id;
    g.next_id += 1;
    try g.print("local l{d:0>5} = ", .{id % 100000});
    try g.funBody(g.chance(4));
    try g.w("\n");
    try g.locals.append(g.gpa, .{ .id = id, .kind = .fun, .constant = false });
    g.fn_locals += 1;
    // Call it.
    try g.indent();
    try g.print("show(pcall(l{d:0>5}", .{id % 100000});
    var n = g.below(4);
    while (n > 0) : (n -= 1) {
        try g.w(", ");
        try g.anyExpr();
    }
    try g.w("))\n");
}

fn metatableStmt(g: *Gen) Error!void {
    const id = g.reserve();
    const n = id % 100000;
    try g.print("local l{d:0>5} = setmetatable({{v = ", .{n});
    try g.expr(.int);
    try g.w("}, {\n");
    const events = [_][]const u8{
        "__add = function(a, b) return 'add' end",
        "__sub = function(a, b) return 2 end",
        "__mul = function(a, b) return type(a) .. type(b) end",
        "__div = function(a, b) return 0.5 end",
        "__mod = function(a, b) return 'mod' end",
        "__idiv = function(a, b) return -1 end",
        "__unm = function(a) return 'neg' end",
        "__band = function(a, b) return 'band' end",
        "__shl = function(a, b) return 'shl' end",
        "__bnot = function(a) return 'bnot' end",
        "__concat = function(a, b) return 'cat' end",
        "__len = function(a) return 99 end",
        "__eq = function(a, b) return true end",
        "__lt = function(a, b) return true end",
        "__le = function(a, b) return false end",
        "__call = function(self, ...) return select('#', ...) end",
        "__tostring = function(self) return 'OBJ' end",
        "__name = 'MyType'",
        "__index = function(t, k) return tostring(k) .. '!' end",
        "__index = {inherited = 'yes'}",
        "__newindex = function(t, k, v) rawset(t, k, v and 'set') end",
        "__close = function() print('closed') end",
        "__metatable = 'locked'",
    };
    var count = 1 + g.below(6);
    while (count > 0) : (count -= 1) {
        try g.indent();
        try g.w("  ");
        try g.w(g.pick([]const u8, &events));
        try g.w(",\n");
    }
    try g.indent();
    try g.w("})\n");
    try g.addLocal(id, .tbl, false);
    // Exercise it.
    const uses = [_][]const u8{
        "show(pcall(function() return @ + 1, 1 - @, @ * @, @ / 2, @ % 3, @ // 4 end))",
        "show(pcall(function() return -@, ~@, @ & 1, @ << 1, @ .. 'x', 'x' .. @ end))",
        "show(pcall(function() return #@, @ == {}, @ < @, @ <= @, @ > 1 end))",
        "show(pcall(function() return @(1, 2, 3) end))",
        "show(pcall(tostring, @))",
        "show(pcall(function() return @.missing, @.inherited, @[1] end))",
        "show(pcall(function() @.newkey = 5 return rawget(@, 'newkey') end))",
        "show(pcall(getmetatable, @))",
        "show(pcall(setmetatable, @, {}))",
        "show(pcall(function() local c <close> = @ end))",
        "show(pcall(function() return @.v.w end))",
        "show(pcall(string.rep, @, 2))",
        "show(pcall(ipairs, @))",
        "show(pcall(function() for i, v in ipairs(@) do if i > 5 then break end end return 'iter' end))",
    };
    var k = 1 + g.below(4);
    while (k > 0) : (k -= 1) {
        try g.indent();
        const u = g.pick([]const u8, &uses);
        var it = std.mem.splitScalar(u8, u, '@');
        var first = true;
        while (it.next()) |piece| {
            if (!first) try g.print("l{d:0>5}", .{n});
            first = false;
            try g.w(piece);
        }
        try g.w("\n");
    }
}

fn coroutineStmt(g: *Gen) Error!void {
    switch (g.below(5)) {
        0 => {
            try g.w("do\n");
            try g.indent();
            try g.w("  local co = coroutine.wrap(function(a)\n");
            try g.indent();
            try g.w("    local b = coroutine.yield(a + 1)\n");
            try g.indent();
            try g.w("    local c, d = coroutine.yield(b .. '!')\n");
            try g.indent();
            try g.w("    return c, d, coroutine.isyieldable()\n");
            try g.indent();
            try g.w("  end)\n");
            try g.indent();
            try g.w("  show(co(");
            try g.expr(.int);
            try g.w(")) show(co(");
            try g.expr(.str);
            try g.w(")) show(co(1, 2)) show(pcall(co))\n");
            try g.indent();
            try g.w("end\n");
        },
        1 => {
            try g.w("do\n");
            try g.indent();
            try g.w("  local co = coroutine.create(function(...)\n");
            g.depth += 1;
            const saved = g.vararg;
            g.vararg = true;
            try g.block(3);
            g.vararg = saved;
            g.depth -= 1;
            try g.indent();
            try g.w("    coroutine.yield(...)\n");
            try g.indent();
            try g.w("    return 'done'\n");
            try g.indent();
            try g.w("  end)\n");
            try g.indent();
            try g.w("  show(coroutine.resume(co, 1, 2)) show(coroutine.status(co)) show(coroutine.resume(co)) show(coroutine.resume(co)) show(coroutine.status(co))\n");
            try g.indent();
            try g.w("end\n");
        },
        2 => {
            try g.w("do\n");
            try g.indent();
            try g.w("  local co = coroutine.create(function() local x <close> = setmetatable({}, {__close = function(_, e) print('close', first(e)) end}) coroutine.yield(1) end)\n");
            try g.indent();
            try g.w("  show(coroutine.resume(co)) show(coroutine.close(co)) show(coroutine.status(co))\n");
            try g.indent();
            try g.w("end\n");
        },
        3 => {
            try g.w("do\n");
            try g.indent();
            try g.w("  local gen = coroutine.wrap(function() for i = 1, 3 do coroutine.yield(i, pcall(coroutine.yield, -i)) end end)\n");
            try g.indent();
            try g.w("  for i = 1, 6 do show(gen(i)) end\n");
            try g.indent();
            try g.w("end\n");
        },
        else => {
            try g.w("show(pcall(coroutine.wrap(function() ");
            try g.w(g.pick([]const u8, &.{ "return coroutine.running()", "return coroutine.status(coroutine.running())", "return table.sort({3, 1, 2}, function(a, b) coroutine.yield() return a < b end)", "return select('#', coroutine.yield())", "return string.gsub('ab', '.', function(c) return coroutine.yield(c) end)" }));
            try g.w(" end)))\n");
        },
    }
}

fn gotoStmt(g: *Gen) Error!void {
    const id = g.next_id;
    g.next_id += 1;
    const n = id % 100000;
    switch (g.below(3)) {
        0 => {
            try g.print("do local c{d} = 0 ::top{d}:: c{d} = c{d} + 1 if c{d} < 3 then goto top{d} end print('goto', c{d}) end\n", .{ n, n, n, n, n, n, n });
        },
        1 => {
            try g.print("for i{d} = 1, 4 do\n", .{n});
            try g.indent();
            try g.print("  if i{d} % 2 == 0 then goto continue{d} end\n", .{ n, n });
            try g.indent();
            try g.print("  print('odd', i{d})\n", .{n});
            try g.indent();
            try g.print("  ::continue{d}::\n", .{n});
            try g.indent();
            try g.w("end\n");
        },
        else => {
            try g.print("do goto skip{d} print('never') ::skip{d}:: end\n", .{ n, n });
        },
    }
}

fn closeStmt(g: *Gen) Error!void {
    try g.w("do\n");
    try g.indent();
    try g.w("  local a <close> = setmetatable({}, {__close = function(o, e) print('close a', first(e)) end})\n");
    try g.indent();
    try g.w("  local b <close> = ");
    try g.w(g.pick([]const u8, &.{ "nil", "false", "setmetatable({}, {__close = function() print('close b') end})" }));
    try g.w("\n");
    try g.block(2);
    if (g.chance(3)) {
        try g.indent();
        try g.w("  show(pcall(function() local c <close> = setmetatable({}, {__close = function(_, e) error('in close') end}) error('body') end))\n");
    }
    try g.indent();
    try g.w("end\n");
}

fn loadStmt(g: *Gen) Error!void {
    // Compile generated source at run time: the compiler's messages are
    // compared too.
    try g.w("show(load(");
    switch (g.below(3)) {
        0 => {
            try g.w("'return ' .. ");
            try g.expr(.str);
        },
        1 => {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(g.gpa);
            try tokenSoup(g, &buf);
            try writeLuaString(g, buf.items);
        },
        else => try g.w(g.pick([]const u8, &.{
            "'x = = 1'",                       "'return 1 +'",           "'local x <bad> = 1'",             "'goto nowhere'",
            "'::a:: ::a::'",                   "'break'",                "'local a <const> = 1; a = 2'",    "'for i = 1 do end'",
            "'return \"unfinished'",           "'return [[open'",        "'x = 0x'",                        "'return 1e'",
            "'return \\'\\\\q\\''",            "'f(\\n)'",               "'local function end'",            "'return ...'",
            "'function f() return ... end'",   "'return 3 .. 4'",        "'x = 1 y = 2 return x + y'",      "'return {...}'",
            "'global x; y = 1'",               "'return \\'\\\\300\\''", "'return \\'\\\\u{110000000}\\''", "'--[[ unclosed'",
            "'return 0x7fffffffffffffff + 1'", "'a.b:c\"d\"'",           "'return ~= 1'",                   "'(f)\\n(g)'",
        })),
    }
    if (g.chance(2)) try g.w(", '=gen'");
    try g.w("))\n");
}

/// A Lua string literal holding `bytes`.
fn writeLuaString(g: *Gen, bytes: []const u8) Error!void {
    try g.w("\"");
    for (bytes) |c| switch (c) {
        '"' => try g.w("\\\""),
        '\\' => try g.w("\\\\"),
        '\n' => try g.w("\\n"),
        32...33, 35...91, 93...126 => try g.out.append(g.gpa, c),
        else => try g.print("\\{d:0>3}", .{c}),
    };
    try g.w("\"");
}

const tokens = [_][]const u8{
    "local", "function", "end",    "if",     "then",  "else",    "elseif",  "while", "do",  "repeat",
    "until", "for",      "in",     "return", "break", "goto",    "and",     "or",    "not", "nil",
    "true",  "false",    "global", "x",      "y",     "f",       "t",       "...",   "=",   "==",
    "~=",    "<",        "<=",     ">",      ">=",    "+",       "-",       "*",     "/",   "//",
    "%",     "^",        "#",      "&",      "|",     "~",       "<<",      ">>",    "..",  "(",
    ")",     "{",        "}",      "[",      "]",     ";",       ":",       "::",    ",",   ".",
    "1",     "2.5",      "0x10",   "'s'",    "[[l]]", "<const>", "<close>", "*",     "\n",  "1e9",
};

pub const tokens_for_mutation = tokens;

/// A sequence of Lua tokens with little structure: mostly a syntax error.
pub fn tokenSoup(g: *Gen, buf: *std.ArrayList(u8)) Error!void {
    var n = 1 + g.below(20);
    while (n > 0) : (n -= 1) {
        try buf.appendSlice(g.gpa, g.pick([]const u8, &tokens));
        try buf.append(g.gpa, ' ');
    }
}

fn tableStmt(g: *Gen) Error!void {
    const id = g.reserve();
    const n = id % 100000;
    try g.print("local l{d:0>5} = {{", .{n});
    var k = g.below(8);
    while (k > 0) : (k -= 1) {
        try g.expr(g.pick(Kind, &.{ .int, .str, .flt }));
        try g.w(", ");
    }
    try g.w("}\n");
    try g.addLocal(id, .tbl, false);
    const ops = [_][]const u8{
        "table.insert(@, 'ins') table.insert(@, 1, 'first') show(#@, @[1], @[#@])",
        "show(table.remove(@), table.remove(@, 1), #@)",
        "show(table.concat(@, ',', 1, math.min(#@, 3)))",
        "show(pcall(table.concat, @, '-'))",
        "show(table.unpack(@))",
        "show(select('#', table.unpack(@, 1, 5)))",
        "table.sort(@, function(a, b) return tostring(a) < tostring(b) end) show(table.unpack(@))",
        "show(pcall(table.sort, @))",
        "show(table.move(@, 1, 3, 2)[2], #@)",
        "@[#@ + 1] = #@ show(#@, rawlen(@), rawequal(@, @))",
        "for k, v in spairs(@) do show(k, v) end",
        "@.x = nil @[100] = 1 show(#@, next({}))",
        "for i = #@, 1, -1 do @[i] = nil end show(#@)",
        "@[1.0] = 'float key' @[2^53] = 'big' show(@[1], @[2^53 | 0])",
        "show(pcall(function() @[0/0] = 1 end))",
        "show(select(-1, table.unpack(@)))",
        "local p = table.pack(table.unpack(@)) show(p.n)",
    };
    var c = 1 + g.below(3);
    while (c > 0) : (c -= 1) {
        try g.indent();
        const u = g.pick([]const u8, &ops);
        var it = std.mem.splitScalar(u8, u, '@');
        var first = true;
        while (it.next()) |piece| {
            if (!first) try g.print("l{d:0>5}", .{n});
            first = false;
            try g.w(piece);
        }
        try g.w("\n");
    }
}

fn stringStmt(g: *Gen) Error!void {
    const ops = [_][]const u8{
        "show(string.find(@, 'a', 1, true), string.find(@, '(%a)(%a)'))",
        "show(string.byte(@, 1, -1))",
        "show(string.len(@), #@, @:upper())",
        "for w in string.gmatch(@, '%S+') do show(w) end",
        "show(string.gsub(@, '%w', '%0%0', 2))",
        "show(string.format('%q', @))",
        "show(string.format('%-10s|', @:sub(1, 20)))",
        "show(pcall(string.pack, 's4', @))",
        "show(string.unpack('z', @ .. '\\0'))",
        "show(utf8.len(@), pcall(utf8.codepoint, @, 1, -1))",
        "show(tonumber(@), tonumber(@, 16), tonumber(@, 36))",
        "show(@ < 'm', @ == @ .. '', @ .. 1 .. 2)",
        "show(@:rep(2, '|'), @:reverse(), @:lower())",
        "show(string.find(@, '', 10), string.find(@, '%f[%a]'))",
        "show(pcall(string.format, '%' .. @, 1))",
    };
    const id = g.reserve();
    const n = id % 100000;
    try g.print("local l{d:0>5} = ", .{n});
    try g.strExpr(false);
    try g.w("\n");
    try g.addLocal(id, .str, false);
    var c = 1 + g.below(3);
    while (c > 0) : (c -= 1) {
        try g.indent();
        const u = g.pick([]const u8, &ops);
        var it = std.mem.splitScalar(u8, u, '@');
        var first = true;
        while (it.next()) |piece| {
            if (!first) try g.print("l{d:0>5}", .{n});
            first = false;
            try g.w(piece);
        }
        try g.w("\n");
    }
}

fn numberStmt(g: *Gen) Error!void {
    const ops = [_][]const u8{
        "show(math.maxinteger + 1 == math.mininteger, math.mininteger // -1, math.mininteger % -1)",
        "show(1e308 * 10, -1e308 * 10, 2^1024, math.huge // 1)",
        "show(3 // 0.0, -3 // 0.0, 0/0 ~= 0/0, 3 % -2, -3 % 2, 3.5 % -2, -3.5 % 2)",
        "show(5 // -2, -5 // 2, 5.0 // -2, 7 % math.huge, -7 % math.huge)",
        "show(1 << 63, 1 << 64, -1 >> 1, 1 >> -1, 3 & 5.0, 2^53 | 0)",
        "show(math.tointeger(2^53), math.tointeger(2^63), math.tointeger(-2^63), math.tointeger('3'))",
        "show('10' + 1, '0x10' * 2, '1e1' - 1, 10 .. '', 1.0 .. '', -0.0 .. '')",
        "show(tostring(1e15), tostring(1e16), tostring(-1e100), tostring(2^63), 123456789012 * 1000)",
        "show(math.floor(-3.5), math.ceil(-3.5), math.floor(2^62 + 0.0), math.fmod(-7, 3), math.fmod(7, -3), math.fmod(-7.5, 2))",
        "show(math.abs(math.mininteger), math.max(1, 2.5, -1), math.min(3), math.ult(1, -1))",
        "show(0x7fffffffffffffff, 0xffffffffffffffff, 0x1p-1074, 1e-400, 9007199254740993)",
        "show(string.format('%.17g', 0.1), string.format('%.0f', 0.5), string.format('%5.3s', 'abcdef'))",
        "show(1 == 1.0, math.type(1), math.type(1.0), math.type('1'), 2^63 == math.mininteger, -2^63 == math.mininteger)",
        "show(1 < 1.5, math.maxinteger < 2^63, math.maxinteger + 0.0 == 2^63, math.mininteger <= -2^63)",
        "show(tonumber('0x'), tonumber('1e'), tonumber(' 0x1p4 '), tonumber('inf'), tonumber('.5'), tonumber('5.'))",
        "show(math.random(1, 10), math.random(-5, 5), math.random(math.mininteger, math.maxinteger))",
        "show(pcall(math.fmod, 1, 0), math.fmod(1, 0.0) ~= math.fmod(1, 0.0), pcall(math.fmod, math.mininteger, -1))",
        "show(8 // 3 * 3 + 8 % 3, -8 // 3 * 3 + -8 % 3, 2^-1, (-2)^0.5 ~= (-2)^0.5)",
        "show(utf8.char(72, 228, 8364, 128512), utf8.charpattern)",
        "show(string.pack('<i4', 100):byte(1, -1))",
        "show(string.unpack('<d', string.pack('<d', 1.5)))",
        "show(string.packsize('i4i8'), pcall(string.packsize, 's'))",
    };
    try g.w(g.pick([]const u8, &ops));
    try g.w("\n");
}

fn doStmt(g: *Gen) Error!void {
    try g.w("do\n");
    try g.block(4);
    try g.indent();
    try g.w("end\n");
}

fn recursion(g: *Gen) Error!void {
    const id = try g.newLocal(.fun, false);
    const n = id % 100000;
    switch (g.below(3)) {
        0 => try g.print("local function l{d:0>5}(n) if n <= 0 then return 0 end return n + l{d:0>5}(n - 1) end show(l{d:0>5}({d}))\n", .{ n, n, n, g.below(200) }),
        1 => try g.print("local function l{d:0>5}(n, acc) if n == 0 then return acc end return l{d:0>5}(n - 1, acc + 1) end show(l{d:0>5}({d}, 0))\n", .{ n, n, n, g.below(100000) }),
        else => try g.print("local function l{d:0>5}(n) return n > 0 and l{d:0>5}(n - 1) end show(pcall(l{d:0>5}, 1e7))\n", .{ n, n, n }),
    }
}

fn varargStmt(g: *Gen) Error!void {
    const ops = [_][]const u8{
        "show((function(...) return select('#', ...), ... end)(1, nil, 3, nil))",
        "show((function(...t) return t.n, #t end)(1, 2, 3))",
        "show((function(a, ...) local x, y = ... return a, x, y end)(1))",
        "show(select(2, 'a', 'b', 'c'), select(-2, 'a', 'b', 'c'))",
        "show((function(...) return ... end)(table.unpack({1, 2, 3}, 1, 5)))",
        "show(pcall(select, 'x'))",
        "show((function(...) local t = {..., n = 'n'} return #t, t.n end)(4, 5))",
        "show((function(...t) t[1] = 'z' return ... end)('a', 'b'))",
    };
    try g.w(g.pick([]const u8, &ops));
    try g.w("\n");
}

/// Syntax the diff mode avoids: declarations and shapes that stress the
/// compiler more than the run.
fn wildStmt(g: *Gen) Error!void {
    switch (g.below(9)) {
        0 => {
            // Deep nesting of parentheses and unary operators.
            const depth = 1 + g.below(180);
            try g.w("show(");
            var i: u32 = 0;
            while (i < depth) : (i += 1) try g.w(g.pick([]const u8, &.{ "(", "-(", "not (", "~(", "#(" }));
            try g.w("1");
            i = 0;
            while (i < depth) : (i += 1) try g.w(")");
            try g.w(")\n");
        },
        1 => {
            // Many locals in one function.
            const count = 150 + g.below(80);
            try g.w("show(pcall(load('");
            var i: u32 = 0;
            while (i < count) : (i += 1) try g.print("local v{d} = {d} ", .{ i, i });
            try g.w("return v1')))\n");
        },
        2 => {
            // Many upvalues.
            try g.w("do\n");
            const count = 10 + g.below(260);
            var i: u32 = 0;
            while (i < count) : (i += 1) try g.print("local u{d} = {d}\n", .{ i, i });
            try g.w("show(pcall(load('return function() return 1 end')))\nend\n");
        },
        3 => {
            try g.w(g.pick([]const u8, &.{
                "show(pcall(load('global x; x = 1; return x')))",
                "show(pcall(load('global<const> *; return print')))",
                "show(pcall(load('local x <const> = 2^53; local y <const> = x // 3; return y, x % 7')))",
                "show(pcall(load('local a <const> = \"str\"; local b <const> = a .. a; return b')))",
                "show(pcall(load('return 1 // 0')))",
                "show(pcall(load('return -9223372036854775808, - 9223372036854775808, 9223372036854775808')))",
                "show(pcall(load('return 0x' .. string.rep(\"f\", 40))))",
                "show(pcall(load('local t = {' .. string.rep(\"1,\", 600) .. '} return #t')))",
                "show(pcall(load('return ' .. string.rep(\"a.\", 300) .. 'b')))",
                "show(pcall(load('local x = 1 ' .. string.rep(\"x = x + 1 \", 300) .. 'return x')))",
                "show(pcall(load('return \"' .. string.rep(\"\\\\n\", 100) .. '\"')))",
                "show(pcall(load('local function f(...) local a, b = ... return ... end return f(1, 2)')))",
                "show(pcall(load('return 1 and 2 or 3 and nil or false')))",
                "show(pcall(load('local a, b, c = (function() return 1, 2, 3 end)() return c')))",
                "show(pcall(load('if x then elseif y then else end while false do end repeat until true')))",
                "show(pcall(load('return {[1]=1, [2]=2, 3, 4, [\"k\"]=5; n=6}')))",
            }));
            try g.w("\n");
        },
        4 => {
            // A long string with levels.
            const level = g.below(4);
            try g.w("show(#[");
            var i: u32 = 0;
            while (i < level) : (i += 1) try g.w("=");
            try g.w("[\nline ]] ]=] text\n]");
            i = 0;
            while (i < level) : (i += 1) try g.w("=");
            try g.w("])\n");
        },
        5 => {
            // A chain of method calls and string call syntax.
            try g.w("show(('abc'):upper():lower():rep(2):sub(2, -2):len())\n");
        },
        6 => {
            // Constant folding edges.
            try g.w(g.pick([]const u8, &.{
                "show(2^63 // 1, -0.0 == 0.0, 1/0 > 0, 3 // 2.0, 7 % -3.0, 1e308 + 1e308)",
                "show(math.mininteger // -1, 5 // 0.0, -5 % 0.0 ~= -5 % 0.0)",
                "show(1 << 64, 1 >> 64, -1 << 63, ~0, 5 ~ 3, 0xF0 & 0x3C | 1)",
                "show('a' .. 'b' .. 1 .. 2.0, not not nil, -(-(1)), - - 2)",
            }));
            try g.w("\n");
        },
        7 => {
            // Many constants in one function: past the 8-bit and k-limit.
            const count = 200 + g.below(400);
            try g.w("show(pcall(load('local t = {");
            var i: u32 = 0;
            while (i < count) : (i += 1) try g.print("\"k{d}\", {d}.5, ", .{ i, i });
            try g.w("} return #t')))\n");
        },
        else => {
            // Integer for loops with odd bounds.
            try g.w(g.pick([]const u8, &.{
                "for i = math.maxinteger, math.maxinteger - 1, -1 do show(i) end",
                "for i = 1, math.huge do if i > 3 then break end show(i) end",
                "for i = -1, -math.huge, -1 do if i < -2 then break end show(i) end",
                "for i = 1.5, 0, -0.5 do show(i) end",
                "for i = math.mininteger, math.mininteger + 1 do show(i) end",
                "for i = 3, 2^53 + 2, 2^52 do show(i) end",
            }));
            try g.w("\n");
        },
    }
}

test "generated programs are deterministic for a seed" {
    const gpa = std.testing.allocator;
    var a: std.ArrayList(u8) = .empty;
    defer a.deinit(gpa);
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(gpa);
    try program(gpa, &a, 7, .diff);
    try program(gpa, &b, 7, .diff);
    try std.testing.expectEqualStrings(a.items, b.items);
}

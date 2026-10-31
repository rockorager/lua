//! Tests of the embedding API (`api.zig`) through its public names, as a
//! host uses them. Expected messages are the reference's: each is what
//! Lua 5.5.1 prints for the same mistake with a C function in place of
//! the Zig one.

const std = @import("std");
const testing = std.testing;
const lua = @import("root.zig");

fn expectRuntime(state: *lua.State, want: []const u8, r: anytype) !void {
    if (r) |_| return error.TestExpectedError else |e| try testing.expectEqual(error.Runtime, e);
    try testing.expectEqualStrings(want, state.errorMessage());
}

fn add(a: i64, b: i64) i64 {
    return a +% b;
}

const Shape = enum { circle, square };

fn area(shape: Shape, size: f64, scale: ?f64) f64 {
    const s = size * (scale orelse 1);
    return switch (shape) {
        .circle => std.math.pi * s * s,
        .square => s * s,
    };
}

fn divmod(a: i64, b: i64) !struct { i64, i64 } {
    if (b == 0) return error.DivisionByZero;
    return .{ @divFloor(a, b), @mod(a, b) };
}

fn greet(state: *lua.State, name: []const u8) ![]const u8 {
    if (name.len == 0) return state.raise("empty name", .{});
    return std.fmt.allocPrint(arena(state), "hello, {s}", .{name});
}

fn arena(state: *lua.State) std.mem.Allocator {
    return state.context(std.heap.ArenaAllocator).allocator();
}

fn count(args: lua.Args) u32 {
    return args.count();
}

test "chunks run and their results convert to Zig types" {
    const state = try lua.State.init(testing.allocator, .{ .io = testing.io });
    defer state.close();
    const r = try state.doString(
        struct { i64, []const u8, f64, bool, ?i64, i32 },
        "return 1, 'two', 3.5, nil, nil, 7.0",
        .{},
    );
    try testing.expectEqual(1, r[0]);
    try testing.expectEqualStrings("two", r[1]);
    try testing.expectEqual(3.5, r[2]);
    try testing.expectEqual(false, r[3]);
    try testing.expectEqual(null, r[4]);
    try testing.expectEqual(7, r[5]);
    // Lua's conversions: numeric strings to numbers, numbers to strings.
    try testing.expectEqual(16, try state.doString(u8, "return '0x10'", .{}));
    try testing.expectEqualStrings("12", try state.doString([]const u8, "return 12", .{}));
    try expectRuntime(state, "result #1: number has no integer representation", state.doString(i64, "return 1.5", .{}));
    try expectRuntime(state, "result #1: value out of range", state.doString(u8, "return 256", .{}));
    try expectRuntime(
        state,
        "result #2: string expected, got table",
        state.doString(struct { i64, []const u8 }, "return 1, {}", .{}),
    );
}

test "errors come back as Zig errors with the message and a traceback" {
    const state = try lua.State.init(testing.allocator, .{});
    defer state.close();
    try testing.expectError(error.Syntax, state.doString(void, "x = = 1", .{ .name = "=cfg" }));
    try testing.expectEqualStrings("cfg:1: unexpected symbol near '='", state.errorMessage());
    try testing.expectEqual(null, state.errorTraceback());

    try testing.expectError(
        error.Runtime,
        state.doString(void, "local function f() error('boom') end\nf()", .{ .name = "=cfg" }),
    );
    try testing.expectEqualStrings("cfg:1: boom", state.errorMessage());
    const tb = state.errorTraceback().?;
    try testing.expect(std.mem.startsWith(u8, tb, "cfg:1: boom\nstack traceback:\n"));
    try testing.expect(std.mem.find(u8, tb, "cfg:1: in local 'f'") != null);
    try testing.expect(std.mem.find(u8, tb, "cfg:2: in main chunk") != null);

    // A non-string error object is kept as it was.
    try testing.expectError(error.Runtime, state.doString(void, "error({code = 42})", .{}));
    try testing.expectEqualStrings("(error object is a table value)", state.errorMessage());
    try testing.expectEqual(42, try state.getField(i64, state.errorValue(), "code"));

    // The kind of error comes from the engine, not from the message.
    try expectRuntime(state, "not enough memory", state.doString(void, "error('not enough memory', 0)", .{}));

    // The state is usable after every error, and its stack is where it was.
    const th: *lua.internal.Thread = @ptrCast(@alignCast(state));
    try testing.expectEqual(1, th.top);
    try testing.expectEqual(3, try state.doString(i64, "return 1 + 2", .{}));
    try testing.expectEqual(1, th.top);
}

test "libraries open as chosen, and a sandbox reaches no files" {
    const state = try lua.State.init(testing.allocator, .{});
    defer state.close();
    try testing.expect(try state.doString(bool,
        \\return io == nil and os == nil and package == nil and debug == nil and require == nil
    , .{}));
    try testing.expectEqualStrings("HI", try state.doString([]const u8, "return string.upper('hi')", .{}));
    try testing.expectError(error.Runtime, state.doString(void, "dofile('/etc/passwd')", .{ .name = "=s" }));
    try testing.expect(std.mem.startsWith(u8, state.errorMessage(), "cannot open /etc/passwd"));
    try testing.expectError(error.Syntax, state.load("\x1bLua", .{}));
    try testing.expectEqualStrings("attempt to load a binary chunk (mode is 't')", state.errorMessage());

    const none = try lua.State.init(testing.allocator, .{ .libs = .initEmpty() });
    defer none.close();
    try testing.expect(try none.doString(bool, "return print == nil and string == nil", .{}));
}

test "binary chunks load when allowed" {
    const state = try lua.State.init(testing.allocator, .{});
    defer state.close();
    const chunk = try state.doString([]const u8, "return string.dump(function(a) return a * 2 end)", .{});
    const owned = try testing.allocator.dupe(u8, chunk);
    defer testing.allocator.free(owned);
    const f = try state.load(owned, .{ .mode = .binary });
    try testing.expectEqual(42, try state.call(i64, f, .{21}));
}

test "globals and fields, with metamethods" {
    const state = try lua.State.init(testing.allocator, .{});
    defer state.close();
    try state.setGlobal("n", 41);
    try state.setGlobal("name", "lua");
    try state.setGlobal("list", [_]i32{ 10, 20, 30 });
    try testing.expectEqual(42, try state.doString(i64, "return n + 1", .{}));
    try testing.expectEqual(60, try state.doString(i64, "return list[1] + list[2] + list[3] - #list * 0", .{}));
    try testing.expectEqualStrings("lua", try state.getGlobal([]const u8, "name"));
    try testing.expectEqual(null, try state.getGlobal(?i64, "missing"));
    try expectRuntime(state, "global 'missing': number expected, got nil", state.getGlobal(i64, "missing"));

    _ = try state.doString(void,
        \\proxy = setmetatable({}, {
        \\  __index = function(_, k) if k == "bad" then error("no " .. k) end return k .. "!" end,
        \\  __newindex = function(t, k, v) rawset(t, k, v * 2) end,
        \\})
    , .{ .name = "=m" });
    const proxy = try state.getGlobal(lua.Table, "proxy");
    try testing.expectEqualStrings("x!", try state.getField([]const u8, proxy, "x"));
    try state.setField(proxy, "y", 21);
    try testing.expectEqual(42, try state.getField(i64, proxy, "y"));
    // A metamethod's error at the top level is caught, with a traceback.
    try expectRuntime(state, "m:2: no bad", state.getField(i64, proxy, "bad"));
    try testing.expect(std.mem.find(u8, state.errorTraceback().?, "m:2: in function <m:2>") != null);
    try expectRuntime(state, "table index is nil", state.setField(try state.newTable(), null, 1));
    try testing.expectEqual(42, try state.getField(i64, proxy, "y"));
}

test "Zig functions check arguments with the reference's messages" {
    var ar: std.heap.ArenaAllocator = .init(testing.allocator);
    defer ar.deinit();
    const state = try lua.State.init(testing.allocator, .{ .context = &ar });
    defer state.close();
    try state.setGlobal("add", add);
    try state.setGlobal("area", area);
    try state.setGlobal("divmod", divmod);
    try state.setGlobal("greet", greet);
    try state.setGlobal("count", count);
    // A struct of functions is a module table.
    try state.setGlobal("geo", .{ .area = area, .pi = std.math.pi });
    const o: lua.LoadOptions = .{ .name = "=t" };
    try testing.expectEqual(5, try state.doString(i64, "return add(2, 3)", o));
    try testing.expectEqual(5, try state.doString(i64, "return add('2', 3.0)", o));
    try testing.expectEqual(16, try state.doString(f64, "return area('square', 2, 2)", o));
    const qr = try state.doString(struct { i64, i64 }, "return divmod(17, 5)", o);
    try testing.expectEqual(3, qr[0]);
    try testing.expectEqual(2, qr[1]);
    try testing.expectEqualStrings("hello, zig", try state.doString([]const u8, "return greet('zig')", o));
    try testing.expectEqual(3, try state.doString(i64, "return count(1, nil, 3)", o));
    try testing.expectEqual(std.math.pi, try state.doString(f64, "return geo.area('circle', 1) / geo.pi * math.pi", o));

    try expectRuntime(
        state,
        "t:1: bad argument #2 to 'add' (number expected, got no value)",
        state.doString(void, "add(1)", o),
    );
    try expectRuntime(
        state,
        "t:1: bad argument #1 to 'add' (number has no integer representation)",
        state.doString(void, "add(1.5, 1)", o),
    );
    try expectRuntime(
        state,
        "t:1: bad argument #1 to 'f' (number expected, got table)",
        state.doString(void, "local f = add; f({}, 1)", o),
    );
    try expectRuntime(
        state,
        "t:1: bad argument #1 to 'area' (invalid option 'hexagon')",
        state.doString(void, "area('hexagon', 1)", o),
    );
    try expectRuntime(
        state,
        "t:1: bad argument #3 to 'area' (number expected, got boolean)",
        state.doString(void, "area('circle', 1, true)", o),
    );
    try expectRuntime(state, "t:1: DivisionByZero", state.doString(void, "divmod(1, 0)", o));
    try expectRuntime(state, "t:1: empty name", state.doString(void, "greet('')", o));
    // Errors from Zig functions are Lua errors: pcall catches them. Called
    // from pcall, the error has no position, as `luaL_error`'s has none.
    const caught = try state.doString([]const u8, "return select(2, pcall(greet, ''))", o);
    try testing.expectEqualStrings("empty name", caught);
    try expectRuntime(
        state,
        "t:1: bad argument #1 to 'integer index' (number expected, got nil)",
        state.doString(void, "local t = {add} t[1](nil, 1)", o),
    );
}

const Window = struct { width: u32 = 800, height: u32 = 600, title: ?[]const u8 = null };
const Config = struct {
    font_size: f64,
    theme: enum { light, dark } = .dark,
    window: Window = .{},
    padding: struct { i32, i32 } = .{ 0, 0 },
    bold: bool = false,
};

test "structs and tables convert both ways" {
    const state = try lua.State.init(testing.allocator, .{});
    defer state.close();
    _ = try state.doString(void,
        \\config = { font_size = 13.5, theme = "light", window = { width = 1024, title = "term" },
        \\  padding = {4, 8}, bold = 1 }
        \\partial = { font_size = 12 }
        \\bad = { font_size = 12, window = { width = "wide" } }
    , .{});
    const c = try state.getGlobal(Config, "config");
    try testing.expectEqual(13.5, c.font_size);
    try testing.expectEqual(.light, c.theme);
    try testing.expectEqual(1024, c.window.width);
    try testing.expectEqual(600, c.window.height);
    try testing.expectEqualStrings("term", c.window.title.?);
    try testing.expectEqual(4, c.padding[0]);
    try testing.expectEqual(8, c.padding[1]);
    try testing.expect(c.bold);
    const p = try state.getGlobal(Config, "partial");
    try testing.expectEqual(Config{ .font_size = 12 }, p);
    const want = "global 'bad': field 'window.width': number expected, got string";
    try expectRuntime(state, want, state.getGlobal(Config, "bad"));

    // Back to Lua: a struct becomes a table, null fields left out.
    try state.setGlobal("out", Config{ .font_size = 9, .window = .{ .title = "x" } });
    try testing.expect(try state.doString(bool,
        \\return out.font_size == 9 and out.theme == "dark" and out.window.width == 800
        \\  and out.window.title == "x" and out.padding[2] == 0 and out.bold == false
    , .{}));
    _ = try state.doString(void, "out.window.title = nil", .{});
    try testing.expectEqual(null, (try state.getGlobal(Config, "out")).window.title);

    // Slices need an allocator.
    var ar: std.heap.ArenaAllocator = .init(testing.allocator);
    defer ar.deinit();
    const names = try state.decodeAlloc(
        []const []const u8,
        ar.allocator(),
        try state.doString(lua.Value, "return {'a', 'bc', 3}", .{}),
    );
    try testing.expectEqual(3, names.len);
    try testing.expectEqualStrings("bc", names[1]);
    try testing.expectEqualStrings("3", names[2]);
    try expectRuntime(
        state,
        "field '[2]': number expected, got string",
        state.decodeAlloc([]i64, ar.allocator(), try state.doString(lua.Value, "return {1, 'x'}", .{})),
    );
}

test "light userdata and copied strings" {
    const state = try lua.State.init(testing.allocator, .{});
    defer state.close();
    var x: u32 = 7;
    try state.setGlobal("p", @as(*anyopaque, &x));
    try testing.expectEqualStrings("userdata", try state.doString([]const u8, "return type(p)", .{}));
    const back: *u32 = @ptrCast(@alignCast(try state.getGlobal(*anyopaque, "p")));
    try testing.expectEqual(&x, back);
    try expectRuntime(state, "global 'q': light userdata expected, got nil", state.getGlobal(*anyopaque, "q"));
    const str = try state.doString(lua.Value, "return 'abc' .. 1", .{});
    const owned = try state.decodeAlloc([]u8, testing.allocator, str);
    defer testing.allocator.free(owned);
    try testing.expectEqualStrings("abc1", owned);
}

test "iterating a table" {
    const state = try lua.State.init(testing.allocator, .{});
    defer state.close();
    const t = try state.doString(lua.Table, "return {10, 20, x = 5}", .{});
    try testing.expectEqual(2, t.len());
    var sum: i64 = 0;
    var keys: usize = 0;
    var it = t.iterator();
    while (it.next()) |e| {
        sum += try state.decode(i64, e.value);
        keys += 1;
    }
    try testing.expectEqual(35, sum);
    try testing.expectEqual(3, keys);
}

const Counter = struct {
    n: i64,
    log: *std.ArrayList(i64),

    pub const lua_userdata = .{
        .name = "Counter",
        .methods = .{ .incr = incr, .get = get },
        .meta = .{ .__gc = finalize, .__tostring = toString, .__len = get },
    };

    fn incr(self: *Counter, by: ?i64) *Counter {
        self.n += by orelse 1;
        return self;
    }

    fn get(self: *const Counter) i64 {
        return self.n;
    }

    fn toString(state: *lua.State, self: *Counter) ![]const u8 {
        return std.fmt.allocPrint(arenaOf(state), "Counter({d})", .{self.n});
    }

    fn finalize(self: *Counter) void {
        self.log.append(testing.allocator, self.n) catch return;
    }
};

fn newCounter(state: *lua.State, start: ?i64) !*Counter {
    return state.newUserdata(Counter, .{ .n = start orelse 0, .log = state.context(Ctx).log });
}

const Ctx = struct {
    arena: std.heap.ArenaAllocator,
    log: *std.ArrayList(i64),

    fn allocator(c: *Ctx) std.mem.Allocator {
        return c.arena.allocator();
    }
};

fn arenaOf(state: *lua.State) std.mem.Allocator {
    return state.context(Ctx).allocator();
}

test "userdata with methods, metamethods, and finalizers" {
    var log: std.ArrayList(i64) = .empty;
    defer log.deinit(testing.allocator);
    var ctx: Ctx = .{ .arena = .init(testing.allocator), .log = &log };
    defer ctx.arena.deinit();
    {
        const state = try lua.State.init(testing.allocator, .{ .context = &ctx });
        defer state.close();
        try state.setGlobal("Counter", newCounter);
        const o: lua.LoadOptions = .{ .name = "=u" };
        try testing.expectEqual(7, try state.doString(i64, "local c = Counter(1) c:incr():incr(5) return c:get()", o));
        try testing.expectEqualStrings(
            "Counter(3) 3",
            try state.doString([]const u8, "local c = Counter(3) return tostring(c) .. ' ' .. #c", o),
        );
        try expectRuntime(
            state,
            "u:1: bad argument #1 to 'incr' (Counter expected, got table)",
            state.doString(void, "local c = Counter() c.incr({})", o),
        );
        try expectRuntime(
            state,
            "u:1: calling 'incr' on bad self (Counter expected, got table)",
            state.doString(void, "local t = {incr = getmetatable(Counter()).__index.incr} t:incr()", o),
        );
        try expectRuntime(
            state,
            "u:1: bad argument #1 to 'get' (Counter expected, got no value)",
            state.doString(void, "local c = Counter() c.get()", o),
        );
        try testing.expectEqualStrings(
            "Counter",
            try state.doString([]const u8, "return getmetatable(Counter()).__name", o),
        );
        // The host holds one across collections through a reference.
        const c = try state.doString(lua.Ref, "return Counter(100)", o);
        state.collect();
        const incr = try state.getField(lua.Function, c, "incr");
        const get = try state.getField(lua.Function, c, "get");
        try testing.expectEqual(101, try state.call(i64, get, .{try state.call(lua.Value, incr, .{c})}));
        state.unref(c);
        state.collect();
        try testing.expect(std.mem.findScalar(i64, log.items, 101) != null);
        _ = try state.doString(void, "keep = Counter(-1)", o);
        const p = try state.getGlobal(*Counter, "keep");
        try testing.expectEqual(-1, p.n);
        try expectRuntime(state, "global 'add': Counter expected, got nil", state.getGlobal(*Counter, "add"));
    }
    // `close` ran the last finalizer.
    try testing.expectEqual(-1, log.items[log.items.len - 1]);
}

test "references keep values alive and their slots are reused" {
    const state = try lua.State.init(testing.allocator, .{});
    defer state.close();
    const r = try state.ref(try state.doString(lua.Value, "return {answer = 42}", .{}));
    state.collect();
    state.collect();
    try testing.expectEqual(42, try state.getField(i64, r, "answer"));
    state.unref(r);
    const r2 = try state.ref("again");
    try testing.expectEqual(r, r2);
    try testing.expectEqualStrings("again", try state.decode([]const u8, r2));
    try testing.expectEqual(lua.Ref.nil, try state.ref(null));
    state.unref(r2);
}

fn callBack(state: *lua.State, f: lua.Function, x: i64) !i64 {
    // Inside a Zig function, an error in the call propagates to Lua.
    return try state.call(i64, f, .{x}) * 10;
}

fn protectAll(state: *lua.State, f: lua.Function) !struct { bool, []const u8 } {
    state.call(void, f, .{}) catch |e| switch (e) {
        error.Runtime => return .{ false, state.errorMessage() },
        else => return e,
    };
    return .{ true, "" };
}

test "Zig functions call back into Lua, and errors cross both ways" {
    const state = try lua.State.init(testing.allocator, .{});
    defer state.close();
    try state.setGlobal("callBack", callBack);
    const o: lua.LoadOptions = .{ .name = "=c" };
    try testing.expectEqual(420, try state.doString(i64, "return callBack(function(x) return x * 2 end, 21)", o));
    try testing.expectEqualStrings("c:1: inner", try state.doString([]const u8,
        \\local ok, err = pcall(callBack, function() error("inner") end, 1) return err
    , o));
    try expectRuntime(state, "c:1: inner", state.doString(void, "callBack(function() error('inner') end, 1)", o));
    try expectRuntime(
        state,
        "c:1: result #1: number expected, got string",
        state.doString(void, "callBack(function() return 'x' end, 1)", o),
    );
}

test "toString uses __tostring and the values the API makes" {
    const state = try lua.State.init(testing.allocator, .{});
    defer state.close();
    try testing.expectEqualStrings("12.5", try state.toString(12.5));
    const objs = try state.doString(struct { lua.Value, lua.Value },
        \\return setmetatable({}, {__tostring = function() return 'x' end}),
        \\  setmetatable({}, {__tostring = function() return {} end})
    , .{});
    try testing.expectEqualStrings("x", try state.toString(objs[0]));
    try expectRuntime(state, "'__tostring' must return a string", state.toString(objs[1]));
    try testing.expect(std.mem.startsWith(u8, try state.toString(add), "function: "));
}

test "the API stays correct when the collector runs at every safe point" {
    var log: std.ArrayList(i64) = .empty;
    defer log.deinit(testing.allocator);
    var ctx: Ctx = .{ .arena = .init(testing.allocator), .log = &log };
    defer ctx.arena.deinit();
    const state = try lua.State.init(testing.allocator, .{ .context = &ctx });
    defer state.close();
    const th: *lua.internal.Thread = @ptrCast(@alignCast(state));
    th.state.heap.stress = true;
    try state.setGlobal("Counter", newCounter);
    try state.setGlobal("callBack", callBack);
    try state.setGlobal("cfg", Config{ .font_size = 10, .window = .{ .title = "stress" } });
    const r = try state.doString(i64,
        \\local s = 0
        \\for i = 1, 50 do
        \\  local c = Counter(i)
        \\  s = s + callBack(function(x) return c:incr(x):get() .. "" end, i) + #tostring(c)
        \\  collectgarbage()
        \\end
        \\return s + #cfg.window.title
    , .{});
    // Each round adds 20 * i, and the length of "Counter(2i)".
    try testing.expectEqual(25500 + 547 + 6, r);
}

test "a state cleans up after allocation failure at any point" {
    // Fail each allocation in turn until the whole run succeeds; the
    // testing allocator reports any leak on the failing paths.
    var i: usize = 0;
    while (true) : (i += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = i });
        const state = lua.State.init(failing.allocator(), .{}) catch continue;
        defer state.close();
        const r = state.doString(i64, "local t = {} for i = 1, 100 do t[i] = i .. '' end return #t", .{}) catch |e| {
            try testing.expect(e == error.OutOfMemory);
            continue;
        };
        try testing.expectEqual(100, r);
        break;
    }
    try testing.expect(i > 100);
}

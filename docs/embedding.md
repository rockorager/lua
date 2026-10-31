# Embedding Lua in a Zig program

This package runs Lua 5.5 inside a Zig program. The host extends Lua with Zig functions and Zig types; there is no C API and no loading of C modules. Everything below is in the `lua` module, and `examples/host/main.zig` is a complete host (`zig build example`).

The API is unstable while the project incubates.

## Add the dependency

```sh
zig fetch --save <url of a release tarball>
```

```zig
// build.zig
const lua = b.dependency("lua", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("lua", lua.module("lua"));
```

## A state

```zig
const lua = @import("lua");

const state = try lua.State.init(gpa, .{ .io = io });
defer state.close();
```

`lua.State` is one Lua universe. Every byte it allocates comes from the allocator you pass, and `close` runs pending finalizers and frees everything. `Options` also takes:

- `libs`: the standard libraries to open, a `lua.Libs` set. By default every library when `io` is set, and `lua.safe_libs` when it is not.
- `io`: the `std.Io` for `print`, `dofile`, `loadfile`, and the `io`, `os`, and `package` libraries. Leave it out to sandbox: then `print` prints nothing, no file opens, and only `lua.safe_libs` (`base`, `coroutine`, `math`, `string`, `table`, `utf8`) can be opened.
- `environ`: the environment `os.getenv` and `package` see.
- `context`: a pointer to your own data, which Zig functions get back with `state.context(T)`.
- `traceback`: record a traceback when a call fails (on by default).
- `seed`, `strings`: a fixed hash seed, and a separate allocator for strings.

A state is used from one thread at a time.

## Running code

```zig
try state.doString(void, "x = 1 + 2", .{});
const n = try state.doString(i64, "return x * 2", .{});
const pair = try state.doString(struct { []const u8, f64 }, "return 'pi', math.pi", .{});
const f = try state.load(source, .{ .name = "=config" });
try state.doFile(void, "init.lua", .text);
```

`load` compiles without running and returns a `lua.Function`. The `name` option names the chunk in messages: `"=name"` as is, `"@file"` as a file. Binary chunks (`string.dump`, `luac` output) load only with `.mode = .binary` or `.any`. Like reference Lua, the engine trusts binary chunks, so load them only from trusted sources.

The type you pass says what comes back: `void` for nothing, a tuple type for several results, or one type for one result.

## Errors

A failed call returns `error.Runtime`, a chunk that does not compile returns `error.Syntax`, and allocation failure returns `error.OutOfMemory`. After an error:

```zig
state.doString(void, script, .{ .name = "@init.lua" }) catch |err| switch (err) {
    error.Runtime, error.Syntax => {
        std.log.err("{s}", .{state.errorTraceback() orelse state.errorMessage()});
    },
    error.OutOfMemory => return err,
};
```

`errorMessage` is the error as text, `errorValue` the error object itself (Lua can raise any value), and `errorTraceback` the message with a stack traceback, as the standalone `lua` prints it. The state stays usable after any error.

## Values

Zig values become Lua values by their type, and Lua values become Zig values by the type you ask for:

| Zig                                      | Lua                                                                      |
| ---------------------------------------- | ------------------------------------------------------------------------ |
| `bool`                                   | any value, by Lua's truth (`nil` and `false` are false)                  |
| integers                                 | integers; floats with an exact integer value and numeric strings convert |
| floats                                   | numbers; numeric strings convert                                         |
| `[]const u8`, `[:0]const u8`             | strings; numbers convert                                                 |
| `?T`                                     | `nil` is `null`                                                          |
| enums                                    | strings holding the tag's name                                           |
| structs                                  | tables, one field per struct field                                       |
| tuples, arrays, slices                   | sequences                                                                |
| Zig functions                            | functions (see below)                                                    |
| `*T` from `newUserdata`                  | userdata (see below)                                                     |
| `*anyopaque`                             | light userdata                                                           |
| `lua.Value`, `lua.Table`, `lua.Function` | any value, a table, a function                                           |
| `lua.Ref`                                | the value it refers to                                                   |

Reading a struct reads its fields from a table, and a field that is `nil` takes the field's default value; a field without a default must be present (or optional). A value of the wrong type fails with `error.Runtime` and a message that says where: `global 'config': field 'window.width': number expected, got string`.

```zig
const Config = struct {
    font_size: f64 = 12,
    theme: enum { light, dark } = .dark,
    keybinds: []const struct { key: []const u8, action: []const u8 } = &.{},
};
var arena: std.heap.ArenaAllocator = .init(gpa);
defer arena.deinit();
const config = try state.decodeAlloc(Config, arena.allocator(), try state.getGlobal(lua.Value, "config"));
```

`decode` reads without allocating; its strings point into Lua's memory. `decodeAlloc` copies strings and builds slices from sequences, from the allocator you pass; use an arena, since a decode that fails partway does not free what it allocated.

### How long values live

Strings, `Value`, `Table`, `Function`, and userdata pointers that the API returns are borrowed from Lua. Each stays valid while Lua can reach it, for example from a global, a table, or the arguments of the running Zig function, and in any case until the collector next runs. The collector runs only while Lua code runs (a call, a chunk, a metamethod) and in `state.collect()`, never in the middle of an API call that does not run Lua code. To keep a value longer, take a reference:

```zig
const handler = try state.ref(try state.getGlobal(lua.Function, "on_key"));
defer state.unref(handler);
// ... later, after any amount of Lua code:
const handled = try state.call(bool, handler, .{"ctrl+t"});
```

## Globals, fields, and calls

```zig
try state.setGlobal("width", 80);
const w = try state.getGlobal(u32, "width");
const t = try state.getGlobal(lua.Table, "settings");
const name = try state.getField([]const u8, t, "name");
try state.setField(t, "count", 3);
const sum = try state.call(i64, try state.getGlobal(lua.Function, "add"), .{ 1, 2 });
```

`getField` and `setField` index any value with `__index` and `__newindex`, as Lua code does. A table's `iterator()` visits its keys and values raw, and `len()` is its raw length. `toString` converts any value as `tostring` does.

## Zig functions

Any Zig function can be passed where the API takes a Lua value:

```zig
fn add(a: i64, b: i64) i64 {
    return a + b;
}

try state.setGlobal("add", add);
try state.setGlobal("geometry", .{ .area = area, .pi = std.math.pi }); // a module table
```

Lua's arguments convert to the parameters with the reference's argument checks and messages: `add(1)` raises `bad argument #2 to 'add' (number expected, got no value)`. An optional parameter may be absent or `nil`. A first parameter `*lua.State` receives the state, and a last parameter `lua.Args` gives every argument for functions that take any number (`args.count()`, `args.get(n)`, `args.check(T, n)`).

The return value converts back: `void` returns nothing, a tuple returns several values, anything else one value. A function can return an error: `return state.raise("bad size {d}", .{n})` raises a Lua error with that message and the caller's position, and any other error raises its name.

```zig
fn divmod(a: i64, b: i64) !struct { i64, i64 } {
    if (b == 0) return error.DivisionByZero;
    return .{ @divFloor(a, b), @mod(a, b) };
}
```

Inside a Zig function, an error from a call into Lua propagates to Lua's caller when you `try` it, so Lua's `pcall` sees it as usual; catch it to handle it yourself. At the top level, outside any call from Lua, every call into Lua is protected.

## Userdata

A Zig type becomes a userdata type by declaring its Lua side:

```zig
const Counter = struct {
    n: i64,

    pub const lua_userdata = .{
        .name = "Counter",
        .methods = .{ .incr = incr, .get = get },
        .meta = .{ .__tostring = toString, .__gc = deinit },
    };

    fn incr(self: *Counter, by: ?i64) *Counter {
        self.n += by orelse 1;
        return self;
    }
    fn get(self: *const Counter) i64 {
        return self.n;
    }
    fn toString(self: *const Counter) []const u8 { ... }
    fn deinit(self: *Counter) void { ... }
};

fn newCounter(state: *lua.State) !*Counter {
    return state.newUserdata(Counter, .{ .n = 0 });
}

try state.setGlobal("Counter", newCounter);
```

```lua
local c = Counter()
c:incr():incr(5)
print(c:get(), tostring(c))
```

`newUserdata` stores the value in memory the collector owns and gives it the type's metatable: `__name` is `.name`, `__index` is a table of `.methods`, and `.meta` holds metamethods. A parameter `*Counter` accepts only a `Counter` userdata, and anything else raises `bad argument #1 to 'get' (Counter expected, got table)`. `__gc` runs when the collector frees the userdata, and at `close` for those still alive. The type's alignment can be at most 16.

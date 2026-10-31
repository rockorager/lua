# Embedding Lua in a Zig program

This package runs Lua 5.5 inside a Zig program. The host extends Lua with Zig functions and Zig types. By default there is no C API and no loading of C modules; an optional build adds them (below). Everything below is in the `lua` module, and `examples/host/main.zig` is a complete host (`zig build example`).

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

To let scripts `require` compiled Lua C modules (`.so` files built against Lua 5.5.1's headers), pass `.c_api = true` to `b.dependency` and set `exe.rdynamic = true`, so the modules find the `lua_*` functions in your executable. That links libc dynamically and works on x86-64 Linux only; the C API is a prototype and not complete. In this build the `io` library runs on C's stdio, so a file handle is the `luaL_Stream` with a `FILE *` that `lauxlib.h` describes and C modules can share files with scripts, and `print`, `io.write`, and C code write through C's `stdout` (or, with `Options.stdout`, a C stream over your writer). The headers install with the package's own build (`zig build -Dc-api=true`) to `zig-out/include`.

## A state

```zig
const lua = @import("lua");

const state = try lua.State.init(gpa, .{ .io = io });
defer state.close();
```

`lua.State` is one Lua universe. Every byte it allocates comes from the allocator you pass, and `close` runs pending finalizers and frees everything. `Options` also takes:

- `libs`: the standard libraries to open, a `lua.Libs` set. By default every library when `io` is set, and `lua.safe_libs` when it is not.
- `io`: the `std.Io` for `print`, `dofile`, `loadfile`, and the `io`, `os`, and `package` libraries. Leave it out to sandbox: then `print` prints nothing, no file opens, and only `lua.safe_libs` (`base`, `coroutine`, `math`, `string`, `table`, `utf8`) can be opened.
- `stdout`: a `*std.Io.Writer` that `print` and `io.write` write to instead of the process's standard output, with or without `io`; a GUI host captures script output here. `state.stdout()` returns the writer in use, so the host's own output stays in order with the script's.
- `environ`: the environment `os.getenv` and `package` see; `noenv` makes `package.path` and `package.cpath` ignore `LUA_PATH` and `LUA_CPATH`, as `lua -E` does.
- `context`: a pointer to your own data, which Zig functions get back with `state.context(T)`.
- `traceback`: record a traceback when a call fails (on by default).
- `seed`, `strings`: a fixed hash seed, and a separate allocator for strings.
- `gc_mode`: start the collector in `.generational` mode, as the standalone `lua` does.
- `gc_stress`: collect at every safe point (`.full`) or take an incremental step at each (`.step`). Slow; use it in tests to catch a host holding a borrowed value too long.

A state is used from one thread at a time.

## Running code

```zig
try state.doString(void, "x = 1 + 2", .{});
const n = try state.doString(i64, "return x * 2", .{});
const pair = try state.doString(struct { []const u8, f64 }, "return 'pi', math.pi", .{});
const f = try state.load(source, .{ .name = "=config" });
try state.doFile(void, "init.lua", .text);
```

`load` compiles without running and returns a `lua.Function`. The `name` option names the chunk in messages: `"=name"` as is, `"@file"` as a file. `loadFile(null, ...)` reads standard input. Binary chunks (`string.dump`, `luac` output) load only with `.mode = .binary` or `.any`. Like reference Lua, the engine trusts binary chunks, so load them only from trusted sources.

The type you pass says what comes back: `void` for nothing, a tuple type for several results, `lua.Values` for all of them however many there are, or one type for one result.

```zig
const results = try state.doString(lua.Values, "return 1, 'two', nil", .{});
for (results) |v| std.debug.print("{s}\n", .{v.typeOf().name()});
const sum = try state.call(i64, add_all, results); // pass them on as arguments
```

`lua.Values` is a slice borrowed from the state, with no allocation: it stays valid until the next call that runs Lua code (`call`, `pcall`, `doString`, `doFile`, a coroutine's `resume`), and reading it with `decode` and the other API functions in between is fine. Passing it where the arguments go, in place of a tuple, passes each value.

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

`errorMessage` is the error as text, `errorValue` the error object itself (Lua can raise any value), and `errorTraceback` the message with a stack traceback, as the standalone `lua` prints it. The state stays usable after any error. `error.OutOfMemory` means an allocation failed; a script that raises the string "not enough memory" itself is an ordinary `error.Runtime`.

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
const config = try state.decodeAlloc(Config, arena.allocator(), try state.getGlobal(lua.Value, "config"), .{
    .unknown_keys = .reject,
});
```

`decode` reads without allocating; its strings point into Lua's memory. `decodeAlloc` copies strings and builds slices from sequences, from the allocator you pass; use an arena, since a decode that fails partway does not free what it allocated.

Both take `lua.DecodeOptions`. Keys a struct has no field for are ignored unless `.unknown_keys = .reject`, which fails with the key's path, such as `unknown key 'keybinds[2].acton'`, to catch typos in a configuration.

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

`getField` and `setField` index any value with `__index` and `__newindex`, as Lua code does; a table's `rawGet` and `rawSet` skip them (`try t.rawGet(state, i64, "count")`). A table's `iterator()` visits its keys and values raw, and `len()` is its raw length; `state.len(x)` is `#x` with `__len`, as `luaL_len` gives it, and fails unless the length is an integer. `toString` converts any value as `tostring` does, and `state.warn` emits a warning as `warn` does.

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

Inside a Zig function, an error from a call into Lua propagates to Lua's caller when you `try` it, so Lua's `pcall` sees it as usual. To handle it in Zig instead, call with `state.pcall`, which is protected wherever it runs and fills in `errorMessage` and `errorTraceback`; do not catch an error from `call` and carry on. At the top level, outside any call from Lua, every call into Lua is protected.

A function returning `lua.Values` returns each value, so a function can pass along what a call returned:

```zig
fn retry(state: *lua.State, f: lua.Function) !lua.Values {
    return state.pcall(lua.Values, f, .{}) catch try state.call(lua.Values, f, .{});
}
```

### Functions with their own state

`state.function(ctx, f)` makes a Lua function that hands `ctx` to `f` as its first parameter on every call. A pointer is kept as it is, so it must outlive the function; any other value is copied into memory the function owns, and `f` takes the copy by value or by pointer to change it:

```zig
fn bump(count: *i64, by: ?i64) i64 {
    count.* += by orelse 1;
    return count.*;
}

try state.setGlobal("next_id", try state.function(@as(i64, 0), bump)); // a counter of its own
try state.setGlobal("log", try state.function(&editor, Editor.log)); // the host's editor
```

Lua code cannot reach the context, with one exception: the function holds it as its upvalue, and `debug.setupvalue` can replace that with any other value, as it can a C closure's. `f` then reads the replacement as its context without checking it, which is undefined behavior. The `debug` library can break any invariant a host relies on; leave it out of states that run code you do not trust.

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

## Coroutines

`state.newCoroutine(f)` makes a coroutine, as `coroutine.create` does, and its `resume` runs it until it yields or returns. The result type converts the values as `call` does:

```zig
const gen = try state.newCoroutine(try state.getGlobal(lua.Function, "numbers"));
while (true) switch (try gen.@"resume"(state, ?i64, .{})) {
    .yielded => |n| std.debug.print("{?d}\n", .{n}),
    .returned => break,
};
```

`resume` is a Zig keyword, hence `@"resume"`. The arguments go to the body on the first resume, and come back from `coroutine.yield` after that. An error inside the coroutine ends it and returns `error.Runtime`, with `errorTraceback` showing the coroutine's stack; resuming a dead coroutine fails the same way. A `lua.Coroutine` is borrowed like any value, and converts to and from Lua's threads.

`co.status(state)` says what the coroutine is doing, with `coroutine.status`'s names: `.suspended` (not started, or in a yield), `.running` (it is the caller), `.normal` (it resumed the caller), or `.dead`. `co.close(state)` closes a suspended or dead coroutine, as `coroutine.close` does: its pending to-be-closed variables are closed, and it is dead. An error from a `__close` handler, or the error the coroutine died with, comes back as `error.Runtime` with `errorMessage` set (`error.OutOfMemory` if it died because an allocation failed). Closing a running or normal coroutine raises "cannot close a running coroutine" or "cannot close a normal coroutine".

A Zig function yields by returning `state.yield(values)`, with a tuple or `lua.Values`, from a function that returns an error union. When the coroutine is resumed, the function returns the values the resume passed:

```zig
fn ask(state: *lua.State, question: []const u8) !lua.Values {
    return state.yield(.{question});
}
```

It must be the function's last act, as with C's `lua_yield`; there are no continuations. Yielding outside a coroutine, or from inside a call the host made with `call`, raises the reference's errors ("attempt to yield across a C-call boundary").

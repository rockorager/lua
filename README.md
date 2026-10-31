# lua

Lua 5.5 in Zig, with no C.

This project is incubating. It is unstable, its API will change, and it is not ready to depend on.

## Embed it

A Zig program hosts Lua through `lua.State`, and extends it with Zig functions and Zig types:

```zig
const lua = @import("lua");

fn add(a: i64, b: i64) i64 {
    return a + b;
}

const state = try lua.State.init(gpa, .{});
defer state.close();
try state.setGlobal("add", add);
const sum = try state.doString(i64, "return add(1, 2)", .{});
```

`docs/embedding.md` is the guide, and `examples/host/main.zig` a complete host that uses Lua for configuration and plugins (`zig build example`).

## Work on it

`nix develop` provides the toolchain, and `just ci` runs what CI runs.

## License

MIT. See `LICENSE`. The vendored Lua 5.5.1 test suite is PUC-Rio's; see `THIRD_PARTY.md`.

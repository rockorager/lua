# Changelog

All notable changes to lua are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- An embedding API for Zig hosts: `lua.State.init` with `lua.Options` (the allocator, which standard libraries to open, and the `std.Io` they may use, so a host can sandbox scripts without `io` and `os`), `load`, `doString`, `doFile`, and `call` with results converted to Zig types, `getGlobal`, `setGlobal`, `getField`, `setField`, `decode` and `decodeAlloc` between Zig values (structs, slices, enums, optionals) and Lua tables, Zig functions as Lua functions with the reference's "bad argument" errors, userdata types declared with `lua_userdata` (methods, metamethods, `__gc`), and `lua.Ref` registry references. Failures return `error.Runtime` or `error.Syntax`, with `errorMessage` and `errorTraceback`. `docs/embedding.md` is the guide and `examples/host` a complete host.
- A compiler, `Parser.compile`, that turns Lua 5.5 source into the same bytecode `luac` 5.5.1 produces and raises syntax errors with the reference's messages.
- The base library (`print`, `pcall`, `load`, `setmetatable`, and the rest of §6.1) and `lua.internal.lib.openLibs`, which opens the standard libraries into a state.
- A standalone `lua` executable, installed to `zig-out/bin/lua`, with lua.c's options (`-e`, `-l`, `-i`, `-v`, `-E`, `-W`, `-`) and `LUA_INIT`.
- The engine itself as an unstable Zig API under `lua.internal`: `Value`, `State`, `Thread`, `Table`, `String`, `Proto`, `opcodes`, and the `vm` interpreter, which runs Lua 5.5 bytecode. It changes with the engine; hosts use the embedding API.
- The `string`, `table`, `math`, and `utf8` standard libraries, each opened with its module's `open(state)`; `math.random` with a seed gives the reference's sequence, and `math.exp` and `math.log` round as glibc does.
- `string.dump`, with `strip`, and binary chunks in `load`, `loadfile`, and `dofile`, in Lua 5.5.1's format: `luac` 5.5.1 output runs, dumps load on reference Lua, and a bad chunk fails with the reference's "bad binary format (truncated chunk)" and similar messages.
- The `package`, `io`, and `os` standard libraries: `require` with `package.path` from `LUA_PATH_5_5`/`LUA_PATH`, files as `FILE*` userdata with `io.open`, `read`, `lines`, `seek`, `setvbuf`, and `io.popen`, and `os.date`/`os.time` in the system's local time zone. `package.loadlib` and the C searchers report "dynamic libraries not enabled".
- The `coroutine` library (§6.2), with yields across `pcall`, `xpcall`, metamethods, `__close` handlers, and `for` iterators, and the continuation API natives use for that: `vm.callk`, `vm.pcallk`, `vm.yieldk`, `vm.resumeThread`, `vm.closeThread`.
- The `debug` library (§6.10), with hooks: `debug.sethook` and `debug.gethook` with call, tail call, return, line, and count events per coroutine, and `ftransfer`/`ntransfer` in `debug.getinfo` inside a hook; `vm.setHook` sets a `Thread.Hook` from Zig.
- The standalone `lua` prints a traceback after an uncaught error, ending in "[C]: in ?" as the reference's does.
- Runtime errors name the variable involved ("attempt to index a nil value (global 'x')"), "bad argument" messages name the function as the call site does, and `xpcall`'s message handler runs before the stack unwinds, as in the reference.
- To-be-closed variables (`local x <close>`), `__concat`, and named vararg tables (`function f(...t)`) run instead of raising "not implemented yet".
- The collector is Lua 5.5's: weak tables (`__mode` "k", "v", "kv") with ephemerons, `__gc` finalizers on tables and userdata (set with the metatable, run in reverse order, resurrection, errors as "error in __gc" warnings, every pending one at `State.destroy` and `os.exit(code, true)`), incremental collection, and generational mode; `collectgarbage` supports every 5.5 option, and the standalone `lua` runs in generational mode as the reference's does. Files left open close when collected.
- `lua.Options.strings`, an allocator for string objects, and `SmallAllocator`, a single-threaded allocator with size classes 8 bytes apart up to 128 bytes; the standalone `lua` allocates strings with it.

### Changed

- The interpreter is faster on float arithmetic, table indexing with integer and string keys, and calls: against reference Lua 5.5.1, mandelbrot, nbody, hash_int, hash_string, array, binary_trees, and fib now run faster, and every `bench/` program peaks at or below the reference's memory.
- `String.len` is a method, `len()`: a string is 32 bytes plus its contents, in PUC-Rio's `TString` layout.
- `table.concat`, `string.format`, `gsub`, and the other functions that build strings in an `auxlib.Buffer` no longer copy a long result into a new string, and grow their buffer by half instead of doubling, halving table_concat's peak memory.
- Reading and writing a global variable (a field of `_ENV` with a constant name) goes through a per-function cache of where the name sits in the table, so code written with globals runs faster (bench/globals.lua 9% faster).

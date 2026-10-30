# Changelog

All notable changes to lua are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- A compiler, `Parser.compile`, that turns Lua 5.5 source into the same bytecode `luac` 5.5.1 produces and raises syntax errors with the reference's messages.
- The base library (`print`, `pcall`, `load`, `setmetatable`, and the rest of §6.1) and `lib.openLibs`, which opens the standard libraries into a state.
- A standalone `lua` executable, installed to `zig-out/bin/lua`, with lua.c's options (`-e`, `-l`, `-i`, `-v`, `-E`, `-W`, `-`) and `LUA_INIT`.
- The core runtime as an unstable Zig API: `Value`, `State`, `Thread`, `Table`, `String`, `Proto`, `opcodes`, and the `vm` interpreter, which runs Lua 5.5 bytecode.
- The `string`, `table`, `math`, and `utf8` standard libraries, each opened with its module's `open(state)`; `math.random` with a seed gives the reference's sequence, and `math.exp` and `math.log` round as glibc does.
- `string.dump`, with `strip`, and binary chunks in `load`, `loadfile`, and `dofile`, in Lua 5.5.1's format: `luac` 5.5.1 output runs, dumps load on reference Lua, and a bad chunk fails with the reference's "bad binary format (truncated chunk)" and similar messages.
- The `package`, `io`, and `os` standard libraries: `require` with `package.path` from `LUA_PATH_5_5`/`LUA_PATH`, files as `FILE*` userdata with `io.open`, `read`, `lines`, `seek`, `setvbuf`, and `io.popen`, and `os.date`/`os.time` in the system's local time zone. `package.loadlib` and the C searchers report "dynamic libraries not enabled".
- The `coroutine` library (§6.2), with yields across `pcall`, `xpcall`, metamethods, `__close` handlers, and `for` iterators, and the continuation API natives use for that: `vm.callk`, `vm.pcallk`, `vm.yieldk`, `vm.resumeThread`, `vm.closeThread`.
- The `debug` library (§6.10), with hooks: `debug.sethook` and `debug.gethook` with call, tail call, return, line, and count events per coroutine, and `ftransfer`/`ntransfer` in `debug.getinfo` inside a hook; `vm.setHook` sets a `Thread.Hook` from Zig.
- The standalone `lua` prints a traceback after an uncaught error, ending in "[C]: in ?" as the reference's does.
- Runtime errors name the variable involved ("attempt to index a nil value (global 'x')"), "bad argument" messages name the function as the call site does, and `xpcall`'s message handler runs before the stack unwinds, as in the reference.
- To-be-closed variables (`local x <close>`), `__concat`, and named vararg tables (`function f(...t)`) run instead of raising "not implemented yet".

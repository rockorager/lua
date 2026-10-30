# Changelog

All notable changes to lua are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- A compiler, `Parser.compile`, that turns Lua 5.5 source into the same bytecode `luac` 5.5.1 produces and raises syntax errors with the reference's messages.
- The base library (`print`, `pcall`, `load`, `setmetatable`, and the rest of §6.1) and `lib.openLibs`, which opens the standard libraries into a state.
- A standalone `lua` executable, installed to `zig-out/bin/lua`, with lua.c's options (`-e`, `-l`, `-i`, `-v`, `-E`, `-W`, `-`) and `LUA_INIT`.
- The core runtime as an unstable Zig API: `Value`, `State`, `Thread`, `Table`, `String`, `Proto`, `opcodes`, and the `vm` interpreter, which runs Lua 5.5 bytecode.
- The `string`, `table`, `math`, and `utf8` standard libraries, each opened with its module's `open(state)`; `math.random` with a seed gives the reference's sequence, and `math.exp` and `math.log` round as glibc does. `string.dump` raises "unable to dump given function".
- The `package`, `io`, and `os` standard libraries: `require` with `package.path` from `LUA_PATH_5_5`/`LUA_PATH`, files as `FILE*` userdata with `io.open`, `read`, `lines`, `seek`, `setvbuf`, and `io.popen`, and `os.date`/`os.time` in the system's local time zone. `package.loadlib` and the C searchers report "dynamic libraries not enabled".

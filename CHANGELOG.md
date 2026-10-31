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
- `lua.Values`, any number of results borrowed from the state without allocating: `state.call(lua.Values, f, args)`, as a Zig function's return type, and in place of the argument tuple.
- `lua.Coroutine`: `state.newCoroutine(f)` and `co.@"resume"(state, R, args)`, which returns `.yielded` or `.returned` values; a Zig function yields with `return state.yield(values)`.
- `state.function(ctx, f)`, a Lua function that passes `ctx` (a pointer, or a copy of a value) to the Zig function `f` as its first parameter.
- `state.pcall`, a call in protected mode inside a Zig function, so the host can handle a Lua error in Zig.
- `Table.rawGet` and `Table.rawSet`, which skip `__index` and `__newindex`.
- An optional C API, built with `-Dc-api=true` (or `.c_api = true` from a Zig build): Lua 5.5.1's `lua.h` and `lauxlib.h` functions exported from `lua`, the 5.5.1 headers installed to `zig-out/include`, and `package.loadlib` and the C searchers loading compiled C modules with `dlopen`, so modules such as lpeg, lua-cjson, and luafilesystem load unmodified. It links libc dynamically, covers most but not all of the API, and runs on x86-64 Linux only. The default build is unchanged and has no C.
- `lua.Options.stdout`, a `*std.Io.Writer` for `print` and `io.write` in place of the process's standard output, and `state.stdout()`, the writer in use.
- `lua.DecodeOptions` with `.unknown_keys = .reject`, which fails a decode on a table key the struct has no field for and names its path ("unknown key 'keybinds[2].acton'").
- `lua.Options.noenv` (as `lua -E`), `gc_mode`, and `gc_stress`, `state.warn`, and `state.loadFile(null, mode)` for standard input.
- `co.close(state)` and `co.status(state)` on a `lua.Coroutine`, as `coroutine.close` and `coroutine.status`; `close` returns the error a coroutine died with, or a `__close` handler's, as `error.Runtime` (`error.OutOfMemory` for an allocation failure).
- `state.len(x)`, `#x` with `__len` as `luaL_len` gives it.

### Changed

- The registry is laid out as Lua 5.5.1's: `debug.getregistry()[2]` is the globals table and `[3]` the main thread (it was 5.4's, with the main thread at `[1]`).
- The interpreter is faster on float arithmetic, table indexing with integer and string keys, and calls: against reference Lua 5.5.1, mandelbrot, nbody, hash_int, hash_string, array, binary_trees, and fib now run faster, and every `bench/` program peaks at or below the reference's memory.
- `String.len` is a method, `len()`: a string is 32 bytes plus its contents, in PUC-Rio's `TString` layout.
- `table.concat`, `string.format`, `gsub`, and the other functions that build strings in an `auxlib.Buffer` no longer copy a long result into a new string, and grow their buffer by half instead of doubling, halving table_concat's peak memory.
- Reading and writing a global variable (a field of `_ENV` with a constant name) goes through a per-function cache of where the name sits in the table, so code written with globals runs faster (bench/globals.lua 9% faster).
- `auxlib.Buffer` is declared `var b: auxlib.Buffer = .init(state)` instead of `undefined` followed by `b.init(state)`, so ReleaseSafe builds no longer clear 1 KiB on every `string.format`, `table.concat`, `gsub`, `string.pack`, or `string.dump` call (format 21–28% faster in ReleaseSafe).
- ReleaseSafe builds no longer write 0xAA over every table, string, closure, userdata, and stack as it is allocated and freed (Debug builds still do): against the previous ReleaseSafe build, programs run 10.5% faster on the geomean and array and table_concat peak 24 to 27% lower.
- ReleaseSafe builds no longer check each instruction's opcode before dispatching it, since the compiler and the binary loader only produce valid ones: dispatch-heavy programs run 5–12% faster in ReleaseSafe.
- Compiled functions keep line information in `luac`'s encoding, a byte per instruction plus absolute entries (`Proto.lineinfo` is `[]i8`, with `Proto.abslineinfo`; `Proto.lineAt` gives an instruction's line), so loaded code takes about 3 bytes less per instruction: a 521 KB chunk holds 184 KiB less.
- `load` compiles faster: the compiler no longer stalls on its constant cache and on every token it reads, so a 521 KB table constructor compiles 24% faster (bench/config.lua 17% faster).
- `state.decode` and `state.decodeAlloc` take a `lua.DecodeOptions` last; pass `.{}` for the old behavior.
- A script that raises "not enough memory" itself now returns `error.Runtime`; `error.OutOfMemory` means an allocation failed.
- `vm.pcall` and `vm.closeThread` return a `vm.Status` instead of a `bool`; test for `.ok`.
- A function made by `coroutine.wrap` adds the caller's position to an error raised as `error("not enough memory", 0)` inside it, like any other error; only a failed allocation passes through unpositioned.
- The standalone `lua` passes a script `#arg` arguments counted with `__len`, as the reference's does, instead of the raw length.
- `state.errorTraceback()` for an error object whose `__tostring` returns a string is that string, as the standalone `lua` prints it.
- The standalone `lua` is built on the embedding API. An error in `_PROMPT`'s `__tostring` now ends it, a non-string error from `print` in the interactive loop shows as "(null)", and a `__tostring` that returns a non-string gives "(error object is a table value)" and a traceback, as with the reference.
- "C stack overflow" is raised when nested calls between native code and Lua, or the compiler's nesting, use 192 KiB of native stack below the host's call into Lua, as well as at 200 levels, so a host thread with 256 KiB of stack gets a Lua error instead of a crash on any script. Each level takes a third to a quarter of the stack it did (200 nested `pcall`s need 136 KiB instead of 400); nested `string.gsub` replacement functions stop at about 74 levels, where the reference allows 197.
- Release builds of the standalone `lua` no longer install Zig's segfault handler or its 256 KiB signal stack, so `lua -e ''` peaks at 1.2 MiB instead of 1.45 MiB; Debug builds keep both.

### Fixed

- `string.dump` writes the same bytes as `luac` for a function with a call whose parentheses enclose 128 or more lines; before, its line information differed (the lines it decoded to did not).
- `load` of a binary chunk with an instruction whose opcode is not one of Lua 5.5.1's fails with "bad binary format (invalid opcode)" instead of loading a function that crashes when called.
- A Zig function that calls Lua with `state.call` no longer leaves a coroutine that fails inside that call with a corrupt stack for `debug.traceback`.
- The result of an arithmetic, `__len`, or `__index` metamethod, and the error a `__close` handler raises inside `pcall`, are no longer lost (or written to freed memory) when the call grows the stack; `'0' + 1` could give `'0'`.
- `setmetatable(t)` without a second argument raises "bad argument #2 to 'setmetatable' (nil or table expected, got no value)", as in the reference.
- `#t` on a table with holes in its array part returns the border the reference returns.
- A chunk name passed to `load` ends at its first zero byte, and the standalone `lua` prints an error message, and its traceback, only up to a zero byte, as the reference's C strings do.

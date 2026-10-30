# package, io, and os

`lib/package.zig`, `lib/io.zig`, and `lib/os.zig`, opened by `init.zig` in
linit.c's order (`_G`, `package`, `io`, `math`, `os`, `string`, `table`,
`utf8`), each recorded in `package.loaded` as `luaL_requiref` does. All I/O
goes through `std.Io` and `lib.base.Host`; there is no C and no libc.

## What each covers

- **package** (loadlib.c): `require` with `package.loaded` (registry
  `_LOADED`) and `package.preload` (registry `_PRELOAD`), the loader's second
  value, and "module 'x' not found:" listing every searcher's lines.
  `package.searchers` holds the four reference searchers as closures over the
  package table: preload, Lua files over `package.path`, and the two C
  searchers, which search `package.cpath` and report the "no file" lines; a C
  file they do find fails with "dynamic libraries not enabled; check your Lua
  installation". `searchpath` (with `sep` and `rep`), `config`
  (`"/\n;\n?\n!\n-\n"`), and `loadlib`, which returns nil, that message, and
  `"absent"`. `path` and `cpath` come from `LUA_PATH_5_5`/`LUA_PATH` and
  `LUA_CPATH_5_5`/`LUA_CPATH` with `;;` expanded to the default, which is the
  stock build's (`/usr/local/share/lua/5.5/...`); registry `LUA_NOENV` (set by
  `lua -E`) selects the defaults.
- **io** (liolib.c): files are full userdata with the `FILE*` metatable
  (`__index` methods, `__gc`, `__close`, `__name`, `__tostring` as
  `file (0x...)` and `file (closed)`). The userdata holds a `Stream` with a
  4096-byte buffer that follows glibc stdio's rules: full, line, and no
  buffering; a line-buffered write flushes through its last newline; a failed
  flush drops its data; read/write switching; append mode positions at the end
  on every write; the position is tracked, since `std.Io` has no `ftell`.
  `io.stdout` writes through `Host.stdout`. `open` with every mode and the
  "invalid mode" error, `read` with `n` (liolib's `read_number`, 200-byte
  limit, hex and exponents), `l`, `L`, `a`, and counts, `write`, `lines`
  (formats, `io.lines` returning four values and closing at the end),
  `seek`, `setvbuf`, `flush`, `close`, `input`/`output`, `type`, `tmpfile`,
  and `popen` (through `std.process.spawn` running `/bin/sh -c`, closing with
  `execResult`). Errors give errno and its glibc `strerror` text
  (`nil, "x: No such file or directory", 2`). `io.flushAll` flushes every open
  file; `main.zig` calls it at exit, as C's `exit` flushes every `FILE`.
- **os** (loslib.c): `clock` (process CPU time), `date` (C-locale `strftime`
  with every C99 conversion and the `E`/`O` modifiers, `!` for UTC, `*t` and
  `!*t`, "invalid conversion specifier '%Ez'"), `time` (a table normalized as
  glibc's `mktime`, a port of `__mktime_internal`, updating the table's
  fields; "field 'day' is out-of-bound"), `difftime`, `getenv`, `exit` (true,
  false, or a status; `close` flushes but does not close the state yet),
  `remove` (files and empty directories), `rename`, `tmpname`
  (`/tmp/lua_XXXXXX`, created exclusively as `mkstemp` does), `execute`
  (`/bin/sh -c`, with the reference's `true/nil, "exit"/"signal", n`), and
  `setlocale` (only `"C"`, `""`, and `"POSIX"` succeed, as on a system with
  no other locales; the dev shell's reference returns `C.UTF-8` for `""` when
  the environment names that locale). Local time is glibc's: a TZif parser for
  `/etc/localtime` and `TZ=:file` or zone names under
  `/usr/share/zoneinfo`, a POSIX TZ string parser for `TZ=EST5EDT,M3.2.0,...`
  and the TZif footer, and glibc's rule evaluation (`compute_change`'s integer
  wrapping included). A `TZ` that fails to parse is UTC under its leading
  name, as glibc does.

## Not covered

- Closing files when the collector frees them: `__gc` is set, but the
  collector does not run finalizers yet, so an unreferenced file stays open
  until the process ends (files.lua's line 110 loop runs out of
  descriptors).
- `os.exit(code, true)` cannot close the state from inside a native.
- `local f <close> = io.open(...)` and the generic for's closing value need
  to-be-closed variables in the VM.
- Yields across `require`, `dofile`, and `io.lines` callbacks need
  continuations.
- Binary chunks in `loadfile` and `require` need `string.dump` and an
  undumper.
- `io.stdout:seek` reports the tracked position, which is wrong when fd 1's
  offset is shared and moved by another writer.
- `setvbuf`'s size argument is ignored, as glibc ignores it without a
  caller-supplied buffer.
- `read(n)` with a huge count reads as data arrives instead of allocating
  `n` bytes first, so it fails on end of file rather than with "not enough
  memory".

## Verification

Expected values come from the dev shell's `lua`. Each file has a Zig test that
runs Lua chunks with every library open (`package.testing.expectChunk`) and
asserts the reference's results: require's searchers, messages, and
`package.path` expansion; every `io.open` mode and error, the readers, buffer
modes, append, seek, lines, popen, and tmpfile; `os.date` across formats and
zones, `os.time` normalization at month, year, and DST edges, `difftime`,
`execute`, `remove` on files and directories, and `rename`. Bugs injected
into the code under test fail them. `test/diff/io_os.lua` runs under
`just diff` and matches the reference.

Throwaway differential drivers, not kept, compared ours with the reference:
`os.date` with random formats and times under many `TZ` values (zone
names, POSIX rules, invalid strings), `os.time` with random out-of-range
tables, and random sequences of io operations on a file. They match except
for the call-site function name in argument errors, a core request. A port
of `files.lua` without coroutines, to-be-closed variables, the debug library,
and `string.dump`, with an explicit close in its collector loop, passes on
ours with and without `_port` (popen, execute, large files, dates).

## Requests for the core

- Finalizers: run `__gc` for userdata when collected and at `State.destroy`
  (lua_close), so files close and flush.
- A `lua_close` a native can call, for `os.exit(_, true)`: calling
  `State.destroy` there trips its accounting assert.
- To-be-closed variables, including the generic for's fourth value.
- Continuations, so `require` and `dofile` can yield.
- The `debug` and `coroutine` libraries, so `package.loaded` has them; most
  suite files now stop on `require "debug"`.
- Call-site function names in argument errors ("bad argument #1 to
  'io.read'" vs ours' 'read').
- `string.dump` and an undumper for binary chunks.
- The environment and `-E` belong in `Host`: for now `main.zig` stores them
  in the registry (`os.setEnviron`, registry `LUA_NOENV`) before
  `openLibs`.

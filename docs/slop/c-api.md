# The C API

Plan item 16 had "no C API, no `.so` loading" as settled. The owner reopened
it to find out whether compiled Lua C modules (lpeg, lua-cjson,
luafilesystem, ...) can load unmodified without giving up the speed and memory
lead. Wave 8 built the prototype; wave 11 finished it: every function of
`lua.h`, `lauxlib.h`, and `lualib.h`, and `liblua` for C hosts. This is the
design, how the risky parts were proven, what it covers, and where it
differs. The numbers are in `results/c-api-20261031.md` (wave 8) and
`results/capi-full-20261031.md` (wave 11).

## Shape

- **Opt-in.** `-Dc-api=true` (or `.c_api = true` from a Zig host's
  `b.dependency("lua", ...)`) sets `lua_options.c_api`. Only then do the
  module and `lua` link libc, `lua` link `-rdynamic` (C modules bind to its
  `lua_*` symbols as they do to lua.c's `-Wl,-E`), `src/capi/` compile, and
  `include/` install to `zig-out/include`, and `liblua.a`, `liblua.so`, and
  `lua5.5.pc` build (below). The default build is libc-free, static, and
  its two `runLoop` instances are byte-identical to the base's with
  addresses masked; after wave 11 its whole `.text` is.
- **Our code stays Zig.** Every API function is `export fn ... callconv(.c)`
  in `src/capi/capi.zig` (lua.h), `src/capi/lauxlib.zig` (lauxlib.h), and
  `src/capi/state.zig` (states for C hosts and lualib.h).
  `src/capi/loadlib.zig` is loadlib.c's `LUA_USE_DLOPEN` half on `dlopen`
  from libc (`std.c.dlopen`: Zig's libc-free ElfDynLib does no relocations or
  `DT_NEEDED`, so it cannot load real modules).
- **The headers are 5.5.1's, unmodified** (`include/`, recorded in
  `THIRD_PARTY.md`). The stock `luaconf.h` already matches our configuration:
  64-bit integers, doubles, `LUA_EXTRASPACE` of a pointer, `LUAL_BUFFERSIZE`
  from `BUFSIZ`, `LUA_IDSIZE` 60. So the macros modules bake in hold:
  - `LUA_REGISTRYINDEX` is `-(INT_MAX/2 + 1000)` in 5.5.1 (not
    `-LUAI_MAXSTACK - 1000` as in 5.4); upvalue `i` is that minus `i`.
  - `lua_call`, `lua_pcall`, `lua_yield` go to the `k` variants,
    `lua_tonumber` to `lua_tonumberx`, `lua_pop` to `lua_settop`,
    `lua_insert`/`lua_remove`/`lua_replace` to `lua_rotate`/`lua_copy`.
  - `luaL_Buffer`, `lua_Debug`, `luaL_Reg` are the header's structs, used
    as declared (`lauxlib.zig` mirrors them as `extern struct`s).
  - `luaL_checkversion_` checks `LUAL_NUMSIZES` and the version.
- **The registry is 5.5.1's.** `registry[1]` heads `luaL_ref`'s free list
  (false until the first reference), `[2]` is `LUA_RIDX_GLOBALS`, `[3]`
  `LUA_RIDX_MAINTHREAD`. We had 5.4's layout (1 = main thread); `api.zig`'s
  references moved their free list to `[1]` with it. This change is in every
  build; it costs nothing measurable.

## `lua_State *` and the extra space

A `lua_State *` is the `*Thread` itself: no API call translates it. In a C-API
build `Thread.create` allocates `Thread.prefix_len` (24) bytes in front of the
thread: 8 for its C hook (`lua_sethook`'s function), 8 for this file's
per-thread data pointer (`ThreadData`: the C continuations by frame, and on
the main thread the table of light C functions, the warning, panic, and
allocation functions), then `LUA_EXTRASPACE`, so `lua_getextraspace(L)`,
which is `(char *)L - sizeof(void *)`, lands in memory we own.
`lua_newthread` copies the main thread's extra space into the new thread's,
as 5.5.1 does. `prefix_len` is 0 in the default build, where `create` and
`destroy` compile to what they were.

## C functions are natives

`Proto.NativeClosure` gains `cfn` (`?*const anyopaque`, and `void` in the
default build, where the struct is unchanged). A C function is a native
closure whose `f` is `capi.trampoline` and whose `cfn` is the C function. The
interpreter's CALL sees an ordinary native and checks nothing new.
`lua_tocfunction` returns `cfn` when `f` is the trampoline, and `lua_iscfunction`
is true for every native, as for every C function in the reference.

A light C function (`lua_pushcfunction`, `luaL_setfuncs` with no upvalues) is
a value in the reference, equal to itself by address. Here it is a closure
with no upvalues, interned by address in a registry table on first push, so
pushing `f` twice gives the same value (`lua_rawequal`, table keys, and
attrib.lua's checks hold). The price is one allocation per distinct C
function, once.

## Errors: protected calls into C

C code calls `lua_error`/`luaL_error` and expects them not to return. Our VM
unwinds with Zig error unions, which cannot pass through C frames. The design
is the one proposed, with one change, the fused protected call:

1. **The trampoline makes a protected call.** `jmp.call(regs, f, L, a1, a2)`
   (`src/capi/jmp.zig`, two naked functions) saves rbx, rbp, r12 to r15, the
   stack pointer after its return, and its return address, then calls `f`
   (on aarch64: x19 to x30, the stack pointer, and d8 to d15, under a frame
   record; see "aarch64" below).
   `jmp.jump(regs)` restores them and returns from that same call with
   `aborted` (~0, which a C `int` zero-extended can never be). The trampoline
   keeps a thread-local chain of these (`current`), innermost first.
2. **An API function that fails throws.** Every export that can raise wraps
   the Zig call in `check(L, ...)`, which on error stores the error in a
   thread-local and `jump`s to the innermost protected call. `lua_error`
   throws `L.throw(v)`, `lua_yieldk` throws `error.Yield` after
   `vm.yieldk`.
3. **The trampoline returns the error.** On `aborted` it returns the stored
   Zig error, and from there the VM unwinds as for any native's error:
   `pcall`, message handlers, to-be-closed variables, and coroutines need
   nothing new.

Why fused, rather than C's setjmp: `setjmp` returns twice, and Zig has no
`returns_twice` for a call it makes, so locals the optimizer keeps in
registers across it could be stale after the second return. `jmp.call` is an
ordinary call that returns once, either way, so the optimizer needs no
knowledge of it. It also saves no signal mask (no syscall), like `_setjmp`.

**The invariant that makes the jump safe:** between a protected call and a
`throw` sit only C frames and the one API function that throws. VM frames
under a C function's `lua_call` have already returned their Zig error to
`lua_callk` before it throws; a C function called from that Lua code has its
own protected call. The API function throwing has no pending `defer` or
`errdefer` at the throw (where one would hold memory, the memory lives in a
userdata on the stack instead: `Box` for `lua_load`'s chunk and for
`luaL_Buffer`'s heap part, which the collector frees if a jump abandons it).
Zig natives (our libraries) never call a throwing export; `loadlib.zig`
uses `lightCFunction`, not `lua_pushcfunction`, for that reason. Wave 11
made this a test, below.

Every place Zig calls C code goes through a protected call of its own:
the trampoline for C functions, `cK` for continuations, and `protect` for
the rest, so an error a callback raises stops at the Zig frame that called
it: `lua_load`'s reader (`readShim`), `lua_dump`'s writer (`writeShim`),
hooks (`cHook`), the warning function (`cWarn`, which drops the error, as
the collector warns from deep in Zig code), and `lua_closeslot`'s and
`lua_settop`'s `__close` calls through the VM. A `lua_Alloc` must not
raise, as in the reference.

### The invariant, checked

`src/capi/unwind.zig` reads the sources with Zig's tokenizer and fails
`zig build test -Dc-api=true` on a violation. A function may throw if it
calls `capi.throw`, a function that may throw, or C code directly (a
function-typed value, or a field of a callback type such as `lua_Writer`);
a call through `protect` is not a call. In `src/capi/`, no call that may
throw may follow a pending `defer` or `errdefer`, or sit inside one, and
no code outside `src/capi/` may call a C-API function that may throw. The
test runs over the tree (and checks it is not vacuous: `check`,
`luaCallk`, `luaSettop`, `readShim`, `lauxError` throw, `luaLoad`,
`trampoline`, `cWarn`, `loadFunc` do not) and over sources seeded with each
kind of violation, which it must report by line. A call to a sibling in
the same struct resolves to it; an `extern fn` named `lua*` (`liolib.zig`
calls the API by its C names) counts as C code, other externs as libc.
It found `cWarn` calling the warning function directly; it now goes
through `protect`.

An error raised on another Lua thread than the protected call's (a coroutine
resumed from C) moves its error object to the catching thread first.

**Continuations** map onto the VM's existing native continuations.
`lua_callk`, `lua_pcallk` and `lua_yieldk` with a `k` record `{k, ctx}` in
the per-thread data under the running frame's index and pass `vm.callk`,
`vm.pcallk` or `vm.yieldk` the continuation `cK` with that index as its
context. On resume `cK` reads the record and calls `k(L, status, ctx)`
through the same protected call, so a continuation may raise or yield again.

**Stack moves.** API functions keep stack indices, not pointers, across any
call that can run Lua or grow the stack, and write results back by index
(the rule a4deed2 applied to `getSlow`, `arithSlow`, `lenSlow` and
`protectedCall`). lpeg found that bug before the rebase: its `__pow` C
metamethod grows the stack under `arithSlow`.

### Proofs

`test/capi/capitest.c` with `test/capi/errors.lua`, run by `just capi-test`
on our C-API `lua` and on the reference with the same `.so`, output compared
with addresses masked (identical):

- C → `lua_call` → Lua → `error`; error tables keep their identity.
- C → `lua_call` → Lua → C → `luaL_error`, nested 1, 50, and 300 deep (the
  last hits "C stack overflow" as in the reference), 2000 times in `pcall`,
  with C-side allocations counted to show nothing leaks.
- `lua_pcall` from C: success, error, `luaL_error` inside, memory error,
  message handler (`debug.traceback` too), a failing handler (`LUA_ERRERR`),
  nested `lua_pcall`.
- Errors through metamethods called from C: `lua_gettable`/`lua_settable`
  with raising `__index`/`__newindex`, `lua_arith` with `__add` and with no
  handler, integer division by zero, `lua_compare` with a raising `__lt`,
  `lua_concat` with a raising `__concat`, `lua_len`, `luaL_tolstring`; a C
  `__add` that raises, called from Lua; a Lua `__index` that calls C that
  calls Lua's `__index`.
- Yields: `lua_yield` from C, `lua_yieldk` with a continuation (and in a
  loop), `lua_callk` whose callee yields, `lua_pcallk` whose callee yields
  then raises or returns, yield across `lua_call` without `k` ("attempt to
  yield across a C-call boundary"), yield outside a coroutine, `lua_resume`
  of a coroutine from C including its error and dead states,
  `lua_newthread` + `lua_resume`.
- lauxlib: argument checks with the reference's messages (named locals,
  bad self), `luaL_checkoption`, `luaL_checkudata`, buffers small, large
  (5000 bytes through `luaL_prepbuffsize`), and abandoned by an error,
  references, `luaL_loadstring`, `luaL_traceback`, `luaL_where`,
  `luaL_gsub`, `lua_pushfstring`'s formats.
- The same under `-Dgc-stress=full`: capitest, lpeg, lfs, and attrib pass
  (capitest's `__gc` warning names a position, because the finalizer runs
  at a different time).
- Allocation failure: a Zig test (`zig build test -Dc-api=true`) fails every
  allocation in turn under a C function that loads a chunk through a
  reader, calls, raises in a `lua_pcall`, concatenates, and makes
  userdata; each run ends `LUA_OK` or `LUA_ERRMEM` with "not enough memory",
  and the testing allocator finds no leak.

### Alternatives considered

- **Zero-cost unwinding** (`_Unwind_ForcedUnwind` through C frames, which
  x86-64 GCC gives `.eh_frame` by default) would make a call into C free of
  the register saves. It needs a personality routine and landing pad in the
  trampoline, which Zig does not emit, and libgcc_s; a throw would cost
  microseconds instead of nanoseconds. The saves are 8 stores of the 14 ns;
  not worth it before the rest of the call path.
- **One protected call per API call** instead of per C function would make
  every `lua_*` call pay for it. Per C function, a C function that raises
  nothing pays once.

## io handles are `luaL_Stream`

lauxlib.h promises C modules that a file handle is a full userdata with
the "FILE*" metatable whose first bytes are `luaL_Stream { FILE *f;
lua_CFunction closef; }`, `closef` null once closed. Modules rely on it
both ways: luafilesystem's `setmode` and `lock` and luaposix's `fileno`
read `f` from a handle Lua opened; luaposix's `fdopen` makes a handle with
its own `FILE *` and close function and gives it to Lua to read, write,
and close. The default build's io (`lib/io.zig`) has no libc and emulates
glibc's stdio in Zig, with a 4 KiB buffer in each handle, so there is no
`FILE *` to give.

A C-API build links libc anyway, so there `lib/init.zig` opens
`capi/liolib.zig` instead: liolib.c ported function by function to Zig,
on C's stdio and the C API. Its functions are C functions (`callconv(.c)`,
run through the trampoline), and call the API by its C names (`extern fn
lua_getfield`, `luaL_checkudata`, ...), as liolib.c does, so they may use
the API functions that raise and `luaL_fileresult` is the one module see.
What follows from being the reference's code on the reference's libc:

- Every behavior is the reference's by construction: buffering modes,
  read/write switching, `read("n")`'s numeral scan with `ungetc`, `popen`
  (with `fflush(NULL)` first) and `pclose`'s status, `tmpfile`, `seek` with
  `fseeko`/`ftello`, errors with errno and glibc's `strerror`. The default
  build's divergences (`io.stdout:seek` on a shared descriptor, `read(n)`
  with a huge `n`) are gone in this build.
- `aux_close` calls the handle's `closef` directly, whoever set it: a
  module's close function runs inside io's protected call and may raise.
- Standard output is one C stream for everyone. `base.Host` gains
  `cstdout`: C's `stdout`, or with `Options.stdout` a `fopencookie` stream
  over the embedder's writer (its write function writes and flushes the
  writer, as the default build's `io.stdout` flushes it; seeking fails
  with ESPIPE, "Illegal seek", as there). `print`, `io.stdout`, `lua`'s
  own output (`Host.stdout` is a writer with no buffer that `fwrite`s to
  it), and C modules writing to `stdout` all go through its one buffer, so
  their output stays in order. `State.stdout()` with an embedder's writer
  flushes the C stream into it first. `stdin` and `stderr` are C's.
- `liolib.execResult` is lauxlib.c's `luaL_execresult`, for `pclose`,
  and `lauxlib.zig` exports it under that name: one function for both.
- `read_line` reads with glibc's `getc_unlocked` macro inlined (the
  stream's read pointer, `__uflow` at the end of the buffer), as liolib.c
  compiles on glibc; other libcs call the function.
- `read("a")` is liolib.c's. Before the API part of wave 11 it sized
  its buffer to what was left of a regular file first (`statx`), as
  lauxlib's box then grew by copying into a new userdata; reading 20.6
  MB whole took 3.1× the reference's time without the hint. The box now
  reallocates in place (`capi.Box`, below), and the hint no longer paid
  (`results/capi-full-20261031.md`), so it went.
- `lib/io.zig`'s tests run on this io in a C-API build (they only run Lua
  chunks), and `just capi-test` runs `files.lua` and every `test/diff`
  case on the C-API `lua` against the reference.

`os` stays `lib/os.zig` in both builds: it opens no files, and its
`execute` and `exit` reach io only through `lib.io.flushAll`.

Proofs (`just capi-test`, same output as the reference with the same
`.so`): luafilesystem's own tests whole (its setmode block was cut
before), `lock.lua` (lock, unlock, ranges, closed and bad-mode errors),
`stream.c` with `handles.lua` (Lua and C writing and reading one `FILE`
in order, `fileno` of the standard files, module-made handles closed by
`close`, the collector, `<close>`, and a raising close function, `io.output`
and `io.input` on them, every open mode, `popen`, `tmpfile`), and
luaposix 37's `posix.stdio` (its spec's cases without specl, `fileno`
with `posix.unistd.write`, `fdopen` over a dup of stdout, an `O_EXCL` file
and a pipe, `rename`).

## C libraries close with the state

`package.loadlib` and the C searchers keep each library's handle in the
registry's `_CLIBS`, by path as before and now also at `#_CLIBS + 1`, as
5.4's loadlib.c did. `State.destroy` calls `capi/loadlib.closeLibs` after
`vm.closeState` (to-be-closed variables and every finalizer) and before
any object is freed: it `dlclose`s from the last opened to the first.
That is 5.5.1's order: it ties each library to an external string whose
deallocation closes it, so `lua_close` closes libraries after every
finalizer, newest first, while freeing objects. Here external strings are
copied (`lua_pushexternalstring` gives the bytes back at once), so no
object can point into a library's memory and closing before the objects
are freed is the same. `_CLIBS[i]` holds a light userdata where 5.5.1 has
a library string. `os.exit(code, true)` runs finalizers but leaves the
libraries to the process's exit, which closes them anyway.

`unload.c`, built as two libraries, checks it: their userdata's `__gc`
(module code) prints first, then each library's destructor reports whether
the other is still mapped: "unload 2: still loaded", then "unload 1:
gone", as on the reference. Before this change the destructors ran at
exit with both still mapped.

## aarch64

`jmp.zig` has an aarch64 pair beside the x86-64 one, for AAPCS64 (Linux)
and Apple's arm64 ABI, which agree on everything it touches. `call`
stores x19 to x28, x29 and x30, the stack pointer at entry, and d8 to d15
(AAPCS64 has the callee keep the low 64 bits of v8 to v15, which x86-64
System V has no counterpart for), pushes a frame record and sets x29 (Apple
requires x29 to address a valid frame record at every call; unwinders
follow it), calls `f`, and zero-extends its `int` (`mov w0, w0`). `jump`
reloads them, sets the stack pointer, and `ret`s to x30 with x0 = ~0. x18,
Apple's platform register, is never touched; it is not callee-saved on
Linux either. No BTI landing pad: Zig does not mark its objects for BTI,
so no page is guarded.

A test in `jmp.zig` loads 100 + n into every callee-saved register, makes
a protected call to a function that overwrites them all and jumps, and
checks each came back (on x86-64 too). Dropping one restore fails it.

The rest of the API needed two changes for aarch64:

- Function pointers have 4-byte alignment there, so `@ptrCast` from
  `*anyopaque` to a function pointer needs `@alignCast` (`Value.asNative`,
  `capi.cfunction`, `loadlib`); on x86-64 it compiles to nothing, and the
  default build's interpreter loop is byte for byte the same.
- Zig 0.16 refuses `@cVaStart`, `@cVaArg`, and `std.builtin.VaList` on
  aarch64 Linux with LLVM ("disabled due to miscompilations"), which
  `lua_pushfstring`, `lua_pushvfstring`, and `luaL_error` used.
  `capi/va.zig` is AAPCS64's `va_list` there: `va.Entry(target)` is a
  naked entry that saves x0 to x7 and q0 to q7, builds the list
  (`__stack`, `__gr_top`, `__vr_top`, `__gr_offs` = -48 after two named
  arguments, `__vr_offs` = -128) and calls `target(L, fmt, &list)`;
  `va.arg` reads it as `va_arg` does. Elsewhere `va.List` is
  `std.builtin.VaList` and `va.arg` is `@cVaArg`, so x86-64 compiles as
  before. `lua_gc` declares `...` without reading it, which compiles; when
  it reads its arguments (`LUA_GCINC`, `LUA_GCGEN`) it needs the same.

Tested on aarch64 Linux under qemu-user from the flake's nixpkgs:
`just capi-test aarch64-linux-gnu` cross-builds `lua` and every module
with `zig cc -target aarch64-linux-gnu` and runs both interpreters under
qemu, the reference being nixpkgs' aarch64 build; all 28 comparisons
match. io_os takes the native reference as its oracle there: under qemu
glibc's `system()` leaves errno at ENOSYS from a `clone3` qemu refuses,
which the reference's `luaL_execresult` reports for a failing command.
`zig build test -Dc-api=true -Dtarget=aarch64-linux-gnu -fqemu
--libc-runtimes DIR` (DIR/aarch64-linux-gnu/lib holding nixpkgs'
aarch64 glibc) passes everything C-API: the register test, allocation
failure under C calls, the io tests on liolib, the API's stdout test. Three
tests fail on aarch64 in every build, the default one included: they
expect x86-64's "-nan" for a NaN from 0/0 or `math.fmod`, where aarch64
gives a positive NaN, as the reference does there.

What macOS (arm64 and x86-64) still needs, untested here:

- `jmp.zig` and `va.zig` should be right as written (Apple passes
  variable arguments on the stack and `va_list` is a pointer, which Zig's
  own `@cVaStart` handles; `va.native` is true there). Run the register
  test and `capitest.c` on hardware.
- `fopencookie` is glibc's; macOS has `funopen`, which `Host.setStdout`
  would use with the same write and seek functions. `liolib.zig`'s
  `__uflow` fast path is glibc-only already; `stdin`, `stdout`, and
  `stderr` are `__stdinp`, `__stdoutp`, `__stderrp` there (done).
- Linking: `lua` exports its symbols with `-rdynamic` (fine with Mach-O's
  `-export_dynamic`), and modules link with `-undefined dynamic_lookup`
  (`-bundle`) instead of `-shared`; `capi-test` would need that flag.
- `dlopen` and `dlclose` exist; `libm.so.6` in loadlib's retry would be
  `libm.dylib` (libSystem has it already, so the retry never triggers).

## Coverage

All 156 functions `lua.h`, `lauxlib.h`, and `lualib.h` declare are
exported, from `lua` and from `liblua`. `just capi-coverage BINARY...`
(the end of `just capi-test`) takes every declaration from the headers
(`LUA_API`, `LUALIB_API`, `LUAMOD_API`, the name in parentheses) and every
defined dynamic symbol named `lua_*`, `luaL_*`, or `luaopen_*` from each
binary, and fails on one missing from either side: "156 of 156" for
`liblua.so` and `lua`, nothing extra. Every function has a differential
case run on both interpreters or both libraries: `capitest.c` with
`errors.lua` for C modules, `host.c` for C hosts.

The suite's `libs/` (lib1, lib11, lib2, lib21, lib22), lpeg 1.1.0,
lua-cjson 2.1.0.10, and luafilesystem 1.9.0 pass with their own tests.
`package.loadlib` and the C searchers (cpath, `luaopen_a_b` for `a.b`, the
part before `-`, the all-in-one loader, `"*"` for global symbols) give the
reference's messages.

### liblua for C hosts

With `-Dc-api=true` the build installs `lib/liblua.a`,
`lib/liblua.so.5.5.1` (soname `liblua.so.5`, as Zig sets only the major
version; the reference's is `liblua.so.5.5`), and `lib/pkgconfig/lua5.5.pc`.
Both bundle compiler-rt, link no UBSan runtime, and export only the API
(`src/capi/liblua.map`). A static host links with `-Wl,-z,noexecstack`, as
the archive's objects carry no GNU-stack note.

- `lua_newstate(f, ud, seed)` (5.5's signature) makes a state whose every
  byte goes through the host's `lua_Alloc`: its heap's backing allocator
  is an adapter over `f` (`state.zig`'s `CState`), which also holds what
  the libraries need from a host. `lua_Alloc` gives malloc's alignment, so
  the adapter refuses alignments over 16; `resize` succeeds only in place
  and `remap` is the realloc. `lua_close` closes the state, flushes the
  standard streams, and frees everything through `f`; `host.c` counts the
  bytes and finds none left. It goes through `State.destroy`, so C
  libraries the state loaded close after every finalizer, the last loaded
  first (`host.c` loads unload.c's two modules and closes).
- `luaL_newstate` is lauxlib's: `realloc`/`free`, a seed from
  `luaL_makeseed`, the panic function that prints "PANIC: unprotected
  error in call to Lua API (...)", and warnings on.
- `lua_atpanic` is per state. An error with no protected call runs the
  panic function, then aborts, as `luaD_throw` does; with none set (a bare
  `lua_newstate`), it aborts.
- `luaL_openselectedlibs(L, load, preload)` follows linit.c, and each
  `luaopen_*` opens its library and returns its table, as the reference's
  do when a host calls them with `luaL_requiref`.
- The libraries' I/O is one process-wide `std.Io.Threaded`, with the
  vtable trimmed to what they call, as `main.zig` does; `os.getenv` and
  `package`'s paths read libc's `environ` when those libraries open.
- `lua_setallocf` on a state from `lua_newstate` switches the function
  for later blocks, which must free what the old one allocated, as in the
  reference.

`test/capi/host.c` embeds the library and runs allocators (a counting
`lua_Alloc` and a failing one), states and libraries, the panic path in a
child process, hooks, the debug interface, to-be-closed slots, dumps,
warnings, `luaL_execresult` and `luaL_fileresult`, every `lua_gc` option,
threads and their extra space. `just capi-test` builds it against the
reference's `liblua.so`, our `liblua.so`, and our `liblua.a`, and the
three outputs must be the same.

### Hooks and the debug interface

`lua_sethook` keeps the C hook in the thread's prefix and sets the
thread's `Thread.Hook` to `cHook`, the engine's existing machinery
(`vm.md`, wave 3), so events, masks, counts, and inheritance by new
coroutines are `debug.sethook`'s. `cHook` fills a `lua_Debug` with the
event, the line, and the frame, and calls the C hook through `protect`.
`lua_sethook` and `debug.sethook` replace each other; `debug.gethook`
answers "external hook" for a C hook, and `lua_gethook` answers a C
function that runs debug's hook when `debug.sethook` set it.
`lua_getinfo` takes every option (`r` reads the transfer of the hooked
frame); `lua_getlocal` and `lua_setlocal` use the debug library's
`findLocal`, and `lua_upvalueid` and `lua_upvaluejoin` its upvalue
identities.

### The rest

- `lua_toclose` marks a slot in the VM's to-be-closed list;
  `lua_closeslot` and `lua_settop` close what they pop, and a C function
  that returns with marked slots has them closed by the trampoline (or
  `cK`) through `vm.closeLevel`.
- `lua_dump` streams `string.dump`'s writer to the C `lua_Writer`;
  `lua_setwarnf` replaces the state's warning function, which `warn` and
  the collector call; `lua_gc` takes every option, the mode switches and
  `LUA_GCPARAM` included.
- `lua_load` and `luaL_loadbufferx`/`luaL_loadfilex` never raise: a reader
  that raises, a syntax error, or no memory comes back as the status.
- `luaL_Buffer`'s box and `lua_load`'s chunk live in `capi.Box`, lauxlib.c's
  box: a userdata holding a pointer to memory from the state's heap, which
  grows with `realloc` (in place where the allocator can; large blocks
  `mremap`), with a `__gc` that frees it if an error abandons the box.
  `luaL_pushresult` and `lua_load` free it at once. Wave 8's box was the
  bytes in a userdata, copied into a new one at each growth, the old ones
  left to the collector. While the state closes, finalizers no longer
  register, so a box made then is the old kind.
- `luaL_fileresult` and `luaL_execresult` are lauxlib.c's: "(no extra
  info)" for errno 0, and the file name and message whole, however long.

### Where it differs

- **Hooks cannot yield.** `lua_yield` in a line or count hook raises
  "attempt to yield across a C-call boundary"; the reference suspends the
  coroutine.
- **`lua_load` reads the whole chunk** before compiling it, as the
  compiler takes a buffer; the reference parses as it reads.
- **A yield inside the `__close` of a returning C function's marked
  slot** is not supported.
- **The stack of a coroutine an error killed**, below the error object,
  is not the reference's: `lua_gettop` on it can differ by a slot.
  `capi-diff` found it; the error object on top and every status match.
- **`lua_setallocf` on our `lua`** (a state the Zig API made) changes only
  what `lua_getallocf` answers: `lua_Alloc` carries no alignment, so the
  engine's blocks cannot be freed through it.
- **`liblua.so`'s soname** is `liblua.so.5`.
- x86-64 and aarch64 Linux; macOS untested ("aarch64" above).

### Fuzzing

`just fuzz-capi SECONDS` builds the fuzz driver, `lua`, and
`test/fuzz/capifuzz.c` with `-Dc-api=true` into `zig-out/fuzz-capi`.
capifuzz's `run(ops)` reads four bytes per operation and makes one or a
few C-API calls for each, on eight registers that persist, noting what
they return (`test/fuzz/README.md`). `run capi` sweeps generated
workloads with the Nth allocation failing, once and from then on, for
every N, through `require` and the module's calls: "not enough memory",
no leak, no crash, the state usable after. `capi-diff` runs generated
workloads on our `lua` and the reference with the same `capifuzz.so`.
It found `lua_rawset`'s nil-key message ("index is nil" for "table index
is nil") and the dead coroutine's stack above.

## Costs, in brief

Detail and raw output in `results/c-api-20261031.md`.

- bench/ programs: −18.7% to −22.7% wall time against the reference (two
  code placements of the same build), with the default build at −23.0%.
  Zig builds glibc-linked code position-independent, which costs the
  interpreter loop one register for its jump table base.
- Peak RSS on bench/: −4.9% geomean against the reference (default:
  −37.8%; both read through `taskset`, which floored small programs
  at 2.3 MiB until wave 9). The floor, `lua -e ''`, is 3.02 MiB against
  the reference's 2.62 and the default's 1.49 (wave 9, without Zig's
  256 KiB signal stack: 2.69 and 1.22): dynamic glibc and ld.so map ~1.3 MiB the
  static build does not, and our executable's text (1.3 MB) is resident
  where the reference's is 300 KB. Wave 10: 1888 KiB, below the
  reference's 2564, with the text cut to 724 KB and the code startup
  needs first (`src/order.ld`): 156 KiB of it resident at exit instead
  of 800 (`results/lean-20261031.md`). Our allocators stay: glibc malloc
  saves 32 KiB at the floor and costs 10 to 60% peak RSS on the
  allocation-heavy programs.
- A call of an empty C function from Lua: 15.2 ns against 6.1 ns. About
  5 ns is the trampoline; the rest is our native call path against the
  reference's `precallC`. C → `lua_call` → Lua: 63 ns against 33.
  Wave 10: `CALL` sends C functions straight to `callNative`, not
  through `preCall`: an empty call 12.1 ns a loop iteration against
  the reference's 9.6 (base 14.4); net of the loop 8.6 against 5.2, of
  which the protected call per C function is 2.6 and `callNative` 2.8.
  C calls Lua: 51.3 ns against 30.6 (`results/lean-20261031.md`).
- Native stack per C → `lua_call` → Lua level: 1903 bytes against 351;
  `runLoop`'s frame is 1432 of it, the trampoline ~160. Wave 9: 656,
  with `runLoop`'s frame 272 (`results/stack-20261031.md`).
- Startup: 1.29 ms against the reference's 1.34 and the default's 0.80.
- lua-cjson and lpeg workloads run ~9% faster than on the reference,
  with 0.4 to 0.9 MiB more peak memory.

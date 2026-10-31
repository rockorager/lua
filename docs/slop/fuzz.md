# Fuzzing

Wave 7 added fuzzers (`test/fuzz/`, `just fuzz`, `just fuzz-stress`,
`just fuzz-zig`) and ran them. `test/fuzz/README.md` says what each checks;
this file is the design, what the runs found, and what is left. The runs
and their numbers are in `results/fuzz-20261031.md`.

## Design

- **Zig's fuzzer works here.** `std.testing.fuzz` with the default test
  runner and `zig build --fuzz=N` runs coverage-guided in this orb
  (`test/fuzz/zig_fuzz.zig`: the compiler, the loader, generated
  programs). It cannot run a subprocess per input or watch for hangs and
  memory, and a crash ends the run, so a standalone driver
  (`test/fuzz/main.zig`) does the rest.
- **Fork server.** In-process targets run in a forked child. Before each
  input the child copies it to a shared mapping, bumps a heartbeat, and
  sets a phase (load or run). The parent waits with `WNOHANG`: a signal
  or a nonzero exit is a crash or a bad outcome, a stalled heartbeat a
  hang. The input and the child's stderr (the panic message) are saved,
  the input minimized by delta debugging in fresh children while the
  kind and the panic's first line stay the same, and a new child resumes
  after the input.
- **Memory.** A counting allocator caps a state at 1 GiB (256 MiB for
  `binary`), so a chunk that wants unbounded memory gets "not enough
  memory"; `parse` also flags a peak above 64 MiB + 256 bytes per source
  byte. Subprocesses run under `prlimit --as=2GiB`. Leaks are bytes still
  counted after `close`.
- **Allocation failure.** `oom` fails the Nth allocation (growth by
  `resize` and `remap` counts) for every N until a run finishes without
  reaching N, once (later allocations succeed, then the state must still
  run a chunk) and from then on (then `close`, still failing, must free
  everything), over a `DebugAllocator`. 22 programs that cannot catch the
  error must end in `error.OutOfMemory` or "not enough memory"; the API
  scenario (globals, structs, userdata, bound functions, `decodeAlloc`,
  refs, `Values`, coroutines, binary `load`, `pcall`) the same; the
  `test/diff` programs, which catch errors and go on, may end any way but
  a crash, a leak, or an unusable state.
- **Line info on loaded chunks.** Since the line info moved to luac's
  encoding, line lookups promise to stay in bounds on a chunk whose line
  info nothing checked. `binary` calls `lineAt` at every pc,
  `changedLine` the way the line hook does, and the `nextLine` walk of
  `debug.getinfo`'s "L" on every function of each chunk that loads,
  while still in the load phase, and runs the chunk under a line hook. A
  crash whose first frame is in `Proto.zig` is a finding even while
  running.
- **Debug builds.** Object allocation skips the safe build's 0xAA fill,
  so a read of uninitialized or freed object memory does not show in
  ReleaseSafe. Runs meant to catch those use the Debug driver
  (`zig build fuzz -Doptimize=Debug --prefix zig-out/debug`).
- **Differential.** `diff` runs generated programs on both interpreters
  as files, so chunk names and tracebacks compare too; `bytecode` runs
  `luac -l -l -p` and `listing`; `messages` and `binary-diff` load 400
  inputs per process with one Lua runner on each side and compare line by
  line, grouping differences by message class. Differences are minimized
  by lines and then bytes, with a 3 s limit per run so a removed loop
  counter cannot stall it.
- **Generator** (`gen.zig`): typed expressions (integer, float, string,
  table, function, boolean) so most programs run to the end, risky
  operations inside `pcall`, string values cut to 40 bytes on assignment
  so loops cannot grow them without bound, loop counters the body cannot
  assign, and `.wild` mode for the compiler (deep nesting, 150 to 230
  locals, up to 270 upvalues, 200 to 600 constants, `global`). A program
  is a function of its seed: `fuzz gen SEED` prints it.

## Findings

Fixed, each with a regression test:

1. **A metamethod's result written to the freed stack** (`vm.zig`
   `getSlow`, `arithSlow`, `lenSlow`): `th.stack[dest] = try callTm(...)`
   takes the destination's address before the call, and a metamethod that
   grows the stack (any native one needs 20 free slots) moves it, so the
   result went to the old stack: `'0' + 1` in a frame near the stack's
   end gave `'0'`. Found by `diff`. Test: api_test.zig "a metamethod's
   result lands in the stack after the call moved it".
2. **The same in `pcall` after a `__close` error** (`vm.protectedCall`):
   `th.stack[func] = closeProtected(...)`, with the handler's call
   growing the stack; `pcall` returned whatever the new stack held there
   (a function). Same test.
3. **`setmetatable(t)` with no second argument** returned `t`; 5.5 raises
   "nil or table expected, got no value". `test/diff/base_lib.lua`.
4. **The length hint after a resize** kept the old hint where 5.5.1 sets
   `asize / 2`, so `#` on a table with holes found another border
   (`#{nil, 2, nil, 4}` gave 0, the reference 2). Both are borders; the
   reference's is the one to match. `test/diff/base_lib.lua`.
5. **Zero bytes in chunk names**: `lua_load` takes the name as a C string,
   so `load("x\0y")`'s name is `x`. Cut in `base.loadChunk`.
   `test/diff/load.lua`.
6. **Zero bytes in the standalone `lua`'s messages**: lua.c prints with
   "%s", and `luaL_traceback` pushes the message as a C string, so both
   stop at a zero byte. Cut in main.zig's `message` and the API's
   traceback handler. `test/diff/zero_byte_error.lua`.

Not fixed, by design or for size:

- **Message handler visibility.** The API's handler keeps the traceback
  beside the error object (`errorTraceback`), so the standalone `lua`
  differs where lua.c's handler is visible from Lua: a `__close` at the
  top level of a script gets the message without the traceback, and a
  "C stack overflow" raised while compiling (where lparser's error goes
  through the current `errfunc`) has none. Matching would mean a
  Lua-visible handler in main.zig that changes the error object.
- **"stack overflow" for metamethod recursion.** Metamethods run in the
  loop (decision 4), so `__index`/`__eq`/`__concat` functions recursing
  without end exhaust the Lua stack ("stack overflow") instead of 200 C
  levels ("C stack overflow").
- **Native stack use.** At the 200-level C limit ours needs 2 to 5 times
  the reference's native stack: measured with `ulimit -s`, `pcall`
  recursion 439 KiB against 175, `gsub` callbacks 839 against 431,
  `table.sort` comparators 703 against 127, nested `__close` 375 against
  87; the parser at its nesting limit 151 to 167 KiB against 79 to 95.
  The main thread's 8 MiB and Zig's 16 MiB thread default are far
  above that, but a host thread with 256 KiB crashes (SIGSEGV) on a
  hostile script instead of raising "C stack overflow" (`fuzz repro
grammar FILE --stack 256` reproduces). Shrinking the frames on the
  native call path, or a C-call limit scaled to the stack, would fix it;
  until then hosts should give a state 1 MiB of stack.

The known limit, recorded apart (`binary` writes them to `known/`):
corrupted chunks that load and then crash or hang when run. See
`results/fuzz-20261031.md` for the classes.

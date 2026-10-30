# VM: wave 2

What wave 2 added to the interpreter after the core (`core.md`): numbers
through `number.zig`, concatenation, to-be-closed variables, vararg tables,
coroutines with continuations, error messages that name variables, stack
overflow handling, and the debug library. Files: `vm.zig`,
`Thread.zig`, `State.zig`, `Value.zig`, `debuginfo.zig`,
`lib/coroutine.zig`, `lib/debug.zig`. Performance is in
`results/vm-wave2-20261030.md`.

## Decisions

### Numbers

- Every arithmetic helper is `number.zig`'s: floor division, modulo,
  shifts, exact int/float comparison, float-to-int with rounding, and the
  formatting `CONCAT` and `tostring` use. `^` calls `lib/libm.zig`'s `pow`
  (except `x^2`, which is `x*x` as in PUC-Rio) so results match the
  reference bit for bit. `Code.zig` still folds `^` with `std.math.pow`.
- Strings in arithmetic convert through the string library's metamethods,
  as in 5.5: the VM itself never converts a string operand of `+`, and
  bitwise operators on strings raise "attempt to perform bitwise operation
  on a string value", as the reference does. A numeric `for` converts
  numeric strings, as `forprep` does; anything else is "bad 'for' initial
  value (number expected, got table)".

### Errors

- A yield is `error.LuaError` with `Thread.status == .yield`; the error set
  did not grow. `vm.resumeThread` tells a yield from an error by the status.
- `Thread.throw` runs the active message handler (`Thread.errfunc`, a stack
  index) before anything unwinds, as `luaG_errormsg` does, and turns a nil
  error object into "<no error object>" after it. Every error a native
  raises must go through `throw` or `runError` for handlers to see it.
- Native-to-Lua nesting is `Thread.native_calls`, limit 200: past it
  "C stack overflow", and at 220 (while handling that) "error in error
  handling". The stack's limit is 1,000,000 slots plus 200 kept for
  handling "stack overflow"; a protected call that caught an error shrinks
  the stack back (`luaD_shrinkstack`'s rule).
- Variable names come from `debuginfo.zig`, a port of ldebug.c's symbolic
  execution (`getobjname`, `findsetreg`, `isEnv`, `funcnamefromcode`). Each
  slow path in `vm.zig` takes an `Origin` (stack slot, upvalue, or none) for
  the value it may complain about, so the fast paths pass nothing.

### Calls and continuations

- `Frame` is 32 bytes. A native frame's continuation (`Value.KFn`) lives in
  the storage of `pc`, which only Lua frames use, with its context in
  `extra_args`.
- `vm.callk`/`vm.pcallk` are `lua_callk`/`lua_pcallk`. When the thread can
  yield, a yield unwinds the Zig stack through the native, and the resume
  later calls the continuation in place of the rest of the native. An
  error inside a yieldable `pcallk` unwinds to `resumeThread`, which finds
  the frame by its `ypcall` flag, closes what the error left, and calls the
  continuation with `.err` (PUC-Rio's `precover`). Outside a coroutine, or
  when the thread cannot yield (`Thread.nny > 0`), `pcallk` is a plain
  protected call.
- Metamethod frames called from an instruction finish through `finishOp`,
  including `CONCAT`, `CLOSE`, and `RETURN` (closing variables), so yields
  cross them; `__close` handlers and `__concat` are yieldable.
- `coroutine.close` of the running coroutine (5.5) closes its variables and
  unwinds to the resume or to the `coroutine.close` that is closing it, as
  `luaD_throwbaselevel` does, flagged by `Thread.closed_self`. It passes
  through `pcall`/`xpcall` (built on `pcallk`); a native protected call made
  with plain `vm.pcall` cannot pass it on, so there it raises "attempt to
  yield across a C-call boundary" instead.

### Table access

- `SETFIELD` on a table with a metatable stores in place when the key is
  present with a non-nil value (`Table.replaceShortStr`, `luaV_fastset`'s
  rule), so `self.x = v` on an object no longer goes through `setSlow`.
- `GETFIELD`/`SELF` that miss on a table whose `__index` is a table look
  the key up there before calling `getSlow`: one level of method lookup
  inline. Deeper chains and `__index` functions still take `getSlow`.
- An arithmetic fast path that skips its `MMBIN` fetches past it in one
  step (`fetchSkip`), which keeps `pc` in its register.
- `fib` measured slower in wall time with fewer instructions: `execute`
  spills values the call path uses. Moving cold code out of `execute` is
  the next thing to measure.
- Measured in `results/vm-wave2-20261030.md`: `bench/methods.lua` went from
  1.45× the reference to parity.

### To-be-closed variables

- `Thread.tbc` is the list of slots with pending `__close`, so closing is a
  walk down the list, not a scan of the stack. `closeLevel` serves `CLOSE`,
  `RETURN` (results on top, `.ktop`), and errors (`.err`, in protected mode
  with `closeProtected`, where an error in a handler replaces the error
  object and closing goes on).

### Vararg tables

- `Proto.flags.vararg` is set for every vararg function; `vararg_table`
  means PF_VATAB: `VARARGPREP` packs the extra arguments into a table with
  `n`, and `VARARG` with k reads from that table ("vararg table has no
  proper 'n'").

### Debug library

- `lib/debug.zig` is ldblib.c. `getinfo` covers `SlnrtuLf`; `extraargs`
  counts the `__call` handlers a call went through (`Frame.flags.ncallmt`),
  and `ftransfer`/`ntransfer` are set only for a frame running a hook.
- `debuginfo.traceback` is `luaL_traceback`; `debuginfo.raise` and
  `debuginfo.argError` are `luaL_error` and `luaL_argerror` with call-site
  names, and `auxlib.zig` and `base.zig` use them.
- `registry._LOADED` holds `_G` and the libraries (`lib/init.zig`), which
  names functions in messages ("bad argument #1 to 'table.sort'") until a
  package library owns it.
- `vm.closeState` is what `lua_close` runs before freeing (the main
  thread's pending `__close` handlers), for `os.exit(code, true)`. The
  libraries' `base.Host` hangs off `State.host`, and carries the
  environment and `-E`.

### Hooks (wave 3)

- A thread has its own hook (`Thread.hook`, a `Thread.Hook`), mask, and
  count, as `lua_State` does; `vm.setHook` is `lua_sethook`, and a new
  coroutine inherits its creator's (`Thread.inheritHook`). `debug.sethook`
  keeps the Lua functions in `registry._HOOKKEY`, keyed weakly by thread,
  and installs `hookf`, which calls the thread's function.
- `vm.execute` runs one of two instances of the loop, `runLoop(th,
hooked)`. The unhooked instance's dispatch is the wave-2 loop with no
  check per instruction. Only code the loop calls out to can change the
  mask (a native, a metamethod, a `__close` or `__gc` handler), so each
  call-out's return point checks `hookSwitch`, and on a change the loop
  saves `pc` and returns to `execute`, which starts the other instance at
  the same frame and instruction. Lua-to-Lua calls and returns check
  nothing. Measured: `fib` and a 10^8 loop are within noise of the wave-2
  build, peak RSS unchanged (`results/hooks-20261030.md`).
- The hooked instance runs `traceExec` (`luaG_traceexec`) before each
  instruction, the call hook when a frame starts (`hookCall`; a vararg
  function's after `VARARGPREP`, then `oldpc = 1`), and the return hook in
  `doReturn` (`retHook`, which also sets `oldpc` for a Lua caller).
  Natives get call and return hooks in `callNative` and `posCall`. A
  general `RETURN` and a tail call of a native check the mask at run time
  in either instance, since a `__close` handler or the native may have set
  a hook just before the return event.
- Line events follow ldebug.c: a new line, or an instruction at or before
  the last traced one (a loop going around). Hooks run with `allowhook`
  off and the frame flagged `hooked` (getinfo names the hook "hook '?'");
  a protected call restores `allowhook` after an error (`Frame.flags.oah`
  for yieldable ones). Hooks cannot yield: `hookf` calls with `vm.call`.
- Errors loading a chunk (syntax, binary format, unreadable file) raise
  with `Thread.throwRaw`, which skips the message handler, as
  `luaD_throw` does; `dofile` re-raises through the handler.
- `main.zig` runs `pmain` as a native function in protected mode and calls
  each chunk with lua.c's `msghandler`, so uncaught errors print the
  reference's traceback, ending in "[C]: in ?".

## Not done

- Weak tables and finalizers, wave 3's collector work: `coroutine.lua`
  stops at line 478 on a weak table and `db.lua` at line 926 waiting for a
  `__gc`; with those cases cut, both run to "OK" (2026-10-30).

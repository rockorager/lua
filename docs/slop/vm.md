# VM: wave 2

What wave 2 added to the interpreter after the core (`core.md`): numbers
through `number.zig`, concatenation, to-be-closed variables, vararg tables,
coroutines with continuations, error messages that name variables, stack
overflow handling, the debug library, and binary chunks. Files: `vm.zig`,
`Thread.zig`, `State.zig`, `Value.zig`, `debuginfo.zig`, `undump.zig`,
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
- Measured in `results/vm-wave2-20261030.md`: `bench/methods.lua` went from
  1.40× the reference to parity.

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

### Debug library and binary chunks

- `lib/debug.zig` has everything but hooks: `sethook` accepts its arguments
  and never calls the hook, `gethook` returns nil. `getinfo` covers
  `SlnrtuLf` (`ftransfer`/`ntransfer` are 0); `extraargs` counts the
  `__call` handlers a call went through (`Frame.ncallmt`).
- `debuginfo.traceback` is `luaL_traceback`; `debuginfo.raise` and
  `debuginfo.argError` are `luaL_error` and `luaL_argerror` with call-site
  names, and `auxlib.zig` and `base.zig` use them.
- `registry._LOADED` holds `_G` and the libraries (`lib/init.zig`), which
  names functions in messages ("bad argument #1 to 'table.sort'") until a
  package library owns it.
- `undump.zig` loads luac 5.5.1 chunks with lundump.c's messages; `load`
  and `loadfile` use it. `dump.zig` writes them for `string.dump`,
  rebuilding the relative line information as lcode.c's `savelineinfo`
  does; a dump is not byte-for-byte luac's where the compiler's line
  fix-ups differ, but loads in both.

## Not done

- Hooks (`debug.sethook`): `coroutine.lua` (line 413) and `locals.lua`
  (line 851, through `checktable` at 625) assert on hook events. A hooked
  interpreter loop instantiated separately would keep the unhooked loop's
  dispatch as it is.
- Weak tables and finalizers (`coroutine.lua` line 478 checks a weak
  table); wave 3's collector work.
- The standalone `lua` runs the main chunk from the base frame, not from a
  native function as lua.c's `pmain`, so tracebacks lack the final
  "[C]: in ?" line and `debug.getinfo` levels are one short at the bottom.
- `io`, `os`, and `package` do not exist; messages that name them differ.

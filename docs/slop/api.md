# The embedding API (plan item 16)

`src/api.zig` is the API a Zig host uses; `src/root.zig` exports it at the
module's root, and the engine moved under `lua.internal` (`src/internal.zig`)
for the standalone `lua`, the bytecode lister, and the benchmarks.
`docs/embedding.md` is the human guide, `src/api_test.zig` the tests, and
`examples/host/main.zig` the example host. Settled by the owner: no C API, no
C modules; hosts extend Lua with Zig functions.

## Shape

- **`State` is an opaque handle to a `Thread`.** `init` returns the main
  thread; a Zig function Lua calls gets the coroutine running it. Every method
  is a pointer cast away from the engine, like `lua_State *`. `close` (not
  `deinit`: ziglint wants `deinit` to set `self.* = undefined`, which an
  opaque cannot) runs `vm.closeState`, flushes, and frees.
- **What it keeps beside the engine** (`Extra`, from the host's allocator,
  outside the counted heap): the libraries' `base.Host`, the last traceback
  text, `Options.context`, and the userdata metatable table. `State.host`
  points at `Extra.host`, so `extraOf` is one load and `@fieldParentPtr`.
- **Values cross as Zig types.** `toLua` and `decodeAny` are comptime
  switches over the Zig type. `Value`, `Table`, and `Function` wrap the
  engine's value in a field named `raw`, so their size follows the
  representation (16 bytes now, 8 if NaN-boxing lands) without the host
  seeing it. The API reads values only through `Value`'s inline functions;
  `api.zig` never touches `tag` or `payload`.
- **No stack API.** Results, arguments, and temporaries go on the thread's
  stack inside a call and come off before it returns.

## Lifetimes

The collector runs only at safe points (instructions, the return from a
native into a Lua frame) and on request, never inside an allocation. So a
value the API creates or returns stays valid until Lua code next runs, and
the rule for hosts is "borrowed until the collector runs; take a `Ref` to
keep it". Building nested values (`toLua` of a struct) needs no anchoring for
the same reason. The one conversion that allocates a value the host did not
ask for, a number decoded as a string, is anchored: in the argument's slot
(as `lua_tolstring` does) or above a running native's arguments.

Writes go through `Table.set`/`setStr`/`setInt`, `State.setMetatable`, and
`Userdata.create`, which carry their barriers, so the API never calls `gc`.

## Errors and protection

`Error` is `Runtime`, `Syntax`, `OutOfMemory`. The error object lives in
`Thread.err` (a GC root), so `errorMessage`/`errorValue` read it there.

- **Top level** (`frames.len == 1`, nothing running): every call into Lua is
  protected (`vm.pcallMsgh`), with a message handler when
  `Options.traceback` is on. The handler is lua.c's `msghandler`: it writes
  "message + stack traceback" into `Extra.trace`, or for an error object
  that is not a string or number and whose `__tostring` returns a string,
  that string alone, and returns the error object unchanged. On failure
  the error object moves to `th.err` and the stack is reset.
- **Status, not the message.** `vm.pcallMsgh` and `vm.pcallk` return
  `vm.Status` (`ok`, `runtime`, `memory`, `handler`: `LUA_OK`,
  `LUA_ERRRUN`, `LUA_ERRMEM`, `LUA_ERRERR`), and `vm.Resumed.err` says
  which error ended a resume. The kind comes from the Zig error
  (`error.OutOfMemory` is `memory`) and from `Thread.errerr`, which
  `errorInErrorHandling` sets and every other raise (`throw`, `throwRaw`)
  and every catch (`errorObject`) clears; `closeProtected` updates it when
  a `__close` handler raises over the error. The API maps `memory` to
  `error.OutOfMemory` and the rest to `error.Runtime`, so a Lua
  `error("not enough memory")` is `error.Runtime` now; wave 4 compared the
  object with the interned memerr string. Wave 6 finished the switch:
  `vm.pcall` returns the `Status` too, and every caller tests it
  (`auxlib.testing.call`, `gc`'s finalizer call, `load`'s reader, which
  passes a memory error on as `error.OutOfMemory`). A coroutine that dies
  keeps its kind in `Thread.died` (a dead coroutine's `lua_status`), and
  `vm.closeThread` returns a `Status` that starts from it and takes a
  `__close` handler's error over it, as `lua_closethread` does; so
  `coroutine.wrap`'s `auxWrap` adds a position unless closing says
  `.memory`, lcorolib's `LUA_ERRMEM` test. One divergence stays on
  purpose: the reference's `lua_error` turns an error object that _is_
  the memerr string into a memory error, so
  `error("not enough memory", 0)` is `LUA_ERRMEM` there (unpositioned
  through `wrap`, no message handler, `lua_pcall` returns `LUA_ERRMEM`);
  here only a failed allocation is one. `error("not enough memory")` at
  the default level carries a position and is an ordinary error in both.
- **Inside a Zig function**: `call` is unprotected (`vm.call`), so an error
  propagates to Lua's caller with its traceback and handlers intact when the
  host `try`s it, and costs nothing extra. On error `call` leaves the stack
  alone: the frames the error unwinds stay intact until the protected call
  that catches it, as a `longjmp` leaves them, so `debug.traceback` of a
  coroutine that died there sees them (resetting `top` let later pushes
  overwrite a frame's function slot, and `funcName` asserted). Catching
  that error in Zig and going on would leave those frames behind, so
  `pcall` is the API for handling an error in Zig: protected at any level,
  with the message handler and `Extra.trace`. The native wrapper maps
  `Runtime`/`Syntax` back to `error.LuaError` (the object is already in
  `th.err`), `OutOfMemory` to itself, and any other Zig error to a Lua error
  with the error's name, positioned like `luaL_error`.
- **Metamethods at the top level**: `getField`, `setField`, `getGlobal`,
  `setGlobal`, and `toString` take the raw path when it answers (a table hit,
  or no `__index`/`__newindex` by `fastTm`), and otherwise run the engine's
  operation inside a protected native trampoline (`protect`), so an error in
  `__index` cannot leave frames behind.
- Conversion failures raise through `debuginfo.raise`/`argError`, so inside
  natives they are Lua errors with the reference's text, and at the top level
  they set `th.err` with no position.

## Zig functions

`Native(f)` generates a `Value.NativeFn` per Zig function. Parameters decode
with `checkArg`, results push with `pushResults`. Messages are lauxlib's:
`luaL_checkinteger` ("number has no integer representation"),
`luaL_checkoption` ("invalid option 'x'"), `luaL_checkudata` ("T expected,
got U"), `luaL_checkany` ("value expected"), with the call site's name and
"?" as the fallback, as `luaL_argerror` gives. Smaller integer types add
"value out of range" (lstrlib's wording). A struct parameter decodes a table
and names the field: "bad argument #1 to 'f' (field 'x': number expected,
got nil)".

Two codegen lessons, both from `perf annotate` on the benchmark:

- **Decode the exact type inline, everything else out of line.**
  `decodeFast` handles a value that already has the Zig type's Lua type with
  one tag check and no decoder; `decodeAny` (non-inline, with the message
  machinery) handles conversions and errors. Field paths for messages are
  `Crumb`s linked on the Zig stack and written out only on failure; building
  the path text eagerly cost decode_struct 50%.
- **Store forwarding, again.** A `?Function` built from narrow stores and
  read back as 16 bytes, and an `Error!u32` returned through memory from a
  non-inline `pushResults`, each stalled the callback benchmark by ~5 ns.
  `checkArg` copies handle types straight from the slot, and `pushResults`
  is inline and returns the engine's error set. The hot-path rule in the plan
  ("copy values field by field") applies to the API's wrappers too.

## Any number of values

`Values` is `[]const Value` over the thread's stack slots (`Value` is
asserted to be `IValue`'s size with `raw` at offset 0). A call returning
`Values` asks for all results (`nres = -1`) and keeps them on the stack:
`top` stays above them, so they stay rooted and no push lands on them,
and the running frame records them in `extra_args` (start; 0 for none) and
`old_errfunc` (end). Frames without a continuation, which every Zig
function's frame and the base frame are, use neither field. The next
`call`, `pcall`, or `resume` from that frame drops them (`dropKept`: `top`
back to the start, if nothing was pushed above). Keeping them in the frame
means a stale record goes away with its frame; a record in `Extra` keyed by
thread could outlive a collected coroutine and match a new thread at the
same address. Without the drop, a Zig function asking for `Values` in a
loop grows the stack until it returns (the test calls one 400,000 times).

The first version left them above `top`, unrooted. Then `decode` of a
number as a string inside a Zig function pushed its anchor over them, and
a metamethod run by `getField` at the top level overwrote them; the
contract would have been "valid until the next API call", which forbids
reading a second value with `decode`.

`Values` as arguments, in place of the tuple, are copied with `@memmove`,
because they usually are the previous call's results sitting where the
new call goes; `stackIndex` notes where they sit before `ensure` can move
the stack. A Zig function returning `Values` pushes them the same way.
Elsewhere a `[]const Value` is still a slice: a struct field converts to a
sequence, and `decodeAlloc` builds one.

## Bound functions

`State.function(ctx, f)` is a native closure with one upvalue: a light
userdata for a pointer, or a userdata holding a copy of any other value
(no metatable; `f` takes it by value or by pointer). `Native(f, C)` reads
`stack[b - 1]`'s upvalue, as lauxlib natives read `lua_upvalueindex(1)`.
The unbound wrapper is `Native(f, void)`, so `lua_calls_zig` compiles as
before. As with C closures, `debug.setupvalue` can replace the upvalue
with something else; the debug library is not for sandboxes.

## Coroutines

`Coroutine` wraps a `*Thread`. `newCoroutine` is `coroutine.create`.
`resume` copies the arguments onto the coroutine, anchors it on the
caller's stack while it runs (a borrowed handle may be all that reaches
it), and calls `vm.resumeThread` with the caller as `from`. Results come
off the coroutine's stack (`resume` needs it clean), so as `Values` they
are above its `top` and valid until the next call that runs Lua. On error
the object moves to the caller's `th.err` and, with `Options.traceback`,
`debuginfo.traceback` of the dead coroutine at level 0 goes into
`Extra.trace`. `resume` is a Zig keyword, so the method is `@"resume"`, as
`lib/coroutine.zig` names its native.

`State.yield(values)` pushes the values and returns `vm.yield`'s error,
which the native wrapper passes on as `error.LuaError` with the thread's
status `.yield`; a resume makes the native's frame return the resume's
values (`resumeBody` with no continuation). So a Zig function may yield
only as its return, which is `lua_yield` without `lua_yieldk`. Full
continuations would need the wrapper to rebuild the Zig function's state
from the stack; out of scope.

`Coroutine.status` is `coroutine.status` (`lib.coroutine.coStatus`,
re-exported as `Coroutine.Status`). `Coroutine.close` is
`coroutine.close` for a suspended or dead coroutine: it anchors the
coroutine on the caller's stack while `__close` handlers run, and moves
the error to `th.err`, `.memory` mapping to `error.OutOfMemory` (the
kind comes from `Thread.died`). A running or normal coroutine is
refused with lcorolib's "cannot close a %s coroutine"; closing the
coroutine that runs the Zig function, which `coroutine.close` does by
unwinding to the resume (`vm.closeSelf`), would need the Zig function to
return that unwinding, so the API leaves it to Lua.

## Unknown keys

`DecodeOptions.unknown_keys = .reject` scans a struct's table after its
fields are read and fails on the first key that is not a string naming a
field, with the path built from the same `Crumb`s: "unknown key
'keybinds[2].acton'". Only struct reads check; tuples and arrays ignore
entries past their length. The example host's `readConfig` rejects.

## Output

`base.Host.stdout` is a `*std.Io.Writer`; `Host.file_stdout` is the
process's `File.Writer`, which it points at unless `Options.stdout` says
otherwise. `print` and `io.stdout` write through `stdout`; `io.stdout`'s
errors and `seek` use `file_stdout`, and `seek` on a redirected stdout
fails with ESPIPE ("Illegal seek"). `State.stdout()` returns the writer,
so a host (the standalone `lua` for its prompts and `-v`) writes in order
with the script.

## Userdata

`newUserdata(T, v)` allocates a `Userdata` with no user values and gives it
`T`'s metatable, built on first use from the optional `T.lua_userdata`
declaration (`.name`, `.methods` as `__index`, `.meta`). A pointer the API
returned converts back with `Userdata.fromBytes`, checked in safe builds.

Type checks compare the userdata's metatable with `T`'s by identity.
Metatables live in `Extra.types` (a table the registry holds) at index
`typeId(T)`, a process-wide number per Zig type handed out on first use, so
the check is an array read. The alternative measured, a registry lookup
keyed by a light userdata per type (`luaL_checkudata`'s shape with a pointer
key), is 38.8% slower on userdata_method (41.5 ns against 57.6 ns,
`results/api-20261031.md`). A tag inside the metatable (`mt[1] = key`) would
be cheaper still, and was rejected unmeasured: sandboxed Lua can copy the tag
into another userdata type's metatable and forge a `*T`.

## References

`ref`/`unref` are `luaL_ref` in the registry: a free list headed at
`registry[3]`, references from 4 up, `Ref.nil` for nil.

## Libraries

`lib.openSome(th, host, EnumSet(Lib))` opens a chosen set in linit.c's order
(`openLibs` is `openSome` with all). Without `Options.io` the state gets
`std.Io.failing`, which fails file operations cleanly but hits `unreachable`
on `isTty`, `close`, and `lockStderr`; the `io` and `os` libraries call those,
so they require `Options.io` and the default set without it is `safe_libs`.
`print` and `warn` under `failing` print nothing, unless `Options.stdout`
gives `print` a writer.

## The standalone `lua` on the API

`src/main.zig` imports only the API (and `SmallAllocator`). `pmain` is a
Zig function bound to the interpreter's state with `State.function` and
called from the top level; inside it each chunk runs with `pcall`, whose
message handler is lua.c's. What it needed became API:

- `State.pcall`: lua.c's `docall` is a `lua_pcall` inside `pmain`.
- `State.function(ctx, f)`: `pmain` gets the interpreter as its context.
- `Values`: the REPL prints a line's results; a script gets `arg[1..n]`.
- `loadFile(null, ...)`: `lua -` and a script read from a pipe.
- `Options.noenv` (`-E`), `Options.gc_mode` (lua.c runs generational),
  `Options.gc_stress` (the `-Dgc-stress` build), `State.warn` (`-W`), and
  `State.stdout` (the prompt and `-v` go through `print`'s writer).

Nothing stays internal. Behavior that changed toward lua.c on the way:
an error in `_PROMPT`'s `__tostring` now ends the program as lua.c's does
(the old port cleared it), printed without the program name because the
REPL had cleared it; a `__tostring` returning a non-string makes the
message handler fall back to "(error object is a table value)" and a
traceback; "error calling 'print' ((null))" for a non-string error object;
and `pmain` gets `argc` as lua.c's does, so a stack overflow traceback
counts the same levels ("skipping 999970 levels"). `-l` uses
`getGlobal`/`setGlobal`, with metamethods, as lua.c's
`lua_getglobal`/`lua_setglobal` do. The `#arg` count goes through
`State.len` (`luaL_len`, with `__len`), truncated to a C int and refused
past the stack's limit with lua.c's "stack overflow (too many arguments
to script)"; a negative count, undefined behavior in lua.c, passes
nothing.

## A compiler crash to avoid

Zig 0.16 segfaults when it lowers to runtime memory the `fields` slice of
a struct type that has a field with a function default value (a function
body, which is comptime-only). An anonymous struct literal holding a
function (`.{ .get = get }`) has such a field, as a comptime field. So
binding `@typeInfo(T).@"struct".fields` to a `const` and using it at
runtime crashes; `@typeInfo(T).@"struct".fields.len` written inline does
not, because nothing is materialized. Iterate
`comptime std.meta.fieldNames(T)` and use `@field` instead
(`newMetatable`, `isFieldName`). The minimal reproduction, which crashes
`zig build-obj repro.zig` with a segmentation fault in Zig 0.16.0
(x86_64-linux):

```zig
fn get() void {}
const S = struct { f: fn () void = get };
const fields = @typeInfo(S).@"struct".fields;
export fn entry() usize {
    return fields.len;
}
```

Variants checked: a `const` inside the function crashes too, as does
`comptime` on it and `inline for` over it; `struct { f: fn () void }`
without the default, a pointer field `*const fn () void = get`, and a
`u8` field with a default compile.

## Measurements

`results/api-20261031.md`: `just bench-api`, the API against the internal
path as the standard library writes it. `results/api-wave5-20261031.md`:
this wave's API against wave 4's, the new scenarios (`lua_calls_bound`,
`call_values`, `zig_resumes`) against their internal versions, and the
standalone `lua` on the API against the one on the engine.

## Open questions

- Decoding interns every field name on every call (most of decode_struct's
  time, on both arms); a per-type cache of the interned names would help
  config-heavy hosts. Skipped in wave 5: decode's cost does not justify it
  yet.
- Zig functions that yield in the middle (continuations).

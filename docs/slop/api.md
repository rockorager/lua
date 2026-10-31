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
  `Options.traceback` is on. The handler writes lua.c's "message + stack
  traceback" into `Extra.trace` and returns the error object unchanged. On
  failure the error object moves to `th.err` and the stack is reset.
  `vm.pcall` reports a memory error as the fixed memerr string, so a Lua
  `error("not enough memory")` (interned to the same string) reads as
  `error.OutOfMemory` at the top level; a known, accepted divergence.
- **Inside a Zig function**: calls are unprotected (`vm.call`), so an error
  propagates to Lua's caller with its traceback and handlers intact when the
  host `try`s it, and costs nothing extra. The native wrapper maps
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
`print` and `warn` under `failing` print nothing.

## A compiler crash to avoid

Zig 0.16 segfaults when `@typeInfo(T).@"struct".fields` of a struct with
function-valued comptime fields (`.{ .get = get }`) is bound to a runtime
`const` and iterated. Iterate `comptime std.meta.fieldNames(T)` and use
`@field` instead (`newMetatable`).

## Measurements

`results/api-20261031.md`: `just bench-api`, the API against the internal
path as the standard library writes it.

## Open questions

- Coroutines from the host: resuming a Lua coroutine from Zig, and Zig
  functions that yield (the engine has `vm.callk`/`yieldk`; the API exposes
  neither).
- Zig functions with upvalues (closures); `Options.context` and userdata
  cover per-host and per-object state for now.
- A return type for a variable number of results.
- Raw `rawGet`/`rawSet`; `decode` reads tables raw, and `getField` uses
  metamethods.
- Rejecting unknown keys when decoding a config struct.
- Decoding interns every field name on every call (most of decode_struct's
  time, on both arms); a per-type cache of the interned names would help
  config-heavy hosts.
- `print` writes to the process's stdout through `Options.io`; a host that
  wants it elsewhere replaces the global `print`. `base.Host.stdout` is a
  `File.Writer` because `io.stdout` shares it.
- Porting `main.zig` to the API; it stays on the engine because it needs
  lua.c's exact REPL and message handling.

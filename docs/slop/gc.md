# The collector: wave 3

`src/gc.zig` is a port of Lua 5.5.1's `lgc.c`, function by function, the
way `Parser.zig` ports `lparser.c`: the same states, lists, colors, ages,
barriers, and pacing arithmetic, so the reference's behavior (which object
a weak table loses, when a finalizer runs, when a step ends a cycle, when
generational mode switches between minor and major collections) is ours.
Numbers are in `results/gc-wave3-20261030.md`.

## Decisions

### Objects and lists

- `Header` stays 16 bytes: `next`, `tag`, `marked`. `marked` has lgc.h's
  layout: three age bits, two whites, black, and the finalized bit.
- Objects live on four lists, as in the reference: `allgc`, `finobj`
  (objects whose metatable had `__gc` when it was set), `tobefnz` (found
  dead, waiting for their finalizer), and `fixedgc` (the metamethod names,
  "not enough memory", "\_\_name", "n": `gc.fix`, gray and old forever).
  The old `mark.fixed` bit is gone.
- `gc.objects(heap)` iterates every list, for code that must see every
  object (`io.flushAll`).
- Short strings leave the interner when they are freed
  (`Interner.remove`, `luaS_remove`), and `intern` brings back a string that
  is dead but not swept yet, so sweeping can be incremental. The interner
  halves its buckets when a quarter or less is used (`checkSizes`).

### Roots and the stack

- A thread is marked below its `top` only, as in the reference, and in the
  atomic phase the slots above become nil. That is what makes a dead local
  in a stale register collectable (`gc.lua` line 286 checks it). It relies
  on `top` being exact at every safe point: the VM sets `top` to `ra + 1`
  before a step at `NEWTABLE` and `CLOSURE` (lvm.c's `checkGC(L, ra + 1)`),
  to the parameters and the vararg table at `VARARGPREP`, and `CONCAT` and
  native calls leave it exact. Every thread that is not running has a
  native frame innermost (a resume or a yield), whose `top` is exact.
- Threads with open upvalues are on `Heap.twups` (`Thread.twups` points at
  the thread itself when it is off the list), for `remarkUpvals`.
- Roots: the main thread, the registry, the globals, the basic types'
  metatables, objects waiting for finalization, and in the atomic phase the
  running thread.

### Safe points

- `State.checkGc(th)` / `State.gcDue()` plus `gc.step(th)`: at `NEWTABLE`,
  `CLOSURE`, `CONCAT`, `VARARGPREP` with a vararg table, and when a native
  function called from a Lua frame returns having allocated (the heap grew
  while it ran, not counting its frame and stack). The last stands in for
  the reference's API functions that call `luaC_checkGC` when they
  allocate; a native that allocates nothing (such as `next` in a `pairs`
  loop) does not step. Checking after every native call made `hash_int`
  run a minor collection inside its `pairs` loop, so a table aged before
  it died and waited for the next pass: 9.0 MB peak RSS against the
  reference's 8.5 MB, 6.0 MB with the check.
- A step can run finalizers, so the VM reloads its frame pointer and
  `base` after one.
- `Heap.debt()` is lgc.c's `GCdebt` as `threshold - bytes`; the check in
  the VM is still one compare of `bytes` with `threshold`.

### Barriers

- `gc.barrier` (forward, for upvalues, closures, user values, and
  metatables) and `gc.barrierBack` (backward, for tables) are inline
  color checks with a `noinline` slow path, as `luaC_barrier` and
  `luaC_barrierback`. `State.setMetatable` (and so `setmetatable`,
  `debug.setmetatable`, io's handles) uses the forward barrier, as
  `lua_setmetatable` does.
- Closing an upvalue (`Thread.closeUpvals`) calls `gc.closeUpval`: a closed
  upvalue cannot stay gray (`luaF_closeupval`).

### Weak tables and finalizers

- `__mode` is read through the metatable's absence cache
  (`State.fastTm(mt, .mode)`), as `gfasttm` does; a non-string mode is
  ignored, and the mode string is searched up to its first zero byte.
- Ephemerons converge as the reference's, alternating direction. Weak
  entries are cleared by values before finalizable objects are separated
  and by keys after resurrection, so a resurrected object is gone from weak
  values but stays as a weak key until it really dies. Strings are never
  weak-collected. A cleared node keeps its key as `dead_key`, so `next`
  goes on from it.
- `gc.checkFinalizer` runs when a metatable is set (`State.setMetatable`),
  so a `__gc` field added later does not count. Finalizers run in the
  order objects were separated (reverse order of `setmetatable`), each on
  the thread that took the step, with the collector stopped, hooks off
  (`Thread.allowhook`), and the calling frame flagged `fin` so
  `debug.getinfo` names it "\_\_gc", a "metamethod" (`CIST_FIN`). The call
  goes above the running Lua frame's registers. An error becomes the
  warning "error in \_\_gc (msg)" through `State.warnf`, which the base
  library points at its warning function.
- `vm.closeState` (from `os.exit(code, true)`, the standalone `lua` before
  it flushes, and `State.destroy`) closes the main thread's pending
  variables and then calls every pending finalizer, once
  (`gc.callAllFinalizers`, `luaC_freeallobjects`).
- `collectgarbage` inside a finalizer or while the state closes returns
  fail (nil), as `lua_gc` returning -1 makes lbaselib do; `"param"`
  returns -1.

### Modes and parameters

- One divergence in pacing: an automatic incremental step pays for every
  byte allocated since the last step (`stepmul` percent of the debt, in
  words), and goes through the atomic phase when the debt was more than
  two steps, where lgc.c's `incstep` always does one `stepsize` worth and
  stops at the atomic phase. The reference's natives check the collector
  at each allocation (a `luaL_Buffer` growing checks a dozen times while
  `table.concat` builds 3 MB); ours check once when they return, so
  without this the collector fell behind after big natives. With the
  usual debt of about one step the two are the same, and
  `collectgarbage("step", n)` takes the reference's step, so it reports
  the end of a cycle when the reference does. `hash_string` went from
  31.7 MB to 25.5 MB peak RSS with it.

- Incremental steps, the pause, the step multiplier and size, and
  generational minor/major switching are lgc.c's, with its default
  parameters (`minormul` 20, `majorminor` 50, `minormajor` 70, `pause`
  250, `stepmul` 200, `stepsize` 200 × 48 bytes, the reference's
  `sizeof(Table)`), coded in its floating-point bytes. They live in
  `Heap.params`; `lib.base.Host` no longer has collector state.
- The standalone `lua` switches to generational mode at startup, as
  lua.c's `pmain` does; an embedded state starts incremental.
- No emergency collections: allocation failure is "not enough memory"
  without a collection, because a collection inside an allocation could
  see an object half built. `Heap.emergency` exists for `fullGc`'s
  parameter only.
- `luaD_shrinkstack` in the atomic phase is left out: shrinking a stack a
  native function holds slices of is not safe here.

### Testing hooks

- `Heap.stress` collects fully at every safe point; `Heap.stress_step`
  takes one indivisible incremental step (one gray object, or 20 objects
  swept) at every safe point, so marking interleaves with the program as
  finely as it can. Under either, `setDebt` keeps the debt at zero, so
  the stress starts at the first safe point. `State.Options.gc_stress`
  sets them, and `zig build -Dgc-stress=full|step` builds a `lua` with
  them on. Removing `barrierBack` makes the `step` build fail `gc.lua` and
  crash `calls.lua` within seconds, so it does catch missing barriers.
- In generational mode the `step` build runs a minor collection at every
  safe point, so an object kept in registers across three safe points
  becomes old and waits for a major collection that a loop of short-lived
  tables never triggers. `db.lua` (alone or in `all.lua`) therefore spins
  at `repeat local a = {} until name`, its finalizer test, whose object
  became old before `setmetatable` gave it a `__gc`; the reference's aging
  rules do the same. Every other file passes under it, every file passes
  under `step` in incremental mode, and every file and `all.lua` pass
  under `full`.

## Not done

- External strings (`lua_pushexternalstring`).
- Emergency collections, stack shrinking in the atomic phase.
- The string object is 40 bytes before its contents (the reference's is
  24), which is most of `hash_string`'s extra memory together with the
  allocator's power-of-two size classes; see the results file.

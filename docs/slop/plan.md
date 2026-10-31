# Plan

Lua 5.5.1 in Zig, with no C, as fast as reference C Lua or faster. The bar is
the official suite in `test/lua-5.5.1-tests/` (18,000 lines over 33 files),
run with `_U=true`, plus differential runs against the reference `lua` in the
dev shell. This file is the architecture, the performance decisions to
measure, and the order of work. Update it when a decision lands.

## Shape

```
source --Lexer--> tokens --Parser--> Proto (bytecode, constants, nested protos)
Proto + upvalues = Closure
State: one per Lua universe (heap, string table, registry, globals, metatables for basic types)
Thread: one per coroutine (value stack, call frames, open upvalues, status)
vm.zig: the interpreter loop over one Thread's frames
lib/: the standard library, written against the internal API
main.zig: the standalone `lua` program, which the suite runs, on the embedding API
```

One pass from source to bytecode, as PUC-Rio does: the parser emits code as it
parses, with register allocation, constant folding, and jump patching. No AST.
That is the fastest route to bytecode and keeps the compiler small.

## Decisions, and how each gets decided

Each item names a starting choice. Items marked **measure** get an A/B write-up
in `docs/slop/results/` once the VM runs the benchmarks, and the plan is
updated with the winner.

Wave 1's core implements the starting choices of 1 through 9 and 11.
`docs/slop/core.md` records the details these items left open, and
`docs/slop/results/core-baseline-20261030.md` the first numbers against the
reference.

1. **Value.** Start with a 16-byte tagged value: an 8-byte payload (i64, f64,
   pointer, bool, light userdata) and a 1-byte tag, the shape PUC-Rio uses.
   Every access goes through `Value`'s inline functions so the representation
   can change in one file. Settled in wave 4: the 16-byte value stays. A
   NaN-boxing prototype (47-bit payloads, integers beyond 47 bits boxed,
   20-byte nodes, 8-byte array slots) was 7.1% slower on the geomean and
   peaked 9% higher: integer paths pay to unpack and range-check, and a
   growing array part must write nil into every new slot where 5.5's compact
   layout writes one tag byte. Only coroutines (−12%, half-size stacks) and
   hash_int (−13% RSS) gained. A complete version would also make
   `Value.int` need a heap and integer arithmetic allocate
   (`results/nanbox-20261031.md`).
2. **Instructions.** 32-bit instructions in Lua 5.4/5.5's formats (iABC with
   the k bit, iABx, iAsBx, iAx, isJ) and an opcode set modeled on 5.5's,
   including the specialized forms (`ADDI`, `ADDK`, `GETFIELD`, `GETI`,
   `EQK`, `FORPREP`/`FORLOOP` for numeric loops, `TFORCALL`). Specialized
   opcodes are where most of PUC-Rio's speed comes from; copy the design, not
   the code. Landed: the set, numbering, and encoding are 5.5.1's exactly, so
   `luac -l -l` output is the compiler's reference (`src/opcodes.zig`).
3. **Dispatch.** A labeled `switch` with `continue :dispatch`, which Zig
   compiles to threaded dispatch: one indirect jump per opcode, each with its
   own branch history. Keep the hot registers (pc, base, the constant array)
   in locals of the loop function, and reload `base` only after anything that
   can reallocate the stack. Measured in wave 4: a plain loop-and-switch (one
   shared indirect jump) is 9.0% slower on the geomean, mandelbrot 33%, peak
   RSS level (`results/dispatch-20261031.md`).
4. **Calls.** A Lua-to-Lua call pushes a frame and continues the same loop: no
   Zig recursion, so deep Lua recursion costs heap, not Zig stack. Frames refer
   to the stack by index, because the stack reallocates when it grows.
   Metamethods called from an instruction (`__index` functions, arithmetic,
   `__eq`, `__lt`, `__concat`, `__close`) push a frame and record how to finish
   the instruction when it returns, as PUC-Rio's `luaV_finishOp` does. That
   keeps them yieldable and off the Zig stack. Landed in wave 3: `CALL` and
   `TFORCALL` call a native function directly (`results/vm-native-calls-20261030.md`),
   and `RETURN0`/`RETURN1` take the caller's frame as the one below without
   reloading the frame list (`results/vm-returns-20261030.md`, fib −10%).
   Setting the callee's `cl`/`k` in `CALL` instead of going through
   `newframe` was slower: they become loop-wide variables and spill.
5. **Errors.** A Lua error is the Zig error `error.LuaError`, with the error
   object held in the thread. It unwinds through Zig with ordinary error
   returns and stops at the nearest protected boundary (`pcall`, `xpcall`,
   `coroutine.resume`, the top of the program). Out of memory becomes a Lua
   error with the message "not enough memory", as the manual requires; never
   panic on allocation failure.
6. **Coroutines.** Each coroutine is a `Thread` with its own stack and frames.
   `resume` runs the loop on that thread; a `yield` from Lua code returns from
   the loop to `resume`. Native functions that call back into Lua (`pcall`,
   `xpcall`, `dofile`, the `table`/`string` functions that call metamethods)
   take a continuation, like `lua_callk`, so yields cross them. Yields across a
   native function without a continuation raise "attempt to yield across a
   C-call boundary", as in PUC-Rio. Landed: `vm.callk`/`vm.pcallk` with
   `Value.KFn` continuations, `lib/coroutine.zig`, and yieldable `pcall`
   and `xpcall`; `vm.md` has the details.
7. **Strings.** Short strings (40 bytes or fewer) are interned in a hash set
   owned by the `State`, so equality is pointer equality. Long strings are not
   interned and hash lazily. A string is one allocation: header, hash, length,
   bytes, and a trailing zero. Landed in wave 3: PUC-Rio's `TString` layout,
   32 bytes (a short length byte, and a union of a long string's length and a
   short string's intern link); `State.Options.strings` gives strings their
   own allocator, and the `lua` executable passes `SmallAllocator` (classes 8
   bytes apart up to 128). A general size-class allocator for every object was
   measured and rejected: closures, prototypes, and short arrays off 32-byte
   boundaries cost call-heavy programs 20–30%. A long `auxlib.Buffer` result
   becomes its string in place, as 5.5's `luaL_pushresult` does with an
   external string (`results/strings-20261030.md`,
   `results/buffer-strings-20261030.md`, `results/allocator-20261030.md`).
   5.5's external strings as an API (bytes the collector does not own) come
   later.
8. **Tables.** An array part and a hash part. The array part uses 5.5's
   compact layout: payloads and tags in separate runs, 9 bytes per slot instead
   of 16. The hash part starts as PUC-Rio's chained scatter table with Brent's
   variation (a power-of-two node array, collisions chained through free nodes),
   because `next` must survive assignment to existing keys during traversal.
   Cache `__index`/`__newindex` and friends' absence in a per-table flag byte, as
   PUC-Rio does, so the common case skips the metatable lookup. Settled in
   wave 5: the chained table stays. Linear probing and Robin Hood, each
   growing at 7/8 load or full, were 2.5 to 9.9% slower on the geomean
   (hash_string +19% to +162%, hash_int +13% to +17%), and the ones growing
   at 7/8 peaked up to 4.3% higher (binary_trees). With Brent's variation
   most keys sit in their main position, so a hit at load 0.76 looks at
   about 1.4 nodes against linear probing's 2.6, and the chain link fits
   in the node's padding (`results/table-hash-20261031.md`).
9. **Collector.** Precise and non-moving. Every collectable object starts with a
   common header (next pointer, tag, mark bits). Start stop-the-world
   mark-and-sweep, but call the write barrier at every store into a table,
   upvalue, or userdata from the first commit, as a no-op, so incremental
   marking lands without touching every call site. Then weak tables,
   ephemerons, `__gc` finalizers, and `__close`; then incremental, with 5.5's
   incremental major collections; then generational mode. Allocation goes
   through the state's allocator with byte accounting, for
   `collectgarbage("count")` and pacing. Landed in wave 3: `gc.zig` ports lgc.c
   function by function (weak tables and ephemerons, finalizers,
   incremental steps with 5.5's parameters, real barriers, 5.5's
   generational mode and its incremental major collections); `gc.md` has
   the decisions and the divergences, and
   `results/gc-wave3-20261030.md` the speed and peak memory against the
   reference.
10. **Numbers.** i64 and f64, with the manual's conversions (§3.4.3): exact
    integer-float comparison, floor division and modulo with Lua's signs, shifts
    that saturate at 64, string coercion. Floats print in decimal with enough
    digits to read back exactly (new in 5.5). Landed in `number.zig`: 5.5.1
    does not print the shortest round trip but `%.15g`, then `%.17g` when that
    does not read back (`0.1 + 0.7` is `0.79999999999999993`), so
    `formatFloat` takes Ryu's shortest digits when they are 15 or fewer and
    rounds exactly with a small bignum otherwise; subnormals always take the
    exact path.
11. **`global`.** The reference builds with `LUA_COMPAT_GLOBAL`, so `global`
    lexes as a name and lparser.c treats it as a declaration only when the
    next token is a name, `<`, `*`, or `function`. `Lexer.zig` does the same
    (`global_is_reserved = false`); the parser owns the lookahead check.
12. **Native functions** take the thread and the index of their first argument
    and return how many results they pushed. Landed:
    `fn (*Thread, base: u32) Error!u32`, `Value.NativeFn`.
13. **The compiler matches luac.** Landed: `Parser.zig` and `Code.zig`
    translate lparser.c and lcode.c function by function, so the bytecode,
    constants, upvalues, locals, line info, and `maxstacksize` are the
    reference's, instruction for instruction. `just bytecode` diffs our
    listing (`zig build listing`, `Code.writeListing`, luac's
    `PrintFunction` format) with `luac -l -l -p` for every suite and bench
    file, addresses masked: 54 of 54 identical. Keep it that way; a
    deliberate divergence goes in the recipe with the reason. Line info is
    luac's encoding (`Proto.lineinfo`, a byte per instruction, and
    `Proto.abslineinfo`), built as lcode.c builds it and decoded by
    `Proto.lineAt` as `luaG_getfuncline` does. Landed in wave 7: against
    one absolute `u32` per instruction, bench/config.lua's compiled chunk
    holds 184 KiB less (850 to 666 KiB; the reference's 630), every suite
    and bench file loaded together 15% less, and compile time, line
    hooks, and error positions are unchanged
    (`results/lineinfo-20261031.md`). Wave 6 took two store forwarding stalls out
    of the compiler, the token returned by value and the constant
    cache's generic hash: building and loading a large table constructor
    64 times runs 24% faster than on the reference
    (`results/compiler-config-20261031.md`).
14. **Binary chunks are luac's.** Landed: `dump.zig` (`string.dump`) and
    `undump.zig` (`load` of a chunk starting with ESC) read and write
    5.5.1's format exactly, so `luac -o` output runs here and our dumps
    load on the reference. `just dump` checks that our dump of every suite
    and bench file is `luac -o`'s byte for byte, plain and stripped, and
    that luac's chunks load and dump back unchanged: 108 of 108. Line
    info is written and read as the prototype holds it, so no case
    differs any more; details are in `dump.md`. Unlike
    lundump.c, the loader rejects an opcode outside the set ("bad binary
    format (invalid opcode)"), which is what lets the loop's dispatch go
    unchecked in safe builds (`results/opcode-check-20261031.md`).
15. **Library host.** The libraries reach I/O and state the core does not keep
    (warning mode, the collector's mode and parameters) through
    `lib.base.Host`, which the embedder owns and `lib.openLibs` stores in the
    registry as a light userdata under `_LUA_HOST`. A field on `State` would
    save the lookup; ask the core's owner when a library needs it on a hot
    path.
16. **Embedding API.** A Zig API first. Reopened in wave 8: whether to
    add Lua 5.5.1's C API and `.so` loading as an opt-in build
    (`-Dc-api=true`), so compiled C modules load unmodified. A prototype
    landed (`c-api.md`, `src/capi/`, `results/c-api-20261031.md`): 128
    of 156 functions, the suite's `libs/`, lpeg, lua-cjson, and
    luafilesystem passing their own tests, errors unwound by a protected
    call per C function. The default build is unchanged; without the
    option `package.loadlib` and the C searchers keep the reference's
    "dynamic libraries not enabled" answer. Still to decide: full
    coverage (hooks, `luaL_Stream`, `lua_newstate` for a `liblua.so`),
    aarch64, and whether the C-API build becomes a release artifact.
    Landed: `src/api.zig`, exported at the
    module's root (`lua.State`, `lua.Value`, `lua.Ref`, ...), with the engine
    under `lua.internal` for the tools. `State` is an opaque
    handle to a `Thread`; values cross as Zig types; calls from the top level
    are protected and calls inside Zig functions propagate; userdata
    metatables are found by a per-type number in an array, not a registry
    hash. Against the internal path the API is 7.7% faster on geomean, with
    equal peak memory (`api.md`, `results/api-20261031.md`). Wave 5 added
    `Values` (results kept on the stack, recorded in the calling frame,
    no allocator), `Table.rawGet`/`rawSet`, bound functions
    (`State.function(ctx, f)`, a native closure), `State.pcall`,
    `Coroutine` with Zig functions yielding in tail position,
    `DecodeOptions.unknown_keys`, and `Options.stdout` (`base.Host.stdout`
    is a `*std.Io.Writer`); `vm.pcallMsgh` reports `vm.Status`, so a Lua
    `error("not enough memory")` is `error.Runtime`. `main.zig` runs on the
    API alone, nothing left internal. The existing API paths cost what they
    did (geomean +0.3%; `zig_calls_lua` +2.2%, layout-sized); `lua` on the API
    matches `lua` on the engine (−0.26% time, +0.01% peak RSS)
    (`results/api-wave5-20261031.md`). Wave 6 finished the status
    switch (`vm.pcall` and `vm.closeThread` return `vm.Status`; a dead
    coroutine keeps its kind in `Thread.died`, which `coroutine.wrap`
    reads) and added `Coroutine.close`, `Coroutine.status`, and
    `State.len`, with which `lua` counts `#arg` through `__len`.

## Hot-path rules

- No allocation on an instruction's path except where the language allocates.
- No hash lookup for a global access that a constant key and a cached slot can
  answer. Landed in wave 4: `GETTABUP` and `SETTABUP` try the node in
  `Proto.kslot[c]` for their constant key first (4 bytes per constant in
  functions that touch globals); bench/globals.lua −8.9%, a read of an unset
  global +4% (`results/gettabup-cache-20261031.md`).
- Integer and float fast paths first in every arithmetic opcode; metamethods
  and coercions on the slow branch, out of line.
- Slow paths take operands as `*const Value` and carry `@branchHint(.cold)`.
  Zig passes a 16-byte `Value` to a noinline function by reference, so a
  by-value argument makes the fast path copy the operand to a stack temporary,
  and a 16-byte load of a value just written by two narrow stores stalls on
  store forwarding. Copy values field by field (`put`, `setv`).
  (`results/vm-operands-20261030.md`, `vm-copies`, `vm-registers`.)
- The interpreter loop's register allocation shifts other programs by ±5%
  with any edit; judge a change only by a full 10-round A/B.
- `ReleaseFast` builds are the ones measured. `ReleaseSafe` runs the suite too;
  it is 33% slower than ReleaseFast and still faster than the reference.
  Half of that and all of its extra peak memory is the standard allocator
  interface writing 0xAA over every allocation and free; then
  `SmpAllocator`'s own safe build. Landed in wave 7: objects and the
  blocks they own allocate through `gc.Raw` (`Heap.raw()`,
  `Heap.rawStrings()`), the same calls on the vtable without the fill,
  which Debug builds keep: ReleaseSafe −10.5% on the geomean and −3.8%
  peak RSS (array −27%, table_concat −24%), ReleaseFast's loop byte for
  byte the same (`results/safe-poison-20261031.md`). Allocate a new kind
  of object through `Heap.raw()`, and call `rawAlloc` and `rawFree`
  directly in anything that inlines into the loop. The loop's checks are spread thin
  (`results/release-safe-20261031.md`). Measure it with
  `just optimize=ReleaseSafe bench-compare`. Landed in wave 5: a
  `Buffer` is declared `.init(state)`, not `undefined`, which a safe
  build fills with 0xAA, 1 KiB per `string.format` (format −21 to −28%
  in ReleaseSafe, `results/buffer-init-20261031.md`); never declare a
  large local `undefined` on a hot path. The loop switches on
  `Dispatch`, a non-exhaustive copy of `OpCode`, so safe builds do not
  check the opcode before each jump (fib −12%, spectral_norm −10% in
  ReleaseSafe; ReleaseFast's loop is byte for byte the same,
  `results/opcode-check-20261031.md`).

## Testing

- Unit tests next to each module, through testingx.
- Differential tests: a Lua snippet runs on our `lua` and on the reference, and
  the outputs must match. This catches most semantics bugs before the suite does.
- The suite: `just suite` runs `all.lua` with `_U=true` on our binary. A file
  or case that cannot pass yet is listed in the suite driver with the reason.
  `docs/slop/suite-status.md` tracks which files pass.
- Fuzzing: `just fuzz` runs the fuzzers in `test/fuzz/` (the compiler on
  mutated and generated source, the binary loader on corrupted dumps,
  generated programs and bytecode listings against the reference, and an
  allocation-failure sweep over programs and the API) in ReleaseSafe;
  `just fuzz-stress` under collector stress, `just fuzz-zig` through Zig's
  coverage-guided fuzzer. Design, findings, and known limits are in
  `fuzz.md`.

## Benchmarks

`just bench-api` times the embedding API against the same work on the
engine (`bench/api/main.zig`), interleaved and pinned like `bench-compare`.

`bench/` holds Lua programs that stress one thing each: calls (fib), tables
(binary trees, hash insert and lookup), floats (n-body, spectral norm,
mandelbrot), strings (concatenation, `string.format`, `gsub`), closures and
upvalues, method calls through metatables, and coroutines. `just bench-compare`
runs each on our binary and on reference Lua 5.5.1, interleaved and pinned to
one core, and prints benchstat input: wall time, and each process's peak RSS
(GNU time's `%M`) as the `peak-RSS-KiB` unit. Memory is a gate like time.
Four programs are shaped like real workloads rather than one feature: a
pure-Lua JSON encoder and decoder (`json`), templated HTML and text
reports (`template`), a class-based simulation (`oop`), and a large
table constructor compiled with `load` and queried (`config`).

## Order of work

Files have one owner at a time. A piece of work that needs another's file asks
for the change instead of editing it.

Wave 1, in parallel, with no shared files:

- **Core**: `Value.zig`, `gc.zig`, `String.zig`, `Table.zig`,
  `State.zig` and `Thread.zig`, `opcodes.zig`, `Proto.zig`, and the skeleton of
  `vm.zig`.
- **Lexer and numbers**: `Lexer.zig` (every token, long brackets, all string
  escapes including `\u{...}` and `\z`, line tracking) and `number.zig`
  (string to number by the manual's rules, number to string, the arithmetic
  helpers of decision 10). Depends on nothing.
- **String library engines**: `lib/pattern.zig` (Lua patterns: match, find,
  gmatch, gsub's matching, with captures and position captures), `lib/format.zig`
  (`string.format`'s conversions), and `lib/pack.zig` (`string.pack`,
  `string.unpack`, `string.packsize`), each over byte slices and plain numbers,
  with no dependency on `Value`. Landed: the interfaces the glue implements and
  how they were checked against the reference are in `string-engines.md`.
- **Harness**: `bench/` programs, `just bench-compare`, and `just suite`,
  working against the reference `lua` now and ready for ours.

Wave 2, once the core and the lexer land: the parser and code generator, the
opcodes in `vm.zig`, metatables, the standalone `lua`, and the standard library
in pieces (base, string glue, table, math, utf8, os, io, coroutine, debug).
Landed: the string, table, math, and utf8 libraries, with `lib/auxlib.zig`
(lauxlib's checks and messages) and `lib/libm.zig` (glibc's `exp`, `pow`, and
logarithms, bit for bit); coverage, verification, and the helpers they need
from the core are in `stdlib.md`.

Landed from wave 2: the compiler (`Parser.zig`, `Code.zig`), the base
library (`lib/base.zig`), `lib/init.zig`'s `openLibs`, and the standalone
`lua` (`main.zig`, lua.c without the traceback). `just diff` runs
`test/diff/*.lua` on both interpreters. The package, io, and os libraries
(`lib/package.zig`, `lib/io.zig`, `lib/os.zig`) landed too, with `require`;
`main.zig` hands them the environment and `-E` in `base.Host`. Coverage, verification, and what they need from the core
are in `io-os-package.md`. Most suite files now stop on `require "debug"`.

Landed from wave 3: `string.dump` and binary chunks (`dump.zig`,
`undump.zig`, decision 16); all.lua now runs main.lua through its dump
round trip and stops on `require "debug"`.

Landed from wave 2, the VM (`vm.md`): `number.zig` arithmetic, `__concat`,
to-be-closed variables, vararg tables, coroutines and continuations
(`lib/coroutine.zig`), error messages with variable names, stack overflow
handling, and the debug library (`lib/debug.zig`). Wave 3 added hooks,
with a second instance of the interpreter loop so the unhooked one checks
nothing per instruction (`vm.md`), and the standalone `lua` runs
everything from a native frame with lua.c's traceback handler.

Wave 3: the collector's weak tables, finalizers, incremental and generational
modes (landed, `gc.md`), then the measured decisions above.

Wave 4 measured the decisions still open: the value representation
(decision 1, kept), dispatch (decision 3, kept), the global-access cache
(landed), and the cost of ReleaseSafe. The comparison with the reference at
the end of wave 4 is `results/bench-compare-wave4-20261031.md`.

Wave 5: `auxlib.Buffer` without the safe build's memset, opcodes checked
by the loader instead of before each dispatch (both under the hot-path
rules), and the hash part against open addressing (decision 8, kept). The
comparison with the reference at the end of wave 5 is
`results/bench-compare-wave5-20261031.md`.

Wave 6: the API cleanups left from wave 5 (under decision 16), four
realistic benchmark programs, and the compiler's two stalls (decision
13). Inherited method lookups that repeat the object's and the class's
lookup in `getSlow` were measured and not landed: the gain (methods
−6%) is the size of the loop's layout noise
(`results/index-chain-20261031.md`). The comparison with the reference
at the end of wave 6 is `results/bench-compare-wave6-20261031.md`.

Wave 7: memory. Line information in luac's encoding (decision 13,
`results/lineinfo-20261031.md`), which also makes `string.dump`'s line
info luac's in every case (decision 14), and ReleaseSafe without the
allocator's fill (the hot-path rules, `results/safe-poison-20261031.md`).
The comparison with the reference at the end of wave 7 is
`results/bench-compare-wave7-20261031.md`.

Wave 8: the C API prototype (decision 16 reopened, `c-api.md`), opt-in
with `-Dc-api=true`. Owner of `src/capi/`, `include/`, `test/capi/`,
`bench/capi/`; small edits to `Thread.zig` (the prefix in front of each
thread), `Proto.zig` (`NativeClosure.cfn`), `State.zig` (5.5.1's
registry layout), and `lib/package.zig` (`loadlib` and the C searchers
call `capi/loadlib.zig`). Measurements in `results/c-api-20261031.md`.

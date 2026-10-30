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
main.zig: the standalone `lua` program, which the suite runs
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
   can change in one file. **Measure** against NaN-boxing, which needs boxed
   integers outside 2^47 or a separate integer tag scheme; Lua 5.5's 64-bit
   integers make NaN-boxing a real trade, not a free win.
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
   can reallocate the stack. **Measure** a plain loop-and-switch once, to know
   what threading buys.
4. **Calls.** A Lua-to-Lua call pushes a frame and continues the same loop: no
   Zig recursion, so deep Lua recursion costs heap, not Zig stack. Frames refer
   to the stack by index, because the stack reallocates when it grows.
   Metamethods called from an instruction (`__index` functions, arithmetic,
   `__eq`, `__lt`, `__concat`, `__close`) push a frame and record how to finish
   the instruction when it returns, as PUC-Rio's `luaV_finishOp` does. That
   keeps them yieldable and off the Zig stack.
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
   C-call boundary", as in PUC-Rio.
7. **Strings.** Short strings (40 bytes or fewer) are interned in a hash set
   owned by the `State`, so equality is pointer equality. Long strings are not
   interned and hash lazily. A string is one allocation: header, hash, length,
   bytes, and a trailing zero. 5.5's external strings (bytes the collector does
   not own) come later.
8. **Tables.** An array part and a hash part. The array part uses 5.5's
   compact layout: payloads and tags in separate runs, 9 bytes per slot instead
   of 16. The hash part starts as PUC-Rio's chained scatter table with Brent's
   variation (a power-of-two node array, collisions chained through free nodes),
   because `next` must survive assignment to existing keys during traversal.
   Cache `__index`/`__newindex` and friends' absence in a per-table flag byte, as
   PUC-Rio does, so the common case skips the metatable lookup. **Measure** the
   hash part against an open-addressing table once the suite passes.
9. **Collector.** Precise and non-moving. Every collectable object starts with a
   common header (next pointer, tag, mark bits). Start stop-the-world
   mark-and-sweep, but call the write barrier at every store into a table,
   upvalue, or userdata from the first commit, as a no-op, so incremental
   marking lands without touching every call site. Then weak tables,
   ephemerons, `__gc` finalizers, and `__close`; then incremental, with 5.5's
   incremental major collections; then generational mode. Allocation goes
   through the state's allocator with byte accounting, for
   `collectgarbage("count")` and pacing.
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
    file, addresses masked: 49 of 49 identical. Keep it that way; a
    deliberate divergence goes in the recipe with the reason. Line info is
    one absolute line per instruction (`Proto.lineinfo`), not luac's
    delta encoding, which only `string.dump` would need.
14. **Library host.** The libraries reach I/O and state the core does not keep
    (warning mode, the collector's mode and parameters) through
    `lib.base.Host`, which the embedder owns and `lib.openLibs` stores in the
    registry as a light userdata under `_LUA_HOST`. A field on `State` would
    save the lookup; ask the core's owner when a library needs it on a hot
    path.
15. **Embedding API.** A Zig API, not the C API, designed once the standard
    library has exercised the internal one. Nothing outside `src/` depends on
    internals until then.

## Hot-path rules

- No allocation on an instruction's path except where the language allocates.
- No hash lookup for a global access that a constant key and a cached slot can
  answer (`GETTABUP` with a constant string key: measure an inline cache).
- Integer and float fast paths first in every arithmetic opcode; metamethods
  and coercions on the slow branch, out of line.
- `ReleaseFast` builds are the ones measured. `ReleaseSafe` runs the suite too.

## Testing

- Unit tests next to each module, through testingx.
- Differential tests: a Lua snippet runs on our `lua` and on the reference, and
  the outputs must match. This catches most semantics bugs before the suite does.
- The suite: `just suite` runs `all.lua` with `_U=true` on our binary. A file
  or case that cannot pass yet is listed in the suite driver with the reason.
  `docs/slop/suite-status.md` tracks which files pass.

## Benchmarks

`bench/` holds Lua programs that stress one thing each: calls (fib), tables
(binary trees, hash insert and lookup), floats (n-body, spectral norm,
mandelbrot), strings (concatenation, `string.format`, `gsub`), closures and
upvalues, method calls through metatables, and coroutines. `just bench-compare`
runs each on our binary and on reference Lua 5.5.1, interleaved and pinned to
one core, and prints benchstat input.

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
`test/diff/*.lua` on both interpreters; `vm_errors.lua` there lists the VM's
messages that still differ. Nothing owns `package`/`require` yet, and most
suite files start with `require`.

Wave 3: the collector's weak tables, finalizers, incremental and generational
modes, then the measured decisions above.

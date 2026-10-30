# Core: the object model, collector, tables, and interpreter

Wave 1's core: `src/Value.zig`, `gc.zig`, `String.zig`, `Table.zig`,
`Proto.zig` (prototypes, closures, upvalues), `Userdata.zig`, `State.zig`,
`Thread.zig`, `opcodes.zig`, and `vm.zig`. This file records the decisions
the plan left open and what was measured. Numbers are in
`results/core-baseline-20261030.md`.

## Decisions

### Values and errors

- `Value` is 16 bytes: an extern-union payload and a `u8` tag, as decision 1
  says. False and true are separate tags (`bool_false`, `bool_true`) right
  after `nil`, so truthiness is one compare: `tag <= bool_false`. The tag
  set has internal kinds no value holds (`proto`, `upval`) and `dead_key`
  for table keys the collector dropped.
- `Value.Error` is `error{ LuaError, OutOfMemory }`. Allocation failure
  stays `error.OutOfMemory` through Zig code and `vm.pcall` turns it into the
  preallocated, fixed "not enough memory" string. That keeps every
  allocation site a plain `try` instead of converting at each one.
- Native functions are `fn (*Thread, base: u32) Error!u32`: arguments are
  `stack[base..top]`, results are the top n values, the return is n
  (decision 11). A native runs with `Thread.min_stack` (20) free slots.

### Bytecode

- The opcode set, numbering, and encoding are Lua 5.5.1's exactly
  (`lopcodes.h`), including `ivABC` for `NEWTABLE`/`SETLIST`, `GETVARG`,
  and `ERRNNIL`. The parser's specification is `luac -l -l` on the same
  source; the tests check encodings against words in `luac -o` output.
- Register layouts follow 5.5: a numeric loop uses three registers (count
  or limit, step, control variable at `A+2`); a generic loop puts the
  closing value at `A+2` and the control variable at `A+3`, the first loop
  variable.
- Arithmetic keeps 5.4/5.5's `MMBIN` design: the opcode's fast path skips
  the following `MMBIN`; non-numbers fall through to it.

### Strings

- Hash: Wyhash keyed by the state's seed, truncated to 32 bits. The seed is
  random per state by mixing ASLR-randomized addresses (no `Io` needed);
  `State.Options.seed` fixes it.
- A long string's `hash` field holds the seed until first hashed (PUC-Rio's
  trick), so table code hashes keys without the state.
- `String.extra` is free on short strings for the lexer to mark reserved
  words.

### Tables

- Array part: 5.5's compact block (payloads backwards from `array`, a
  4-byte length hint, then tags), 9 bytes per slot.
- Hash part: chained scatter with Brent's variation, nodes of 24 bytes,
  relative `next` offsets. Integer keys hash by Fibonacci multiplication
  (high half of `key * 0x9E3779B97F4A7C15`), not PUC-Rio's modulo by an odd
  number: no division on the path.
- Sizing follows 5.5: an array size n is chosen when n ≤ 3 × (integer keys
  in 1..n); the array keeps its size when no new key is an array candidate;
  a table with deleted entries gets 25% extra hash room.
- `#t` is 5.5's hint-based border search. `hash_search` takes 5.5's random
  steps (2j or 2j + 1), with bits from the table's address instead of the
  state's seed, so `nextvar.lua`'s attack on the length stays fast.
- There is no slot-pointer API. The VM's store fast path is "table without
  a metatable: raw set". A table with a metatable does a raw get, then
  checks `__newindex`'s cached absence. Wave 2 added an in-place store for
  a present short-string key (`vm.md`).
- The metamethod cache: `Table.flags` bit e set means event e (`__index`
  through `__eq`) is absent. New tables start with all bits set; any store
  that adds a key or refills a nil value clears them.

### Collector

Wave 3 replaced the stop-the-world collector with a port of lgc.c
(`gc.md`). Still true from wave 1:

- Gray objects are linked through a `gclist` field in each object with
  children, so marking never allocates.
- Open upvalues form a doubly linked list per thread (`prev` points at the
  link to the upvalue), so sweeping a dead upvalue unlinks it, and freeing a
  thread closes whatever is left; either sweep order is safe.
- All memory goes through `Heap.allocator()`, a counting wrapper around the
  state's allocator, so `Heap.bytes` is every byte the state holds.

### Threads, calls, and metamethods

- Frames live in a `std.ArrayList(Frame)` and refer to the stack by index.
  The VM reloads its frame pointer after any call, since the list may move.
- The stack starts at 40 slots plus 5 spare above every frame's top (room
  for a metamethod's function and three arguments), doubles, and stops at
  1,000,000 slots with "stack overflow". Nested native-to-Lua calls stop at
  200 with "C stack overflow".
- `CALL` of a Lua function pushes the frame inline and continues the loop;
  only natives and `__call` go through `preCall`.
- A Lua metamethod called from an instruction gets a frame flagged
  `finish_op`; its return runs `finishOp`, which stores the result or takes
  the conditional jump (decision 4). A native metamethod runs at once and
  the instruction completes inline. Implemented this way: `__index`,
  `__newindex`, `__call`, the arithmetic and bitwise events through
  `MMBIN*`, `__unm`, `__bnot`, `__len`, `__eq`, `__lt`, `__le`.
- `Thread.runError` prefixes "chunk:line:" from the running Lua frame,
  using PUC-Rio's chunk-id rules. Line info is one `u32` per instruction
  for now.
- Upvalues keep their open-list fields and closed value as separate fields
  rather than a union: a `Value` cannot sit in an extern union, and a bare
  union carries a safety tag in safe builds. It costs 16 bytes per upvalue.

### Numbers

Wave 1 had private versions of the number helpers; wave 2 moved the VM onto
`number.zig` (see `vm.md`).

## Measured

- Dispatch: objdump of the ReleaseFast build shows one
  `jmp *table(,%rax,8)` at the end of each handler, with `pc`, `base`, and
  the instruction in registers. The plain loop-and-switch comparison is
  still to do.
- Against reference Lua 5.5.1 (medians, ratio ours/theirs): `fib(32)` 0.98,
  a 10^8-iteration numeric loop 0.84, filling and summing a 10^7-element
  array 1.05. Two changes during development moved `fib` from 1.58 and
  `tab` from 1.33; see the results file.

## Not done

Wave 2 finished concatenation, to-be-closed variables, vararg tables,
coroutines, variable names in messages, `number.zig` arithmetic, message
handlers, and stack shrinking; `vm.md` records how and what is still open.
Left from this list:

- A `GETTABUP` inline cache.

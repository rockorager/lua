# Binary chunks: `string.dump` and loading them

`src/dump.zig` writes a prototype in reference Lua 5.5.1's binary format
(ldump.c) and `src/undump.zig` reads it (lundump.c). `string.dump` in
`lib/string.zig` calls the first; `lib/base.zig`'s `loadChunk` calls the
second for a chunk whose first byte is ESC, after the mode check, so `load`,
`loadfile`, `dofile`, `require`, and `lua file.out` all take binary chunks.

## The format, as 5.5.1 has it

- Header: `"\x1bLua"`, version `0x55`, format 0, `"\x19\x93\r\n\x1a\n"`,
  then size and value checks for `int` (4, -0x5678), `Instruction` (4,
  0x12345678), `lua_Integer` (8, -0x5678), and `lua_Number` (8, -370.5), in
  native byte order. Then the main function's upvalue count, then the
  function.
- Counts and line numbers are MSB-first varints; integer constants are
  zigzag varints; floats are 8 raw bytes. Code and absolute line entries
  are aligned to 4 bytes from the start of the dump.
- Strings are written once: a length plus one and the bytes with their
  zero, and later occurrences (by contents, short or long) as 0 and the
  1-based index of the first; 0, 0 is no string.
- Per function: lines defined, `numparams`, the flag byte (`PF_VAHID` 1 is
  `Proto.Flags.vararg`, `PF_VATAB` 2 is `vararg_table`, `PF_FIXED` 4 is
  masked), `maxstacksize`, code, constants (5.5's variant tags: 0, 1, 0x11,
  3, 0x13, 4, 0x14), upvalue descriptors with `kind`, nested functions,
  source, then line info, absolute line entries, locals, and upvalue names.
  `strip` writes no source and zero counts for the debug parts.

## Line information

`Proto.lineinfo` and `Proto.abslineinfo` hold lcode.c's encoding, built by
`Code.zig` as `savelineinfo`, `removelastlineinfo`, and `luaK_fixline`
build it: a signed byte per instruction (the change from the previous
line) and an absolute entry where the change does not fit in a byte,
after 128 relative entries in a row, or where `luaK_fixline` moved an
instruction whose first save was absolute. The dump writes both as they
are and the loader reads them back as they are, so every line-info byte
is luac's, including the case the earlier re-encoding of absolute lines
could not reproduce (a call whose parentheses enclose 128 lines or more,
in `test/diff/dump.lua`). `Proto.lineAt` decodes a line as
`luaG_getfuncline` does (`results/lineinfo-20261031.md`).

## Loading

- Messages are the reference's, as "NAME: bad binary format (WHY)" with
  NAME the chunk name without its '@' or '=', or "binary string" when the
  name is the chunk itself: `truncated chunk`, `not a binary chunk`,
  `version mismatch`, `format mismatch`, `corrupted chunk` (bad
  `LUAC_DATA`, or an upvalue count that disagrees with the function's), `int
size mismatch` and the other size and format checks, `integer overflow`,
  `invalid string index`, `bad format for constant string`, and `invalid
constant`. Bytes after the main function are ignored, as the reference
  reads no further.
- A count larger than the bytes left could hold fails as a truncated chunk
  before anything is allocated for it.
- The closure is `vm.mainClosure`'s, as `lua_load` builds it: every upvalue
  a fresh nil, then the first set to the globals table (or `load`'s `env`),
  whatever its name.
- Like the reference, the loader does not verify bytecode: a hand-made
  chunk can hold out-of-range registers or constant indices, which the VM
  trusts. Nor does it check line information; `Proto.lineAt` and
  `changedLine` stay in bounds on any entries, giving some line for
  out-of-order ones.

## Verification

- `just dump`: for every suite and bench file, our `string.dump` of our
  compile equals `luac -o` and `luac -s -o` byte for byte, and luac's
  chunks load on ours and dump back unchanged: 108 of 108.
- Every one of our dumps loads on the reference, which lists it with
  `luac -l -l` exactly as it lists its own (98 of 98 in wave 3; since
  the dumps are now luac's bytes, this follows from `just dump`).
- `lua x.out` on ours for luac's output of each bench program prints what
  the reference prints for the source (plain and stripped), except
  `coroutines`, which needs the coroutine library either way.
- Each suite file run through `load(string.dump(loadfile(f), strip))`
  ends where running it directly ends; stripped, runtime errors lack their
  position (see below).
- `test/diff/dump.lua` (`just diff`) compares with the reference: dump
  bytes of constants of every kind, nested functions, a vararg table, long
  lines gaps and loops, stripped and not; round trips; the upvalue rule;
  `string.dump`'s argument error; modes and chunk names; every header
  check, truncation, invalid string index and constant, integer overflow;
  a reader function; and binary files through `loadfile`, `dofile`, and a
  `#` first line.
- Unit tests: our dump of a fixed source equals luac's bytes (plain and
  stripped, including a forced absolute line); luac's chunk loads with the
  right lines and dumps back unchanged; every truncation and each header
  corruption gives the reference's message; every byte of the chunk flipped
  four ways loads or fails cleanly, and what loads dumps again and decodes
  every instruction's line.

## Requests for the core

- A runtime error in a stripped function: the reference prefixes "?:?:"
  (no source, no line); `Thread.runError` adds no prefix.

# `auxlib.Buffer` without the safe-build memset, 2026-10-31

`release-safe-20261031.md` found 23% of `string.format`'s ReleaseSafe
samples in `memset`, called from `format` itself: the library code
declared `var b: auxlib.Buffer = undefined;`, and a safe build writes
0xAA over everything a variable set to `undefined` holds, here the whole
1,096-byte struct with its 1 KiB inline buffer, on every call. Every
function that builds a string in a `Buffer` paid it: `string.format`,
`table.concat`, `gsub`, `string.pack`, `string.dump`, `utf8.char`,
`os.date`, `io` reads, and `package`'s messages.

## What Zig writes for `undefined`

A small object file built with `zig build-obj -OReleaseSafe`, one
function per way of declaring a struct with a 1 KiB array field:

- `var b: B = undefined;`: `memset(&b, 0xaa, 1024)`.
- `var b: B = blk: { @setRuntimeSafety(false); break :blk undefined; };`:
  the same memset; the store happens in the declaration's scope.
- `var b: B = .{};` or a declared constant `.empty`, every field
  defaulting to `undefined`: the same memset, because the whole value is
  comptime-known and undefined.
- `var b: B = .init(p)`, where `init` returns a struct literal with at
  least one runtime field and the array field left to its `= undefined`
  default: no memset. The literal stores field by field into the result
  location and skips the defaulted `undefined` fields. Returned through
  the result location, there is no copy either (ReleaseSafe and
  ReleaseFast; a Debug build copies).

## The change

- `Buffer.init(state) Buffer` returns the buffer by value, with `small`
  and `block` left to their `undefined` defaults. Call sites declare
  `var b: auxlib.Buffer = .init(state);` instead of `undefined` and then
  `b.init(state)`.
- A buffer must not move once its writer points into `small`, so the
  writer starts with an empty buffer and `ensureUnused`, the one place
  every write that does not fit goes through, takes `small` on the first
  write. That costs one call through the writer's vtable per buffer.
- `deinit` no longer sets `b.* = undefined`. Where `deinit` inlines next
  to the end of the buffer's lifetime, LLVM drops that store as dead, but
  not everywhere: with it, the safe `lua` still has ten 1,096-byte
  memsets, in `package.searchPath`, `package`'s loader, and
  `io.fileResultErrno`; without it, none. ziglint's Z030 asks for the
  store, so the line carries a `ziglint-ignore` with the reason.

The disassembly of the ReleaseSafe `lua` confirms it: `lib.string.format`,
`gsub`, `pack`, `dump`, and `lib.table.concat` each had one
`memset(…, 0xaa, 0x4xx)` call; after the change none does. Over the
whole binary, memsets of 0x448 bytes (`@sizeOf(Buffer)`) go from 15 to 0.

## Measurements

Interleaved, pinned to the last core, 10 rounds of every `bench/`
program, wall time and peak RSS per process, benchstat. `base` is
f55ff31; `buf` is this change alone.

ReleaseSafe:

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
                  │     base     │                 buf                  │
                  │    sec/op    │    sec/op     vs base                │
Lua/array            1.053 ± 10%    1.040 ± 10%        ~ (p=0.280 n=10)
Lua/binary_trees    843.0m ± 18%   837.7m ± 10%        ~ (p=0.853 n=10)
Lua/closures        811.6m ± 15%   798.3m ±  4%        ~ (p=0.739 n=10)
Lua/concat          867.3m ±  8%   837.1m ± 10%        ~ (p=0.739 n=10)
Lua/coroutines      541.4m ± 10%   528.5m ±  9%        ~ (p=0.739 n=10)
Lua/fib             612.8m ± 15%   607.9m ±  9%        ~ (p=0.971 n=10)
Lua/format          671.8m ± 12%   486.6m ±  9%  -27.56% (p=0.000 n=10)
Lua/globals         734.0m ± 21%   739.5m ± 16%        ~ (p=0.631 n=10)
Lua/hash_int        671.6m ± 13%   692.7m ± 11%        ~ (p=0.280 n=10)
Lua/hash_string     655.2m ± 19%   587.2m ± 11%        ~ (p=0.353 n=10)
Lua/mandelbrot      500.5m ± 16%   518.5m ± 18%        ~ (p=0.684 n=10)
Lua/methods         786.2m ± 34%   786.3m ±  7%        ~ (p=0.739 n=10)
Lua/nbody           757.1m ± 11%   720.4m ±  7%        ~ (p=0.165 n=10)
Lua/patterns        636.9m ± 11%   628.8m ± 14%        ~ (p=0.280 n=10)
Lua/spectral_norm   790.1m ±  2%   773.5m ±  8%        ~ (p=0.315 n=10)
Lua/table_concat    520.1m ± 10%   513.1m ±  6%        ~ (p=0.796 n=10)
geomean             702.4m         678.3m         -3.43%

                  │     base     │                  buf                  │
                  │ peak-RSS-KiB │ peak-RSS-KiB  vs base                 │
Lua/array            29.34k ± 0%    29.34k ± 0%       ~ (p=1.000 n=10) ¹
Lua/binary_trees     26.89k ± 0%    26.89k ± 0%       ~ (p=1.000 n=10) ¹
Lua/closures         2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/concat           2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/coroutines       2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/fib              2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/format           2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/globals          2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/hash_int         6.348k ± 0%    6.348k ± 0%       ~ (p=1.000 n=10) ¹
Lua/hash_string      23.18k ± 0%    23.18k ± 0%       ~ (p=1.000 n=10) ¹
Lua/mandelbrot       2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/methods          2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/nbody            2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/patterns         9.360k ± 0%    9.360k ± 0%       ~ (p=1.000 n=10) ¹
Lua/spectral_norm    2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/table_concat     30.82k ± 0%    30.82k ± 0%       ~ (p=1.000 n=10) ¹
geomean              5.056k         5.056k       +0.00%
¹ all samples are equal
```

ReleaseFast:

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
                  │     base     │                 buf                 │
                  │    sec/op    │    sec/op     vs base               │
Lua/array           784.4m ±  9%   764.9m ± 14%       ~ (p=0.912 n=10)
Lua/binary_trees    591.4m ± 16%   587.0m ± 17%       ~ (p=0.912 n=10)
Lua/closures        533.5m ± 12%   536.5m ± 13%       ~ (p=0.739 n=10)
Lua/concat          309.8m ±  7%   320.0m ± 17%       ~ (p=0.218 n=10)
Lua/coroutines      385.6m ± 14%   379.4m ± 14%       ~ (p=0.393 n=10)
Lua/fib             495.5m ± 15%   466.7m ±  8%       ~ (p=0.436 n=10)
Lua/format          379.7m ±  4%   377.0m ±  8%       ~ (p=0.796 n=10)
Lua/globals         555.8m ±  6%   568.2m ± 11%       ~ (p=0.579 n=10)
Lua/hash_int        550.9m ± 15%   537.1m ± 12%       ~ (p=0.912 n=10)
Lua/hash_string     533.2m ±  6%   531.7m ±  9%       ~ (p=0.796 n=10)
Lua/mandelbrot      460.1m ± 18%   465.8m ± 12%       ~ (p=0.579 n=10)
Lua/methods         592.6m ± 14%   633.0m ± 13%       ~ (p=0.105 n=10)
Lua/nbody           662.5m ± 11%   721.3m ± 15%       ~ (p=0.280 n=10)
Lua/patterns        560.0m ± 17%   608.2m ±  7%  +8.61% (p=0.011 n=10)
Lua/spectral_norm   694.4m ±  8%   698.3m ± 16%       ~ (p=0.796 n=10)
Lua/table_concat    309.8m ±  9%   320.7m ±  9%       ~ (p=0.247 n=10)
geomean             508.1m         514.6m        +1.27%

                  │     base     │                  buf                  │
                  │ peak-RSS-KiB │ peak-RSS-KiB  vs base                 │
Lua/array            20.93k ± 0%    20.93k ± 0%       ~ (p=1.000 n=10) ¹
Lua/binary_trees     26.60k ± 0%    26.60k ± 0%       ~ (p=1.000 n=10) ¹
Lua/closures         2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/concat           2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/coroutines       2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/fib              2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/format           2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/globals          2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/hash_int         6.000k ± 0%    6.000k ± 0%       ~ (p=1.000 n=10) ¹
Lua/hash_string      22.38k ± 0%    22.38k ± 0%       ~ (p=1.000 n=10) ¹
Lua/mandelbrot       2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/methods          2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/nbody            2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/patterns         9.044k ± 0%    9.044k ± 0%       ~ (p=1.000 n=10) ¹
Lua/spectral_norm    2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/table_concat     23.10k ± 0%    23.10k ± 0%       ~ (p=1.000 n=10) ¹
geomean              4.821k         4.821k       +0.00%
¹ all samples are equal
```

In ReleaseSafe format is 27.6% faster (671.8 ms to 486.6 ms); nothing
else moves beyond noise, and peak memory is unchanged everywhere. A
second run, with the loader change of `opcode-check-20261031.md` in the
same build, put format at −20.9% (638.9 ms to 505.5 ms).

In ReleaseFast nothing moves and peak memory is identical: the safe
build's memset is what went away, and the lazy attach costs one indirect
call per buffer. patterns' +8.6% is noise: it calls `gsub` 30 times in
the whole run, and the second run (`opcode-check-20261031.md`'s ReleaseFast
arms, which carry this change) has patterns at +1.5% (p=0.53) and the
geomean at −2.7% (no program significant except binary_trees, −3.5%,
which builds no strings).

This machine is noisy (±15% intervals on single programs in both runs);
only format's change in ReleaseSafe is outside it.

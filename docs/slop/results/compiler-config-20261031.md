# The compiler on a large table constructor, 2026-10-31

`bench/config.lua` (new in wave 6) compiles a 521 KB chunk, one table
constructor of 2,000 items and 500 monsters, 64 times, runs it, and
queries the tables. Against the reference it tied on time (−0.9%,
p=0.74) with peak RSS level (+3%, p=0.38, the reference bimodal at
10.7 or 13.0 MB from run to run). Split apart, running the chunk was
ours by 10%, and compiling it was the reference's by 18%: 64 compiles
took 0.548 s against 0.463 s.

## Where the compile time went

`perf record` of 64 `load`s of the chunk (ReleaseFast, 5 kHz):

| ours                      | share | reference      | share |
| ------------------------- | ----: | -------------- | ----: |
| `Code.FuncState.k2proto`  | 21.0% | `llex`         | 17.5% |
| `Parser.constructor`      | 16.5% | `internshrstr` | 11.3% |
| `Parser.scan` (the lexer) | 13.7% | `luaH_get`     |  5.1% |
| `Parser.subExpr`          |  7.5% | `save`         |  5.0% |
| `String.Interner.create`  |  4.9% | `insertkey`    |  4.9% |

Two store forwarding stalls, the pattern the plan's hot-path rules
already name for the interpreter:

- **The constant cache.** `k2proto` looks constants up in a
  `std.AutoHashMapUnmanaged(KKey, u32)`. The generic hash feeds the
  key's nine bytes (a tag byte and a u64) to Wyhash, which copies them
  into its buffer with narrow stores and reads them back as two 4-byte
  words: 30% of `k2proto`'s samples sat on the instruction after that
  load. And a miss looked the key up twice, `get` then `put`.
- **The token.** `Parser.scan` returned the 64-byte token by value in an
  error union, written field by field, and `next` copied it into `ls.t`
  with two 32-byte loads: 40% of `constructor`'s samples (where `next`
  inlines) were on those loads.

## The change

- `KKey.Context` hashes the two fields as integers
  (`std.hash.int(bits ^ tag << 61)`), and `k2proto` does one
  `getOrPut`, with the constant's slot reserved first so a new entry
  always gets its constant.
- `scan(ls, tok)` writes the token into its destination (`ls.t`, or the
  lookahead), so nothing reads back a token it just wrote.

The bytecode is unchanged: `just bytecode` lists 54 of 54 files as luac
does, and `just dump` matches 108 of 108.

After it, `k2proto` is 12.5% and `constructor` 8.4% of the compile.
One stall is left: `next` copies a lookahead token into `ls.t` whole,
once per `name = value` field. Pointing `ls.t` at one of two token slots
instead of copying measured nothing (cfgcompile 363.0 ms ± 8% against
356.7 ms ± 7%, p=0.48), so it stays a copy.

## Measurements

Interleaved, pinned to the last core, 10 rounds of every `bench/`
program, wall time and peak RSS per process, benchstat. `base` is
`bench: add json, template, oop, and config programs`; `parser` is this
change alone.

config is 16.9% faster. No other program compiles more than a few
hundred lines, so their compile time is below a millisecond; the
interpreter loop is the same machine code (`vm.runLoop` 0x7dee bytes on
both arms) moved 48 bytes, which is the plan's ±5% layout effect:
nbody −7.0%, oop +4.0%, template +2.0%. Peak RSS is identical
everywhere.

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
                  │     base     │                parser                │
                  │    sec/op    │    sec/op     vs base                │
Lua/array           862.1m ±  4%   862.1m ±  3%        ~ (p=0.579 n=10)
Lua/binary_trees    673.8m ±  4%   674.6m ±  3%        ~ (p=0.853 n=10)
Lua/closures        627.2m ±  2%   621.1m ±  9%        ~ (p=0.436 n=10)
Lua/concat          372.3m ±  4%   373.9m ±  6%        ~ (p=0.631 n=10)
Lua/config          709.7m ±  6%   589.9m ± 17%  -16.89% (p=0.000 n=10)
Lua/coroutines      450.0m ±  2%   459.9m ± 10%        ~ (p=0.165 n=10)
Lua/fib             565.3m ±  2%   563.3m ±  3%        ~ (p=0.912 n=10)
Lua/format          453.7m ±  1%   449.3m ±  2%        ~ (p=0.393 n=10)
Lua/globals         648.5m ±  4%   639.9m ± 11%        ~ (p=0.315 n=10)
Lua/hash_int        466.8m ±  4%   459.5m ±  4%        ~ (p=0.529 n=10)
Lua/hash_string     439.4m ±  3%   438.2m ±  2%        ~ (p=0.631 n=10)
Lua/json            628.3m ±  5%   604.9m ±  8%        ~ (p=0.105 n=10)
Lua/mandelbrot      529.6m ±  6%   546.7m ±  5%        ~ (p=0.143 n=10)
Lua/methods         677.5m ±  3%   670.5m ±  2%        ~ (p=0.143 n=10)
Lua/nbody           813.9m ±  6%   757.2m ±  7%   -6.97% (p=0.003 n=10)
Lua/oop             669.7m ±  3%   696.4m ±  4%   +3.97% (p=0.003 n=10)
Lua/patterns        643.2m ±  6%   651.6m ±  9%        ~ (p=0.481 n=10)
Lua/spectral_norm   800.3m ±  6%   804.1m ±  8%        ~ (p=0.631 n=10)
Lua/table_concat    321.5m ± 14%   325.3m ±  4%        ~ (p=0.684 n=10)
Lua/template        641.4m ±  2%   653.9m ±  3%   +1.95% (p=0.043 n=10)
geomean             581.1m         574.9m         -1.06%

                  │     base     │                parser                 │
                  │ peak-RSS-KiB │ peak-RSS-KiB  vs base                 │
Lua/array            20.97k ± 0%    20.97k ± 0%       ~ (p=1.000 n=10) ¹
Lua/binary_trees     26.40k ± 0%    26.40k ± 0%       ~ (p=1.000 n=10) ¹
Lua/closures         2.368k ± 0%    2.368k ± 0%       ~ (p=1.000 n=10) ¹
Lua/concat           2.368k ± 0%    2.368k ± 0%       ~ (p=1.000 n=10) ¹
Lua/config           11.49k ± 0%    11.49k ± 0%       ~ (p=1.000 n=10) ¹
Lua/coroutines       2.368k ± 0%    2.368k ± 0%       ~ (p=1.000 n=10) ¹
Lua/fib              2.368k ± 0%    2.368k ± 0%       ~ (p=1.000 n=10) ¹
Lua/format           2.368k ± 0%    2.368k ± 0%       ~ (p=1.000 n=10) ¹
Lua/globals          2.368k ± 0%    2.368k ± 0%       ~ (p=1.000 n=10) ¹
Lua/hash_int         6.044k ± 0%    6.044k ± 0%       ~ (p=1.000 n=10) ¹
Lua/hash_string      22.40k ± 0%    22.40k ± 0%       ~ (p=1.000 n=10) ¹
Lua/json             10.46k ± 0%    10.46k ± 0%       ~ (p=1.000 n=10) ¹
Lua/mandelbrot       2.368k ± 0%    2.368k ± 0%       ~ (p=1.000 n=10) ¹
Lua/methods          2.368k ± 0%    2.368k ± 0%       ~ (p=1.000 n=10) ¹
Lua/nbody            2.368k ± 0%    2.368k ± 0%       ~ (p=1.000 n=10) ¹
Lua/oop              9.536k ± 0%    9.536k ± 0%       ~ (p=1.000 n=10) ¹
Lua/patterns         9.000k ± 0%    9.000k ± 0%       ~ (p=1.000 n=10) ¹
Lua/spectral_norm    2.368k ± 0%    2.368k ± 0%       ~ (p=1.000 n=10) ¹
Lua/table_concat     23.12k ± 0%    23.12k ± 0%       ~ (p=1.000 n=10) ¹
Lua/template         2.368k ± 0%    2.368k ± 0%       ~ (p=1.000 n=10) ¹
geomean              5.230k         5.230k       +0.00%
¹ all samples are equal
```

Compiling alone, against the reference: a script that builds config's
source and `load`s it 64 times without running it, 10 rounds, the same
method. Building the source is ours by a little, so the whole process
was level before (+3.4%, p=0.17) though the 64 compiles alone were 18%
slower by `os.clock`; after the change the process is 23.7% faster than
the reference, and peaks 32% lower.

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
               │     ref     │             base              │               parser                │
               │   sec/op    │   sec/op     vs base          │   sec/op     vs base                │
Lua/cfgcompile   471.6m ± 6%   487.8m ± 4%  ~ (p=0.165 n=10)   359.7m ± 3%  -23.72% (p=0.000 n=10)

               │     ref      │                 base                 │                parser                │
               │ peak-RSS-KiB │ peak-RSS-KiB  vs base                │ peak-RSS-KiB  vs base                │
Lua/cfgcompile    7.944k ± 2%    5.384k ± 0%  -32.23% (p=0.000 n=10)    5.384k ± 0%  -32.23% (p=0.000 n=10)
```

## Peak memory

config's peak RSS was level with the reference (11.49 MB against a
median of 11.15 MB ± 17%, p=0.38): the reference lands at 10.7 or
13.0 MB from run to run, ours at 11.49 MB every time. Measured with
`collectgarbage("count")` after full collections:

| counted KiB                       | ours | reference |
| --------------------------------- | ---: | --------: |
| before `load` (the 521 KB source) |  547 |        23 |
| the compiled chunk                |  851 |       629 |
| one run's tables                  | 1415 |      1302 |

- **The source string.** 5.5's `luaL_pushresult` turns a long buffer
  into an external string whose bytes the collector does not count, so
  the reference paces its collections as if the source were not there.
  Ours counts it. Not counting it (an experiment that subtracted the
  bytes in `String.adoptLong`) raised our peak to 12.16 MB, so the
  pacing is not monotone in the count, and the change was dropped. With
  the source freed before the runs, the two peak at 9,156 and
  9,112 KiB.
- **Line info.** `Proto.lineinfo` keeps one absolute `u32` line per
  instruction; luac keeps a signed byte of delta per instruction and an
  absolute line every 128 instructions (`savelineinfo`). That is about
  3 bytes more per instruction: the chunk is 64,414 instructions, so
  about 185 KiB of the 222 KiB difference, and every loaded function
  pays the same per instruction. The fix is luac's encoding in `Code.zig`, with
  `luaG_getfuncline`'s lookup in `debuginfo.zig` and the hooks' line
  events, and `dump.zig` then writes it as it is. Not done here.
- **Table headers.** A `Table` is 64 bytes against the reference's 48
  (5.5 keeps `lastfree` in front of the node array; ours is a field,
  and the header's padding cannot hold `flags`). Both round to a 64-byte
  block in their allocators, so RSS does not see it; the count does
  (+16 bytes over 8,500 tables).

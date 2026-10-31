# ReleaseSafe against ReleaseFast and the reference, 2026-10-31

The plan measures `ReleaseFast` builds and runs the suite on
`ReleaseSafe`. This measures what the safe build costs, and where.
`just bench-compare` takes an optimize option for it now:
`just optimize="ReleaseFast ReleaseSafe" bench-compare` builds one arm
per mode.

## Our ReleaseSafe against our ReleaseFast and the reference

`just optimize="ReleaseFast ReleaseSafe" bench-compare 10` on 124cb08:
10 rounds of every `bench/` program on the three arms, interleaved,
pinned to the last core.

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
                  │     ref     │           ours-ReleaseFast           │           ours-ReleaseSafe            │
                  │   sec/op    │    sec/op     vs base                │    sec/op      vs base                │
Lua/array           793.2m ± 9%   816.3m ±  6%        ~ (p=0.481 n=10)   1002.8m ±  6%  +26.42% (p=0.000 n=10)
Lua/binary_trees    803.3m ± 5%   606.0m ±  4%  -24.56% (p=0.000 n=10)    845.0m ±  3%   +5.19% (p=0.005 n=10)
Lua/closures        765.8m ± 5%   554.5m ±  5%  -27.60% (p=0.000 n=10)    809.1m ±  3%   +5.66% (p=0.011 n=10)
Lua/concat          730.2m ± 8%   326.8m ±  5%  -55.24% (p=0.000 n=10)    848.7m ±  6%  +16.23% (p=0.000 n=10)
Lua/coroutines      710.2m ± 2%   395.8m ± 10%  -44.27% (p=0.000 n=10)    542.0m ±  3%  -23.69% (p=0.000 n=10)
Lua/fib             597.4m ± 3%   496.6m ±  2%  -16.88% (p=0.000 n=10)    582.1m ±  3%        ~ (p=0.052 n=10)
Lua/format          812.2m ± 2%   377.3m ±  7%  -53.55% (p=0.000 n=10)    664.3m ±  3%  -18.21% (p=0.000 n=10)
Lua/hash_int        472.0m ± 5%   428.0m ±  3%   -9.32% (p=0.000 n=10)    542.6m ± 12%  +14.96% (p=0.001 n=10)
Lua/hash_string     452.7m ± 9%   396.3m ±  4%  -12.45% (p=0.000 n=10)    459.0m ±  1%        ~ (p=0.631 n=10)
Lua/mandelbrot      694.0m ± 8%   475.3m ±  5%  -31.51% (p=0.000 n=10)    504.3m ±  9%  -27.34% (p=0.000 n=10)
Lua/methods         660.5m ± 5%   591.4m ±  5%  -10.47% (p=0.000 n=10)    782.4m ±  9%  +18.46% (p=0.000 n=10)
Lua/nbody           907.2m ± 8%   696.0m ±  8%  -23.28% (p=0.000 n=10)    802.2m ± 10%  -11.57% (p=0.003 n=10)
Lua/patterns        730.9m ± 8%   606.8m ± 14%  -16.99% (p=0.000 n=10)    636.5m ±  7%  -12.92% (p=0.000 n=10)
Lua/spectral_norm   769.9m ± 3%   719.6m ±  5%   -6.54% (p=0.000 n=10)    775.9m ±  4%        ~ (p=0.796 n=10)
Lua/table_concat    742.3m ± 8%   311.0m ± 10%  -58.10% (p=0.000 n=10)    473.2m ±  7%  -36.26% (p=0.000 n=10)
geomean             698.1m        499.4m        -28.47%                   665.9m         -4.61%

                  │     ref      │           ours-ReleaseFast           │           ours-ReleaseSafe           │
                  │ peak-RSS-KiB │ peak-RSS-KiB  vs base                │ peak-RSS-KiB  vs base                │
Lua/array            35.40k ± 0%    20.94k ± 0%  -40.85% (p=0.000 n=10)    29.28k ± 0%  -17.30% (p=0.000 n=10)
Lua/binary_trees     31.56k ± 0%    26.67k ± 0%  -15.50% (p=0.000 n=10)    26.94k ± 0%  -14.63% (p=0.000 n=10)
Lua/closures         2.926k ± 1%    2.372k ± 0%  -18.93% (p=0.000 n=10)    2.376k ± 0%  -18.80% (p=0.000 n=10)
Lua/concat           2.936k ± 1%    2.370k ± 0%  -19.28% (p=0.000 n=10)    2.372k ± 0%  -19.21% (p=0.000 n=10)
Lua/coroutines       2.882k ± 2%    2.370k ± 0%  -17.77% (p=0.000 n=10)    2.374k ± 0%  -17.63% (p=0.000 n=10)
Lua/fib              2.894k ± 1%    2.372k ± 0%  -18.04% (p=0.000 n=10)    2.372k ± 0%  -18.04% (p=0.000 n=10)
Lua/format           2.934k ± 2%    2.372k ± 0%  -19.15% (p=0.000 n=10)    2.372k ± 0%  -19.15% (p=0.000 n=10)
Lua/hash_int         8.504k ± 0%    6.012k ± 0%  -29.30% (p=0.000 n=10)    6.292k ± 0%  -26.01% (p=0.000 n=10)
Lua/hash_string      22.59k ± 0%    22.39k ± 0%   -0.89% (p=0.000 n=10)    23.13k ± 0%   +2.39% (p=0.000 n=10)
Lua/mandelbrot       3.002k ± 2%    2.372k ± 0%  -20.99% (p=0.000 n=10)    2.372k ± 0%  -20.99% (p=0.000 n=10)
Lua/methods          2.878k ± 1%    2.368k ± 0%  -17.72% (p=0.000 n=10)    2.372k ± 0%  -17.58% (p=0.000 n=10)
Lua/nbody            3.022k ± 2%    2.372k ± 0%  -21.51% (p=0.000 n=10)    2.372k ± 0%  -21.51% (p=0.000 n=10)
Lua/patterns        17.642k ± 0%    9.052k ± 0%  -48.69% (p=0.000 n=10)    9.364k ± 0%  -46.92% (p=0.000 n=10)
Lua/spectral_norm    3.054k ± 2%    2.372k ± 0%  -22.33% (p=0.000 n=10)    2.372k ± 0%  -22.33% (p=0.000 n=10)
Lua/table_concat     40.49k ± 0%    23.11k ± 0%  -42.93% (p=0.000 n=10)    30.76k ± 0%  -24.02% (p=0.000 n=10)
geomean              6.719k         5.067k       -24.59%                   5.326k       -20.73%
```

ReleaseSafe is 33% slower than ReleaseFast on the geomean (665.9 ms
against 499.4 ms) and still 4.6% faster than the reference. It peaks 5%
higher than ReleaseFast (21% below the reference), all of it on the
programs that build big tables and strings: array +40%, table_concat
+33%.

## Where the cost goes

### 1. The standard allocator interface's poisoning: about half

In safe modes `std.mem.Allocator.alloc`, `realloc`, and `free` fill the
memory with `undefined` (0xAA) on every allocation and every free
(`allocBytesWithAlignment`, `realloc`, and `free` in
`std/mem/Allocator.zig`). A perf profile of concat in ReleaseSafe puts
48% of its samples in `compiler_rt.memset`. Filling a fresh block also
touches every page of it, where ReleaseFast leaves the pages of a big
array part's unused capacity unmapped; that is the peak-memory gap.

To size it, a ReleaseSafe build against a copy of Zig 0.16's standard
library with those three memsets deleted (`safe-nopoison`, `zig build
--zig-lib-dir`), in a four-arm run with the cache experiment of
`gettabup-cache-20261031.md` (`ic`, ignore here):

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
                  │     base     │                 ic                  │                  safe                  │            safe-nopoison             │
                  │    sec/op    │    sec/op     vs base               │    sec/op      vs base                 │    sec/op     vs base                │
Lua/array           773.3m ± 10%   771.7m ± 14%       ~ (p=1.000 n=10)   1006.2m ±  7%   +30.13% (p=0.000 n=10)   825.0m ± 10%        ~ (p=0.063 n=10)
Lua/binary_trees    611.8m ±  5%   591.1m ± 15%       ~ (p=0.796 n=10)    828.1m ±  4%   +35.36% (p=0.000 n=10)   796.7m ±  8%  +30.22% (p=0.000 n=10)
Lua/closures        547.9m ±  6%   574.6m ±  5%       ~ (p=0.105 n=10)    802.2m ± 12%   +46.43% (p=0.000 n=10)   742.6m ±  5%  +35.55% (p=0.000 n=10)
Lua/concat          318.5m ±  6%   338.3m ±  9%       ~ (p=0.063 n=10)    857.6m ± 17%  +169.25% (p=0.000 n=10)   385.4m ± 15%  +20.99% (p=0.000 n=10)
Lua/coroutines      391.1m ± 14%   398.9m ±  5%       ~ (p=0.529 n=10)    549.4m ±  8%   +40.47% (p=0.000 n=10)   451.5m ±  8%  +15.44% (p=0.003 n=10)
Lua/fib             490.8m ±  6%   511.4m ±  7%       ~ (p=0.143 n=10)    599.1m ±  9%   +22.07% (p=0.000 n=10)   596.2m ± 11%  +21.47% (p=0.000 n=10)
Lua/format          372.8m ±  8%   355.6m ±  3%  -4.63% (p=0.015 n=10)    675.0m ± 11%   +81.03% (p=0.000 n=10)   640.3m ±  4%  +71.72% (p=0.000 n=10)
Lua/globals         599.5m ± 12%   566.7m ±  6%  -5.47% (p=0.011 n=10)    719.5m ±  5%   +20.01% (p=0.000 n=10)   742.0m ± 13%  +23.77% (p=0.000 n=10)
Lua/hash_int        412.2m ± 14%   423.2m ±  6%       ~ (p=0.529 n=10)    544.3m ±  6%   +32.03% (p=0.000 n=10)   465.5m ± 15%  +12.92% (p=0.011 n=10)
Lua/hash_string     423.5m ± 11%   395.6m ±  9%       ~ (p=0.105 n=10)    474.9m ±  8%   +12.14% (p=0.002 n=10)   435.5m ±  6%        ~ (p=0.529 n=10)
Lua/mandelbrot      489.1m ± 29%   475.9m ± 15%       ~ (p=0.579 n=10)    539.2m ± 21%         ~ (p=0.063 n=10)   547.5m ±  9%        ~ (p=0.052 n=10)
Lua/methods         599.6m ±  6%   608.9m ± 15%       ~ (p=0.280 n=10)    761.5m ± 29%   +27.00% (p=0.001 n=10)   718.9m ± 16%  +19.91% (p=0.001 n=10)
Lua/nbody           706.2m ± 11%   694.8m ±  5%       ~ (p=0.436 n=10)    796.2m ±  6%   +12.75% (p=0.004 n=10)   778.8m ±  7%  +10.27% (p=0.035 n=10)
Lua/patterns        603.6m ± 18%   572.6m ± 14%       ~ (p=0.089 n=10)    637.9m ± 10%         ~ (p=0.075 n=10)   619.1m ±  7%        ~ (p=0.280 n=10)
Lua/spectral_norm   700.0m ±  4%   713.6m ±  5%       ~ (p=0.684 n=10)    800.5m ±  6%   +14.36% (p=0.001 n=10)   764.3m ± 11%   +9.19% (p=0.001 n=10)
Lua/table_concat    290.5m ± 30%   291.3m ± 12%       ~ (p=0.684 n=10)    442.2m ± 26%   +52.24% (p=0.000 n=10)   358.4m ± 10%  +23.38% (p=0.011 n=10)
geomean             500.9m         498.7m        -0.45%                   672.5m         +34.24%                  596.0m        +18.98%

                  │     base     │                 ic                  │                 safe                 │            safe-nopoison            │
                  │ peak-RSS-KiB │ peak-RSS-KiB  vs base               │ peak-RSS-KiB  vs base                │ peak-RSS-KiB  vs base               │
Lua/array            20.93k ± 0%    20.93k ± 0%  -0.01% (p=0.005 n=10)    29.28k ± 0%  +39.86% (p=0.000 n=10)    21.20k ± 0%  +1.28% (p=0.000 n=10)
Lua/binary_trees     26.63k ± 0%    26.61k ± 0%  -0.08% (p=0.000 n=10)    26.91k ± 0%   +1.07% (p=0.000 n=10)    26.89k ± 0%  +0.99% (p=0.000 n=10)
Lua/closures         2.372k ± 0%    2.372k ± 0%       ~ (p=0.731 n=10)    2.372k ± 0%        ~ (p=0.777 n=10)    2.372k ± 0%       ~ (p=0.838 n=10)
Lua/concat           2.372k ± 0%    2.372k ± 0%       ~ (p=0.725 n=10)    2.374k ± 0%        ~ (p=0.942 n=10)    2.372k ± 0%       ~ (p=0.978 n=10)
Lua/coroutines       2.374k ± 0%    2.372k ± 0%       ~ (p=0.357 n=10)    2.372k ± 0%        ~ (p=0.401 n=10)    2.372k ± 0%       ~ (p=0.536 n=10)
Lua/fib              2.372k ± 0%    2.372k ± 0%       ~ (p=0.237 n=10)    2.374k ± 0%        ~ (p=0.127 n=10)    2.372k ± 0%       ~ (p=1.000 n=10)
Lua/format           2.372k ± 0%    2.372k ± 0%       ~ (p=0.854 n=10)    2.372k ± 0%        ~ (p=0.854 n=10)    2.372k ± 0%       ~ (p=0.991 n=10)
Lua/globals          2.372k ± 0%    2.374k ± 0%  +0.08% (p=0.039 n=10)    2.372k ± 0%        ~ (p=0.303 n=10)    2.374k ± 0%       ~ (p=0.081 n=10)
Lua/hash_int         6.006k ± 0%    6.004k ± 0%  -0.03% (p=0.014 n=10)    6.288k ± 0%   +4.70% (p=0.000 n=10)    6.268k ± 0%  +4.36% (p=0.000 n=10)
Lua/hash_string      22.38k ± 0%    22.38k ± 0%  -0.02% (p=0.000 n=10)    23.12k ± 0%   +3.31% (p=0.000 n=10)    22.62k ± 0%  +1.07% (p=0.000 n=10)
Lua/mandelbrot       2.372k ± 1%    2.370k ± 0%       ~ (p=0.336 n=10)    2.372k ± 0%        ~ (p=0.352 n=10)    2.368k ± 0%       ~ (p=0.176 n=10)
Lua/methods          2.372k ± 0%    2.374k ± 0%       ~ (p=0.233 n=10)    2.372k ± 0%        ~ (p=0.546 n=10)    2.372k ± 0%       ~ (p=0.974 n=10)
Lua/nbody            2.372k ± 0%    2.372k ± 0%       ~ (p=0.551 n=10)    2.372k ± 0%        ~ (p=0.750 n=10)    2.372k ± 0%       ~ (p=0.538 n=10)
Lua/patterns         9.052k ± 0%    9.048k ± 0%  -0.04% (p=0.000 n=10)    9.364k ± 0%   +3.45% (p=0.000 n=10)    9.296k ± 0%  +2.70% (p=0.000 n=10)
Lua/spectral_norm    2.372k ± 0%    2.372k ± 0%       ~ (p=0.363 n=10)    2.372k ± 0%        ~ (p=0.768 n=10)    2.372k ± 0%       ~ (p=0.998 n=10)
Lua/table_concat     23.10k ± 0%    23.10k ± 0%  -0.01% (p=0.005 n=10)    30.76k ± 0%  +33.15% (p=0.000 n=10)    23.34k ± 0%  +1.03% (p=0.000 n=10)
geomean              4.832k         4.832k       -0.01%                   5.063k        +4.77%                   4.866k       +0.70%
```

Without the poisoning ReleaseSafe is 19% slower than ReleaseFast instead
of 34% in this run, and its peak memory is within 1.3% on every program
(array +1.3%, table_concat +1.0%, against +40% and +33%). concat goes
from +169% to +21%.

### 2. `string.format`'s buffer declared `undefined`: 23% of format

With the allocator's memsets gone, format still spends 23% of its
ReleaseSafe samples in `compiler_rt.memset`, called from
`lib.string.format` itself. A frame-pointer build's profile and the
disassembly place it at `var b: auxlib.Buffer = undefined;`
(`src/lib/string.zig`, in `format`): a safe build writes 0xAA over the
whole 1,096-byte `auxlib.Buffer`, with its 1 KiB inline buffer, on every
call. The other buffers declared that way (`table.concat`, `gsub`,
`string.pack`, `string.dump`) pay the same per call. Clearing
`Buffer.deinit`'s `b.* = undefined` alone did not change format's time.

### 3. The allocator itself: about 40% more time

`std.heap.SmpAllocator`'s safe build runs its own checks, and its
`Thread.lock` is no longer inlined. In binary_trees the allocator's
samples (alloc, free, and lock) grow from 301M to 424M
(task-clock samples), +41%; in closures from 228M
to 320M.

### 4. The interpreter loop: spread out, no single site

fib spends all its time in `runLoop`, and its safe build (without the
poisoning) is 19% slower (625M against 745M samples). The checks are
spread over every instruction: the dispatch switch's check that the
opcode is a valid `OpCode` (a compare and branch before each indirect
jump, 144 sites per instance of the loop), overflow checks on the
`u32` frame and stack index arithmetic in `pushLuaFrame`, and bounds
checks on `th.stack` slices. The hottest instructions in the safe
profile are the same loads that are hottest in ReleaseFast.

No `@setRuntimeSafety(false)` is added. The one check that is per
instruction, the opcode's validity, can fire: `undump.zig` loads
instructions from binary chunks without checking their opcodes, so a
corrupted chunk reaches the switch with a value outside `OpCode`, which
ReleaseSafe catches and ReleaseFast does not (PUC-Rio does not check
either). If the loader validated opcodes, that check could not fire;
it is one compare per instruction, not where the cost is.

## What this means

ReleaseSafe's cost is mostly not the interpreter's checks. Half of it,
and all of the extra memory, is the allocator interface poisoning
memory, which is standard library behavior in safe builds; another
large part is the poisoning of `undefined` locals and the allocator's
own safe build. A ReleaseSafe build is still faster than reference Lua
on the geomean. Who owns what:

- The standard library's poisoning: nothing to do in this repository
  short of calling `rawAlloc`/`rawFree` instead of `alloc`/`free`, which
  gives up the poisoning that safe builds exist to have. Not done.
- `auxlib.Buffer` (the libraries' owner): declaring the 1 KiB buffer
  `undefined` costs safe builds a 1 KiB memset per `string.format`,
  `table.concat`, and `gsub` call.

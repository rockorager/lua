# Zig 0.17.1: the toolchain upgrade against 0.16.0, 2026-11-05

The move from Zig 0.16.0 to 0.17.1 (LLVM 22) changes the code generated
for every hot path at once, so it gets the same A/B as a hot-path change.
The source changes are API ports only (`@typeInfo`'s struct-of-arrays
shape, `@splat` for `**`, `std.lang`, `Allocator.print`, `mem.print`,
`SafeAllocator`, `Io.VTable`'s renamed entries); `src/order.ld` was
regenerated with `just order` because 0.17 names several functions
differently (232 of its 339 entries still matched before).

Machine: the orb's 4-core Intel Xeon @ 2.60GHz, kernel 6.1. ReleaseFast
builds: `zig-0.16` is HEAD (db83faf) built by 0.16.0, `zig-0.17` the
upgrade built by 0.17.1. 10 interleaved rounds of every `bench/` program
plus `lua -e ''` (`startup`), each pinned to core 3 with `taskset`, wall
time and GNU time's peak RSS, outputs checked against the reference's,
then benchstat. Same method as `just bench-compare`, with a third arm.

Headlines:

- Time, geomean −1.6%. Faster: coroutines −18%, format −10%, hash_int
  −10%, concat −7%, config −5%, patterns −4%. Slower: methods +13.7%,
  binary_trees +3.7%, fib +2.3%. The rest within noise.
- Peak RSS, geomean +2.9%: eight small programs gain one 64 KiB step
  (692 to 756 KiB and similar), the code fault-around granule; text grew
  776 KB to 811 KB. Startup is unchanged at 560 KiB.
- Against the reference, 0.17 is −28.8% time (0.16: −27.6%); methods
  drops from −19% to −8% faster than the reference.
- Not yet investigated: why `methods` (the `__index` chain and
  metamethod calls) lost 14%.

Text size (`size`, ReleaseFast default build): 0.16 775781 bytes, 0.17 810808.

## Raw output

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
                  │   zig-0.16   │               zig-0.17               │
                  │    sec/op    │    sec/op     vs base                │
Lua/startup         2.512m ± 10%   2.478m ±  5%        ~ (p=0.280 n=10)
Lua/array           522.3m ±  6%   537.3m ±  5%        ~ (p=0.247 n=10)
Lua/binary_trees    482.0m ±  1%   500.0m ±  7%   +3.73% (p=0.000 n=10)
Lua/closures        452.4m ±  6%   458.8m ±  2%        ~ (p=0.280 n=10)
Lua/concat          266.2m ±  9%   248.6m ±  3%   -6.62% (p=0.001 n=10)
Lua/config          428.1m ±  9%   408.4m ±  2%   -4.60% (p=0.003 n=10)
Lua/coroutines      321.3m ± 13%   262.7m ±  6%  -18.23% (p=0.000 n=10)
Lua/fib             403.1m ±  3%   412.3m ±  4%   +2.27% (p=0.023 n=10)
Lua/format          298.0m ±  4%   268.2m ±  9%   -9.98% (p=0.002 n=10)
Lua/globals         447.3m ±  5%   448.2m ±  3%        ~ (p=0.739 n=10)
Lua/hash_int        415.8m ±  5%   376.1m ±  7%   -9.56% (p=0.002 n=10)
Lua/hash_string     387.2m ±  5%   394.4m ±  5%        ~ (p=0.353 n=10)
Lua/json            442.8m ± 10%   455.7m ± 11%        ~ (p=0.853 n=10)
Lua/mandelbrot      399.1m ±  2%   392.7m ±  4%        ~ (p=0.481 n=10)
Lua/methods         453.5m ±  1%   515.9m ±  2%  +13.74% (p=0.000 n=10)
Lua/nbody           550.4m ±  2%   557.6m ±  2%        ~ (p=0.089 n=10)
Lua/oop             513.0m ±  2%   515.0m ±  2%        ~ (p=0.796 n=10)
Lua/patterns        476.2m ± 11%   457.0m ±  1%   -4.03% (p=0.000 n=10)
Lua/spectral_norm   596.6m ±  3%   580.4m ±  5%        ~ (p=0.063 n=10)
Lua/table_concat    240.7m ±  3%   241.0m ±  3%        ~ (p=0.912 n=10)
Lua/template        462.5m ±  7%   454.0m ±  7%        ~ (p=0.315 n=10)
geomean             327.2m         321.9m         -1.62%

                  │   zig-0.16   │                zig-0.17                │
                  │ peak-RSS-KiB │ peak-RSS-KiB  vs base                  │
Lua/startup           560.0 ± 0%     560.0 ± 0%        ~ (p=1.000 n=10) ¹
Lua/array            19.99k ± 0%    19.99k ± 0%        ~ (p=1.000 n=10) ¹
Lua/binary_trees     25.55k ± 0%    25.55k ± 0%        ~ (p=1.000 n=10) ¹
Lua/closures          716.0 ± 0%     716.0 ± 0%        ~ (p=1.000 n=10) ¹
Lua/concat            692.0 ± 0%     756.0 ± 0%   +9.25% (p=0.000 n=10)
Lua/config           10.79k ± 0%    10.79k ± 0%   +0.04% (p=0.000 n=10)
Lua/coroutines        712.0 ± 0%     776.0 ± 0%   +8.99% (p=0.000 n=10)
Lua/fib               636.0 ± 0%     636.0 ± 0%        ~ (p=1.000 n=10) ¹
Lua/format            792.0 ± 0%     792.0 ± 0%        ~ (p=1.000 n=10) ¹
Lua/globals           700.0 ± 0%     764.0 ± 0%   +9.14% (p=0.000 n=10)
Lua/hash_int         5.056k ± 0%    5.056k ± 0%        ~ (p=1.000 n=10) ¹
Lua/hash_string      21.41k ± 0%    21.41k ± 0%        ~ (p=1.000 n=10) ¹
Lua/json             9.784k ± 0%    9.852k ± 0%   +0.70% (p=0.000 n=10)
Lua/mandelbrot        636.0 ± 0%     700.0 ± 0%  +10.06% (p=0.000 n=10)
Lua/methods           716.0 ± 0%     716.0 ± 0%        ~ (p=1.000 n=10) ¹
Lua/nbody             776.0 ± 0%     840.0 ± 0%   +8.25% (p=0.000 n=10)
Lua/oop              8.700k ± 0%    8.764k ± 0%   +0.74% (p=0.000 n=10)
Lua/patterns         8.276k ± 0%    8.276k ± 0%        ~ (p=1.000 n=10) ¹
Lua/spectral_norm     756.0 ± 0%     820.0 ± 0%   +8.47% (p=0.000 n=10)
Lua/table_concat     22.20k ± 0%    22.26k ± 0%   +0.29% (p=0.000 n=10)
Lua/template         1.116k ± 0%    1.180k ± 0%   +5.73% (p=0.000 n=10)
geomean              2.481k         2.552k        +2.86%
¹ all samples are equal

cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
                  │     ref      │               zig-0.16               │               zig-0.17               │
                  │    sec/op    │    sec/op     vs base                │    sec/op     vs base                │
Lua/startup         3.161m ± 16%   2.512m ± 10%  -20.52% (p=0.000 n=10)   2.478m ±  5%  -21.61% (p=0.000 n=10)
Lua/array           659.2m ±  4%   522.3m ±  6%  -20.77% (p=0.000 n=10)   537.3m ±  5%  -18.49% (p=0.000 n=10)
Lua/binary_trees    698.0m ±  3%   482.0m ±  1%  -30.94% (p=0.000 n=10)   500.0m ±  7%  -28.36% (p=0.000 n=10)
Lua/closures        647.7m ±  2%   452.4m ±  6%  -30.16% (p=0.000 n=10)   458.8m ±  2%  -29.16% (p=0.000 n=10)
Lua/concat          595.0m ±  4%   266.2m ±  9%  -55.27% (p=0.000 n=10)   248.6m ±  3%  -58.23% (p=0.000 n=10)
Lua/config          526.6m ±  5%   428.1m ±  9%  -18.70% (p=0.000 n=10)   408.4m ±  2%  -22.44% (p=0.000 n=10)
Lua/coroutines      538.6m ±  2%   321.3m ± 13%  -40.35% (p=0.000 n=10)   262.7m ±  6%  -51.22% (p=0.000 n=10)
Lua/fib             482.6m ±  3%   403.1m ±  3%  -16.47% (p=0.000 n=10)   412.3m ±  4%  -14.57% (p=0.000 n=10)
Lua/format          637.8m ±  3%   298.0m ±  4%  -53.28% (p=0.000 n=10)   268.2m ±  9%  -57.94% (p=0.000 n=10)
Lua/globals         618.8m ± 11%   447.3m ±  5%  -27.71% (p=0.000 n=10)   448.2m ±  3%  -27.57% (p=0.000 n=10)
Lua/hash_int        485.3m ± 10%   415.8m ±  5%  -14.32% (p=0.000 n=10)   376.1m ±  7%  -22.51% (p=0.000 n=10)
Lua/hash_string     454.9m ±  4%   387.2m ±  5%  -14.89% (p=0.000 n=10)   394.4m ±  5%  -13.31% (p=0.000 n=10)
Lua/json            544.9m ±  9%   442.8m ± 10%  -18.74% (p=0.000 n=10)   455.7m ± 11%  -16.37% (p=0.000 n=10)
Lua/mandelbrot      561.3m ±  4%   399.1m ±  2%  -28.89% (p=0.000 n=10)   392.7m ±  4%  -30.04% (p=0.000 n=10)
Lua/methods         561.7m ±  3%   453.5m ±  1%  -19.26% (p=0.000 n=10)   515.9m ±  2%   -8.16% (p=0.001 n=10)
Lua/nbody           720.6m ±  6%   550.4m ±  2%  -23.61% (p=0.000 n=10)   557.6m ±  2%  -22.61% (p=0.000 n=10)
Lua/oop             553.3m ±  5%   513.0m ±  2%   -7.29% (p=0.000 n=10)   515.0m ±  2%   -6.92% (p=0.000 n=10)
Lua/patterns        545.5m ±  4%   476.2m ± 11%  -12.70% (p=0.000 n=10)   457.0m ±  1%  -16.21% (p=0.000 n=10)
Lua/spectral_norm   643.3m ±  2%   596.6m ±  3%   -7.26% (p=0.000 n=10)   580.4m ±  5%   -9.78% (p=0.000 n=10)
Lua/table_concat    655.6m ±  4%   240.7m ±  3%  -63.28% (p=0.000 n=10)   241.0m ±  3%  -63.24% (p=0.000 n=10)
Lua/template        547.8m ±  4%   462.5m ±  7%  -15.58% (p=0.000 n=10)   454.0m ±  7%  -17.13% (p=0.000 n=10)
geomean             452.2m         327.2m        -27.63%                  321.9m        -28.80%

                  │      ref      │               zig-0.16               │               zig-0.17               │
                  │ peak-RSS-KiB  │ peak-RSS-KiB  vs base                │ peak-RSS-KiB  vs base                │
Lua/startup          2664.0 ±  0%     560.0 ± 0%  -78.98% (p=0.000 n=10)     560.0 ± 0%  -78.98% (p=0.000 n=10)
Lua/array            35.46k ±  0%    19.99k ± 0%  -43.63% (p=0.000 n=10)    19.99k ± 0%  -43.63% (p=0.000 n=10)
Lua/binary_trees     31.60k ±  0%    25.55k ± 0%  -19.13% (p=0.000 n=10)    25.55k ± 0%  -19.13% (p=0.000 n=10)
Lua/closures         2968.0 ±  0%     716.0 ± 0%  -75.88% (p=0.000 n=10)     716.0 ± 0%  -75.88% (p=0.000 n=10)
Lua/concat           2988.0 ±  0%     692.0 ± 0%  -76.84% (p=0.000 n=10)     756.0 ± 0%  -74.70% (p=0.000 n=10)
Lua/config           13.07k ± 14%    10.79k ± 0%  -17.45% (p=0.001 n=10)    10.79k ± 0%  -17.42% (p=0.001 n=10)
Lua/coroutines       2940.0 ±  0%     712.0 ± 0%  -75.78% (p=0.000 n=10)     776.0 ± 0%  -73.61% (p=0.000 n=10)
Lua/fib              2932.0 ±  0%     636.0 ± 0%  -78.31% (p=0.000 n=10)     636.0 ± 0%  -78.31% (p=0.000 n=10)
Lua/format           2992.0 ±  0%     792.0 ± 0%  -73.53% (p=0.000 n=10)     792.0 ± 0%  -73.53% (p=0.000 n=10)
Lua/globals          2944.0 ±  0%     700.0 ± 0%  -76.22% (p=0.000 n=10)     764.0 ± 0%  -74.05% (p=0.000 n=10)
Lua/hash_int         8.532k ±  0%    5.056k ± 0%  -40.74% (p=0.000 n=10)    5.056k ± 0%  -40.74% (p=0.000 n=10)
Lua/hash_string      22.63k ±  0%    21.41k ± 0%   -5.41% (p=0.000 n=10)    21.41k ± 0%   -5.41% (p=0.000 n=10)
Lua/json            12.180k ±  0%    9.784k ± 0%  -19.67% (p=0.000 n=10)    9.852k ± 0%  -19.11% (p=0.000 n=10)
Lua/mandelbrot       2984.0 ±  0%     636.0 ± 0%  -78.69% (p=0.000 n=10)     700.0 ± 0%  -76.54% (p=0.000 n=10)
Lua/methods          2944.0 ±  0%     716.0 ± 0%  -75.68% (p=0.000 n=10)     716.0 ± 0%  -75.68% (p=0.000 n=10)
Lua/nbody            2996.0 ±  0%     776.0 ± 0%  -74.10% (p=0.000 n=10)     840.0 ± 0%  -71.96% (p=0.000 n=10)
Lua/oop             11.322k ±  1%    8.700k ± 0%  -23.16% (p=0.000 n=10)    8.764k ± 0%  -22.59% (p=0.000 n=10)
Lua/patterns        17.688k ±  0%    8.276k ± 0%  -53.21% (p=0.000 n=10)    8.276k ± 0%  -53.21% (p=0.000 n=10)
Lua/spectral_norm    3020.0 ±  0%     756.0 ± 0%  -74.97% (p=0.000 n=10)     820.0 ± 0%  -72.85% (p=0.000 n=10)
Lua/table_concat     40.52k ±  0%    22.20k ± 0%  -45.23% (p=0.000 n=10)    22.26k ± 0%  -45.07% (p=0.000 n=10)
Lua/template         3.212k ±  0%    1.116k ± 0%  -65.26% (p=0.000 n=10)    1.180k ± 0%  -63.26% (p=0.000 n=10)
geomean              6.526k          2.481k       -61.98%                   2.552k       -60.90%
```

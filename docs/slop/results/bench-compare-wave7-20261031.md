# Wave 7 against the reference, 2026-10-31

`just optimize="ReleaseFast ReleaseSafe" bench-compare 10` at the end of
wave 7 (line information in luac's encoding, `lineinfo-20261031.md`, and
objects allocated without the safe build's fill,
`safe-poison-20261031.md`): our ReleaseFast and ReleaseSafe builds
against reference Lua 5.5.1 from the dev shell, 10 rounds of every
`bench/` program, interleaved, pinned to one core, wall time and peak
RSS per process.

ReleaseFast is 25.9% faster on the geomean with 22.7% lower peak RSS
(wave 6: −26.8% and −22.8%). Neither change touches ReleaseFast's
interpreter loop, so read that as level; the machine's reference times
moved again (array 644 ms against 913 ms in wave 6), so compare ratios.
array is level with the reference this run (+0.6%, p=0.68; −4.1% in
wave 6). Line information shows in the compiled code, not in these
peaks: config's chunk holds 184 KiB less, but config's peak is its
tables (11.46 MB, the reference bimodal at 10.7 or 13.0 MB).

ReleaseSafe is now 15.6% faster than the reference (wave 6: 6.8%) and
peaks 21.8% lower (wave 6: 18.7%). Of wave 6's three programs slower
than the reference in ReleaseSafe, template is now 4.5% faster (was
+10.9%) and config level (was +7.2%). oop (+10.1%) and methods (+6.8%)
remain slower: their safe-build cost is the interpreter loop's own
checks, which the fill was never part of (`release-safe-20261031.md`,
section 4). hash_string peaks 0.6% above the reference in ReleaseSafe
(ReleaseFast −0.85%); json, which peaked 1.4% above in wave 6, is now
11.3% below.

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
                  │     ref      │           ours-ReleaseFast           │           ours-ReleaseSafe           │
                  │    sec/op    │    sec/op     vs base                │    sec/op     vs base                │
Lua/array           643.7m ±  5%   647.7m ±  3%        ~ (p=0.684 n=10)   657.8m ±  3%        ~ (p=0.123 n=10)
Lua/binary_trees    674.6m ±  6%   514.5m ±  6%  -23.74% (p=0.000 n=10)   634.3m ±  2%   -5.97% (p=0.000 n=10)
Lua/closures        631.2m ±  2%   430.8m ± 14%  -31.74% (p=0.000 n=10)   583.8m ±  5%   -7.50% (p=0.000 n=10)
Lua/concat          579.7m ±  3%   270.8m ±  4%  -53.28% (p=0.000 n=10)   315.8m ±  9%  -45.52% (p=0.000 n=10)
Lua/config          533.8m ±  2%   439.7m ± 10%  -17.63% (p=0.000 n=10)   523.4m ±  8%        ~ (p=0.579 n=10)
Lua/coroutines      538.2m ±  5%   333.4m ±  3%  -38.04% (p=0.000 n=10)   384.0m ±  3%  -28.65% (p=0.000 n=10)
Lua/fib             485.1m ±  3%   426.9m ±  2%  -11.99% (p=0.000 n=10)   447.2m ±  3%   -7.80% (p=0.000 n=10)
Lua/format          647.3m ±  3%   311.8m ±  2%  -51.83% (p=0.000 n=10)   378.6m ±  2%  -41.51% (p=0.000 n=10)
Lua/globals         593.5m ±  4%   463.8m ±  4%  -21.85% (p=0.000 n=10)   582.0m ±  4%        ~ (p=0.353 n=10)
Lua/hash_int        540.9m ±  7%   418.6m ± 10%  -22.61% (p=0.000 n=10)   475.6m ±  4%  -12.07% (p=0.000 n=10)
Lua/hash_string     495.3m ±  5%   421.6m ±  4%  -14.87% (p=0.000 n=10)   441.1m ±  5%  -10.95% (p=0.000 n=10)
Lua/json            539.6m ±  3%   444.6m ±  1%  -17.61% (p=0.000 n=10)   509.5m ±  5%   -5.58% (p=0.000 n=10)
Lua/mandelbrot      556.2m ±  3%   375.7m ±  1%  -32.46% (p=0.000 n=10)   377.8m ±  2%  -32.07% (p=0.000 n=10)
Lua/methods         546.7m ±  4%   483.9m ±  5%  -11.48% (p=0.000 n=10)   583.8m ±  5%   +6.79% (p=0.002 n=10)
Lua/nbody           705.3m ±  4%   570.7m ± 11%  -19.09% (p=0.000 n=10)   577.4m ± 11%  -18.15% (p=0.000 n=10)
Lua/oop             555.8m ± 10%   526.4m ±  7%   -5.30% (p=0.019 n=10)   612.0m ±  3%  +10.11% (p=0.005 n=10)
Lua/patterns        538.9m ±  2%   468.2m ±  2%  -13.12% (p=0.000 n=10)   496.9m ±  2%   -7.79% (p=0.000 n=10)
Lua/spectral_norm   645.5m ±  7%   574.5m ±  3%  -10.99% (p=0.000 n=10)   608.6m ±  3%   -5.72% (p=0.000 n=10)
Lua/table_concat    652.1m ±  8%   249.4m ±  9%  -61.75% (p=0.000 n=10)   304.8m ±  5%  -53.26% (p=0.000 n=10)
Lua/template        542.2m ±  4%   449.4m ±  4%  -17.11% (p=0.000 n=10)   517.9m ±  6%   -4.49% (p=0.009 n=10)
geomean             579.2m         429.4m        -25.85%                  488.8m        -15.60%

                  │      ref      │           ours-ReleaseFast           │           ours-ReleaseSafe           │
                  │ peak-RSS-KiB  │ peak-RSS-KiB  vs base                │ peak-RSS-KiB  vs base                │
Lua/array            35.42k ±  0%    20.98k ± 0%  -40.77% (p=0.000 n=10)    21.30k ± 0%  -39.86% (p=0.000 n=10)
Lua/binary_trees     31.55k ±  0%    26.44k ± 0%  -16.22% (p=0.000 n=10)    26.75k ± 0%  -15.22% (p=0.000 n=10)
Lua/closures         2.894k ±  1%    2.372k ± 0%  -18.04% (p=0.000 n=10)    2.372k ± 0%  -18.04% (p=0.000 n=10)
Lua/concat           2.936k ±  1%    2.372k ± 0%  -19.21% (p=0.000 n=10)    2.376k ± 0%  -19.07% (p=0.000 n=10)
Lua/config           13.02k ± 17%    11.46k ± 0%        ~ (p=0.459 n=10)    11.79k ± 0%        ~ (p=0.461 n=10)
Lua/coroutines       2.890k ±  1%    2.372k ± 0%  -17.92% (p=0.000 n=10)    2.372k ± 0%  -17.92% (p=0.000 n=10)
Lua/fib              2.860k ±  1%    2.372k ± 0%  -17.06% (p=0.000 n=10)    2.372k ± 0%  -17.06% (p=0.000 n=10)
Lua/format           2.942k ±  1%    2.372k ± 0%  -19.37% (p=0.000 n=10)    2.372k ± 0%  -19.37% (p=0.000 n=10)
Lua/globals          2.888k ±  1%    2.374k ± 0%  -17.80% (p=0.000 n=10)    2.374k ± 0%  -17.80% (p=0.000 n=10)
Lua/hash_int         8.484k ±  0%    6.046k ± 0%  -28.74% (p=0.000 n=10)    6.364k ± 0%  -24.99% (p=0.000 n=10)
Lua/hash_string      22.59k ±  0%    22.40k ± 0%   -0.85% (p=0.000 n=10)    22.72k ± 0%   +0.58% (p=0.000 n=10)
Lua/json             12.15k ±  0%    10.46k ± 0%  -13.92% (p=0.000 n=10)    10.78k ± 0%  -11.26% (p=0.000 n=10)
Lua/mandelbrot       3.014k ±  2%    2.372k ± 0%  -21.30% (p=0.000 n=10)    2.372k ± 0%  -21.30% (p=0.000 n=10)
Lua/methods          2.886k ±  1%    2.372k ± 0%  -17.81% (p=0.000 n=10)    2.372k ± 0%  -17.81% (p=0.000 n=10)
Lua/nbody            3.012k ±  2%    2.374k ± 0%  -21.18% (p=0.000 n=10)    2.372k ± 0%  -21.25% (p=0.000 n=10)
Lua/oop             11.354k ±  0%    9.478k ± 0%  -16.52% (p=0.000 n=10)    9.812k ± 0%  -13.58% (p=0.000 n=10)
Lua/patterns        17.620k ±  0%    9.004k ± 0%  -48.90% (p=0.000 n=10)    9.328k ± 0%  -47.06% (p=0.000 n=10)
Lua/spectral_norm    3.058k ±  2%    2.372k ± 0%  -22.43% (p=0.000 n=10)    2.374k ± 0%  -22.37% (p=0.000 n=10)
Lua/table_concat     40.46k ±  0%    23.12k ± 0%  -42.86% (p=0.000 n=10)    23.44k ± 0%  -42.06% (p=0.000 n=10)
Lua/template         3.162k ±  2%    2.372k ± 0%  -24.98% (p=0.000 n=10)    2.372k ± 0%  -24.98% (p=0.000 n=10)
geomean              6.775k          5.234k       -22.74%                   5.296k       -21.82%
```

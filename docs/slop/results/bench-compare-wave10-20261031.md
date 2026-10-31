# Wave 10 against the reference, 2026-10-31

`just optimize="ReleaseFast ReleaseSafe ReleaseFast-capi" bench-compare
10` at the end of wave 10 (leanness, `lean-20261031.md`): our
ReleaseFast, ReleaseSafe, and C-API ReleaseFast builds against
reference Lua 5.5.1 from the dev shell, 10 rounds of every `bench/`
program, interleaved, pinned to one core, wall time and peak RSS per
process (GNU time under taskset).

ReleaseFast is 28.4% faster on the geomean with 60.6% lower peak RSS
(wave 9: −28.6% and −44.1%). ReleaseSafe is 20.1% faster and peaks
58.0% lower (wave 9: −18.7% and −36.3%). The C-API build, new to this
comparison, is 28.2% faster and peaks 24.9% lower; wave 8 measured it
at −18.7% to −22.7% and −4.9% (`c-api-20261031.md`). Every program is
faster than the reference in every build except oop in ReleaseSafe,
which is level (p = 0.075); methods in ReleaseSafe is 1.4% faster. The machine ran
faster than in wave 9 (the reference's geomean 666 ms against 779), so
compare ratios.

Peak RSS: every program peaks below the reference in ReleaseFast and
ReleaseSafe; the small programs, which are the floor, peak at 636 to
788 KiB in ReleaseFast against the reference's 2.8 to 3.0 MiB (wave 9:
1.29 to 1.37 MiB). In the C-API build they peak at 2.0 to 2.2 MiB, a
quarter below the reference, and only hash_string peaks above it
(+0.7%, 22.8 MiB against 22.6). config's reading on the reference is
bimodal (10.7 or 13.0 MB), as in wave 9.

The time is wave 9's: no change of this wave touched the default
build's loop (its code is byte for byte the same), and the code
around it moved, which shifts single programs by a few percent either
way (`lean-20261031.md`, Speed). The memory is the wave's: less code
mapped at startup (556 KiB floor against 1216).

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
                  │     ref     │          ours-ReleaseFast           │          ours-ReleaseSafe           │        ours-ReleaseFast-capi        │
                  │   sec/op    │   sec/op     vs base                │   sec/op     vs base                │   sec/op     vs base                │
Lua/array           765.9m ± 3%   592.9m ± 1%  -22.59% (p=0.000 n=10)   629.3m ± 1%  -17.83% (p=0.000 n=10)   594.6m ± 2%  -22.37% (p=0.000 n=10)
Lua/binary_trees    791.8m ± 2%   564.0m ± 1%  -28.77% (p=0.000 n=10)   718.3m ± 2%   -9.28% (p=0.000 n=10)   577.1m ± 2%  -27.11% (p=0.000 n=10)
Lua/closures        742.8m ± 1%   536.7m ± 2%  -27.75% (p=0.000 n=10)   667.8m ± 1%  -10.10% (p=0.000 n=10)   539.3m ± 2%  -27.39% (p=0.000 n=10)
Lua/concat          703.6m ± 2%   310.9m ± 1%  -55.82% (p=0.000 n=10)   372.3m ± 1%  -47.09% (p=0.000 n=10)   318.5m ± 2%  -54.73% (p=0.000 n=10)
Lua/config          598.5m ± 1%   483.5m ± 1%  -19.22% (p=0.000 n=10)   568.1m ± 1%   -5.07% (p=0.000 n=10)   480.0m ± 1%  -19.80% (p=0.000 n=10)
Lua/coroutines      695.6m ± 2%   378.0m ± 1%  -45.65% (p=0.000 n=10)   434.1m ± 2%  -37.59% (p=0.000 n=10)   381.9m ± 1%  -45.10% (p=0.000 n=10)
Lua/fib             566.6m ± 1%   476.1m ± 1%  -15.97% (p=0.000 n=10)   523.6m ± 1%   -7.59% (p=0.000 n=10)   486.2m ± 1%  -14.20% (p=0.000 n=10)
Lua/format          785.8m ± 1%   367.2m ± 2%  -53.28% (p=0.000 n=10)   442.0m ± 1%  -43.76% (p=0.000 n=10)   366.7m ± 1%  -53.33% (p=0.000 n=10)
Lua/globals         725.4m ± 3%   521.4m ± 4%  -28.13% (p=0.000 n=10)   609.6m ± 2%  -15.97% (p=0.000 n=10)   522.3m ± 2%  -28.00% (p=0.000 n=10)
Lua/hash_int        465.2m ± 2%   404.6m ± 2%  -13.03% (p=0.000 n=10)   428.4m ± 2%   -7.91% (p=0.000 n=10)   415.4m ± 2%  -10.70% (p=0.000 n=10)
Lua/hash_string     442.4m ± 1%   383.8m ± 1%  -13.26% (p=0.000 n=10)   391.5m ± 1%  -11.52% (p=0.000 n=10)   391.8m ± 1%  -11.45% (p=0.000 n=10)
Lua/json            636.0m ± 3%   501.5m ± 2%  -21.15% (p=0.000 n=10)   575.2m ± 1%   -9.56% (p=0.000 n=10)   499.8m ± 2%  -21.41% (p=0.000 n=10)
Lua/mandelbrot      673.8m ± 1%   461.8m ± 1%  -31.47% (p=0.000 n=10)   452.6m ± 1%  -32.83% (p=0.000 n=10)   463.4m ± 1%  -31.23% (p=0.000 n=10)
Lua/methods         621.5m ± 1%   541.9m ± 4%  -12.81% (p=0.000 n=10)   613.1m ± 2%   -1.35% (p=0.037 n=10)   521.0m ± 3%  -16.18% (p=0.000 n=10)
Lua/nbody           862.7m ± 5%   660.1m ± 5%  -23.49% (p=0.000 n=10)   680.9m ± 3%  -21.08% (p=0.000 n=10)   658.0m ± 4%  -23.72% (p=0.000 n=10)
Lua/oop             619.4m ± 4%   571.4m ± 2%   -7.74% (p=0.000 n=10)   606.6m ± 1%        ~ (p=0.075 n=10)   580.0m ± 4%   -6.35% (p=0.000 n=10)
Lua/patterns        694.0m ± 2%   549.5m ± 1%  -20.81% (p=0.000 n=10)   578.0m ± 1%  -16.72% (p=0.000 n=10)   549.5m ± 2%  -20.81% (p=0.000 n=10)
Lua/spectral_norm   746.3m ± 1%   689.7m ± 0%   -7.59% (p=0.000 n=10)   713.0m ± 1%   -4.47% (p=0.000 n=10)   680.5m ± 3%   -8.82% (p=0.000 n=10)
Lua/table_concat    696.1m ± 1%   263.6m ± 3%  -62.13% (p=0.000 n=10)   315.0m ± 2%  -54.75% (p=0.000 n=10)   255.3m ± 4%  -63.32% (p=0.000 n=10)
Lua/template        656.1m ± 1%   544.0m ± 1%  -17.08% (p=0.000 n=10)   596.1m ± 0%   -9.15% (p=0.000 n=10)   537.6m ± 1%  -18.06% (p=0.000 n=10)
geomean             666.1m        477.0m       -28.39%                  532.4m       -20.07%                  478.0m       -28.24%

                  │      ref      │           ours-ReleaseFast           │           ours-ReleaseSafe           │        ours-ReleaseFast-capi         │
                  │ peak-RSS-KiB  │ peak-RSS-KiB  vs base                │ peak-RSS-KiB  vs base                │ peak-RSS-KiB  vs base                │
Lua/array            35.41k ±  0%    19.99k ± 0%  -43.56% (p=0.000 n=10)    20.05k ± 0%  -43.38% (p=0.000 n=10)    21.34k ± 0%  -39.73% (p=0.000 n=10)
Lua/binary_trees     31.58k ±  0%    25.56k ± 0%  -19.04% (p=0.000 n=10)    25.63k ± 0%  -18.84% (p=0.000 n=10)    27.04k ± 0%  -14.38% (p=0.000 n=10)
Lua/closures         2940.0 ±  1%     716.0 ± 1%  -75.65% (p=0.000 n=10)     846.0 ± 0%  -71.22% (p=0.000 n=10)    2178.0 ± 0%  -25.92% (p=0.000 n=10)
Lua/concat           2950.0 ±  1%     692.0 ± 1%  -76.54% (p=0.000 n=10)     692.0 ± 1%  -76.54% (p=0.000 n=10)    2130.0 ± 0%  -27.80% (p=0.000 n=10)
Lua/config           13.04k ± 17%    10.78k ± 0%  -17.30% (p=0.001 n=10)    10.82k ± 0%  -17.02% (p=0.001 n=10)    11.52k ± 0%  -11.63% (p=0.019 n=10)
Lua/coroutines       2884.0 ±  1%     716.0 ± 1%  -75.17% (p=0.000 n=10)     784.0 ± 1%  -72.82% (p=0.000 n=10)    2178.0 ± 0%  -24.48% (p=0.000 n=10)
Lua/fib              2856.0 ±  1%     636.0 ± 1%  -77.73% (p=0.000 n=10)     768.0 ± 1%  -73.11% (p=0.000 n=10)    2100.0 ± 0%  -26.47% (p=0.000 n=10)
Lua/format           2966.0 ±  2%     788.0 ± 1%  -73.43% (p=0.000 n=10)     788.0 ± 1%  -73.43% (p=0.000 n=10)    2224.0 ± 0%  -25.02% (p=0.000 n=10)
Lua/globals          2892.0 ±  1%     708.0 ± 1%  -75.52% (p=0.000 n=10)     834.0 ± 0%  -71.16% (p=0.000 n=10)    2166.0 ± 0%  -25.10% (p=0.000 n=10)
Lua/hash_int         8.486k ±  0%    5.060k ± 0%  -40.37% (p=0.000 n=10)    5.124k ± 0%  -39.62% (p=0.000 n=10)    6.412k ± 0%  -24.44% (p=0.000 n=10)
Lua/hash_string      22.60k ±  0%    21.41k ± 0%   -5.25% (p=0.000 n=10)    21.54k ± 0%   -4.67% (p=0.000 n=10)    22.77k ± 0%   +0.74% (p=0.000 n=10)
Lua/json            12.170k ±  0%    9.784k ± 0%  -19.61% (p=0.000 n=10)    9.884k ± 0%  -18.78% (p=0.000 n=10)   11.142k ± 0%   -8.45% (p=0.000 n=10)
Lua/mandelbrot       3006.0 ±  2%     636.0 ± 1%  -78.84% (p=0.000 n=10)     700.0 ± 1%  -76.71% (p=0.000 n=10)    2096.0 ± 0%  -30.27% (p=0.000 n=10)
Lua/methods          2904.0 ±  2%     718.0 ± 0%  -75.28% (p=0.000 n=10)     780.0 ± 1%  -73.14% (p=0.000 n=10)    2178.0 ± 0%  -25.00% (p=0.000 n=10)
Lua/nbody            3044.0 ±  2%     776.0 ± 1%  -74.51% (p=0.000 n=10)     912.0 ± 0%  -70.04% (p=0.000 n=10)    2240.0 ± 0%  -26.41% (p=0.000 n=10)
Lua/oop             11.398k ±  0%    8.700k ± 0%  -23.67% (p=0.000 n=10)    8.764k ± 0%  -23.11% (p=0.000 n=10)   10.050k ± 0%  -11.83% (p=0.000 n=10)
Lua/patterns        17.654k ±  0%    8.268k ± 0%  -53.17% (p=0.000 n=10)    8.298k ± 0%  -53.00% (p=0.000 n=10)    9.624k ± 0%  -45.49% (p=0.000 n=10)
Lua/spectral_norm    3056.0 ±  2%     756.0 ± 1%  -75.26% (p=0.000 n=10)     952.0 ± 0%  -68.85% (p=0.000 n=10)    2216.0 ± 0%  -27.49% (p=0.000 n=10)
Lua/table_concat     40.49k ±  0%    22.20k ± 0%  -45.18% (p=0.000 n=10)    22.35k ± 0%  -44.80% (p=0.000 n=10)    23.55k ± 0%  -41.84% (p=0.000 n=10)
Lua/template         3.174k ±  1%    1.122k ± 0%  -64.65% (p=0.000 n=10)    1.192k ± 0%  -62.44% (p=0.000 n=10)    2.520k ± 0%  -20.60% (p=0.000 n=10)
geomean              6.793k          2.675k       -60.62%                   2.855k       -57.98%                   5.104k       -24.87%
```

## The floor and C calls

`just bench-capi 10` (C calls, 10M a row; `lua -e ''`, 20 runs a row,
GNU time under taskset):

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
              │     ref     │                 capi                 │
              │   sec/op    │    sec/op     vs base                │
Capi/loop       4.370n ± 4%    3.445n ± 3%  -21.17% (p=0.000 n=10)
Capi/nop        9.760n ± 4%   12.065n ± 2%  +23.62% (p=0.000 n=10)
Capi/add        23.38n ± 2%    26.07n ± 1%  +11.53% (p=0.000 n=10)
Capi/callback   30.60n ± 2%    51.04n ± 1%  +66.78% (p=0.000 n=10)
geomean         13.22n         15.34n       +16.03%
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
        │     ref     │               default               │             capi              │
        │   sec/op    │   sec/op     vs base                │   sec/op     vs base          │
Startup   3.470m ± 7%   2.897m ± 8%  -16.52% (p=0.000 n=10)   3.354m ± 9%  ~ (p=0.143 n=10)

        │     ref      │               default                │                 capi                 │
        │ peak-RSS-KiB │ peak-RSS-KiB  vs base                │ peak-RSS-KiB  vs base                │
Startup    2624.0 ± 1%     564.0 ± 1%  -78.51% (p=0.000 n=10)    1896.0 ± 0%  -27.74% (p=0.000 n=10)
native stack per C -> Lua level, ref: 351 bytes
native stack per C -> Lua level, capi: 672 bytes
```

The floor is 564 KiB for the default build, 78.5% below the
reference's 2624, and 1896 KiB for the C-API build, 27.7% below it
(wave 9: 1216 and 2692, the C-API build 3.5% above). An empty C call
costs 12.1 ns a loop iteration against the reference's 9.8 (wave 9:
17.2 against 11.8 on a slower run); a C function that calls back into
Lua 51.0 against 30.6. Startup is 16.5% faster than the reference's in
the default build and level in the C-API build.

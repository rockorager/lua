# Wave 9 against the reference, 2026-10-31

`just optimize="ReleaseFast ReleaseSafe" bench-compare 10` at the end of
wave 9 (native stack, `stack-20261031.md`; the loader's order of checks;
no segfault handler or signal stack in release builds of `lua`): our
ReleaseFast and ReleaseSafe builds against reference Lua 5.5.1 from the
dev shell, 10 rounds of every `bench/` program, interleaved, pinned to
one core, wall time and peak RSS per process.

This is the first comparison with peak RSS read correctly. GNU time ran
over `taskset` until now, and `ru_maxrss` keeps the high-water mark
across exec, so every reading was at least taskset's own 2376 KiB:
eleven of our twenty programs, which peak at 1.3 MiB, read as 2.37 MiB
in waves 4 to 8, and the reference's small programs, at 2.9 MiB, were
barely touched. The recipe now runs GNU time under taskset, as
`bench-capi` already did.

ReleaseFast is 28.6% faster on the geomean with 44.1% lower peak RSS
(wave 7: −25.9% and −22.7%, with the floor). ReleaseSafe is 18.7%
faster and peaks 36.3% lower (wave 7: −15.6% and −21.8%). The machine
was slower this run (the reference's geomean 779 ms against 579 in
wave 7), so compare ratios. Slower than the reference: methods (+2.2%;
wave 7 +6.8%) and oop (+4.5%; wave 7 +10.1%) in ReleaseSafe, whose cost
is the loop's own checks (`release-safe-20261031.md`).

Peak RSS: every program peaks below the reference in both builds. The
small programs are the floor, 1.29 to 1.37 MiB in ReleaseFast against
the reference's 2.88 to 3.02; config's reading on the reference is
bimodal (10.7 or 13.0 MB), so its −14% is that.

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
                  │     ref      │          ours-ReleaseFast           │           ours-ReleaseSafe           │
                  │    sec/op    │   sec/op     vs base                │    sec/op     vs base                │
Lua/array            899.5m ± 5%   692.4m ± 4%  -23.02% (p=0.000 n=10)   746.8m ±  2%  -16.97% (p=0.000 n=10)
Lua/binary_trees     914.1m ± 2%   660.2m ± 2%  -27.77% (p=0.000 n=10)   839.7m ±  3%   -8.13% (p=0.000 n=10)
Lua/closures         877.0m ± 2%   628.2m ± 5%  -28.37% (p=0.000 n=10)   796.1m ±  3%   -9.22% (p=0.000 n=10)
Lua/concat           831.9m ± 3%   372.6m ± 3%  -55.21% (p=0.000 n=10)   439.9m ± 14%  -47.12% (p=0.000 n=10)
Lua/config           712.5m ± 4%   574.1m ± 1%  -19.42% (p=0.000 n=10)   664.6m ±  5%   -6.71% (p=0.001 n=10)
Lua/coroutines       805.6m ± 3%   439.7m ± 4%  -45.42% (p=0.000 n=10)   516.7m ±  2%  -35.86% (p=0.000 n=10)
Lua/fib              669.6m ± 3%   558.1m ± 2%  -16.65% (p=0.000 n=10)   620.6m ±  2%   -7.31% (p=0.000 n=10)
Lua/format           931.6m ± 4%   426.3m ± 2%  -54.24% (p=0.000 n=10)   529.8m ±  2%  -43.13% (p=0.000 n=10)
Lua/globals          854.0m ± 2%   612.8m ± 4%  -28.24% (p=0.000 n=10)   793.7m ±  3%   -7.06% (p=0.000 n=10)
Lua/hash_int         526.3m ± 3%   456.9m ± 4%  -13.18% (p=0.000 n=10)   481.5m ±  2%   -8.50% (p=0.000 n=10)
Lua/hash_string      503.4m ± 3%   435.8m ± 3%  -13.42% (p=0.000 n=10)   445.5m ±  3%  -11.49% (p=0.000 n=10)
Lua/json             739.7m ± 2%   567.8m ± 4%  -23.23% (p=0.000 n=10)   673.2m ±  3%   -8.99% (p=0.000 n=10)
Lua/mandelbrot       782.5m ± 3%   543.0m ± 6%  -30.61% (p=0.000 n=10)   529.2m ±  3%  -32.38% (p=0.000 n=10)
Lua/methods          743.2m ± 2%   639.7m ± 5%  -13.92% (p=0.000 n=10)   759.7m ±  2%   +2.22% (p=0.009 n=10)
Lua/nbody           1006.8m ± 2%   777.6m ± 6%  -22.76% (p=0.000 n=10)   808.0m ±  5%  -19.75% (p=0.000 n=10)
Lua/oop              721.2m ± 4%   660.9m ± 6%   -8.36% (p=0.000 n=10)   753.3m ±  4%   +4.46% (p=0.004 n=10)
Lua/patterns         812.9m ± 3%   629.9m ± 2%  -22.52% (p=0.000 n=10)   698.0m ±  3%  -14.14% (p=0.000 n=10)
Lua/spectral_norm    884.5m ± 5%   811.1m ± 2%   -8.29% (p=0.000 n=10)   836.6m ±  3%   -5.41% (p=0.000 n=10)
Lua/table_concat     804.6m ± 3%   311.3m ± 4%  -61.32% (p=0.000 n=10)   372.1m ±  3%  -53.76% (p=0.000 n=10)
Lua/template         771.9m ± 2%   635.6m ± 2%  -17.65% (p=0.000 n=10)   714.8m ±  2%   -7.39% (p=0.000 n=10)
geomean              779.0m        556.2m       -28.60%                  633.4m        -18.69%

                  │      ref      │           ours-ReleaseFast           │           ours-ReleaseSafe           │
                  │ peak-RSS-KiB  │ peak-RSS-KiB  vs base                │ peak-RSS-KiB  vs base                │
Lua/array            35.41k ±  0%    20.71k ± 0%  -41.52% (p=0.000 n=10)    21.03k ± 0%  -40.61% (p=0.000 n=10)
Lua/binary_trees     31.54k ±  0%    26.16k ± 0%  -17.08% (p=0.000 n=10)    26.48k ± 0%  -16.05% (p=0.000 n=10)
Lua/closures         2.918k ±  1%    1.372k ± 0%  -52.98% (p=0.000 n=10)    1.700k ± 0%  -41.74% (p=0.000 n=10)
Lua/concat           2.942k ±  1%    1.348k ± 0%  -54.18% (p=0.000 n=10)    1.660k ± 0%  -43.58% (p=0.000 n=10)
Lua/config           13.03k ± 17%    11.19k ± 0%  -14.15% (p=0.019 n=10)    11.52k ± 0%  -11.62% (p=0.019 n=10)
Lua/coroutines       2.906k ±  1%    1.310k ± 0%  -54.92% (p=0.000 n=10)    1.626k ± 0%  -44.05% (p=0.000 n=10)
Lua/fib              2.884k ±  1%    1.292k ± 0%  -55.20% (p=0.000 n=10)    1.612k ± 0%  -44.11% (p=0.000 n=10)
Lua/format           2.952k ±  1%    1.316k ± 0%  -55.42% (p=0.000 n=10)    1.636k ± 0%  -44.58% (p=0.000 n=10)
Lua/globals          2.896k ±  2%    1.298k ± 0%  -55.18% (p=0.000 n=10)    1.616k ± 0%  -44.20% (p=0.000 n=10)
Lua/hash_int         8.482k ±  0%    5.780k ± 0%  -31.86% (p=0.000 n=10)    6.094k ± 0%  -28.15% (p=0.000 n=10)
Lua/hash_string      22.57k ±  0%    22.13k ± 0%   -1.92% (p=0.000 n=10)    22.45k ± 0%   -0.51% (p=0.000 n=10)
Lua/json             12.16k ±  0%    10.19k ± 0%  -16.24% (p=0.000 n=10)    10.52k ± 0%  -13.55% (p=0.000 n=10)
Lua/mandelbrot       3.022k ±  2%    1.292k ± 0%  -57.25% (p=0.000 n=10)    1.610k ± 0%  -46.72% (p=0.000 n=10)
Lua/methods          2.892k ±  1%    1.312k ± 0%  -54.63% (p=0.000 n=10)    1.640k ± 0%  -43.29% (p=0.000 n=10)
Lua/nbody            3.022k ±  2%    1.306k ± 0%  -56.78% (p=0.000 n=10)    1.632k ± 0%  -46.00% (p=0.000 n=10)
Lua/oop             11.370k ±  0%    9.228k ± 0%  -18.84% (p=0.000 n=10)    9.544k ± 0%  -16.06% (p=0.000 n=10)
Lua/patterns        17.648k ±  0%    8.732k ± 0%  -50.52% (p=0.000 n=10)    9.058k ± 0%  -48.67% (p=0.000 n=10)
Lua/spectral_norm    3.014k ±  2%    1.348k ± 0%  -55.28% (p=0.000 n=10)    1.664k ± 0%  -44.79% (p=0.000 n=10)
Lua/table_concat     40.47k ±  0%    22.85k ± 0%  -43.53% (p=0.000 n=10)    23.17k ± 0%  -42.73% (p=0.000 n=10)
Lua/template         3.166k ±  1%    1.650k ± 0%  -47.88% (p=0.000 n=10)    1.976k ± 0%  -37.59% (p=0.000 n=10)
geomean              6.784k          3.795k       -44.07%                   4.320k       -36.32%
```

## The floor

`lua -e ''`, from `just bench-capi 10` (20 runs a row, GNU time under
taskset): the reference, our default ReleaseFast build, and our C-API
build.

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
              │     ref     │                capi                 │
              │   sec/op    │   sec/op     vs base                │
Capi/loop       5.305n ± 2%   4.115n ± 4%  -22.43% (p=0.000 n=10)
Capi/nop        11.76n ± 2%   17.16n ± 2%  +45.86% (p=0.000 n=10)
Capi/add        28.39n ± 2%   35.14n ± 2%  +23.82% (p=0.000 n=10)
Capi/callback   37.17n ± 5%   64.19n ± 2%  +72.68% (p=0.000 n=10)
geomean         16.02n        19.98n       +24.71%
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
        │     ref     │               default               │             capi              │
        │   sec/op    │   sec/op     vs base                │   sec/op     vs base          │
Startup   4.064m ± 3%   3.445m ± 3%  -15.23% (p=0.000 n=10)   4.022m ± 3%  ~ (p=0.315 n=10)

        │     ref      │               default                │                capi                 │
        │ peak-RSS-KiB │ peak-RSS-KiB  vs base                │ peak-RSS-KiB  vs base               │
Startup    2.602k ± 1%    1.216k ± 0%  -53.27% (p=0.000 n=10)    2.692k ± 0%  +3.46% (p=0.000 n=10)
native stack per C -> Lua level, ref: 351 bytes
native stack per C -> Lua level, capi: 656 bytes
```

The default build peaks at 1216 KiB, 53% below the reference's 2602;
the C-API build, dynamically linked, at 2692 KiB, 3.5% above. Before
this wave they were 1.49 and 3.02 MiB (`c-api-20261031.md`); the
difference is the 256 KiB signal stack (`stack-20261031.md`). The C
call rows are wave 8's prototype costs measured again; the native call
path is the next owner's (`plan.md`, wave 9).

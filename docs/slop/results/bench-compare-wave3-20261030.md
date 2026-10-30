# Wave 3 against the reference, 2026-10-30

`just bench-compare 10` at the end of wave 3's performance work (the
commit that adds this file): ReleaseFast against reference Lua 5.5.1 from
the dev shell, 10 rounds of every `bench/` program, interleaved, pinned to
one core, wall time and peak RSS per process.

Every program is faster or level (methods −1.8% and spectral_norm +0.5%,
both within noise), and every program peaks below the reference's memory;
hash_string by the least, −0.9%. The baseline this wave started from is in
`core-baseline-20261030.md` and `vm-wave2-20261030.md`.

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
                  │     ref      │                 ours                 │
                  │    sec/op    │    sec/op     vs base                │
Lua/array           939.8m ±  4%   895.4m ±  2%   -4.72% (p=0.000 n=10)
Lua/binary_trees    943.0m ±  3%   750.9m ±  7%  -20.37% (p=0.000 n=10)
Lua/closures        867.0m ±  6%   648.1m ±  3%  -25.25% (p=0.000 n=10)
Lua/concat          831.7m ±  3%   353.0m ±  2%  -57.55% (p=0.000 n=10)
Lua/coroutines      763.3m ±  2%   485.2m ±  3%  -36.43% (p=0.000 n=10)
Lua/fib             652.4m ±  7%   535.1m ±  3%  -17.97% (p=0.000 n=10)
Lua/format          952.0m ±  3%   449.0m ±  3%  -52.83% (p=0.000 n=10)
Lua/hash_int        578.6m ±  6%   456.0m ±  4%  -21.20% (p=0.000 n=10)
Lua/hash_string     563.1m ± 10%   458.1m ± 15%  -18.64% (p=0.000 n=10)
Lua/mandelbrot      702.0m ±  6%   586.8m ±  6%  -16.41% (p=0.000 n=10)
Lua/methods         716.8m ±  5%   703.8m ±  5%        ~ (p=0.165 n=10)
Lua/nbody           967.4m ±  2%   829.1m ± 11%  -14.30% (p=0.000 n=10)
Lua/patterns        758.2m ±  4%   632.2m ±  5%  -16.61% (p=0.000 n=10)
Lua/spectral_norm   809.7m ±  2%   813.8m ±  6%        ~ (p=0.143 n=10)
Lua/table_concat    883.9m ±  4%   347.7m ±  7%  -60.67% (p=0.000 n=10)
geomean             784.2m         572.0m        -27.06%

                  │     ref      │                 ours                 │
                  │ peak-RSS-KiB │ peak-RSS-KiB  vs base                │
Lua/array            35.42k ± 0%    20.94k ± 0%  -40.88% (p=0.000 n=10)
Lua/binary_trees     31.55k ± 0%    26.63k ± 0%  -15.60% (p=0.000 n=10)
Lua/closures         2.904k ± 1%    2.384k ± 0%  -17.91% (p=0.000 n=10)
Lua/concat           2.950k ± 1%    2.382k ± 0%  -19.25% (p=0.000 n=10)
Lua/coroutines       2.888k ± 2%    2.380k ± 0%  -17.59% (p=0.000 n=10)
Lua/fib              2.896k ± 1%    2.380k ± 0%  -17.82% (p=0.000 n=10)
Lua/format           2.918k ± 2%    2.380k ± 0%  -18.44% (p=0.000 n=10)
Lua/hash_int         8.506k ± 0%    6.012k ± 0%  -29.32% (p=0.000 n=10)
Lua/hash_string      22.59k ± 0%    22.39k ± 0%   -0.90% (p=0.000 n=10)
Lua/mandelbrot       2.992k ± 2%    2.378k ± 0%  -20.52% (p=0.000 n=10)
Lua/methods          2.894k ± 1%    2.380k ± 0%  -17.76% (p=0.000 n=10)
Lua/nbody            3.004k ± 1%    2.378k ± 0%  -20.84% (p=0.000 n=10)
Lua/patterns        17.634k ± 0%    9.050k ± 0%  -48.68% (p=0.000 n=10)
Lua/spectral_norm    3.038k ± 3%    2.380k ± 0%  -21.66% (p=0.000 n=10)
Lua/table_concat     40.48k ± 0%    23.10k ± 0%  -42.93% (p=0.000 n=10)
geomean              6.713k         5.078k       -24.36%
```

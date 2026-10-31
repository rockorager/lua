# Wave 4 against the reference, 2026-10-31

`just bench-compare 10` at the end of wave 4 (the commit that adds this
file, on c8bc322 with the embedding API): ReleaseFast against reference
Lua 5.5.1 from the dev shell, 10 rounds of every `bench/` program,
interleaved, pinned to one core, wall time and peak RSS per process.

29% faster on the geomean and 24% lower peak RSS. Every program is
faster than the reference; the closest are array (−3.0%), methods
(−8.2%), and spectral_norm (−9.6%). Every program peaks below the
reference's memory, hash_string by the least (−0.9%). globals is new in
this wave (`gettabup-cache-20261031.md`). Wave 3's table is
`bench-compare-wave3-20261030.md`.

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
                  │     ref      │                 ours                 │
                  │    sec/op    │    sec/op     vs base                │
Lua/array           771.1m ± 12%   748.2m ±  2%   -2.96% (p=0.009 n=10)
Lua/binary_trees    794.7m ±  4%   591.0m ±  1%  -25.64% (p=0.000 n=10)
Lua/closures        761.2m ±  7%   546.9m ±  5%  -28.15% (p=0.000 n=10)
Lua/concat          726.1m ±  5%   316.3m ±  4%  -56.44% (p=0.000 n=10)
Lua/coroutines      710.5m ±  3%   394.0m ±  9%  -44.55% (p=0.000 n=10)
Lua/fib             579.2m ±  3%   492.4m ±  6%  -14.99% (p=0.000 n=10)
Lua/format          790.3m ±  6%   384.7m ±  9%  -51.33% (p=0.000 n=10)
Lua/globals         733.0m ±  9%   567.9m ±  6%  -22.53% (p=0.000 n=10)
Lua/hash_int        485.1m ±  5%   420.2m ±  4%  -13.37% (p=0.000 n=10)
Lua/hash_string     459.3m ±  3%   387.9m ±  8%  -15.55% (p=0.000 n=10)
Lua/mandelbrot      689.2m ±  5%   473.7m ± 10%  -31.27% (p=0.000 n=10)
Lua/methods         644.0m ±  5%   591.3m ±  5%   -8.18% (p=0.001 n=10)
Lua/nbody           898.1m ±  5%   685.4m ± 14%  -23.68% (p=0.000 n=10)
Lua/patterns        698.7m ±  3%   553.6m ±  7%  -20.77% (p=0.000 n=10)
Lua/spectral_norm   749.2m ±  4%   677.5m ±  4%   -9.57% (p=0.000 n=10)
Lua/table_concat    710.0m ±  9%   285.9m ±  8%  -59.73% (p=0.000 n=10)
geomean             690.4m         489.5m        -29.10%

                  │     ref      │                 ours                 │
                  │ peak-RSS-KiB │ peak-RSS-KiB  vs base                │
Lua/array            35.43k ± 0%    20.93k ± 0%  -40.91% (p=0.000 n=10)
Lua/binary_trees     31.57k ± 0%    26.62k ± 0%  -15.67% (p=0.000 n=10)
Lua/closures         2.926k ± 1%    2.372k ± 0%  -18.93% (p=0.000 n=10)
Lua/concat           2.950k ± 2%    2.376k ± 0%  -19.46% (p=0.000 n=10)
Lua/coroutines       2.904k ± 0%    2.370k ± 0%  -18.39% (p=0.000 n=10)
Lua/fib              2.888k ± 2%    2.370k ± 0%  -17.94% (p=0.000 n=10)
Lua/format           2.934k ± 1%    2.372k ± 0%  -19.15% (p=0.000 n=10)
Lua/globals          2.906k ± 1%    2.372k ± 0%  -18.38% (p=0.000 n=10)
Lua/hash_int         8.502k ± 0%    6.008k ± 0%  -29.33% (p=0.000 n=10)
Lua/hash_string      22.58k ± 0%    22.38k ± 0%   -0.88% (p=0.000 n=10)
Lua/mandelbrot       3.020k ± 1%    2.372k ± 0%  -21.46% (p=0.000 n=10)
Lua/methods          2.894k ± 2%    2.372k ± 0%  -18.04% (p=0.000 n=10)
Lua/nbody            3.014k ± 2%    2.370k ± 0%  -21.37% (p=0.000 n=10)
Lua/patterns        17.642k ± 0%    9.048k ± 0%  -48.71% (p=0.000 n=10)
Lua/spectral_norm    3.008k ± 2%    2.370k ± 0%  -21.21% (p=0.000 n=10)
Lua/table_concat     40.49k ± 0%    23.10k ± 0%  -42.94% (p=0.000 n=10)
geomean              6.378k         4.832k       -24.25%
```

# Wave 5 against the reference, 2026-10-31

`just optimize="ReleaseFast ReleaseSafe" bench-compare 10` at the end of
wave 5 (891d2de: the `auxlib.Buffer` change, the loader's opcode check,
and the unchecked dispatch, on f55ff31): our ReleaseFast and ReleaseSafe
builds against reference Lua 5.5.1 from the dev shell, 10 rounds of
every `bench/` program, interleaved, pinned to one core, wall time and
peak RSS per process. The hash part did not change (`table-hash-20261031.md`).

ReleaseFast is 29% faster on the geomean with 24% lower peak RSS, the
same as wave 4 (`bench-compare-wave4-20261031.md`: −28.5% and −24.3%).
ReleaseSafe is 8.3% faster than the reference, against 4.6% in
`release-safe-20261031.md`: format is now 37% faster than the reference
in a safe build (it was 18%), and the dispatch-bound programs gained
5–12% (`buffer-init-20261031.md`, `opcode-check-20261031.md`). Its
remaining losses (array, concat, methods) and its extra peak memory are
the standard allocator interface's poisoning, which this wave did not
touch.

This machine was noisier today than in wave 4 (±15% on single programs
against ±2–9%), so differences of a few percent between the two waves'
tables are not changes.

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
                  │     ref      │           ours-ReleaseFast           │           ours-ReleaseSafe           │
                  │    sec/op    │    sec/op     vs base                │    sec/op     vs base                │
Lua/array           781.6m ± 18%   735.3m ± 12%        ~ (p=0.190 n=10)   959.5m ± 12%  +22.76% (p=0.000 n=10)
Lua/binary_trees    840.5m ± 17%   523.0m ± 16%  -37.78% (p=0.000 n=10)   718.8m ± 18%        ~ (p=0.063 n=10)
Lua/closures        761.2m ± 20%   491.1m ± 13%  -35.48% (p=0.000 n=10)   762.0m ± 14%        ~ (p=1.000 n=10)
Lua/concat          641.3m ± 10%   293.1m ± 14%  -54.30% (p=0.000 n=10)   843.2m ± 15%  +31.48% (p=0.000 n=10)
Lua/coroutines      629.3m ± 20%   391.8m ± 21%  -37.74% (p=0.000 n=10)   505.8m ±  8%  -19.62% (p=0.005 n=10)
Lua/fib             538.2m ± 14%   463.5m ± 16%  -13.87% (p=0.015 n=10)   531.1m ± 13%        ~ (p=0.631 n=10)
Lua/format          751.9m ± 13%   375.9m ± 16%  -50.01% (p=0.000 n=10)   472.2m ± 20%  -37.20% (p=0.000 n=10)
Lua/globals         674.7m ± 15%   536.1m ± 20%  -20.54% (p=0.000 n=10)   662.6m ±  8%        ~ (p=0.631 n=10)
Lua/hash_int        611.7m ±  9%   507.6m ± 15%  -17.03% (p=0.000 n=10)   660.3m ± 12%        ~ (p=0.353 n=10)
Lua/hash_string     604.6m ±  7%   518.2m ±  7%  -14.30% (p=0.001 n=10)   593.2m ±  6%        ~ (p=0.853 n=10)
Lua/mandelbrot      646.9m ± 19%   441.6m ± 18%  -31.74% (p=0.000 n=10)   422.7m ± 16%  -34.66% (p=0.000 n=10)
Lua/methods         632.3m ± 16%   571.9m ± 18%   -9.56% (p=0.043 n=10)   712.5m ±  7%  +12.68% (p=0.004 n=10)
Lua/nbody           836.7m ± 20%   622.3m ± 18%  -25.62% (p=0.000 n=10)   690.1m ± 12%  -17.52% (p=0.003 n=10)
Lua/patterns        636.9m ± 20%   576.3m ± 21%   -9.51% (p=0.011 n=10)   605.5m ± 12%        ~ (p=0.089 n=10)
Lua/spectral_norm   689.8m ± 13%   639.8m ± 16%        ~ (p=0.123 n=10)   657.4m ± 14%        ~ (p=0.089 n=10)
Lua/table_concat    765.8m ± 16%   306.1m ± 14%  -60.03% (p=0.000 n=10)   488.3m ± 19%  -36.23% (p=0.000 n=10)
geomean             684.9m         485.2m        -29.16%                  628.3m         -8.27%

                  │     ref      │           ours-ReleaseFast           │           ours-ReleaseSafe           │
                  │ peak-RSS-KiB │ peak-RSS-KiB  vs base                │ peak-RSS-KiB  vs base                │
Lua/array            35.43k ± 0%    20.93k ± 0%  -40.92% (p=0.000 n=10)    29.34k ± 0%  -17.17% (p=0.000 n=10)
Lua/binary_trees     31.56k ± 0%    26.62k ± 0%  -15.67% (p=0.000 n=10)    26.90k ± 0%  -14.75% (p=0.000 n=10)
Lua/closures         2.932k ± 0%    2.368k ± 0%  -19.24% (p=0.000 n=10)    2.368k ± 0%  -19.24% (p=0.000 n=10)
Lua/concat           2.948k ± 0%    2.368k ± 0%  -19.67% (p=0.000 n=10)    2.368k ± 0%  -19.67% (p=0.000 n=10)
Lua/coroutines       2.904k ± 0%    2.368k ± 0%  -18.46% (p=0.000 n=10)    2.368k ± 0%  -18.46% (p=0.000 n=10)
Lua/fib              2.892k ± 0%    2.368k ± 0%  -18.12% (p=0.000 n=10)    2.368k ± 0%  -18.12% (p=0.000 n=10)
Lua/format           2.952k ± 0%    2.368k ± 0%  -19.78% (p=0.000 n=10)    2.368k ± 0%  -19.78% (p=0.000 n=10)
Lua/globals          2.908k ± 0%    2.368k ± 0%  -18.57% (p=0.000 n=10)    2.368k ± 0%  -18.57% (p=0.000 n=10)
Lua/hash_int         8.500k ± 0%    6.004k ± 0%  -29.36% (p=0.000 n=10)    6.356k ± 0%  -25.22% (p=0.000 n=10)
Lua/hash_string      22.59k ± 0%    22.38k ± 0%   -0.94% (p=0.000 n=10)    23.19k ± 0%   +2.66% (p=0.000 n=10)
Lua/mandelbrot       2.948k ± 0%    2.368k ± 0%  -19.67% (p=0.000 n=10)    2.368k ± 0%  -19.67% (p=0.000 n=10)
Lua/methods          2.908k ± 0%    2.368k ± 0%  -18.57% (p=0.000 n=10)    2.368k ± 0%  -18.57% (p=0.000 n=10)
Lua/nbody            2.960k ± 0%    2.368k ± 0%  -20.00% (p=0.000 n=10)    2.368k ± 0%  -20.00% (p=0.000 n=10)
Lua/patterns        17.648k ± 0%    9.044k ± 0%  -48.75% (p=0.000 n=10)    9.364k ± 0%  -46.94% (p=0.000 n=10)
Lua/spectral_norm    2.984k ± 0%    2.368k ± 0%  -20.64% (p=0.000 n=10)    2.368k ± 0%  -20.64% (p=0.000 n=10)
Lua/table_concat     40.48k ± 0%    23.10k ± 0%  -42.94% (p=0.000 n=10)    30.83k ± 0%  -23.85% (p=0.000 n=10)
geomean              6.364k         4.826k       -24.16%                   5.063k       -20.45%
```

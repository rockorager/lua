# First end-to-end bench run, 2026-10-30

The first `just bench-compare` with our own `lua` (wave-2 parser branch: our
compiler, the wave-1 VM, the base library only). Not an A/B of a change: it is
the starting line. Our bytecode is luac's instruction for instruction
(`just bytecode`), so the differences are the VM's and the runtime's.

- Command: `just bench-compare 10 fib closures methods array concat hash_int hash_string mandelbrot`
- Machine: Intel Xeon @ 2.60GHz, 4 cores, orb, pinned with `taskset`; ours built ReleaseFast.
- Checksums matched the reference on every program that ran.
- Cannot run yet, for a missing library: `binary_trees`, `nbody`,
  `spectral_norm` (math), `format`, `patterns` (string), `table_concat`
  (table), `coroutines` (coroutine).

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
                │     ref      │                 ours                  │
                │    sec/op    │    sec/op      vs base                │
Lua/fib           645.5m ±  1%    615.8m ±  1%   -4.59% (p=0.000 n=10)
Lua/closures      856.2m ±  2%    729.9m ±  2%  -14.76% (p=0.000 n=10)
Lua/methods       714.4m ±  3%   1009.9m ±  4%  +41.37% (p=0.000 n=10)
Lua/array         973.9m ±  2%   1288.0m ±  3%  +32.25% (p=0.000 n=10)
Lua/concat        829.2m ±  2%    404.5m ±  1%  -51.22% (p=0.000 n=10)
Lua/hash_int      577.5m ±  6%    813.8m ±  7%  +40.92% (p=0.000 n=10)
Lua/hash_string   634.0m ± 49%    877.6m ± 37%  +38.43% (p=0.007 n=10)
Lua/mandelbrot    696.8m ±  3%   1087.7m ±  2%  +56.11% (p=0.000 n=10)
geomean           730.8m          809.1m        +10.72%
```

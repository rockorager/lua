# An inline cache for global access, 2026-10-31

The plan's hot-path rules ask that a global access with a constant key
not hash when a cached slot can answer (`GETTABUP` with a constant
string key). The suite of `bench/` programs had no global access in a
loop, so this change adds `bench/globals.lua`: code written without
locals, where every name is a field of `_ENV` (global functions and
counters, library functions through their global tables, 40 user
globals besides the library's).

## The change

- `Proto.kslot` holds a node index for each constant, allocated when the
  code has a `GETTABUP` or `SETTABUP` (`Proto.initSlots`, called by the
  parser and the binary loader): 4 bytes per constant.
- `GETTABUP` reads through `Table.getShortStrCached`: when the node at
  the cached index (bounded by the node count) holds the key, that is
  the answer; otherwise the ordinary chain walk runs and records where
  it found the key. `SETTABUP` replaces an existing value the same way
  (`Table.replaceShortStrCached`), with the same rule as
  `replaceShortStr`: a key whose value is nil is absent, so it does not
  skip `__newindex`.
- The cache is per constant, not per instruction: the same key in the
  same `_ENV` sits in the same node. A different table, a resize, or a
  removed key only costs a miss.

What a hit saves is the load of the key string's hash and the walk down
a collision chain: in the chained scatter table a key outside its main
position costs one more dependent load per step. A hit costs the load of the
slot. A key that is absent (`if DEBUG then` on a global never set) pays
the failed check before the walk.

## Measurements

Base is 124cb08, ReleaseFast, interleaved and pinned to the last core,
benchstat. Three variants were measured: `ic`, the cache on `GETTABUP`
only with the miss path out of line (`noinline`, cold); `ic2`, the same
on `SETTABUP` too; `ic3`, `ic2` with the miss path inline. `ic3` is
the change.

`ic3` against base, 10 rounds of every program:

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
                  │     base     │                 ic                  │
                  │    sec/op    │    sec/op     vs base               │
Lua/array           793.0m ± 17%   776.4m ± 14%       ~ (p=0.280 n=10)
Lua/binary_trees    631.6m ±  4%   630.9m ± 13%       ~ (p=0.971 n=10)
Lua/closures        580.0m ± 10%   584.2m ±  6%       ~ (p=0.436 n=10)
Lua/concat          340.9m ± 13%   335.4m ±  4%       ~ (p=0.579 n=10)
Lua/coroutines      408.9m ± 11%   409.2m ±  6%       ~ (p=0.853 n=10)
Lua/fib             504.2m ±  2%   516.7m ±  4%  +2.48% (p=0.035 n=10)
Lua/format          387.5m ±  7%   396.6m ±  7%       ~ (p=0.315 n=10)
Lua/globals         633.2m ±  7%   576.6m ± 11%  -8.94% (p=0.015 n=10)
Lua/hash_int        446.5m ±  6%   449.1m ± 13%       ~ (p=0.684 n=10)
Lua/hash_string     416.1m ±  5%   416.5m ±  5%       ~ (p=0.684 n=10)
Lua/mandelbrot      496.2m ±  4%   494.7m ±  3%       ~ (p=0.912 n=10)
Lua/methods         615.7m ±  8%   616.1m ± 17%       ~ (p=0.436 n=10)
Lua/nbody           744.4m ±  8%   747.3m ± 14%       ~ (p=0.631 n=10)
Lua/patterns        633.2m ±  7%   630.9m ±  6%       ~ (p=0.739 n=10)
Lua/spectral_norm   735.9m ±  9%   726.1m ±  5%       ~ (p=0.481 n=10)
Lua/table_concat    297.6m ±  7%   300.8m ±  7%       ~ (p=0.353 n=10)
geomean             520.9m         518.4m        -0.47%

                  │     base     │                 ic                  │
                  │ peak-RSS-KiB │ peak-RSS-KiB  vs base               │
Lua/array            20.93k ± 0%    20.93k ± 0%  -0.03% (p=0.000 n=10)
Lua/binary_trees     26.63k ± 0%    26.61k ± 0%  -0.08% (p=0.000 n=10)
Lua/closures         2.372k ± 0%    2.372k ± 0%       ~ (p=0.725 n=10)
Lua/concat           2.372k ± 0%    2.376k ± 0%  +0.17% (p=0.046 n=10)
Lua/coroutines       2.372k ± 0%    2.372k ± 0%       ~ (p=0.875 n=10)
Lua/fib              2.372k ± 0%    2.372k ± 0%       ~ (p=0.357 n=10)
Lua/format           2.374k ± 0%    2.372k ± 0%       ~ (p=0.692 n=10)
Lua/globals          2.368k ± 0%    2.372k ± 0%  +0.17% (p=0.006 n=10)
Lua/hash_int         6.008k ± 0%    6.000k ± 0%  -0.13% (p=0.000 n=10)
Lua/hash_string      22.38k ± 0%    22.38k ± 0%  -0.03% (p=0.001 n=10)
Lua/mandelbrot       2.372k ± 0%    2.372k ± 0%       ~ (p=0.445 n=10)
Lua/methods          2.372k ± 0%    2.372k ± 0%       ~ (p=0.394 n=10)
Lua/nbody            2.370k ± 0%    2.372k ± 0%       ~ (p=0.127 n=10)
Lua/patterns         9.050k ± 0%    9.048k ± 0%  -0.02% (p=0.014 n=10)
Lua/spectral_norm    2.372k ± 0%    2.372k ± 0%       ~ (p=0.076 n=10)
Lua/table_concat     23.10k ± 0%    23.10k ± 0%  -0.02% (p=0.005 n=10)
geomean              4.832k         4.832k       +0.00%
```

globals −8.9%. fib +2.5% does not run a `GETTABUP` in its loop (its
calls are to a local); the plan notes that any edit to the loop moves
other programs by a few percent through register allocation. Peak RSS
is level.

20 rounds of globals and of a loop reading an absent global 30 million
times (`absent`), the three variants:

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
            │    base     │                ic2                 │                ic3                 │
            │   sec/op    │   sec/op     vs base               │   sec/op     vs base               │
Lua/globals   593.5m ± 3%   567.8m ± 2%  -4.33% (p=0.002 n=20)   560.1m ± 2%  -5.64% (p=0.000 n=20)
Lua/absent    220.2m ± 2%   239.0m ± 5%  +8.56% (p=0.000 n=20)   229.9m ± 3%  +4.43% (p=0.002 n=20)
geomean       361.5m        368.4m       +1.91%                  358.8m       -0.73%
```

The out-of-line miss path made the absent read 8.6% slower; inline it
is 4.4% slower, and globals gains more. The earlier runs of `ic` and
`ic2` against base on every program (globals −5.5% and −4.1% for `ic`,
−6.1% for `ic2`, the rest within noise or layout shifts in both
directions, such as patterns −5.9% for `ic2` with no global access in
its loops):

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
                  │    base     │                 ic                  │                ic2                 │
                  │   sec/op    │    sec/op     vs base               │   sec/op     vs base               │
Lua/array           742.0m ± 9%   738.5m ±  6%       ~ (p=0.796 n=10)   732.9m ± 6%       ~ (p=0.436 n=10)
Lua/binary_trees    579.3m ± 3%   591.8m ±  2%       ~ (p=0.165 n=10)   586.6m ± 7%       ~ (p=0.393 n=10)
Lua/closures        536.0m ± 6%   560.1m ±  7%       ~ (p=0.247 n=10)   546.8m ± 4%       ~ (p=0.481 n=10)
Lua/concat          315.3m ± 2%   327.2m ±  5%  +3.78% (p=0.004 n=10)   320.3m ± 4%       ~ (p=0.190 n=10)
Lua/coroutines      394.4m ± 5%   400.5m ±  3%       ~ (p=0.353 n=10)   396.6m ± 4%       ~ (p=0.684 n=10)
Lua/fib             481.7m ± 1%   492.3m ±  8%  +2.20% (p=0.002 n=10)   493.2m ± 3%  +2.39% (p=0.002 n=10)
Lua/format          354.0m ± 5%   353.2m ±  2%       ~ (p=0.631 n=10)   353.2m ± 9%       ~ (p=0.912 n=10)
Lua/globals         582.8m ± 4%   559.1m ±  3%  -4.06% (p=0.004 n=10)   547.3m ± 6%  -6.09% (p=0.005 n=10)
Lua/hash_int        412.5m ± 3%   411.4m ±  3%       ~ (p=0.796 n=10)   413.9m ± 2%       ~ (p=0.853 n=10)
Lua/hash_string     389.9m ± 2%   381.6m ± 12%       ~ (p=0.481 n=10)   382.3m ± 3%       ~ (p=0.075 n=10)
Lua/mandelbrot      461.1m ± 7%   459.8m ±  5%       ~ (p=0.631 n=10)   462.2m ± 3%       ~ (p=1.000 n=10)
Lua/methods         591.6m ± 5%   609.2m ± 12%       ~ (p=0.218 n=10)   607.5m ± 5%       ~ (p=0.280 n=10)
Lua/nbody           680.2m ± 7%   673.1m ±  7%       ~ (p=0.971 n=10)   668.0m ± 4%       ~ (p=0.143 n=10)
Lua/patterns        587.0m ± 7%   556.0m ±  7%  -5.29% (p=0.004 n=10)   552.2m ± 5%  -5.93% (p=0.001 n=10)
Lua/spectral_norm   685.2m ± 4%   682.0m ±  4%       ~ (p=0.796 n=10)   681.1m ± 4%       ~ (p=0.912 n=10)
Lua/table_concat    272.4m ± 4%   284.3m ±  4%       ~ (p=0.052 n=10)   277.4m ± 9%       ~ (p=0.089 n=10)
geomean             484.8m        486.8m        +0.41%                  483.2m       -0.34%

                  │     base     │                 ic                  │                 ic2                 │
                  │ peak-RSS-KiB │ peak-RSS-KiB  vs base               │ peak-RSS-KiB  vs base               │
Lua/array            20.94k ± 0%    20.94k ± 0%  -0.02% (p=0.005 n=10)    20.94k ± 0%       ~ (p=0.070 n=10)
Lua/binary_trees     26.64k ± 0%    26.62k ± 0%  -0.06% (p=0.000 n=10)    26.62k ± 0%  -0.06% (p=0.000 n=10)
Lua/closures         2.378k ± 0%    2.376k ± 0%       ~ (p=0.885 n=10)    2.376k ± 0%       ~ (p=0.363 n=10)
Lua/concat           2.376k ± 0%    2.376k ± 0%       ~ (p=0.969 n=10)    2.376k ± 0%       ~ (p=0.697 n=10)
Lua/coroutines       2.372k ± 0%    2.378k ± 0%       ~ (p=0.338 n=10)    2.376k ± 0%       ~ (p=0.194 n=10)
Lua/fib              2.376k ± 0%    2.376k ± 0%       ~ (p=0.538 n=10)    2.376k ± 0%       ~ (p=0.518 n=10)
Lua/format           2.376k ± 0%    2.376k ± 0%       ~ (p=0.580 n=10)    2.376k ± 0%       ~ (p=0.875 n=10)
Lua/globals          2.378k ± 0%    2.376k ± 0%  -0.08% (p=0.019 n=10)    2.376k ± 0%       ~ (p=0.257 n=10)
Lua/hash_int         6.016k ± 0%    6.012k ± 0%  -0.07% (p=0.000 n=10)    6.010k ± 0%  -0.10% (p=0.000 n=10)
Lua/hash_string      22.39k ± 0%    22.39k ± 0%  -0.02% (p=0.000 n=10)    22.39k ± 0%  -0.02% (p=0.000 n=10)
Lua/mandelbrot       2.376k ± 0%    2.376k ± 0%       ~ (p=0.854 n=10)    2.374k ± 0%       ~ (p=0.309 n=10)
Lua/methods          2.376k ± 0%    2.376k ± 0%       ~ (p=0.574 n=10)    2.376k ± 0%       ~ (p=0.574 n=10)
Lua/nbody            2.376k ± 0%    2.376k ± 0%       ~ (p=0.971 n=10)    2.376k ± 0%       ~ (p=0.973 n=10)
Lua/patterns         9.068k ± 0%    9.064k ± 0%  -0.04% (p=0.002 n=10)    9.062k ± 0%  -0.07% (p=0.001 n=10)
Lua/spectral_norm    2.374k ± 0%    2.376k ± 0%       ~ (p=0.577 n=10)    2.374k ± 0%       ~ (p=0.984 n=10)
Lua/table_concat     23.11k ± 0%    23.11k ± 0%  -0.02% (p=0.003 n=10)    23.11k ± 0%  -0.03% (p=0.000 n=10)
geomean              4.839k         4.838k       -0.00%                   4.838k       -0.02%
```

## Decision

Keep `ic3`: global reads and writes with a constant key go through the
cache. The win is modest (4 to 9% on a program made of global
accesses) because PUC-Rio's table already answers most keys at their
main position in one probe; there is no shape to check that would let a
hit skip the key comparison. The cost is 4 bytes per constant in
functions that touch globals, and a few percent on reads of a global
that is not set.

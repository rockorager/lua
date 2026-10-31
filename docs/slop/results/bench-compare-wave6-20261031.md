# Wave 6 against the reference, 2026-10-31

`just optimize="ReleaseFast ReleaseSafe" bench-compare 10` at the end of
wave 6 (the parser change, `compiler-config-20261031.md`, on the API
cleanups): our ReleaseFast and ReleaseSafe builds against reference Lua
5.5.1 from the dev shell, 10 rounds of every `bench/` program,
interleaved, pinned to one core, wall time and peak RSS per process.
The interpreter loop did not change this wave (`index-chain-20261031.md`
was not landed).

Four programs are new: `json` (a pure-Lua JSON encoder and decoder
round-tripping 800 generated records 10 times), `template` (2,400 HTML
invoices and text reports from templates), `oop` (a predator and prey
simulation over classes with three levels of inheritance, 300 ticks of
about 2,200 movers and 4,096 plants), and `config` (a 521 KB table
constructor compiled with `load` 64 times, run, and queried). Each
prints a checksum the recipe checks against the reference's.

ReleaseFast is 26.8% faster on the geomean of all 20 programs with
22.8% lower peak RSS. Over the 16 programs of wave 5 it is 29.5% faster
with 24.2% lower peak RSS, the same as wave 5's −29.2% and −24.2%; over
the four new ones, 14.8% faster with 16.9% lower peak RSS. The machine
ran slower today (the reference's geomean over the old 16 is 808 ms
against 685 ms in wave 5), so compare ratios, not times.

| new program | time vs ref | peak RSS vs ref          |
| ----------- | ----------: | ------------------------ |
| `json`      |      −18.7% | −13.8%                   |
| `template`  |      −18.3% | −25.4%                   |
| `oop`       |       −6.2% | −15.8%                   |
| `config`    |      −15.2% | level (p=0.11; ref ±14%) |

None is slower than the reference in ReleaseFast, and none peaks
higher. What each found:

- **config** tied on time before this wave's parser change (−0.9%,
  p=0.74): running the chunk was ours by 10%, compiling it the
  reference's by 18%, from two store forwarding stalls in the compiler.
  Fixed (`compiler-config-20261031.md`, config −16.9%). Its peak RSS is
  level: the reference lands at 10.7 or 13.0 MB from run to run, ours at
  11.49 MB. Ours counts the 521 KB source string, which 5.5 keeps as an
  uncounted external string, and our line info costs about 3 bytes more
  per instruction than luac's encoding (185 KiB for this chunk); the
  same file records both, and the fix the second needs.
- **oop** has the thinnest margin, like `methods`. Inherited methods
  look the key up again in the object and the class before reaching the
  base class; skipping the repeats was measured and not landed, because
  its gain is the size of the loop's layout noise
  (`index-chain-20261031.md`).
- **json** and **template** spend their time in `string.byte`, `find`,
  `sub`, `gsub`, `format`, and `table.concat`, where ours is ahead.

ReleaseSafe is 6.8% faster than the reference over all 20 (9.9% over
the old 16, against 8.3% in wave 5) and 6.5% slower over the new four:
template +10.9%, config +7.2%, oop +7.2%, json level, and json peaks
1.4% above the reference. In a safe build `compiler_rt.memset` is 14.7%
of template (a frame-pointer build shows the standard allocator
interface writing 0xAA over the userdata, more than 600 bytes, that
`string.gmatch` allocates per call, and again when the collector frees
it) and 8.5% of
config; oop is the loop's own checks (83% in `vm.runLoop`). That is
the poisoning `release-safe-20261031.md` measured and chose to keep;
nothing new.

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
                  │     ref      │           ours-ReleaseFast           │           ours-ReleaseSafe            │
                  │    sec/op    │    sec/op     vs base                │    sec/op      vs base                │
Lua/array            912.8m ± 5%   875.0m ±  6%   -4.14% (p=0.019 n=10)   1096.3m ±  4%  +20.09% (p=0.000 n=10)
Lua/binary_trees     961.9m ± 3%   682.2m ±  5%  -29.08% (p=0.000 n=10)    940.0m ± 12%        ~ (p=0.280 n=10)
Lua/closures         895.8m ± 2%   637.2m ±  5%  -28.87% (p=0.000 n=10)    920.4m ±  2%   +2.74% (p=0.005 n=10)
Lua/concat           857.0m ± 4%   379.4m ±  3%  -55.73% (p=0.000 n=10)   1014.7m ±  3%  +18.40% (p=0.000 n=10)
Lua/config           715.1m ± 4%   606.1m ±  6%  -15.24% (p=0.000 n=10)    766.7m ±  5%   +7.22% (p=0.002 n=10)
Lua/coroutines       802.6m ± 1%   456.6m ±  4%  -43.11% (p=0.000 n=10)    605.8m ±  4%  -24.53% (p=0.000 n=10)
Lua/fib              676.2m ± 4%   570.8m ±  4%  -15.59% (p=0.000 n=10)    610.8m ±  3%   -9.67% (p=0.000 n=10)
Lua/format           927.6m ± 4%   454.6m ±  4%  -50.99% (p=0.000 n=10)    605.8m ±  3%  -34.70% (p=0.000 n=10)
Lua/globals          873.1m ± 3%   653.9m ±  3%  -25.10% (p=0.000 n=10)    783.3m ±  4%  -10.28% (p=0.000 n=10)
Lua/hash_int         559.9m ± 7%   481.6m ±  6%  -13.99% (p=0.000 n=10)    592.0m ±  5%   +5.74% (p=0.029 n=10)
Lua/hash_string      516.1m ± 5%   454.7m ±  5%  -11.90% (p=0.000 n=10)    517.2m ±  6%        ~ (p=0.853 n=10)
Lua/json             759.4m ± 2%   617.1m ±  5%  -18.74% (p=0.000 n=10)    765.5m ±  6%        ~ (p=0.684 n=10)
Lua/mandelbrot       807.1m ± 3%   546.9m ±  4%  -32.24% (p=0.000 n=10)    557.2m ±  5%  -30.96% (p=0.000 n=10)
Lua/methods          757.5m ± 6%   670.6m ±  4%  -11.48% (p=0.000 n=10)    843.5m ±  7%  +11.35% (p=0.000 n=10)
Lua/nbody           1019.5m ± 4%   766.6m ± 12%  -24.81% (p=0.000 n=10)    806.6m ±  7%  -20.88% (p=0.000 n=10)
Lua/oop              755.2m ± 7%   708.7m ±  5%   -6.16% (p=0.015 n=10)    809.5m ±  5%   +7.20% (p=0.005 n=10)
Lua/patterns         829.9m ± 4%   665.4m ±  4%  -19.82% (p=0.000 n=10)    719.9m ±  2%  -13.26% (p=0.000 n=10)
Lua/spectral_norm    881.5m ± 4%   808.6m ±  4%   -8.27% (p=0.000 n=10)    837.2m ±  5%   -5.02% (p=0.007 n=10)
Lua/table_concat     841.2m ± 9%   330.8m ±  6%  -60.68% (p=0.000 n=10)    526.7m ±  4%  -37.39% (p=0.000 n=10)
Lua/template         790.6m ± 3%   646.2m ±  5%  -18.27% (p=0.000 n=10)    876.5m ±  2%  +10.85% (p=0.000 n=10)
geomean              796.8m        583.6m        -26.76%                   742.5m         -6.82%

                  │      ref      │           ours-ReleaseFast           │           ours-ReleaseSafe           │
                  │ peak-RSS-KiB  │ peak-RSS-KiB  vs base                │ peak-RSS-KiB  vs base                │
Lua/array            35.43k ±  0%    20.98k ± 0%  -40.79% (p=0.000 n=10)    29.35k ± 0%  -17.15% (p=0.000 n=10)
Lua/binary_trees     31.56k ±  0%    26.42k ± 0%  -16.30% (p=0.000 n=10)    26.73k ± 0%  -15.31% (p=0.000 n=10)
Lua/closures         2.932k ±  0%    2.368k ± 0%  -19.24% (p=0.000 n=10)    2.368k ± 0%  -19.24% (p=0.000 n=10)
Lua/concat           2.948k ±  0%    2.368k ± 0%  -19.67% (p=0.000 n=10)    2.368k ± 0%  -19.67% (p=0.000 n=10)
Lua/config           13.03k ± 14%    11.49k ± 0%        ~ (p=0.112 n=10)    11.86k ± 0%        ~ (p=0.112 n=10)
Lua/coroutines       2.904k ±  0%    2.368k ± 0%  -18.46% (p=0.000 n=10)    2.368k ± 0%  -18.46% (p=0.000 n=10)
Lua/fib              2.892k ±  0%    2.368k ± 0%  -18.12% (p=0.000 n=10)    2.368k ± 0%  -18.12% (p=0.000 n=10)
Lua/format           2.952k ±  0%    2.368k ± 0%  -19.78% (p=0.000 n=10)    2.368k ± 0%  -19.78% (p=0.000 n=10)
Lua/globals          2.908k ±  0%    2.368k ± 0%  -18.57% (p=0.000 n=10)    2.368k ± 0%  -18.57% (p=0.000 n=10)
Lua/hash_int         8.500k ±  0%    6.048k ± 0%  -28.85% (p=0.000 n=10)    6.364k ± 0%  -25.13% (p=0.000 n=10)
Lua/hash_string      22.59k ±  0%    22.40k ± 0%   -0.85% (p=0.000 n=10)    23.20k ± 0%   +2.69% (p=0.000 n=10)
Lua/json             12.14k ±  0%    10.46k ± 0%  -13.83% (p=0.000 n=10)    12.32k ± 0%   +1.42% (p=0.000 n=10)
Lua/mandelbrot       2.948k ±  0%    2.368k ± 0%  -19.67% (p=0.000 n=10)    2.368k ± 0%  -19.67% (p=0.000 n=10)
Lua/methods          2.908k ±  0%    2.368k ± 0%  -18.57% (p=0.000 n=10)    2.368k ± 0%  -18.57% (p=0.000 n=10)
Lua/nbody            2.960k ±  0%    2.368k ± 0%  -20.00% (p=0.000 n=10)    2.368k ± 0%  -20.00% (p=0.000 n=10)
Lua/oop             11.324k ±  0%    9.540k ± 0%  -15.75% (p=0.000 n=10)   10.104k ± 0%  -10.77% (p=0.000 n=10)
Lua/patterns        17.648k ±  0%    9.000k ± 0%  -49.00% (p=0.000 n=10)    9.372k ± 0%  -46.89% (p=0.000 n=10)
Lua/spectral_norm    2.984k ±  0%    2.368k ± 0%  -20.64% (p=0.000 n=10)    2.368k ± 0%  -20.64% (p=0.000 n=10)
Lua/table_concat     40.49k ±  0%    23.12k ± 0%  -42.90% (p=0.000 n=10)    30.84k ± 0%  -23.84% (p=0.000 n=10)
Lua/template         3.176k ±  0%    2.368k ± 0%  -25.44% (p=0.000 n=10)    2.368k ± 0%  -25.44% (p=0.000 n=10)
geomean              6.772k          5.231k       -22.76%                   5.503k       -18.74%
```

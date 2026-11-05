# Thread.push copies field by field, 2026-11-05

`bench/methods` lost 7–14% moving to Zig 0.17.1 (`zig-0.17-20261105.md`).
On a 10M-iteration run, perf samples rose 9% overall: 30% in `getSlow`,
and 10% in `runLoop`, mostly in the hash-chain walks that `GETFIELD`/`SELF`
inline (`Table.getShortStrNode`).

Per statement, interleaved, ReleaseFast (ms, median of 11–15):

| statement                  | 0.16 | 0.17 |
| -------------------------- | ---- | ---- |
| `p:move` (one `__index`)   | 180  | 190  |
| `q:move` (two `__index`)   | 248  | 278  |
| `q:lift`                   | 151  | 170  |
| `p:dot`                    | 208  | 201  |
| `proxy:get` (`__index` fn) | 315  | 324  |
| `__add`/`__eq` every 16th  | 130  | 125  |

The hottest instruction in `getSlow` (27% of its samples on 0.17, 14% on
0.16) is in `callTm`'s `th.push`: `Thread.push` stored a whole `Value`, so
Zig copied its 7 padding bytes too, through two overlapping 4-byte stack
spills (`0x10(%rsp)` and `0x13(%rsp)`) read back at once, a store-forwarding
stall. `vm.put`/`vm.setv` already copy payload and tag separately for this
reason (`vm-copies-20261030.md`); `push` now does the same.

What is left of the gap is register allocation in `runLoop`'s `GETFIELD`/
`SELF` handler: the same instructions as 0.16 plus a reload of `th` from the
stack and an `rbp`/`r15` shuffle inside `fastTm`'s chain walk. Not fixed.

Machine: the orb's 4-core Intel Xeon @ 2.60GHz. Both arms built by Zig
0.17.1, ReleaseFast: `zig-0.17` is 973b202, `push` adds this change. 10
interleaved rounds of every `bench/` program pinned to core 3, outputs
checked against the reference, benchstat. methods −5.9% (p=0.000), every
other program within noise, peak RSS unchanged. Against 0.16 on a
three-arm run (15 rounds, medians): methods 484 / 531 / 509 ms, fib 399 /
412 / 406, binary_trees 491 / 504 / 492 for 0.16 / 0.17 / push.

## Raw output

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
                  │   zig-0.17   │                push                 │
                  │    sec/op    │    sec/op     vs base               │
Lua/array           513.8m ± 14%   515.6m ± 11%       ~ (p=0.912 n=10)
Lua/binary_trees    511.8m ±  6%   508.0m ±  5%       ~ (p=0.684 n=10)
Lua/closures        465.7m ±  4%   445.8m ±  6%       ~ (p=0.063 n=10)
Lua/concat          248.9m ±  7%   252.1m ±  2%       ~ (p=0.353 n=10)
Lua/config          411.0m ±  4%   411.8m ±  3%       ~ (p=0.684 n=10)
Lua/coroutines      259.3m ±  5%   266.0m ±  4%       ~ (p=0.105 n=10)
Lua/fib             419.7m ±  1%   410.3m ±  3%       ~ (p=0.063 n=10)
Lua/format          264.3m ±  6%   268.6m ±  3%       ~ (p=0.684 n=10)
Lua/globals         453.5m ±  6%   453.0m ±  4%       ~ (p=0.529 n=10)
Lua/hash_int        379.5m ±  6%   373.0m ±  5%       ~ (p=0.315 n=10)
Lua/hash_string     392.3m ±  3%   388.7m ±  4%       ~ (p=0.912 n=10)
Lua/json            436.3m ±  3%   431.0m ±  5%       ~ (p=0.218 n=10)
Lua/mandelbrot      390.6m ±  3%   378.8m ± 12%       ~ (p=0.280 n=10)
Lua/methods         518.4m ±  5%   487.8m ±  2%  -5.90% (p=0.000 n=10)
Lua/nbody           559.7m ±  1%   547.0m ±  6%       ~ (p=0.190 n=10)
Lua/oop             508.0m ±  4%   522.0m ±  3%       ~ (p=0.143 n=10)
Lua/patterns        452.9m ±  3%   446.0m ±  3%       ~ (p=0.436 n=10)
Lua/spectral_norm   583.6m ±  5%   573.0m ±  3%       ~ (p=0.315 n=10)
Lua/table_concat    236.7m ±  4%   235.0m ±  8%       ~ (p=0.912 n=10)
Lua/template        441.4m ±  3%   439.0m ±  2%       ~ (p=0.739 n=10)
geomean             408.7m         404.8m        -0.94%

                  │   zig-0.17   │                 push                  │
                  │ peak-RSS-KiB │ peak-RSS-KiB  vs base                 │
Lua/array            19.99k ± 0%    19.99k ± 0%       ~ (p=1.000 n=10) ¹
Lua/binary_trees     25.55k ± 0%    25.55k ± 0%       ~ (p=1.000 n=10) ¹
Lua/closures          716.0 ± 0%     716.0 ± 0%       ~ (p=1.000 n=10) ¹
Lua/concat            752.0 ± 0%     752.0 ± 0%       ~ (p=1.000 n=10) ¹
Lua/config           10.79k ± 0%    10.79k ± 0%       ~ (p=1.000 n=10) ¹
Lua/coroutines        776.0 ± 0%     776.0 ± 0%       ~ (p=1.000 n=10) ¹
Lua/fib               632.0 ± 0%     632.0 ± 0%       ~ (p=1.000 n=10) ¹
Lua/format            792.0 ± 0%     792.0 ± 0%       ~ (p=1.000 n=10) ¹
Lua/globals           764.0 ± 0%     764.0 ± 0%       ~ (p=1.000 n=10) ¹
Lua/hash_int         5.052k ± 0%    5.052k ± 0%       ~ (p=1.000 n=10) ¹
Lua/hash_string      21.41k ± 0%    21.41k ± 0%       ~ (p=1.000 n=10) ¹
Lua/json             9.852k ± 0%    9.788k ± 0%  -0.65% (p=0.000 n=10)
Lua/mandelbrot        700.0 ± 0%     700.0 ± 0%       ~ (p=1.000 n=10) ¹
Lua/methods           716.0 ± 0%     716.0 ± 0%       ~ (p=1.000 n=10) ¹
Lua/nbody             840.0 ± 0%     840.0 ± 0%       ~ (p=1.000 n=10) ¹
Lua/oop              8.720k ± 0%    8.720k ± 0%       ~ (p=1.000 n=10) ¹
Lua/patterns         8.272k ± 0%    8.272k ± 0%       ~ (p=1.000 n=10) ¹
Lua/spectral_norm     816.0 ± 0%     816.0 ± 0%       ~ (p=1.000 n=10) ¹
Lua/table_concat     22.26k ± 0%    22.26k ± 0%       ~ (p=1.000 n=10) ¹
Lua/template         1.180k ± 0%    1.180k ± 0%       ~ (p=1.000 n=10) ¹
geomean              2.750k         2.749k       -0.03%
¹ all samples are equal
```

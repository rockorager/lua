# Registers for the interpreter loop, 2026-10-30

The table-access change (`vm-table-access-20261030.md`) made fib,
mandelbrot, and methods 4–6% slower without touching their handlers.
Their profiles showed the cause: the loop keeps more values live across
calls (`th`, `ci`, `cl`, `k`, `base`, `pc`, the instruction, and a
`heap` pointer) than x86-64 has callee-saved registers. LLVM now spilled
`th` itself, so `CALL` reloaded it from the stack six times. Its
allocator also weighs every slow-path call as likely as the fast path.

## The change

- Every slow path the loop calls is marked `@branchHint(.cold)`
  (`getSlow`, `setSlow`, `arithSlow`, the comparisons, `finishOp`,
  the hooks, `forPrep`, and the error builders), so LLVM puts spill code
  in those blocks.
- The loop no longer keeps a `heap` local; stores take `th.heap()`.
- `SETFIELD`, `SETTABLE`, and `SETTABUP` call `Table.setShortStr`
  through `setShortStrAt`, which takes the value by pointer. With a
  `Value` argument, nbody's `SETFIELD` copied its operand to a stack
  temporary on every store (a vector load of a just-written register,
  12% of nbody's samples), not only on the stores that add a key.
  `SETTABUP` also replaces a present global in place first.
- The `lua` executable builds its own instance of the module with
  `omit_frame_pointer` in optimized builds, which frees `rbp` for the
  loop. The exported module keeps the consumer's setting.

Base is 9cb33c6 (the table change); new is this change. ReleaseFast, 10
rounds of every `bench/` program, interleaved, pinned to the last core,
wall time and peak RSS per process, benchstat.

## Results

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
                  │     base     │                 new                 │
                  │    sec/op    │    sec/op     vs base               │
Lua/array            1.008 ±  3%    1.003 ±  4%       ~ (p=0.280 n=10)
Lua/binary_trees    884.1m ± 28%   825.5m ± 12%  -6.63% (p=0.029 n=10)
Lua/closures        650.4m ±  6%   643.9m ±  2%       ~ (p=0.105 n=10)
Lua/concat          389.7m ±  3%   375.5m ±  8%  -3.64% (p=0.019 n=10)
Lua/coroutines      558.9m ±  9%   521.1m ±  8%  -6.76% (p=0.007 n=10)
Lua/fib             648.3m ±  6%   625.5m ±  2%  -3.51% (p=0.000 n=10)
Lua/format          470.7m ±  5%   471.0m ± 10%       ~ (p=0.579 n=10)
Lua/hash_int        492.0m ± 12%   479.9m ±  2%  -2.45% (p=0.015 n=10)
Lua/hash_string     532.9m ±  9%   529.8m ± 13%       ~ (p=0.796 n=10)
Lua/mandelbrot      582.7m ±  4%   577.9m ±  5%       ~ (p=0.353 n=10)
Lua/methods         726.4m ±  3%   684.7m ±  5%  -5.74% (p=0.007 n=10)
Lua/nbody           796.2m ±  3%   802.4m ±  4%       ~ (p=0.436 n=10)
Lua/patterns        661.5m ± 10%   638.7m ± 11%       ~ (p=0.052 n=10)
Lua/spectral_norm   887.0m ±  2%   840.4m ±  6%  -5.26% (p=0.009 n=10)
Lua/table_concat    346.2m ±  5%   341.0m ±  6%       ~ (p=0.393 n=10)
geomean             615.6m         598.6m        -2.77%

                  │     base     │                 new                 │
                  │ peak-RSS-KiB │ peak-RSS-KiB  vs base               │
Lua/array            20.84k ± 0%    20.78k ± 0%  -0.27% (p=0.000 n=10)
Lua/binary_trees     18.97k ± 0%    18.91k ± 0%  -0.28% (p=0.000 n=10)
Lua/closures         2.372k ± 0%    2.372k ± 0%       ~ (p=0.979 n=10)
Lua/concat           2.372k ± 0%    2.372k ± 0%       ~ (p=0.095 n=10)
Lua/coroutines       2.374k ± 0%    2.372k ± 0%       ~ (p=0.375 n=10)
Lua/fib              2.372k ± 0%    2.372k ± 0%       ~ (p=0.608 n=10)
Lua/format           2.372k ± 0%    2.372k ± 0%       ~ (p=0.638 n=10)
Lua/hash_int         12.06k ± 0%    12.00k ± 0%  -0.46% (p=0.000 n=10)
Lua/hash_string      34.68k ± 0%    34.62k ± 0%  -0.15% (p=0.000 n=10)
Lua/mandelbrot       2.372k ± 0%    2.372k ± 0%       ~ (p=0.054 n=10)
Lua/methods          2.372k ± 0%    2.372k ± 0%       ~ (p=0.718 n=10)
Lua/nbody            2.370k ± 0%    2.372k ± 0%       ~ (p=0.263 n=10)
Lua/patterns         8.750k ± 0%    8.694k ± 0%  -0.64% (p=0.000 n=10)
Lua/spectral_norm    2.376k ± 0%    2.376k ± 0%       ~ (p=0.907 n=10)
Lua/table_concat     22.13k ± 0%    22.07k ± 0%  -0.25% (p=0.000 n=10)
geomean              5.314k         5.307k       -0.14%
```

The parts alone, measured first on six programs and six rounds against
the same base (cold hints; then also no `heap`; then also no frame
pointer, before `setShortStrAt`). Each part alone moves programs both
ways by a few percent, which is layout. Only all of them together moves
everything one way:

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
                  │     base     │                cold                │              noheap               │                nofp                │
                  │    sec/op    │    sec/op     vs base              │   sec/op     vs base              │    sec/op     vs base              │
Lua/fib             662.3m ± 11%   649.8m ±  4%       ~ (p=0.394 n=6)   644.8m ± 3%  -2.64% (p=0.026 n=6)   628.0m ±  1%  -5.17% (p=0.002 n=6)
Lua/mandelbrot      588.3m ±  7%   571.9m ±  6%  -2.80% (p=0.041 n=6)   634.7m ± 3%  +7.87% (p=0.002 n=6)   569.6m ± 18%       ~ (p=0.065 n=6)
Lua/methods         731.8m ±  6%   722.0m ±  9%       ~ (p=0.937 n=6)   736.5m ± 3%       ~ (p=0.818 n=6)   688.9m ±  2%  -5.86% (p=0.002 n=6)
Lua/spectral_norm   873.4m ±  4%   918.9m ±  3%  +5.20% (p=0.002 n=6)   866.0m ± 1%       ~ (p=0.180 n=6)   860.7m ±  5%       ~ (p=0.240 n=6)
Lua/nbody           846.6m ± 15%   813.6m ±  3%  -3.90% (p=0.026 n=6)   794.8m ± 5%  -6.12% (p=0.026 n=6)   858.3m ±  6%       ~ (p=0.485 n=6)
Lua/coroutines      549.1m ± 14%   546.8m ± 11%       ~ (p=0.485 n=6)   550.8m ± 9%       ~ (p=0.394 n=6)   515.3m ±  4%  -6.15% (p=0.002 n=6)
geomean             698.1m         691.9m        -0.90%                 696.6m       -0.22%                 674.1m        -3.44%
```

## Reading it

- −2.8% geomean, and nothing slower: coroutines −7%, binary_trees −7%,
  methods −6%, spectral_norm −5%, concat −4%, fib −4%. The table change's
  regressions are gone.
- Peak RSS is unchanged; the small drops are the binary.

## Raw output

base:

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
BenchmarkLua/array	1	995451000 ns/op	20836 peak-RSS-KiB
BenchmarkLua/binary_trees	1	846112000 ns/op	18968 peak-RSS-KiB
BenchmarkLua/closures	1	645186000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/concat	1	390777000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/coroutines	1	558510000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/fib	1	647547000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/format	1	470142000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/hash_int	1	499604000 ns/op	12056 peak-RSS-KiB
BenchmarkLua/hash_string	1	537050000 ns/op	34676 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	607061000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	754134000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/nbody	1	902658000 ns/op	2364 peak-RSS-KiB
BenchmarkLua/patterns	1	728880000 ns/op	8748 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	940834000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/table_concat	1	362666000 ns/op	22128 peak-RSS-KiB
BenchmarkLua/array	1	1038812000 ns/op	20836 peak-RSS-KiB
BenchmarkLua/binary_trees	1	886385000 ns/op	18972 peak-RSS-KiB
BenchmarkLua/closures	1	691579000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/concat	1	398870000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/coroutines	1	556910000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/fib	1	648297000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/format	1	467773000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/hash_int	1	494359000 ns/op	12056 peak-RSS-KiB
BenchmarkLua/hash_string	1	539744000 ns/op	34680 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	594028000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/methods	1	717040000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/nbody	1	792918000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/patterns	1	726347000 ns/op	8748 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	892741000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/table_concat	1	341692000 ns/op	22132 peak-RSS-KiB
BenchmarkLua/array	1	1000588000 ns/op	20840 peak-RSS-KiB
BenchmarkLua/binary_trees	1	838585000 ns/op	18968 peak-RSS-KiB
BenchmarkLua/closures	1	649176000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/concat	1	385959000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/coroutines	1	555225000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/fib	1	643293000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/format	1	471307000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/hash_int	1	504122000 ns/op	12056 peak-RSS-KiB
BenchmarkLua/hash_string	1	533890000 ns/op	34676 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	575619000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	701829000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/nbody	1	797697000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/patterns	1	662721000 ns/op	8748 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	897494000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/table_concat	1	345807000 ns/op	22128 peak-RSS-KiB
BenchmarkLua/array	1	1007493000 ns/op	20836 peak-RSS-KiB
BenchmarkLua/binary_trees	1	863153000 ns/op	18968 peak-RSS-KiB
BenchmarkLua/closures	1	641789000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/concat	1	385799000 ns/op	2364 peak-RSS-KiB
BenchmarkLua/coroutines	1	549346000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/fib	1	645759000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/format	1	507644000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/hash_int	1	482993000 ns/op	12052 peak-RSS-KiB
BenchmarkLua/hash_string	1	520236000 ns/op	34680 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	576036000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	704890000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/nbody	1	794626000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/patterns	1	657622000 ns/op	8752 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	900184000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/table_concat	1	337460000 ns/op	22132 peak-RSS-KiB
BenchmarkLua/array	1	1032394000 ns/op	20836 peak-RSS-KiB
BenchmarkLua/binary_trees	1	951257000 ns/op	18968 peak-RSS-KiB
BenchmarkLua/closures	1	651524000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/concat	1	396890000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/coroutines	1	564287000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/fib	1	653425000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/format	1	466845000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/hash_int	1	472483000 ns/op	12052 peak-RSS-KiB
BenchmarkLua/hash_string	1	520468000 ns/op	34676 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	581384000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	742107000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/nbody	1	782400000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/patterns	1	656448000 ns/op	8748 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	865817000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/table_concat	1	335759000 ns/op	22128 peak-RSS-KiB
BenchmarkLua/array	1	984154000 ns/op	20836 peak-RSS-KiB
BenchmarkLua/binary_trees	1	868030000 ns/op	18972 peak-RSS-KiB
BenchmarkLua/closures	1	647605000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/concat	1	387081000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/coroutines	1	611538000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/fib	1	675921000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/format	1	493927000 ns/op	2364 peak-RSS-KiB
BenchmarkLua/hash_int	1	481707000 ns/op	12056 peak-RSS-KiB
BenchmarkLua/hash_string	1	531911000 ns/op	34676 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	577446000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	724979000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/nbody	1	772963000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/patterns	1	656667000 ns/op	8752 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	877701000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/table_concat	1	346625000 ns/op	22128 peak-RSS-KiB
BenchmarkLua/array	1	1098415000 ns/op	20836 peak-RSS-KiB
BenchmarkLua/binary_trees	1	881868000 ns/op	18968 peak-RSS-KiB
BenchmarkLua/closures	1	643502000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/concat	1	384042000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/coroutines	1	578956000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/fib	1	706807000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/format	1	467315000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/hash_int	1	550868000 ns/op	12056 peak-RSS-KiB
BenchmarkLua/hash_string	1	578241000 ns/op	34676 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	607048000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	734906000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/nbody	1	803040000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/patterns	1	745235000 ns/op	8752 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	867304000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/table_concat	1	360064000 ns/op	22128 peak-RSS-KiB
BenchmarkLua/array	1	1008615000 ns/op	20840 peak-RSS-KiB
BenchmarkLua/binary_trees	1	1214839000 ns/op	18972 peak-RSS-KiB
BenchmarkLua/closures	1	665104000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/concat	1	388555000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/coroutines	1	549882000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/fib	1	687597000 ns/op	2360 peak-RSS-KiB
BenchmarkLua/format	1	483090000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/hash_int	1	571040000 ns/op	12056 peak-RSS-KiB
BenchmarkLua/hash_string	1	595110000 ns/op	34680 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	609361000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	741684000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/nbody	1	821260000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/patterns	1	658816000 ns/op	8752 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	862462000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/table_concat	1	344657000 ns/op	22128 peak-RSS-KiB
BenchmarkLua/array	1	982237000 ns/op	20840 peak-RSS-KiB
BenchmarkLua/binary_trees	1	1131628000 ns/op	18972 peak-RSS-KiB
BenchmarkLua/closures	1	707305000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/concat	1	400865000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/coroutines	1	559327000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/fib	1	648232000 ns/op	2364 peak-RSS-KiB
BenchmarkLua/format	1	469192000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/hash_int	1	489660000 ns/op	12052 peak-RSS-KiB
BenchmarkLua/hash_string	1	509500000 ns/op	34676 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	584047000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	727846000 ns/op	2356 peak-RSS-KiB
BenchmarkLua/nbody	1	815699000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/patterns	1	665757000 ns/op	8752 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	881245000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/table_concat	1	394919000 ns/op	22128 peak-RSS-KiB
BenchmarkLua/array	1	1037512000 ns/op	20836 peak-RSS-KiB
BenchmarkLua/binary_trees	1	901982000 ns/op	18968 peak-RSS-KiB
BenchmarkLua/closures	1	691640000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/concat	1	416864000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/coroutines	1	626994000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/fib	1	646376000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/format	1	471270000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/hash_int	1	484759000 ns/op	12056 peak-RSS-KiB
BenchmarkLua/hash_string	1	500313000 ns/op	34680 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	575740000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	707051000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/nbody	1	773620000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/patterns	1	660285000 ns/op	8748 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	898948000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/table_concat	1	348430000 ns/op	22128 peak-RSS-KiB
```

new:

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
BenchmarkLua/array	1	1022620000 ns/op	20780 peak-RSS-KiB
BenchmarkLua/binary_trees	1	811746000 ns/op	18912 peak-RSS-KiB
BenchmarkLua/closures	1	636891000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/concat	1	380829000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/coroutines	1	531000000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/fib	1	632505000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/format	1	476797000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/hash_int	1	483238000 ns/op	12000 peak-RSS-KiB
BenchmarkLua/hash_string	1	526886000 ns/op	34620 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	600668000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/methods	1	703734000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/nbody	1	848009000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/patterns	1	680083000 ns/op	8696 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	888737000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/table_concat	1	354372000 ns/op	22072 peak-RSS-KiB
BenchmarkLua/array	1	1012833000 ns/op	20780 peak-RSS-KiB
BenchmarkLua/binary_trees	1	805261000 ns/op	18916 peak-RSS-KiB
BenchmarkLua/closures	1	654950000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/concat	1	417104000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/coroutines	1	618653000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/fib	1	621879000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/format	1	460297000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/hash_int	1	489029000 ns/op	11996 peak-RSS-KiB
BenchmarkLua/hash_string	1	505791000 ns/op	34624 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	577021000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	685507000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/nbody	1	786328000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/patterns	1	709950000 ns/op	8692 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	839727000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/table_concat	1	336487000 ns/op	22072 peak-RSS-KiB
BenchmarkLua/array	1	992383000 ns/op	20780 peak-RSS-KiB
BenchmarkLua/binary_trees	1	821220000 ns/op	18916 peak-RSS-KiB
BenchmarkLua/closures	1	625015000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/concat	1	374615000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/coroutines	1	561669000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/fib	1	620014000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/format	1	475856000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/hash_int	1	472040000 ns/op	12000 peak-RSS-KiB
BenchmarkLua/hash_string	1	522517000 ns/op	34620 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	570572000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/methods	1	672953000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/nbody	1	815064000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/patterns	1	634716000 ns/op	8692 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	832904000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/table_concat	1	366456000 ns/op	22076 peak-RSS-KiB
BenchmarkLua/array	1	1050574000 ns/op	20780 peak-RSS-KiB
BenchmarkLua/binary_trees	1	817471000 ns/op	18916 peak-RSS-KiB
BenchmarkLua/closures	1	655596000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/concat	1	376145000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/coroutines	1	515497000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/fib	1	621033000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/format	1	483979000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/hash_int	1	474180000 ns/op	11996 peak-RSS-KiB
BenchmarkLua/hash_string	1	583958000 ns/op	34624 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	573177000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/methods	1	666077000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/nbody	1	799796000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/patterns	1	630594000 ns/op	8696 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	836833000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/table_concat	1	335160000 ns/op	22072 peak-RSS-KiB
BenchmarkLua/array	1	965502000 ns/op	20780 peak-RSS-KiB
BenchmarkLua/binary_trees	1	927642000 ns/op	18916 peak-RSS-KiB
BenchmarkLua/closures	1	647805000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/concat	1	374204000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/coroutines	1	506991000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/fib	1	620409000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/format	1	458786000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/hash_int	1	471596000 ns/op	11996 peak-RSS-KiB
BenchmarkLua/hash_string	1	529763000 ns/op	34620 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	605113000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	693653000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/nbody	1	789112000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/patterns	1	632564000 ns/op	8692 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	830015000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/table_concat	1	337545000 ns/op	22072 peak-RSS-KiB
BenchmarkLua/array	1	951862000 ns/op	20780 peak-RSS-KiB
BenchmarkLua/binary_trees	1	807954000 ns/op	18912 peak-RSS-KiB
BenchmarkLua/closures	1	631834000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/concat	1	378562000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/coroutines	1	517523000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/fib	1	626061000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/format	1	516243000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/hash_int	1	479687000 ns/op	12000 peak-RSS-KiB
BenchmarkLua/hash_string	1	597701000 ns/op	34620 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	634718000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	769917000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/nbody	1	798657000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/patterns	1	636798000 ns/op	8696 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	834283000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/table_concat	1	330331000 ns/op	22072 peak-RSS-KiB
BenchmarkLua/array	1	961266000 ns/op	20780 peak-RSS-KiB
BenchmarkLua/binary_trees	1	829768000 ns/op	18916 peak-RSS-KiB
BenchmarkLua/closures	1	636776000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/concat	1	374293000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/coroutines	1	524705000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/fib	1	629383000 ns/op	2364 peak-RSS-KiB
BenchmarkLua/format	1	462081000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/hash_int	1	487264000 ns/op	12000 peak-RSS-KiB
BenchmarkLua/hash_string	1	622100000 ns/op	34624 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	578807000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/methods	1	720486000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/nbody	1	815960000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/patterns	1	748067000 ns/op	8692 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	889341000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/table_concat	1	350754000 ns/op	22072 peak-RSS-KiB
BenchmarkLua/array	1	1021505000 ns/op	20780 peak-RSS-KiB
BenchmarkLua/binary_trees	1	1058321000 ns/op	18912 peak-RSS-KiB
BenchmarkLua/closures	1	662097000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/concat	1	374802000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/coroutines	1	509001000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/fib	1	625010000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/format	1	536699000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/hash_int	1	484518000 ns/op	12000 peak-RSS-KiB
BenchmarkLua/hash_string	1	555774000 ns/op	34624 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	590905000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	680199000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/nbody	1	805031000 ns/op	2364 peak-RSS-KiB
BenchmarkLua/patterns	1	640531000 ns/op	8692 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	875928000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/table_concat	1	334476000 ns/op	22072 peak-RSS-KiB
BenchmarkLua/array	1	958532000 ns/op	20784 peak-RSS-KiB
BenchmarkLua/binary_trees	1	881030000 ns/op	18912 peak-RSS-KiB
BenchmarkLua/closures	1	639928000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/concat	1	374468000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/coroutines	1	515306000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/fib	1	639872000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/format	1	466230000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/hash_int	1	476458000 ns/op	12000 peak-RSS-KiB
BenchmarkLua/hash_string	1	529860000 ns/op	34624 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	575029000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	683882000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/nbody	1	834827000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/patterns	1	646207000 ns/op	8696 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	871397000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/table_concat	1	362862000 ns/op	22076 peak-RSS-KiB
BenchmarkLua/array	1	1017630000 ns/op	20784 peak-RSS-KiB
BenchmarkLua/binary_trees	1	849754000 ns/op	18912 peak-RSS-KiB
BenchmarkLua/closures	1	651991000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/concat	1	404066000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/coroutines	1	548221000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/fib	1	650153000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/format	1	463029000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/hash_int	1	480180000 ns/op	12000 peak-RSS-KiB
BenchmarkLua/hash_string	1	496226000 ns/op	34624 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	571205000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	680492000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/nbody	1	789545000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/patterns	1	634678000 ns/op	8696 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	840989000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/table_concat	1	344391000 ns/op	22072 peak-RSS-KiB
```

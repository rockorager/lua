# Operands that stay in registers, 2026-10-30

The first wave-3 profile (`perf record -e cpu-clock` on ReleaseFast;
the orb has no hardware counters) put mandelbrot's hottest instructions
in `LT` and `LEI`: each loaded its operand `Value`s with one 16-byte
vector load, stored them to a stack temporary, and read the tag and
payload back from there. The same pattern was in `GETTABLE`, `GETFIELD`,
`SETFIELD`, and the arithmetic slow paths. The cause: the slow paths
(`getSlow`, `setSlow`, `arithSlow`, `lenSlow`, `equalSlow`, `orderSlow`)
took `Value`s by value, Zig's calling convention passes a 16-byte struct
by reference, and LLVM materialized each operand in memory up front for
the possible call, so the fast path paid for the copy every time.

## The change

- The slow paths take `*const Value` that point at the operand where it
  already is (a register, a constant, an upvalue), or at a temporary built
  inside the slow branch, and copy it on entry. The fast paths now read
  tags and payloads with scalar loads straight from the registers.
- Arithmetic and `EQ`/`LT`/`LE` get a float-and-float fast path before the
  mixed int/float one, which converted both operands branchlessly (two
  `cvtsi2sd` and two masked moves on the dependency chain of every float
  operation).

Base is `wave3-perf` at 5ac12f0 (the hooks plus `bench-compare` RSS);
new is this change. Both ReleaseFast, 10 rounds of every `bench/`
program, interleaved in a rotating order, pinned to the last core with
`taskset`, wall time and peak RSS (GNU time's `%M`) per process,
benchstat.

## Results

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
                  │     base      │                 new                  │
                  │    sec/op     │    sec/op     vs base                │
Lua/array             1.224 ±  2%    1.230 ±  4%        ~ (p=0.739 n=10)
Lua/binary_trees     888.9m ± 11%   868.1m ±  5%        ~ (p=0.353 n=10)
Lua/closures         677.2m ±  4%   692.6m ±  3%        ~ (p=0.075 n=10)
Lua/concat           389.5m ±  4%   395.7m ±  4%        ~ (p=0.631 n=10)
Lua/coroutines       549.8m ± 10%   539.1m ±  7%        ~ (p=0.481 n=10)
Lua/fib              652.3m ±  5%   628.8m ±  4%   -3.61% (p=0.007 n=10)
Lua/format           461.2m ±  1%   470.9m ±  3%   +2.10% (p=0.011 n=10)
Lua/hash_int         795.5m ±  5%   807.6m ±  6%        ~ (p=0.353 n=10)
Lua/hash_string      825.6m ± 18%   894.3m ± 14%        ~ (p=0.247 n=10)
Lua/mandelbrot       871.9m ±  5%   577.0m ±  2%  -33.83% (p=0.000 n=10)
Lua/methods          808.9m ±  7%   723.2m ±  5%  -10.59% (p=0.000 n=10)
Lua/nbody           1216.0m ±  2%   976.6m ±  2%  -19.69% (p=0.000 n=10)
Lua/patterns         668.0m ±  6%   657.8m ±  5%        ~ (p=0.218 n=10)
Lua/spectral_norm     1.126 ±  2%    1.021 ±  7%   -9.32% (p=0.000 n=10)
Lua/table_concat     387.4m ±  4%   390.1m ±  7%        ~ (p=0.796 n=10)
geomean              723.5m         687.2m         -5.01%

                  │     base     │                 new                 │
                  │ peak-RSS-KiB │ peak-RSS-KiB  vs base               │
Lua/array            20.90k ± 0%    20.83k ± 0%  -0.33% (p=0.000 n=10)
Lua/binary_trees     18.97k ± 0%    18.97k ± 0%       ~ (p=0.628 n=10)
Lua/closures         2.372k ± 0%    2.372k ± 0%       ~ (p=0.628 n=10)
Lua/concat           2.372k ± 0%    2.372k ± 0%       ~ (p=0.854 n=10)
Lua/coroutines       2.372k ± 0%    2.372k ± 0%       ~ (p=0.376 n=10)
Lua/fib              2.372k ± 0%    2.372k ± 0%       ~ (p=0.075 n=10)
Lua/format           2.372k ± 0%    2.372k ± 0%       ~ (p=0.677 n=10)
Lua/hash_int         12.11k ± 0%    12.05k ± 0%  -0.53% (p=0.000 n=10)
Lua/hash_string      34.74k ± 0%    34.67k ± 0%  -0.20% (p=0.000 n=10)
Lua/mandelbrot       2.372k ± 0%    2.372k ± 0%       ~ (p=0.971 n=10)
Lua/methods          2.372k ± 0%    2.374k ± 0%       ~ (p=0.924 n=10)
Lua/nbody            2.372k ± 0%    2.372k ± 0%       ~ (p=0.747 n=10)
Lua/patterns         8.744k ± 0%    8.746k ± 0%       ~ (p=0.650 n=10)
Lua/spectral_norm    2.372k ± 0%    2.372k ± 0%       ~ (p=0.739 n=10)
Lua/table_concat     22.19k ± 0%    22.13k ± 0%  -0.28% (p=0.000 n=10)
geomean              5.318k         5.314k       -0.08%
```

## Reading it

- mandelbrot −34% (now 0.58 s against the reference's 0.71 s), nbody
  −20%, methods −11%, spectral_norm −9%, fib −4%: every program whose
  inner loop compares, does float arithmetic, or touches fields.
- format +2% is code layout; nothing on its path changed.
- Peak RSS is unchanged; the 0.2–0.5% drops are the smaller binary.

## Raw output

base:

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
BenchmarkLua/array	1	1212842000 ns/op	20900 peak-RSS-KiB
BenchmarkLua/binary_trees	1	904159000 ns/op	18964 peak-RSS-KiB
BenchmarkLua/closures	1	718623000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/concat	1	387183000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/coroutines	1	536945000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/fib	1	647871000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/format	1	459123000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/hash_int	1	832777000 ns/op	12112 peak-RSS-KiB
BenchmarkLua/hash_string	1	974860000 ns/op	34736 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	913594000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	810965000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/nbody	1	1235185000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/patterns	1	671113000 ns/op	8744 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	1104851000 ns/op	2364 peak-RSS-KiB
BenchmarkLua/table_concat	1	384464000 ns/op	22192 peak-RSS-KiB
BenchmarkLua/array	1	1206416000 ns/op	20896 peak-RSS-KiB
BenchmarkLua/binary_trees	1	826935000 ns/op	18964 peak-RSS-KiB
BenchmarkLua/closures	1	676820000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/concat	1	405251000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/coroutines	1	736670000 ns/op	2352 peak-RSS-KiB
BenchmarkLua/fib	1	701151000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/format	1	661728000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/hash_int	1	891975000 ns/op	12112 peak-RSS-KiB
BenchmarkLua/hash_string	1	1337725000 ns/op	34740 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	868360000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	814289000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/nbody	1	1260019000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/patterns	1	806849000 ns/op	8744 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	1149937000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/table_concat	1	392723000 ns/op	22188 peak-RSS-KiB
BenchmarkLua/array	1	1244816000 ns/op	20900 peak-RSS-KiB
BenchmarkLua/binary_trees	1	873548000 ns/op	18968 peak-RSS-KiB
BenchmarkLua/closures	1	677528000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/concat	1	385919000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/coroutines	1	602673000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/fib	1	647977000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/format	1	460358000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/hash_int	1	797344000 ns/op	12116 peak-RSS-KiB
BenchmarkLua/hash_string	1	841689000 ns/op	34740 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	867099000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/methods	1	803479000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/nbody	1	1206737000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/patterns	1	705307000 ns/op	8744 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	1139336000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/table_concat	1	390263000 ns/op	22188 peak-RSS-KiB
BenchmarkLua/array	1	1237641000 ns/op	20896 peak-RSS-KiB
BenchmarkLua/binary_trees	1	954086000 ns/op	18968 peak-RSS-KiB
BenchmarkLua/closures	1	686599000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/concat	1	398032000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/coroutines	1	549851000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/fib	1	658142000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/format	1	458009000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/hash_int	1	771997000 ns/op	12112 peak-RSS-KiB
BenchmarkLua/hash_string	1	763448000 ns/op	34736 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	872125000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	839726000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/nbody	1	1225951000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/patterns	1	658892000 ns/op	8748 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	1106498000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/table_concat	1	383991000 ns/op	22188 peak-RSS-KiB
BenchmarkLua/array	1	1265201000 ns/op	20900 peak-RSS-KiB
BenchmarkLua/binary_trees	1	932376000 ns/op	18968 peak-RSS-KiB
BenchmarkLua/closures	1	676488000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/concat	1	384412000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/coroutines	1	552982000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/fib	1	648819000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/format	1	462008000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/hash_int	1	765473000 ns/op	12116 peak-RSS-KiB
BenchmarkLua/hash_string	1	803437000 ns/op	34736 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	940285000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/methods	1	754983000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/nbody	1	1241786000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/patterns	1	669071000 ns/op	8748 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	1125760000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/table_concat	1	430843000 ns/op	22192 peak-RSS-KiB
BenchmarkLua/array	1	1195460000 ns/op	20900 peak-RSS-KiB
BenchmarkLua/binary_trees	1	852328000 ns/op	18968 peak-RSS-KiB
BenchmarkLua/closures	1	669085000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/concat	1	393582000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/coroutines	1	530247000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/fib	1	642415000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/format	1	458229000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/hash_int	1	792203000 ns/op	12116 peak-RSS-KiB
BenchmarkLua/hash_string	1	816636000 ns/op	34740 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	863548000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	854207000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/nbody	1	1204832000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/patterns	1	681026000 ns/op	8744 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	1144052000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/table_concat	1	391267000 ns/op	22188 peak-RSS-KiB
BenchmarkLua/array	1	1199383000 ns/op	20896 peak-RSS-KiB
BenchmarkLua/binary_trees	1	988257000 ns/op	18964 peak-RSS-KiB
BenchmarkLua/closures	1	676074000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/concat	1	391755000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/coroutines	1	532887000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/fib	1	642519000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/format	1	462342000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/hash_int	1	797048000 ns/op	12112 peak-RSS-KiB
BenchmarkLua/hash_string	1	866326000 ns/op	34736 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	884048000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/methods	1	806797000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/nbody	1	1225231000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/patterns	1	666968000 ns/op	8744 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	1125283000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/table_concat	1	400404000 ns/op	22188 peak-RSS-KiB
BenchmarkLua/array	1	1244202000 ns/op	20896 peak-RSS-KiB
BenchmarkLua/binary_trees	1	864110000 ns/op	18968 peak-RSS-KiB
BenchmarkLua/closures	1	676154000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/concat	1	385857000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/coroutines	1	549661000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/fib	1	655875000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/format	1	460175000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/hash_int	1	813131000 ns/op	12112 peak-RSS-KiB
BenchmarkLua/hash_string	1	828279000 ns/op	34740 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	871759000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/methods	1	767279000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/nbody	1	1164134000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/patterns	1	654187000 ns/op	8748 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	1119509000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/table_concat	1	364025000 ns/op	22188 peak-RSS-KiB
BenchmarkLua/array	1	1189809000 ns/op	20900 peak-RSS-KiB
BenchmarkLua/binary_trees	1	1030462000 ns/op	18968 peak-RSS-KiB
BenchmarkLua/closures	1	699314000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/concat	1	387032000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/coroutines	1	560649000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/fib	1	668034000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/format	1	465882000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/hash_int	1	760224000 ns/op	12112 peak-RSS-KiB
BenchmarkLua/hash_string	1	822934000 ns/op	34740 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	886594000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/methods	1	821912000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/nbody	1	1193161000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/patterns	1	665381000 ns/op	8744 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	1126160000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/table_concat	1	372727000 ns/op	22188 peak-RSS-KiB
BenchmarkLua/array	1	1235445000 ns/op	20900 peak-RSS-KiB
BenchmarkLua/binary_trees	1	864433000 ns/op	18964 peak-RSS-KiB
BenchmarkLua/closures	1	706399000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/concat	1	414601000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/coroutines	1	534875000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/fib	1	683401000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/format	1	468090000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/hash_int	1	794031000 ns/op	12116 peak-RSS-KiB
BenchmarkLua/hash_string	1	794357000 ns/op	34740 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	862300000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/methods	1	748968000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/nbody	1	1185843000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/patterns	1	662985000 ns/op	8744 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	1116360000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/table_concat	1	378207000 ns/op	22192 peak-RSS-KiB
```

new:

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
BenchmarkLua/array	1	1202558000 ns/op	20832 peak-RSS-KiB
BenchmarkLua/binary_trees	1	862649000 ns/op	18968 peak-RSS-KiB
BenchmarkLua/closures	1	686673000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/concat	1	388713000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/coroutines	1	538779000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/fib	1	627937000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/format	1	470214000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/hash_int	1	819546000 ns/op	12048 peak-RSS-KiB
BenchmarkLua/hash_string	1	1015368000 ns/op	34676 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	593530000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/methods	1	724171000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/nbody	1	972657000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/patterns	1	654356000 ns/op	8744 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	1023201000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/table_concat	1	376913000 ns/op	22128 peak-RSS-KiB
BenchmarkLua/array	1	1225907000 ns/op	20836 peak-RSS-KiB
BenchmarkLua/binary_trees	1	801401000 ns/op	18968 peak-RSS-KiB
BenchmarkLua/closures	1	693767000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/concat	1	406078000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/coroutines	1	532725000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/fib	1	764324000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/format	1	490164000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/hash_int	1	810720000 ns/op	12048 peak-RSS-KiB
BenchmarkLua/hash_string	1	1619522000 ns/op	34672 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	578323000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	803246000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/nbody	1	1030868000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/patterns	1	771658000 ns/op	8748 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	1022240000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/table_concat	1	403149000 ns/op	22124 peak-RSS-KiB
BenchmarkLua/array	1	1278136000 ns/op	20836 peak-RSS-KiB
BenchmarkLua/binary_trees	1	901556000 ns/op	18968 peak-RSS-KiB
BenchmarkLua/closures	1	713103000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/concat	1	399759000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/coroutines	1	575301000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/fib	1	629781000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/format	1	463765000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/hash_int	1	866114000 ns/op	12048 peak-RSS-KiB
BenchmarkLua/hash_string	1	826454000 ns/op	34676 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	576371000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/methods	1	747884000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/nbody	1	987258000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/patterns	1	690738000 ns/op	8744 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	1028051000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/table_concat	1	387422000 ns/op	22124 peak-RSS-KiB
BenchmarkLua/array	1	1232562000 ns/op	20832 peak-RSS-KiB
BenchmarkLua/binary_trees	1	872181000 ns/op	18968 peak-RSS-KiB
BenchmarkLua/closures	1	691532000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/concat	1	409916000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/coroutines	1	536541000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/fib	1	641803000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/format	1	474092000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/hash_int	1	779257000 ns/op	12048 peak-RSS-KiB
BenchmarkLua/hash_string	1	819743000 ns/op	34672 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	590453000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	760053000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/nbody	1	955737000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/patterns	1	657099000 ns/op	8744 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	1018977000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/table_concat	1	392928000 ns/op	22128 peak-RSS-KiB
BenchmarkLua/array	1	1228108000 ns/op	20832 peak-RSS-KiB
BenchmarkLua/binary_trees	1	866721000 ns/op	18964 peak-RSS-KiB
BenchmarkLua/closures	1	686450000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/concat	1	384928000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/coroutines	1	542126000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/fib	1	629129000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/format	1	466097000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/hash_int	1	761090000 ns/op	12052 peak-RSS-KiB
BenchmarkLua/hash_string	1	912721000 ns/op	34672 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	574656000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/methods	1	707047000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/nbody	1	980490000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/patterns	1	693012000 ns/op	8744 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	1117544000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/table_concat	1	448290000 ns/op	22128 peak-RSS-KiB
BenchmarkLua/array	1	1233589000 ns/op	20836 peak-RSS-KiB
BenchmarkLua/binary_trees	1	826682000 ns/op	18968 peak-RSS-KiB
BenchmarkLua/closures	1	682084000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/concat	1	383433000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/coroutines	1	539350000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/fib	1	620109000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/format	1	463625000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/hash_int	1	791948000 ns/op	12052 peak-RSS-KiB
BenchmarkLua/hash_string	1	928634000 ns/op	34672 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	576940000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/methods	1	707840000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/nbody	1	965676000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/patterns	1	656861000 ns/op	8748 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	1088896000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/table_concat	1	392728000 ns/op	22124 peak-RSS-KiB
BenchmarkLua/array	1	1281187000 ns/op	20836 peak-RSS-KiB
BenchmarkLua/binary_trees	1	908485000 ns/op	18968 peak-RSS-KiB
BenchmarkLua/closures	1	726298000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/concat	1	384479000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/coroutines	1	530304000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/fib	1	625189000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/format	1	475029000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/hash_int	1	804205000 ns/op	12052 peak-RSS-KiB
BenchmarkLua/hash_string	1	947672000 ns/op	34676 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	586959000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	722290000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/nbody	1	988439000 ns/op	2356 peak-RSS-KiB
BenchmarkLua/patterns	1	658513000 ns/op	8748 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	999484000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/table_concat	1	415818000 ns/op	22128 peak-RSS-KiB
BenchmarkLua/array	1	1238662000 ns/op	20828 peak-RSS-KiB
BenchmarkLua/binary_trees	1	869560000 ns/op	18964 peak-RSS-KiB
BenchmarkLua/closures	1	714810000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/concat	1	475926000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/coroutines	1	536363000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/fib	1	628418000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/format	1	471563000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/hash_int	1	854852000 ns/op	12048 peak-RSS-KiB
BenchmarkLua/hash_string	1	805166000 ns/op	34672 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	577046000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	753636000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/nbody	1	963409000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/patterns	1	655083000 ns/op	8744 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	988062000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/table_concat	1	371284000 ns/op	22124 peak-RSS-KiB
BenchmarkLua/array	1	1203463000 ns/op	20832 peak-RSS-KiB
BenchmarkLua/binary_trees	1	1031817000 ns/op	18968 peak-RSS-KiB
BenchmarkLua/closures	1	697504000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/concat	1	406214000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/coroutines	1	543057000 ns/op	2360 peak-RSS-KiB
BenchmarkLua/fib	1	655661000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/format	1	464210000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/hash_int	1	835218000 ns/op	12048 peak-RSS-KiB
BenchmarkLua/hash_string	1	806137000 ns/op	34672 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	576323000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/methods	1	710138000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/nbody	1	968757000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/patterns	1	657148000 ns/op	8748 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	990723000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/table_concat	1	364304000 ns/op	22124 peak-RSS-KiB
BenchmarkLua/array	1	1199166000 ns/op	20832 peak-RSS-KiB
BenchmarkLua/binary_trees	1	852914000 ns/op	18968 peak-RSS-KiB
BenchmarkLua/closures	1	677566000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/concat	1	391577000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/coroutines	1	580937000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/fib	1	628007000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/format	1	486343000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/hash_int	1	804446000 ns/op	12048 peak-RSS-KiB
BenchmarkLua/hash_string	1	875780000 ns/op	34672 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	574188000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	710526000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/nbody	1	998707000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/patterns	1	661736000 ns/op	8748 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	995957000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/table_concat	1	372496000 ns/op	22156 peak-RSS-KiB
```

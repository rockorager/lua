# Native calls from the interpreter loop, 2026-10-30

array is the program whose time goes to native calls: its `ipairs` loop
calls `ipairsAux` once per element through `TFORCALL`. Its profile on
c5b115f (`perf record -e cpu-clock`, ReleaseFast):

```
    41.57%  vm.runLoop
    15.99%  vm.callNative
    15.73%  Table.get
    11.85%  lib.base.ipairsAux
     3.26%  lib.base.checkInteger
     3.22%  Table.length
     3.13%  vm.preCall
     2.41%  array_list.Aligned(Thread.Frame,null).ensureTotalCapacity
```

Three costs in that list are call plumbing, not work: `preCall`, which
only switches on the callee's tag before calling `callNative`; the frame
push, where `ArrayList.append` called `ensureTotalCapacity` out of line
on every call; and `Table.get`, the generic lookup behind `vm.get`
(`lua_geti` from native code), which switches on the key's tag in a
function of its own.

## The change

- `CALL` and `TFORCALL` call `callNative` directly for a
  `native_fn` callee, as `CALL` already pushed Lua frames itself.
  Other callees still go through `preCall`.
- `callNative` pushes its frame the way `pushLuaFrame` does: a
  capacity check inline, growth out of line, `appendAssumeCapacity`.
- `vm.get` looks an integer key up with the inline `Table.getInt`.

After it, array's profile has no `preCall`, `ensureTotalCapacity`, or
`Table.get`:

```
    48.69%  vm.runLoop
    22.91%  lib.base.ipairsAux
    17.68%  vm.callNative
     3.65%  Table.length
     3.60%  lib.base.checkInteger
```

Base is c5b115f; new is this change. ReleaseFast, 10 rounds of every
`bench/` program, interleaved, pinned to the last core, wall time and
peak RSS per process, benchstat.

## Results

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
                  │     base     │                 new                 │
                  │    sec/op    │    sec/op     vs base               │
Lua/array           979.0m ±  2%   901.4m ±  5%  -7.93% (p=0.000 n=10)
Lua/binary_trees    884.2m ± 20%   887.2m ± 25%       ~ (p=0.912 n=10)
Lua/closures        636.7m ±  7%   629.8m ± 17%       ~ (p=0.631 n=10)
Lua/concat          379.0m ±  7%   373.1m ±  4%       ~ (p=0.218 n=10)
Lua/coroutines      520.9m ±  3%   473.2m ±  3%  -9.15% (p=0.001 n=10)
Lua/fib             629.9m ±  1%   617.9m ±  1%  -1.91% (p=0.001 n=10)
Lua/format          467.3m ±  3%   477.5m ±  5%       ~ (p=0.089 n=10)
Lua/hash_int        484.3m ±  3%   479.0m ±  3%       ~ (p=0.315 n=10)
Lua/hash_string     584.1m ± 11%   578.1m ± 13%       ~ (p=0.971 n=10)
Lua/mandelbrot      578.4m ±  1%   569.3m ±  3%       ~ (p=0.105 n=10)
Lua/methods         695.4m ±  6%   689.5m ±  8%       ~ (p=0.436 n=10)
Lua/nbody           821.1m ±  4%   818.5m ±  6%       ~ (p=0.796 n=10)
Lua/patterns        662.4m ± 11%   645.3m ± 23%       ~ (p=0.796 n=10)
Lua/spectral_norm   855.1m ±  4%   847.8m ±  6%       ~ (p=0.579 n=10)
Lua/table_concat    347.2m ±  2%   348.5m ± 11%       ~ (p=0.481 n=10)
geomean             609.0m         597.8m        -1.84%

                  │     base     │                 new                 │
                  │ peak-RSS-KiB │ peak-RSS-KiB  vs base               │
Lua/array            20.78k ± 0%    20.79k ± 0%  +0.04% (p=0.000 n=10)
Lua/binary_trees     18.92k ± 0%    18.92k ± 0%  +0.02% (p=0.000 n=10)
Lua/closures         2.374k ± 0%    2.372k ± 0%       ~ (p=0.262 n=10)
Lua/concat           2.372k ± 0%    2.372k ± 0%       ~ (p=0.191 n=10)
Lua/coroutines       2.372k ± 0%    2.372k ± 0%       ~ (p=0.871 n=10)
Lua/fib              2.374k ± 0%    2.372k ± 0%       ~ (p=0.450 n=10)
Lua/format           2.372k ± 1%    2.372k ± 0%       ~ (p=0.545 n=10)
Lua/hash_int         12.00k ± 0%    12.01k ± 0%  +0.07% (p=0.000 n=10)
Lua/hash_string      34.62k ± 0%    34.63k ± 0%  +0.01% (p=0.000 n=10)
Lua/mandelbrot       2.370k ± 0%    2.372k ± 0%  +0.08% (p=0.024 n=10)
Lua/methods          2.372k ± 0%    2.370k ± 0%       ~ (p=0.559 n=10)
Lua/nbody            2.372k ± 0%    2.372k ± 0%       ~ (p=0.779 n=10)
Lua/patterns         8.692k ± 0%    8.700k ± 0%  +0.09% (p=0.000 n=10)
Lua/spectral_norm    2.372k ± 0%    2.374k ± 0%       ~ (p=0.237 n=10)
Lua/table_concat     22.07k ± 0%    22.08k ± 0%  +0.04% (p=0.000 n=10)
geomean              5.307k         5.307k       +0.01%
```

## Reading it

- array −8%, coroutines −9% (`coroutine.resume` and `wrap` are native
  calls), fib −2%. Nothing is slower.
- Peak RSS moves by at most 8 KiB (+0.09%), the size of the binary's
  extra code; no program allocates differently.

## Rejected: integer stores by pointer

`SETTABLE` copies its value operand to a stack temporary before the
integer store, because the out-of-line `Table.setIntHash` takes a
`Value`, which Zig passes by reference. A `setIntAt` that stores the
array part inline and passes the value by pointer to the hash path (the
`setShortStrAt` pattern) made array 4% faster in single runs, but not in
the A/B against this change (base is this change, new adds `setIntAt`),
so it is not in:

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
                  │     base     │                 new                 │
                  │    sec/op    │    sec/op     vs base               │
Lua/array           895.8m ±  4%   902.9m ±  4%       ~ (p=0.971 n=10)
Lua/binary_trees    867.3m ± 11%   860.4m ± 11%       ~ (p=0.853 n=10)
Lua/closures        635.1m ±  6%   637.6m ±  6%       ~ (p=1.000 n=10)
Lua/concat          369.8m ±  5%   367.4m ±  3%       ~ (p=0.315 n=10)
Lua/coroutines      470.9m ±  2%   468.2m ±  5%       ~ (p=0.529 n=10)
Lua/fib             621.6m ±  7%   620.8m ±  4%       ~ (p=0.684 n=10)
Lua/format          466.3m ±  6%   456.2m ±  2%  -2.16% (p=0.011 n=10)
Lua/hash_int        475.6m ±  6%   471.5m ± 15%       ~ (p=0.853 n=10)
Lua/hash_string     548.1m ± 21%   560.4m ± 10%       ~ (p=0.529 n=10)
Lua/mandelbrot      568.1m ±  1%   566.0m ±  2%       ~ (p=0.289 n=10)
Lua/methods         696.7m ±  6%   696.8m ±  6%       ~ (p=0.579 n=10)
Lua/nbody           845.2m ± 11%   834.9m ±  5%       ~ (p=0.165 n=10)
Lua/patterns        641.4m ±  5%   646.0m ±  5%       ~ (p=0.796 n=10)
Lua/spectral_norm   853.4m ±  5%   848.9m ± 10%       ~ (p=0.436 n=10)
Lua/table_concat    347.8m ±  3%   339.5m ±  4%       ~ (p=0.143 n=10)
geomean             594.9m         592.7m        -0.37%
```

## Raw output

base:

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
BenchmarkLua/array	1	990039000 ns/op	20780 peak-RSS-KiB
BenchmarkLua/binary_trees	1	801387000 ns/op	18916 peak-RSS-KiB
BenchmarkLua/closures	1	631740000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/concat	1	373103000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/coroutines	1	513073000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/fib	1	636402000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/format	1	459635000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/hash_int	1	484277000 ns/op	11996 peak-RSS-KiB
BenchmarkLua/hash_string	1	498600000 ns/op	34624 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	569732000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	704003000 ns/op	2364 peak-RSS-KiB
BenchmarkLua/nbody	1	797502000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/patterns	1	746339000 ns/op	8692 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	883769000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/table_concat	1	347270000 ns/op	22072 peak-RSS-KiB
BenchmarkLua/array	1	954858000 ns/op	20780 peak-RSS-KiB
BenchmarkLua/binary_trees	1	837535000 ns/op	18912 peak-RSS-KiB
BenchmarkLua/closures	1	627894000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/concat	1	381209000 ns/op	2364 peak-RSS-KiB
BenchmarkLua/coroutines	1	524812000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/fib	1	623490000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/format	1	461022000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/hash_int	1	494502000 ns/op	11996 peak-RSS-KiB
BenchmarkLua/hash_string	1	555934000 ns/op	34620 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	570916000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/methods	1	734193000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/nbody	1	804925000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/patterns	1	677266000 ns/op	8696 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	868735000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/table_concat	1	396924000 ns/op	22072 peak-RSS-KiB
BenchmarkLua/array	1	980226000 ns/op	20784 peak-RSS-KiB
BenchmarkLua/binary_trees	1	851904000 ns/op	18916 peak-RSS-KiB
BenchmarkLua/closures	1	656484000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/concat	1	391523000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/coroutines	1	511815000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/fib	1	628534000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/format	1	478001000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/hash_int	1	478145000 ns/op	12000 peak-RSS-KiB
BenchmarkLua/hash_string	1	627354000 ns/op	34620 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	577656000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	705185000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/nbody	1	850838000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/patterns	1	644886000 ns/op	8692 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	891383000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/table_concat	1	347145000 ns/op	22072 peak-RSS-KiB
BenchmarkLua/array	1	977828000 ns/op	20784 peak-RSS-KiB
BenchmarkLua/binary_trees	1	900994000 ns/op	18916 peak-RSS-KiB
BenchmarkLua/closures	1	627187000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/concat	1	371630000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/coroutines	1	518078000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/fib	1	635989000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/format	1	525311000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/hash_int	1	497576000 ns/op	11996 peak-RSS-KiB
BenchmarkLua/hash_string	1	600318000 ns/op	34624 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	579279000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/methods	1	684176000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/nbody	1	809273000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/patterns	1	636257000 ns/op	8696 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	829498000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/table_concat	1	342340000 ns/op	22072 peak-RSS-KiB
BenchmarkLua/array	1	992378000 ns/op	20780 peak-RSS-KiB
BenchmarkLua/binary_trees	1	867437000 ns/op	18912 peak-RSS-KiB
BenchmarkLua/closures	1	624386000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/concat	1	371958000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/coroutines	1	523703000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/fib	1	625408000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/format	1	464800000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/hash_int	1	457638000 ns/op	12000 peak-RSS-KiB
BenchmarkLua/hash_string	1	520308000 ns/op	34624 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	583464000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/methods	1	686843000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/nbody	1	873289000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/patterns	1	642059000 ns/op	8692 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	827627000 ns/op	2364 peak-RSS-KiB
BenchmarkLua/table_concat	1	344289000 ns/op	22076 peak-RSS-KiB
BenchmarkLua/array	1	997844000 ns/op	20780 peak-RSS-KiB
BenchmarkLua/binary_trees	1	1057088000 ns/op	18912 peak-RSS-KiB
BenchmarkLua/closures	1	638537000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/concat	1	423225000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/coroutines	1	582112000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/fib	1	623105000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/format	1	461695000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/hash_int	1	474478000 ns/op	12000 peak-RSS-KiB
BenchmarkLua/hash_string	1	531755000 ns/op	34620 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	579216000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/methods	1	684764000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/nbody	1	828044000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/patterns	1	660834000 ns/op	8692 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	901545000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/table_concat	1	353791000 ns/op	22072 peak-RSS-KiB
BenchmarkLua/array	1	1119474000 ns/op	20780 peak-RSS-KiB
BenchmarkLua/binary_trees	1	949380000 ns/op	18916 peak-RSS-KiB
BenchmarkLua/closures	1	717570000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/concat	1	404156000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/coroutines	1	508342000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/fib	1	628165000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/format	1	469719000 ns/op	2356 peak-RSS-KiB
BenchmarkLua/hash_int	1	484254000 ns/op	12000 peak-RSS-KiB
BenchmarkLua/hash_string	1	599683000 ns/op	34624 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	571965000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	685111000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/nbody	1	814146000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/patterns	1	663884000 ns/op	8692 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	830339000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/table_concat	1	351689000 ns/op	22076 peak-RSS-KiB
BenchmarkLua/array	1	976457000 ns/op	20780 peak-RSS-KiB
BenchmarkLua/binary_trees	1	1113720000 ns/op	18916 peak-RSS-KiB
BenchmarkLua/closures	1	679260000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/concat	1	376773000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/coroutines	1	538842000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/fib	1	632706000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/format	1	472987000 ns/op	2356 peak-RSS-KiB
BenchmarkLua/hash_int	1	496240000 ns/op	11996 peak-RSS-KiB
BenchmarkLua/hash_string	1	631482000 ns/op	34624 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	573033000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	711662000 ns/op	2364 peak-RSS-KiB
BenchmarkLua/nbody	1	834577000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/patterns	1	672844000 ns/op	8696 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	851328000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/table_concat	1	348901000 ns/op	22072 peak-RSS-KiB
BenchmarkLua/array	1	975605000 ns/op	20784 peak-RSS-KiB
BenchmarkLua/binary_trees	1	928891000 ns/op	18912 peak-RSS-KiB
BenchmarkLua/closures	1	640016000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/concat	1	372496000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/coroutines	1	512445000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/fib	1	631328000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/format	1	460123000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/hash_int	1	480604000 ns/op	12000 peak-RSS-KiB
BenchmarkLua/hash_string	1	622607000 ns/op	34624 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	579087000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/methods	1	680007000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/nbody	1	812042000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/patterns	1	735910000 ns/op	8692 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	858846000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/table_concat	1	344210000 ns/op	22072 peak-RSS-KiB
BenchmarkLua/array	1	955526000 ns/op	20784 peak-RSS-KiB
BenchmarkLua/binary_trees	1	795818000 ns/op	18916 peak-RSS-KiB
BenchmarkLua/closures	1	634780000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/concat	1	381567000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/coroutines	1	523662000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/fib	1	642279000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/format	1	480495000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/hash_int	1	551039000 ns/op	11996 peak-RSS-KiB
BenchmarkLua/hash_string	1	568614000 ns/op	34624 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	635561000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	782895000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/nbody	1	856414000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/patterns	1	635238000 ns/op	8696 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	844019000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/table_concat	1	341514000 ns/op	22076 peak-RSS-KiB
```

new:

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
BenchmarkLua/array	1	889687000 ns/op	20788 peak-RSS-KiB
BenchmarkLua/binary_trees	1	786094000 ns/op	18920 peak-RSS-KiB
BenchmarkLua/closures	1	621004000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/concat	1	373852000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/coroutines	1	466615000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/fib	1	619235000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/format	1	480626000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/hash_int	1	467940000 ns/op	12008 peak-RSS-KiB
BenchmarkLua/hash_string	1	563011000 ns/op	34632 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	564579000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/methods	1	672252000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/nbody	1	854776000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/patterns	1	638723000 ns/op	8700 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	849793000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/table_concat	1	355288000 ns/op	22080 peak-RSS-KiB
BenchmarkLua/array	1	894871000 ns/op	20788 peak-RSS-KiB
BenchmarkLua/binary_trees	1	802148000 ns/op	18920 peak-RSS-KiB
BenchmarkLua/closures	1	626736000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/concat	1	372261000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/coroutines	1	477529000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/fib	1	631483000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/format	1	472334000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/hash_int	1	469549000 ns/op	12008 peak-RSS-KiB
BenchmarkLua/hash_string	1	575761000 ns/op	34628 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	566750000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/methods	1	752755000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/nbody	1	790360000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/patterns	1	828711000 ns/op	8700 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	883296000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/table_concat	1	386552000 ns/op	22084 peak-RSS-KiB
BenchmarkLua/array	1	919009000 ns/op	20788 peak-RSS-KiB
BenchmarkLua/binary_trees	1	851169000 ns/op	18924 peak-RSS-KiB
BenchmarkLua/closures	1	629395000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/concat	1	408994000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/coroutines	1	469561000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/fib	1	620330000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/format	1	474437000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/hash_int	1	481349000 ns/op	12004 peak-RSS-KiB
BenchmarkLua/hash_string	1	671956000 ns/op	34632 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	586048000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	667193000 ns/op	2364 peak-RSS-KiB
BenchmarkLua/nbody	1	810560000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/patterns	1	644451000 ns/op	8700 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	844721000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/table_concat	1	344433000 ns/op	22080 peak-RSS-KiB
BenchmarkLua/array	1	984575000 ns/op	20788 peak-RSS-KiB
BenchmarkLua/binary_trees	1	963304000 ns/op	18924 peak-RSS-KiB
BenchmarkLua/closures	1	630221000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/concat	1	365698000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/coroutines	1	476055000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/fib	1	624529000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/format	1	481474000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/hash_int	1	492348000 ns/op	12008 peak-RSS-KiB
BenchmarkLua/hash_string	1	599473000 ns/op	34632 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	573023000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	708201000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/nbody	1	785965000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/patterns	1	637825000 ns/op	8704 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	841188000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/table_concat	1	342473000 ns/op	22084 peak-RSS-KiB
BenchmarkLua/array	1	881625000 ns/op	20792 peak-RSS-KiB
BenchmarkLua/binary_trees	1	919711000 ns/op	18920 peak-RSS-KiB
BenchmarkLua/closures	1	627313000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/concat	1	367597000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/coroutines	1	471808000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/fib	1	615061000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/format	1	467161000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/hash_int	1	459497000 ns/op	12008 peak-RSS-KiB
BenchmarkLua/hash_string	1	534748000 ns/op	34628 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	573362000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	715276000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/nbody	1	807445000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/patterns	1	654503000 ns/op	8700 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	839738000 ns/op	2356 peak-RSS-KiB
BenchmarkLua/table_concat	1	398527000 ns/op	22080 peak-RSS-KiB
BenchmarkLua/array	1	881243000 ns/op	20788 peak-RSS-KiB
BenchmarkLua/binary_trees	1	1111012000 ns/op	18924 peak-RSS-KiB
BenchmarkLua/closures	1	739253000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/concat	1	388696000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/coroutines	1	485422000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/fib	1	615673000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/format	1	470744000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/hash_int	1	476607000 ns/op	12004 peak-RSS-KiB
BenchmarkLua/hash_string	1	507076000 ns/op	34628 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	694421000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/methods	1	698097000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/nbody	1	845011000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/patterns	1	638966000 ns/op	8700 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	907265000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/table_concat	1	349426000 ns/op	22080 peak-RSS-KiB
BenchmarkLua/array	1	907972000 ns/op	20792 peak-RSS-KiB
BenchmarkLua/binary_trees	1	1042126000 ns/op	18920 peak-RSS-KiB
BenchmarkLua/closures	1	737041000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/concat	1	381225000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/coroutines	1	472227000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/fib	1	617708000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/format	1	500533000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/hash_int	1	482348000 ns/op	12008 peak-RSS-KiB
BenchmarkLua/hash_string	1	553538000 ns/op	34628 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	565379000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/methods	1	672325000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/nbody	1	886202000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/patterns	1	638422000 ns/op	8700 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	901661000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/table_concat	1	354199000 ns/op	22080 peak-RSS-KiB
BenchmarkLua/array	1	943501000 ns/op	20792 peak-RSS-KiB
BenchmarkLua/binary_trees	1	1114515000 ns/op	18920 peak-RSS-KiB
BenchmarkLua/closures	1	647998000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/concat	1	380757000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/coroutines	1	474227000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/fib	1	615632000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/format	1	518498000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/hash_int	1	495161000 ns/op	12004 peak-RSS-KiB
BenchmarkLua/hash_string	1	651009000 ns/op	34628 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	571936000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/methods	1	680953000 ns/op	2364 peak-RSS-KiB
BenchmarkLua/nbody	1	805023000 ns/op	2364 peak-RSS-KiB
BenchmarkLua/patterns	1	676697000 ns/op	8704 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	902578000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/table_concat	1	347480000 ns/op	22080 peak-RSS-KiB
BenchmarkLua/array	1	916714000 ns/op	20792 peak-RSS-KiB
BenchmarkLua/binary_trees	1	854623000 ns/op	18920 peak-RSS-KiB
BenchmarkLua/closures	1	645216000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/concat	1	367971000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/coroutines	1	464521000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/fib	1	618031000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/format	1	464601000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/hash_int	1	465505000 ns/op	12004 peak-RSS-KiB
BenchmarkLua/hash_string	1	580463000 ns/op	34632 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	565095000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	671133000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/nbody	1	826416000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/patterns	1	646207000 ns/op	8704 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	845723000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/table_concat	1	345612000 ns/op	22080 peak-RSS-KiB
BenchmarkLua/array	1	883130000 ns/op	20788 peak-RSS-KiB
BenchmarkLua/binary_trees	1	804381000 ns/op	18920 peak-RSS-KiB
BenchmarkLua/closures	1	623443000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/concat	1	368855000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/coroutines	1	527928000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/fib	1	617516000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/format	1	487259000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/hash_int	1	498821000 ns/op	12004 peak-RSS-KiB
BenchmarkLua/hash_string	1	596903000 ns/op	34628 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	564898000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	743758000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/nbody	1	871022000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/patterns	1	791002000 ns/op	8704 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	840679000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/table_concat	1	339666000 ns/op	22080 peak-RSS-KiB
```

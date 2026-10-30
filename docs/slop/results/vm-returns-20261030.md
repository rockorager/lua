# Returns that know their caller's frame, 2026-10-30

`RETURN0` and `RETURN1` went through `doReturn`, which found the
returning frame with `th.frame()` (a load of the frame list's pointer and
length) although the loop holds it in `ci`, and the loop then called
`th.frame()` again for the caller's frame. Those loads sit on the chain
the caller's next instruction waits for: frame, then `func`, then the
closure, its prototype, and `k`. In fib's and spectral_norm's profiles
the return path and the frame reload after it were 6% of the loop's
samples.

## The change

- The unhooked loop's `RETURN0` and `RETURN1` call `popFrame` with `ci`,
  and take the caller's frame as the one below it in the frame array,
  without loading the array back. When the return finished an
  interrupted instruction (`finishOp`, which may push a frame), the loop
  still asks for the top frame and checks whether a hook was set.
- The hooked loop keeps `doReturn` as it was.

An alternative that also skipped `newframe` on `CALL` (setting `cl`, `k`,
`base`, and `pc` from the callee it already had) made fib 2.8% slower in
an 8-round A/B on six programs: `cl` and `k` became variables live across
the whole loop, and LLVM spilled them. It is not in.

Base is the rebased native-call change on 9f9fc62 (the collector merge);
new is this change. ReleaseFast, 10 rounds of every `bench/` program,
interleaved, pinned to the last core, wall time and peak RSS per process,
benchstat.

## Results

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
                  │     base     │                 new                 │
                  │    sec/op    │    sec/op     vs base               │
Lua/array           878.4m ±  2%   919.8m ±  6%  +4.71% (p=0.015 n=10)
Lua/binary_trees    772.6m ±  8%   771.5m ±  8%       ~ (p=0.436 n=10)
Lua/closures        670.7m ± 10%   670.8m ±  5%       ~ (p=0.353 n=10)
Lua/concat          367.4m ±  1%   368.3m ± 15%       ~ (p=0.912 n=10)
Lua/coroutines      498.6m ±  8%   493.0m ±  2%       ~ (p=0.165 n=10)
Lua/fib             598.7m ±  1%   539.9m ±  2%  -9.82% (p=0.000 n=10)
Lua/format          464.8m ±  5%   471.9m ±  3%       ~ (p=0.796 n=10)
Lua/hash_int        490.2m ±  8%   488.7m ±  8%       ~ (p=0.579 n=10)
Lua/hash_string     586.7m ± 31%   614.4m ± 24%       ~ (p=0.579 n=10)
Lua/mandelbrot      598.6m ±  7%   609.1m ±  9%       ~ (p=0.684 n=10)
Lua/methods         713.6m ±  8%   688.7m ± 16%       ~ (p=0.315 n=10)
Lua/nbody           843.7m ±  7%   843.2m ±  3%       ~ (p=0.631 n=10)
Lua/patterns        667.8m ±  7%   657.9m ±  5%       ~ (p=0.315 n=10)
Lua/spectral_norm   866.9m ±  6%   815.0m ±  4%  -5.99% (p=0.001 n=10)
Lua/table_concat    379.5m ±  8%   390.1m ±  5%       ~ (p=0.393 n=10)
geomean             604.7m         601.6m        -0.51%

                  │     base     │                 new                 │
                  │ peak-RSS-KiB │ peak-RSS-KiB  vs base               │
Lua/array            20.88k ± 0%    20.88k ± 0%       ~ (p=1.000 n=10)
Lua/binary_trees     27.37k ± 0%    27.37k ± 0%       ~ (p=1.000 n=10)
Lua/closures         2.380k ± 0%    2.382k ± 0%       ~ (p=0.598 n=10)
Lua/concat           2.380k ± 0%    2.382k ± 0%       ~ (p=0.423 n=10)
Lua/coroutines       2.376k ± 0%    2.382k ± 0%       ~ (p=0.057 n=10)
Lua/fib              2.380k ± 0%    2.382k ± 0%       ~ (p=0.233 n=10)
Lua/format           2.380k ± 0%    2.380k ± 0%       ~ (p=0.466 n=10)
Lua/hash_int         5.956k ± 0%    5.956k ± 0%       ~ (p=1.000 n=10)
Lua/hash_string      25.51k ± 0%    25.51k ± 0%       ~ (p=0.650 n=10)
Lua/mandelbrot       2.378k ± 0%    2.380k ± 0%       ~ (p=0.155 n=10)
Lua/methods          2.380k ± 0%    2.380k ± 0%       ~ (p=0.540 n=10)
Lua/nbody            2.380k ± 0%    2.380k ± 0%       ~ (p=0.731 n=10)
Lua/patterns         9.852k ± 0%    9.852k ± 0%       ~ (p=1.000 n=10)
Lua/spectral_norm    2.380k ± 0%    2.380k ± 0%       ~ (p=0.744 n=10)
Lua/table_concat     43.54k ± 0%    43.54k ± 0%       ~ (p=1.000 n=10)
geomean              5.378k         5.380k       +0.04%
```

## Reading it

- fib −10%, spectral_norm −6%: the programs whose time is Lua calls.
- array is 4.7% slower in this run (p=0.015) though the change does not
  touch any instruction array runs in its loops (its calls are native).
  The same change without the `hookSwitch` check on the `finished`
  path, an earlier draft whose code differs only in that cold branch,
  measured array unchanged (−1%, p=0.39) and fib −12%, spectral_norm
  −3.6%, binary_trees −5%, closures −3%, methods −2% against the same
  base. Both runs are below; array's difference is layout, not work.
- Peak RSS is unchanged.

The earlier draft's run (base is the same; new lacks the hook check):

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
                  │     base     │                 new                  │
                  │    sec/op    │    sec/op     vs base                │
Lua/array           902.4m ±  4%   891.5m ±  6%        ~ (p=0.393 n=10)
Lua/binary_trees    776.7m ±  5%   736.5m ±  1%   -5.18% (p=0.000 n=10)
Lua/closures        667.3m ±  3%   646.1m ±  6%   -3.18% (p=0.015 n=10)
Lua/concat          369.7m ±  2%   367.9m ±  2%        ~ (p=0.579 n=10)
Lua/coroutines      486.9m ±  6%   490.1m ±  4%        ~ (p=0.971 n=10)
Lua/fib             609.6m ±  3%   536.1m ±  2%  -12.06% (p=0.000 n=10)
Lua/format          460.5m ±  1%   455.4m ±  2%        ~ (p=0.280 n=10)
Lua/hash_int        467.0m ±  4%   464.4m ±  5%        ~ (p=0.739 n=10)
Lua/hash_string     638.0m ± 13%   633.1m ± 12%        ~ (p=0.853 n=10)
Lua/mandelbrot      589.3m ±  3%   595.1m ±  2%        ~ (p=0.579 n=10)
Lua/methods         695.4m ±  4%   679.9m ±  4%   -2.22% (p=0.015 n=10)
Lua/nbody           804.6m ±  8%   834.8m ±  7%        ~ (p=0.123 n=10)
Lua/patterns        648.6m ± 10%   646.8m ±  4%        ~ (p=0.529 n=10)
Lua/spectral_norm   835.2m ±  3%   805.6m ±  3%   -3.55% (p=0.004 n=10)
Lua/table_concat    379.1m ± 11%   379.8m ±  8%        ~ (p=0.971 n=10)
geomean             600.6m         590.2m         -1.73%

                  │     base     │                 new                 │
                  │ peak-RSS-KiB │ peak-RSS-KiB  vs base               │
Lua/array            20.88k ± 0%    20.88k ± 0%       ~ (p=0.628 n=10)
Lua/binary_trees     27.37k ± 0%    27.37k ± 0%       ~ (p=1.000 n=10)
Lua/closures         2.380k ± 0%    2.380k ± 0%       ~ (p=0.195 n=10)
Lua/concat           2.380k ± 0%    2.380k ± 0%       ~ (p=0.760 n=10)
Lua/coroutines       2.380k ± 0%    2.378k ± 0%       ~ (p=0.066 n=10)
Lua/fib              2.380k ± 0%    2.380k ± 0%       ~ (p=0.978 n=10)
Lua/format           2.380k ± 0%    2.382k ± 0%       ~ (p=1.000 n=10)
Lua/hash_int         5.956k ± 0%    5.956k ± 0%       ~ (p=1.000 n=10)
Lua/hash_string      25.51k ± 0%    25.51k ± 0%       ~ (p=1.000 n=10)
Lua/mandelbrot       2.380k ± 0%    2.380k ± 0%       ~ (p=0.779 n=10)
Lua/methods          2.382k ± 0%    2.380k ± 0%       ~ (p=0.446 n=10)
Lua/nbody            2.380k ± 0%    2.380k ± 0%       ~ (p=0.760 n=10)
Lua/patterns         9.856k ± 0%    9.852k ± 0%       ~ (p=0.656 n=10)
Lua/spectral_norm    2.380k ± 0%    2.380k ± 0%       ~ (p=1.000 n=10)
Lua/table_concat     43.54k ± 0%    43.54k ± 0%       ~ (p=0.141 n=10)
geomean              5.379k         5.379k       -0.01%
```

## Raw output

base:

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
BenchmarkLua/array	1	998752000 ns/op	20884 peak-RSS-KiB
BenchmarkLua/binary_trees	1	787006000 ns/op	27364 peak-RSS-KiB
BenchmarkLua/closures	1	666409000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/concat	1	359989000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/coroutines	1	546852000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/fib	1	603257000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/format	1	470259000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/hash_int	1	609916000 ns/op	5960 peak-RSS-KiB
BenchmarkLua/hash_string	1	507695000 ns/op	25512 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	588360000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/methods	1	690442000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/nbody	1	845421000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/patterns	1	665885000 ns/op	9852 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	854571000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/table_concat	1	364554000 ns/op	43536 peak-RSS-KiB
BenchmarkLua/array	1	866629000 ns/op	20884 peak-RSS-KiB
BenchmarkLua/binary_trees	1	833791000 ns/op	27368 peak-RSS-KiB
BenchmarkLua/closures	1	663641000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/concat	1	362242000 ns/op	2364 peak-RSS-KiB
BenchmarkLua/coroutines	1	494085000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/fib	1	598181000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/format	1	466166000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/hash_int	1	503377000 ns/op	5956 peak-RSS-KiB
BenchmarkLua/hash_string	1	813721000 ns/op	25508 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	590819000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/methods	1	718312000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/nbody	1	846929000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/patterns	1	680003000 ns/op	9852 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	873842000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/table_concat	1	410911000 ns/op	43540 peak-RSS-KiB
BenchmarkLua/array	1	885529000 ns/op	20888 peak-RSS-KiB
BenchmarkLua/binary_trees	1	760456000 ns/op	27364 peak-RSS-KiB
BenchmarkLua/closures	1	669924000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/concat	1	365458000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/coroutines	1	496160000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/fib	1	616481000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/format	1	462311000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/hash_int	1	505521000 ns/op	5956 peak-RSS-KiB
BenchmarkLua/hash_string	1	598839000 ns/op	25508 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	591174000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/methods	1	749011000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/nbody	1	858856000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/patterns	1	715778000 ns/op	9852 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	839102000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/table_concat	1	389764000 ns/op	43536 peak-RSS-KiB
BenchmarkLua/array	1	876769000 ns/op	20884 peak-RSS-KiB
BenchmarkLua/binary_trees	1	766203000 ns/op	27364 peak-RSS-KiB
BenchmarkLua/closures	1	711933000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/concat	1	365012000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/coroutines	1	491731000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/fib	1	594312000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/format	1	458525000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/hash_int	1	482406000 ns/op	5956 peak-RSS-KiB
BenchmarkLua/hash_string	1	660487000 ns/op	25508 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	611340000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	708891000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/nbody	1	841931000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/patterns	1	651948000 ns/op	9852 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	883322000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/table_concat	1	371526000 ns/op	43536 peak-RSS-KiB
BenchmarkLua/array	1	899057000 ns/op	20884 peak-RSS-KiB
BenchmarkLua/binary_trees	1	765409000 ns/op	27364 peak-RSS-KiB
BenchmarkLua/closures	1	671713000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/concat	1	364862000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/coroutines	1	504007000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/fib	1	593474000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/format	1	463521000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/hash_int	1	477569000 ns/op	5960 peak-RSS-KiB
BenchmarkLua/hash_string	1	547408000 ns/op	25508 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	599498000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/methods	1	698755000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/nbody	1	778955000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/patterns	1	711685000 ns/op	9852 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	859960000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/table_concat	1	378073000 ns/op	43536 peak-RSS-KiB
BenchmarkLua/array	1	880077000 ns/op	20888 peak-RSS-KiB
BenchmarkLua/binary_trees	1	810187000 ns/op	27368 peak-RSS-KiB
BenchmarkLua/closures	1	787380000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/concat	1	370810000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/coroutines	1	501132000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/fib	1	605486000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/format	1	485934000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/hash_int	1	530112000 ns/op	5960 peak-RSS-KiB
BenchmarkLua/hash_string	1	574558000 ns/op	25508 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	631944000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/methods	1	672559000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/nbody	1	927660000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/patterns	1	669803000 ns/op	9856 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	835851000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/table_concat	1	367902000 ns/op	43536 peak-RSS-KiB
BenchmarkLua/array	1	864434000 ns/op	20884 peak-RSS-KiB
BenchmarkLua/binary_trees	1	765733000 ns/op	27368 peak-RSS-KiB
BenchmarkLua/closures	1	671509000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/concat	1	369560000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/coroutines	1	476328000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/fib	1	589290000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/format	1	472256000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/hash_int	1	448666000 ns/op	5956 peak-RSS-KiB
BenchmarkLua/hash_string	1	615150000 ns/op	25508 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	597676000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/methods	1	724994000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/nbody	1	786116000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/patterns	1	649580000 ns/op	9852 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	832261000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/table_concat	1	373438000 ns/op	43536 peak-RSS-KiB
BenchmarkLua/array	1	872372000 ns/op	20884 peak-RSS-KiB
BenchmarkLua/binary_trees	1	748357000 ns/op	27368 peak-RSS-KiB
BenchmarkLua/closures	1	668589000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/concat	1	369378000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/coroutines	1	511512000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/fib	1	599306000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/format	1	452128000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/hash_int	1	493380000 ns/op	5956 peak-RSS-KiB
BenchmarkLua/hash_string	1	549385000 ns/op	25512 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	589038000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/methods	1	678317000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/nbody	1	814803000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/patterns	1	659496000 ns/op	9852 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	917789000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/table_concat	1	389216000 ns/op	43536 peak-RSS-KiB
BenchmarkLua/array	1	884329000 ns/op	20888 peak-RSS-KiB
BenchmarkLua/binary_trees	1	955079000 ns/op	27368 peak-RSS-KiB
BenchmarkLua/closures	1	737802000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/concat	1	371122000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/coroutines	1	539012000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/fib	1	599583000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/format	1	497531000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/hash_int	1	459569000 ns/op	5960 peak-RSS-KiB
BenchmarkLua/hash_string	1	472609000 ns/op	25512 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	643438000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/methods	1	767959000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/nbody	1	819386000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/patterns	1	705006000 ns/op	9856 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	883633000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/table_concat	1	411691000 ns/op	43540 peak-RSS-KiB
BenchmarkLua/array	1	868921000 ns/op	20884 peak-RSS-KiB
BenchmarkLua/binary_trees	1	779067000 ns/op	27368 peak-RSS-KiB
BenchmarkLua/closures	1	664986000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/concat	1	378754000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/coroutines	1	489094000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/fib	1	597679000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/format	1	461236000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/hash_int	1	487051000 ns/op	5956 peak-RSS-KiB
BenchmarkLua/hash_string	1	769308000 ns/op	25508 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	657691000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/methods	1	877126000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/nbody	1	885582000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/patterns	1	654548000 ns/op	9856 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	914757000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/table_concat	1	380913000 ns/op	43536 peak-RSS-KiB
```

new:

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
BenchmarkLua/array	1	921447000 ns/op	20884 peak-RSS-KiB
BenchmarkLua/binary_trees	1	830038000 ns/op	27368 peak-RSS-KiB
BenchmarkLua/closures	1	636510000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/concat	1	378067000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/coroutines	1	508755000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/fib	1	549054000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/format	1	471709000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/hash_int	1	502070000 ns/op	5956 peak-RSS-KiB
BenchmarkLua/hash_string	1	566913000 ns/op	25508 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	588205000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/methods	1	650665000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/nbody	1	818196000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/patterns	1	688447000 ns/op	9852 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	805833000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/table_concat	1	370964000 ns/op	43536 peak-RSS-KiB
BenchmarkLua/array	1	925841000 ns/op	20884 peak-RSS-KiB
BenchmarkLua/binary_trees	1	718678000 ns/op	27368 peak-RSS-KiB
BenchmarkLua/closures	1	676462000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/concat	1	368471000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/coroutines	1	498457000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/fib	1	542916000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/format	1	472108000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/hash_int	1	495299000 ns/op	5956 peak-RSS-KiB
BenchmarkLua/hash_string	1	768660000 ns/op	25508 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	600072000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/methods	1	801475000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/nbody	1	860067000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/patterns	1	642740000 ns/op	9852 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	802621000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/table_concat	1	413154000 ns/op	43536 peak-RSS-KiB
BenchmarkLua/array	1	937488000 ns/op	20884 peak-RSS-KiB
BenchmarkLua/binary_trees	1	796309000 ns/op	27368 peak-RSS-KiB
BenchmarkLua/closures	1	688722000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/concat	1	362526000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/coroutines	1	486985000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/fib	1	544785000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/format	1	483745000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/hash_int	1	490768000 ns/op	5960 peak-RSS-KiB
BenchmarkLua/hash_string	1	636643000 ns/op	25512 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	585239000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/methods	1	652804000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/nbody	1	839836000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/patterns	1	652205000 ns/op	9852 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	854212000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/table_concat	1	402746000 ns/op	43540 peak-RSS-KiB
BenchmarkLua/array	1	1059594000 ns/op	20888 peak-RSS-KiB
BenchmarkLua/binary_trees	1	734108000 ns/op	27364 peak-RSS-KiB
BenchmarkLua/closures	1	665149000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/concat	1	362093000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/coroutines	1	493486000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/fib	1	533780000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/format	1	457348000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/hash_int	1	486660000 ns/op	5956 peak-RSS-KiB
BenchmarkLua/hash_string	1	671512000 ns/op	25508 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	624253000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/methods	1	713754000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/nbody	1	846465000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/patterns	1	643197000 ns/op	9852 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	824470000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/table_concat	1	386299000 ns/op	43540 peak-RSS-KiB
BenchmarkLua/array	1	918204000 ns/op	20884 peak-RSS-KiB
BenchmarkLua/binary_trees	1	778722000 ns/op	27364 peak-RSS-KiB
BenchmarkLua/closures	1	653821000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/concat	1	430870000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/coroutines	1	479602000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/fib	1	531502000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/format	1	459014000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/hash_int	1	463378000 ns/op	5956 peak-RSS-KiB
BenchmarkLua/hash_string	1	568262000 ns/op	25512 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	589606000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/methods	1	684781000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/nbody	1	819712000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/patterns	1	674231000 ns/op	9852 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	843726000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/table_concat	1	381317000 ns/op	43536 peak-RSS-KiB
BenchmarkLua/array	1	909913000 ns/op	20884 peak-RSS-KiB
BenchmarkLua/binary_trees	1	764306000 ns/op	27364 peak-RSS-KiB
BenchmarkLua/closures	1	693794000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/concat	1	425011000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/coroutines	1	492491000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/fib	1	540405000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/format	1	532832000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/hash_int	1	518973000 ns/op	5956 peak-RSS-KiB
BenchmarkLua/hash_string	1	736875000 ns/op	25512 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	618114000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/methods	1	680989000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/nbody	1	863840000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/patterns	1	633573000 ns/op	9856 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	794717000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/table_concat	1	373461000 ns/op	43540 peak-RSS-KiB
BenchmarkLua/array	1	880862000 ns/op	20888 peak-RSS-KiB
BenchmarkLua/binary_trees	1	728623000 ns/op	27364 peak-RSS-KiB
BenchmarkLua/closures	1	637060000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/concat	1	358306000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/coroutines	1	494815000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/fib	1	536566000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/format	1	472674000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/hash_int	1	449081000 ns/op	5956 peak-RSS-KiB
BenchmarkLua/hash_string	1	592253000 ns/op	25512 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	598350000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/methods	1	656080000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/nbody	1	829255000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/patterns	1	714757000 ns/op	9856 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	812809000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/table_concat	1	371425000 ns/op	43536 peak-RSS-KiB
BenchmarkLua/array	1	871878000 ns/op	20884 peak-RSS-KiB
BenchmarkLua/binary_trees	1	721332000 ns/op	27364 peak-RSS-KiB
BenchmarkLua/closures	1	663546000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/concat	1	368210000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/coroutines	1	497656000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/fib	1	536205000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/format	1	455937000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/hash_int	1	443965000 ns/op	5956 peak-RSS-KiB
BenchmarkLua/hash_string	1	578266000 ns/op	25508 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	651601000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/methods	1	717525000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/nbody	1	857530000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/patterns	1	657326000 ns/op	9852 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	848579000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/table_concat	1	396624000 ns/op	43536 peak-RSS-KiB
BenchmarkLua/array	1	976572000 ns/op	20884 peak-RSS-KiB
BenchmarkLua/binary_trees	1	1076014000 ns/op	27368 peak-RSS-KiB
BenchmarkLua/closures	1	679250000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/concat	1	393093000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/coroutines	1	489052000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/fib	1	539481000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/format	1	481672000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/hash_int	1	466962000 ns/op	5960 peak-RSS-KiB
BenchmarkLua/hash_string	1	477775000 ns/op	25512 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	665246000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/methods	1	692693000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/nbody	1	826351000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/patterns	1	671390000 ns/op	9856 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	817204000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/table_concat	1	393911000 ns/op	43536 peak-RSS-KiB
BenchmarkLua/array	1	901502000 ns/op	20884 peak-RSS-KiB
BenchmarkLua/binary_trees	1	795488000 ns/op	27368 peak-RSS-KiB
BenchmarkLua/closures	1	678319000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/concat	1	359888000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/coroutines	1	481907000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/fib	1	557074000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/format	1	458553000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/hash_int	1	522692000 ns/op	5960 peak-RSS-KiB
BenchmarkLua/hash_string	1	761233000 ns/op	25508 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	670353000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/methods	1	910847000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/nbody	1	887265000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/patterns	1	658514000 ns/op	9852 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	808064000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/table_concat	1	404499000 ns/op	43536 peak-RSS-KiB
```

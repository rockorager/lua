# String buffers that become their strings, 2026-10-30

After the collector merge, table_concat was the one program besides
hash_string whose peak RSS was above the reference's: 43,536 KiB against
40,484. Taking its pieces apart (wall seconds and peak KiB, single runs):

```
                                   ref             ours
building the tables only           0.19 s 17440    0.16 s 11248
plus one table.concat(buf, ",")    0.55 s 37460    0.29 s 37524
```

Our tables are smaller; the concatenation costs more. `table.concat`
builds in an `auxlib.Buffer`, which doubled its heap block when full and
at the end copied the bytes into a new string, so a 4 MB result needed up
to 8 MB of buffer plus 4 MB of string at once. The reference's
`luaL_Buffer` grows by half and, in 5.5, turns its box into the result
string without a copy (`luaL_pushresult` makes an external string).

## The change

- `Buffer` keeps room for a `String` header in front of its heap block
  and a byte for the trailing zero after it.
- `toString` on a long result shrinks the block to the string's size and
  makes it the string in place (`String.adoptLong`); short results are
  still interned from the bytes.
- The block grows by half, as `luaL_Buffer` does, instead of doubling.

Every library function that builds in a `Buffer` gets this:
`table.concat`, `string.dump`, `gsub`, `format`, `string.pack`,
`utf8.char`, `os.date`, and `package`'s messages.

Base is the return change (cbc44e9); new is this change. ReleaseFast, 10
rounds of every `bench/` program, interleaved, pinned to the last core,
wall time and peak RSS per process, benchstat.

## Results

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
                  │    base     │                 new                 │
                  │   sec/op    │    sec/op     vs base               │
Lua/array           882.7m ± 1%   872.8m ±  2%       ~ (p=0.052 n=10)
Lua/binary_trees    722.8m ± 5%   726.9m ± 11%       ~ (p=0.739 n=10)
Lua/closures        661.8m ± 7%   648.4m ±  6%       ~ (p=0.165 n=10)
Lua/concat          369.1m ± 3%   360.5m ±  6%       ~ (p=0.165 n=10)
Lua/coroutines      488.1m ± 2%   491.7m ±  2%       ~ (p=0.123 n=10)
Lua/fib             535.5m ± 2%   533.1m ±  1%       ~ (p=0.853 n=10)
Lua/format          455.4m ± 3%   451.6m ±  5%       ~ (p=0.123 n=10)
Lua/hash_int        452.2m ± 2%   462.1m ± 10%       ~ (p=0.190 n=10)
Lua/hash_string     528.6m ± 6%   510.0m ± 13%       ~ (p=0.481 n=10)
Lua/mandelbrot      583.3m ± 4%   584.4m ±  4%       ~ (p=0.315 n=10)
Lua/methods         668.2m ± 3%   654.9m ±  7%       ~ (p=0.315 n=10)
Lua/nbody           848.8m ± 9%   857.4m ± 11%       ~ (p=0.481 n=10)
Lua/patterns        648.8m ± 3%   641.2m ±  3%       ~ (p=0.315 n=10)
Lua/spectral_norm   831.1m ± 3%   803.9m ±  4%       ~ (p=0.089 n=10)
Lua/table_concat    377.4m ± 4%   361.8m ± 13%       ~ (p=0.143 n=10)
geomean             582.1m        575.7m        -1.09%

                  │     base     │                 new                  │
                  │ peak-RSS-KiB │ peak-RSS-KiB  vs base                │
Lua/array            20.88k ± 0%    20.89k ± 0%   +0.02% (p=0.000 n=10)
Lua/binary_trees     27.37k ± 0%    27.37k ± 0%    0.00% (p=0.010 n=10)
Lua/closures         2.380k ± 0%    2.380k ± 0%        ~ (p=0.236 n=10)
Lua/concat           2.380k ± 0%    2.380k ± 0%        ~ (p=0.758 n=10)
Lua/coroutines       2.380k ± 0%    2.380k ± 0%        ~ (p=0.854 n=10)
Lua/fib              2.380k ± 0%    2.380k ± 0%        ~ (p=0.697 n=10)
Lua/format           2.380k ± 0%    2.380k ± 0%        ~ (p=1.000 n=10)
Lua/hash_int         5.960k ± 0%    5.960k ± 0%    0.00% (p=0.010 n=10)
Lua/hash_string      25.51k ± 0%    25.51k ± 0%    0.00% (p=0.033 n=10)
Lua/mandelbrot       2.378k ± 0%    2.380k ± 0%        ~ (p=0.874 n=10)
Lua/methods          2.378k ± 0%    2.380k ± 0%        ~ (p=0.157 n=10)
Lua/nbody            2.380k ± 0%    2.380k ± 0%        ~ (p=0.706 n=10)
Lua/patterns         9.854k ± 0%    9.388k ± 0%   -4.73% (p=0.000 n=10)
Lua/spectral_norm    2.380k ± 0%    2.380k ± 0%        ~ (p=0.509 n=10)
Lua/table_concat     43.54k ± 0%    23.04k ± 0%  -47.09% (p=0.000 n=10)
geomean              5.379k         5.139k        -4.45%
```

## Reading it

- table_concat's peak RSS halves (−47%), from above the reference's to
  57% of it; patterns, whose `gsub` results are long, drops 4.7%.
- No program is slower; table_concat and spectral_norm lean faster but
  within noise.

## Raw output

base:

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
BenchmarkLua/array	1	880096000 ns/op	20884 peak-RSS-KiB
BenchmarkLua/binary_trees	1	719050000 ns/op	27364 peak-RSS-KiB
BenchmarkLua/closures	1	666607000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/concat	1	364625000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/coroutines	1	490036000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/fib	1	532166000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/format	1	457889000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/hash_int	1	442601000 ns/op	5960 peak-RSS-KiB
BenchmarkLua/hash_string	1	496616000 ns/op	25512 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	580744000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/methods	1	659042000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/nbody	1	824182000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/patterns	1	653837000 ns/op	9852 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	840340000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/table_concat	1	377519000 ns/op	43540 peak-RSS-KiB
BenchmarkLua/array	1	879782000 ns/op	20888 peak-RSS-KiB
BenchmarkLua/binary_trees	1	717902000 ns/op	27368 peak-RSS-KiB
BenchmarkLua/closures	1	688849000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/concat	1	373977000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/coroutines	1	481963000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/fib	1	529355000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/format	1	456736000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/hash_int	1	449253000 ns/op	5956 peak-RSS-KiB
BenchmarkLua/hash_string	1	588807000 ns/op	25512 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	585950000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/methods	1	658100000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/nbody	1	807017000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/patterns	1	645939000 ns/op	9856 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	842513000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/table_concat	1	374774000 ns/op	43536 peak-RSS-KiB
BenchmarkLua/array	1	874872000 ns/op	20884 peak-RSS-KiB
BenchmarkLua/binary_trees	1	783034000 ns/op	27364 peak-RSS-KiB
BenchmarkLua/closures	1	732027000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/concat	1	360567000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/coroutines	1	479552000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/fib	1	530101000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/format	1	468032000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/hash_int	1	462102000 ns/op	5956 peak-RSS-KiB
BenchmarkLua/hash_string	1	529328000 ns/op	25508 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	584264000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/methods	1	672936000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/nbody	1	873620000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/patterns	1	632864000 ns/op	9856 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	792457000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/table_concat	1	375700000 ns/op	43536 peak-RSS-KiB
BenchmarkLua/array	1	985557000 ns/op	20884 peak-RSS-KiB
BenchmarkLua/binary_trees	1	761567000 ns/op	27364 peak-RSS-KiB
BenchmarkLua/closures	1	675078000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/concat	1	378529000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/coroutines	1	486997000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/fib	1	543855000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/format	1	462003000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/hash_int	1	440909000 ns/op	5960 peak-RSS-KiB
BenchmarkLua/hash_string	1	495181000 ns/op	25512 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	581337000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/methods	1	672850000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/nbody	1	928232000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/patterns	1	650896000 ns/op	9852 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	815440000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/table_concat	1	377360000 ns/op	43540 peak-RSS-KiB
BenchmarkLua/array	1	883023000 ns/op	20884 peak-RSS-KiB
BenchmarkLua/binary_trees	1	700472000 ns/op	27364 peak-RSS-KiB
BenchmarkLua/closures	1	642241000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/concat	1	362550000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/coroutines	1	492851000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/fib	1	535834000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/format	1	454098000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/hash_int	1	459070000 ns/op	5960 peak-RSS-KiB
BenchmarkLua/hash_string	1	490099000 ns/op	25512 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	580541000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/methods	1	663645000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/nbody	1	784237000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/patterns	1	635603000 ns/op	9852 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	886151000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/table_concat	1	379583000 ns/op	43536 peak-RSS-KiB
BenchmarkLua/array	1	889363000 ns/op	20884 peak-RSS-KiB
BenchmarkLua/binary_trees	1	745782000 ns/op	27368 peak-RSS-KiB
BenchmarkLua/closures	1	653198000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/concat	1	369384000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/coroutines	1	489136000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/fib	1	536221000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/format	1	451378000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/hash_int	1	460916000 ns/op	5960 peak-RSS-KiB
BenchmarkLua/hash_string	1	545859000 ns/op	25512 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	590375000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/methods	1	707776000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/nbody	1	801312000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/patterns	1	670855000 ns/op	9856 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	848685000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/table_concat	1	426657000 ns/op	43540 peak-RSS-KiB
BenchmarkLua/array	1	882474000 ns/op	20884 peak-RSS-KiB
BenchmarkLua/binary_trees	1	721738000 ns/op	27368 peak-RSS-KiB
BenchmarkLua/closures	1	709892000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/concat	1	405862000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/coroutines	1	490114000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/fib	1	531386000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/format	1	454122000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/hash_int	1	449616000 ns/op	5956 peak-RSS-KiB
BenchmarkLua/hash_string	1	536350000 ns/op	25508 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	582379000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/methods	1	661961000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/nbody	1	902055000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/patterns	1	646739000 ns/op	9852 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	803816000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/table_concat	1	393093000 ns/op	43540 peak-RSS-KiB
BenchmarkLua/array	1	894277000 ns/op	20884 peak-RSS-KiB
BenchmarkLua/binary_trees	1	755971000 ns/op	27368 peak-RSS-KiB
BenchmarkLua/closures	1	656894000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/concat	1	375507000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/coroutines	1	504959000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/fib	1	539958000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/format	1	476550000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/hash_int	1	537519000 ns/op	5960 peak-RSS-KiB
BenchmarkLua/hash_string	1	544379000 ns/op	25512 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	604185000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/methods	1	688903000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/nbody	1	981879000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/patterns	1	680972000 ns/op	9856 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	848195000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/table_concat	1	366303000 ns/op	43540 peak-RSS-KiB
BenchmarkLua/array	1	882196000 ns/op	20884 peak-RSS-KiB
BenchmarkLua/binary_trees	1	718250000 ns/op	27368 peak-RSS-KiB
BenchmarkLua/closures	1	651028000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/concat	1	354338000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/coroutines	1	477984000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/fib	1	593329000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/format	1	452891000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/hash_int	1	454549000 ns/op	5960 peak-RSS-KiB
BenchmarkLua/hash_string	1	527949000 ns/op	25512 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	605819000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/methods	1	678788000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/nbody	1	847327000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/patterns	1	650923000 ns/op	9852 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	821841000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/table_concat	1	378737000 ns/op	43540 peak-RSS-KiB
BenchmarkLua/array	1	892475000 ns/op	20888 peak-RSS-KiB
BenchmarkLua/binary_trees	1	723776000 ns/op	27368 peak-RSS-KiB
BenchmarkLua/closures	1	645535000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/concat	1	368780000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/coroutines	1	478079000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/fib	1	535070000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/format	1	453426000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/hash_int	1	449843000 ns/op	5956 peak-RSS-KiB
BenchmarkLua/hash_string	1	516134000 ns/op	25512 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	580554000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/methods	1	643386000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/nbody	1	850282000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/patterns	1	635471000 ns/op	9856 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	805812000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/table_concat	1	362691000 ns/op	43536 peak-RSS-KiB
```

new:

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
BenchmarkLua/array	1	861013000 ns/op	20892 peak-RSS-KiB
BenchmarkLua/binary_trees	1	809941000 ns/op	27372 peak-RSS-KiB
BenchmarkLua/closures	1	642023000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/concat	1	360282000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/coroutines	1	497708000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/fib	1	533190000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/format	1	454705000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/hash_int	1	444645000 ns/op	5960 peak-RSS-KiB
BenchmarkLua/hash_string	1	585289000 ns/op	25512 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	581939000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/methods	1	701383000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/nbody	1	951847000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/patterns	1	634321000 ns/op	9388 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	800712000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/table_concat	1	356067000 ns/op	23036 peak-RSS-KiB
BenchmarkLua/array	1	871255000 ns/op	20888 peak-RSS-KiB
BenchmarkLua/binary_trees	1	697448000 ns/op	27368 peak-RSS-KiB
BenchmarkLua/closures	1	638708000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/concat	1	355802000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/coroutines	1	483961000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/fib	1	528017000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/format	1	449614000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/hash_int	1	450604000 ns/op	5964 peak-RSS-KiB
BenchmarkLua/hash_string	1	500922000 ns/op	25512 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	668382000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/methods	1	652181000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/nbody	1	846775000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/patterns	1	640990000 ns/op	9384 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	804485000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/table_concat	1	356550000 ns/op	23036 peak-RSS-KiB
BenchmarkLua/array	1	849254000 ns/op	20892 peak-RSS-KiB
BenchmarkLua/binary_trees	1	804254000 ns/op	27368 peak-RSS-KiB
BenchmarkLua/closures	1	689775000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/concat	1	353508000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/coroutines	1	484734000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/fib	1	532958000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/format	1	450194000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/hash_int	1	462849000 ns/op	5960 peak-RSS-KiB
BenchmarkLua/hash_string	1	506549000 ns/op	25512 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	586625000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/methods	1	648424000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/nbody	1	835026000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/patterns	1	623602000 ns/op	9384 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	836834000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/table_concat	1	346795000 ns/op	23040 peak-RSS-KiB
BenchmarkLua/array	1	880456000 ns/op	20888 peak-RSS-KiB
BenchmarkLua/binary_trees	1	734082000 ns/op	27368 peak-RSS-KiB
BenchmarkLua/closures	1	682117000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/concat	1	365084000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/coroutines	1	489648000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/fib	1	539754000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/format	1	476185000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/hash_int	1	466147000 ns/op	5964 peak-RSS-KiB
BenchmarkLua/hash_string	1	513395000 ns/op	25516 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	582474000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/methods	1	648507000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/nbody	1	831014000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/patterns	1	641474000 ns/op	9384 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	803219000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/table_concat	1	369463000 ns/op	23036 peak-RSS-KiB
BenchmarkLua/array	1	913216000 ns/op	20888 peak-RSS-KiB
BenchmarkLua/binary_trees	1	720054000 ns/op	27372 peak-RSS-KiB
BenchmarkLua/closures	1	687500000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/concat	1	358191000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/coroutines	1	491138000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/fib	1	537238000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/format	1	452568000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/hash_int	1	455459000 ns/op	5964 peak-RSS-KiB
BenchmarkLua/hash_string	1	481864000 ns/op	25512 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	581629000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/methods	1	645204000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/nbody	1	817066000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/patterns	1	625762000 ns/op	9388 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	799929000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/table_concat	1	350972000 ns/op	23040 peak-RSS-KiB
BenchmarkLua/array	1	853691000 ns/op	20892 peak-RSS-KiB
BenchmarkLua/binary_trees	1	727926000 ns/op	27368 peak-RSS-KiB
BenchmarkLua/closures	1	657547000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/concat	1	366317000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/coroutines	1	506548000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/fib	1	532950000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/format	1	448488000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/hash_int	1	461251000 ns/op	5964 peak-RSS-KiB
BenchmarkLua/hash_string	1	544899000 ns/op	25516 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	596041000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	657573000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/nbody	1	893345000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/patterns	1	652612000 ns/op	9388 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	823622000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/table_concat	1	388673000 ns/op	23036 peak-RSS-KiB
BenchmarkLua/array	1	874269000 ns/op	20888 peak-RSS-KiB
BenchmarkLua/binary_trees	1	725817000 ns/op	27368 peak-RSS-KiB
BenchmarkLua/closures	1	648837000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/concat	1	386899000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/coroutines	1	497427000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/fib	1	530033000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/format	1	450634000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/hash_int	1	507400000 ns/op	5960 peak-RSS-KiB
BenchmarkLua/hash_string	1	478460000 ns/op	25512 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	583608000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/methods	1	647790000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/nbody	1	863481000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/patterns	1	633316000 ns/op	9388 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	816816000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/table_concat	1	367112000 ns/op	23036 peak-RSS-KiB
BenchmarkLua/array	1	888217000 ns/op	20888 peak-RSS-KiB
BenchmarkLua/binary_trees	1	711222000 ns/op	27372 peak-RSS-KiB
BenchmarkLua/closures	1	647869000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/concat	1	381250000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/coroutines	1	482238000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/fib	1	540551000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/format	1	473050000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/hash_int	1	508671000 ns/op	5960 peak-RSS-KiB
BenchmarkLua/hash_string	1	575853000 ns/op	25512 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	608215000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/methods	1	714492000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/nbody	1	902351000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/patterns	1	768413000 ns/op	9388 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	799450000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/table_concat	1	409897000 ns/op	23036 peak-RSS-KiB
BenchmarkLua/array	1	853006000 ns/op	20892 peak-RSS-KiB
BenchmarkLua/binary_trees	1	723969000 ns/op	27372 peak-RSS-KiB
BenchmarkLua/closures	1	630970000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/concat	1	353599000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/coroutines	1	498419000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/fib	1	570475000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/format	1	448868000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/hash_int	1	494929000 ns/op	5960 peak-RSS-KiB
BenchmarkLua/hash_string	1	516409000 ns/op	25516 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	585251000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/methods	1	679839000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/nbody	1	965237000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/patterns	1	662727000 ns/op	9388 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	846855000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/table_concat	1	408154000 ns/op	23036 peak-RSS-KiB
BenchmarkLua/array	1	883943000 ns/op	20888 peak-RSS-KiB
BenchmarkLua/binary_trees	1	730449000 ns/op	27368 peak-RSS-KiB
BenchmarkLua/closures	1	635543000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/concat	1	360794000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/coroutines	1	492246000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/fib	1	531647000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/format	1	455915000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/hash_int	1	447576000 ns/op	5960 peak-RSS-KiB
BenchmarkLua/hash_string	1	491700000 ns/op	25516 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	582954000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/methods	1	660719000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/nbody	1	851365000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/patterns	1	642766000 ns/op	9384 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	790426000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/table_concat	1	340058000 ns/op	23040 peak-RSS-KiB
```

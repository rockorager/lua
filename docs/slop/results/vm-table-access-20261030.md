# Table access with integer and short string keys inline, 2026-10-30

`GETTABLE` with a key that was not an integer called `Table.get`, and
`SETTABLE` with one called `Table.set`; both take the key and value by
value, so the operands went through stack temporaries (see
`vm-operands-20261030.md`), and a short string key paid for the generic
dispatch. `SETFIELD` on a table without a metatable called
`Table.setShortStr` even to overwrite a field that was there.

## The change

- `GETTABLE` looks up integer and short string keys inline
  (`Table.getInt`, `Table.getShortStr`); any other key goes to `getSlow`.
- `SETTABLE` with a short string key and `SETFIELD` first try
  `Table.replaceShortStr` (inline): a present key with a non-nil value
  takes the new value in place, metatable or not, as `luaV_fastset`
  does. Only a new key on a table without a metatable calls
  `setShortStr`. An integer key on a table without a metatable takes
  `setInt` as before; everything else goes to `setSlow`, by pointer.

Base is the field-by-field copies (554e68b); new is this change. Same
method: ReleaseFast, 10 rounds of every `bench/` program, interleaved,
pinned to the last core, wall time and peak RSS per process, benchstat.

## Results

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
                  │     base      │                 new                  │
                  │    sec/op     │    sec/op     vs base                │
Lua/array           1184.2m ±  4%   983.7m ±  8%  -16.93% (p=0.000 n=10)
Lua/binary_trees     815.7m ± 14%   862.6m ± 11%        ~ (p=0.143 n=10)
Lua/closures         662.2m ±  4%   657.1m ±  4%        ~ (p=0.796 n=10)
Lua/concat           388.5m ±  3%   391.6m ±  7%        ~ (p=0.315 n=10)
Lua/coroutines       540.0m ±  3%   563.8m ±  5%   +4.41% (p=0.002 n=10)
Lua/fib              628.3m ±  4%   655.0m ±  2%   +4.25% (p=0.019 n=10)
Lua/format           470.0m ±  3%   473.4m ±  9%        ~ (p=0.631 n=10)
Lua/hash_int         767.4m ±  3%   475.9m ±  4%  -37.99% (p=0.000 n=10)
Lua/hash_string      804.6m ±  5%   521.2m ± 19%  -35.23% (p=0.000 n=10)
Lua/mandelbrot       570.1m ±  1%   601.5m ±  8%   +5.50% (p=0.000 n=10)
Lua/methods          709.2m ±  4%   754.7m ± 11%   +6.42% (p=0.023 n=10)
Lua/nbody            929.7m ±  4%   804.4m ±  4%  -13.48% (p=0.000 n=10)
Lua/patterns         663.4m ± 11%   658.1m ±  1%        ~ (p=0.089 n=10)
Lua/spectral_norm    907.0m ±  2%   880.3m ±  3%   -2.94% (p=0.002 n=10)
Lua/table_concat     373.0m ± 14%   343.4m ±  4%   -7.95% (p=0.001 n=10)
geomean              662.2m         615.4m         -7.07%

                  │     base     │                 new                 │
                  │ peak-RSS-KiB │ peak-RSS-KiB  vs base               │
Lua/array            20.83k ± 0%    20.84k ± 0%  +0.03% (p=0.001 n=10)
Lua/binary_trees     18.96k ± 0%    18.97k ± 0%  +0.03% (p=0.001 n=10)
Lua/closures         2.374k ± 0%    2.372k ± 0%       ~ (p=0.473 n=10)
Lua/concat           2.372k ± 0%    2.372k ± 0%       ~ (p=0.698 n=10)
Lua/coroutines       2.372k ± 0%    2.372k ± 0%       ~ (p=0.326 n=10)
Lua/fib              2.372k ± 0%    2.372k ± 0%       ~ (p=1.000 n=10)
Lua/format           2.372k ± 0%    2.372k ± 0%       ~ (p=1.000 n=10)
Lua/hash_int         12.05k ± 0%    12.05k ± 0%  +0.03% (p=0.004 n=10)
Lua/hash_string      34.67k ± 0%    34.68k ± 0%  +0.02% (p=0.001 n=10)
Lua/mandelbrot       2.372k ± 0%    2.372k ± 0%       ~ (p=0.520 n=10)
Lua/methods          2.372k ± 0%    2.374k ± 0%       ~ (p=0.473 n=10)
Lua/nbody            2.372k ± 0%    2.372k ± 0%       ~ (p=0.662 n=10)
Lua/patterns         8.748k ± 0%    8.748k ± 0%   0.00% (p=0.019 n=10)
Lua/spectral_norm    2.372k ± 0%    2.372k ± 0%       ~ (p=0.736 n=10)
Lua/table_concat     22.12k ± 0%    22.13k ± 0%  +0.02% (p=0.000 n=10)
geomean              5.314k         5.314k       +0.01%
```

## Reading it

- hash_int −38%, hash_string −35%, array −17%, nbody −13%, table_concat
  −8%, spectral_norm −3%: everything that indexes tables with integers
  or strings from registers, or stores to fields.
- fib +4%, mandelbrot +6%, methods +6%, coroutines +4% run none of the
  changed handlers on their hot paths. The profiles show why they moved:
  the larger loop spilled `th` to the stack, and the call path reloads
  it. That is register allocation across the whole loop, and the next
  change (`vm-registers-20261030.md`) takes it back.
- Peak RSS is unchanged.

## Raw output

base:

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
BenchmarkLua/array	1	1130523000 ns/op	20832 peak-RSS-KiB
BenchmarkLua/binary_trees	1	797948000 ns/op	18968 peak-RSS-KiB
BenchmarkLua/closures	1	643886000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/concat	1	382841000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/coroutines	1	535473000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/fib	1	620569000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/format	1	469695000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/hash_int	1	743659000 ns/op	12052 peak-RSS-KiB
BenchmarkLua/hash_string	1	738178000 ns/op	34676 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	566688000 ns/op	2364 peak-RSS-KiB
BenchmarkLua/methods	1	680226000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/nbody	1	955998000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/patterns	1	736757000 ns/op	8748 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	893393000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/table_concat	1	360140000 ns/op	22124 peak-RSS-KiB
BenchmarkLua/array	1	1187845000 ns/op	20832 peak-RSS-KiB
BenchmarkLua/binary_trees	1	791338000 ns/op	18968 peak-RSS-KiB
BenchmarkLua/closures	1	666716000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/concat	1	401431000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/coroutines	1	534109000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/fib	1	708215000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/format	1	483604000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/hash_int	1	785261000 ns/op	12048 peak-RSS-KiB
BenchmarkLua/hash_string	1	839887000 ns/op	34672 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	574502000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	739269000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/nbody	1	936510000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/patterns	1	657593000 ns/op	8748 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	928177000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/table_concat	1	361965000 ns/op	22124 peak-RSS-KiB
BenchmarkLua/array	1	1137403000 ns/op	20832 peak-RSS-KiB
BenchmarkLua/binary_trees	1	776288000 ns/op	18964 peak-RSS-KiB
BenchmarkLua/closures	1	670771000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/concat	1	378408000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/coroutines	1	530200000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/fib	1	626818000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/format	1	465724000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/hash_int	1	774193000 ns/op	12048 peak-RSS-KiB
BenchmarkLua/hash_string	1	786199000 ns/op	34672 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	565699000 ns/op	2364 peak-RSS-KiB
BenchmarkLua/methods	1	692740000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/nbody	1	891118000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/patterns	1	659644000 ns/op	8748 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	897972000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/table_concat	1	363055000 ns/op	22124 peak-RSS-KiB
BenchmarkLua/array	1	1156476000 ns/op	20832 peak-RSS-KiB
BenchmarkLua/binary_trees	1	962681000 ns/op	18964 peak-RSS-KiB
BenchmarkLua/closures	1	640193000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/concat	1	377406000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/coroutines	1	543506000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/fib	1	622463000 ns/op	2364 peak-RSS-KiB
BenchmarkLua/format	1	473343000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/hash_int	1	763016000 ns/op	12052 peak-RSS-KiB
BenchmarkLua/hash_string	1	791519000 ns/op	34676 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	570437000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	721817000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/nbody	1	931593000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/patterns	1	663121000 ns/op	8744 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	892733000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/table_concat	1	366539000 ns/op	22124 peak-RSS-KiB
BenchmarkLua/array	1	1189221000 ns/op	20832 peak-RSS-KiB
BenchmarkLua/binary_trees	1	797177000 ns/op	18964 peak-RSS-KiB
BenchmarkLua/closures	1	659765000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/concat	1	396762000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/coroutines	1	543153000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/fib	1	629859000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/format	1	469654000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/hash_int	1	771779000 ns/op	12048 peak-RSS-KiB
BenchmarkLua/hash_string	1	812425000 ns/op	34676 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	569755000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	766879000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/nbody	1	931910000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/patterns	1	663736000 ns/op	8748 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	916495000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/table_concat	1	395196000 ns/op	22124 peak-RSS-KiB
BenchmarkLua/array	1	1229926000 ns/op	20832 peak-RSS-KiB
BenchmarkLua/binary_trees	1	831792000 ns/op	18964 peak-RSS-KiB
BenchmarkLua/closures	1	679584000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/concat	1	420504000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/coroutines	1	584683000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/fib	1	645106000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/format	1	472910000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/hash_int	1	816390000 ns/op	12048 peak-RSS-KiB
BenchmarkLua/hash_string	1	982936000 ns/op	34672 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	568013000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	681130000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/nbody	1	943534000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/patterns	1	659345000 ns/op	8748 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	925608000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/table_concat	1	455528000 ns/op	22124 peak-RSS-KiB
BenchmarkLua/array	1	1147322000 ns/op	20832 peak-RSS-KiB
BenchmarkLua/binary_trees	1	872221000 ns/op	18968 peak-RSS-KiB
BenchmarkLua/closures	1	664700000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/concat	1	378838000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/coroutines	1	545811000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/fib	1	621746000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/format	1	470019000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/hash_int	1	739794000 ns/op	12048 peak-RSS-KiB
BenchmarkLua/hash_string	1	796770000 ns/op	34676 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	572221000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	734607000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/nbody	1	900445000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/patterns	1	673149000 ns/op	8748 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	893873000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/table_concat	1	376990000 ns/op	22124 peak-RSS-KiB
BenchmarkLua/array	1	1205179000 ns/op	20832 peak-RSS-KiB
BenchmarkLua/binary_trees	1	889938000 ns/op	18964 peak-RSS-KiB
BenchmarkLua/closures	1	637332000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/concat	1	394157000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/coroutines	1	536839000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/fib	1	631288000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/format	1	493958000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/hash_int	1	745088000 ns/op	12052 peak-RSS-KiB
BenchmarkLua/hash_string	1	791231000 ns/op	34672 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	623434000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	696508000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/nbody	1	927895000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/patterns	1	756826000 ns/op	8744 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	984944000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/table_concat	1	372845000 ns/op	22124 peak-RSS-KiB
BenchmarkLua/array	1	1183829000 ns/op	20836 peak-RSS-KiB
BenchmarkLua/binary_trees	1	933127000 ns/op	18964 peak-RSS-KiB
BenchmarkLua/closures	1	711649000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/concat	1	400882000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/coroutines	1	558327000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/fib	1	622939000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/format	1	470061000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/hash_int	1	791464000 ns/op	12052 peak-RSS-KiB
BenchmarkLua/hash_string	1	841846000 ns/op	34676 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	570540000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/methods	1	690539000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/nbody	1	924789000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/patterns	1	715634000 ns/op	8744 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	915960000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/table_concat	1	426243000 ns/op	22124 peak-RSS-KiB
BenchmarkLua/array	1	1184660000 ns/op	20832 peak-RSS-KiB
BenchmarkLua/binary_trees	1	799621000 ns/op	18964 peak-RSS-KiB
BenchmarkLua/closures	1	637561000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/concat	1	378463000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/coroutines	1	530021000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/fib	1	652881000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/format	1	469902000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/hash_int	1	741493000 ns/op	12048 peak-RSS-KiB
BenchmarkLua/hash_string	1	820878000 ns/op	34672 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	568608000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	728233000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/nbody	1	896900000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/patterns	1	651657000 ns/op	8748 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	898057000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/table_concat	1	373243000 ns/op	22124 peak-RSS-KiB
```

new:

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
BenchmarkLua/array	1	987770000 ns/op	20840 peak-RSS-KiB
BenchmarkLua/binary_trees	1	817815000 ns/op	18972 peak-RSS-KiB
BenchmarkLua/closures	1	662690000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/concat	1	420860000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/coroutines	1	558421000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/fib	1	641338000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/format	1	466400000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/hash_int	1	466343000 ns/op	12052 peak-RSS-KiB
BenchmarkLua/hash_string	1	472077000 ns/op	34680 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	578766000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/methods	1	712481000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/nbody	1	786630000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/patterns	1	654123000 ns/op	8748 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	887891000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/table_concat	1	333611000 ns/op	22128 peak-RSS-KiB
BenchmarkLua/array	1	978214000 ns/op	20832 peak-RSS-KiB
BenchmarkLua/binary_trees	1	812772000 ns/op	18972 peak-RSS-KiB
BenchmarkLua/closures	1	653536000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/concat	1	392942000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/coroutines	1	554191000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/fib	1	660076000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/format	1	532966000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/hash_int	1	483689000 ns/op	12052 peak-RSS-KiB
BenchmarkLua/hash_string	1	488098000 ns/op	34676 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	605801000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/methods	1	878704000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/nbody	1	837772000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/patterns	1	655943000 ns/op	8752 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	883002000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/table_concat	1	331183000 ns/op	22128 peak-RSS-KiB
BenchmarkLua/array	1	960799000 ns/op	20836 peak-RSS-KiB
BenchmarkLua/binary_trees	1	812448000 ns/op	18968 peak-RSS-KiB
BenchmarkLua/closures	1	646415000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/concat	1	382781000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/coroutines	1	552798000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/fib	1	642629000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/format	1	465442000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/hash_int	1	473149000 ns/op	12052 peak-RSS-KiB
BenchmarkLua/hash_string	1	492044000 ns/op	34676 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	579938000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	720981000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/nbody	1	812024000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/patterns	1	653962000 ns/op	8752 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	863810000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/table_concat	1	338523000 ns/op	22128 peak-RSS-KiB
BenchmarkLua/array	1	977660000 ns/op	20840 peak-RSS-KiB
BenchmarkLua/binary_trees	1	832324000 ns/op	18972 peak-RSS-KiB
BenchmarkLua/closures	1	655775000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/concat	1	388650000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/coroutines	1	593466000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/fib	1	644869000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/format	1	474609000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/hash_int	1	473493000 ns/op	12052 peak-RSS-KiB
BenchmarkLua/hash_string	1	519839000 ns/op	34676 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	577505000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	758107000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/nbody	1	780648000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/patterns	1	664004000 ns/op	8752 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	873340000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/table_concat	1	344825000 ns/op	22132 peak-RSS-KiB
BenchmarkLua/array	1	1061276000 ns/op	20836 peak-RSS-KiB
BenchmarkLua/binary_trees	1	922246000 ns/op	18968 peak-RSS-KiB
BenchmarkLua/closures	1	741681000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/concat	1	390346000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/coroutines	1	561102000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/fib	1	658951000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/format	1	514380000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/hash_int	1	484791000 ns/op	12052 peak-RSS-KiB
BenchmarkLua/hash_string	1	544176000 ns/op	34680 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	658601000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	834131000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/nbody	1	811583000 ns/op	2364 peak-RSS-KiB
BenchmarkLua/patterns	1	660977000 ns/op	8748 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	903995000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/table_concat	1	347777000 ns/op	22132 peak-RSS-KiB
BenchmarkLua/array	1	1067033000 ns/op	20840 peak-RSS-KiB
BenchmarkLua/binary_trees	1	945027000 ns/op	18968 peak-RSS-KiB
BenchmarkLua/closures	1	683320000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/concat	1	475826000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/coroutines	1	566518000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/fib	1	671198000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/format	1	494756000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/hash_int	1	478220000 ns/op	12052 peak-RSS-KiB
BenchmarkLua/hash_string	1	622448000 ns/op	34680 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	602348000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/methods	1	751291000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/nbody	1	782100000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/patterns	1	658827000 ns/op	8748 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	907668000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/table_concat	1	357968000 ns/op	22128 peak-RSS-KiB
BenchmarkLua/array	1	983859000 ns/op	20836 peak-RSS-KiB
BenchmarkLua/binary_trees	1	892919000 ns/op	18968 peak-RSS-KiB
BenchmarkLua/closures	1	639700000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/concat	1	385056000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/coroutines	1	553029000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/fib	1	651140000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/format	1	489618000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/hash_int	1	471666000 ns/op	12056 peak-RSS-KiB
BenchmarkLua/hash_string	1	640579000 ns/op	34680 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	581147000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	775382000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/nbody	1	797214000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/patterns	1	659572000 ns/op	8748 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	877612000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/table_concat	1	417469000 ns/op	22128 peak-RSS-KiB
BenchmarkLua/array	1	1059873000 ns/op	20840 peak-RSS-KiB
BenchmarkLua/binary_trees	1	953356000 ns/op	18972 peak-RSS-KiB
BenchmarkLua/closures	1	658430000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/concat	1	395843000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/coroutines	1	638793000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/fib	1	661223000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/format	1	469685000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/hash_int	1	495821000 ns/op	12056 peak-RSS-KiB
BenchmarkLua/hash_string	1	541761000 ns/op	34680 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	651507000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/methods	1	708150000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/nbody	1	833102000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/patterns	1	707479000 ns/op	8752 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	865807000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/table_concat	1	339981000 ns/op	22128 peak-RSS-KiB
BenchmarkLua/array	1	983589000 ns/op	20840 peak-RSS-KiB
BenchmarkLua/binary_trees	1	1059736000 ns/op	18972 peak-RSS-KiB
BenchmarkLua/closures	1	672158000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/concat	1	415270000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/coroutines	1	586720000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/fib	1	668501000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/format	1	467910000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/hash_int	1	516409000 ns/op	12052 peak-RSS-KiB
BenchmarkLua/hash_string	1	522482000 ns/op	34680 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	627456000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	773054000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/nbody	1	793028000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/patterns	1	657405000 ns/op	8748 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	884178000 ns/op	2364 peak-RSS-KiB
BenchmarkLua/table_concat	1	348860000 ns/op	22128 peak-RSS-KiB
BenchmarkLua/array	1	981404000 ns/op	20836 peak-RSS-KiB
BenchmarkLua/binary_trees	1	813187000 ns/op	18968 peak-RSS-KiB
BenchmarkLua/closures	1	645092000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/concat	1	387005000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/coroutines	1	572172000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/fib	1	643832000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/format	1	472099000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/hash_int	1	464598000 ns/op	12056 peak-RSS-KiB
BenchmarkLua/hash_string	1	494936000 ns/op	34676 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	600587000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/methods	1	734098000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/nbody	1	862994000 ns/op	2368 peak-RSS-KiB
BenchmarkLua/patterns	1	656580000 ns/op	8748 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	871419000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/table_concat	1	341916000 ns/op	22128 peak-RSS-KiB
```

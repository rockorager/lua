# A size-class allocator for the executable: rejected, 2026-10-30

The collector's write-up left two causes for hash_string's peak RSS above
the reference's (1.13×): our 40-byte `String` header against the
reference's 24-byte `TString`, and `std.heap.SmpAllocator`'s power-of-two
size classes. This measures the allocator alone.

## What was tried

A single-threaded allocator for `src/main.zig` (no lock, no thread-local
slot lookup): size classes 8 bytes apart up to 128 bytes, then four per
doubling up to 32 KiB, carved from 64 KiB chunks with a free list per
class; larger blocks were mapped pages, as SmpAllocator does. A 50-byte
string took 56 bytes instead of 64, a 144-byte `Proto` 160 instead of 256.

Base is the return change (cbc44e9) with SmpAllocator; new is the same
tree with the class allocator. ReleaseFast, 10 rounds of every `bench/`
program, interleaved, pinned to the last core, benchstat.

## Results

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
                  │     base     │                  new                  │
                  │    sec/op    │    sec/op      vs base                │
Lua/array           880.2m ±  3%    908.6m ±  3%   +3.23% (p=0.003 n=10)
Lua/binary_trees    695.9m ±  1%    688.4m ±  3%        ~ (p=0.165 n=10)
Lua/closures        647.1m ±  7%    677.5m ±  1%   +4.70% (p=0.019 n=10)
Lua/concat          370.9m ±  9%    359.5m ±  1%   -3.08% (p=0.029 n=10)
Lua/coroutines      485.5m ± 13%    535.9m ±  3%  +10.39% (p=0.011 n=10)
Lua/fib             531.6m ±  2%    535.3m ±  3%        ~ (p=0.353 n=10)
Lua/format          455.3m ±  1%    449.5m ±  1%   -1.28% (p=0.004 n=10)
Lua/hash_int        446.5m ±  9%    462.5m ±  4%        ~ (p=0.190 n=10)
Lua/hash_string     490.6m ±  8%    456.5m ± 12%        ~ (p=0.105 n=10)
Lua/mandelbrot      584.4m ±  1%    592.5m ±  4%   +1.39% (p=0.004 n=10)
Lua/methods         668.3m ±  3%    837.6m ±  2%  +25.33% (p=0.000 n=10)
Lua/nbody           821.2m ±  6%    960.3m ±  5%  +16.95% (p=0.000 n=10)
Lua/patterns        633.6m ±  1%    637.7m ±  3%        ~ (p=0.063 n=10)
Lua/spectral_norm   803.7m ±  6%   1080.0m ±  3%  +34.38% (p=0.000 n=10)
Lua/table_concat    371.9m ±  2%    375.3m ±  8%        ~ (p=0.190 n=10)
geomean             572.0m          603.3m         +5.47%

                  │     base     │                 new                 │
                  │ peak-RSS-KiB │ peak-RSS-KiB  vs base               │
Lua/array            20.89k ± 0%    20.93k ± 0%  +0.23% (p=0.000 n=10)
Lua/binary_trees     27.37k ± 0%    26.15k ± 0%  -4.46% (p=0.000 n=10)
Lua/closures         2.380k ± 0%    2.382k ± 0%       ~ (p=0.584 n=10)
Lua/concat           2.378k ± 0%    2.380k ± 0%       ~ (p=0.418 n=10)
Lua/coroutines       2.380k ± 0%    2.380k ± 0%       ~ (p=0.996 n=10)
Lua/fib              2.380k ± 0%    2.380k ± 0%       ~ (p=0.677 n=10)
Lua/format           2.382k ± 0%    2.380k ± 0%       ~ (p=0.714 n=10)
Lua/hash_int         5.958k ± 0%    6.004k ± 0%  +0.77% (p=0.000 n=10)
Lua/hash_string      25.51k ± 0%    23.96k ± 0%  -6.07% (p=0.000 n=10)
Lua/mandelbrot       2.380k ± 0%    2.380k ± 0%       ~ (p=0.760 n=10)
Lua/methods          2.376k ± 0%    2.380k ± 0%       ~ (p=0.160 n=10)
Lua/nbody            2.380k ± 0%    2.380k ± 0%       ~ (p=0.736 n=10)
Lua/patterns         9.852k ± 0%    9.646k ± 0%  -2.09% (p=0.000 n=10)
Lua/spectral_norm    2.380k ± 0%    2.380k ± 0%       ~ (p=0.330 n=10)
Lua/table_concat     43.54k ± 0%    43.63k ± 0%  +0.21% (p=0.000 n=10)
geomean              5.378k         5.337k       -0.76%
```

## Reading it

- Memory moved the right way where blocks fell between powers of two:
  hash_string −6.1%, binary_trees −4.5%, patterns −2.1%.
- Time did not: spectral_norm +34%, methods +25%, nbody +17%,
  coroutines +10%. Those programs allocate nothing in their loops; the
  interpreter's code is byte for byte the same (runLoop is 0x7eef bytes
  in both binaries, shifted by 0xf0). The extra samples sit on loads in
  `CALL`'s frame setup: the callee's `Proto` fields
  (`maxstacksize`, `code`) and its first instruction.

Where the time went, by experiment on spectral_norm and methods (wall
seconds, two runs each, one binary with the rounding chosen at startup):

```
mode                                      spectral_norm   methods
classes as above                          1.03  1.02      0.81  0.80
start each chunk at a varying 64-byte
  offset (six multipliers)                1.02 – 1.06     0.78 – 0.83
round blocks over 64 B to 64              0.93  0.92      0.74  0.81
round blocks over 128 B to 64             0.91  0.89      0.79  0.70
33–56 B blocks to 64 (closures, small
  arrays) only                            0.85  0.89      0.68  0.68
129–160 B blocks to 192 (Proto) only      0.89  0.92      0.74  0.76
161–192 B to 192 (Thread) only            1.02  1.02      0.79  0.78
65–128 B to 32 multiples only             1.00  1.02      0.80  0.84
round blocks over 32 B to 32              0.83  0.82      0.70  0.68
SmpAllocator (base)                       0.81  0.83      0.68  0.72
```

So the cost comes from 40-, 48- and 56-byte blocks (closures with few
upvalues, short constant and code arrays) and 144-byte prototypes placed
off 32-byte boundaries. Varying the chunk offsets, which moves every
class's blocks relative to the others, did not help, so it is not plain
4 KiB aliasing between chunk starts. Without hardware counters in the
orb, the exact mechanism is not settled.

With every block over 32 bytes a multiple of 32, time came back
(spectral_norm 0.91 against 0.88, methods 0.67 against 0.68, single runs)
but the memory win went with it: a 50-byte string takes 64 bytes again,
and hash_string's peak rose to 26,056 KiB against SmpAllocator's 25,520.
binary_trees kept a small gain (26,940 against 27,376 KiB).

The allocator is not in. hash_string's remaining gap is the `String`
header and what the collector keeps; the allocator alone cannot close it
without the layout cost above.

Follow-up: aligning only closures to 32 bytes (a 32-byte alignment request
from `LuaClosure.create`) did not bring the time back (spectral_norm 1.03
and 1.05 s, methods 0.82 and 0.84). Classes for strings alone, with every
other object on SmpAllocator, kept the time (an A/B on seven programs:
geomean +0.5%, nothing but methods outside noise at +3%); that and a
32-byte header are `strings-20261030.md`.

## Raw output

base:

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
BenchmarkLua/array	1	859314000 ns/op	20888 peak-RSS-KiB
BenchmarkLua/binary_trees	1	700500000 ns/op	27368 peak-RSS-KiB
BenchmarkLua/closures	1	648252000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/concat	1	357274000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/coroutines	1	476354000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/fib	1	541600000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/format	1	452779000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/hash_int	1	451005000 ns/op	5956 peak-RSS-KiB
BenchmarkLua/hash_string	1	451263000 ns/op	25512 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	581881000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/methods	1	685471000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/nbody	1	804586000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/patterns	1	631252000 ns/op	9852 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	852333000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/table_concat	1	375373000 ns/op	43540 peak-RSS-KiB
BenchmarkLua/array	1	884198000 ns/op	20884 peak-RSS-KiB
BenchmarkLua/binary_trees	1	696251000 ns/op	27368 peak-RSS-KiB
BenchmarkLua/closures	1	644069000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/concat	1	407048000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/coroutines	1	482538000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/fib	1	530798000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/format	1	526768000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/hash_int	1	441057000 ns/op	5960 peak-RSS-KiB
BenchmarkLua/hash_string	1	521262000 ns/op	25508 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	582699000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/methods	1	652458000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/nbody	1	811405000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/patterns	1	632486000 ns/op	9852 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	794721000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/table_concat	1	369438000 ns/op	43536 peak-RSS-KiB
BenchmarkLua/array	1	874493000 ns/op	20888 peak-RSS-KiB
BenchmarkLua/binary_trees	1	701990000 ns/op	27368 peak-RSS-KiB
BenchmarkLua/closures	1	634288000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/concat	1	373271000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/coroutines	1	478724000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/fib	1	528946000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/format	1	453632000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/hash_int	1	435554000 ns/op	5956 peak-RSS-KiB
BenchmarkLua/hash_string	1	452628000 ns/op	25508 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	584359000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/methods	1	701819000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/nbody	1	832081000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/patterns	1	627387000 ns/op	9856 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	803477000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/table_concat	1	371337000 ns/op	43540 peak-RSS-KiB
BenchmarkLua/array	1	874102000 ns/op	20888 peak-RSS-KiB
BenchmarkLua/binary_trees	1	692251000 ns/op	27368 peak-RSS-KiB
BenchmarkLua/closures	1	656509000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/concat	1	369611000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/coroutines	1	488451000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/fib	1	531359000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/format	1	455352000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/hash_int	1	441896000 ns/op	5956 peak-RSS-KiB
BenchmarkLua/hash_string	1	497287000 ns/op	25512 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	587571000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/methods	1	669791000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/nbody	1	815997000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/patterns	1	653000000 ns/op	9852 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	817984000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/table_concat	1	361922000 ns/op	43536 peak-RSS-KiB
BenchmarkLua/array	1	909555000 ns/op	20884 peak-RSS-KiB
BenchmarkLua/binary_trees	1	689236000 ns/op	27368 peak-RSS-KiB
BenchmarkLua/closures	1	641040000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/concat	1	365719000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/coroutines	1	492611000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/fib	1	530084000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/format	1	456117000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/hash_int	1	433473000 ns/op	5960 peak-RSS-KiB
BenchmarkLua/hash_string	1	458764000 ns/op	25512 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	584466000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/methods	1	662661000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/nbody	1	910197000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/patterns	1	635270000 ns/op	9856 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	816072000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/table_concat	1	365310000 ns/op	43536 peak-RSS-KiB
BenchmarkLua/array	1	921595000 ns/op	20884 peak-RSS-KiB
BenchmarkLua/binary_trees	1	695156000 ns/op	27364 peak-RSS-KiB
BenchmarkLua/closures	1	645848000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/concat	1	359916000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/coroutines	1	477316000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/fib	1	531901000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/format	1	453792000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/hash_int	1	488218000 ns/op	5956 peak-RSS-KiB
BenchmarkLua/hash_string	1	515483000 ns/op	25512 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	582219000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/methods	1	646994000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/nbody	1	857848000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/patterns	1	637886000 ns/op	9856 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	799124000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/table_concat	1	373670000 ns/op	43536 peak-RSS-KiB
BenchmarkLua/array	1	878271000 ns/op	20884 peak-RSS-KiB
BenchmarkLua/binary_trees	1	683414000 ns/op	27364 peak-RSS-KiB
BenchmarkLua/closures	1	732943000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/concat	1	372153000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/coroutines	1	475446000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/fib	1	537612000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/format	1	461178000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/hash_int	1	455951000 ns/op	5960 peak-RSS-KiB
BenchmarkLua/hash_string	1	521093000 ns/op	25512 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	590196000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/methods	1	667606000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/nbody	1	785860000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/patterns	1	635885000 ns/op	9852 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	803837000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/table_concat	1	368997000 ns/op	43536 peak-RSS-KiB
BenchmarkLua/array	1	871541000 ns/op	20884 peak-RSS-KiB
BenchmarkLua/binary_trees	1	695608000 ns/op	27368 peak-RSS-KiB
BenchmarkLua/closures	1	649802000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/concat	1	373813000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/coroutines	1	523129000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/fib	1	532158000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/format	1	456257000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/hash_int	1	461255000 ns/op	5960 peak-RSS-KiB
BenchmarkLua/hash_string	1	549711000 ns/op	25508 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	591689000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/methods	1	669787000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/nbody	1	794135000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/patterns	1	626838000 ns/op	9852 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	857559000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/table_concat	1	388398000 ns/op	43536 peak-RSS-KiB
BenchmarkLua/array	1	882085000 ns/op	20888 peak-RSS-KiB
BenchmarkLua/binary_trees	1	720984000 ns/op	27368 peak-RSS-KiB
BenchmarkLua/closures	1	694694000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/concat	1	403256000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/coroutines	1	548131000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/fib	1	529841000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/format	1	452262000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/hash_int	1	439755000 ns/op	5956 peak-RSS-KiB
BenchmarkLua/hash_string	1	467699000 ns/op	25508 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	615305000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/methods	1	642887000 ns/op	2364 peak-RSS-KiB
BenchmarkLua/nbody	1	873223000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/patterns	1	634664000 ns/op	9852 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	800019000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/table_concat	1	374423000 ns/op	43540 peak-RSS-KiB
BenchmarkLua/array	1	888035000 ns/op	20888 peak-RSS-KiB
BenchmarkLua/binary_trees	1	698060000 ns/op	27368 peak-RSS-KiB
BenchmarkLua/closures	1	645062000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/concat	1	361517000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/coroutines	1	550628000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/fib	1	558104000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/format	1	455260000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/hash_int	1	491848000 ns/op	5960 peak-RSS-KiB
BenchmarkLua/hash_string	1	483977000 ns/op	25512 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	584194000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/methods	1	669015000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/nbody	1	826343000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/patterns	1	627281000 ns/op	9852 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	792314000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/table_concat	1	372465000 ns/op	43536 peak-RSS-KiB
```

new:

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
BenchmarkLua/array	1	892126000 ns/op	20932 peak-RSS-KiB
BenchmarkLua/binary_trees	1	691408000 ns/op	26148 peak-RSS-KiB
BenchmarkLua/closures	1	677829000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/concat	1	358832000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/coroutines	1	535662000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/fib	1	536076000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/format	1	445517000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/hash_int	1	441675000 ns/op	6004 peak-RSS-KiB
BenchmarkLua/hash_string	1	438695000 ns/op	23960 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	591876000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/methods	1	821735000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/nbody	1	953883000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/patterns	1	730135000 ns/op	9648 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	1076417000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/table_concat	1	378424000 ns/op	43624 peak-RSS-KiB
BenchmarkLua/array	1	1027371000 ns/op	20932 peak-RSS-KiB
BenchmarkLua/binary_trees	1	711971000 ns/op	26148 peak-RSS-KiB
BenchmarkLua/closures	1	666697000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/concat	1	355160000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/coroutines	1	522450000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/fib	1	549732000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/format	1	449879000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/hash_int	1	460650000 ns/op	6004 peak-RSS-KiB
BenchmarkLua/hash_string	1	452725000 ns/op	23964 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	592801000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/methods	1	846145000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/nbody	1	983949000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/patterns	1	640595000 ns/op	9648 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	1084245000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/table_concat	1	377092000 ns/op	43628 peak-RSS-KiB
BenchmarkLua/array	1	904172000 ns/op	20936 peak-RSS-KiB
BenchmarkLua/binary_trees	1	676040000 ns/op	26144 peak-RSS-KiB
BenchmarkLua/closures	1	671864000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/concat	1	362924000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/coroutines	1	534953000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/fib	1	528185000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/format	1	450949000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/hash_int	1	441777000 ns/op	6004 peak-RSS-KiB
BenchmarkLua/hash_string	1	460207000 ns/op	23964 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	603155000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/methods	1	825319000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/nbody	1	1007826000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/patterns	1	633027000 ns/op	9644 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	1072105000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/table_concat	1	371300000 ns/op	43628 peak-RSS-KiB
BenchmarkLua/array	1	907566000 ns/op	20936 peak-RSS-KiB
BenchmarkLua/binary_trees	1	683530000 ns/op	26144 peak-RSS-KiB
BenchmarkLua/closures	1	698197000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/concat	1	355941000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/coroutines	1	544219000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/fib	1	534774000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/format	1	452303000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/hash_int	1	469625000 ns/op	6004 peak-RSS-KiB
BenchmarkLua/hash_string	1	450391000 ns/op	23964 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	596294000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/methods	1	872271000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/nbody	1	1084268000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/patterns	1	647237000 ns/op	9648 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	1076621000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/table_concat	1	367828000 ns/op	43628 peak-RSS-KiB
BenchmarkLua/array	1	895931000 ns/op	20936 peak-RSS-KiB
BenchmarkLua/binary_trees	1	680051000 ns/op	26148 peak-RSS-KiB
BenchmarkLua/closures	1	677089000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/concat	1	362600000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/coroutines	1	540700000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/fib	1	531231000 ns/op	2360 peak-RSS-KiB
BenchmarkLua/format	1	456675000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/hash_int	1	451018000 ns/op	6004 peak-RSS-KiB
BenchmarkLua/hash_string	1	444720000 ns/op	23964 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	615332000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/methods	1	842565000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/nbody	1	953221000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/patterns	1	633615000 ns/op	9648 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	1121161000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/table_concat	1	381596000 ns/op	43628 peak-RSS-KiB
BenchmarkLua/array	1	923645000 ns/op	20936 peak-RSS-KiB
BenchmarkLua/binary_trees	1	692440000 ns/op	26148 peak-RSS-KiB
BenchmarkLua/closures	1	667995000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/concat	1	353961000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/coroutines	1	553294000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/fib	1	535931000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/format	1	448425000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/hash_int	1	464259000 ns/op	6000 peak-RSS-KiB
BenchmarkLua/hash_string	1	450021000 ns/op	23960 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	586967000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/methods	1	845737000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/nbody	1	952481000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/patterns	1	637957000 ns/op	9644 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	1083332000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/table_concat	1	432930000 ns/op	43624 peak-RSS-KiB
BenchmarkLua/array	1	909662000 ns/op	20932 peak-RSS-KiB
BenchmarkLua/binary_trees	1	680852000 ns/op	26148 peak-RSS-KiB
BenchmarkLua/closures	1	684309000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/concat	1	361055000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/coroutines	1	536188000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/fib	1	535791000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/format	1	454221000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/hash_int	1	541359000 ns/op	6004 peak-RSS-KiB
BenchmarkLua/hash_string	1	511936000 ns/op	23964 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	589351000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/methods	1	828765000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/nbody	1	978623000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/patterns	1	634319000 ns/op	9644 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	1072619000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/table_concat	1	370856000 ns/op	43628 peak-RSS-KiB
BenchmarkLua/array	1	901416000 ns/op	20936 peak-RSS-KiB
BenchmarkLua/binary_trees	1	705595000 ns/op	26148 peak-RSS-KiB
BenchmarkLua/closures	1	675432000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/concat	1	360072000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/coroutines	1	575276000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/fib	1	554496000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/format	1	449052000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/hash_int	1	474605000 ns/op	6000 peak-RSS-KiB
BenchmarkLua/hash_string	1	606441000 ns/op	23968 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	592237000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/methods	1	814695000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/nbody	1	959338000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/patterns	1	633037000 ns/op	9644 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	1111219000 ns/op	2372 peak-RSS-KiB
BenchmarkLua/table_concat	1	404500000 ns/op	43628 peak-RSS-KiB
BenchmarkLua/array	1	939242000 ns/op	20932 peak-RSS-KiB
BenchmarkLua/binary_trees	1	698000000 ns/op	26148 peak-RSS-KiB
BenchmarkLua/closures	1	677921000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/concat	1	412750000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/coroutines	1	525714000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/fib	1	532143000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/format	1	448520000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/hash_int	1	446872000 ns/op	6004 peak-RSS-KiB
BenchmarkLua/hash_string	1	463779000 ns/op	23964 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	591761000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/methods	1	832557000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/nbody	1	946064000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/patterns	1	637439000 ns/op	9648 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	1094667000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/table_concat	1	373582000 ns/op	43628 peak-RSS-KiB
BenchmarkLua/array	1	914191000 ns/op	20932 peak-RSS-KiB
BenchmarkLua/binary_trees	1	685306000 ns/op	26144 peak-RSS-KiB
BenchmarkLua/closures	1	679788000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/concat	1	356268000 ns/op	2384 peak-RSS-KiB
BenchmarkLua/coroutines	1	529907000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/fib	1	532522000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/format	1	448241000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/hash_int	1	465613000 ns/op	6004 peak-RSS-KiB
BenchmarkLua/hash_string	1	481702000 ns/op	23964 peak-RSS-KiB
BenchmarkLua/mandelbrot	1	642340000 ns/op	2376 peak-RSS-KiB
BenchmarkLua/methods	1	849730000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/nbody	1	961351000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/patterns	1	658458000 ns/op	9644 peak-RSS-KiB
BenchmarkLua/spectral_norm	1	1069711000 ns/op	2380 peak-RSS-KiB
BenchmarkLua/table_concat	1	372009000 ns/op	43624 peak-RSS-KiB
```

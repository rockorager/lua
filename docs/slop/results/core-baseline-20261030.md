# Core baseline against reference Lua, 2026-10-30

The first measurement of the wave-1 core: three hand-assembled programs on
our interpreter against the same programs in reference C Lua 5.5.1 from the
dev shell. No parser exists yet, so the Zig side runs bytecode transcribed
from `luac -l -l` (the `fib` test in `src/vm.zig` is the same transcription),
and process startup is included on both sides.

## Programs

- `fib`: `local function fib(n) if n < 2 then return n end return fib(n-1) + fib(n-2) end print(fib(32))`.
  Calls and returns, `LTI`, `ADDI`, `GETUPVAL`.
- `loop`: `local s = 0 for i = 1, 100000000 do s = s + i end print(s)`.
  Dispatch, `ADD` with its skipped `MMBIN`, `FORLOOP`.
- `tab`: `local t = {} for i = 1, 10000000 do t[i] = i end local s = 0 for i = 1, #t do s = s + t[i] end print(s)`.
  Array-part growth, `SETTABLE`, `GETTABLE`, `LEN`.

Both sides print the same results (2178309, 5000000050000000,
50000005000000).

## Method

Our side: a scratch driver built with `zig build-exe -OReleaseFast` against
`src/root.zig`, allocating through `std.heap.smp_allocator`. Reference:
`lua <file>.lua`. Each run is pinned with `taskset -c 1`; the six commands
are interleaved round by round, 20 rounds. Orb: Intel Xeon @ 2.60GHz, 4
vCPUs, kernel 6.1. The orb is shared, so variance is high (see max); the
medians are the comparison. benchstat is not in the dev shell yet, so the raw
lines below are in Go benchmark format for it, and the summary is computed
directly.

## Results

| program | ours median (min) | reference median (min) | ratio |
| ------- | ----------------- | ---------------------- | ----- |
| fib     | 131.1 ms (106.7)  | 134.4 ms (110.6)       | 0.98  |
| loop    | 357.4 ms (290.6)  | 424.9 ms (338.1)       | 0.84  |
| tab     | 272.2 ms (225.9)  | 259.9 ms (217.3)       | 1.05  |

## Development measurements

Same method, 10 rounds, taken while building the core; each row changed
one thing:

| change                                                                                                             | fib ratio | loop ratio | tab ratio |
| ------------------------------------------------------------------------------------------------------------------ | --------- | ---------- | --------- |
| first working build                                                                                                | 1.58      | 1.09       | 1.26      |
| `CALL` pushes Lua frames inline (no out-of-line `preCall`), register operands widened to `u32`                     | 1.01      | 0.89       | 1.33      |
| `Table.setInt` array path inline; resize copies payloads and tags with one `memcpy` each; slice counting in rehash | 0.98      | 0.87       | 1.03      |

The widened operands also fixed a latent wrap: `a + 3` in `u8` overflows
for registers near 255.

## Raw output

```
BenchmarkRaw/fib/impl=zig 1 133724328 ns/op
BenchmarkRaw/fib/impl=zig 1 173979707 ns/op
BenchmarkRaw/fib/impl=zig 1 115122630 ns/op
BenchmarkRaw/fib/impl=zig 1 132907448 ns/op
BenchmarkRaw/fib/impl=zig 1 135305527 ns/op
BenchmarkRaw/fib/impl=zig 1 127611400 ns/op
BenchmarkRaw/fib/impl=zig 1 131925380 ns/op
BenchmarkRaw/fib/impl=zig 1 128001257 ns/op
BenchmarkRaw/fib/impl=zig 1 136743652 ns/op
BenchmarkRaw/fib/impl=zig 1 129707001 ns/op
BenchmarkRaw/fib/impl=zig 1 127257491 ns/op
BenchmarkRaw/fib/impl=zig 1 130194065 ns/op
BenchmarkRaw/fib/impl=zig 1 106729424 ns/op
BenchmarkRaw/fib/impl=zig 1 135704163 ns/op
BenchmarkRaw/fib/impl=zig 1 124449102 ns/op
BenchmarkRaw/fib/impl=zig 1 133472850 ns/op
BenchmarkRaw/fib/impl=zig 1 218425015 ns/op
BenchmarkRaw/fib/impl=zig 1 114720816 ns/op
BenchmarkRaw/fib/impl=zig 1 124682176 ns/op
BenchmarkRaw/fib/impl=zig 1 136500184 ns/op
BenchmarkRaw/fib/impl=lua 1 134262186 ns/op
BenchmarkRaw/fib/impl=lua 1 132406946 ns/op
BenchmarkRaw/fib/impl=lua 1 138227310 ns/op
BenchmarkRaw/fib/impl=lua 1 133129312 ns/op
BenchmarkRaw/fib/impl=lua 1 142171711 ns/op
BenchmarkRaw/fib/impl=lua 1 130072541 ns/op
BenchmarkRaw/fib/impl=lua 1 135560625 ns/op
BenchmarkRaw/fib/impl=lua 1 110569900 ns/op
BenchmarkRaw/fib/impl=lua 1 141937973 ns/op
BenchmarkRaw/fib/impl=lua 1 133088532 ns/op
BenchmarkRaw/fib/impl=lua 1 134449627 ns/op
BenchmarkRaw/fib/impl=lua 1 133750027 ns/op
BenchmarkRaw/fib/impl=lua 1 111019222 ns/op
BenchmarkRaw/fib/impl=lua 1 134479933 ns/op
BenchmarkRaw/fib/impl=lua 1 142606359 ns/op
BenchmarkRaw/fib/impl=lua 1 153337356 ns/op
BenchmarkRaw/fib/impl=lua 1 146551552 ns/op
BenchmarkRaw/fib/impl=lua 1 111806892 ns/op
BenchmarkRaw/fib/impl=lua 1 129975187 ns/op
BenchmarkRaw/fib/impl=lua 1 136656536 ns/op
BenchmarkRaw/loop/impl=zig 1 364046924 ns/op
BenchmarkRaw/loop/impl=zig 1 310743377 ns/op
BenchmarkRaw/loop/impl=zig 1 357194182 ns/op
BenchmarkRaw/loop/impl=zig 1 351464714 ns/op
BenchmarkRaw/loop/impl=zig 1 386522644 ns/op
BenchmarkRaw/loop/impl=zig 1 343889628 ns/op
BenchmarkRaw/loop/impl=zig 1 354529638 ns/op
BenchmarkRaw/loop/impl=zig 1 327974213 ns/op
BenchmarkRaw/loop/impl=zig 1 369462888 ns/op
BenchmarkRaw/loop/impl=zig 1 365012199 ns/op
BenchmarkRaw/loop/impl=zig 1 357638858 ns/op
BenchmarkRaw/loop/impl=zig 1 355143460 ns/op
BenchmarkRaw/loop/impl=zig 1 290611236 ns/op
BenchmarkRaw/loop/impl=zig 1 363593215 ns/op
BenchmarkRaw/loop/impl=zig 1 430463956 ns/op
BenchmarkRaw/loop/impl=zig 1 388484115 ns/op
BenchmarkRaw/loop/impl=zig 1 446459869 ns/op
BenchmarkRaw/loop/impl=zig 1 293586064 ns/op
BenchmarkRaw/loop/impl=zig 1 353582908 ns/op
BenchmarkRaw/loop/impl=zig 1 371925212 ns/op
BenchmarkRaw/loop/impl=lua 1 430392642 ns/op
BenchmarkRaw/loop/impl=lua 1 340119086 ns/op
BenchmarkRaw/loop/impl=lua 1 410198185 ns/op
BenchmarkRaw/loop/impl=lua 1 413588562 ns/op
BenchmarkRaw/loop/impl=lua 1 420516147 ns/op
BenchmarkRaw/loop/impl=lua 1 431560275 ns/op
BenchmarkRaw/loop/impl=lua 1 415222645 ns/op
BenchmarkRaw/loop/impl=lua 1 429817425 ns/op
BenchmarkRaw/loop/impl=lua 1 412941278 ns/op
BenchmarkRaw/loop/impl=lua 1 435613977 ns/op
BenchmarkRaw/loop/impl=lua 1 407366188 ns/op
BenchmarkRaw/loop/impl=lua 1 354457519 ns/op
BenchmarkRaw/loop/impl=lua 1 429231728 ns/op
BenchmarkRaw/loop/impl=lua 1 519467350 ns/op
BenchmarkRaw/loop/impl=lua 1 504247711 ns/op
BenchmarkRaw/loop/impl=lua 1 431236000 ns/op
BenchmarkRaw/loop/impl=lua 1 579379640 ns/op
BenchmarkRaw/loop/impl=lua 1 338101477 ns/op
BenchmarkRaw/loop/impl=lua 1 418926541 ns/op
BenchmarkRaw/loop/impl=lua 1 464096139 ns/op
BenchmarkRaw/tab/impl=zig 1 274987424 ns/op
BenchmarkRaw/tab/impl=zig 1 227001856 ns/op
BenchmarkRaw/tab/impl=zig 1 263328550 ns/op
BenchmarkRaw/tab/impl=zig 1 278403352 ns/op
BenchmarkRaw/tab/impl=zig 1 251915490 ns/op
BenchmarkRaw/tab/impl=zig 1 293999069 ns/op
BenchmarkRaw/tab/impl=zig 1 264759162 ns/op
BenchmarkRaw/tab/impl=zig 1 280328271 ns/op
BenchmarkRaw/tab/impl=zig 1 282456777 ns/op
BenchmarkRaw/tab/impl=zig 1 269268574 ns/op
BenchmarkRaw/tab/impl=zig 1 256616650 ns/op
BenchmarkRaw/tab/impl=zig 1 228270413 ns/op
BenchmarkRaw/tab/impl=zig 1 299184500 ns/op
BenchmarkRaw/tab/impl=zig 1 225893946 ns/op
BenchmarkRaw/tab/impl=zig 1 338957194 ns/op
BenchmarkRaw/tab/impl=zig 1 276325206 ns/op
BenchmarkRaw/tab/impl=zig 1 321194877 ns/op
BenchmarkRaw/tab/impl=zig 1 233134131 ns/op
BenchmarkRaw/tab/impl=zig 1 271185836 ns/op
BenchmarkRaw/tab/impl=zig 1 273156726 ns/op
BenchmarkRaw/tab/impl=lua 1 264367280 ns/op
BenchmarkRaw/tab/impl=lua 1 226927347 ns/op
BenchmarkRaw/tab/impl=lua 1 243270072 ns/op
BenchmarkRaw/tab/impl=lua 1 261077239 ns/op
BenchmarkRaw/tab/impl=lua 1 251996308 ns/op
BenchmarkRaw/tab/impl=lua 1 268890946 ns/op
BenchmarkRaw/tab/impl=lua 1 251190049 ns/op
BenchmarkRaw/tab/impl=lua 1 271234366 ns/op
BenchmarkRaw/tab/impl=lua 1 278358611 ns/op
BenchmarkRaw/tab/impl=lua 1 249416472 ns/op
BenchmarkRaw/tab/impl=lua 1 243184171 ns/op
BenchmarkRaw/tab/impl=lua 1 217295514 ns/op
BenchmarkRaw/tab/impl=lua 1 325813351 ns/op
BenchmarkRaw/tab/impl=lua 1 228399665 ns/op
BenchmarkRaw/tab/impl=lua 1 370853563 ns/op
BenchmarkRaw/tab/impl=lua 1 274575212 ns/op
BenchmarkRaw/tab/impl=lua 1 267573197 ns/op
BenchmarkRaw/tab/impl=lua 1 251413159 ns/op
BenchmarkRaw/tab/impl=lua 1 258813103 ns/op
BenchmarkRaw/tab/impl=lua 1 273188579 ns/op
```

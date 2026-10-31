# lua bench

Lua programs that each stress one part of an implementation, timed on this package's `lua` and on reference C Lua 5.5.1.

These are local numbers, for iterating. They are not claims: a number that gets quoted in the README needs a run on dedicated hardware.

## Programs

Each program is plain Lua 5.5 with no modules. It takes one size argument, `lua bench/fib.lua 30`, and its default size runs for about 0.5 to 2 seconds on the reference. It prints a checksum: the same output from two implementations means they did the same work, so their times can be compared.

| Program         | Stresses                                                                                                     |
| --------------- | ------------------------------------------------------------------------------------------------------------ |
| `fib`           | Lua-to-Lua calls and returns: naive recursive Fibonacci                                                      |
| `binary_trees`  | table allocation and the collector: the benchmarks game's binary-trees                                       |
| `hash_string`   | the hash part with string keys: insert, hit, miss, delete                                                    |
| `hash_int`      | the hash part with sparse integer keys: insert, hit, miss, delete, `pairs`                                   |
| `array`         | the array part: fill by index and by `t[#t + 1]`, read with `ipairs` and a numeric `for`                     |
| `nbody`         | float arithmetic and field access: the benchmarks game's n-body                                              |
| `spectral_norm` | float arithmetic, calls, and array access: the benchmarks game's spectral-norm                               |
| `mandelbrot`    | float arithmetic and comparisons in locals                                                                   |
| `concat`        | the `..` operator on strings and numbers, in a loop                                                          |
| `table_concat`  | `table.concat` with and without a separator                                                                  |
| `format`        | `string.format`'s common conversions                                                                         |
| `patterns`      | `string.find`, `match`, `gsub`, and `gmatch` with patterns, captures, and replacements                       |
| `closures`      | closure creation, shared upvalues, per-iteration loop upvalues, nested upvalues                              |
| `methods`       | `obj:method()` through `__index` tables, a two-level `__index` chain, an `__index` function, `__add`, `__eq` |
| `coroutines`    | `coroutine.resume` and `yield` ping-pong, a `coroutine.wrap` generator, short-lived coroutines               |
| `globals`       | global variables and functions: every name a field of `_ENV`, as in code written without locals              |

## Arms

| Arm    | Binary                                                    |
| ------ | --------------------------------------------------------- |
| `ref`  | the dev shell's `lua`: reference C Lua 5.5.1 from nixpkgs |
| `ours` | `zig-out/bin/lua` from `zig build -Doptimize=ReleaseFast` |

`just optimize=ReleaseSafe bench-compare` builds our arm in another mode. Several modes, as in `just optimize="ReleaseFast ReleaseSafe" bench-compare`, give one arm each, named `ours-ReleaseFast` and `ours-ReleaseSafe`.

Until `build.zig` installs `zig-out/bin/lua`, `just bench-compare` says so and times the reference alone.

## Method

`just bench-compare [ROUNDS] [PROGRAMS...]` (default 10 rounds of every program) builds our arm, then runs ROUNDS rounds. A round runs each program on each arm once, in an arm order that rotates each round, so drift on the machine lands on every arm alike. Every run is pinned with `taskset` to the last core. A row is one run's wall time, from process start to exit, so it includes startup, a millisecond or so on both arms, and its peak resident memory (`ru_maxrss`, read with GNU time's `%M`) in KiB. benchstat compares both, as `sec/op` and `peak-RSS-KiB`: memory is held to the same bar as time.

Every run's output must match the reference's first run. A program whose output differs on an arm, or that exits with an error, loses that arm's rows, the differences are printed, and the recipe fails after the table. `benchstat` then compares the arms with the reference as the base. Everything lands in `zig-out/bench-compare/`: each run's output in `stdout/`, the raw rows, the per-arm benchstat input, and `benchstat.txt`.

`just bench-compare 20 fib nbody` runs only those programs, for a tighter A/B on one change.

## The embedding API

`bench/api/main.zig` is a Zig program, not a Lua one: it times calls through the embedding API (`lua.State`) against the same work written directly on the engine, as the standard library writes it. `just bench-api [ROUNDS] [SCENARIOS...]` runs both arms in interleaved rounds pinned to the last core, checks that they did the same work, and compares time per operation and peak RSS with benchstat.

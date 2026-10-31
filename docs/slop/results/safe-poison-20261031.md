# ReleaseSafe without the allocator's 0xAA fill, 2026-10-31

In safe builds `std.mem.Allocator`'s `alloc`, `create`, `realloc`, and
`free` write `undefined` (0xAA) over the whole block: after allocating
it, and before freeing it (`allocBytesWithAlignment`, `reallocAdvanced`,
and `free` in Zig 0.16's `std/mem/Allocator.zig`; `destroy` does not).
`release-safe-20261031.md` measured that as about half of ReleaseSafe's
cost and all of its extra peak memory, and in wave 6 `compiler_rt.memset`
was 14.7% of template and 8.5% of config in ReleaseSafe
(`bench-compare-wave6-20261031.md`), where template, config, and oop
were 7 to 11% slower than the reference.

## The change

`gc.Raw` wraps a counting allocator and offers the calls the object code
makes (`create`, `destroy`, `alloc`, `alignedAlloc`, `free`, `realloc`) on the vtable's `rawAlloc`, `rawRemap`, and `rawFree`, minus
the fill; Debug builds still write it. `Heap.raw()` and
`Heap.rawStrings()` hand it out. Every object and every block an object
owns goes through it:

- tables and their array and hash parts (`Table.create`, `resize`,
  `destroy`);
- strings and the interner's buckets; `auxlib.Buffer`'s heap block,
  which becomes a long string in place;
- closures, upvalues (closed and open), prototypes, userdata, threads
  and their stacks, and stack growth.

What still goes through the standard interface is what lives in a
standard container and grows by doubling: the compiler's lists and its
constant cache, a thread's frame and to-be-closed lists, and the
`std.Io.Writer.Allocating` that error messages and `load` use. The bytes
filled there are a constant factor of the container's final size, not a
cost per object.

`perf record` of the ReleaseSafe builds (one run each, 2 kHz),
`compiler_rt.memset`'s share of the samples:

| program  | before | after |
| -------- | -----: | ----: |
| template |  17.2% |  1.0% |
| config   |   8.5% |  2.8% |
| oop      |   2.0% |  0.1% |

What remains in config, from a frame-pointer build's call stacks: 39%
is `Table.resize` setting new nodes empty and new array tags nil, which
ReleaseFast does too, and the rest the compiler's containers (the
constant cache growing and freeing, the instruction and line lists).

## Measurements

Interleaved, pinned to the last core, 20 rounds of every `bench/`
program, wall time and peak RSS per process, benchstat. `base` is
`compiler: keep line info in luac's encoding` (5acde7b), `raw` this
change; `just bench-compare` with the base build first on `PATH` as
`lua`.

### ReleaseSafe

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
                  │     base    │                 raw                 │
                  │   sec/op    │   sec/op     vs base                │
Lua/array           852.4m ± 3%   680.7m ± 2%  -20.14% (p=0.000 n=20)
Lua/binary_trees    687.5m ± 2%   659.5m ± 2%   -4.07% (p=0.000 n=20)
Lua/closures        666.8m ± 1%   583.5m ± 1%  -12.50% (p=0.000 n=20)
Lua/concat          715.1m ± 2%   322.3m ± 3%  -54.92% (p=0.000 n=20)
Lua/config          569.7m ± 1%   530.5m ± 1%   -6.89% (p=0.000 n=20)
Lua/coroutines      444.1m ± 4%   382.1m ± 2%  -13.97% (p=0.000 n=20)
Lua/fib             446.8m ± 1%   445.4m ± 1%        ~ (p=0.758 n=20)
Lua/format          426.5m ± 2%   380.0m ± 2%  -10.89% (p=0.000 n=20)
Lua/globals         575.4m ± 2%   583.3m ± 1%        ~ (p=0.231 n=20)
Lua/hash_int        616.5m ± 3%   559.8m ± 1%   -9.19% (p=0.000 n=20)
Lua/hash_string     584.2m ± 2%   544.5m ± 2%   -6.80% (p=0.000 n=20)
Lua/json            547.0m ± 2%   527.0m ± 3%   -3.65% (p=0.002 n=20)
Lua/mandelbrot      377.3m ± 2%   381.8m ± 2%        ~ (p=0.056 n=20)
Lua/methods         611.7m ± 4%   587.7m ± 2%   -3.92% (p=0.001 n=20)
Lua/nbody           580.9m ± 3%   586.3m ± 2%        ~ (p=0.583 n=20)
Lua/oop             652.6m ± 2%   637.4m ± 2%        ~ (p=0.063 n=20)
Lua/patterns        512.9m ± 1%   501.8m ± 1%   -2.15% (p=0.002 n=20)
Lua/spectral_norm   603.2m ± 4%   605.9m ± 1%        ~ (p=0.925 n=20)
Lua/table_concat    413.2m ± 4%   318.3m ± 3%  -22.96% (p=0.000 n=20)
Lua/template        622.5m ± 2%   519.7m ± 1%  -16.52% (p=0.000 n=20)
geomean             564.1m        504.6m       -10.54%

                  │     base     │                 raw                  │
                  │ peak-RSS-KiB │ peak-RSS-KiB  vs base                │
Lua/array            29.36k ± 0%    21.30k ± 0%  -27.44% (p=0.000 n=20)
Lua/binary_trees     26.73k ± 0%    26.75k ± 0%   +0.07% (p=0.000 n=20)
Lua/closures         2.372k ± 0%    2.376k ± 0%        ~ (p=0.184 n=20)
Lua/concat           2.372k ± 0%    2.372k ± 0%        ~ (p=0.875 n=20)
Lua/config           11.85k ± 0%    11.79k ± 0%   -0.51% (p=0.000 n=20)
Lua/coroutines       2.372k ± 0%    2.372k ± 0%        ~ (p=0.469 n=20)
Lua/fib              2.372k ± 0%    2.372k ± 0%        ~ (p=0.826 n=20)
Lua/format           2.372k ± 0%    2.376k ± 0%        ~ (p=0.093 n=20)
Lua/globals          2.372k ± 0%    2.372k ± 0%        ~ (p=0.766 n=20)
Lua/hash_int         6.364k ± 0%    6.364k ± 0%        ~ (p=0.065 n=20)
Lua/hash_string      23.20k ± 0%    22.72k ± 0%   -2.07% (p=0.000 n=20)
Lua/json             12.32k ± 0%    10.78k ± 0%  -12.44% (p=0.000 n=20)
Lua/mandelbrot       2.372k ± 0%    2.372k ± 0%        ~ (p=0.952 n=20)
Lua/methods          2.372k ± 0%    2.372k ± 0%        ~ (p=0.960 n=20)
Lua/nbody            2.372k ± 0%    2.372k ± 0%        ~ (p=0.807 n=20)
Lua/oop             10.060k ± 0%    9.812k ± 0%   -2.47% (p=0.000 n=20)
Lua/patterns         9.380k ± 0%    9.328k ± 0%   -0.55% (p=0.000 n=20)
Lua/spectral_norm    2.372k ± 0%    2.372k ± 0%        ~ (p=0.499 n=20)
Lua/table_concat     30.84k ± 0%    23.44k ± 0%  -23.99% (p=0.000 n=20)
Lua/template         2.372k ± 0%    2.372k ± 0%        ~ (p=0.995 n=20)
geomean              5.507k         5.296k        -3.83%
```

ReleaseSafe is 10.5% faster on the geomean and peaks 3.8% lower. The
programs that allocate and free the most gain the most: concat −55%,
table_concat −23%, array −20%, template −17%, coroutines −14%, closures
−13%, format −11%, hash_int −9%, config and hash_string −7%. The
loop-bound ones are level (fib, mandelbrot, nbody, spectral_norm,
globals, and oop, whose ReleaseSafe cost is the loop's own checks).
Peak RSS falls where the fill touched pages a program never used:
array −27%, table_concat −24% (a big array part's unused capacity),
json −12%, oop −2.5%, hash_string −2.1%; nothing peaks higher
(binary_trees +0.07%).

### ReleaseFast

The fill is compiled out of ReleaseFast, so the change should not show
there. Both instances of `vm.runLoop` are the base's instruction for
instruction (`objdump -d`, addresses masked; 0x7dee and 0xa046 bytes).
What differs is a few bytes in `Table.resize`, `Thread.reallocStack`,
`Buffer.ensureUnused`, the interner's `resize`, and library functions
that inline a `Buffer`, and the addresses of what follows them.

A first version built `Raw.create` on `alloc(T, 1)` and `destroy` on
`free`. That changed the loop (0x7d33 bytes, through the inlined
`Table.create` and `LuaClosure.create`), and its ReleaseFast A/B moved
programs both ways by layout: nbody +7.8%, concat +3.6%, template
+3.5%, fib −3.0%, globals −3.4%, geomean +0.6%. `create` and `destroy`
now call `rawAlloc` and `rawFree` directly, as the standard ones do, and
the loop came back byte for byte.

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
                  │     base    │                raw                 │
                  │   sec/op    │   sec/op     vs base               │
Lua/array           681.6m ± 1%   679.5m ± 1%       ~ (p=0.414 n=20)
Lua/binary_trees    526.4m ± 2%   523.2m ± 5%       ~ (p=0.602 n=20)
Lua/closures        441.7m ± 2%   442.2m ± 2%       ~ (p=0.925 n=20)
Lua/concat          269.4m ± 3%   271.3m ± 2%       ~ (p=0.445 n=20)
Lua/config          462.0m ± 1%   460.2m ± 2%       ~ (p=0.402 n=20)
Lua/coroutines      333.1m ± 2%   331.3m ± 2%       ~ (p=0.277 n=20)
Lua/fib             419.3m ± 1%   421.1m ± 2%       ~ (p=0.602 n=20)
Lua/format          307.7m ± 2%   307.3m ± 1%       ~ (p=0.547 n=20)
Lua/globals         455.2m ± 3%   460.0m ± 1%       ~ (p=0.718 n=20)
Lua/hash_int        495.7m ± 2%   494.2m ± 2%       ~ (p=0.904 n=20)
Lua/hash_string     515.3m ± 2%   521.6m ± 3%       ~ (p=0.478 n=20)
Lua/json            455.7m ± 2%   452.7m ± 3%       ~ (p=0.583 n=20)
Lua/mandelbrot      373.2m ± 1%   373.2m ± 1%       ~ (p=0.841 n=20)
Lua/methods         474.7m ± 2%   478.9m ± 4%       ~ (p=0.445 n=20)
Lua/nbody           558.5m ± 4%   568.8m ± 4%       ~ (p=0.231 n=20)
Lua/oop             560.3m ± 2%   561.3m ± 4%       ~ (p=0.565 n=20)
Lua/patterns        473.0m ± 2%   471.9m ± 2%       ~ (p=0.883 n=20)
Lua/spectral_norm   572.3m ± 1%   571.9m ± 1%       ~ (p=0.968 n=20)
Lua/table_concat    263.6m ± 3%   263.3m ± 3%       ~ (p=0.947 n=20)
Lua/template        454.5m ± 3%   453.4m ± 2%       ~ (p=0.369 n=20)
geomean             441.9m        442.5m       +0.14%

                  │     base     │                 raw                 │
                  │ peak-RSS-KiB │ peak-RSS-KiB  vs base               │
Lua/array            20.97k ± 0%    20.98k ± 0%  +0.02% (p=0.000 n=20)
Lua/binary_trees     26.41k ± 0%    26.44k ± 0%  +0.09% (p=0.000 n=20)
Lua/closures         2.372k ± 0%    2.372k ± 0%       ~ (p=0.370 n=20)
Lua/concat           2.372k ± 0%    2.374k ± 0%       ~ (p=0.220 n=20)
Lua/config           11.46k ± 0%    11.46k ± 0%       ~ (p=1.000 n=20)
Lua/coroutines       2.372k ± 0%    2.372k ± 0%       ~ (p=0.967 n=20)
Lua/fib              2.372k ± 0%    2.372k ± 0%       ~ (p=0.324 n=20)
Lua/format           2.372k ± 0%    2.372k ± 0%       ~ (p=0.998 n=20)
Lua/globals          2.376k ± 0%    2.372k ± 0%       ~ (p=0.122 n=20)
Lua/hash_int         6.044k ± 0%    6.048k ± 0%  +0.07% (p=0.000 n=20)
Lua/hash_string      22.40k ± 0%    22.40k ± 0%  +0.02% (p=0.000 n=20)
Lua/json             10.46k ± 0%    10.46k ± 0%  +0.04% (p=0.000 n=20)
Lua/mandelbrot       2.372k ± 0%    2.372k ± 0%       ~ (p=0.135 n=20)
Lua/methods          2.372k ± 0%    2.372k ± 0%       ~ (p=0.270 n=20)
Lua/nbody            2.372k ± 0%    2.372k ± 0%       ~ (p=1.000 n=20)
Lua/oop              9.456k ± 0%    9.496k ± 0%  +0.42% (p=0.001 n=20)
Lua/patterns         9.004k ± 0%    9.004k ± 0%       ~ (p=0.301 n=20)
Lua/spectral_norm    2.376k ± 0%    2.372k ± 0%       ~ (p=0.199 n=20)
Lua/table_concat     23.12k ± 0%    23.12k ± 0%   0.00% (p=0.000 n=20)
Lua/template         2.372k ± 0%    2.372k ± 0%       ~ (p=0.126 n=20)
geomean              5.233k         5.234k       +0.02%
```

Every program is level in time (geomean +0.14%) and in peak RSS
(within 0.1%, oop +0.4%: 9,456 against 9,496 KiB, where the base ran
9,492 to 9,536 KiB in the other runs today).

## Is any safety lost?

What a safe build checks is unchanged: bounds, integer overflow,
`unreachable`, null unwraps, invalid tags and enum values, alignment.
The fill is not one of those checks. Reading memory that was just
allocated, or that was freed, is illegal behavior Zig does not detect at
run time; the fill only makes such a read return 0xAA, which then tends
to trip one of the checks (an invalid tag, a wild pointer). It is a
probabilistic detector of our own bugs, and only until the allocator
hands the block to someone else, after which a stale read sees valid
data with or without it. So the question is whether the engine ever
reads memory it has not written or has freed, on the paths `Raw` now
serves. It does not, by these invariants:

1. **Every object is written whole before anything can reach it.**
   Each constructor assigns the struct (`t.* = .{...}`, `p.* = .{...}`,
   `uv.* = .{...}`) before linking it into `allgc` or returning it.
   The parts are filled when allocated: a table's new hash nodes are set
   to `Node.empty` and its new array slots' tags to nil; a string's
   header, hash, length, and trailing zero are written by `init` and its
   bytes copied in (or written by `Sized`, `createLong`'s callers, and
   `Buffer`, which track how much they wrote); a native closure's
   upvalues and a userdata's user values are set to nil; a thread's
   stack, and every slot stack growth adds, are set to nil; the
   interner's buckets to null. Two parts are left for the caller, as in
   the reference: a Lua closure's upvalue pointers, which `CLOSURE` and
   `vm.mainClosure` fill before the next instruction, and a userdata's
   payload, which `lua_newuserdatauv` also leaves undefined and each
   library fills before use. An array slot whose tag is nil keeps an
   undefined payload, which nothing reads: `rawEquals`, marking, and
   hashing look at the tag first and never at a nil's payload.
2. **The collector never sees an object half built.** It runs only at
   safe points (`State.checkGc`) and on request, never inside an
   allocation (`gc.zig`'s header), so nothing can traverse a closure
   between its allocation and the filling of its upvalues.
3. **Nothing is freed while reachable, and nothing reads it after.**
   Only the sweep frees objects, those left white after the atomic
   phase, and it unlinks each from its list before freeing it. Weak
   tables drop dead keys and values in the atomic phase, before the
   sweep; `freeObject` takes a short string out of the interner before
   freeing it; `Upval.destroy` unlinks an open upvalue from its thread;
   a table's parts are freed with it, a thread's stack with it; a stack
   that moves repoints its open upvalues (`reallocStack`); a resized
   table copies its old parts before freeing them. These are lgc.c's
   rules, ported function by function.

The evidence, all on this change:

- **Debug builds still fill**, so the detector the fill was still runs
  on every `Raw` path there. Under a Debug build with the collector
  stressed in full (`zig build -Dgc-stress=full`, a full collection at
  every safe point), every suite file passes alone and `all.lua` passes,
  in generational mode (the default) and in incremental mode
  (`LUA_INIT="collectgarbage('incremental')"`). Under `-Dgc-stress=step`
  (one incremental step at every safe point) every file passes alone in
  incremental mode, and every file but `db.lua` in generational mode,
  where `db.lua` spins at its finalizer test as `gc.md` records.
  `zig build test` runs the unit tests in Debug and ReleaseSafe on
  `std.testing.allocator`, whose double-free, leak, and size checks sit
  behind the vtable `Raw` calls.
- **ReleaseSafe with the collector stressed**, the same runs: under
  `full`, every file alone and `all.lua` pass in both modes; under
  `step`, every file alone in incremental mode and every file but
  `db.lua` in generational mode. `all.lua` under `step` does not finish
  in either mode within 5 minutes: it stops at `db.lua` in generational
  mode, and at `closure.lua`'s `while x[1]` wait for a collection in
  incremental mode, where the base build (5acde7b) stops too (killed
  after 8 minutes). That is the step stress's pace on all.lua's heap,
  not this change.
- The unstressed gates: `just ci`, `all.lua`, every suite file,
  `just diff`, `just bytecode`, `just dump`, and `just bench-api`.

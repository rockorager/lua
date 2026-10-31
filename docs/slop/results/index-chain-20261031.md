# Inherited method lookups without the repeated lookups, 2026-10-31

Not landed. bench/oop.lua (new in wave 6) beats the reference by only
6%, and bench/methods.lua by 11%. In `perf`, oop spends 82% in the
interpreter loop, 9.7% in `Table.get`, and 4.6% in `vm.getSlow`; the
reference spends 39% in `luaH_getshortstr`. Most of the last two are
methods inherited through two or more `__index` tables: `self:die()`
on a `Prey` looks in the object, `Prey`, `Mover`, then `Entity`.

`GETFIELD` and `SELF` look in the object and, when its `__index` is a
table, in that class table inline. When both miss, `getSlow` starts
the chain over from the object, so it looks the key up in the object
and in the class a second time before it reaches the base class.
lvm.c's `luaV_finishget` starts from the object's metatable, because
its caller passes the failed lookup along.

## Variant A: the callers say they missed

`getSlow` takes `missed: bool` and skips the first table's lookup when
it is set; every caller in the loop passes it (`gettable` only for
integer and short string keys), and `GETFIELD`/`SELF` continue from the
class table after their inline miss, skipping both repeats. The loop's
machine code changes. Base is the parser change before it; 10 rounds of
every program, then 20 of five:

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
                  │    base     │               index                │
                  │   sec/op    │   sec/op     vs base               │
Lua/array           886.2m ± 3%   873.1m ± 4%       ~ (p=0.739 n=10)
Lua/binary_trees    683.8m ± 3%   688.5m ± 4%       ~ (p=0.631 n=10)
Lua/closures        627.6m ± 5%   634.5m ± 2%       ~ (p=0.393 n=10)
Lua/concat          375.3m ± 4%   371.6m ± 3%       ~ (p=0.143 n=10)
Lua/config          594.4m ± 3%   598.2m ± 2%       ~ (p=0.436 n=10)
Lua/coroutines      455.7m ± 4%   453.7m ± 3%       ~ (p=0.315 n=10)
Lua/fib             562.7m ± 2%   569.0m ± 2%  +1.12% (p=0.019 n=10)
Lua/format          450.3m ± 9%   456.8m ± 4%       ~ (p=0.075 n=10)
Lua/globals         638.0m ± 2%   650.5m ± 2%  +1.97% (p=0.007 n=10)
Lua/hash_int        465.5m ± 1%   472.6m ± 2%       ~ (p=0.105 n=10)
Lua/hash_string     434.2m ± 3%   435.5m ± 2%       ~ (p=0.739 n=10)
Lua/json            594.1m ± 1%   615.3m ± 7%  +3.57% (p=0.000 n=10)
Lua/mandelbrot      530.3m ± 3%   540.1m ± 2%       ~ (p=0.063 n=10)
Lua/methods         660.7m ± 2%   620.8m ± 5%  -6.04% (p=0.000 n=10)
Lua/nbody           756.6m ± 9%   765.7m ± 2%       ~ (p=0.579 n=10)
Lua/oop             696.7m ± 3%   672.5m ± 3%  -3.47% (p=0.000 n=10)
Lua/patterns        650.4m ± 7%   643.3m ± 5%       ~ (p=0.218 n=10)
Lua/spectral_norm   800.3m ± 5%   806.3m ± 2%       ~ (p=0.796 n=10)
Lua/table_concat    325.1m ± 4%   325.8m ± 5%       ~ (p=0.971 n=10)
Lua/template        652.5m ± 7%   646.1m ± 5%       ~ (p=0.190 n=10)
geomean             574.5m        574.9m       +0.07%
```

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
            │    base     │               index                │
            │   sec/op    │   sec/op     vs base               │
Lua/json      611.5m ± 8%   640.6m ± 4%       ~ (p=0.056 n=20)
Lua/globals   639.0m ± 3%   674.3m ± 2%  +5.51% (p=0.001 n=20)
Lua/fib       576.4m ± 2%   573.9m ± 4%       ~ (p=0.445 n=20)
Lua/methods   664.4m ± 3%   622.6m ± 3%  -6.28% (p=0.000 n=20)
Lua/oop       661.2m ± 4%   680.5m ± 3%  +2.92% (p=0.017 n=20)
geomean       629.6m        637.2m       +1.20%
```

methods is 6.0% and 6.3% faster in both runs. oop moved −3.5%, then
+2.9%; globals +2.0%, then +5.5%; json +3.6%, then +4.8% (p=0.056).
None of globals, json, or fib reaches `getSlow` on an inherited key:
that is the loop's register allocation moving with any edit, the
plan's ±5%, and it is as large as the gain.

## Variant B: the loop stays the same

`getSlow` alone decides: called from the loop (`caller == .vm`) with an
integer or short string key, the first table has already missed. The
call sites do not change, and `vm.runLoop` is byte for byte the same
apart from call targets, so this measures the saved lookup alone. It
saves only the object's repeat, not the class's, because `GETFIELD`
still restarts from the object.

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
                  │    base     │               index                │
                  │   sec/op    │   sec/op     vs base               │
Lua/array           881.1m ± 2%   868.0m ± 2%       ~ (p=0.165 n=10)
Lua/binary_trees    687.9m ± 4%   683.8m ± 1%       ~ (p=0.353 n=10)
Lua/closures        622.8m ± 2%   632.1m ± 3%       ~ (p=0.089 n=10)
Lua/concat          377.7m ± 4%   372.2m ± 5%       ~ (p=0.579 n=10)
Lua/config          596.7m ± 6%   595.9m ± 3%       ~ (p=0.971 n=10)
Lua/coroutines      458.4m ± 7%   459.2m ± 3%       ~ (p=1.000 n=10)
Lua/fib             562.7m ± 3%   564.9m ± 5%       ~ (p=0.481 n=10)
Lua/format          455.2m ± 3%   459.9m ± 3%       ~ (p=0.315 n=10)
Lua/globals         648.1m ± 3%   652.8m ± 2%       ~ (p=0.796 n=10)
Lua/hash_int        466.5m ± 7%   476.9m ± 5%       ~ (p=0.315 n=10)
Lua/hash_string     438.9m ± 3%   441.6m ± 6%       ~ (p=0.393 n=10)
Lua/json            606.5m ± 5%   624.6m ± 4%       ~ (p=0.315 n=10)
Lua/mandelbrot      535.2m ± 6%   537.4m ± 3%       ~ (p=0.912 n=10)
Lua/methods         656.0m ± 6%   644.8m ± 4%  -1.71% (p=0.019 n=10)
Lua/nbody           747.9m ± 6%   765.2m ± 3%  +2.32% (p=0.029 n=10)
Lua/oop             684.3m ± 3%   683.2m ± 5%       ~ (p=0.853 n=10)
Lua/patterns        647.2m ± 4%   648.3m ± 1%       ~ (p=0.912 n=10)
Lua/spectral_norm   808.6m ± 3%   800.8m ± 2%       ~ (p=0.247 n=10)
Lua/table_concat    329.4m ± 2%   326.2m ± 5%       ~ (p=0.912 n=10)
Lua/template        651.7m ± 4%   654.1m ± 2%       ~ (p=0.912 n=10)
geomean             576.1m        577.6m       +0.26%
```

methods −1.7%, oop level, nbody +2.3%, geomean +0.26%.

## Verdict

The repeats cost real work, but variant B's saving is within the noise
and variant A's comes with loop layout swings as large as itself, so
neither lands. Variant A's shape is the right one when the loop next
changes for another reason, measured with that change: pass the miss to
`getSlow` and continue from the class table. Both variants passed the
unit tests and all.lua; variant A's first draft, which kept skipping
past a userdata's `__index` table, failed `api_test`'s userdata test.

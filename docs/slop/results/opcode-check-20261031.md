# Invalid opcodes: rejected by the loader, unchecked in dispatch, 2026-10-31

`release-safe-20261031.md` left one per-instruction check in the safe
build's interpreter loop, the test that the opcode is one of the set,
because it could fire: `undump.zig` copied a binary chunk's instructions
without looking at them. A corrupted chunk loaded, and running it
panicked a ReleaseSafe build ("invalid enum value", `vm.zig:310`) and was
undefined behavior in ReleaseFast, which jumps through an 85-entry table
with a value up to 127. Reference Lua 5.5.1 is the same: it loads the
chunk and crashes when it runs.

## The loader

`undump.zig` now checks every instruction of every function as it reads
the code: an opcode field (the low 7 bits) of 85 or more fails with the
reference's message form, "name: bad binary format (invalid opcode)".
`lundump.c` has no such message, since it checks nothing; the name
follows its others ("truncated chunk", "invalid constant", "invalid
string index"). The check is one compare per instruction at load time.

```
$ cat badop2.lua
local d = string.dump(function(a) return a + 1 end)
local bad = d:sub(1, 48) .. string.char((d:byte(49) & 0x80) | 0x7f) .. d:sub(50)
local g, err = load(bad)
print(g, err)
if g then print(pcall(g, 1)) end

base ReleaseSafe:  function: 0x7fc333790480  nil
                   thread 19814 panic: invalid enum value
now:               nil  binary string: bad binary format (invalid opcode)
reference lua:     function: 0x5555555a8860  nil      (and dies running it)
```

`undump.zig`'s test of bad chunks corrupts the first instruction of the
golden chunk's main function and of its nested function to 85 and to 127,
keeping the A operand's bit, and expects the message; 84 (`EXTRAARG`)
still loads. Without the loader's check that test fails. `just dump`
stays at 100 of 100.

Operands are still not verified, as in the reference: a chunk with a
register or constant index out of range loads and is undefined behavior
when it runs. The embedding API's `load` already says binary chunks must
come from trusted sources.

## The dispatch check can no longer fire

Every instruction the loop runs is in some `Proto.code`, and there are
three writers of that array:

1. The compiler: `Parser.zig` takes `FuncState.insts`, which only
   `FuncState.code` appends to. Every call of it passes an encoder's
   result, `opcodes.abc`, `vabc`, `abx`, `asbx`, `iax`, or `isj`, each of
   which takes an `OpCode`, except `Parser.zig`'s `fs.code(0)`, a `MOVE`
   placeholder later overwritten with `iax(.extraarg, …)`. In-place
   patches go through `setOp(OpCode)` or the field setters `setA`
   (`<< 7`), `setK` (`<< 15`), `setB` (`<< 16`), `setC` (`<< 24`), and
   `setBx` (keeps the low 15 bits), none of which touches bits 0 to 6,
   and `fixJump` and `NEWTABLE`'s fixup write encoder results.
2. `undump.zig`, which now rejects any other opcode.
3. `vm.zig`'s unit tests, which build protos from the same encoders.

Nothing modifies a prototype's code afterwards (the debug library, hooks,
and `string.dump` read it). So every word that reaches `fetch` has an
opcode below 85, and the check is dead.

## Removing it

The check is not `@enumFromInt`'s: it is the safe build's guard on a
`switch` over an exhaustive enum ("switch on corrupt value"), emitted at
every `continue :dispatch` (146 and 145 sites in the two instances of the
loop, a `cmp $0x55` and `jae` before each indirect jump). In a test
object file, `@setRuntimeSafety(false)` in a block around the `continue`
does not remove it; the switch's own scope decides, and turning safety
off there would drop every check in every prong.

What does remove it: the loop switches on `Dispatch`, a non-exhaustive
copy of `OpCode` built with `@Enum` from `OpCode`'s tag names, so the
names, the numbering, and the inline prongs stay as they were, with a
`_` prong that is an unchecked `unreachable`. LLVM then builds the jump
table without a range check. The two prongs that capture the opcode
convert it back for `arithOf` at compile time.

In the ReleaseSafe `lua`, the loop's `cmp $0x55` sites go from 146 and 145
to 2 and 2, and the two instances shrink from 47,925 and 35,593 bytes to
45,940 and 35,021. In ReleaseFast, which never checked, both instances
disassemble identically before and after.

## Measurements

Interleaved, pinned to the last core, benchstat, wall time and peak RSS
per process. `val` is the loader check and the `Buffer` change of
`buffer-init-20261031.md`; `op` is `val` plus the unchecked dispatch.

ReleaseSafe, 10 rounds of every program:

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
                  │   val-safe    │               op-safe                │
                  │    sec/op     │    sec/op     vs base                │
Lua/array           1037.5m ± 13%   978.1m ± 17%   -5.72% (p=0.009 n=10)
Lua/binary_trees     808.0m ± 16%   803.2m ± 16%        ~ (p=0.971 n=10)
Lua/closures         796.9m ± 21%   763.0m ± 14%        ~ (p=0.315 n=10)
Lua/concat           835.9m ± 16%   867.7m ±  5%        ~ (p=0.393 n=10)
Lua/coroutines       544.3m ± 11%   534.8m ± 11%        ~ (p=0.247 n=10)
Lua/fib              597.2m ± 16%   462.6m ± 16%  -22.54% (p=0.003 n=10)
Lua/format           505.5m ± 15%   475.5m ±  8%        ~ (p=0.123 n=10)
Lua/globals          730.7m ± 17%   672.3m ± 20%   -7.99% (p=0.035 n=10)
Lua/hash_int         673.0m ±  9%   665.4m ± 16%        ~ (p=0.796 n=10)
Lua/hash_string      617.3m ±  6%   603.2m ± 11%        ~ (p=0.529 n=10)
Lua/mandelbrot       501.3m ± 12%   452.5m ± 12%        ~ (p=0.105 n=10)
Lua/methods          769.7m ± 17%   711.0m ± 19%        ~ (p=0.143 n=10)
Lua/nbody            704.1m ± 12%   707.0m ± 14%        ~ (p=0.912 n=10)
Lua/patterns         612.3m ±  6%   634.1m ±  5%        ~ (p=0.190 n=10)
Lua/spectral_norm    745.3m ± 15%   722.1m ± 11%        ~ (p=0.315 n=10)
Lua/table_concat     447.5m ± 18%   492.1m ± 15%        ~ (p=0.481 n=10)
geomean              667.3m         642.7m         -3.69%

                  │   val-safe   │                op-safe                │
                  │ peak-RSS-KiB │ peak-RSS-KiB  vs base                 │
Lua/array            29.34k ± 0%    29.34k ± 0%  +0.01% (p=0.000 n=10)
Lua/binary_trees     26.89k ± 0%    26.90k ± 0%  +0.01% (p=0.000 n=10)
Lua/closures         2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/concat           2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/coroutines       2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/fib              2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/format           2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/globals          2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/hash_int         6.348k ± 0%    6.352k ± 0%  +0.06% (p=0.000 n=10)
Lua/hash_string      23.18k ± 0%    23.19k ± 0%  +0.02% (p=0.000 n=10)
Lua/mandelbrot       2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/methods          2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/nbody            2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/patterns         9.360k ± 0%    9.364k ± 0%  +0.04% (p=0.000 n=10)
Lua/spectral_norm    2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/table_concat     30.82k ± 0%    30.82k ± 0%  +0.01% (p=0.000 n=10)
geomean              5.056k         5.057k       +0.01%
¹ all samples are equal
```

ReleaseSafe again, 20 rounds of the programs that are mostly dispatch:

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
                  │   val-safe   │               op-safe                │
                  │    sec/op    │    sec/op     vs base                │
Lua/fib             560.3m ±  8%   491.1m ± 10%  -12.35% (p=0.002 n=20)
Lua/mandelbrot      475.9m ± 12%   444.1m ± 11%   -6.66% (p=0.008 n=20)
Lua/globals         685.4m ± 11%   649.6m ±  9%   -5.23% (p=0.010 n=20)
Lua/spectral_norm   750.1m ± 11%   674.4m ± 12%  -10.10% (p=0.003 n=20)
geomean             608.5m         556.0m         -8.63%

                  │   val-safe   │                op-safe                │
                  │ peak-RSS-KiB │ peak-RSS-KiB  vs base                 │
Lua/fib              2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=20) ¹
Lua/mandelbrot       2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=20) ¹
Lua/globals          2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=20) ¹
Lua/spectral_norm    2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=20) ¹
geomean              2.364k         2.364k       +0.00%
¹ all samples are equal
```

ReleaseFast, base f55ff31 against `op` (the loop is byte for byte the
same, so this measures the loader and `Buffer` changes):

```
cpu: Intel(R) Xeon(R) Processor @ 2.60GHz
                  │  base-fast   │               op-fast               │
                  │    sec/op    │    sec/op     vs base               │
Lua/array           787.2m ± 16%   763.6m ± 13%       ~ (p=0.853 n=10)
Lua/binary_trees    607.7m ±  6%   586.2m ±  8%  -3.54% (p=0.043 n=10)
Lua/closures        533.7m ± 21%   528.0m ± 19%       ~ (p=0.912 n=10)
Lua/concat          333.6m ± 13%   323.1m ±  5%       ~ (p=0.739 n=10)
Lua/coroutines      399.4m ± 10%   410.7m ± 10%       ~ (p=0.579 n=10)
Lua/fib             476.6m ± 16%   481.9m ± 13%       ~ (p=0.631 n=10)
Lua/format          366.7m ± 14%   370.1m ± 14%       ~ (p=0.579 n=10)
Lua/globals         550.9m ± 19%   494.5m ± 13%       ~ (p=0.280 n=10)
Lua/hash_int        562.2m ± 24%   507.9m ± 14%       ~ (p=0.218 n=10)
Lua/hash_string     507.2m ± 11%   488.7m ± 13%       ~ (p=0.481 n=10)
Lua/mandelbrot      466.1m ± 16%   468.0m ±  8%       ~ (p=0.481 n=10)
Lua/methods         565.7m ± 11%   580.9m ± 19%       ~ (p=0.529 n=10)
Lua/nbody           651.3m ± 12%   659.0m ± 11%       ~ (p=0.579 n=10)
Lua/patterns        568.5m ± 16%   577.1m ± 18%       ~ (p=0.529 n=10)
Lua/spectral_norm   658.4m ± 12%   656.5m ± 12%       ~ (p=0.739 n=10)
Lua/table_concat    301.4m ± 20%   252.7m ± 25%       ~ (p=0.529 n=10)
geomean             505.3m         492.0m        -2.65%

                  │  base-fast   │                op-fast                │
                  │ peak-RSS-KiB │ peak-RSS-KiB  vs base                 │
Lua/array            20.93k ± 0%    20.93k ± 0%       ~ (p=1.000 n=10) ¹
Lua/binary_trees     26.60k ± 0%    26.60k ± 0%       ~ (p=1.000 n=10) ¹
Lua/closures         2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/concat           2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/coroutines       2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/fib              2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/format           2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/globals          2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/hash_int         6.000k ± 0%    6.000k ± 0%       ~ (p=1.000 n=10) ¹
Lua/hash_string      22.38k ± 0%    22.38k ± 0%       ~ (p=1.000 n=10) ¹
Lua/mandelbrot       2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/methods          2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/nbody            2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/patterns         9.044k ± 0%    9.044k ± 0%       ~ (p=1.000 n=10) ¹
Lua/spectral_norm    2.364k ± 0%    2.364k ± 0%       ~ (p=1.000 n=10) ¹
Lua/table_concat     23.10k ± 0%    23.10k ± 0%       ~ (p=1.000 n=10) ¹
geomean              4.821k         4.821k       +0.00%
¹ all samples are equal
```

## Decision

Drop the check. It cannot fire (the argument above), it costs safe
builds 5 to 12% on the programs that are mostly dispatch (fib −12.4%,
spectral_norm −10.1%, mandelbrot −6.7%, globals −5.2% over 20 rounds;
fib is then as fast as the ReleaseFast build), peak memory is unchanged,
and ReleaseFast is untouched. The loader's check is what keeps it sound:
an instruction source added later must validate its opcodes the same
way, and `Dispatch`'s comment says so.

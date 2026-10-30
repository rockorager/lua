# Standard libraries without the parser

`lib/string.zig`, `lib/table.zig`, `lib/math.zig`, and `lib/utf8.zig`, with
`lib/auxlib.zig` (what lauxlib.c and the lapi.c calls give the reference's
libraries) and `lib/libm.zig` (glibc's `exp`, `pow`, `log`, `log2`, and
`log10`). Each library has `pub fn open(state: *State) Value.Error!void`,
which builds its table and sets it as a global; `init.zig` calls them.

## What each covers

- **string**: all of §6.5. `byte`, `char`, `find`, `format`, `gmatch` (with
  the init argument), `gsub` (string, table, and function replacements, `%0`
  to `%9`, "invalid replacement value", "invalid use of '%' in replacement
  string"), `len`, `lower`, `match`, `pack`, `packsize`, `rep` (separator,
  "resulting string too large"), `reverse`, `sub`, `unpack`, `upper`. `dump`
  writes luac's binary format through `dump.zig` (see `dump.md`). `open` sets the string metatable: `__index` is the
  library, and `__add`, `__sub`, `__mul`, `__mod`, `__pow`, `__div`, `__idiv`,
  and `__unm` convert strings as lstrlib.c's `trymt`/`tonum` do, with its
  "attempt to add a 'string' with a 'table'" messages. Bitwise operators on
  strings are not metamethods in 5.5; the VM converts them.
- **table**: `concat`, `create` (5.5), `insert`, `move`, `pack`, `remove`,
  `sort`, `unpack`. Element access goes through `__index`, `__newindex`, and
  `__len` as ltablib.c's `aux_getn`/`checktab` do, with raw fast paths for
  plain tables. `sort` is ltablib.c's quicksort, pivot choice included, so
  "invalid order function for sorting" fires on the same inputs and a
  comparator sees the same calls (1644 and 1591 comparisons for the test's
  200-element arrays, as the reference counts).
- **math**: all of §6.7. `random` and `randomseed` are lmathlib.c's xoshiro256**
  with its seeding and its `project` for ranges, so `math.randomseed(n)`
  gives the reference's sequence bit for bit. `randomseed()` with no argument
  mixes addresses and the state's hash seed instead of the time. `fmod` follows
  its integer rules ("bad argument #2 to 'fmod' (zero)", `mininteger % -1`).
  `floor`, `ceil`, `tointeger`, `ult`, `abs`, `min`, `max`, `type`,
  `mininteger`, `maxinteger`, `huge`, `pi`.
- **utf8**: `char`, `charpattern`, `codes` (with `lax`, and "invalid UTF-8
  code" where the reference raises it), `codepoint`, `len` (returning fail and
  the position), `offset` with 5.5's second result, the end of the character.

## Floating point

The reference's math functions are glibc's. `libm.zig` ports glibc 2.44's
`exp`, `pow`, `log`, `log2` (Arm optimized-routines), and `log10` (fdlibm,
calling `log`), with their tables. glibc runs a variant built with `-mfma` on
CPUs with FMA, and GCC contracts `a * b + c` there, including into every use of
a product whose uses are all additions; `mad` reproduces that when the target
has FMA. On this orb's CPU, against the reference:

| function         | mismatches | arguments                                      |
| ---------------- | ---------- | ---------------------------------------------- |
| exp              | 0          | 20,000                                         |
| pow              | 0          | 20,000                                         |
| log, log2, log10 | 0, 0, 0    | 100,000 (a third near 1, subnormals, integers) |

A build for a CPU without FMA follows glibc's generic code and differs from an
FMA machine's reference in about 15 of 20,000 `pow` and 16 to 46 of 100,000
`log` calls; glibc on such a CPU would too.

`sin`, `cos`, `tan`, `asin`, `acos`, `atan` are glibc's IBM Accurate
Mathematical Library code, too large to port for now, and use `std.math`; they
differ from the reference in the last bit for about 3% (sin, cos, tan, atan)
to 17% (atan2) of random arguments. `asin` and `acos` out of range give the
wrapper's positive NaN, as the reference prints `nan`, not `-nan`.

The VM's `^` calls `libm.pow`, so `2^0.5` agrees with the reference too.

## Verification

Expected values come from the dev shell's `lua`, never from this code. A
generator script runs each case on the reference, serializing arguments before
the call (the reference mutates tables in place), and emits Zig tuples;
`h.expectCases` in each library's tests calls the native and compares the
printed results: 267 string, 92 table, 536 math (special values, integer
edges, seeded random sequences), and 89 utf8 cases, ported from `strings.lua`,
`tpack.lua`, `sort.lua`, `math.lua`, `utf8.lua`, and `nextvar.lua` where they
do not need the parser. Hand-written tests cover what tuples cannot: `gmatch`
iteration, `gsub` with table and function replacements, the arithmetic
metamethods, `%s` with `__tostring` and `__name`, error positions from a Lua
caller ("test:7: bad argument #2 to 'rep'"), `sort`'s comparison counts and
invalid order functions, proxies through metamethods, `utf8.codes`, and values
surviving a collection a native triggers.

A throwaway differential driver ran 200,000 random calls across the four
libraries, generated and evaluated by the reference, through the natives in a
ReleaseSafe build: 0 mismatches.

## Requests for the core

Landed in wave 2's VM work (`vm.md`): `auxlib.raise` and `Args.argError` are
`debuginfo.raise` and `debuginfo.argError`, with call-site names and method
calls not counting `self`; `index`, `setIndex`, `len`, `lessThan`, `equal`,
`toInteger`, `toNumber`, and the number formatting are `vm`'s; `Userdata.bytes`
compiles. Sort's comparator and gsub's replacement function stay plain
`vm.call`s, which cannot yield, as `lua_call` in the reference; `vm.callk`
exists for a native that should let its callback yield. Bitwise operators
on strings raise an error in the reference 5.5.1 too, so the VM does not
convert them.

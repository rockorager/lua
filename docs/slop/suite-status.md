# Suite status

Where the official Lua 5.5.1 suite (`test/lua-5.5.1-tests/`) stands, on the
reference and on ours. Update the table when a file starts or stops passing.

## Running it

- `just suite` runs `all.lua` with `-e"_U=true"` from the suite's directory, as
  lua.org's instructions say, on `zig-out/bin/lua` built ReleaseSafe. It
  fails with a message until `build.zig` installs that executable.
- `just suite ref` runs it on the dev shell's reference `lua`, and
  `just suite path/to/lua` on any binary.
- `just suite BIN each` runs every file all.lua runs, alone and in all.lua's
  order, and prints `ok` or `FAIL` per file with the log in
  `zig-out/suite/<file>.txt`. `just suite BIN strings pm` runs only those.
  Alone, a file gets the globals all.lua sets under `_U`
  (`_U _soft _port _nomsg`, all true), but not all.lua's `string.dump` and
  `load` round trip, so a file that passes alone can still fail in `all.lua`.

`all.lua` stops at the first failing file, so per-file runs are how to fill
the table below; `all.lua` passing is the bar.

## The reference in this orb

Measured 2026-10-30 on reference C Lua 5.5.1 from nixpkgs
(`/nix/store/...-lua-5.5.1/bin/lua`), Intel Xeon @ 2.60GHz, 4 cores.

- `just suite ref`: passes, `final OK !!!`, about 1.2 s wall.
- `just suite ref each`: all 30 files pass alone, about 1 s in total.
- `_U=true` sets `_soft`, `_port`, and `_nomsg`. Run without it (`_soft` and
  `_port` false, `T` nil), the reference fails in `main.lua`:
  - `main.lua:212`: with `-E`, `lua` tries the default readline library,
    `libreadline.so`, and the nixpkgs build cannot `dlopen` it here (its glibc
    does not search `/usr/lib`), so it warns where the test expects silence.
    With a Nix readline on `LD_LIBRARY_PATH` the test passes.
  - `main.lua:251` needs the C modules (`libs/lib2-v2.so` and friends) that
    `libs/makefile` builds against Lua's C headers. They do not apply to an
    implementation without the C API, so `_port` stays on.
  - `attrib.lua:101` writes into `libs/P1/`, an empty directory the tarball
    ships and git does not keep, so the vendored copy lacks it. Its later
    `require` tests load the same C modules.
  - `main.lua` also reruns the interpreter as `env -i <progname>`, so the
    binary must be given by absolute path; `just suite` does that.
- `_soft` is not needed: with `-e"_port=true"` alone (`_soft` false), all.lua
  passes on the reference in about 8.2 s, including `big.lua` and the long
  `api`, `errors`, `gc`, `pm`, `sort`, and `math` cases. A harder bar for
  later.
- No file needs to be skipped on the reference: nothing goes in a skip list.

## Files

`ref` is the reference alone (`just suite ref each`); `ours` is
`just suite ours each` at the commit noted. Ours: the wave-2 parser branch
(`wave2-parser`, 2026-10-30), with the base library only. "With a stub" is
a rerun with `require = function(n) return _G[n] or {} end` to find the next
blocker; no failure so far is in the compiler or the base library. `heavy.lua`, `bwcoercion.lua`, and
`tracegc.lua` are not in the list: all.lua does not run the first, and the
other two are modules the files load.

| File             | ref | ours  | Notes                                                                   |
| ---------------- | --- | ----- | ----------------------------------------------------------------------- |
| `main.lua`       | ok  | ok    | returns at once (`_port`)                                               |
| `gc.lua`         | ok  | FAIL  | `require`; with a stub, line 139 needs `string.gsub`                    |
| `db.lua`         | ok  | FAIL  | `require`; then the debug library                                       |
| `calls.lua`      | ok  | FAIL  | `require`; with a stub, line 168 needs `string.find`                    |
| `strings.lua`    | ok  | FAIL  | line 10: the string library                                             |
| `literals.lua`   | ok  | FAIL  | `require`; with a stub, line 14 needs the string library                |
| `tpack.lua`      | ok  | FAIL  | line 4: `string.pack`                                                   |
| `attrib.lua`     | ok  | FAIL  | `require`, the package library                                          |
| `gengc.lua`      | ok  | FAIL  | `require`; with a stub, line 86 needs `coroutine`                       |
| `locals.lua`     | ok  | FAIL  | `require`; with a stub, line 78 needs `debug.getupvalue`                |
| `constructs.lua` | ok  | FAIL  | `require`; with a stub, line 73 needs `string.format`                   |
| `code.lua`       | ok  | ok    | returns at once (no `T`)                                                |
| `big.lua`        | ok  | ok    | returns at once (`_soft`)                                               |
| `cstack.lua`     | ok  | FAIL  | `require"tracegc"`, the package library                                 |
| `nextvar.lua`    | ok  | FAIL  | line 77: the string library                                             |
| `pm.lua`         | ok  | FAIL  | line 22: the string library                                             |
| `utf8.lua`       | ok  | FAIL  | `require`; then the utf8 library                                        |
| `api.lua`        | ok  | ok    | returns at once (no `T`)                                                |
| `memerr.lua`     | ok  | ok    | returns at once (no `T`)                                                |
| `events.lua`     | ok  | FAIL  | `require`; with a stub, line 55 needs the string arithmetic metamethods |
| `vararg.lua`     | ok  | FAIL  | line 23: named vararg tables in the VM                                  |
| `closure.lua`    | ok  | hangs | line 38 waits for a weak table to be collected                          |
| `coroutine.lua`  | ok  | FAIL  | `require`; then the coroutine library                                   |
| `goto.lua`       | ok  | FAIL  | line 14: the string library                                             |
| `errors.lua`     | ok  | FAIL  | `require`; with a stub, line 35 needs the string library                |
| `math.lua`       | ok  | FAIL  | `require`; then the math library                                        |
| `sort.lua`       | ok  | FAIL  | line 6: the table library                                               |
| `bitwise.lua`    | ok  | FAIL  | `require"bwcoercion"`, the package library                              |
| `verybig.lua`    | ok  | ok    |                                                                         |
| `files.lua`      | ok  | FAIL  | `require`; then the io and os libraries                                 |
| `all.lua`        | ok  | FAIL  | line 61: `math.randomseed`                                              |

Under `_U`, five files return at once: `main.lua` (`_port`), `big.lua`
(`_soft`), and `api.lua`, `code.lua`, and `memerr.lua` (`T`, the C test
library, is nil). Ours passing them says only that they load; `big.lua` gets
real coverage when `_soft` turns off, `main.lua` never does without the C
modules.

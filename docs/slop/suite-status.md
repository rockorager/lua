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
`just suite ours each` at the commit noted. `heavy.lua`, `bwcoercion.lua`, and
`tracegc.lua` are not in the list: all.lua does not run the first, and the
other two are modules the files load.

| File             | ref | ours | Notes |
| ---------------- | --- | ---- | ----- |
| `main.lua`       | ok  |      |       |
| `gc.lua`         | ok  |      |       |
| `db.lua`         | ok  |      |       |
| `calls.lua`      | ok  |      |       |
| `strings.lua`    | ok  |      |       |
| `literals.lua`   | ok  |      |       |
| `tpack.lua`      | ok  |      |       |
| `attrib.lua`     | ok  |      |       |
| `gengc.lua`      | ok  |      |       |
| `locals.lua`     | ok  |      |       |
| `constructs.lua` | ok  |      |       |
| `code.lua`       | ok  |      |       |
| `big.lua`        | ok  |      |       |
| `cstack.lua`     | ok  |      |       |
| `nextvar.lua`    | ok  |      |       |
| `pm.lua`         | ok  |      |       |
| `utf8.lua`       | ok  |      |       |
| `api.lua`        | ok  |      |       |
| `memerr.lua`     | ok  |      |       |
| `events.lua`     | ok  |      |       |
| `vararg.lua`     | ok  |      |       |
| `closure.lua`    | ok  |      |       |
| `coroutine.lua`  | ok  |      |       |
| `goto.lua`       | ok  |      |       |
| `errors.lua`     | ok  |      |       |
| `math.lua`       | ok  |      |       |
| `sort.lua`       | ok  |      |       |
| `bitwise.lua`    | ok  |      |       |
| `verybig.lua`    | ok  |      |       |
| `files.lua`      | ok  |      |       |
| `all.lua`        | ok  |      |       |

Under `_U`, five files return at once: `main.lua` (`_port`), `big.lua`
(`_soft`), and `api.lua`, `code.lua`, and `memerr.lua` (`T`, the C test
library, is nil). Ours passing them says only that they load; `big.lua` gets
real coverage when `_soft` turns off, `main.lua` never does without the C
modules.

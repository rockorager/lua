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
`just suite ours each` on the `wave3-gc` branch, 2026-10-30: wave 2's VM
and libraries, debug hooks, and the collector (`gc.md`). All 30 pass, and
so does `all.lua` with `_U=true` ("final OK !!!"), also with the
collector stressed (`zig build -Dgc-stress=step` and `=full`, in both
modes).
`heavy.lua`, `bwcoercion.lua`, and `tracegc.lua` are not in the list:
all.lua does not run the first, and the other two are modules the files
load.

| File             | ref | ours | Notes                                                 |
| ---------------- | --- | ---- | ----------------------------------------------------- |
| `main.lua`       | ok  | ok   | returns at once (`_port`); without `_port`, see below |
| `gc.lua`         | ok  | ok   | the `T` (C test library) cases skip                   |
| `db.lua`         | ok  | ok   |                                                       |
| `calls.lua`      | ok  | ok   |                                                       |
| `strings.lua`    | ok  | ok   |                                                       |
| `literals.lua`   | ok  | ok   |                                                       |
| `tpack.lua`      | ok  | ok   |                                                       |
| `attrib.lua`     | ok  | ok   |                                                       |
| `gengc.lua`      | ok  | ok   | returns at line 130 without `T`                       |
| `locals.lua`     | ok  | ok   |                                                       |
| `constructs.lua` | ok  | ok   |                                                       |
| `code.lua`       | ok  | ok   | returns at once (no `T`)                              |
| `big.lua`        | ok  | ok   | returns at once (`_soft`)                             |
| `cstack.lua`     | ok  | ok   |                                                       |
| `nextvar.lua`    | ok  | ok   |                                                       |
| `pm.lua`         | ok  | ok   |                                                       |
| `utf8.lua`       | ok  | ok   |                                                       |
| `api.lua`        | ok  | ok   | returns at once (no `T`)                              |
| `memerr.lua`     | ok  | ok   | returns at once (no `T`)                              |
| `events.lua`     | ok  | ok   |                                                       |
| `vararg.lua`     | ok  | ok   |                                                       |
| `closure.lua`    | ok  | ok   |                                                       |
| `coroutine.lua`  | ok  | ok   |                                                       |
| `goto.lua`       | ok  | ok   |                                                       |
| `errors.lua`     | ok  | ok   |                                                       |
| `math.lua`       | ok  | ok   |                                                       |
| `sort.lua`       | ok  | ok   |                                                       |
| `bitwise.lua`    | ok  | ok   |                                                       |
| `verybig.lua`    | ok  | ok   |                                                       |
| `files.lua`      | ok  | ok   |                                                       |

Under `_U`, five files return at once: `main.lua` (`_port`), `big.lua`
(`_soft`), and `api.lua`, `code.lua`, and `memerr.lua` (`T`, the C test
library, is nil). Ours passing them says only that they load; `big.lua` gets
real coverage when `_soft` turns off, `main.lua` never does without the C
modules.

Without `_U` (`_port` false), ours runs `main.lua` through line 206 and stops
where the interpreter would warn about readline (the reference stops at 212);
with that block skipped, both stop at line 251 on the C module `lib2-v2`.
`attrib.lua` with a `coroutine` stub stops at line 337 on the same C modules,
where the reference stops at 272 on the missing `libs/P1/`.

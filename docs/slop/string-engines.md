# String library engines

`src/lib/pattern.zig`, `src/lib/format.zig`, and `src/lib/pack.zig` hold the
work behind `string.find`, `string.match`, `string.gmatch`, `string.gsub`,
`string.format`, `string.pack`, `string.unpack`, and `string.packsize`. They
depend on nothing but `std`: they take byte slices and plain `i64`/`f64`, so
the string library glue wraps them once `Value` and `State` exist.

## Shape the glue sees

- Each engine raises one Zig error (`error.PatternError`, `error.FormatError`,
  `error.PackError`) and puts the reference's message in a `Diagnostic` held
  inline, so raising never allocates. In `format` and `pack`, a nonzero
  `Diagnostic.arg` means an argument error: the glue raises
  "bad argument #arg to 'name' (message)". Otherwise it raises the message as
  `luaL_error` would.
- Lua values reach `format` and `pack` through an `anytype` interface the glue
  implements (`integer`, `number`, `string`, `pointer`, `literal` for
  `format`; `integer`, `number`, `string` for `pack`), so the coercions and
  their errors (`luaL_checkinteger`, `luaL_tolstring` with `__tostring`) stay
  in the glue, and the engines call them in the reference's order.
  `unpack` hands values to a sink with the same three names.
- `gsub` takes a replacer with `replace(m, match, w) !bool`.
  `StringReplacement` is the one for strings and numbers; the glue writes the
  table and function ones, reading captures from the `Matcher`.
- Output goes to a `*std.Io.Writer`.

## Behavior worth knowing

- Positions: offsets are 0-based; `startIndex` turns an `init` argument into
  one (`posrelatI` minus one). Position captures report the 1-based Lua index.
- A `^` anchors `find`, `match`, and `gsub`, but `Gmatch` matches it
  literally, as the reference does.
- Errors raised from the gmatch iterator carry "file:line:" in the reference
  when the iterator is called from a Lua function, because `luaL_error` sees
  the calling Lua frame. That prefix is the glue's job.
- `format` follows glibc where the reference defers to `snprintf`: exact
  decimal expansion with round-half-even, glibc's `%a` layout (leading digit
  0 for subnormals, precision rounding that can carry to `0x2p+0`), NaN with
  its sign bit (`-nan`), and glibc's `%#g` quirk that prints `1.e+06` for
  999999.5. `%F` is rejected, as in the reference. The VM must keep NaN sign
  bits as x86 produces them (0/0 is `-nan` there) for `%f` of NaN to match.
- `pack` sizes follow x86-64 Linux: `l` and `T` are 8 bytes, `i` 4, and `!`
  alone aligns to 16 (`long double`).

## Verification

Besides the unit tests next to the code (expected values from reference Lua
5.5.1), each engine was run against the reference on random inputs: a Lua
script generated cases and the reference's results, and a scratch Zig driver
compared. 450,000 pattern cases (find, plain find, match, gmatch, gsub with
string replacements and limits), 830,000 format cases (every conversion with
random flags, widths, precisions, and special floats), and 600,000 pack cases
(pack, packsize, unpack with random formats, data, and positions) matched,
messages included. The drivers are not kept.

## Performance

Matching allocates nothing and recurses at most 200 levels, as the reference.
A rough ReleaseFast loop over the engine alone took about 110 ns for `%.2f`,
170 ns for `%.14g`, and 40 ns for `%d`; a full `string.format` call in
reference Lua takes 200 to 500 ns. That is not the A/B the performance rules
ask for; `bench/` measures `string.format` and `gsub` end to end once the
glue exists.

# Third-party code and data

lua is MIT (`LICENSE`). Most of the implementation is written for this repository from the reference manual. Some files are adapted from the Lua 5.5.1 sources, so that their output matches the reference's exactly; the upstream artifacts define what the rest must do, and one ships here as test data.

## Lua 5.5.1 sources

- Upstream: https://www.lua.org/ftp/lua-5.5.1.tar.gz
- Copyright (C) 1994-2026 Lua.org, PUC-Rio, under the MIT license below

Adapted into Zig, function by function:

- `src/Parser.zig` from `lparser.c`, and `src/Code.zig` from `lcode.c`, with its listing writer from `luac.c`'s `PrintFunction`.
- `src/lib/base.zig` from `lbaselib.c` and the parts of `lauxlib.c` it uses.
- `src/main.zig` from `lua.c`.

Copied unmodified, for the C API build (`-Dc-api=true`), which installs them so C modules build against them:

- `include/lua.h`, `include/luaconf.h`, `include/lauxlib.h`, and `include/lualib.h`, from the tarball's `src/` (SHA-256 of the tarball: `1c4b4068d67061f2a2231ad2b5422e77acea1487ea9890f6320af614f4373dce`).

## Lua 5.5 Reference Manual

- Upstream: https://www.lua.org/manual/5.5/
- Copyright (C) 1994-2026 Lua.org, PUC-Rio, under the MIT license below

## Lua 5.5.1 test suite

- Upstream: https://www.lua.org/tests/lua-5.5.1-tests.tar.gz, released 2026-07-24
- SHA-256 of the tarball: `da07b543872dc0bb2ff12aabd0c248578d78df3eb6b67efdc537a46d455c7f31`
- Copyright (C) 1994-2026 Lua.org, PUC-Rio, under the MIT license below

`test/lua-5.5.1-tests/` holds the suite, extracted unmodified, as test data. It is not compiled into the library and is not listed in `build.zig.zon`'s `paths`, so a `zig fetch` tarball does not carry it.

```
Copyright (C) 1994-2026 Lua.org, PUC-Rio.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

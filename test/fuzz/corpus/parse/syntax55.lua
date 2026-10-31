-- Lua 5.5 syntax for the parse fuzzer to mutate.
global x, y <const> = 1, 2
global<const> *
local function f(a, ...t) return t.n, ... end
local c <const>, d <close> = 1, nil
global function g() return x end
for i = 1, 3 do goto continue ::continue:: end
local s = [==[ long ]] string ]==] .. '\u{10FFFF}\z
   continued' .. "\x41\65\0"
local n = 0x1p-4 + 0xA.8p1 + 1e308 + 9223372036854775807 + 0x7fffffffffffffff
return f(1, 2, 3), #s, n // 1 | 0 ~ 1 << 2 >> 3, not nil and {[1] = 2; n = 3, "x"}

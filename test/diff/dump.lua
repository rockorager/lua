-- string.dump and binary chunks: the bytes must be the reference's, and
-- loading them must behave and fail as the reference does.

local function hex(s)
  return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

-- A digest for long dumps: FNV-1a over the bytes.
local function digest(s)
  local h = 0xcbf29ce484222325
  for i = 1, #s do h = ((h ~ s:byte(i)) * 0x100000001b3) end
  return #s .. ":" .. string.format("%016x", h)
end

-- Constants of every kind, nested functions, upvalues, locals, a vararg
-- table, repeated and long strings.
local src = [[
local a, b <const> = 10, -3
local s = "short", "short", "a string longer than forty bytes, so it is long"
local big, neg, f, z = math.maxinteger, math.mininteger, 1.5e300, -0.0
local function inner(x, ...)
  local t = {...}
  return function(y) return x + y + a, s, #t end
end
local function vt(...t) return t.n end
return inner, vt, nil, true, false, big, neg, f, z, 2^53, "x" .. a
]]
local main = assert(load(src, "=consts"))
print(hex(string.dump(main)))
print(hex(string.dump(main, true)))
local inner = main()
print(hex(string.dump(inner)))
print(hex(string.dump(inner(1))))

-- Line information: gaps past what a byte holds, more than 128 relative
-- entries in a row, loops whose instructions move back to the 'for', and a
-- call whose parentheses are 200 lines apart, which moves its CALL back
-- from an absolute entry to a line a byte reaches.
local gaps = "local x = 0\n" .. string.rep("x = x + 1 ", 300) .. "\n"
  .. string.rep("\n", 200) .. "for k, v in pairs({}) do\n"
  .. string.rep("x = x + k\n", 140) .. "end\n"
  .. "for i = 1, 2 do\n" .. string.rep("\n", 300) .. "x = x + i end\n"
  .. "local function g()\n" .. string.rep("\n", 150) .. "end\n"
  .. "print(\n" .. string.rep("x,\n", 135) .. "x)\n"
  .. "x = g(" .. string.rep("\n", 200) .. ")\n"
  .. "return x"
local lines = assert(load(gaps, "@gaps.lua"))
print(digest(string.dump(lines)), digest(string.dump(lines, true)))

-- A function from this file, whose source is "@dump.lua".
local function here(p, q) return p * q, hex end
print(hex(string.dump(here)))

-- Round trips: what loads dumps back the same, and runs.
for _, fn in ipairs({main, inner, lines}) do
  local d = string.dump(fn)
  print(string.dump(assert(load(d))) == d, string.dump(assert(load(d, "x", "b")), true) == string.dump(fn, true))
end
print(select(2, load(string.dump(main))()))
print(load(string.dump(here))(6, 7) == 42)

-- The first upvalue becomes the globals (or load's env); the others are nil.
local u1, u2 = 1, 2
local function ups() return u1, u2 end
local function envfirst() return print, u1 end
local l = load(string.dump(ups))
print(l() == _G, select(2, l()))
print(load(string.dump(ups), "u", "b", "env")())
print(pcall(load(string.dump(envfirst))))
print(load(string.dump(function() return 1 end))())

-- string.dump's argument check, called from Lua so the name is the call
-- site's.
print(pcall(function() return string.dump(print) end))
print(pcall(function() return string.dump() end))
print(pcall(function() return string.dump({}) end))

-- Modes and chunk names.
local d = string.dump(here)
print(load(d, "x", "t"))
print(load("return 1", "x", "b"))
print(load("", "x", "b"))
print(pcall(load, d, "x", "B"))
print(load(d:sub(1, 20), "=named"))
print(load(d:sub(1, 20), "@file.lua"))
print(load(d:sub(1, 20), "plain"))
print(load(d:sub(1, 20)))

-- Truncated and corrupted chunks.
for _, n in ipairs({1, 2, 4, 5, 6, 11, 12, 16, 17, 21, 22, 30, 31, 40, #d // 2, #d - 1}) do
  print(n, load(d:sub(1, n)))
end
local function patch(at, byte) return d:sub(1, at - 1) .. string.char(byte) .. d:sub(at + 1) end
print(load(patch(2, 0x4d)))
print(load(patch(5, 0x54)))
print(load(patch(6, 1)))
print(load(patch(7, 0)))
print(load(patch(13, 8)))
print(load(patch(14, 0)))
print(load(patch(18, 2)))
print(load(patch(19, 0)))
print(load(patch(23, 4)))
print(load(patch(24, 0)))
print(load(patch(32, 4)))
print(load(patch(33, 0)))
print(load(patch(41, 9)))
print(load(d .. "trailing bytes are ignored") ~= nil)
-- A string reference to a string not saved yet, a constant of an unknown
-- tag, a varint too long for an int.
local k = string.dump(load("return 'k'"))
local kat = k:find("\4\2k\0", 1, true)
print(load(k:sub(1, kat) .. "\0\9" .. k:sub(kat + 4)))
print(load(k:sub(1, kat - 1) .. "\9" .. k:sub(kat + 1)))
print(load(k:sub(1, 42) .. "\255\255\255\255\255\127" .. k:sub(44)))

-- A reader function that hands over a binary chunk in pieces.
local pos = 0
print(load(function()
  pos = pos + 1
  if pos <= #d then return d:sub(pos, pos) end
end)(3, 4))

-- Binary files: loadfile, dofile, and a first line starting with '#'.
local name = os.tmpname()
local fh = assert(io.open(name, "wb"))
fh:write(string.dump(assert(load("return 'from file', ...", "=file"))))
fh:close()
print(loadfile(name)("arg"), dofile(name), loadfile(name, "t"))
fh = assert(io.open(name, "wb"))
fh:write("#!/usr/bin/env lua\n", string.dump(assert(load("return 'after #'"))))
fh:close()
print(loadfile(name, "b")())
os.remove(name)

-- load, dofile, loadfile, and environments.
print(load("return 1 + 1")())
print(load("return ...", "=c")(1, 2, 3))
local env = {y = 5}
local f = load("x = 10; return y", "=env", "t", env)
print(f(), env.x, x)
print(load("x =", "=c"))
print(load("\27Lua", "b", "t"))
print(load("x=1", "=n", "b"))
print(pcall(load, "x", "n", "B"))
local parts = {"return ", "1 + ", "41"}
local i = 0
print(load(function() i = i + 1 return parts[i] end)())
print(load(function() return nil end))
print(pcall(load, function() error("reader error") end))
print(pcall(load, function() return {} end))
print(load(12))
print(pcall(load, nil))
print(loadfile("/nonexistent/file.lua"))
print(pcall(dofile, "/nonexistent/file.lua"))
local g = load("local a <const> = 7; return function() return a * 2 end")()
print(g())
local h = load("global x1; x1 = 3; return x1")
print(h(), x1)
print(pcall(load("global<const> y1 = 4; return y1")))
print(pcall(load("global z1 = 1; return z1")))
z1 = 2
print(pcall(load("global z1 = 1; return z1")))
print(pcall(load("global function gf() return 1 end; return gf()")))
print(pcall(load("global function gf() return 1 end; return gf()")))
local up = 1
local function closure() return up end
print(load(string_dump_missing and "" or "return 1")())
-- A chunk name ends at its first zero byte, as a C string (found by fuzzing).
print(load("\0")) print(load("x\0y")) print(load("return +", "=a\0b"))

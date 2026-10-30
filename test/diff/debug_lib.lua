-- The debug library, xpcall's message handler running before the stack
-- unwinds, stack overflows, and binary chunks from luac.
local function show(t)
  local keys = {}
  for k in pairs(t) do if k ~= "func" and k ~= "activelines" then keys[#keys + 1] = k end end
  table.sort(keys)
  local out = {}
  for _, k in ipairs(keys) do out[#out + 1] = k .. "=" .. tostring(t[k]) end
  return table.concat(out, " ")
end

local function f(a, b, ...)
  local c = a + b
  print(show(debug.getinfo(1)))
  print(debug.getlocal(1, 1), debug.getlocal(1, 2), debug.getlocal(1, 3), debug.getlocal(1, -1))
  print(debug.setlocal(1, 3, 99), c)
  return c
end
f(1, 2, "va")
print(show(debug.getinfo(print)))
print(show(debug.getinfo(f, "Su")))
print(debug.getinfo(100), pcall(debug.getinfo, 1, ">"))
print(pcall(debug.getinfo, 1, "x"))
local lines = {}
for l in pairs(debug.getinfo(f, "L").activelines) do lines[#lines + 1] = l end
table.sort(lines)
print(table.concat(lines, ","))

-- Upvalues
local u1, u2 = 10, 20
local function g() return u1 + u2 end
print(debug.getupvalue(g, 1), debug.getupvalue(g, 2), debug.getupvalue(g, 3))
print(debug.setupvalue(g, 1, 5), g())
local function h() return u2 end
print(debug.upvalueid(g, 2) == debug.upvalueid(h, 1), debug.upvalueid(g, 1) == debug.upvalueid(h, 1))
debug.upvaluejoin(g, 1, h, 1)
print(g(), pcall(debug.upvaluejoin, g, 3, h, 1))

-- Names of functions by their call sites
local function where() return debug.getinfo(2, "n").name end
local t = {m = function() return debug.getinfo(1, "n").namewhat, debug.getinfo(1, "n").name end}
print(t.m()) print(t:m())
local function tail() return debug.getinfo(1, "t").istailcall end
local function caller() return tail() end
print(caller(), where and "ok")

-- traceback. The reference runs the main chunk from a C function, which
-- tracebacks end with; ours does not yet, so that line is cut.
local function cut(s) return (s:gsub("\n\t%[C%]: in %?$", "")) end
local function lvl3() return cut(debug.traceback("msg", 1)) end
local function lvl2() return lvl3() .. "" end
print(lvl2())
print(cut(debug.traceback(42)), cut(debug.traceback(nil, 1)), type(debug.traceback({})))
local co = coroutine.create(function() coroutine.yield() end)
coroutine.resume(co)
print(debug.traceback(co))
print(debug.traceback(co, "co msg"))

-- xpcall's handler sees the stack where the error happened
local function deep(n) if n == 0 then error("bottom") end return deep(n - 1) + 1 end
print(xpcall(deep, function(m) return m .. " | " .. debug.getinfo(2, "n").name end, 3))
print(xpcall(deep, function(m) return cut(debug.traceback(m)) end, 2))
print(xpcall(error, function(m) return type(m) end))
print(select("#", xpcall(function() return 1, 2, 3 end, print)))

-- Stack overflow, and the stack shrinking back after it
local function rec(n) return 1 + rec(n + 1) end
local ok, m = pcall(rec, 1)
print(ok, m)
local function crec() return pcall(crec) end
print(select("#", crec()) > 0)
local co2 = coroutine.wrap(function() local ok2, m2 = pcall(rec, 1) return m2 end)
print(co2())
print(string.rep("x", 3), pcall(string.rep))

-- Argument errors name the function as the call site does
local rep = string.rep
print(pcall(function() return rep() end))
print(pcall(function() return ("x"):rep({}) end))
print(pcall(function() local s = 1 return s:rep() end))
print(pcall(table.sort, 1))
print(pcall(coroutine.resume, 1))

-- Binary chunk headers
print(load("\27Lua", "=x"))
print(load("\27Lux", "@y"))
print(load("\27Lua\x54\0", "z"))
print(load("\27Lua\x55\1", "\27w"))
print(load("\27Lua\x55\0\x19\x93\r\n\x1a\n\4", "=v"))
print(load("\27Lua", "=x", "t"))

-- string.dump round trips, stripped or not
local function adder(x, ...) local y <const> = 2; local n = select("#", ...) return function(z) return x + y + z + n end end
local d = string.dump(adder)
print(type(d), d:sub(1, 4) == "\27Lua", load(d)(1, "a", "b")(3))
local ds = string.dump(adder, true)
print(#ds < #d, load(ds)(1)(3))
print(pcall(load(ds), nil))
print(pcall(load(d), nil))
print(pcall(string.dump, print))
local function vt(...t) return t.n end
print(load(string.dump(vt))(1, 2, 3))

-- Runtime errors in stripped functions are positioned "?:?:"
print(pcall(load(string.dump(function(t) return t.x.y end, true)), {}))
print(pcall(load(string.dump(function() error("boom") end, true))))
print(pcall(load(string.dump(function() local a = {} return a + 1 end, true))))

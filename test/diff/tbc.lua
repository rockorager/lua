-- To-be-closed variables: __close on normal exit, break, return, errors,
-- and in the generic for.
local log = {}
local function L(s) log[#log + 1] = s end
local function closer(name)
  return setmetatable({}, {__close = function(o, e) L(name .. ":" .. tostring(e)) end})
end
local function dump() local s = "" for i = 1, #log do s = s .. log[i] .. " " end print(s) log = {} end

do local a <close> = closer("a"); local b <close> = closer("b"); L("body") end
dump()
for i = 1, 3 do local x <close> = closer("x" .. i); if i == 2 then break end end
dump()
local function f() local y <close> = closer("y"); return 1, 2, 3 end
print(f()) dump()
local function g(...) local y <close> = closer("y"); return ... end
print(g(4, 5, 6)) dump()
print(pcall(function() local z <close> = closer("z"); error("boom") end)) dump()
print(select("#", pcall(function() local z <close> = closer("z"); local w <close> = closer("w"); error(nil) end))) dump()
-- error in __close replaces the error
print(pcall(function()
  local a <close> = setmetatable({}, {__close = function(o, e) L("a:" .. tostring(e)); error("second") end})
  local b <close> = closer("b")
  error("first")
end)) dump()
-- error in __close on normal exit
print(pcall(function()
  local a <close> = setmetatable({}, {__close = function(o, e) error("in close") end})
  return 10
end)) dump()
-- nil and false are fine
do local n <close> = nil; local f <close> = false; L("ok") end dump()
-- non-closable
print(pcall(function() local q <close> = 42 end))
print(pcall(function() local q <close> = {} end))
-- generic for closing value
local function iter(t)
  local i = 0
  return function() i = i + 1; return t[i] end, nil, nil, closer("for")
end
for v in iter({1, 2, 3}) do L(v) end dump()
for v in iter({1, 2, 3}) do L(v); if v == 2 then break end end dump()
print(pcall(function() for v in iter({1, 2, 3}) do error("in loop") end end)) dump()
local function ret() for v in iter({1, 2}) do return v end end
print(ret()) dump()
-- nested functions and upvalues
local function h()
  local c <close> = closer("c")
  local function inner() return c end
  return inner
end
print(type(h()())) dump()
-- goto out of a block
do
  local i = 0
  ::top::
  do local q <close> = closer("q" .. i); i = i + 1; if i < 3 then goto top end end
end
dump()
-- many values
local function many()
  local a <close> = closer("m")
  return 1, 2, 3, 4, 5, 6, 7, 8, 9, 10
end
print(select('#', many())) dump()
-- close with coroutine.wrap
local co = coroutine.wrap(function()
  local x <close> = closer("cx")
  coroutine.yield(1)
  return 2
end)
print(co()) dump() print(co()) dump()

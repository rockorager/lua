-- Coroutines: resume, yield, wrap, status, close, isyieldable, running,
-- yields across pcall, metamethods, and for iterators, and their errors.
local co = coroutine.create(function(a, b)
  print("start", a, b)
  local c, d = coroutine.yield(a + b)
  print("got", c, d)
  local e = coroutine.yield(c * d)
  return e, "end"
end)
print(coroutine.status(co))
print(coroutine.resume(co, 1, 2))
print(coroutine.status(co))
print(coroutine.resume(co, 3, 4))
print(coroutine.resume(co, 5))
print(coroutine.status(co))
print(coroutine.resume(co))
-- generators
local function gen(n)
  return coroutine.wrap(function() for i = 1, n do coroutine.yield(i) end end)
end
local s = 0 for i in gen(10) do s = s + i end print(s)
-- yield across pcall
co = coroutine.create(function()
  local ok, v = pcall(function()
    local x = coroutine.yield("in pcall")
    error("err " .. x)
  end)
  print("pcall returned", ok, v)
  local ok2, v2 = pcall(function() return coroutine.yield("again") + 1 end)
  print("pcall2", ok2, v2)
  return "done"
end)
print(coroutine.resume(co))
print(coroutine.resume(co, "X"))
print(coroutine.resume(co, 41))
print(coroutine.status(co))
-- yield inside metamethods
local mt = {
  __index = function(t, k) return coroutine.yield("index " .. k) end,
  __add = function(a, b) return coroutine.yield("add") end,
  __lt = function(a, b) return coroutine.yield("lt") end,
  __concat = function(a, b) return coroutine.yield("concat") end,
  __eq = function(a, b) return coroutine.yield("eq") end,
  __newindex = function(t, k, v) coroutine.yield("newindex " .. k) end,
  __len = function() return coroutine.yield("len") end,
  __unm = function() return coroutine.yield("unm") end,
  __call = function(self, x) return coroutine.yield("call " .. x) end,
}
local obj = setmetatable({}, mt)
local obj2 = setmetatable({}, mt)
co = coroutine.wrap(function()
  local r = {}
  r[1] = obj.foo
  r[2] = obj + 1
  r[3] = obj < obj2 and "lt-true" or "lt-false"
  r[4] = "a" .. obj .. "b"
  r[5] = obj == obj2 and "eq-true" or "eq-false"
  obj.bar = 5
  r[6] = #obj
  r[7] = -obj
  r[8] = obj(9)
  return r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8]
end)
print(co())
print(co("FOO"))
print(co(100))
print(co(true))
print(co("CC"))
print(co(false))
print(co())
print(co(3))
print(co(-1))
print(co("CALLED"))
-- errors
co = coroutine.create(function() error("oops") end)
print(coroutine.resume(co))
print(coroutine.status(co))
print(coroutine.resume(co))
co = coroutine.create(function() error({}) end)
print(select("#", coroutine.resume(co)))
print(pcall(coroutine.yield, 1))
print(coroutine.resume(coroutine.running()))
print(coroutine.isyieldable())
print(coroutine.wrap(function() return coroutine.isyieldable(), coroutine.running() end)())
local w = coroutine.wrap(function() error("in wrap") end)
print(pcall(w))
w = coroutine.wrap(function() return 1 end)
w()
print(pcall(w))
-- status normal
local co1, co2
co1 = coroutine.create(function() return coroutine.status(co2) end)
co2 = coroutine.create(function() return coroutine.resume(co1) end)
print(coroutine.resume(co2))
-- close
co = coroutine.create(function()
  local x <close> = setmetatable({}, {__close = function(o, e) print("closing x", e) end})
  coroutine.yield(1)
end)
coroutine.resume(co)
print(coroutine.close(co), coroutine.status(co))
co = coroutine.create(function()
  local x <close> = setmetatable({}, {__close = function(o, e) print("closing x", e) end})
  error("dead")
end)
print(coroutine.resume(co))
print(coroutine.close(co))
print(coroutine.close(co))
co = coroutine.create(function() local x <close> = setmetatable({}, {__close = function() print("self closed") end}); coroutine.close(); print("not here") end)
print(coroutine.resume(co))
print(coroutine.status(co))
print(pcall(coroutine.close, coroutine.running()))
-- yield in __close
co = coroutine.wrap(function()
  local x <close> = setmetatable({}, {__close = function() coroutine.yield("in close") end})
  return "ret"
end)
print(co()) print(co())
-- yield across a for iterator
co = coroutine.wrap(function()
  for k in coroutine.wrap(function() coroutine.yield(1) coroutine.yield(2) end) do coroutine.yield(k * 10) end
  return "fin"
end)
print(co(), co(), co())
-- error inside pcall inside coroutine after yield, with tbc
co = coroutine.wrap(function()
  local ok, e = pcall(function()
    local t <close> = setmetatable({}, {__close = function(o, e) print("tbc closed with", e) end})
    coroutine.yield("y1")
    error("after yield")
  end)
  print("caught", ok, e)
  return "end"
end)
print(co()) print(co())
-- xpcall with yield
co = coroutine.wrap(function()
  return xpcall(function() coroutine.yield("xy"); error("xe") end, function(m) return "handled: " .. m end)
end)
print(co()) print(co())
-- deep recursion of resumes
local function deep(n)
  if n == 0 then return "bottom" end
  local c = coroutine.create(deep)
  local ok, v = coroutine.resume(c, n - 1)
  return v
end
print(deep(100))
local function f(n) local c = coroutine.create(f) local a, b = coroutine.resume(c) return b end
print(f())
-- resume args/results
print(coroutine.resume(coroutine.create(function(...) return select('#', ...), ... end), nil, nil))
-- wrap error position
local ww = coroutine.wrap(function() local x = nil; return x.y end)
print(pcall(ww))
print(pcall(coroutine.resume, 1))
print(pcall(coroutine.create, 1))
-- yield from main
print(pcall(coroutine.yield))
-- yield across non-yieldable (ipairs with __index yielding uses vm.get)
co = coroutine.wrap(function()
  local t = setmetatable({}, {__index = function(t, i) if i < 3 then return coroutine.yield(i) end end})
  for i, v in ipairs(t) do end
end)
print(pcall(co))
local mt = {__index = function(t, k) return coroutine.yield("index " .. k) end}
local mt2 = {__index = function(t, k) local v = coroutine.yield("index " .. k) return v end}
local obj = setmetatable({}, mt)
local obj2 = setmetatable({}, mt2)
local co = coroutine.wrap(function() local r = obj.foo; return r end)
print(co()) print(co("FOO"))
co = coroutine.wrap(function() local r = obj2.foo; return r end)
print(co()) print(co("FOO"))
co = coroutine.wrap(function() local r = {} r[1] = obj.foo; return r[1] end)
print(co()) print(co("FOO"))

-- yields inside __pairs and dofile
local pt = setmetatable({10, 20, 30}, {__pairs = function(t)
  local inc = coroutine.yield("in __pairs")
  return function(t, i) if i > 1 then return i - inc, t[i - inc] end end, t, #t + 1
end})
local pco = coroutine.wrap(function() local r = {} for _, v in pairs(pt) do r[#r + 1] = v end return table.concat(r, ",") end)
print(pco()) print(pco(1))
local fname = os.tmpname()
local fh = io.open(fname, "w") fh:write("local a = coroutine.yield('in dofile') return a, a * 2") fh:close()
local dco = coroutine.wrap(function() return dofile(fname) end)
print(dco()) print(dco(21))
os.remove(fname)

-- "not enough memory" raised by Lua through wrap is an ordinary error,
-- positioned at the caller; so is resuming the dead coroutine again.
-- (Raised at level 0 the reference makes it a memory error, as
-- `lua_error` does for that exact string; here only a failed allocation
-- is one.)
local memco = coroutine.wrap(function() error("not enough memory") end)
print(pcall(function() return memco() end))
print(pcall(function() return memco() end))

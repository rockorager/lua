-- Metatables and metamethods the VM handles.
local mt = {}
mt.__index = function(t, k) return k .. "!" end
mt.__newindex = function(t, k, v) rawset(t, k, v * 2) end
mt.__call = function(self, a, b) return "called", a, b end
mt.__add = function(a, b) return "add" end
mt.__sub = function(a, b) return "sub" end
mt.__mul = function(a, b) return "mul" end
mt.__div = function(a, b) return "div" end
mt.__mod = function(a, b) return "mod" end
mt.__pow = function(a, b) return "pow" end
mt.__unm = function(a) return "unm" end
mt.__idiv = function(a, b) return "idiv" end
mt.__band = function(a, b) return "band" end
mt.__shl = function(a, b) return "shl" end
mt.__bnot = function(a) return "bnot" end
mt.__len = function(a) return 42 end
mt.__eq = function(a, b) return true end
mt.__lt = function(a, b) return true end
mt.__le = function(a, b) return false end
local t = setmetatable({}, mt)
print(t.foo, t[1])
t.x = 21
print(rawget(t, "x"))
print(t(1, 2))
print(t + 1, 1 + t, t - 1, t * 2, t / 2, t % 2, t ^ 2, -t, t // 2, t & 1, t << 1, ~t)
print(#t, t == setmetatable({}, mt), t < t, t <= t, t > t, t >= t)
print(getmetatable(t) == mt)

local base = {greet = function(self) return "hi " .. self.name end}
base.__index = base
local obj = setmetatable({name = "obj"}, base)
print(obj:greet())

local proxy = setmetatable({}, {__index = obj})
print(proxy.name, proxy:greet())

local cnt = 0
local logged = setmetatable({}, {__newindex = function(t, k, v) cnt = cnt + 1 rawset(t, k, v) end})
logged.a = 1 logged.a = 2 logged.b = 3
print(cnt, logged.a, logged.b)

local ro = setmetatable({}, {__metatable = "no", __index = {x = 1}})
print(getmetatable(ro), ro.x, pcall(setmetatable, ro, {}))
print(rawequal(t, t), rawequal(t, {}), rawlen({1, 2, 3}), rawlen("abcd"))

local s = setmetatable({}, {__tostring = function() return "custom" end, __name = "N"})
print(tostring(s), s)

local chain = setmetatable({}, {__index = setmetatable({}, {__index = {deep = "yes"}})})
print(chain.deep)

local calls = 0
local fn = setmetatable({}, {__call = function(self, ...) calls = calls + 1 return select('#', ...) end})
print(fn(), fn(1, 2, 3), calls)

-- The C API's error unwinding, continuations, and lauxlib, through
-- capitest.c. `just capi-test` runs this on our C-API lua and on the
-- reference with the same capitest.so and compares the output, with
-- addresses masked. Run from this directory with the library on cpath.

local T = require "capitest"

local function show (...)
  local t = table.pack(...)
  for i = 1, t.n do t[i] = tostring(t[i]) end
  print(table.concat(t, " ", 1, t.n))
end

local function try (name, f, ...)
  show(name, pcall(f, ...))
end

print "-- calls and errors"
try("call", T.call, function (a, b) return b, a end, 1, 2)
try("call error", T.call, error, "plain")
try("call error table", function ()
  local ok, e = pcall(T.call, error, {code = 7})
  return ok, type(e), e.code
end)
try("lua_error", T.error, "raised")
try("lua_error nil", T.error, nil)
try("luaL_error", T.lerror, "s")
try("luaL_error from Lua", function () return T.lerror() end)
show("pcall ok", T.pcall(function (...) return ... end, 1, 2, 3))
show("pcall err", T.pcall(error, "in pcall"))
show("pcall lerror", T.pcall(T.lerror, "deep"))
show("pcall memerr", T.pcall(T.memerr))
show("pcallh", T.pcallh(function (m) return "handled: " .. m end, error, "oops"))
show("pcallh traceback", (select(2, T.pcallh(debug.traceback, error, "tb"))):gsub("\n.*", ""))
show("pcallh handler fails", T.pcallh(function () error("again") end, error, "first"))
show("nested pcall", T.pcall(T.pcall, T.call, error, "inner"))
try("fail_after", T.fail_after, error, "stop")
try("fail_after lerror", T.fail_after, T.lerror, "stop")
show("leaked", T.leaked())

print "-- C -> Lua -> C -> luaL_error, nested"
local function down (n, f) return T.deep(n, f) end
try("deep 1", T.deep, 1, down)
try("deep 50", T.deep, 50, down)
for i = 1, 2000 do pcall(T.deep, 5, down) end
show("deep repeated, leaked", T.leaked())
try("C stack overflow", T.deep, 300, down)
local function nest (n) if n == 0 then return "done" end return T.call(nest, n - 1) end
try("nested calls 150", nest, 150)
try("nested calls 250", nest, 250)

print "-- argument checks"
try("checkint", T.checkint, 21)
try("checkint str", T.checkint, "x")
try("checkint none", T.checkint)
try("checkint float", T.checkint, 1.5)
try("checknum", T.checknum, "2")
try("checkopt", T.checkopt, "one")
try("checkopt default", T.checkopt)
try("checkopt bad", T.checkopt, "three")
local obj = T.newT(5)
show("udata", obj:get())
try("checkudata", obj.get, {})
try("bad self", function () local o = {get = obj.get} return o:get() end)
local check = T.checkint
try("named local", function () return check("no") end)

print "-- metamethods called from C"
local mt = {
  __index = function (t, k) error("no field " .. tostring(k)) end,
  __newindex = function (t, k, v) error("read-only " .. tostring(k)) end,
  __add = function (a, b) return "added" end,
  __lt = function (a, b) error("cannot order") end,
  __len = function () return 3 end,
  __concat = function () error("cannot concat") end,
  __tostring = function () return "OBJ" end,
}
local o = setmetatable({}, mt)
try("gettable", T.gettable, o, "x")
try("gettable raw hit", T.gettable, {x = 1}, "x")
try("settable", T.settable, o, "k", 1)
try("rawset nil key", T.rawset, {}, nil, 1)
try("rawset NaN key", T.rawset, {}, 0/0, 1)
try("arith mm", T.arith, o, 1)
try("arith error", T.arith, {}, 1)
try("arith ints", T.arith, 2, 3)
try("arith zero", function () return T.arith(1, 0) end)
try("unm", T.unm, 5)
try("compare mm error", T.compare, o, o)
try("compare", T.compare, 1, 2)
try("compare error", T.compare, {}, 1)
try("concat", T.concat, "a", 1, 2.5)
try("concat mm error", T.concat, "a", o)
try("len", T.len, o)
try("len str", T.len, "abcd")
try("tostring", T.tostring, o)
try("tostring int", T.tostring, 10)
local bad = setmetatable({}, {__add = T.badadd})
try("C __add from Lua", function () return bad + 1 end)
try("C __index chain", function ()
  local p = setmetatable({}, {__index = function (t, k) return T.gettable(o, k) end})
  return p.zzz
end)

print "-- coroutines"
local co = coroutine.wrap(function (...)
  local a, b = T.yield(...)
  return "after yield", a, b
end)
show("yield", co(1, 2))
show("resumed", co("x", "y"))
co = coroutine.wrap(function (...)
  local r = table.pack(T.yieldk(...))
  return table.unpack(r, 1, r.n)
end)
show("yieldk", co("p", "q"))
show("yieldk resumed", co("r", "s"))
co = coroutine.wrap(function ()
  return T.callk(function (a) local x = coroutine.yield("in callk", a) return x, "end" end, "arg")
end)
show("callk yield", co())
show("callk resumed", co("value"))
show("callk no yield", T.callk(function (...) return ... end, 1, 2))
co = coroutine.wrap(function ()
  return T.pcallk(function () local x = coroutine.yield("in pcallk") error("after " .. x) end)
end)
show("pcallk yield", co())
show("pcallk error after yield", co("resume"))
co = coroutine.wrap(function ()
  return T.pcallk(function () coroutine.yield("again") return "fine" end)
end)
show("pcallk", co())
show("pcallk ok after yield", co())
show("pcallk no yield", T.pcallk(error, "direct"))
try("yield across lua_call", coroutine.wrap(function () return T.call(coroutine.yield, 1) end))
try("yield outside coroutine", T.yield, 1)
co = coroutine.create(function (a) local b = coroutine.yield(a + 1) error("co failed " .. b) end)
show("C resume", T.resume(co, 10))
show("C resume error", T.resume(co, 20))
show("C resume dead", T.resume(co))
show("spawn", T.spawn(function (a, b) return a .. b end, "x", "y"))
show("spawn yields", T.spawn(function () coroutine.yield("y1", "y2") end))
show("spawn error", T.spawn(function () T.lerror("in thread") end))
co = coroutine.wrap(function ()
  local ok, e = pcall(T.callk, function () coroutine.yield("before") error("caught by Lua") end)
  return "pcall in co", ok, e
end)
show("callk error", co())
show("callk error resumed", co())
co = coroutine.wrap(function ()
  for i = 1, 3 do T.yieldk(i) end
  return "loop done"
end)
show("yieldk loop", co(), co(), co(), co())

print "-- closures, buffers, userdata, registry"
local c = T.counter()
show("counter", c(), c(), c())
show("buffer small", T.buffer(3, "abc"))
local s, n = T.buffer(5000, "tail")
show("buffer big", #s, n, s:sub(-6))
try("buffer abandoned", T.buffail, 100000)
show("ref", T.ref("first"))
show("registry", T.registry(_G))
show("stack", T.stack())
show("types", T.types(1, 2.5, "3", "x", nil, true, {}, print, T.leaked, obj))
show("tonumber", T.tonumber("0x10"))
show("tonumber bad", T.tonumber("z"))
show("tonumber float", T.tonumber(3.0))
show("next", T.next({1, 2, 3, x = 10}))
show("loadstring", T.loadstring("return 1 +"))
local st, f = T.loadstring("return ... or 'loaded'")
show("loadstring ok", st, f())
show("traceback", (T.traceback("msg"):gsub("\n.*", "")))
show("where", (function () return T.where() end)())
show("gsub", T.gsub("a.b.c", ".", "::"))
show("fstring", T.fstring())
show("sameptr", T.sameptr())
show("placeholder", T.placeholder)
print "-- hooks, locals, upvalues, to-be-closed slots, dumps, warnings"
show("hooked", T.hooked(function (n) local s = 0 for i = 1, n do s = s + i end return s end, 100))
debug.sethook(function () end, "l")
show("rehook", T.rehook(), debug.gethook() ~= nil)
debug.sethook()
local function withlocals (a)
  local first, second = a, "two"
  show("locals", T.locals())
  show("after setlocal", a, first, second)
end
withlocals(1)
local up1, up2 = 0, 0
local function fa () up1 = up1 + 1 return up1 end
local function fb () return up1 end
local function fc () up2 = up2 + 10 return up2 end
show("upvalueid", T.upvalueid(fa, 1) == debug.upvalueid(fa, 1), T.upvalueid(fa, 1) == T.upvalueid(fb, 1), T.upvalueid(fa, 1) == T.upvalueid(fc, 1))
T.upvaluejoin(fc, 1, fa, 1)
show("upvaluejoin", fa(), fc(), fb())
local closer = setmetatable({}, {__close = function (_, e) print("closed with", e) end})
show("toclose", T.toclose(closer))
try("toclose error", T.toclose, closer, true)
try("toclose non-closable", T.toclose, {})
local function dumped (a) return a * 3 end
local d, st = T.dump(dumped)
show("dump", st, d == string.dump(dumped), load(d)(14))
d, st = T.dump(dumped, true)
show("dump stripped", st, d == string.dump(dumped, true))
show("warnings", T.warnings(warn, "a", "b"))
show("gcmodes", T.gcmodes())
show("allocf", T.allocf())
show("execresult", T.execresult("exit 7"))
show("execresult ok", T.execresult("true"))

T.newT(-3)
collectgarbage()
collectgarbage()
show("leaked at end", T.leaked())
print "OK"

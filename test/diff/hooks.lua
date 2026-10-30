-- Debug hooks: call, tail call, return, line, and count events, what
-- debug.getinfo sees inside a hook, transfer information, and hooks per
-- coroutine.

local function show(t)
  print(table.concat(t, " "))
end

-- Line events: new lines, loops (a jump back repeats the line), and
-- branches.
do
  local lines = {}
  local function run()
    local s = 0
    for i = 1, 3 do
      s = s + i
    end
    local j = 0
    while j < 2 do j = j + 1 end
    repeat
      j = j - 1
    until j == 0
    if s > 100 then
      s = 0
    else
      s = s + 1
    end
    return s
  end
  debug.sethook(function(e, l) lines[#lines + 1] = l end, "l")
  run()
  debug.sethook()
  show(lines)
end

-- Call, tail call, and return events, with names from getinfo.
do
  local trace = {}
  local function leaf(x) return x + 1 end
  local function tail(x) return leaf(x) end
  local function outer(x) return tail(x) * 2 end
  debug.sethook(function(e)
    local info = debug.getinfo(2, "nSt")
    trace[#trace + 1] = e .. ":" .. tostring(info.name) .. ":" .. info.what .. ":" .. tostring(info.istailcall)
  end, "cr")
  outer(1)
  debug.sethook()
  show(trace)
end

-- Transfer information: the values a call receives and a return gives.
do
  local log = {}
  local on = false
  debug.sethook(function(e)
    if not on then return end
    local ar = debug.getinfo(2, "r")
    local t = {}
    for i = ar.ftransfer, ar.ftransfer + ar.ntransfer - 1 do
      local _, v = debug.getlocal(2, i)
      t[#t + 1] = tostring(v)
    end
    log[#log + 1] = e .. "(" .. table.concat(t, ",") .. ")"
  end, "cr")
  local function va(a, ...) return a, ... end
  on = true
  select(2, "a", "b", "c")
  va(1, 2, 3)
  on = false
  debug.sethook()
  show(log)
end

-- Count events, and gethook.
do
  local n = 0
  debug.sethook(function() n = n + 1 end, "", 3)
  for _ = 1, 30 do end
  local f, mask, count = debug.gethook()
  debug.sethook()
  print(n > 5 and n < 30, type(f), mask, count)
  print(debug.gethook())
end

-- Inside a hook: the hook's own name, and no nested hooks.
do
  local seen = {}
  debug.sethook(function(e, l)
    local me = debug.getinfo(1, "n")
    seen[#seen + 1] = me.namewhat .. ":" .. tostring(me.name)
    debug.sethook()
  end, "l")
  local x = 1
  show(seen)
end

-- Hooks belong to a thread.
do
  local trace = {}
  local co = coroutine.create(function()
    coroutine.yield(10)
    return 20
  end)
  debug.sethook(co, function(e) trace[#trace + 1] = e end, "clr")
  repeat until not coroutine.resume(co)
  print(debug.gethook())
  show(trace)
end

-- A hook's error unwinds like any other, and hooks run again after it.
do
  local ok, msg = pcall(function()
    debug.sethook(function() debug.sethook(); error("in hook") end, "l")
    local a = 1
    return a
  end)
  debug.sethook()
  print(ok, msg)
  local n = 0
  debug.sethook(function() n = n + 1 end, "l")
  local b = 2
  debug.sethook()
  print(n)
end

-- Return hooks run after a function's __close handlers.
do
  local trace = {}
  local function closer()
    return setmetatable({}, { __close = function() trace[#trace + 1] = "close" end })
  end
  local function f()
    local x <close> = closer()
    return 1
  end
  debug.sethook(function(e)
    trace[#trace + 1] = e .. ":" .. tostring(debug.getinfo(2, "n").name)
  end, "r")
  f()
  debug.sethook()
  show(trace)
end

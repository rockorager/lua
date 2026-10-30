-- Coroutines: resume and yield ping-pong, passing values both ways, plus a
-- generator through coroutine.wrap and many short-lived coroutines.
-- Usage: lua coroutines.lua [N], default 3000000. Prints a checksum.

local n = tonumber(arg and arg[1]) or 3000000

local create, resume, yield, wrap = coroutine.create, coroutine.resume, coroutine.yield, coroutine.wrap

-- Ping-pong: each resume sends a value in, each yield sends one out.
local echo = create(function(x)
  while true do
    x = yield(x * 2 + 1)
  end
end)
local sum = 0
for i = 1, n do
  local _, v = resume(echo, i)
  sum = sum + v
end

-- A generator through wrap.
local gen = wrap(function()
  for i = 1, n do
    yield(i % 13)
  end
end)
for _ = 1, n do
  sum = sum + gen()
end

-- Many short-lived coroutines: create, run to a yield, finish.
for i = 1, n // 10 do
  local co = create(function(a)
    local b = yield(a + 1)
    return a + b
  end)
  local _, x = resume(co, i)
  local _, y = resume(co, x)
  sum = sum + y
end

print(sum)

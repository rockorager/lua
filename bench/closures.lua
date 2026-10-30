-- Closures and upvalues: creating closures over fresh locals, calling
-- closures that read and write shared upvalues, and closing the upvalues of
-- loop variables.
-- Usage: lua closures.lua [N], default 2000000. Prints a checksum.

local n = tonumber(arg and arg[1]) or 2000000

local function counter(start)
  local c = start
  return function(d)
    c = c + d
    return c
  end
end

-- Creation: one closure and one upvalue per step, called twice.
local sum = 0
for i = 1, n do
  local f = counter(i)
  sum = sum + f(1) + f(2)
end

-- Calls through shared upvalues: two closures over the same two locals.
local acc, steps = 0, 0
local function add(x)
  acc = acc + x
  steps = steps + 1
end
local function sub(x)
  acc = acc - x // 2
  steps = steps + 1
end
for i = 1, n do
  add(i)
  sub(i)
end
sum = sum + acc + steps

-- Loop variables captured per iteration, so each closure closes its own.
local ring = {}
for i = 1, n do
  ring[i % 64 + 1] = function()
    return i
  end
  if i % 64 == 0 then
    for j = 1, 64 do
      sum = sum + ring[j]()
    end
  end
end

-- Nested upvalues: a closure reaching two levels out.
local function outer(a)
  return function(b)
    return function(c)
      return a + b + c
    end
  end
end
for i = 1, n // 4 do
  sum = sum + outer(i)(2)(3)
end

print(sum)

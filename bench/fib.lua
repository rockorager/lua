-- Calls: naive recursive Fibonacci, two Lua-to-Lua calls and returns per call.
-- Usage: lua fib.lua [N], default 35. Prints fib(N).

local n = tonumber(arg and arg[1]) or 35

local function fib(k)
  if k < 2 then
    return k
  end
  return fib(k - 1) + fib(k - 2)
end

print(fib(n))

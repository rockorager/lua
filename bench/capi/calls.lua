-- `just bench-capi`: lua calls.lua SCENARIO N. A tight loop of N calls
-- of one capibench function (or none, for `loop`), timed with os.clock:
-- prints a benchstat row of CPU ns per iteration, and a checksum on
-- stderr. `stack` prints the native stack bytes per level of
-- Lua -> C -> lua_call nesting instead.

local B = require "capibench"
local scenario, n = arg[1], math.tointeger(tonumber(arg[2]))
local clock = os.clock

local t0, sum = clock(), nil
if scenario == "loop" then
  local s = 0
  for i = 1, n do s = s + i end
  sum = s
elseif scenario == "nop" then
  local f = B.nop
  for i = 1, n do f() end
  sum = n
elseif scenario == "add" then
  local f, s = B.add, 0
  for i = 1, n do s = f(s, i) end
  sum = s
elseif scenario == "callback" then
  local f, s = B.callback, 0
  local function g () s = s + 1 return s end
  for i = 1, n do f(g) end
  sum = s
elseif scenario == "stack" then
  local cb = B.callback
  local function down (k)
    if k == 0 then return B.sp() end
    return cb(function () return down(k - 1) end)
  end
  local top, bottom = B.sp(), down(n)
  print((top - bottom) // n)
  return
else
  error("unknown scenario " .. tostring(scenario))
end
local t1 = clock()
io.stderr:write(sum, "\n")
print(string.format("BenchmarkCapi/%s\t%d\t%.2f ns/op", scenario, n,
                    (t1 - t0) * 1e9 / n))

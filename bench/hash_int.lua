-- Tables: the hash part with integer keys. The keys are spread out so they
-- stay out of the array part. Each pass inserts N keys into a fresh table,
-- looks every key up twice, misses on N absent keys, clears half, and walks
-- the rest with pairs.
-- Usage: lua hash_int.lua [N], default 100000. Prints a checksum.

local n = tonumber(arg and arg[1]) or 100000
local passes = 30
local stride = 7919

local sum, misses, walked = 0, 0, 0
for pass = 1, passes do
  local t = {}
  for i = 1, n do
    t[i * stride] = i + pass
  end
  for _ = 1, 2 do
    for i = 1, n do
      sum = sum + t[i * stride]
    end
  end
  for i = 1, n do
    if t[i * stride + 1] == nil then
      misses = misses + 1
    end
  end
  for i = 1, n, 2 do
    t[i * stride] = nil
  end
  for k, v in pairs(t) do
    walked = walked + v + k % 3
  end
end

print(sum, misses, walked)

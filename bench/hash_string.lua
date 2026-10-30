-- Tables: the hash part with string keys. Each pass inserts N keys into a
-- fresh table, looks every key up twice, misses on N absent keys, and clears
-- half. The keys are built once, so the passes time the table, not the
-- string builder.
-- Usage: lua hash_string.lua [N], default 100000. Prints a checksum.

local n = tonumber(arg and arg[1]) or 100000
local passes = 15

local keys, absent = {}, {}
for i = 1, n do
  keys[i] = "key" .. i
  absent[i] = "absent" .. i
end

local sum, misses, left = 0, 0, 0
for pass = 1, passes do
  local t = {}
  for i = 1, n do
    t[keys[i]] = i + pass
  end
  for _ = 1, 2 do
    for i = 1, n do
      sum = sum + t[keys[i]]
    end
  end
  for i = 1, n do
    if t[absent[i]] == nil then
      misses = misses + 1
    end
  end
  for i = 1, n, 2 do
    t[keys[i]] = nil
  end
  for i = 1, n do
    if t[keys[i]] then
      left = left + 1
    end
  end
end

print(sum, misses, left)

-- Tables: the array part. Each pass fills a fresh table with N integers by
-- index, appends N more with t[#t + 1], then reads it back with ipairs and
-- with a numeric for over #t.
-- Usage: lua array.lua [N], default 800000. Prints a checksum.

local n = tonumber(arg and arg[1]) or 800000
local passes = 10

local sum = 0
for pass = 1, passes do
  local t = {}
  for i = 1, n do
    t[i] = i + pass
  end
  for i = 1, n do
    t[#t + 1] = i
  end
  for _, v in ipairs(t) do
    sum = sum + v
  end
  for i = 1, #t do
    sum = sum + t[i] * 2
  end
end

print(sum)

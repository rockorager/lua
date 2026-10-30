-- Strings: table.concat. Each pass fills a buffer with N pieces, some
-- strings and some numbers, and joins it with and without a separator.
-- Usage: lua table_concat.lua [N], default 600000. Prints a checksum.

local n = tonumber(arg and arg[1]) or 600000
local passes = 10
local concat = table.concat

local words = { "alpha", "beta", "gamma", "delta", "epsilon", "zeta", "eta", "theta" }

local total, last = 0, ""
for pass = 1, passes do
  local buf = {}
  for i = 1, n do
    if i % 4 == 0 then
      buf[i] = i + pass
    else
      buf[i] = words[i % 8 + 1]
    end
  end
  local joined = concat(buf, ",")
  local plain = concat(buf)
  local slice = concat(buf, " ", n // 2, n // 2 + 99)
  total = total + #joined + #plain + #slice
  last = slice
end

print(total, #last, last:sub(1, 40))

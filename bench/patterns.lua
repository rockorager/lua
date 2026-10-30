-- Strings: Lua patterns through string.find, string.match, string.gsub, and
-- string.gmatch, over a generated text of words, numbers, and punctuation.
-- Usage: lua patterns.lua [N], default 10000 lines. Prints a checksum.

local n = tonumber(arg and arg[1]) or 10000
local passes = 10

local words = { "lorem", "Ipsum", "dolor", "sit", "amet", "Consectetur", "adipiscing", "elit" }
local lines = {}
for i = 1, n do
  local w1, w2, w3 = words[i % 8 + 1], words[(i * 3) % 8 + 1], words[(i * 5) % 8 + 1]
  lines[i] = string.format("%s %d, %s=%d; %s (%d.%d) key_%d: %s!", w1, i, w2, i * 7, w3, i % 100, i % 13, i, w1)
end
local text = table.concat(lines, "\n")

local find, match, gsub, gmatch = string.find, string.match, string.gsub, string.gmatch
local upper = { lorem = "LOREM", dolor = "DOLOR", amet = "AMET" }

local sum = 0
for _ = 1, passes do
  -- find with a pattern and an advancing init: every number.
  local pos, count = 1, 0
  while true do
    local s, e = find(text, "%d+", pos)
    if not s then
      break
    end
    count = count + (e - s + 1)
    pos = e + 1
  end
  sum = sum + count

  -- find, plain: every "key_".
  pos, count = 1, 0
  while true do
    local s = find(text, "key_", pos, true)
    if not s then
      break
    end
    count = count + 1
    pos = s + 4
  end
  sum = sum + count

  -- match with captures, one line at a time.
  for i = 1, n, 3 do
    local k, v = match(lines[i], "(%a+)=(%d+);")
    sum = sum + #k + tonumber(v)
  end

  -- gsub with a string, a table, and a function replacement.
  local r1, c1 = gsub(text, "(%a+) (%d+)", "%2 %1")
  local r2, c2 = gsub(text, "%a+", upper)
  local r3, c3 = gsub(text, "%((%d+)%.(%d+)%)", function(a, b)
    return a + b
  end)
  sum = sum + #r1 + c1 + #r2 + c2 + #r3 + c3

  -- gmatch with anchored classes and a frontier.
  for w in gmatch(text, "%f[%w]%u%l+") do
    sum = sum + #w
  end
end

print(sum)

-- Strings: the `..` operator in a loop. Each step builds a short string from
-- strings and numbers in one multi-operand concatenation, and appends it to
-- an accumulator that restarts every 64 pieces, so most results are new short
-- and medium strings.
-- Usage: lua concat.lua [N], default 2000000. Prints a checksum.

local n = tonumber(arg and arg[1]) or 2000000

local total, acc = 0, ""
for i = 1, n do
  local piece = "item" .. i .. ":" .. (i * 3) .. ";"
  if i % 64 == 0 then
    total = total + #acc
    acc = piece
  else
    acc = acc .. piece
  end
end
total = total + #acc

print(total, acc)

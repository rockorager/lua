-- Globals: code written without locals, so every name is a field of _ENV
-- (GETTABUP and SETTABUP with a constant key): global functions and
-- counters, and library functions reached through their global tables.
-- Usage: lua globals.lua [N], default 4000000. Prints a checksum.

N = tonumber(arg and arg[1]) or 4000000

-- Enough user globals that _ENV holds a realistic mix besides the library.
for i = 1, 40 do
  _ENV["g" .. i] = i
end

total = 0
steps = 0

function step(x)
  steps = steps + 1
  return x % 7
end

function mix(a, b)
  return a * 3 + b
end

for i = 1, N do
  total = total + step(i) + mix(g1, g40)
  if i % 3 == 0 then
    total = total + math.abs(g20 - i % 50) + string.len(g7 > i % 9 and "ab" or "abc")
  end
end

for i = 1, N // 2 do
  total = total - g11 + g12 - g13 + g14 + math.max(g2, g3) + type(total):len()
end

print(total, steps)

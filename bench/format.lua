-- Strings: string.format with the common conversions: %d with width and
-- flags, %s, %q, %x, %c, and %f, %e, and %g on floats.
-- Usage: lua format.lua [N], default 500000. Prints a checksum.

local n = tonumber(arg and arg[1]) or 500000
local format = string.format

local names = { "ada", "grace", "edsger", "barbara", "ken", "dennis", "niklaus" }

local total, last = 0, ""
for i = 1, n do
  local name = names[i % #names + 1]
  local x = i / 7
  local s = format("%5d|%-8s|%08x|%c|%.3f", i, name, i * 2654435761 % 4294967296, 65 + i % 26, x)
  local t = format("%s=%q %e %g %+d%%", name, name, x, x * 1000, -i)
  total = total + #s + #t
  last = s .. " " .. t
end

print(total, last)

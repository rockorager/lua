-- Floats: the Mandelbrot set over an N by N grid, at most 50 iterations a
-- point. Tight float arithmetic and comparisons in locals, no tables.
-- Usage: lua mandelbrot.lua [N], default 1000. Prints the number of points in
-- the set and the sum of the escape iterations of the rest.

local n = tonumber(arg and arg[1]) or 1000
local max_iter = 50

local inside, escaped = 0, 0
for y = 0, n - 1 do
  local ci = 2 * y / n - 1
  for x = 0, n - 1 do
    local cr = 2 * x / n - 1.5
    local zr, zi, zr2, zi2 = 0.0, 0.0, 0.0, 0.0
    local iter = 0
    while iter < max_iter and zr2 + zi2 <= 4.0 do
      zi = 2 * zr * zi + ci
      zr = zr2 - zi2 + cr
      zr2 = zr * zr
      zi2 = zi * zi
      iter = iter + 1
    end
    if zr2 + zi2 <= 4.0 then
      inside = inside + 1
    else
      escaped = escaped + iter
    end
  end
end

print(inside, escaped)

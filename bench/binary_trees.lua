-- Tables and the collector: the benchmarks game's binary-trees, which builds
-- and walks many short-lived complete binary trees of two-slot tables.
-- Usage: lua binary_trees.lua [N], default 15. Prints the game's report.

local n = tonumber(arg and arg[1]) or 15

local function bottom_up(depth)
  if depth == 0 then
    return {}
  end
  depth = depth - 1
  return { bottom_up(depth), bottom_up(depth) }
end

local function check(tree)
  if tree[1] then
    return 1 + check(tree[1]) + check(tree[2])
  end
  return 1
end

local min_depth = 4
local max_depth = math.max(min_depth + 2, n)

local stretch = max_depth + 1
print(string.format("stretch tree of depth %d\t check: %d", stretch, check(bottom_up(stretch))))

local long_lived = bottom_up(max_depth)

for depth = min_depth, max_depth, 2 do
  local iterations = 1 << (max_depth - depth + min_depth)
  local sum = 0
  for _ = 1, iterations do
    sum = sum + check(bottom_up(depth))
  end
  print(string.format("%d\t trees of depth %d\t check: %d", iterations, depth, sum))
end

print(string.format("long lived tree of depth %d\t check: %d", max_depth, check(long_lived)))

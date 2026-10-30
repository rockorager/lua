-- Method calls through metatables: obj:method() where the method comes from
-- the class through __index, from a base class through a second __index
-- table, and from an __index function; plus __add and __eq on objects.
-- Usage: lua methods.lua [N], default 2000000. Prints a checksum.

local n = tonumber(arg and arg[1]) or 2000000

local Point = {}
Point.__index = Point

function Point.new(x, y)
  return setmetatable({ x = x, y = y }, Point)
end

function Point:move(dx, dy)
  self.x = self.x + dx
  self.y = self.y + dy
end

function Point:dot(other)
  return self.x * other.x + self.y * other.y
end

Point.__add = function(a, b)
  return Point.new(a.x + b.x, a.y + b.y)
end

Point.__eq = function(a, b)
  return a.x == b.x and a.y == b.y
end

-- A subclass: its own methods through one __index table, the base's
-- through a second.
local Point3 = setmetatable({}, { __index = Point })
Point3.__index = Point3

function Point3.new(x, y, z)
  local p = setmetatable(Point.new(x, y), Point3)
  p.z = z
  return p
end

function Point3:lift(dz)
  self.z = self.z + dz
end

-- A proxy whose methods come from an __index function.
local proxy = setmetatable({}, {
  __index = function(_, key)
    if key == "get" then
      return function(_, i)
        return i % 7
      end
    end
  end,
})

local p = Point.new(0, 0)
local q = Point3.new(1, 2, 3)
local sum = 0
for i = 1, n do
  p:move(1, -1)
  q:move(-1, 1)
  q:lift(1)
  sum = sum + p:dot(q) % 1000 + proxy:get(i)
  if i % 16 == 0 then
    local r = p + q
    if r == Point.new(p.x + q.x, p.y + q.y) then
      sum = sum + 1
    end
  end
end

print(sum, p.x, p.y, q.x, q.y, q.z)

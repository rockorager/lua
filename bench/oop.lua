-- Objects: a predator and prey simulation built from classes the way Lua
-- programs write them: a class() helper over metatables, inheritance
-- three levels deep, constructors and overridden methods that call the
-- base class's, a small vector class, method calls on every object every
-- tick, and objects created and dropped as the populations change.
-- Usage: lua oop.lua [N], default 300 ticks. Prints a checksum.

local n = tonumber(arg and arg[1]) or 300

local sqrt = math.sqrt

-- A deterministic generator, so both implementations simulate the same
-- world.
local seed = 12345
local function rand()
  seed = (seed * 1103515245 + 12345) % 2147483648
  return seed / 2147483648
end

local function class(parent)
  local c = {}
  c.__index = c
  if parent then
    setmetatable(c, { __index = parent })
  end
  c.new = function(...)
    local o = setmetatable({}, c)
    o:init(...)
    return o
  end
  return c
end

local Vec = class()

function Vec:init(x, y)
  self.x = x
  self.y = y
end

function Vec:addScaled(v, k)
  self.x = self.x + v.x * k
  self.y = self.y + v.y * k
end

function Vec:dist2(v)
  local dx, dy = self.x - v.x, self.y - v.y
  return dx * dx + dy * dy
end

function Vec:normalize(len)
  local l = sqrt(self.x * self.x + self.y * self.y)
  if l > 0 then
    self.x = self.x / l * len
    self.y = self.y / l * len
  end
end

local World = class()
local size = 64

-- Entity: everything in the world has a position, an age, and energy.
local Entity = class()

function Entity:init(world, x, y, energy)
  self.world = world
  self.pos = Vec.new(x, y)
  self.age = 0
  self.energy = energy
  self.alive = true
end

function Entity:update(dt)
  self.age = self.age + dt
end

function Entity:die()
  self.alive = false
  self.world:record("death", self:kind())
end

function Entity:kind()
  return "entity"
end

-- Plant: grows in place, eaten by prey.
local Plant = class(Entity)

function Plant:init(world, x, y)
  Entity.init(self, world, x, y, 5)
end

function Plant:update(dt)
  Entity.update(self, dt)
  if self.energy < 30 then
    self.energy = self.energy + dt * 2
  end
end

function Plant:kind()
  return "plant"
end

-- Mover: has a velocity, wraps around the edges, pays to move.
local Mover = class(Entity)

function Mover:init(world, x, y, energy, speed)
  Entity.init(self, world, x, y, energy)
  self.speed = speed
  self.vel = Vec.new(rand() - 0.5, rand() - 0.5)
  self.vel:normalize(speed)
end

function Mover:update(dt)
  Entity.update(self, dt)
  self.pos:addScaled(self.vel, dt)
  self:wrap()
  self.energy = self.energy - self:cost(dt)
  if self.energy <= 0 or self.age > self:lifespan() then
    self:die()
  end
end

function Mover:wrap()
  local p = self.pos
  if p.x < 0 then
    p.x = p.x + size
  elseif p.x >= size then
    p.x = p.x - size
  end
  if p.y < 0 then
    p.y = p.y + size
  elseif p.y >= size then
    p.y = p.y - size
  end
end

function Mover:cost(dt)
  return dt * (0.5 + self.speed * 0.2)
end

function Mover:turn()
  self.vel.x = self.vel.x + (rand() - 0.5) * 0.5
  self.vel.y = self.vel.y + (rand() - 0.5) * 0.5
  self.vel:normalize(self.speed)
end

function Mover:lifespan()
  return 60
end

-- Prey: grazes plants in its cell, splits when well fed.
local Prey = class(Mover)

function Prey:init(world, x, y)
  Mover.init(self, world, x, y, 20, 1.5)
end

function Prey:update(dt)
  Mover.update(self, dt)
  if not self.alive then
    return
  end
  local plant = self.world:plantAt(self.pos)
  if plant.energy > 1 then
    local bite = plant.energy < 3 and plant.energy or 3
    plant.energy = plant.energy - bite
    self.energy = self.energy + bite
  else
    self:turn()
  end
  if self.energy > 40 then
    self:reproduce()
  end
end

function Prey:reproduce()
  if self.world.counts.prey >= 2000 then
    return
  end
  self.energy = self.energy / 2
  local child = Prey.new(self.world, self.pos.x, self.pos.y)
  child.energy = self.energy
  self.world:spawn(child)
end

function Prey:kind()
  return "prey"
end

-- Predator: chases the nearest of a few prey it notices, eats on contact.
local Predator = class(Mover)

function Predator:init(world, x, y)
  Mover.init(self, world, x, y, 60, 2.5)
end

function Predator:lifespan()
  return 80
end

function Predator:update(dt)
  Mover.update(self, dt)
  if not self.alive then
    return
  end
  local target = self.target
  if not (target and target.alive and self.pos:dist2(target.pos) < 900) then
    target = self:look()
    self.target = target
  end
  if target then
    if self.pos:dist2(target.pos) < 4 then
      target:die()
      self.target = nil
      self.energy = self.energy + 25
    else
      self.vel.x = target.pos.x - self.pos.x
      self.vel.y = target.pos.y - self.pos.y
      self.vel:normalize(self.speed)
    end
  else
    self:turn()
  end
  if self.energy > 100 then
    self:reproduce()
  end
end

function Predator:look()
  local prey = self.world.prey
  local count = #prey
  if count == 0 then
    return nil
  end
  local best, bestd = nil, 400
  for _ = 1, 6 do
    local p = prey[(rand() * count) // 1 + 1]
    if p.alive then
      local d = self.pos:dist2(p.pos)
      if d < bestd then
        best, bestd = p, d
      end
    end
  end
  return best
end

function Predator:reproduce()
  if self.world.counts.predator >= 200 then
    return
  end
  self.energy = self.energy / 2
  local child = Predator.new(self.world, self.pos.x, self.pos.y)
  child.energy = self.energy
  self.world:spawn(child)
end

function Predator:kind()
  return "predator"
end

-- The world: a grid of plants, lists of movers, and statistics.

function World:init()
  self.plants = {}
  for y = 0, size - 1 do
    local row = {}
    for x = 0, size - 1 do
      row[x] = Plant.new(self, x + 0.5, y + 0.5)
    end
    self.plants[y] = row
  end
  self.movers = {}
  self.prey = {}
  self.born = {}
  self.counts = { prey = 0, predator = 0 }
  self.events = { birth = {}, death = {} }
end

function World:record(event, kind)
  local e = self.events[event]
  e[kind] = (e[kind] or 0) + 1
end

function World:plantAt(pos)
  return self.plants[pos.y // 1][pos.x // 1]
end

function World:spawn(m)
  self.born[#self.born + 1] = m
  local k = m:kind()
  self.counts[k] = self.counts[k] + 1
  self:record("birth", k)
end

function World:step(dt)
  for y = 0, size - 1 do
    local row = self.plants[y]
    for x = 0, size - 1 do
      row[x]:update(dt)
    end
  end
  local movers = self.movers
  for i = 1, #movers do
    local m = movers[i]
    if m.alive then
      m:update(dt)
    end
  end
  -- Keep the living and add the newborn.
  local kept, prey = {}, {}
  local counts = { prey = 0, predator = 0 }
  local function keep(m)
    if m.alive then
      kept[#kept + 1] = m
      local k = m:kind()
      counts[k] = counts[k] + 1
      if k == "prey" then
        prey[#prey + 1] = m
      end
    end
  end
  for i = 1, #movers do
    keep(movers[i])
  end
  for i = 1, #self.born do
    keep(self.born[i])
  end
  self.movers, self.prey, self.counts, self.born = kept, prey, counts, {}
end

local world = World.new()
for _ = 1, 600 do
  world:spawn(Prey.new(world, rand() * size, rand() * size))
end
for _ = 1, 40 do
  world:spawn(Predator.new(world, rand() * size, rand() * size))
end

local trace = 0
for tick = 1, n do
  world:step(0.5)
  trace = trace + world.counts.prey * tick + world.counts.predator
end

local energy = 0
for _, m in ipairs(world.movers) do
  energy = energy + m.energy
end
local e = world.events
print(
  trace,
  world.counts.prey,
  world.counts.predator,
  e.birth.prey,
  e.birth.predator or 0,
  e.death.prey or 0,
  e.death.predator or 0,
  string.format("%.6f", energy)
)

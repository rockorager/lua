-- Floats: the benchmarks game's n-body, which integrates five planets'
-- orbits. Float arithmetic and field access on small tables.
-- Usage: lua nbody.lua [N], default 500000 steps. Prints the energy before
-- and after.

local n = tonumber(arg and arg[1]) or 500000

local sqrt = math.sqrt
local pi = math.pi
local solar_mass = 4 * pi * pi
local days_per_year = 365.24

local bodies = {
  { -- Sun
    x = 0,
    y = 0,
    z = 0,
    vx = 0,
    vy = 0,
    vz = 0,
    mass = solar_mass,
  },
  { -- Jupiter
    x = 4.84143144246472090e+00,
    y = -1.16032004402742839e+00,
    z = -1.03622044471123109e-01,
    vx = 1.66007664274403694e-03 * days_per_year,
    vy = 7.69901118419740425e-03 * days_per_year,
    vz = -6.90460016972063023e-05 * days_per_year,
    mass = 9.54791938424326609e-04 * solar_mass,
  },
  { -- Saturn
    x = 8.34336671824457987e+00,
    y = 4.12479856412430479e+00,
    z = -4.03523417114321381e-01,
    vx = -2.76742510726862411e-03 * days_per_year,
    vy = 4.99852801234917238e-03 * days_per_year,
    vz = 2.30417297573763929e-05 * days_per_year,
    mass = 2.85885980666130812e-04 * solar_mass,
  },
  { -- Uranus
    x = 1.28943695621391310e+01,
    y = -1.51111514016986312e+01,
    z = -2.23307578892655734e-01,
    vx = 2.96460137564761618e-03 * days_per_year,
    vy = 2.37847173959480950e-03 * days_per_year,
    vz = -2.96589568540237556e-05 * days_per_year,
    mass = 4.36624404335156298e-05 * solar_mass,
  },
  { -- Neptune
    x = 1.53796971148509165e+01,
    y = -2.59193146099879641e+01,
    z = 1.79258772950371181e-01,
    vx = 2.68067772490389322e-03 * days_per_year,
    vy = 1.62824170038242295e-03 * days_per_year,
    vz = -9.51592254519715870e-05 * days_per_year,
    mass = 5.15138902046611451e-05 * solar_mass,
  },
}

local nbody = #bodies

local function advance(dt)
  for i = 1, nbody do
    local bi = bodies[i]
    local bix, biy, biz, bimass = bi.x, bi.y, bi.z, bi.mass
    local bivx, bivy, bivz = bi.vx, bi.vy, bi.vz
    for j = i + 1, nbody do
      local bj = bodies[j]
      local dx, dy, dz = bix - bj.x, biy - bj.y, biz - bj.z
      local d2 = dx * dx + dy * dy + dz * dz
      local mag = sqrt(d2)
      mag = dt / (mag * d2)
      local bm = bj.mass * mag
      bivx = bivx - (dx * bm)
      bivy = bivy - (dy * bm)
      bivz = bivz - (dz * bm)
      bm = bimass * mag
      bj.vx = bj.vx + (dx * bm)
      bj.vy = bj.vy + (dy * bm)
      bj.vz = bj.vz + (dz * bm)
    end
    bi.vx = bivx
    bi.vy = bivy
    bi.vz = bivz
    bi.x = bix + dt * bivx
    bi.y = biy + dt * bivy
    bi.z = biz + dt * bivz
  end
end

local function energy()
  local e = 0
  for i = 1, nbody do
    local bi = bodies[i]
    local vx, vy, vz, bim = bi.vx, bi.vy, bi.vz, bi.mass
    e = e + (0.5 * bim * (vx * vx + vy * vy + vz * vz))
    for j = i + 1, nbody do
      local bj = bodies[j]
      local dx, dy, dz = bi.x - bj.x, bi.y - bj.y, bi.z - bj.z
      local distance = sqrt(dx * dx + dy * dy + dz * dz)
      e = e - ((bim * bj.mass) / distance)
    end
  end
  return e
end

local function offset_momentum()
  local px, py, pz = 0, 0, 0
  for i = 1, nbody do
    local b = bodies[i]
    local bim = b.mass
    px = px + (b.vx * bim)
    py = py + (b.vy * bim)
    pz = pz + (b.vz * bim)
  end
  bodies[1].vx = -px / solar_mass
  bodies[1].vy = -py / solar_mass
  bodies[1].vz = -pz / solar_mass
end

offset_momentum()
print(string.format("%0.9f", energy()))
for _ = 1, n do
  advance(0.01)
end
print(string.format("%0.9f", energy()))

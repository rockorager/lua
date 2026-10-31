-- Data in Lua source: a large configuration written as one table
-- constructor, the way games, build tools, and editors keep their data in
-- Lua files. Each pass compiles the source with load, runs it to build the
-- tables, and queries them: an index by id, lookups by dotted path,
-- filters by type and tag, and recipes resolved recursively.
-- Usage: lua config.lua [N], default 2000 items. Prints a checksum.

local n = tonumber(arg and arg[1]) or 2000
local passes = 64

local format, concat = string.format, table.concat

-- The source: settings, then N items, then monsters that drop them.
local kinds = { "weapon", "armor", "potion", "material", "tool", "food" }
local tags = { "melee", "ranged", "fire", "ice", "rare", "common", "heavy", "light", "magic", "craftable" }
local out = {}
local function emit(s)
  out[#out + 1] = s
end
emit("-- generated game data\nreturn {\n")
emit([[  settings = {
    window = { width = 1280, height = 720, fullscreen = false, vsync = true, title = "Example" },
    audio = { master = 0.8, music = 0.5, effects = 0.7, muted = false },
    controls = {
      up = "w", down = "s", left = "a", right = "d", jump = "space", attack = "mouse1",
      inventory = { "i", "tab" }, map = { "m" }, pause = { "escape", "p" },
    },
    difficulty = "normal",
    seed = 20261031,
  },
]])
emit("  items = {\n")
for i = 1, n do
  local kind = kinds[i % #kinds + 1]
  local t1, t2 = tags[i % #tags + 1], tags[(i * 7) % #tags + 1]
  emit(format('    { id = "%s_%d", name = "%s %d", kind = "%s", value = %d, weight = %.2f,\n', kind, i, kind, i, kind, i * 13 % 997, (i % 40) / 4))
  emit(format('      tags = { "%s", "%s" }, stackable = %s,\n', t1, t2, tostring(i % 3 == 0)))
  emit(format("      stats = { power = %d, speed = %d, durability = %d },\n", i % 50, i % 17, i * 3 % 400))
  if i > 10 and i % 4 == 0 then
    local a, b = i - 1 - i % 7, i - 3 - i % 5
    emit(format('      recipe = { { item = "%s_%d", count = %d }, { item = "%s_%d", count = %d } },\n', kinds[a % #kinds + 1], a, i % 3 + 1, kinds[b % #kinds + 1], b, i % 2 + 1))
  end
  emit("    },\n")
end
emit("  },\n  monsters = {\n")
for i = 1, n // 4 do
  local drop = i * 4 - 1
  emit(format('    { name = "monster %d", level = %d, health = %d, drops = { "%s_%d", "%s_%d" }, boss = %s },\n', i, i % 60 + 1, i * 17 % 5000 + 100, kinds[drop % #kinds + 1], drop, kinds[i % #kinds + 1], i, tostring(i % 50 == 0)))
end
emit("  },\n}\n")
local source = concat(out)

-- `t.a.b.c`, or nil.
local function get(t, path)
  for key in path:gmatch("[^.]+") do
    if type(t) ~= "table" then
      return nil
    end
    t = t[tonumber(key) or key]
  end
  return t
end

-- The base materials an item needs, by id, counted recursively.
local function materials(index, item, count, acc)
  if not item.recipe then
    acc[item.id] = (acc[item.id] or 0) + count
    return acc
  end
  for _, part in ipairs(item.recipe) do
    materials(index, index[part.item], count * part.count, acc)
  end
  return acc
end

local sum = 0
for _ = 1, passes do
  local data = assert(load(source, "=config"))()

  local index = {}
  for _, item in ipairs(data.items) do
    index[item.id] = item
  end

  sum = sum + get(data, "settings.window.width") + #get(data, "settings.controls.pause")
  for i = 1, #data.items, 3 do
    sum = sum + get(data, "items." .. i .. ".stats.power")
  end

  local byKind, tagged = {}, 0
  for _, item in ipairs(data.items) do
    byKind[item.kind] = (byKind[item.kind] or 0) + item.value
    for _, tag in ipairs(item.tags) do
      if tag == "rare" or tag == "magic" then
        tagged = tagged + 1
      end
    end
  end
  for _, kind in ipairs(kinds) do
    sum = sum + byKind[kind]
  end
  sum = sum + tagged

  for _, m in ipairs(data.monsters) do
    for _, id in ipairs(m.drops) do
      local item = index[id]
      if item then
        local acc = materials(index, item, 1, {})
        for _, count in pairs(acc) do
          sum = sum + count
        end
        sum = sum + (m.boss and 2 or 1) * item.stats.durability
      end
    end
  end
end

print(sum, #source)

-- The collector: weak tables, finalizers, and collectgarbage's options.
local function keys(t)
  local ks = {}
  for k, v in pairs(t) do ks[#ks + 1] = tostring(type(k) == "table" and "table" or k) .. "=" .. tostring(type(v) == "table" and "table" or v) end
  table.sort(ks)
  return table.concat(ks, " ")
end

-- Options and their results.
print(collectgarbage("isrunning"), collectgarbage("incremental"), collectgarbage("generational"), collectgarbage("incremental"))
print(collectgarbage("param", "pause"), collectgarbage("param", "stepmul"), collectgarbage("param", "stepsize"))
print(collectgarbage("param", "minormul"), collectgarbage("param", "majorminor"), collectgarbage("param", "minormajor"))
print(collectgarbage("param", "pause", 150), collectgarbage("param", "pause", 250), collectgarbage("param", "pause"))
print(collectgarbage("stop"), collectgarbage("isrunning"), collectgarbage("restart"), collectgarbage("isrunning"))
print(collectgarbage(), collectgarbage("collect"), math.type(collectgarbage("count")))
print(pcall(collectgarbage, "nope"), pcall(collectgarbage, "param", "nope"))

-- A full step cycle ends with true.
collectgarbage()
local done
for i = 1, 1000 do
  done = collectgarbage("step")
  if done then print("cycle done") break end
end
print(collectgarbage("step", 10 ^ 8))

for _, mode in ipairs({ "incremental", "generational" }) do
  collectgarbage(mode)
  print("mode", mode)

  -- Weak keys, weak values, and both; strings are values and stay.
  local live = {}
  local wk = setmetatable({}, { __mode = "k" })
  local wv = setmetatable({}, { __mode = "v" })
  local wkv = setmetatable({}, { __mode = "kv" })
  for i = 1, 5 do
    wk[{}] = i
    wv[i] = {}
    wv["s" .. i] = ("str"):rep(i)
    wkv[{}] = {}
  end
  wk[live] = "live"
  wv.live = live
  wkv[live] = live
  wk[1], wv[100], wkv.x = "one", 100, "x"
  wk[("long"):rep(20)] = "long key"
  collectgarbage()
  print(keys(wk))
  print(keys(wv))
  print(keys(wkv))

  -- Ephemerons: a value referring to its own key does not keep it.
  local eph = setmetatable({}, { __mode = "k" })
  do
    local k1, k2 = {}, {}
    eph[k1] = { k1 }
    eph[k2] = { k1, k2 }
    eph[live] = { live }
  end
  collectgarbage()
  print(keys(eph))

  -- A chain through an ephemeron: kept while its head is.
  local head = {}
  local n = head
  for i = 1, 20 do
    local nx = {}
    eph[n] = nx
    n = nx
  end
  collectgarbage()
  local len = 0
  n = head
  while eph[n] do n = eph[n]; len = len + 1 end
  print("chain", len)
  head = nil
  collectgarbage()
  print(keys(eph))

  -- Finalizers run in reverse order of marking, each once.
  local order = {}
  for i = 1, 5 do
    setmetatable({}, { __gc = function() order[#order + 1] = i end })
  end
  collectgarbage()
  print("order", table.concat(order, " "))

  -- __gc must be in the metatable when it is set.
  local ran = false
  local mt = {}
  local late = setmetatable({}, mt)
  mt.__gc = function() ran = true end
  late = nil
  collectgarbage()
  print("late __gc ran", ran)

  -- __gc = true (not a function) marks for finalization but calls nothing.
  setmetatable({}, { __gc = true })
  collectgarbage()

  -- Resurrection: the object lives on; its weak-value entries go first,
  -- its weak-key entries stay until it really dies.
  local saved
  local wvr = setmetatable({}, { __mode = "v" })
  local wkr = setmetatable({}, { __mode = "k" })
  do
    local o = setmetatable({ name = "zombie" }, { __gc = function(o)
      saved = o
      print("in __gc", wvr[1] == nil, wkr[o])
    end })
    wvr[1] = o
    wkr[o] = "key"
  end
  collectgarbage()
  print("resurrected", saved and saved.name, wvr[1], wkr[saved])
  saved = nil
  collectgarbage()
  collectgarbage()
  print("gone", next(wkr))

  -- collectgarbage inside a finalizer fails.
  local inner
  setmetatable({}, { __gc = function() inner = { collectgarbage(), collectgarbage("count"), collectgarbage("step") } end })
  collectgarbage()
  print("inside __gc", inner[1], inner[2], inner[3])

  -- An error in __gc becomes a warning.
  warn("@on")
  setmetatable({}, { __gc = function() error("boom in gc") end })
  setmetatable({}, { __gc = function() error({}) end })
  collectgarbage()
  warn("@off")

  -- The count goes down once garbage is collected, finalizers included.
  collectgarbage()
  local before = collectgarbage("count")
  do
    local big = {}
    for i = 1, 20000 do big[i] = { i } end
    setmetatable({}, { __gc = function() big = nil end })
  end
  local during = collectgarbage("count")
  collectgarbage()
  collectgarbage()
  local after = collectgarbage("count")
  print("count", during > before + 500, after < before + 50)

  -- Collected coroutines close nothing but free their upvalues' values.
  local wc = setmetatable({}, { __mode = "v" })
  local f
  do
    local co = coroutine.wrap(function()
      local a = 10
      f = function() a = a + 1; return a end
      while true do coroutine.yield() end
    end)
    co()
    wc[1] = co
  end
  collectgarbage()
  print("coroutine", wc[1], f(), f())
end

-- Files close when collected.
local name = os.tmpname()
do
  local fh = assert(io.open(name, "w"))
  fh:write("written before collection")
end
collectgarbage()
collectgarbage()
local fh = assert(io.open(name))
print(fh:read("a"))
fh:close()
os.remove(name)

-- Finalizers left at exit run at close, newest first.
setmetatable({}, { __gc = function() print("closing 1") end })
setmetatable({}, { __gc = function() print("closing 2") end })
_G.keep = setmetatable({}, { __gc = function() print("closing kept") end })
print("end")
